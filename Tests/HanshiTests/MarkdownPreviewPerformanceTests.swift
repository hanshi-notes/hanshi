import AppKit
import Testing
@testable import Hanshi

@Test @MainActor func previewCorpusRendersAtTenHundredAndThousandKilobytes() async throws {
    let unit = """
    ## Heading 😀

    A paragraph with **bold**, *emphasis*, [a link](https://example.com), and Unicode 漢字.

    - First item
    - [x] Completed

    ```swift
    let message = "Hello 😀"
    print(message)
    ```

    | Item | Value |
    | :--- | ---: |
    | Tea | 2 |


    """
    for size in [10_000, 100_000, 1_000_000] {
        let text = String(repeating: unit, count: max(1, size / unit.utf8.count))
        let snapshot = PreviewTestFixtures.snapshot(text)
        let clock = ContinuousClock()
        let parseStart = clock.now
        let recipe = try await MarkdownRenderer.render(snapshot)
        let parseTime = parseStart.duration(to: clock.now)
        let composeStart = clock.now
        let composition = try await MarkdownRenderer.compose(recipe, theme: PreviewTheme())
        let composeTime = composeStart.duration(to: clock.now)
        #expect(composition.text.string.contains("Tea\n2"))
        #expect(composition.anchors.allSatisfy { $0.rendered.upperBound <= composition.text.length })
        #expect(composition.text.length > 0)
        print("PREVIEW_BENCH bytes=\(text.utf8.count) runs=\(recipe.runs.count) anchors=\(recipe.anchors.count) parse_highlight=\(parseTime) compose=\(composeTime) longest_batch=\(composition.longestBatch) main_thread_text=\(composition.composedOnMainThread) font_builds=\(composition.fontBuildCount)")
    }
}

@Test @MainActor func previewEditorScrollTextValidationBenchmark() {
    let source = String(repeating: "Text 😀 漢字.\n", count: 1_000_000 / 18)
    let document = PreviewTestFixtures.document(source)
    let editor = document.editor
    var matches = 0
    let elapsed = ContinuousClock().measure {
        for _ in 0..<20 {
            if editor.displayedText == source { matches += 1 }
        }
    }
    #expect(matches == 20)
    print("PREVIEW_SCROLL_TEXT bytes=\(source.utf8.count) comparisons=20 elapsed=\(elapsed)")
}

extension AppKitWindowTests {
    @Test @MainActor func previewHundredKilobyteUpdatesIncludeApplicationAndLayout() async throws {
        _ = NSApplication.shared
        let unit = "## Heading\n\nA paragraph with **bold**, [link](https://example.com), Unicode 😀 and normal words.\n\n```swift\nlet number = 42\n```\n\n| A | B |\n|---|---|\n| One | Two |\n\n"
        let text = String(repeating: unit, count: 100_000 / unit.utf8.count)
        let session = MarkdownPreviewSession(debounce: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = session.scrollView; window.orderFront(nil)
        defer { session.hide(); window.contentView = nil; window.close() }
        let identity = UUID()
        var durations: [Double] = []
        let clock = ContinuousClock()
        for index in 0..<6 {
            let snapshot = PreviewSnapshot(library: identity, documentID: "bench", text: text + "Edit \(index)", url: URL(filePath: "/unused/Note.md"), root: URL(filePath: "/unused"))
            let start = clock.now
            session.show(snapshot); await session.waitForRendering()
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let duration = start.duration(to: clock.now).components
            durations.append(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
            #expect(session.textView.string.hasSuffix("Edit \(index)"))
        }
        let warm = durations.dropFirst().sorted()
        print("PREVIEW_UPDATE bytes=\(text.utf8.count) cold=\(durations[0]) warm_p95=\(warm.last!) warm_median=\(warm[warm.count / 2]) samples=\(durations)")
    }
}
