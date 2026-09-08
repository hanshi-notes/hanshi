#!/usr/bin/env bash
# Verify editor resources from a disposable app with the build tree unavailable.
set -euo pipefail
shopt -s nullglob
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$TASK_ROOT"
CONF=${2:-release}
BIN_DIR=$(swift build -c "$CONF" --show-bin-path)
PROBE=$(mktemp -d /tmp/hanshi-editor-package.XXXXXX)
HIDDEN="$TASK_ROOT/.build-editor-package-check"
[[ ! -e "$HIDDEN" ]]
cleanup() {
    if [[ -d "$HIDDEN" ]]; then mv "$HIDDEN" "$TASK_ROOT/.build"; fi
    rm -rf "$PROBE"
}
trap cleanup EXIT
ditto "${1:-$TASK_ROOT/build/Hanshi.app}" "$PROBE/Hanshi.app"
cat > "$PROBE/Probe.swift" <<'SWIFT'
import AppKit
import EditorSyntax
import SwiftTreeSitter

@main struct EditorPackageProbe {
    @MainActor static func main() throws {
        let bundle = EditorResources.bundle
        let resources = bundle.resourceURL!
        let directories = try FileManager.default.contentsOfDirectory(at: resources.appendingPathComponent("Syntax"), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        precondition(Set(directories.map(\.lastPathComponent)) == Set(TreeSitterLanguage.allCases.map {
            $0.name.replacingOccurrences(of: "_", with: "")
        }), "Packaged queries must match the linked languages")
        func configuration(_ language: TreeSitterLanguage) -> LanguageConfiguration? {
            let directory = resources.appendingPathComponent("Syntax")
                .appendingPathComponent(language.name.replacingOccurrences(of: "_", with: ""))
            return try? LanguageConfiguration(Language(language.parser), name: language.name, queriesURL: directory)
        }
        for language in TreeSitterLanguage.allCases {
            precondition(configuration(language) != nil, "Missing queries for \(language.name)")
        }
        let client = try TreeSitterClient(languageConfiguration: configuration(.markdown)!, languageProvider: {
            TreeSitterLanguage.injectedLanguage(named: $0).flatMap(configuration)
        })
        let tokens = try client.resetDocument(content: "# Title\n\n```swift\nlet value = 42\n```\n")
        precondition(tokens.contains { $0.name.hasPrefix("text.title") })
        precondition(tokens.contains { $0.name == "keyword" })
        precondition(tokens.contains { $0.name == "number" })
        let themes = try FileManager.default.contentsOfDirectory(at: resources.appendingPathComponent("Themes"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "cottheme" }
        precondition(themes.count == 13)
        for url in themes { _ = try CotTheme(data: Data(contentsOf: url)) }
        let notices = resources.appendingPathComponent("ThirdPartyNotices")
        for name in ["CotEditor-LICENSE", "Editor-Sources.md", "Editor-Grammars.md"] {
            precondition(FileManager.default.isReadableFile(atPath: notices.appendingPathComponent(name).path))
        }
        precondition(!FileManager.default.fileExists(atPath: notices.appendingPathComponent("STTextView-LICENSE.md").path))
        print("Packaged editor verified: \(TreeSitterLanguage.allCases.count) grammars, embedded Swift, 13 themes and notices")
    }
}
SWIFT
OBJECTS=()
INCLUDES=()
for module in EditorSyntax SwiftTreeSitter SwiftTreeSitterLayer; do
    OBJECTS+=("$BIN_DIR/$module.build/"*.o)
done
OBJECTS+=("$BIN_DIR/TreeSitter.build/src/"*.o "$BIN_DIR/TreeSitter.build/src/"*/*.o)
while read -r keyword module; do
    [[ "$module" == TreeSitter* && "$module" != TreeSitter ]] || continue
    OBJECTS+=("$BIN_DIR/$module.build/src/"*.o "$BIN_DIR/$module.build/src/"*/*.o)
    INCLUDES+=(-I "$BIN_DIR/$module.build")
done < <(rg '^import TreeSitter' Sources/EditorSyntax/TreeSitterLanguage.swift)
swiftc -swift-version 6 -parse-as-library \
    -target "$(uname -m)-apple-macosx15.0" \
    -I "$BIN_DIR/Modules" -I "$BIN_DIR/TreeSitter.build" "${INCLUDES[@]}" \
    "$PROBE/Probe.swift" Sources/Hanshi/Features/Editor/CotTheme.swift \
    "$BIN_DIR/Hanshi.build/DerivedSources/resource_bundle_accessor.swift" \
    "${OBJECTS[@]}" -lc++ -o "$PROBE/Hanshi.app/Contents/MacOS/Hanshi"
codesign --force --sign - "$PROBE/Hanshi.app" >/dev/null
mv "$TASK_ROOT/.build" "$HIDDEN"
"$PROBE/Hanshi.app/Contents/MacOS/Hanshi"
