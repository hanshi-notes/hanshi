import AppKit
import SwiftUI
import STTextView

final class MarkdownEditorSession: STTextViewDelegate {
    let scrollView: NSScrollView
    let textView: STTextView
    private weak var document: NoteDocument?
    private var needsFocus = false
    private var ligatures = true
    private let syntax = MarkdownSyntaxPlugin.Handle()
    private var theme = SyntaxTheme.saved

    init(document: NoteDocument) {
        self.document = document
        scrollView = STTextView.scrollableTextView()
        // STTextView's factory always installs an STTextView as its document view.
        textView = scrollView.documentView as! STTextView
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
        textView.showsLineNumbers = true
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
    }

    func textViewDidChangeText(_ notification: Notification) {
        document?.edit(textView.text ?? "")
    }

    func setFont(name: String = "", family: String = "", size: Double) {
        let font = EditorFont.resolve(name: name, family: family, size: size)
        guard textView.font != font else { return }
        textView.font = font
        textView.gutterView?.font = .monospacedSystemFont(ofSize: max(11, font.pointSize - 3), weight: .regular)
    }

    func setSyntaxTheme(_ theme: SyntaxTheme) {
        guard self.theme != theme else { return }
        self.theme = theme
        textView.backgroundColor = theme.background ?? .textBackgroundColor
        syntax.coordinator?.setTheme(theme)
    }

    func setTypography(lineHeight: Double, ligatures: Bool) {
        let lineHeight = EditorFont.clampedLineHeight(lineHeight)
        guard textView.defaultParagraphStyle.lineHeightMultiple != lineHeight || self.ligatures != ligatures else { return }
        self.ligatures = ligatures
        let paragraph = textView.defaultParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
        paragraph.lineHeightMultiple = lineHeight
        textView.defaultParagraphStyle = paragraph
        applyWritingAttributes()
    }

    private func applyWritingAttributes() {
        let attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: textView.defaultParagraphStyle, .ligature: ligatures ? 1 : 0
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

    var body: some View {
        EditorRepresentable(session: document.editor, text: document.text, name: name, family: family,
                            size: size, lineHeight: lineHeight, ligatures: ligatures,
                            theme: SyntaxTheme(rawValue: theme) ?? .system)
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
        session.setTypography(lineHeight: lineHeight, ligatures: ligatures)
        session.setSyntaxTheme(theme)
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
