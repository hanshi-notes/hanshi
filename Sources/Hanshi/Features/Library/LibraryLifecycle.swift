import AppKit
import SwiftUI

final class LibraryLifecycle: NSObject, NSApplicationDelegate {
    var store: NoteStore?
    private weak var window: NSWindow?
    private var windowDelegate: WindowDelegateProxy?
    private var isConfirmingClose = false

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        let proxy = WindowDelegateProxy(previous: window.delegate, lifecycle: self)
        windowDelegate = proxy
        window.delegate = proxy
        // AppKit lays the title bar out again when the window shows, resizes and leaves full screen.
        let windowNames = [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification]
        for name in windowNames + [NSView.frameDidChangeNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
        for name in windowNames {
            NotificationCenter.default.addObserver(self, selector: #selector(titlebarChanged), name: name, object: window)
        }
        if let close = window.standardWindowButton(.closeButton), let container = close.superview?.superview {
            for view in [close, container] {
                NotificationCenter.default.addObserver(self, selector: #selector(titlebarChanged),
                                                       name: NSView.frameDidChangeNotification, object: view)
            }
        }
        centreWindowButtons()
    }

    @objc private func titlebarChanged(_ notification: Notification) { centreWindowButtons() }

    /// Centres the close, minimize and zoom buttons in the bars, where a compact toolbar puts them.
    // ponytail: moves AppKit's private title bar views because a real toolbar swallows clicks on
    // the bars beneath it. Revisit if a macOS release stops honouring these frames.
    private func centreWindowButtons() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let miniaturize = window.standardWindowButton(.miniaturizeButton),
              let container = close.superview?.superview, let frame = container.superview else { return }
        let height = BarMetrics.height
        let titlebar = NSRect(x: container.frame.minX, y: frame.bounds.height - height, width: container.frame.width, height: height)
        if container.frame != titlebar { container.frame = titlebar }
        let margin = (height - close.frame.height) / 2
        let spacing = miniaturize.frame.minX - close.frame.minX
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            // AppKit sets them one point right of the top margin over a compact toolbar.
            let origin = NSPoint(x: margin + 1 + Double(index) * spacing, y: margin)
            if let button = window.standardWindowButton(kind), button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard store?.hasUnsavedChanges == true else {
            return true
        }
        guard !isConfirmingClose else { return false }
        isConfirmingClose = true
        Task {
            let canClose = await prepareToClose()
            isConfirmingClose = false
            if canClose { sender.performClose(nil) }
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store?.hasUnsavedChanges == true else { return .terminateNow }
        guard !isConfirmingClose else { return .terminateCancel }
        isConfirmingClose = true
        Task {
            let canClose = await prepareToClose()
            isConfirmingClose = false
            sender.reply(toApplicationShouldTerminate: canClose)
        }
        return .terminateLater
    }

    private func prepareToClose() async -> Bool {
        guard let store else { return true }
        if store.documents.values.contains(where: \.isSaving) { _ = await store.saveAll() }
        guard store.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "Some notes have unsaved changes. You can save them, keep editing, or discard the changes."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        let response: NSApplication.ModalResponse
        if let window { response = await alert.beginSheetModal(for: window) }
        else { response = alert.runModal() }
        switch response {
        case .alertFirstButtonReturn:
            let success = await store.finishEditing(.save)
            if !success {
                let error = NSAlert()
                error.messageText = "Changes could not be saved"
                error.informativeText = store.documents.values.compactMap(\.errorMessage).joined(separator: "\n")
                if let window { await error.beginSheetModal(for: window) }
                else { error.runModal() }
            }
            return success
        case .alertThirdButtonReturn:
            return await store.finishEditing(.discard)
        default:
            return await store.finishEditing(.cancel)
        }
    }
}

// Immutable forwarding preserves SwiftUI's delegate callbacks without moving them across actors.
nonisolated final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    private let previous: (any NSWindowDelegate)?
    @MainActor private weak var lifecycle: LibraryLifecycle?

    @MainActor init(previous: (any NSWindowDelegate)?, lifecycle: LibraryLifecycle) {
        self.previous = previous
        self.lifecycle = lifecycle
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previous?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        previous
    }

    @MainActor func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard lifecycle?.windowShouldClose(sender) != false else { return false }
        return previous?.windowShouldClose?(sender) ?? true
    }
}

struct LibraryWindowStatusView: View {
    let lifecycle: LibraryLifecycle
    let store: NoteStore

    var body: some View {
        LibraryWindowAttachment(lifecycle: lifecycle, isEdited: store.hasUnsavedChanges)
    }
}

struct LibraryWindowAttachment: NSViewRepresentable {
    let lifecycle: LibraryLifecycle
    let isEdited: Bool

    func makeNSView(context: Context) -> AttachmentView {
        AttachmentView(lifecycle: lifecycle, isEdited: isEdited)
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        view.isEdited = isEdited
    }

    final class AttachmentView: NSView {
        let lifecycle: LibraryLifecycle
        var isEdited: Bool {
            didSet { window?.isDocumentEdited = isEdited }
        }

        init(lifecycle: LibraryLifecycle, isEdited: Bool) {
            self.lifecycle = lifecycle
            self.isEdited = isEdited
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                lifecycle.attach(to: window)
                window.isDocumentEdited = isEdited
            }
        }
    }
}
