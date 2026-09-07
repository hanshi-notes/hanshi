import AppKit
import SwiftUI
import STTextView

// STTextView always inserts a tab character; Settings can ask for spaces instead.
final class MarkdownTextView: STTextView {
    var indentsWithTabs = false
    var indentWidth = EditorFont.defaultTabWidth

    override func insertTab(_ sender: Any?) {
        guard !indentsWithTabs else { return super.insertTab(sender) }
        insertText(String(repeating: " ", count: indentWidth), replacementRange: .notFound)
    }
}

final class MarkdownEditorSession: STTextViewDelegate {
    let scrollView: NSScrollView
    let textView: MarkdownTextView
    private weak var document: NoteDocument?
    private var needsFocus = false
    private var ligatures = true
    private var lineHeight = 1.0
    private var letterSpacing = 1.0
    private var tabWidth = EditorFont.tabWidth
    private let syntax = MarkdownSyntaxPlugin.Handle()
    private var theme = SyntaxTheme.saved

    init(document: NoteDocument) {
        self.document = document
        scrollView = MarkdownTextView.scrollableTextView()
        // STTextView's factory always installs its own class as the document view.
        textView = scrollView.documentView as! MarkdownTextView
        // The text always wraps, so there is nothing to scroll sideways.
        scrollView.hasHorizontalScroller = false
        scrollView.contentView = EditorClipView()
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = textView
        textView.text = document.text
        // A note still holding just the new-note template opens ready to type over its title.
        if document.text == NoteTitle.template {
            textView.textSelection = NSRange(location: NoteTitle.template.utf16.count - 1, length: 0)
        }
        textView.isHorizontallyResizable = false
        textView.highlightSelectedLine = true
        textView.showsLineNumbers = EditorFont.showsGutter
        textView.showsInvisibleCharacters = EditorFont.showsInvisibles
        textView.indentsWithTabs = EditorFont.indentsWithTabs
        textView.indentWidth = tabWidth
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.setAccessibilityLabel("Markdown editor")
        textView.backgroundColor = theme.background ?? .textBackgroundColor
        textView.addPlugin(MarkdownSyntaxPlugin(theme: theme, handle: syntax))
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.gutterView?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textDelegate = self
        // Give the tab its width now: nothing else applies it until a setting changes.
        applyParagraphStyle()
    }

    func textViewDidChangeText(_ notification: Notification) {
        document?.edit(textView.text ?? "")
    }

    func setFont(name: String = "", family: String = "", size: Double) {
        let font = EditorFont.resolve(name: name, family: family, size: size)
        guard textView.font != font else { return }
        textView.font = font
        setGutterFont()
        // A tab is measured in spaces of the editor's font, so it moves with the font.
        applyParagraphStyle()
    }

    func setGutter(_ visible: Bool) {
        guard textView.showsLineNumbers != visible else { return }
        textView.showsLineNumbers = visible
        setGutterFont()
    }

    func setIndentation(width: Int, usesTabs: Bool) {
        textView.indentsWithTabs = usesTabs
        textView.indentWidth = width
        guard tabWidth != width else { return }
        tabWidth = width
        applyParagraphStyle()
    }

    private func setGutterFont() {
        textView.gutterView?.font = .monospacedSystemFont(ofSize: max(11, textView.font.pointSize - 3), weight: .regular)
    }

    func setSyntaxTheme(_ theme: SyntaxTheme) {
        guard self.theme != theme else { return }
        self.theme = theme
        textView.backgroundColor = theme.background ?? .textBackgroundColor
        syntax.coordinator?.setTheme(theme)
    }

    func setTypography(lineHeight: Double, ligatures: Bool, letterSpacing: Double = 1) {
        let lineHeight = EditorFont.clampedLineHeight(lineHeight)
        let letterSpacing = EditorFont.clampedLetterSpacing(letterSpacing)
        guard self.lineHeight != lineHeight || self.ligatures != ligatures
                || self.letterSpacing != letterSpacing else { return }
        self.lineHeight = lineHeight
        self.ligatures = ligatures
        self.letterSpacing = letterSpacing
        applyParagraphStyle()
    }

    func setInvisibles(_ visible: Bool) {
        guard textView.showsInvisibleCharacters != visible else { return }
        textView.showsInvisibleCharacters = visible
    }

