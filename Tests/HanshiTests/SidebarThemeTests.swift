import AppKit
import SwiftUI
import Testing
@testable import Hanshi

extension AppKitWindowTests {
    @Test(arguments: ["", "unknown-theme"]) @MainActor
    func sidebarColorSettingUpdatesTheOpenLibraryAndPersists(saved: String) async throws {
        _ = NSApplication.shared
        let preferences = TestPreferences(); defer { preferences.remove() }
        if !saved.isEmpty { preferences.defaults.set(saved, forKey: SidebarTheme.key) }
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        let store = NoteStore(root: fixture.root)
        await store.refresh()
        let library = NSHostingView(rootView: LibraryScreen(defaults: preferences.defaults).environment(store))
        let settings = NSHostingView(rootView: EditorSettingsView().defaultAppStorage(preferences.defaults))
        let libraryWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 650),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        for window in [libraryWindow, settingsWindow] { window.isReleasedWhenClosed = false }
        libraryWindow.contentView = library; libraryWindow.orderFront(nil)
        settingsWindow.contentView = settings; settingsWindow.orderFront(nil)
        defer {
            for window in [libraryWindow, settingsWindow] { window.contentView = nil; window.close() }
        }
        library.layoutSubtreeIfNeeded(); settings.layoutSubtreeIfNeeded()
        func picker(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl, control.label(forSegment: 0) == "Default" { return control }
            return view.subviews.lazy.compactMap { picker(in: $0) }.first
        }
        let control = try #require(picker(in: settings))
        #expect((0..<control.segmentCount).compactMap { control.label(forSegment: $0) } == ["Default", "Dark", "Light"])
        #expect(control.selectedSegment == 0)

        func snapshot() throws -> NSBitmapImageRep {
            library.layoutSubtreeIfNeeded()
            let rect = NSRect(x: 0, y: 0, width: 130, height: 230)
            let bitmap = try #require(library.bitmapImageRepForCachingDisplay(in: rect))
            library.cacheDisplay(in: rect, to: bitmap)
            return bitmap
        }
        func rgb(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> [Double] {
            let scale = bitmap.pixelsWide / 130
            let color = try #require(bitmap.colorAt(x: x * scale, y: y * scale))
            return [color.redComponent, color.greenComponent, color.blueComponent].map { Double($0) * 255 }
        }
        func matches(_ actual: [Double], _ expected: [Double]) -> Bool {
            zip(actual, expected).allSatisfy { abs($0 - $1) < 2 }
        }
        let initial = try rgb(snapshot(), x: 5, y: 200)
        #expect(matches(initial, [30.6, 40.8, 45.9]), "Default background: \(initial)")

        for (index, background) in [(1, [49.0, 54, 64]), (2, [236.0, 236, 236]), (0, [30.6, 40.8, 45.9])] {
            control.selectedSegment = index
            control.sendAction(control.action, to: control.target)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while try !matches(rgb(snapshot(), x: 5, y: 200), background), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let bitmap = try snapshot()
            let actual = try rgb(bitmap, x: 5, y: 200)
            #expect(matches(actual, background), "Background: \(actual), expected \(background)")
            let text = try (40..<100).flatMap { x in
                try (43..<64).map { y in try rgb(bitmap, x: x, y: y)[0] }
            }
            if index == 2 {
                #expect(try #require(text.min()) < 50, "Light sidebar text must be dark")
                #expect(try rgb(bitmap, x: 5, y: 54)[0] < background[0] - 10,
                        "The selected row must remain visible on the light background")
            } else {
                #expect(try #require(text.max()) > 240, "Dark sidebar text must remain white")
            }
            let reopenedDefaults = try #require(UserDefaults(suiteName: preferences.suite))
            #expect(reopenedDefaults.string(forKey: SidebarTheme.key) == control.label(forSegment: index))
        }
    }
}
