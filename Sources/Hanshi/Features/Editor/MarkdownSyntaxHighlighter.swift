import AppKit
import EditorSyntax
import SwiftTreeSitter
import SwiftTreeSitterLayer

final class MarkdownSyntaxHighlighter {
    var pendingEdit: PendingTextEdit?
    private let service: SyntaxHighlightService?
    private let colors: ColorApplier
    private var work: Task<Void, Never>?
    private var requestID = 0
    private weak var textView: NSTextView?

    init(textView: NSTextView, theme: SyntaxTheme) {
        self.textView = textView
        let colors = ColorApplier(textView: textView, theme: theme)
        self.colors = colors
        if let configuration = SyntaxResources.configuration(for: .markdown),
           let client = try? TreeSitterClient(languageConfiguration: configuration,
                                              languageProvider: SyntaxResources.languageProvider(named:)) {
            service = SyntaxHighlightService(treeSitterClient: client) { update in
                await colors.apply(update)
            }
        } else { service = nil }
        highlight(textView.string)
    }

    func waitForHighlighting() async { await work?.value }

    func setTheme(_ theme: SyntaxTheme) {
        guard colors.setTheme(theme) else { return }
        highlight(textView?.string ?? colors.source)
    }

    func highlight(_ text: String) {
        let edit = pendingEdit
        pendingEdit = nil
        requestID += 1
        let current = requestID
        let previous = work
        work = Task {
            await previous?.value
            guard current == requestID else { return }
            let incremental = edit.map { $0.oldText == colors.source && $0.newLength == text.utf16.count } ?? false
            colors.source = text
            if let edit, incremental {
                await service?.requestHighlighting(content: text, edit: edit)
            } else {
                await service?.requestInitialHighlighting(text)
            }
        }
    }

    private final class ColorApplier {
        private weak var textView: NSTextView?
        private var generation = 0
        var source = ""
        private var needsFullRepaint = true
        private var theme: SyntaxTheme
        private var colors: [String: NSColor]

        init(textView: NSTextView, theme: SyntaxTheme) {
            self.textView = textView
            self.theme = theme
            colors = theme.colors
        }

        /// False when the theme was already applied; a fresh highlight then repaints the document.
        func setTheme(_ theme: SyntaxTheme) -> Bool {
            guard self.theme != theme else { return false }
            self.theme = theme
            colors = theme.colors
            return true
        }

        func apply(_ update: HighlightUpdate) {
            guard let textView, update.generation >= generation else { return }
            generation = update.generation
            guard textView.string == source else {
                needsFullRepaint = true
                return
            }
            let length = source.utf16.count
            let invalidated = needsFullRepaint ? [NSRange(location: 0, length: length)]
                : normalizedRanges(update.invalidatedRanges, maxLength: length)
            needsFullRepaint = false
            for range in invalidated { textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range) }
            let tokens = update.tokens.sorted {
                if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
                if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
                return $0.name.count < $1.name.count
            }
            for token in tokens where token.range.length > 0 && NSMaxRange(token.range) <= length {
                guard invalidated.contains(where: { rangesOverlap($0, token.range) }) else { continue }
                let color = SyntaxTheme.color(for: token.name, in: colors)
                if let color { textView.layoutManager?.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range) }
            }
        }
    }
}

nonisolated enum SyntaxResources {
    static func languageProvider(named name: String) -> LanguageConfiguration? {
        TreeSitterLanguage.injectedLanguage(named: name).flatMap { configuration(for: $0) }
    }

    static func configuration(for language: TreeSitterLanguage,
                              resources: URL? = EditorResources.bundle.resourceURL) -> LanguageConfiguration? {
        guard let resources else { return nil }
        // Queries live in the same signed resource bundle as editor themes.
        let directory = resources.appendingPathComponent("Syntax")
            .appendingPathComponent(language.name.replacingOccurrences(of: "_", with: ""))
        guard FileManager.default.isReadableFile(atPath: directory.appendingPathComponent("highlights.scm").path) else { return nil }
        return try? LanguageConfiguration(Language(language.parser), name: language.name, queriesURL: directory)
    }
}
