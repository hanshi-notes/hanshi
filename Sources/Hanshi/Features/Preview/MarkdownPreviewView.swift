import AppKit
import SwiftUI
import Observation
import MarkdownEngine

@Observable final class MarkdownPreviewSession {
    var scrollView: NSScrollView { native.scrollView }
    var textView: NSTextView { native.engine.textView! }
    var engine: NativeTextViewCoordinator { native.engine }
    private(set) var message: String?
    private(set) var isRendering = false
    private(set) var appliedSnapshot: PreviewSnapshot?
    private(set) var composition: MarkdownComposition?
    private(set) var recipe: MarkdownRecipe?
    @ObservationIgnored private var requested: PreviewSnapshot?
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pending: (PreviewSnapshot, UUID)?
    @ObservationIgnored private weak var document: NoteDocument?
    @ObservationIgnored private var renderer: @Sendable (PreviewSnapshot, MarkdownRecipe?) async throws -> MarkdownRecipe
    @ObservationIgnored var scrollSync: MarkdownScrollSync?
    @ObservationIgnored var openNote: ((URL, String?) -> Bool)?
    @ObservationIgnored var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored var revealFile: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    @ObservationIgnored var pendingHeading: String?
    @ObservationIgnored var focusDocumentID: String?
    let identity = UUID()
    let debounce: Duration

    init(debounce: Duration = .milliseconds(150),
         renderer: @escaping @Sendable (PreviewSnapshot, MarkdownRecipe?) async throws -> MarkdownRecipe = { snapshot, cached in
             try await MarkdownRenderer.render(snapshot, cached: cached)
         }) {
        self.debounce = debounce
        self.renderer = renderer
    }

    // State may construct discarded sessions when its view is recreated. Build AppKit only on use.
    @ObservationIgnored private lazy var native: (scrollView: NSScrollView, engine: NativeTextViewCoordinator) = {
        let wrapper = NativeTextViewWrapper(text: .constant(""), configuration: PreviewTheme().engineConfiguration, isEditable: false)
        let engine = wrapper.makeCoordinator()
        let scrollView = wrapper.makeAppKitView(coordinator: engine)
        let textView = engine.textView!
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.backgroundColor = .white
        textView.setAccessibilityLabel("Markdown preview")
        engine.onOpenLink = { [weak self] target in self?.followLink(target) }
        return (scrollView, engine)
    }()

    func show(_ snapshot: PreviewSnapshot, document: NoteDocument? = nil) {
        self.document = document
        guard requested != snapshot else { return }
        let previous = requested
        let switching = appliedSnapshot?.documentID != snapshot.documentID || appliedSnapshot?.library != snapshot.library
        textView.isEditable = snapshot.settings.allowsEditing && document != nil && !switching
        textView.allowsUndo = textView.isEditable
        requested = snapshot
        token = UUID()
        waiting?.cancel(); pending = nil; worker?.cancel()
        if appliedSnapshot?.documentID != snapshot.documentID || appliedSnapshot?.library != snapshot.library {
            recipe = nil; composition = nil; appliedSnapshot = nil
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            scrollView.contentView.scroll(to: .zero)
            message = nil
        }
        // Style-only updates reuse both the parse and HighlightKit tokens.
        if var applied = appliedSnapshot, recipe != nil {
            applied.theme = snapshot.theme
            applied.settings = snapshot.settings
            if applied == snapshot {
                isRendering = true
                enqueue(snapshot, token: token)
                return
            }
        }
        isRendering = true
        let currentToken = token
        if previous == nil || previous?.documentID != snapshot.documentID || previous?.url != snapshot.url || previous?.resources != snapshot.resources {
            enqueue(snapshot, token: currentToken)
        } else {
            waiting = Task { [weak self, debounce] in
                do { try await Task.sleep(for: debounce) } catch { return }
                guard let self, token == currentToken else { return }
                enqueue(snapshot, token: currentToken)
            }
        }
    }

