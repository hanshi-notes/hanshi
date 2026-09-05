import SwiftUI

@main
struct HanshiApp: App {
    @State private var store = NoteStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Hanshi", id: "library") {
            LibraryScreen()
                .environment(store)
                .frame(minWidth: 1020, minHeight: 580)
                .task { await store.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await store.refresh() } }
                }
        }
        .defaultSize(width: 1440, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            LibraryViewCommands()
        }
    }
}
