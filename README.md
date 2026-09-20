# Hanshi

A native macOS notebook app for Markdown notes, built with SwiftUI. Notes are plain `.md` files on disk: each folder in `~/Documents/hanshi` is a notebook. It has a Tree-sitter-highlighted editor, an editable live preview with formulas and Mermaid diagrams, split view, and wiki-links between notes.

## Requirements

- macOS 15.0+
- Swift 6.3+ (`swift --version`)
- Xcode (for `xcrun actool` when packaging)
- Rust/Cargo from [rustup.rs](https://rustup.rs), for the Mermaid renderer

## Build

```sh
git clone --recurse-submodules https://github.com/hanshi-notes/hanshi.git
cd hanshi
Scripts/build_mermaid.sh
swift test
Scripts/package_app.sh
open build/Hanshi.app
```

In an existing checkout, run `git submodule update --init` first. The Markdown engine lives in the `Vendor/swift-markdown-engine` submodule, which is its own repository with its own tests: `swift test --package-path Vendor/swift-markdown-engine`.

If `swift` still resolves to Xcode's older compiler, run `export TOOLCHAINS=org.swift.633202606251a` for the session.

## Good to know

- **Shortcuts:** new notebook ⌘⇧N, new note ⌘N, search ⌘⇧F, refresh ⌘R, Editor/Preview/Split ⌘⌥1/2/3, Zen ⌘⌥Z.
- **Wiki-links:** `[[Note]]` or `[[Notebook/Note]]`. Renaming a note does not update links to it yet.
- **Saving:** notes save themselves every 60 seconds while you type, when you leave a note and when the app loses focus, or on ⌘S. The interval and the switch are in Settings › General.
- **Not yet:** continuous filesystem watching, a configurable library location.
- **Signing:** the packaged app is ad-hoc signed, with no App Sandbox or notarization. Release checks: `Scripts/package_app.sh release`, `Scripts/check_preview_package.sh`, `Scripts/check_editor_package.sh`.

## License

Hanshi is licensed under the [GNU General Public License v3.0](LICENSE). Third-party notices are in `Sources/Hanshi/Resources/ThirdPartyNotices`.