    private func enqueue(_ snapshot: PreviewSnapshot, token: UUID) {
        pending = (snapshot, token)
        startPending()
    }
    private func startPending() {
        guard worker == nil, let (snapshot, requestToken) = pending else { return }
        pending = nil
        let cached = appliedSnapshot?.text == snapshot.text ? recipe : nil
        let render = renderer
        var styled = appliedSnapshot
        styled?.theme = snapshot.theme
        styled?.settings = snapshot.settings
        let styleOnly = styled == snapshot && appliedSnapshot != snapshot && cached != nil
        worker = Task { [weak self] in
            let result: Result<MarkdownRecipe, any Error>
            do { result = .success(try await (styleOnly ? cached! : render(snapshot, cached))) }
            catch { result = .failure(error) }
            guard let self else { return }
            if token == requestToken, requested == snapshot, isCurrent(snapshot) {
                switch result {
                case let .success(recipe):
                    do { try await apply(recipe, snapshot: snapshot, requestToken: requestToken) }
                    catch { /* Cancellation leaves the previous valid projection in place. */ }
                case let .failure(error):
                    if !(error is CancellationError) { message = "Preview is out of date: \(error.localizedDescription)" }
                }
            }
            if token == requestToken { isRendering = false; focusIfNeeded() }
            worker = nil
            startPending()
        }
    }
    func isCurrent(_ snapshot: PreviewSnapshot) -> Bool {
        guard let document else { return true }
        return document.id == snapshot.documentID && document.text == snapshot.text && document.url == snapshot.url
    }
    func hide() {
        requested = nil; token = UUID(); pending = nil
        waiting?.cancel(); waiting = nil; worker?.cancel()
        isRendering = false
        scrollSync?.disconnect(); scrollSync = nil
    }
    func waitForRendering() async {
        await waiting?.value
        while let worker { await worker.value }
    }
    func retry() {
        guard let snapshot = requested else { return }
        requested = nil
        show(snapshot, document: document)
    }
    private func apply(_ recipe: MarkdownRecipe, snapshot: PreviewSnapshot, requestToken: UUID) async throws {
        try Task.checkCancellation()
        guard token == requestToken, requested == snapshot, isCurrent(snapshot) else { return }
        // An in-flight native keystroke or IME composition must win over an older render.
        guard !textView.hasMarkedText(), engine.pendingSourceText == nil || engine.pendingSourceText == snapshot.text else { return }
        let nativeEdit = appliedSnapshot?.documentID == snapshot.documentID
            && appliedSnapshot?.text != snapshot.text && engine.sourceText == snapshot.text
        let selection = textView.selectedRange()
        // The document top includes its margin; restoring the first text anchor would scroll it away.
        let oldAnchor = nativeEdit || scrollView.contentView.bounds.minY <= 0 ? nil : readingPosition()
        let oldComposition = composition
        let resources = EnginePreviewResources(recipe: recipe)
        var configuration = snapshot.theme.engineConfiguration
        configuration.lists.autoClosePairsEnabled = snapshot.settings.autoClosePairs
        configuration.showsMarkdownMarkersWhileEditing = snapshot.settings.showsMarkdownMarkers
        configuration.services = MarkdownEditorServices(wikiLinks: WikiLinkIndex(notes: snapshot.noteURLs, root: snapshot.root),
                                                       images: resources, syntaxHighlighter: resources, latex: resources)
        if appliedSnapshot?.documentID == snapshot.documentID, engine.sourceText != snapshot.text {
            textView.undoManager?.removeAllActions()
        }
        let binding: Binding<String>
        if let document {
            binding = Binding(get: { [weak document] in document?.text ?? snapshot.text },
                set: { [weak self, weak document] text in
                    guard let document else { return }
                    document.edit(text)
                    document.editor.synchronize(text)
                    guard let self, self.document === document, var next = requested else { return }
                    next.text = text
                    show(next, document: document)
                })
        } else { binding = .constant(snapshot.text) }
        let wrapper = NativeTextViewWrapper(text: binding, configuration: configuration,
            fontName: snapshot.theme.bodyFont(size: snapshot.theme.bodySize).fontName,
            fontSize: snapshot.theme.bodySize, documentId: snapshot.documentID,
            isEditable: snapshot.settings.allowsEditing && document != nil)
        wrapper.updateAppKitView(scrollView, coordinator: engine)
        textView.allowsUndo = textView.isEditable
        self.recipe = recipe
        // Markdown stays in place except for the engine's shortened wiki links.
        let displayed = engine.previewRanges(fromSourceRanges: recipe.anchors.map(\.source))
        let anchors = zip(recipe.anchors, displayed).compactMap { anchor, range in
            range.map { MarkdownAnchor(source: anchor.source, rendered: $0, heading: anchor.heading) }
        }
        let result = MarkdownComposition(text: textView.string as NSString, anchors: anchors)
        self.composition = result
        appliedSnapshot = snapshot
        message = recipe.diagnostics.isEmpty ? nil : Array(Set(recipe.diagnostics)).sorted().joined(separator: " · ")
        textView.setSelectedRange(nativeEdit ? selection : Self.translateSelection(selection, from: oldComposition, to: result))
        if let oldAnchor { restore(position: oldAnchor) }
        else if !nativeEdit { MarkdownScrollSync.scroll(scrollView, to: 0) }
        if nativeEdit { scrollSync?.synchronize(from: .preview) }
        else { scrollSync?.contentDidChange() }
        if focusDocumentID == snapshot.documentID, let heading = pendingHeading { pendingHeading = nil; navigateHeading(heading) }
        focusIfNeeded()
    }

