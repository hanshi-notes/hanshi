# Hanshi

A native macOS notebook browser built with SwiftUI. Requires macOS 14+ and Swift 6.2 or later.

```sh
swift test
Scripts/package_app.sh
open build/Hanshi.app
```

The first launch creates `~/Documents/hanshi` without adding sample content or changing existing files. Each immediate folder is a notebook. Create a notebook with **⌘⇧N**, then create empty Markdown files with **⌘N**. Filenames are numbered independently in each notebook (`01.md`, `02.md`, …) and sorted in natural filename order. In All Notes, creating a note asks for its destination notebook.

The layout follows the supplied Notable replica: full-height dark sidebar, full-width selection rows, and grouped note actions. Click **Notebooks** or use **⌘⇧N** to create a folder.

Search filenames with **⌘F**, refresh from disk with **⌘R**, and toggle Zen with **⌘⌥Z**. Choose Editor, Preview, or Split from **View** (**⌘⌥1**, **⌘⌥2**, **⌘⌥3**); the pencil toggles Editor/Preview and also offers the modes in its context menu. The library also refreshes when the app becomes active. Folder and file context menus open Finder. Notebooks and notes keep filesystem identity when renamed externally.

Editor, preview, and split panels are intentionally empty. Tags, attachments, favorites, pinning, and trash controls are disabled until their behavior is implemented. Editing, Markdown rendering, continuous filesystem watching, and library-location preferences are not included yet.

The app has one window and quits when that window closes. The packaging script makes a locally ad-hoc-signed app without App Sandbox or external dependencies. Developer ID signing and notarization are not configured.
