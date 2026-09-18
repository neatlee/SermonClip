#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Compiler caches contain absolute paths. A moved checkout needs its own cache.
path_id="$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-16)"
scratch_path="$PWD/.build-app/$path_id"
swift build -c release --scratch-path "$scratch_path"
build_dir="$(swift build -c release --scratch-path "$scratch_path" --show-bin-path)"
resource_bundle="$build_dir/SermonCut_SermonCut.bundle"
resource_root="$resource_bundle/Resources"
if [[ ! -f "$resource_root/Tools/ffmpeg" ]]; then
  resource_root="$resource_bundle/Contents/Resources"
fi
if [[ ! -f "$resource_root/Tools/ffmpeg" ]]; then
  resource_root="$resource_bundle/Contents/Resources/Resources"
fi
if [[ ! -f "$resource_root/Tools/ffmpeg" ]]; then
  resource_bundle="$(find "$scratch_path" -type f \( -path '*/release/SermonCut_SermonCut.bundle/Resources/Tools/ffmpeg' -o -path '*/release/SermonCut_SermonCut.bundle/Contents/Resources/Tools/ffmpeg' \) -print -quit | sed -E 's#/Contents/Resources/Tools/ffmpeg$|/Resources/Tools/ffmpeg$##')"
  resource_root="$resource_bundle/Resources"
  [[ -f "$resource_root/Tools/ffmpeg" ]] || resource_root="$resource_bundle/Contents/Resources"
  [[ -f "$resource_root/Tools/ffmpeg" ]] || resource_root="$resource_bundle/Contents/Resources/Resources"
fi
[[ -n "$resource_bundle" && -f "$resource_root/Tools/ffmpeg" ]] || {
  echo "The release resource bundle or bundled encoder is missing." >&2
  exit 1
}
app_name="${1:-SermonClip}"
[[ "$app_name" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Invalid app output name" >&2; exit 1; }
app_dir="$PWD/dist/$app_name.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/SermonCut" "$app_dir/Contents/MacOS/SermonCut"
cp Packaging/Info.plist "$app_dir/Contents/Info.plist"
# Keep the app's resource bundle layout stable across SwiftPM versions. SwiftPM
# may emit a nested Contents/Resources/Resources directory for package bundles,
# while AppResources.swift intentionally reads bundle/Resources directly.
app_bundle="$app_dir/Contents/Resources/SermonCut_SermonCut.bundle"
mkdir -p "$app_bundle/Resources"
ditto "$resource_root/" "$app_bundle/Resources/"
cp THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"
# The production OAuth client configuration is local-only and intentionally
# excluded from Git. It is bundled into the app at packaging time.
bundled_google_json="$PWD/JSON Keys/sermonclip.json"
[[ -f "$bundled_google_json" ]] || {
  echo "Missing local Google OAuth configuration: $bundled_google_json" >&2
  exit 1
}
cp "$bundled_google_json" "$app_dir/Contents/Resources/sermonclip.json"
# Internal church defaults are copied into the application itself. Neither
# TestMedia nor the project checkout is needed by the installed app.
app_resource_root="$app_dir/Contents/Resources/SermonCut_SermonCut.bundle/Resources"
default_bumpers="$app_resource_root/DefaultBumpers"
mkdir -p "$default_bumpers"
cp Packaging/DefaultBumpers/SCB-Bumper.mp4 "$default_bumpers/SCB-Bumper.mp4"
# Build a standard macOS icon resource from the supplied SermonClip favicon.
icon_source="$PWD/Packaging/SermonClip-Lightmode-Favicon@4x.png"
icon_tmp_root="$(mktemp -d)"
icon_tmp="$icon_tmp_root/SermonClip.iconset"
mkdir -p "$icon_tmp"
trap 'rm -rf "$icon_tmp_root"' EXIT
for size in 16 32 128 256 512; do
  sips -s format png --resampleHeightWidth "$size" "$size" "$icon_source" --out "$icon_tmp/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -s format png --resampleHeightWidth "$double" "$double" "$icon_source" --out "$icon_tmp/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_tmp" -o "$app_dir/Contents/Resources/SermonClip.icns"
# Local ad-hoc signatures only; no developer certificate or notarization.
codesign --force --sign - "$app_resource_root/Tools/ffmpeg"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
