#!/usr/bin/env bash
#
# Generate the macOS AppIcon set from a single 1024×1024 source PNG.
#
#   ./Scripts/generate-appicon.sh path/to/source-1024.png
#
# Produces all 10 required PNGs in
#   JarvisMac/Resources/Assets.xcassets/AppIcon.appiconset/
# and rewrites that set's Contents.json to reference them.
#
# Requires macOS (uses `sips`). Run once after you drop in real artwork;
# commit the resulting PNGs + Contents.json.

set -euo pipefail

SRC="${1:-}"
if [[ -z "$SRC" || ! -f "$SRC" ]]; then
  echo "usage: $0 <source-1024.png>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICONSET="$SCRIPT_DIR/../JarvisMac/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"

# size  scale  filename
emit() { # px  out
  sips -z "$1" "$1" "$SRC" --out "$ICONSET/$2" >/dev/null
  echo "  $2 (${1}px)"
}

echo "Generating AppIcon PNGs into $ICONSET"
emit 16   icon_16x16.png
emit 32   icon_16x16@2x.png
emit 32   icon_32x32.png
emit 64   icon_32x32@2x.png
emit 128  icon_128x128.png
emit 256  icon_128x128@2x.png
emit 256  icon_256x256.png
emit 512  icon_256x256@2x.png
emit 512  icon_512x512.png
emit 1024 icon_512x512@2x.png

cat > "$ICONSET/Contents.json" <<'JSON'
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

echo "Done. Commit the PNGs + Contents.json."
