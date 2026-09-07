import AppKit
import SwiftUI
import Observation

@Observable final class MarkdownPreviewSession: NSObject, NSTextViewDelegate {
    let scrollView: NSScrollView
    let textView: PreviewTextView
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
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        textView = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), textContainer: container)
        scrollView = PreviewScrollView(frame: .zero)
        super.init()
        textView.delegate = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.backgroundColor = .white
        textView.setAccessibilityLabel("Markdown preview")
        scrollView.contentView = PreviewClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        textView.onResize = { [weak self] in self?.resizeAttachments() }
    }

    func show(_ snapshot: PreviewSnapshot, document: NoteDocument? = nil) {
        self.document = document
        guard requested != snapshot else { return }
        let previous = requested
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
        let result = try await MarkdownRenderer.compose(recipe, theme: snapshot.theme)
        try Task.checkCancellation()
        guard token == requestToken, requested == snapshot, isCurrent(snapshot) else { return }
        let selection = textView.selectedRange()
        let oldAnchor = readingPosition()
        let oldComposition = composition
        self.recipe = recipe
        self.composition = result
        appliedSnapshot = snapshot
        message = recipe.diagnostics.isEmpty ? nil : Array(Set(recipe.diagnostics)).sorted().joined(separator: " · ")
        textView.textContainerInset = NSSize(width: snapshot.theme.margin, height: snapshot.theme.margin)
        textView.textStorage?.beginEditing()
        textView.textStorage?.setAttributedString(result.text)
        textView.textStorage?.endEditing()
        let translated = Self.translateSelection(selection, from: oldComposition, to: result)
        textView.setSelectedRange(translated)
        resizeAttachments()
        textView.layoutManager?.ensureLayout(forBoundingRect: textView.visibleRect, in: textView.textContainer!)
        if let oldAnchor { restore(position: oldAnchor) }
        else { MarkdownScrollSync.scroll(scrollView, to: 0) }
        scrollSync?.contentDidChange()
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
                let composed = (new.text.string as NSString).rangeOfComposedCharacterSequence(at: start)
                return NSRange(location: composed.location, length: 0)
            }
            return range
        }
        return (new.text.string as NSString).rangeOfComposedCharacterSequences(for: range)
    }
    func resizeAttachments() {
        guard let composition else { return }
        let width = textView.bounds.width - 2 * textView.textContainerInset.width
        for attachment in composition.attachments { attachment.resize(width: width) }
        guard !composition.attachments.isEmpty else { return }
        for range in composition.attachmentRanges {
            textView.layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
        textView.needsDisplay = true
    }
    func focusIfNeeded() {
        guard let focusDocumentID, appliedSnapshot?.documentID == focusDocumentID, !isRendering, requested == appliedSnapshot else { return }
        // Match the editor: let SwiftUI finish mounting and updating its focus state.
        Task { @MainActor [weak self] in
            guard let self, self.focusDocumentID == focusDocumentID, appliedSnapshot?.documentID == focusDocumentID,
                  !isRendering, let window = textView.window else { return }
            if window.makeFirstResponder(textView) { self.focusDocumentID = nil }
        }
    }
    func navigateHeading(_ heading: String) {
        guard let anchor = composition?.anchors.first(where: { $0.heading == heading }) else {
            message = "Heading not found: \(heading)"; return
        }
        scroll(to: anchor.rendered.location, fraction: 0)
        scrollSync?.synchronize(from: .preview)
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        followLink((link as? URL)?.absoluteString ?? (link as? String ?? ""))
        return true
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

final class PreviewTextView: NSTextView {
    var onResize: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage else { return false }
        let selected = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: selectedRange()))
        var alternatives: [(NSRange, String)] = []
        selected.enumerateAttribute(.previewAlternative, in: NSRange(location: 0, length: selected.length)) { value, range, _ in
            if let alternative = value as? String { alternatives.append((range, alternative)) }
        }
        for (range, alternative) in alternatives.reversed() { selected.replaceCharacters(in: range, with: alternative) }
        pboard.clearContents()
        pboard.setString(selected.string, forType: .string)
        if let rtf = try? selected.data(from: NSRange(location: 0, length: selected.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pboard.setData(rtf, forType: .rtf)
        }
        return true
    }
}

struct MarkdownPreviewView: NSViewRepresentable {
    let session: MarkdownPreviewSession
    let snapshot: PreviewSnapshot
    let document: NoteDocument
    var split = false

    func makeNSView(context: Context) -> PreviewContainerView { PreviewContainerView() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PreviewContainerView, context: Context) -> CGSize? { proposal.replacingUnspecifiedDimensions() }
    func updateNSView(_ container: PreviewContainerView, context: Context) {
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


private final class PreviewScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let view = documentView as? NSTextView else { return }
        view.minSize = NSSize(width: 0, height: contentView.bounds.height)
        if abs(view.frame.width - contentView.bounds.width) > 0.5 {
            view.setFrameSize(NSSize(width: contentView.bounds.width, height: max(view.frame.height, contentView.bounds.height)))
        }
    }
}

private final class PreviewClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin.x = 0
        return bounds
    }
}
