import AppKit
import SwiftUI

struct FontPicker: NSViewRepresentable {
    @Binding var font: NSFont
    var label = "Select editor font"

    func makeCoordinator() -> Coordinator { Coordinator(font: $font) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Select…", target: context.coordinator, action: #selector(Coordinator.showPanel))
        button.bezelStyle = .rounded
        button.setAccessibilityLabel(label)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.font = $font
        if NSFontManager.shared.target === context.coordinator {
            NSFontManager.shared.setSelectedFont(font, isMultiple: false)
        }
    }

    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        if NSFontManager.shared.target === coordinator {
            NSFontManager.shared.target = nil
            NSFontPanel.shared.orderOut(nil)
        }
    }

    final class Coordinator: NSObject, NSFontChanging {
        var font: Binding<NSFont>

        init(font: Binding<NSFont>) { self.font = font }

        @objc func showPanel() {
            let manager = NSFontManager.shared
            manager.target = self
            manager.setSelectedFont(font.wrappedValue, isMultiple: false)
            manager.orderFrontFontPanel(nil)
            NSFontPanel.shared.makeKeyAndOrderFront(nil)
        }

        @objc func changeFont(_ sender: NSFontManager?) {
            font.wrappedValue = (sender ?? .shared).convert(font.wrappedValue)
        }

        func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
            [.face, .size, .collection]
        }
    }
}
