# Notebook actions: UI regression check

Use a new disposable notebook for this check; do not alter an existing library folder.

1. Right-click a notebook and choose **New Notebook…**. Verify the title is **New Notebook**, the name starts empty, and **Create** is disabled until a name is entered. Create a uniquely named notebook and verify it is selected in the sidebar.
2. Right-click the new notebook and choose **Rename…**. Verify the title is **Rename Notebook**, its current name is prefilled, and the enabled confirmation button says **Rename** (regression: the first presentation previously displayed the creation form). Rename it and verify the new name replaces the old row.
3. Open **New Notebook…** again. Verify the name is empty and the confirmation button says **Create**. Cancel and verify no new folder appears.
4. Right-click the disposable notebook and choose **Move to Trash**. Verify the confirmation names that notebook and warns that all contents are moved. Cancel and verify the notebook remains; repeat and confirm, then verify it disappears.

File contents, drafts, conflicts, identity, undo, invalid paths, and recovery from Trash are covered by `NotebookFileActionTests.swift`.
