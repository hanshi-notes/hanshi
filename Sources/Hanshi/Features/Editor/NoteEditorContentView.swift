import SwiftUI
import UniformTypeIdentifiers

struct NoteEditorContentView: View {
    @Bindable var document: NoteDocument
    let files: LibraryFiles
    let mode: ContentMode
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
                    previewPlaceholder.frame(minWidth: 200)
                }
            } else if mode == .source {
                MarkdownEditorView(document: document)
            } else {
                previewPlaceholder
            }
        }
        .confirmationDialog("Discard your edits and reload this note from disk?", isPresented: $confirmingReload) {
            Button("Discard Edits and Reload", role: .destructive) {
                Task { await document.reload(using: files, discardChanges: true) }
            }
        }
    }

    private var previewPlaceholder: some View {
        Text("Preview is not available yet. Choose Editor to edit Markdown.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