    private func applyParagraphStyle() {
        let paragraph = textView.defaultParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
        paragraph.lineHeightMultiple = lineHeight
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: textView.font]).width * Double(tabWidth)
        paragraph.tabStops = []
        textView.defaultParagraphStyle = paragraph
        applyWritingAttributes()
    }

    private func applyWritingAttributes() {
        // Letter spacing is a multiple of the font's own space, so it holds across font sizes.
        let kern = (letterSpacing - 1) * (" " as NSString).size(withAttributes: [.font: textView.font]).width
        let attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: textView.defaultParagraphStyle, .ligature: ligatures ? 1 : 0, .kern: kern
        ]
        textView.addAttributes(attributes, range: NSRange(location: 0, length: (textView.text ?? "").utf16.count))
        textView.typingAttributes.merge(attributes) { _, new in new }
    }

    func textView(_ textView: STTextView, shouldChangeTextIn affectedCharRange: NSTextRange, replacementString: String?) -> Bool {
        // Selection commands reset typing attributes after notifying the delegate, so restore them just before insertion.
        textView.typingAttributes[.ligature] = ligatures ? 1 : 0
        return true
    }

    func requestFocus() {
        needsFocus = true
        focusIfNeeded()
    }

    fileprivate func focusIfNeeded() {
        guard needsFocus, textView.window != nil else { return }
        // Wait until SwiftUI finishes mounting the selected note and updating search focus.
        Task { @MainActor [weak self] in
            guard let self, needsFocus, let window = textView.window else { return }
            needsFocus = !window.makeFirstResponder(textView)
        }
    }

    func synchronize(_ text: String) {
        guard document?.text == text, textView.text != text else { return }
        let selection = textView.textSelection
        textView.text = text
        applyWritingAttributes()
        textView.undoManager?.removeAllActions()
        textView.textSelection = NSRange(location: min(selection.location, text.utf16.count), length: 0)
    }
}

private final class EditorClipView: NSClipView {
    override func mouseDown(with event: NSEvent) {
        // Text and gutter views handle their own clicks; this receives the unused viewport.
        guard let editor = documentView as? STTextView else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(editor)
        editor.moveToEndOfDocument(nil)
    }
}

struct MarkdownEditorView: View {
    let document: NoteDocument
    @AppStorage(EditorFont.familyKey) private var family = ""
    @AppStorage(EditorFont.sizeKey) private var size = EditorFont.defaultSize
    @AppStorage(EditorFont.nameKey) private var name = ""
    @AppStorage(EditorFont.lineHeightKey) private var lineHeight = 1.0
    @AppStorage(EditorFont.ligaturesKey) private var ligatures = true
    @AppStorage(SyntaxTheme.key) private var theme = SyntaxTheme.system.rawValue
    @AppStorage(EditorFont.gutterKey) private var showsGutter = true
    @AppStorage(EditorFont.tabWidthKey) private var tabWidth = EditorFont.defaultTabWidth
    @AppStorage(EditorFont.indentsWithTabsKey) private var indentsWithTabs = false
    @AppStorage(EditorFont.letterSpacingKey) private var letterSpacing = 1.0
    @AppStorage(EditorFont.invisiblesKey) private var showsInvisibles = false

    var body: some View {
        EditorRepresentable(session: document.editor, text: document.text, name: name, family: family,
                            size: size, lineHeight: lineHeight, ligatures: ligatures,
                            theme: SyntaxTheme(rawValue: theme) ?? .system, showsGutter: showsGutter,
                            tabWidth: EditorFont.clampedTabWidth(tabWidth), indentsWithTabs: indentsWithTabs,
                            letterSpacing: letterSpacing, showsInvisibles: showsInvisibles)
    }
}

private struct EditorRepresentable: NSViewRepresentable {
    let session: MarkdownEditorSession
    let text: String
    let name: String
    let family: String
    let size: Double
    let lineHeight: Double
    let ligatures: Bool
    let theme: SyntaxTheme
    let showsGutter: Bool
    let tabWidth: Int
    let indentsWithTabs: Bool
    let letterSpacing: Double
    let showsInvisibles: Bool

    func makeNSView(context: Context) -> EditorContainerView {
        EditorContainerView()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorContainerView, context: Context) -> CGSize? {
        // Let SwiftUI size the viewport; inferring it from AppKit causes a split-view layout loop.
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        container.session = session
        session.synchronize(text)
        session.setFont(name: name, family: family, size: size)
        session.setTypography(lineHeight: lineHeight, ligatures: ligatures, letterSpacing: letterSpacing)
        session.setSyntaxTheme(theme)
        session.setGutter(showsGutter)
        session.setIndentation(width: tabWidth, usesTabs: indentsWithTabs)
        session.setInvisibles(showsInvisibles)
        let scrollView = session.scrollView
        guard scrollView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        scrollView.removeFromSuperview()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        session.focusIfNeeded()
    }
}

private final class EditorContainerView: NSView {
    var session: MarkdownEditorSession?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        session?.focusIfNeeded()
    }
}
