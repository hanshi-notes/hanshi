import SwiftUI

extension FocusedValues {
    @Entry var contentMode: Binding<ContentMode>?
    @Entry var zenMode: Binding<Bool>?
}

struct LibraryViewCommands: Commands {
    @FocusedBinding(\.contentMode) private var mode
    @FocusedBinding(\.zenMode) private var isZen

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Editor") { mode = .source }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(mode == nil)
            Button("Preview") { mode = .preview }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(mode == nil)
            Button("Split View") { mode = .split }
                .keyboardShortcut("3", modifiers: [.command, .option])
                .disabled(mode == nil)
            Divider()
            Button(isZen == true ? "Exit Zen Mode" : "Zen Mode") {
                isZen?.toggle()
            }
            .keyboardShortcut("z", modifiers: [.command, .option])
            .disabled(isZen == nil)
        }
    }
}
