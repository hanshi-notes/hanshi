import SwiftUI

struct NoteDocumentView: View {
    enum Event {
        case editorAppeared
        case retryOpen
    }

    let document: NoteDocument?
    let hasSelection: Bool
    let isOpening: Bool
    let files: LibraryFiles
    let mode: ContentMode
    let libraryID: UUID
    let resourceGeneration: Int
    let noteURLs: [URL]
    let preview: MarkdownPreviewSession
    let onEvent: (Event) -> Void

    var body: some View {
        if let document {
            NoteEditorContentView(document: document, files: files, mode: mode,
                                  libraryID: libraryID, resourceGeneration: resourceGeneration, noteURLs: noteURLs,
                                  preview: preview)
                .onAppear { onEvent(.editorAppeared) }
        } else if hasSelection {
            VStack(spacing: 12) {
                if isOpening { ProgressView("Opening note…") }
                else {
                    Text("Unable to open this note.").foregroundStyle(.secondary)
                    Button("Retry") { onEvent(.retryOpen) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select a note to start writing")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview("Could not open") {
    NoteDocumentView(document: nil, hasSelection: true, isOpening: false, files: LibraryFiles(root: URL(filePath: "/library")),
                     mode: .source, libraryID: UUID(), resourceGeneration: 0, noteURLs: [],
                     preview: MarkdownPreviewSession()) { _ in }
        .frame(width: 600, height: 400)
}
