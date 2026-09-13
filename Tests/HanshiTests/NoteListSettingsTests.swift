import AppKit
import SwiftUI
import Testing
@testable import Hanshi

extension AppKitWindowTests {
    @Test(arguments: ["Draft.md", "Version.1.MD", "Notas 日本語.md"]) @MainActor
    func fileExtensionSettingUpdatesNoteRowsAndPersists(filename: String) async throws {
        _ = NSApplication.shared
        let preferences = TestPreferences(); defer { preferences.remove() }
        let note = Note(id: "note", url: URL(filePath: "/library/Notes/\(filename)"))
        let settings = NSHostingView(rootView: GeneralSettingsView().defaultAppStorage(preferences.defaults))
        let row = NSHostingView(rootView: NoteRowView(note: note, selected: false).defaultAppStorage(preferences.defaults))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 480))
        settings.frame = NSRect(x: 0, y: 40, width: 520, height: 440)
        row.frame = NSRect(x: 0, y: 0, width: 520, height: 32)
        host.addSubview(settings); host.addSubview(row)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
        func checkbox(in view: NSView) -> NSButton? {
            if let button = view as? NSButton { return button }
            return view.subviews.lazy.compactMap { checkbox(in: $0) }.first
        }
        func pixels() throws -> Data {
            row.layoutSubtreeIfNeeded()
            let bitmap = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
            row.cacheDisplay(in: row.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let toggle = try #require(checkbox(in: settings))
        #expect(toggle.state == .on)
        let hiddenPixels = try pixels()
        for hidden in [false, true, false] {
            let location = toggle.convert(NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while try (pixels() == hiddenPixels) != hidden, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try (pixels() == hiddenPixels) == hidden, "The displayed filename must follow the checkbox")
            #expect(toggle.state == (hidden ? .on : .off))
            let reopened = try #require(UserDefaults(suiteName: preferences.suite))
            #expect(reopened.object(forKey: Note.hidesExtensionKey) as? Bool == hidden)
        }
    }
}
