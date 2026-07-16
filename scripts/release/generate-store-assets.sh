#!/usr/bin/env bash
# Regenerate branded iOS/Android launcher icons and Google Play graphics.
# Requires ImageMagick 7 (`magick`). Existing tracked outputs are overwritten
# mechanically; no files are removed and nothing is uploaded.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

command -v magick >/dev/null || {
  echo "ImageMagick 7 is required (expected the 'magick' command)." >&2
  exit 1
}

mkdir -p build/store-assets \
  android/app/src/main/res/drawable-nodpi \
  android/fastlane/metadata/android/en-US/images

master="build/store-assets/app-icon-master.png"
font="assets/fonts/Baloo2-VF.ttf"

# Full-bleed, opaque master: stores apply their own corner masks.
magick -size 1024x1024 'gradient:#34C585-#0C3B2E' \
  -fill none -stroke '#fffdf8' -strokewidth 62 \
  -draw "path 'M 384,704 C 296,704 224,632 224,488 C 224,326 350,200 512,200 C 674,200 800,308 800,470 C 800,596 710,650 638,650 C 584,650 566,614 566,578 C 566,542 602,524 602,470 C 602,416 566,380 512,380 C 458,380 422,416 422,488 C 422,596 440,632 440,704'" \
  -stroke none -fill '#fd7e14' -draw 'circle 746,278 822,278' \
  -fill 'rgba(255,253,248,0.35)' -draw 'circle 724,256 744,256' \
  -depth 8 "PNG24:$master"

for icon in ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png; do
  size="$(magick identify -format '%w' "$icon")"
  magick "$master" -resize "${size}x${size}" -depth 8 "PNG24:$icon"
done

for density_size in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  density="${density_size%%:*}"
  size="${density_size##*:}"
  magick "$master" -resize "${size}x${size}" -depth 8 \
    "PNG24:android/app/src/main/res/mipmap-${density}/ic_launcher.png"
done

# Android adaptive icon foreground; the OS supplies the green background and
# masks/animates this safe-zone artwork.
magick -size 432x432 xc:none \
  -fill none -stroke '#fffdf8' -strokewidth 27 \
  -draw "path 'M 168,300 C 129,300 98,268 98,205 C 98,134 153,79 224,79 C 295,79 350,126 350,197 C 350,252 311,276 279,276 C 255,276 247,260 247,244 C 247,228 263,220 263,197 C 263,173 247,157 224,157 C 200,157 184,173 184,205 C 184,252 192,268 192,300'" \
  -stroke none -fill '#fd7e14' -draw 'circle 327,112 361,112' \
  -depth 8 "PNG32:android/app/src/main/res/drawable-nodpi/ic_launcher_foreground.png"

magick "$master" -resize 512x512 -depth 8 \
  'PNG24:android/fastlane/metadata/android/en-US/images/icon.png'

mark="build/store-assets/app-icon-mark.png"
magick "$master" -resize 78x78 "$mark"
magick -size 1024x500 'gradient:#0C3B2E-#136F4F' \
  "$mark" -geometry +72+50 -composite \
  -font "$font" -fill '#fffdf8' -pointsize 48 -weight 800 \
  -draw "text 172,105 'Sonus Auris'" \
  -pointsize 84 -draw "text 72,258 'A dashcam'" \
  -fill '#ff9f43' -draw "text 72,348 'for your ears.'" \
  -fill 'rgba(255,253,248,0.82)' -pointsize 29 -weight 500 \
  -draw "text 72,430 'Always-on audio  ·  Encrypted backup  ·  Open source'" \
  -fill none -stroke 'rgba(255,255,255,0.16)' -strokewidth 24 \
  -draw 'circle 830,238 962,238' \
  -stroke none -fill '#fd7e14' -draw 'circle 830,238 914,238' \
  -fill '#fffdf8' -draw 'roundrectangle 800,208 860,268 12,12' \
  -depth 8 'PNG24:android/fastlane/metadata/android/en-US/images/featureGraphic.png'

echo "Generated branded launcher icons and Play Store graphics."