    static func translateSelection(_ selection: NSRange, from old: MarkdownComposition?, to new: MarkdownComposition) -> NSRange {
        func translate(_ offset: Int) -> Int {
            guard let old, let anchor = old.anchors.filter({ $0.rendered.location <= offset && $0.rendered.upperBound >= offset }).min(by: { $0.rendered.length < $1.rendered.length }),
                  let match = new.anchors.min(by: { abs($0.source.location - anchor.source.location) < abs($1.source.location - anchor.source.location) }) else {
                return min(offset, new.text.length)
            }
            return min(match.rendered.upperBound, match.rendered.location + offset - anchor.rendered.location)
        }
        let start = max(0, translate(selection.location)), end = max(start, translate(selection.upperBound))
        let range = NSRange(location: start, length: min(new.text.length, end) - start)
        guard range.length > 0 else {
            if start > 0, start < new.text.length {
                let composed = new.text.rangeOfComposedCharacterSequence(at: start)
                return NSRange(location: composed.location, length: 0)
            }
            return range
        }
        return new.text.rangeOfComposedCharacterSequences(for: range)
    }
    func focusIfNeeded() {
        guard let focusDocumentID, appliedSnapshot?.documentID == focusDocumentID, !isRendering, requested == appliedSnapshot else { return }
        // Match the editor: let SwiftUI finish mounting and updating its focus state.
        Task { @MainActor [weak self] in
            guard let self, self.focusDocumentID == focusDocumentID, appliedSnapshot?.documentID == focusDocumentID,
                  !isRendering, let window = textView.window else { return }
            if window.makeFirstResponder(textView) {
                self.focusDocumentID = nil
                self.placeCaretAfterNewNoteTitle()
            }
        }
    }

