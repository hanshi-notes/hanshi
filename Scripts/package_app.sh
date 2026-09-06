#!/usr/bin/env bash
# Adapted from the macos-spm-app-packaging template for a local build.
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$TASK_ROOT"
CONF=${1:-debug}
swift build -c "$CONF"
BIN_DIR=$(swift build -c "$CONF" --show-bin-path)
APP="$TASK_ROOT/build/Hanshi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Hanshi" "$APP/Contents/MacOS/Hanshi"
# Keep parser queries in the signed app's Resources directory, independent of SwiftPM's build paths.
for resource in "$BIN_DIR"/STTextView-Plugin-TreeSitter_TreeSitter*Queries.bundle; do
    [[ -d "$resource" ]] || continue
    resource_name=$(basename "$resource" .bundle)
    language=${resource_name#STTextView-Plugin-TreeSitter_TreeSitter}
    language=$(echo "${language%Queries}" | tr '[:upper:]' '[:lower:]')
    ditto "$resource" "$APP/Contents/Resources/Syntax/$language"
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
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDocumentsFolderUsageDescription</key><string>Hanshi stores your notebooks and Markdown files in Documents/hanshi.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Created $APP"
