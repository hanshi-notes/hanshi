import AppKit
import SwiftUI
import STTextView

final class MarkdownEditorSession: STTextViewDelegate {
    // SwiftPM's command-line build does not compile the plugin's color asset catalog.
    // Native colors also adapt to the editor's appearance without that resource dependency.
    static let colors: [String: NSColor] = [
        "plain": .textColor, "text.title": .systemBlue, "text.literal": .systemBrown,
        "text.uri": .systemBlue, "text.reference": .systemBlue,
        "text.emphasis": .systemPurple, "text.strong": .systemPurple,
        "keyword": .systemPurple, "keyword.function": .systemPurple, "keyword.return": .systemPurple,
        "include": .systemPurple, "boolean": .systemPurple,
        "string": .systemRed, "string.escape": .systemOrange,
        "comment": .secondaryLabelColor, "number": .systemOrange,
        "type": .systemTeal, "constructor": .systemTeal,
        "function.call": .systemBlue, "method": .systemBlue,
        "variable": .textColor, "variable.builtin": .systemTeal,
        "parameter": .systemBrown, "operator": .systemPurple,
        "punctuation.special": .systemBlue, "punctuation.delimiter": .secondaryLabelColor
    ]
    let scrollView: NSScrollView
    let textView: STTextView
    private weak var document: NoteDocument?
    private var needsFocus = false

    init(document: NoteDocument) {
        self.document = document
        scrollView = STTextView.scrollableTextView()
        // STTextView's factory always installs an STTextView as its document view.
        textView = scrollView.documentView as! STTextView
        scrollView.contentView = EditorClipView()
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = textView
        textView.text = document.text
        textView.isHorizontallyResizable = false
        textView.highlightSelectedLine = true
        textView.showsLineNumbers = true
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.setAccessibilityLabel("Markdown editor")
        textView.addPlugin(MarkdownSyntaxPlugin())
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.gutterView?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textDelegate = self
    }

    func textViewDidChangeText(_ notification: Notification) {
        document?.edit(textView.text ?? "")
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

    var body: some View {
        EditorRepresentable(session: document.editor, text: document.text)
    }
}

private struct EditorRepresentable: NSViewRepresentable {
    let session: MarkdownEditorSession
    let text: String

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
