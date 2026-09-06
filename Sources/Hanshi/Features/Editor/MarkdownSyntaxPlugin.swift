import AppKit
import STTextView
import STPluginTreeSitterCore
import TreeSitterResource
import SwiftTreeSitter
import SwiftTreeSitterLayer

// Uses the upstream parser and incremental service with a color-only TextKit adapter.
// Upstream's adapter applies broad tokens after nested tokens and mutates fonts while coloring.
struct MarkdownSyntaxPlugin: STPlugin {
    func makeCoordinator(context: CoordinatorContext) -> Coordinator {
        Coordinator(textView: context.textView)
    }

    func setUp(context: any Context) {
        context.events.onWillChangeText { range, replacement in
            let view = context.textView
            let start = view.textContentManager.offset(from: view.textContentManager.documentRange.location, to: range.location)
            let length = view.textContentManager.offset(from: range.location, to: range.endLocation)
            context.coordinator.pendingEdit = replacement.map {
                PendingTextEdit(oldText: view.text ?? "", oldRange: NSRange(location: start, length: length), replacementText: $0)
            }
        }
        context.events.onDidChangeText { _, _ in
            context.coordinator.highlight(context.textView.text ?? "")
        }
    }

    final class Coordinator {
        var pendingEdit: PendingTextEdit?
        private let service: SyntaxHighlightService?
        private let colors: ColorApplier
        private var work: Task<Void, Never>?

        init(textView: STTextView) {
            let colors = ColorApplier(textView: textView)
            self.colors = colors
            if let configuration = SyntaxResources.configuration(for: .markdown),
               let client = try? TreeSitterClient(languageConfiguration: configuration,
                                                  languageProvider: SyntaxResources.languageProvider(named:)) {
                service = SyntaxHighlightService(treeSitterClient: client) { update in
                    await colors.apply(update)
                }
            } else { service = nil }
            highlight(textView.text ?? "")
        }

        func highlight(_ text: String) {
            let edit = pendingEdit
            pendingEdit = nil
            let previous = work
            work = Task {
                await previous?.value
                colors.source = text
                if let edit, edit.newLength == text.utf16.count {
                    await service?.requestHighlighting(content: text, edit: edit)
                } else {
                    await service?.requestInitialHighlighting(text)
                }
            }
        }
    }

    private final class ColorApplier {
        private weak var textView: STTextView?
        private var generation = 0
        var source = ""
        private var needsFullRepaint = true

        init(textView: STTextView) { self.textView = textView }

        func apply(_ update: HighlightUpdate) {
            guard let textView, update.generation >= generation else { return }
            generation = update.generation
            guard textView.text == source else {
                needsFullRepaint = true
                return
            }
            let length = source.utf16.count
            let invalidated = needsFullRepaint ? [NSRange(location: 0, length: length)]
                : normalizedRanges(update.invalidatedRanges, maxLength: length)
            needsFullRepaint = false
            for range in invalidated { textView.removeRenderingAttribute(.foregroundColor, range: range) }
            let tokens = update.tokens.sorted {
                $0.range.location == $1.range.location
                    ? $0.range.length > $1.range.length
                    : $0.range.location < $1.range.location
            }
            for token in tokens where token.range.length > 0 && NSMaxRange(token.range) <= length {
                guard invalidated.contains(where: { rangesOverlap($0, token.range) }) else { continue }
                let color = token.name == "none" ? NSColor.textColor
                    : MarkdownEditorSession.colors[token.name]
                if let color { textView.addRenderingAttributes([.foregroundColor: color], range: token.range) }
            }
        }
    }
}

nonisolated enum SyntaxResources {
    static func languageProvider(named name: String) -> LanguageConfiguration? {
        TreeSitterLanguage.injectedLanguage(named: name).flatMap { configuration(for: $0) }
    }

    static func configuration(for language: TreeSitterLanguage,
                              resources: URL? = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.resourceURL : nil) -> LanguageConfiguration? {
        guard let resources else { return language.configuration }
        // SwiftPM's generated accessors expect bundles at the .app root, which codesign rejects.
        let directory = resources.appendingPathComponent("Syntax")
            .appendingPathComponent(language.name.replacingOccurrences(of: "_", with: ""))
        guard FileManager.default.isReadableFile(atPath: directory.appendingPathComponent("highlights.scm").path) else { return nil }
        return try? LanguageConfiguration(Language(language.parser), name: language.name, queriesURL: directory)
    }
}
