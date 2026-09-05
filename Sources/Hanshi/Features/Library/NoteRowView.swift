import SwiftUI

struct NoteRowView: View {
    let note: Note
    let selected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(note.name)
                .font(.system(size: 13.5))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .foregroundStyle(Color(white: 0.12))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .background(selected ? Color(white: 0.92) : .white)
        .contentShape(Rectangle())
        .accessibilityLabel("\(note.name), \(note.notebookName)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview {
    NoteRowView(note: Note(id: "example", url: URL(filePath: "/library/tutorial/01.md")), selected: true)
        .frame(width: 390)
}
