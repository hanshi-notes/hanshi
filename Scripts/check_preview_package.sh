#!/usr/bin/env bash
# Exercise the packaged engines with every SwiftPM build path unavailable.
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$TASK_ROOT"
BIN_DIR=$(swift build -c release --show-bin-path)
PROBE=$(mktemp -d /tmp/hanshi-package-probe.XXXXXX)
HIDDEN="$TASK_ROOT/.build-preview-package-check"
[[ ! -e "$HIDDEN" ]]
cleanup() {
    if [[ -d "$HIDDEN" ]]; then mv "$HIDDEN" "$TASK_ROOT/.build"; fi
    rm -rf "$PROBE"
}
trap cleanup EXIT
ditto "${1:-$TASK_ROOT/build/Hanshi.app}" "$PROBE/Hanshi.app"
cat > "$PROBE/Probe.swift" <<'SWIFT'
import Foundation
import CoreText
import ImageIO
import SwaTex
import SwaTexRender
import CMermaid

@main struct PreviewPackageProbe {
    static func main() throws {
        let font = KaTeXFontProvider.shared.font(for: .mainRegular, size: 20)
        let name = CTFontCopyPostScriptName(font) as String
        precondition(name.contains("KaTeX"), "Formula fonts must come from the packaged bundle")
        let list = try SwaTexEngine.displayList(for: #"\frac{1}{2}+\sqrt{x}+\int_0^1 x dx"#, style: .display)
        guard let math = ImageRenderer.png(for: list, options: RenderOptions(fontSize: 20, padding: 2), displayScale: 2) else {
            fatalError("Formula rendering failed")
        }
        checkImage(math)
        let source = Array("flowchart TD\nA[Packaged] --> B[Rendered]".utf8)
        var output: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = source.withUnsafeBufferPointer { hanshi_mermaid_render($0.baseAddress, $0.count, 2, &output, &length) }
        defer { if let output { hanshi_mermaid_free(output, length) } }
        precondition(status == 0 && output != nil, "Packaged Mermaid rendering failed")
        checkImage(Data(bytes: output!, count: length))
        print("Packaged formula and Mermaid PNGs verified; font: \(name)")
    }
    static func checkImage(_ data: Data) {
        precondition(data.count > 100)
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(image.width > 10 && image.height > 10)
    }
}
SWIFT
# Only the disposable copy's entry point changes; engines are the release objects
# linked into Hanshi, and resources are copied from the finished, signed package.
swiftc -swift-version 6 -parse-as-library \
    -target "$(uname -m)-apple-macosx15.0" \
    -I "$BIN_DIR/Modules" -I "$TASK_ROOT/Sources/CMermaid" \
    "$PROBE/Probe.swift" "$BIN_DIR"/SwaTex.build/*.o "$BIN_DIR"/SwaTexRender.build/*.o \
    -L "$TASK_ROOT/.build/mermaid/release" -lhanshi_mermaid \
    -framework Security -framework SystemConfiguration -framework SwiftUI -lc++ -lz \
    -o "$PROBE/Hanshi.app/Contents/MacOS/Hanshi"
codesign --force --sign - "$PROBE/Hanshi.app" >/dev/null
mv "$TASK_ROOT/.build" "$HIDDEN"
"$PROBE/Hanshi.app/Contents/MacOS/Hanshi"
