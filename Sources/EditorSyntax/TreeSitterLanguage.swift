// Copyright (c) 2023 Marcin Krzyzanowski. MIT License.
// Adapted from STTextView-Plugin-TreeSitter; see ThirdPartyNotices/Editor-Sources.md.
import Foundation
import SwiftTreeSitter
import TreeSitter

import TreeSitterBash
import TreeSitterCSS
import TreeSitterHTML
import TreeSitterJSDoc
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterPython
import TreeSitterRegex
import TreeSitterSwift
import TreeSitterTypeScript
import TreeSitterYAML

public enum TreeSitterLanguage: CaseIterable, Hashable, Sendable {
    case bash
    case css
    case html
    case javascript
    case jsdoc
    case json
    case markdown
    case markdownInline
    case python
    case regex
    case swift
    case typescript
    case yaml

    public var parser: OpaquePointer {
        switch self {
        case .bash: tree_sitter_bash()
        case .css: tree_sitter_css()
        case .html: tree_sitter_html()
        case .javascript: tree_sitter_javascript()
        case .jsdoc: tree_sitter_jsdoc()
        case .json: tree_sitter_json()
        case .markdown: tree_sitter_markdown()
        case .markdownInline: tree_sitter_markdown_inline()
        case .python: tree_sitter_python()
        case .regex: tree_sitter_regex()
        case .swift: tree_sitter_swift()
        case .typescript: tree_sitter_typescript()
        case .yaml: tree_sitter_yaml()
        }
    }

    public var name: String {
        switch self {
        case .bash: "bash"
        case .css: "css"
        case .html: "html"
        case .javascript: "javascript"
        case .jsdoc: "jsdoc"
        case .json: "json"
        case .markdown: "markdown"
        case .markdownInline: "markdown_inline"
        case .python: "python"
        case .regex: "regex"
        case .swift: "swift"
        case .typescript: "typescript"
        case .yaml: "yaml"
        }
    }

    public static func injectedLanguage(named name: String) -> TreeSitterLanguage? {
        switch name {
        case "bash", "sh", "shell": .bash
        case "css": .css
        case "html": .html
        case "javascript", "js": .javascript
        case "jsdoc": .jsdoc
        case "json": .json
        case "markdown": .markdown
        case "markdown_inline", "markdown-inline": .markdownInline
        case "python", "py": .python
        case "regex": .regex
        case "swift": .swift
        case "typescript", "ts": .typescript
        case "yaml", "yml": .yaml
        default: nil
        }
    }

}