    /// A note still holding just the new-note template opens ready to type over its title,
    /// the same as the source editor does. The caret goes at the end of the first line of
    /// what the text view actually holds. That is the source text today, markers included
    /// and merely shrunk out of sight, but reading the line back keeps this correct if the
    /// preview ever stops carrying them.
    private func placeCaretAfterNewNoteTitle() {
        guard appliedSnapshot?.text == NoteTitle.template else { return }
        let rendered = textView.string as NSString
        let firstBreak = rendered.range(of: "\n")
        textView.setSelectedRange(NSRange(
            location: firstBreak.location == NSNotFound ? rendered.length : firstBreak.location,
            length: 0
        ))
    }
    func navigateHeading(_ heading: String) {
        guard let anchor = composition?.anchors.first(where: { $0.heading == heading }) else {
            message = "Heading not found: \(heading)"; return
        }
        scroll(to: anchor.rendered.location, fraction: 0)
        scrollSync?.synchronize(from: .preview)
    }
    func followLink(_ target: String) {
        guard let snapshot = appliedSnapshot, requested == snapshot, isCurrent(snapshot) else {
            message = "Wait for the preview to finish updating before following this link."; return
        }
        do {
            switch try PreviewResources.destination(target, base: snapshot.url, root: snapshot.root) {
            case let .heading(heading): navigateHeading(heading)
            case let .external(url): openExternal(url)
            case let .local(url, fragment):
                guard FileManager.default.fileExists(atPath: url.path) else { throw PreviewFailure.message("Linked file not found") }
                if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                    guard openNote?(url, fragment) == true else { throw PreviewFailure.message("The linked note is not in the library catalog. Refresh the library and retry.") }
                }
                else { revealFile(url) }
            }
        } catch { message = error.localizedDescription }
    }
}

struct MarkdownPreviewView: NSViewRepresentable {
    @AppStorage(PreviewSettings.autoClosePairsKey) private var autoClosePairs = true
    @AppStorage(PreviewSettings.allowsEditingKey) private var allowsEditing = true
    @AppStorage(PreviewSettings.showsMarkdownMarkersKey) private var showsMarkdownMarkers = false
    @AppStorage(PreviewSettings.bodySizeKey) private var bodySize = PreviewTheme.defaultBodySize
    @AppStorage(PreviewSettings.marginKey) private var margin = PreviewTheme.defaultMargin
    @AppStorage(PreviewSettings.verticalMarginKey) private var verticalMargin = PreviewTheme.defaultVerticalMargin
    @AppStorage(PreviewSettings.fontNameKey) private var fontName = ""
    @AppStorage(PreviewSettings.fontFamilyKey) private var fontFamily = ""
    @AppStorage(PreviewSettings.lineHeightKey) private var lineHeight = PreviewTheme.defaultLineHeight
    let session: MarkdownPreviewSession
    let snapshot: PreviewSnapshot
    let document: NoteDocument
    var split = false

    func makeNSView(context: Context) -> PreviewContainerView { PreviewContainerView() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PreviewContainerView, context: Context) -> CGSize? { proposal.replacingUnspecifiedDimensions() }
    func updateNSView(_ container: PreviewContainerView, context: Context) {
        // An outgoing representable can update after its replacement has taken the scroll view.
        guard container.session !== session || session.scrollView.superview === container else { return }
        container.session = session
        let scroll = session.scrollView
        if scroll.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            scroll.removeFromSuperview(); scroll.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: container.topAnchor), scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        var snapshot = snapshot
        snapshot.scale = Double(container.window?.backingScaleFactor ?? 2)
        snapshot.settings = PreviewSettings(autoClosePairs: autoClosePairs, allowsEditing: allowsEditing, showsMarkdownMarkers: showsMarkdownMarkers)
        snapshot.theme = PreviewTheme(bodySize: bodySize, margin: margin, verticalMargin: verticalMargin,
                                      fontName: fontName, fontFamily: fontFamily, lineHeight: lineHeight)
        session.show(snapshot, document: document)
        if split, session.scrollSync?.editor !== document.editor {
            session.scrollSync?.disconnect()
            session.scrollSync = MarkdownScrollSync(editor: document.editor, preview: session)
            session.scrollSync?.connect()
        } else if !split { session.scrollSync?.disconnect(); session.scrollSync = nil }
        session.focusIfNeeded()
    }
    static func dismantleNSView(_ nsView: PreviewContainerView, coordinator: ()) {
        // SwiftUI can mount the replacement before dismantling the old representable.
        if nsView.session?.scrollView.superview === nsView { nsView.session?.hide() }
        nsView.session = nil
    }
}

final class PreviewContainerView: NSView {
    weak var session: MarkdownPreviewSession?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); session?.focusIfNeeded() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); session?.retry() }
}
