#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES_DIR="$ROOT_DIR/Resources"
APPICONSET_DIR="$ROOT_DIR/PTTVoice/PTTVoice/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$RESOURCES_DIR" "$APPICONSET_DIR"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

PNG_1024="$WORK_DIR/icon_1024.png"
ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

swift "$SCRIPT_DIR/render-app-icon.swift" "$PNG_1024"

sips -z 16 16     "$PNG_1024" --out "$ICONSET_DIR/icon_16x16.png"      >/dev/null
sips -z 32 32     "$PNG_1024" --out "$ICONSET_DIR/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$PNG_1024" --out "$ICONSET_DIR/icon_32x32.png"      >/dev/null
sips -z 64 64     "$PNG_1024" --out "$ICONSET_DIR/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$PNG_1024" --out "$ICONSET_DIR/icon_128x128.png"    >/dev/null
sips -z 256 256   "$PNG_1024" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$PNG_1024" --out "$ICONSET_DIR/icon_256x256.png"    >/dev/null
sips -z 512 512   "$PNG_1024" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$PNG_1024" --out "$ICONSET_DIR/icon_512x512.png"    >/dev/null
cp "$PNG_1024" "$ICONSET_DIR/icon_512x512@2x.png"

# Legacy .icns — kept for any consumer that still expects it.
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"

# Populate the Xcode asset catalog. The PTTVoice target reads its icon
# from this appiconset; without filenames wired up here, xcodebuild
# produces an .app with the macOS default icon even though Contents.json
# already lists all the slots.
for f in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png \
         icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png \
         icon_512x512.png icon_512x512@2x.png; do
    cp "$ICONSET_DIR/$f" "$APPICONSET_DIR/$f"
done

cat > "$APPICONSET_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "$RESOURCES_DIR/AppIcon.icns"
echo "$APPICONSET_DIR"
