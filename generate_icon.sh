#!/bin/bash
# Generate TopStats app icon using ImageMagick
# Requires: ImageMagick (brew install imagemagick)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SVG_FILE="TopStats_icon_simple.svg"

if [ ! -f "$SVG_FILE" ]; then
    echo "Error: $SVG_FILE not found"
    exit 1
fi

echo "Generating TopStats app icon from $SVG_FILE..."

# Create iconset directory
rm -rf TopStats.iconset
mkdir -p TopStats.iconset

# Use magick (ImageMagick 7)
if ! command -v magick &> /dev/null; then
    echo "Error: ImageMagick (magick command) not found"
    echo "Install with: brew install imagemagick"
    exit 1
fi

# Generate all required icon sizes with 8-bit depth for macOS compatibility
echo "Creating icon sizes..."
magick -background none -density 300 "$SVG_FILE" -resize 16x16 -depth 8 PNG32:TopStats.iconset/icon_16x16.png
magick -background none -density 300 "$SVG_FILE" -resize 32x32 -depth 8 PNG32:TopStats.iconset/icon_16x16@2x.png
magick -background none -density 300 "$SVG_FILE" -resize 32x32 -depth 8 PNG32:TopStats.iconset/icon_32x32.png
magick -background none -density 300 "$SVG_FILE" -resize 64x64 -depth 8 PNG32:TopStats.iconset/icon_32x32@2x.png
magick -background none -density 300 "$SVG_FILE" -resize 128x128 -depth 8 PNG32:TopStats.iconset/icon_128x128.png
magick -background none -density 300 "$SVG_FILE" -resize 256x256 -depth 8 PNG32:TopStats.iconset/icon_128x128@2x.png
magick -background none -density 300 "$SVG_FILE" -resize 256x256 -depth 8 PNG32:TopStats.iconset/icon_256x256.png
magick -background none -density 300 "$SVG_FILE" -resize 512x512 -depth 8 PNG32:TopStats.iconset/icon_256x256@2x.png
magick -background none -density 300 "$SVG_FILE" -resize 512x512 -depth 8 PNG32:TopStats.iconset/icon_512x512.png
magick -background none -density 300 "$SVG_FILE" -resize 1024x1024 -depth 8 PNG32:TopStats.iconset/icon_512x512@2x.png

echo "All PNG sizes created"

# Convert iconset to icns
echo "Converting to icns..."
iconutil -c icns TopStats.iconset -o TopStats.icns

if [ -f "TopStats.icns" ]; then
    echo ""
    echo "Success! Created TopStats.icns ($(du -h TopStats.icns | cut -f1))"
    echo ""
    echo "To rebuild app with new icon: ./build.sh"
    echo "To install: cp -R TopStats.app /Applications/"
else
    echo "Error: Failed to create icns file"
    exit 1
fi
