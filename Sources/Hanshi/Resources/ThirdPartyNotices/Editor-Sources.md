# Editor source provenance

Hanshi's editor uses NSTextView and TextKit 1. No STTextView code is included.

## CotEditor

Source: https://github.com/coteditor/CotEditor/tree/257c95d843251f4888ab38012bb4b74bed09f9c1

License: Apache 2.0, reproduced in `CotEditor-LICENSE`. No image assets are included.

| Hanshi file | CotEditor source under `CotEditor/` | Adaptation |
| --- | --- | --- |
| `Features/Editor/LineNumberView.swift` | `Sources/Document Window/Text View/LineNumberView.swift` | Horizontal ruler with native font drawing and an independent line index; removes Combine, vertical text, custom font and editor dependencies. |
| `Features/Editor/EditorLayoutManager.swift` | `Sources/Document Window/Text View/LayoutManager.swift` | Retains the drawGlyphs integration for visible whitespace; uses native glyph locations and symbols, without CotEditor's control substitution or indent guides. |
| `Features/Editor/NSTextView+EditorGeometry.swift` | `Sources/Document Window/Text View/NSTextView+CurrentLineHighlighting.swift` | Simplifies current-line geometry for a single insertion point; shares TextKit 1 range geometry with preview scrolling. |
| `Resources/Themes/*.cottheme` (13 files) | `Resources/Themes/*.cottheme` | Unmodified JSON assets. Each declares `Same as CotEditor (Apache, ver.2)` in `metadata.license`. |

Original copyright headers are retained. Each adapted Swift file is marked modified.
Preferences use Hanshi's existing AppStorage and SwiftUI panels; no CotEditor preferences code is copied.
Markdown roles use the peg-markdown-highlight vocabulary with CotEditor or existing Hanshi colors. No Mou/MacDown theme values or images are copied. Editor highlighting remains color-only.

## Incremental syntax service

Source: https://github.com/krzyzanowskim/STTextView-Plugin-TreeSitter/tree/346bbce977ce6a485ff9ad5696bebbe8790241e9

License: MIT, reproduced in `STTextView-Plugin-TreeSitter-LICENSE`.

`Sources/EditorSyntax/` contains the parser-only files from `Sources/STPluginTreeSitterCore/` and the language registry from `Sources/TreeSitterResource/TreeSitterLanguage.swift`. Parser point conversion uses a shared UTF-16 line index. The registry's query-bundle accessors were removed; Hanshi loads queries from its own resource bundle. The AppKit/UIKit plugin adapters, STPlugin interfaces, and STTextView are not included.

`Resources/Syntax/` contains the selected languages' `.scm` files from `Sources/TreeSitter*Queries/` at the same revision. Markdown captures are extended for Hanshi's Markdown theme roles; modified query files carry an explicit comment. Query sources include nvim-treesitter; its Apache 2.0 license is reproduced in `Editor-Grammars.md`.

## Grammars

Generated grammar libraries come directly from the MIT-licensed Swift package https://github.com/simonbs/TreeSitterLanguages at revision `15cf3a9ec3ab95e0d058b7df9f35619123c9e02d`. Hanshi links only its C/C++ parser products. Runestone is a resolved package dependency, but no Runestone product or editor is linked.

The linked set is Markdown and Markdown Inline, Bash, CSS, HTML, JavaScript, JSON, Python, Swift and TypeScript, plus YAML for Markdown metadata and JSDoc/Regex for JavaScript injections (13 grammars). Other grammar products and query resources are excluded to reduce the application size. Unsupported fence languages retain the Markdown literal color; preview language support is unchanged.

The package's license is reproduced in `TreeSitterLanguages-LICENSE`; grammar and query upstream notices are in `Editor-Grammars.md`. SwiftTreeSitter and the tree-sitter runtime retain their separate notices.
