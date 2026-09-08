# Native editor acceptance checks

Build with `Scripts/package_app.sh release`. Run `Scripts/check_editor_package.sh` and `Scripts/check_preview_package.sh` after all builds and tests finish. Both checks use a disposable app with `.build` temporarily hidden and restore it on exit.

Use a disposable notebook containing short Markdown, an empty note, Unicode/RTL prose, wrapped lines, and the 1 MB corpus from `NativeEditorTests.swift`.

- Switch Source → Preview → Split and back. Selection, draft text, scroll position and undo must survive.
- Scroll from either panel to distant headings and back. Resize Split; both panels must stay aligned without feedback loops.
- Click blank space below text at the left, middle and right of the editor. Focus must move to the editor, with the insertion point at the end. Click a text line to place the caret normally.
- Type Japanese using a real input method: compose, select a candidate, commit and undo. Also cancel a composition and edit near emoji/combining characters.
- Dictate a sentence through macOS Dictation, correct a word, then undo and redo. This requires a microphone and the user's configured dictation language.
- Enable continuous spelling checks from the native spelling menu, enter a misspelling, and apply a suggestion. Verify the draft and undo history.
- Select and copy Unicode text. The clipboard must contain exact plain Markdown with no syntax attributes.
- With VoiceOver, focus the editor, navigate lines, select text and read the insertion position. The editor must be announced as “Markdown editor”. Check the line-number ruler does not obscure editing accessibility.
- Toggle gutter/invisibles and change font, spacing, indentation, ligatures and all 13 CotEditor themes. Text and undo must stay unchanged. Check dark-theme cursor and selection contrast.

Automated coverage exercises NSTextInputClient marked-text composition/commit/undo, temporary colors and font attributes, Unicode and CRLF line numbers, blank-space clicks, copy-related plain storage, layout resizing, two-way scroll synchronization, theme resources and the 1 MB corpus. Real microphone dictation and spoken VoiceOver navigation require the manual checks above; automated API checks do not certify those interactions.
