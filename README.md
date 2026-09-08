# Hanshi

A native macOS notebook browser built with SwiftUI. Requires macOS 15.0+ and Swift tools 6.3 or later, using Swift 6 language mode. The development toolchain is Swift 6.3.3.

The scripts use `swift` and `swiftc` from your `PATH`, matching the compiler selected in your terminal (including Swiftly). If `swift --version` already reports 6.3+, build directly:

```sh
swift --version
Scripts/build_mermaid.sh
swift test
Scripts/package_app.sh
open build/Hanshi.app
```

Building Mermaid requires Rust/Cargo (install the stable toolchain from [rustup.rs](https://rustup.rs)). `Scripts/build_mermaid.sh` builds the locked merman/resvg static library for the host architecture; rerun it after changes to `Native/Mermaid`. The packaging script runs it automatically. Rust, Node and JavaScript runtimes are not required on the end user’s Mac.

For release packaging checks, run `Scripts/package_app.sh release`, `Scripts/check_preview_package.sh`, and `Scripts/check_editor_package.sh`. The editor check verifies all 38 grammar configurations, Markdown/Swift highlighting, all 13 CotEditor themes, and editor notices from a disposable app with `.build` hidden. The latter temporarily hides `.build` (restoring it on exit) and renders formulas and Mermaid using the release engine objects and resources from a disposable copy of the packaged app. Run it after builds finish. Toolchain-selection regressions run with `python3 Tests/Scripts/test_swift_toolchain.py`. Native bridge tests run with `cargo test --release --locked --manifest-path Native/Mermaid/Cargo.toml --target-dir .build/mermaid`.

If your terminal still selects Xcode’s older Swift through `/usr/bin/swift`, run `export TOOLCHAINS=org.swift.633202606251a` to select the installed standalone Swift 6.3.3 toolchain for that session, then check `swift --version` again. This does not change Xcode’s global selection. `xcrun swift` follows Xcode/toolchain selection and can differ from a Swiftly-managed `swift` on `PATH`. In Xcode, select Swift 6.3.3 under **Xcode → Toolchains** when using the standalone installation.

The first launch creates `~/Documents/hanshi` without adding sample content or changing existing files. Each immediate folder is a notebook. Create a notebook with **⌘⇧N**, then create Markdown files with **⌘N**. New files use the first available name in their notebook: `Note.md`, `Note (1).md`, and so on. The title template is enabled by default: new notes start with `# Note`, and saving follows the first heading while the filename is still managed by that behavior. Turning the template off creates blank notes. Notes are sorted in natural filename order and displayed without their extension. In All Notes, creating a note asks for its destination notebook.

The layout follows the supplied Notable replica: full-height dark sidebar, full-width selection rows, and grouped note actions. Click **Notebooks** or use **⌘⇧N** to create a folder.

Search filenames with **⌘⇧F**, refresh from disk with **⌘R**, and toggle Zen with **⌘⌥Z**. Hide or show the notebook sidebar from **View** (**⌃⌘S**), keeping the note list and document visible; its visibility is preserved when leaving Zen. Choose Editor, Preview, or Split from **View** (**⌘⌥1**, **⌘⌥2**, **⌘⌥3**); the pencil toggles Editor/Preview and also offers the modes in its context menu. The library also refreshes when the app becomes active. Folder and file context menus open Finder. Notebooks and notes keep filesystem identity when renamed externally.

The Markdown editor uses NSTextView with TextKit 1 and incremental Tree-sitter highlighting, with manual saving, undo/redo, and draft preservation across notes and content modes. The selectable native preview renders the unsaved draft with cmark-gfm, HighlightKit code highlighting, SwaTex formulas and merman 0.7.0/resvg 0.47.0 diagrams. Split synchronizes scrolling by source blocks; switching modes preserves editor selection and undo/redo. Preview links to catalog notes preserve the reading mode and focus. Autosave, continuous filesystem watching, and library-location preferences remain planned.

Preview supports GFM tables, task lists (read-only), strikethrough, reference links/images and literal HTML. Front matter remains visible. Local raster images are restricted to the library, including symlink validation; remote images are never downloaded. Web/email links open only when clicked; local non-Markdown attachments are revealed in Finder. Refresh with **⌘R** to reread changed images.

Use `$…$` for inline formulas, `$$…$$` for display formulas and fenced `mermaid` blocks for diagrams. Escaped dollars and code remain literal; single-dollar formulas cannot cross a newline, code span or HTML tag. Unclosed delimiters remain visible. Invalid formulas/diagrams show their source and a diagnostic. Mermaid is a compatibility implementation, not guaranteed browser-identical output; rasterized diagrams do not execute callbacks or load external resources.

Work is bounded: notes up to 2 MB, Markdown nesting up to 128 levels, code highlighting up to 64 KB per block (larger blocks remain readable), formulas up to 4 KB/64 brace levels, diagrams up to 32 KB/256 lines/512 statements. Images are limited to 20 MB and 80 million input pixels and downsampled to 2048 pixels. A render is limited to 256 media attachments and 32 million output pixels; task-list markers reuse two symbol attachments. The preview currently uses the app’s light appearance.

The app has one window and quits when that window closes. The packaging script makes a locally ad-hoc-signed app without App Sandbox, bundling syntax queries, formula fonts and third-party license notices. Resource bundles are placed in `Contents/Resources`. Packaging applies the small, checked `Patches/SwaTex-resource-bundle.patch` to the pinned checkout so its font loader finds that signed-app location; normal SwiftPM builds retain their existing fallback. No math or synchronization code is changed. The Rust renderer is statically linked; the build produces the host architecture. Developer ID signing and notarization are not configured.

Preview parsing, highlighting, and attributed-text composition run off the main actor. The composed text and its paragraph/table objects transfer ownership once using Swift `sending`; attachment cells and view updates stay on the main actor. Resizing invalidates only recorded media ranges. Run `swift test -c release --filter previewCorpusRendersAtTenHundredAndThousandKilobytes` for composition measurements and `swift test -c release --filter previewHundredKilobyteUpdatesIncludeApplicationAndLayout` for end-to-end updates. `longest_batch` measures attachment finalization on the main actor, excluding storage application and layout.

Editor syntax colors use temporary NSLayoutManager attributes, so changing a theme does not alter source text or undo history. The editor retains its font, indentation, gutter and invisible-character preferences and adds 13 bundled CotEditor themes with a themed preview in Appearance settings. CotEditor adaptations and resource revisions are listed in `Sources/Hanshi/Resources/ThirdPartyNotices/Editor-Sources.md`. No CotEditor image resources are included.

Run `swift test -c release --filter nativeEditorMillionByteCorpus` to measure the 1 MB editor corpus (layout, typing and highlighting). Parsing remains off the main actor; pending highlighting requests coalesce to the latest source. The syntax service indexes UTF-16 line starts once per parse, preserving byte columns for Unicode text. See `Tests/Manual/NativeEditor.md` for native input and accessibility checks.
