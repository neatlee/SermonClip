#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

version=$(/usr/libexec/PlistBuddy -c 'Print:CFBundleShortVersionString' Packaging/Info.plist)
app_name="${1:-SermonClip}"
[[ "$app_name" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Invalid app output name" >&2; exit 1; }

Packaging/build-app.sh "$app_name" >/dev/null
app_path="$PWD/dist/$app_name.app"
staging_root="$(mktemp -d)"
trap 'rm -rf "$staging_root"' EXIT

cp -R "$app_path" "$staging_root/$app_name.app"
ln -s /Applications "$staging_root/Applications"

mkdir -p dist
dmg_path="$PWD/dist/${app_name}-${version}-StoneyCreek-arm64.dmg"
rm -f "$dmg_path"
hdiutil create \
    -volname "${app_name} ${version}" \
    -srcfolder "$staging_root" \
    -ov \
    -format UDZO \
    "$dmg_path" >/dev/null

echo "$dmg_path"
