import SwiftUI

/// Asks which notebook a new note goes in, when no notebook is selected.
struct NotebookPickerView: View {
    enum Event {
        case choose(Notebook)
        case cancel
    }

    let notebooks: [Notebook]
    let root: URL
    let onEvent: (Event) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a Notebook").font(.title2.bold())
            Text("The new note will be created in this folder.").foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(notebooks) { notebook in
                        Button { onEvent(.choose(notebook)) } label: {
                            Label(notebook.path(in: root), systemImage: "book.closed")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onEvent(.cancel) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

#Preview {
    NotebookPickerView(notebooks: [Notebook(id: "writing", url: URL(filePath: "/library/Writing"), notes: [])],
                       root: URL(filePath: "/library")) { _ in }
}
