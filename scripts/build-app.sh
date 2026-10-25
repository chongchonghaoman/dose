#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
version=$(cat VERSION)
swift build -c release
binary=$(swift build -c release --show-bin-path)
app="${1:-$PWD/dist/观片台.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary/LightTable" "$app/Contents/MacOS/LightTable"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LightTable</string>
<key>CFBundleIdentifier</key><string>local.ourlighttable.desktop</string>
<key>CFBundleName</key><string>观片台</string>
<key>CFBundleDisplayName</key><string>观片台</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>UTExportedTypeDeclarations</key>
<array><dict>
<key>UTTypeIdentifier</key><string>app.ourlighttable.photo-reference</string>
<key>UTTypeDescription</key><string>LightTable Photo Reference</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict><dict>
<key>UTTypeIdentifier</key><string>app.ourlighttable.album-page</string>
<key>UTTypeDescription</key><string>LightTable Album Page</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict></array>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
