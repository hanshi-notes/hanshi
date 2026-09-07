import SwiftUI
import UniformTypeIdentifiers

struct NoteEditorContentView: View {
    @Bindable var document: NoteDocument
    let files: LibraryFiles
    let mode: ContentMode
    var libraryID: UUID? = nil
    var resourceGeneration = 0
    @State var preview = MarkdownPreviewSession()
    @State private var confirmingReload = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = document.errorMessage {
                HStack {
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Retry Save") { Task { await document.save() } }
                    Button("Save a Copy…", action: saveCopy)
                    Button("Reload…") { confirmingReload = true }
                }
                .padding(10)
                .background(.yellow.opacity(0.15))
            }
            if mode == .split {
                HSplitView {
                    MarkdownEditorView(document: document).frame(minWidth: 200)
                    previewContent.frame(minWidth: 200)
                }
            } else if mode == .source {
                MarkdownEditorView(document: document)
            } else {
                previewContent
            }
        }
        .confirmationDialog("Discard your edits and reload this note from disk?", isPresented: $confirmingReload) {
            Button("Discard Edits and Reload", role: .destructive) {
                Task { await document.reload(using: files, discardChanges: true) }
            }
        }
    }

    private var previewContent: some View {
        VStack(spacing: 0) {
            if let message = preview.message {
                HStack {
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Retry") { preview.retry() }
                }
                .padding(10)
                .background(.yellow.opacity(0.12))
            }
            MarkdownPreviewView(session: preview, snapshot: PreviewSnapshot(
                library: libraryID ?? preview.identity, documentID: document.id, text: document.text,
                url: document.url, root: files.root, resources: resourceGeneration
            ), document: document, split: mode == .split)
        }
    }

    private func saveCopy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.url.deletingPathExtension().lastPathComponent + " copy.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Keep the original draft pending; exporting a copy does not resolve its conflict.
            Task {
                do { try await files.saveCopy(text: document.text, to: url) }
                catch { document.errorMessage = error.localizedDescription }
            }
        }
    }
}
