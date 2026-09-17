import SwiftUI
import UniformTypeIdentifiers

nonisolated enum NoteDrag {
    static let type = UTType(exportedAs: "com.hanshi.note", conformingTo: .data)

    static func provider(noteID: String, sessionID: UUID) -> NSItemProvider {
        NSItemProvider(item: Data("\(sessionID.uuidString)\n\(noteID)".utf8) as NSData,
                       typeIdentifier: type.identifier)
    }

    static func noteID(from provider: NSItemProvider, sessionID: UUID) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                let fields = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .split(separator: "\n", omittingEmptySubsequences: false)
                guard let fields, fields.count == 2, fields[0] == sessionID.uuidString,
                      !fields[1].isEmpty else { continuation.resume(returning: nil); return }
                continuation.resume(returning: String(fields[1]))
            }
        }
    }
}

struct NotebookDropDelegate: DropDelegate {
    let isBusy: Bool
    let sessionID: UUID
    let notebookID: String
    @Binding var targetedNotebookID: String?
    let move: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        // Item providers are only available inside performDrop, not while hovering.
        !isBusy && info.hasItemsConforming(to: [NoteDrag.type])
    }

    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { targetedNotebookID = notebookID }
    }

    func dropExited(info: DropInfo) {
        if targetedNotebookID == notebookID { targetedNotebookID = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        targetedNotebookID = nil
        guard validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: [NoteDrag.type])
        guard providers.count == 1, let provider = providers.first else { return false }
        Task {
            if let noteID = await NoteDrag.noteID(from: provider, sessionID: sessionID) {
                move(noteID)
            }
        }
        return true
    }
}
