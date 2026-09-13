# Notebook actions: UI regression check

Use a new disposable notebook for this check; do not alter an existing library folder.

1. Right-click the sidebar background and choose **New Notebook…**. Verify the title is **New Notebook**, the name starts empty, and **Create** is disabled until a name is entered. Create a uniquely named notebook and verify it is selected in the sidebar.
2. Right-click the new notebook and choose **Rename…**. Verify the title is **Rename Notebook**, its current name is prefilled, and the enabled confirmation button says **Rename** (regression: the first presentation previously displayed the creation form). Rename it and verify the new name replaces the old row.
3. Open **New Notebook…** from the sidebar background again. Verify the name is empty and the confirmation button says **Create**. Cancel and verify no new folder appears.
4. Right-click the disposable notebook and choose **Move to Trash**. Verify the confirmation names that notebook and warns that all contents are moved. Cancel and verify the notebook remains; repeat and confirm, then verify it disappears.
5. Hide the notebook sidebar. The icon bar should show a notebook picker with **All Notes** and every notebook, including empty ones. Switch notebooks with an unsaved note: the first note opens, search clears, and returning restores the draft and undo. Show the sidebar again and verify the same notebook is selected. The picker disappears with the sidebar visible and in Zen mode.

File contents, drafts, conflicts, identity, undo, invalid paths, and recovery from Trash are covered by `NotebookFileActionTests.swift`.

6. Right-click the disposable notebook and choose **New Subnotebook…**. Verify the form names its parent, then create a child and a grandchild. Each appears indented under its parent; clicking the arrow collapses only that branch and keeps the selected note and draft open. Clicking a notebook name shows only that folder's own notes.
7. Create two subnotebooks with the same name under different parents. Verify the note destination sheet, **Move to Notebook** menu, and hidden-sidebar picker show their relative paths. Create and move a note into each one, then rename the parent and verify the nested notes remain editable.

Nested loading, creation, note actions, ancestor rename/trash, draft preservation, path validation, and independent naming are covered by `NestedNotebookTests.swift`; disclosure interaction is covered by `LibrarySelectionTests.swift`.
