// Copyright (c) 2023 Marcin Krzyzanowski. MIT License.
// Adapted from STTextView-Plugin-TreeSitter; see ThirdPartyNotices/Editor-Sources.md.
import Foundation
import SwiftTreeSitter
import TreeSitter

import TreeSitterAstro
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSharp
import TreeSitterCSS
import TreeSitterComment
import TreeSitterElixir
import TreeSitterElm
import TreeSitterGo
import TreeSitterHTML
import TreeSitterHaskell
import TreeSitterJSDoc
import TreeSitterJSON
import TreeSitterJSON5
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJulia
import TreeSitterLaTeX
import TreeSitterLua
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterOCaml
import TreeSitterPHP
import TreeSitterPerl
import TreeSitterPython
import TreeSitterR
import TreeSitterRegex
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSCSS
import TreeSitterSQL
import TreeSitterSvelte
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

public enum TreeSitterLanguage: CaseIterable, Hashable, Sendable {
    case astro
    case bash
    case c
    case comment
    case cpp
    case csharp
    case css
    case elixir
    case elm
    case go
    case haskell
    case html
    case java
    case javascript
    case jsdoc
    case json
    case json5
    case julia
    case latex
    case lua
    case markdown
    case markdownInline
    case ocaml
    case perl
    case php
    case python
    case r
    case regex
    case ruby
    case rust
    case scss
    case sql
    case svelte
    case swift
    case toml
    case tsx
    case typescript
    case yaml

    public var parser: OpaquePointer {
        switch self {
        case .astro: tree_sitter_astro()
        case .bash: tree_sitter_bash()
        case .c: tree_sitter_c()
        case .comment: tree_sitter_comment()
        case .cpp: tree_sitter_cpp()
        case .csharp: tree_sitter_c_sharp()
        case .css: tree_sitter_css()
        case .elixir: tree_sitter_elixir()
        case .elm: tree_sitter_elm()
        case .go: tree_sitter_go()
        case .haskell: tree_sitter_haskell()
        case .html: tree_sitter_html()
        case .java: tree_sitter_java()
        case .javascript: tree_sitter_javascript()
        case .jsdoc: tree_sitter_jsdoc()
        case .json: tree_sitter_json()
        case .json5: tree_sitter_json5()
        case .julia: tree_sitter_julia()
        case .latex: tree_sitter_latex()
        case .lua: tree_sitter_lua()
        case .markdown: tree_sitter_markdown()
        case .markdownInline: tree_sitter_markdown_inline()
        case .ocaml: tree_sitter_ocaml()
        case .perl: tree_sitter_perl()
        case .php: tree_sitter_php()
        case .python: tree_sitter_python()
        case .r: tree_sitter_r()
        case .regex: tree_sitter_regex()
        case .ruby: tree_sitter_ruby()
        case .rust: tree_sitter_rust()
        case .scss: tree_sitter_scss()
        case .sql: tree_sitter_sql()
        case .svelte: tree_sitter_svelte()
        case .swift: tree_sitter_swift()
        case .toml: tree_sitter_toml()
        case .tsx: tree_sitter_tsx()
        case .typescript: tree_sitter_typescript()
        case .yaml: tree_sitter_yaml()
        }
    }

    public var name: String {
        switch self {
        case .astro: "astro"
        case .bash: "bash"
        case .c: "c"
        case .comment: "comment"
        case .cpp: "cpp"
        case .csharp: "c_sharp"
        case .css: "css"
        case .elixir: "elixir"
        case .elm: "elm"
        case .go: "go"
        case .haskell: "haskell"
        case .html: "html"
        case .java: "java"
        case .javascript: "javascript"
        case .jsdoc: "jsdoc"
        case .json: "json"
        case .json5: "json5"
        case .julia: "julia"
        case .latex: "latex"
        case .lua: "lua"
        case .markdown: "markdown"
        case .markdownInline: "markdown_inline"
        case .ocaml: "ocaml"
        case .perl: "perl"
        case .php: "php"
        case .python: "python"
        case .r: "r"
        case .regex: "regex"
        case .ruby: "ruby"
        case .rust: "rust"
        case .scss: "scss"
        case .sql: "sql"
        case .svelte: "svelte"
        case .swift: "swift"
        case .toml: "toml"
        case .tsx: "tsx"
        case .typescript: "typescript"
        case .yaml: "yaml"
        }
    }

    public static func injectedLanguage(named name: String) -> TreeSitterLanguage? {
        switch name {
        case "astro": .astro
        case "bash", "sh", "shell": .bash
        case "c": .c
        case "comment": .comment
        case "cpp", "c++": .cpp
        case "c_sharp", "csharp": .csharp
        case "css": .css
        case "elixir": .elixir
        case "elm": .elm
        case "go": .go
        case "haskell": .haskell
        case "html": .html
        case "java": .java
        case "javascript", "js": .javascript
        case "jsdoc": .jsdoc
        case "json": .json
        case "json5": .json5
        case "julia": .julia
        case "latex": .latex
        case "lua": .lua
        case "markdown": .markdown
        case "markdown_inline", "markdown-inline": .markdownInline
        case "ocaml": .ocaml
        case "perl": .perl
        case "php": .php
        case "python", "py": .python
        case "r": .r
        case "regex": .regex
        case "ruby", "rb": .ruby
        case "rust", "rs": .rust
        case "scss": .scss
        case "sql": .sql
        case "svelte": .svelte
        case "swift": .swift
        case "toml": .toml
        case "tsx": .tsx
        case "typescript", "ts": .typescript
        case "yaml", "yml": .yaml
        default: nil
        }
    }

}
