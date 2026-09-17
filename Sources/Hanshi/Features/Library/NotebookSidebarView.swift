import SwiftUI

struct NotebookSidebarView: View {
    enum Event {
        case select(String)
        case newNotebook(in: Notebook?)
        case rename(Notebook)
        case trash(Notebook)
        case move(noteID: String, to: Notebook)
        case refresh
    }

    let notebooks: [Notebook]
    let noteCount: Int
    let selection: String
    let root: URL
    let theme: SidebarTheme
    let isBusy: Bool
    let sessionID: UUID
    @Binding var isExpanded: Bool
    @Binding var collapsedIDs: Set<String>
    @Binding var dropTargetID: String?
    let onEvent: (Event) -> Void

    private var visibleNotebooks: [Notebook] {
        var collapsedAncestor: Notebook?
        return notebooks.filter { notebook in
            if collapsedAncestor?.contains(notebook.url) == true { return false }
            collapsedAncestor = collapsedIDs.contains(notebook.id) ? notebook : nil
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                BarButton(title: "New Notebook", icon: "plus", color: theme.foreground) { onEvent(.newNotebook(in: nil)) }
                    // A white surface over the sidebar colour would outweigh the bar's buttons.
                    .barControl(surface: theme.foreground.opacity(0.06), border: theme.foreground.opacity(0.25))
                    .help("New Notebook (⇧⌘N)")
                    .disabled(isBusy)
            }
            .padding(.horizontal, BarMetrics.margin)
            .frame(height: BarMetrics.height)
            ScrollView {
                LazyVStack(spacing: 0) {
                    Button { onEvent(.select("all")) } label: {
                        row("All Notes", icon: "doc.text.fill", count: noteCount, selected: selection == "all")
                    }
                    Button { isExpanded.toggle() } label: {
                        row("Notebooks", icon: isExpanded ? "chevron.down" : "chevron.right", count: noteCount)
                    }
                    .help(isExpanded ? "Collapse Notebooks" : "Expand Notebooks")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                    if isExpanded {
                        let parents = Set(notebooks.map { $0.url.deletingLastPathComponent().standardizedFileURL })
                        ForEach(visibleNotebooks) { notebook in
                            notebookRow(notebook, hasChildren: parents.contains(notebook.url.standardizedFileURL))
                        }
                    }
                    row("Tags", icon: "tag.fill", count: 0)
                        .accessibilityHint("Tag organization is not available yet")
                }
                .buttonStyle(.plain)
            }
        }
        .background(theme.background)
        .foregroundStyle(theme.foreground)
        .contextMenu {
            Button("New Notebook…") { onEvent(.newNotebook(in: nil)) }
                .disabled(isBusy)
            Button("Show Library in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root.path)
            }
            Button("Refresh Library") { onEvent(.refresh) }
                .disabled(isBusy)
        }
        .background {
            Button("New Notebook") { onEvent(.newNotebook(in: nil)) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(isBusy)
                .hidden()
            Button("Refresh Library") { onEvent(.refresh) }
                .keyboardShortcut("r")
                .disabled(isBusy)
                .hidden()
        }
    }

    private func notebookRow(_ notebook: Notebook, hasChildren: Bool) -> some View {
        let indentation = CGFloat(notebook.path(in: root).split(separator: "/").count - 1) * 18
        let collapsed = collapsedIDs.contains(notebook.id)
        return Button { onEvent(.select(notebook.id)) } label: {
            row(notebook.name, count: notebook.notes.count,
                selected: selection == notebook.id || dropTargetID == notebook.id,
                indentation: indentation)
        }
        .overlay(alignment: .leading) {
            if hasChildren {
                Button {
                    if collapsed { collapsedIDs.remove(notebook.id) }
                    else { collapsedIDs.insert(notebook.id) }
                } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 23, height: 32)
                        .contentShape(Rectangle())
                }
                .padding(.leading, 12 + indentation)
                .help(collapsed ? "Expand \(notebook.name)" : "Collapse \(notebook.name)")
                .accessibilityLabel("Subnotebooks of \(notebook.name)")
                .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            }
        }
        .onDrop(of: [NoteDrag.type], delegate: NotebookDropDelegate(
            isBusy: isBusy, sessionID: sessionID, notebookID: notebook.id, targetedNotebookID: $dropTargetID,
            move: { onEvent(.move(noteID: $0, to: notebook)) }))
        .contextMenu {
            Button("New Subnotebook…") { onEvent(.newNotebook(in: notebook)) }
                .disabled(isBusy)
            Button("Rename…") { onEvent(.rename(notebook)) }
                .disabled(isBusy)
            Button("Move to Trash", role: .destructive) { onEvent(.trash(notebook)) }
                .disabled(isBusy)
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: notebook.url.path)
            }
        }
    }

    private func row(_ name: String, icon: String? = nil, count: Int,
                     selected: Bool = false, indentation: CGFloat = 0) -> some View {
        HStack(spacing: 5) {
            if let icon {
                BarIconView(icon)
                    .frame(width: BarMetrics.iconBox, height: BarMetrics.iconBox)
            }
            Text(name)
                .font(.system(size: 13.5, weight: .regular))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(count, format: .number)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .padding(.leading, (icon == nil ? 35 : 12) + indentation)
        .padding(.trailing, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(selected ? theme.foreground.opacity(0.08) : .clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview {
    let root = URL(filePath: "/library")
    let writing = URL(filePath: "/library/Writing")
    NotebookSidebarView(
        notebooks: [
            Notebook(id: "writing", url: writing, notes: [Note(id: "draft", url: writing.appendingPathComponent("Draft.md"))]),
            Notebook(id: "ideas", url: writing.appendingPathComponent("Ideas"), notes: []),
        ],
        noteCount: 1, selection: "writing", root: root, theme: .standard, isBusy: false, sessionID: UUID(),
        isExpanded: .constant(true), collapsedIDs: .constant([]), dropTargetID: .constant(nil)) { _ in }
        .frame(width: 260, height: 400)
}
