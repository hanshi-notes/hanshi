#!/usr/bin/env bash
# Adapted from the macos-spm-app-packaging template for a local build.
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$TASK_ROOT"
CONF=${1:-debug}
"$TASK_ROOT/Scripts/build_mermaid.sh"
swift package resolve
# SwiftPM's native accessor omits Contents/Resources. Keep this small, checked patch
# until SwaTex accepts a packaged-app bundle lookup upstream.
SWATEX="$TASK_ROOT/.build/checkouts/SwaTex"
PATCH="$TASK_ROOT/Patches/SwaTex-resource-bundle.patch"
if git -C "$SWATEX" apply --check "$PATCH" 2>/dev/null; then
    git -C "$SWATEX" apply "$PATCH"
else
    git -C "$SWATEX" apply --reverse --check "$PATCH"
fi
swift build -c "$CONF"
BIN_DIR=$(swift build -c "$CONF" --show-bin-path)
APP="$TASK_ROOT/build/Hanshi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Hanshi" "$APP/Contents/MacOS/Hanshi"
# Resource bundles belong inside Contents/Resources so the app can be signed.
for resource in "$BIN_DIR"/SwaTex_SwaTexRender.bundle "$BIN_DIR"/Hanshi_Hanshi.bundle; do
    [[ -d "$resource" ]] || { echo "Missing resource bundle: $resource" >&2; exit 1; }
    ditto "$resource" "$APP/Contents/Resources/$(basename "$resource")"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>Hanshi</string>
    <key>CFBundleDisplayName</key><string>Hanshi</string>
    <key>CFBundleIdentifier</key><string>com.hanshi.app</string>
    <key>CFBundleExecutable</key><string>Hanshi</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDocumentsFolderUsageDescription</key><string>Hanshi stores your notebooks and Markdown files in Documents/hanshi.</string>
    <key>UTExportedTypeDeclarations</key>
    <array><dict>
        <key>UTTypeIdentifier</key><string>com.hanshi.note</string>
        <key>UTTypeDescription</key><string>Hanshi Note Reference</string>
        <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict></array>
</dict></plist>
PLIST
# SwiftPM's command-line build does not compile asset catalogs into the app bundle.
xcrun actool "$TASK_ROOT/Sources/Hanshi/Resources/Assets.xcassets" \
    --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 15.0 --app-icon AppIcon \
    --output-partial-info-plist "$TASK_ROOT/build/asset-info.plist"
/usr/libexec/PlistBuddy -c "Merge $TASK_ROOT/build/asset-info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Created $APP"
