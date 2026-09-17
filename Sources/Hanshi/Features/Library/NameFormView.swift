import SwiftUI

/// Names a notebook or a note: the sheet shown to create or rename either.
struct NameFormView: View {
    enum Event {
        case confirm
        case cancel
    }

    let title: String
    var message: String?
    let placeholder: String
    var footnote: String?
    let confirmTitle: String
    @Binding var name: String
    let isBusy: Bool
    let onEvent: (Event) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.bold())
            if let message { Text(message).foregroundStyle(.secondary) }
            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onEvent(.confirm) }
            if let footnote { Text(footnote).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onEvent(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { onEvent(.confirm) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

#Preview("Rename note") {
    NameFormView(title: "Rename Note", placeholder: "Name", footnote: "The .md extension is kept automatically.",
                 confirmTitle: "Rename", name: .constant("Draft"), isBusy: false) { _ in }
}
