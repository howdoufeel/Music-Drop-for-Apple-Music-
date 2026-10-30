#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
destination="${1:-$project_dir/build}"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
# iCloud adds FinderInfo back to .app folders in Documents. Sign a clean
# staging bundle outside FileProvider, then copy the signed result.
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/musicdrop-sign.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
bundle="$staging_dir/Music Drop.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$project_dir/Info.plist" "$bundle/Contents/Info.plist"
if [ -d "$project_dir/Resources" ]; then
    ditto --norsrc --noextattr "$project_dir/Resources" "$bundle/Contents/Resources"
fi
lipo -create "$project_dir/build/MusicDrop-arm64" "$project_dir/build/MusicDrop-x86_64" \
    -output "$bundle/Contents/MacOS/MusicDrop"
# The unpacked yt-dlp carries its own libraries; give every nested binary a local signature
# so the sealed bundle verifies regardless of how upstream signed them.
if [ -d "$bundle/Contents/Resources/Helpers/yt-dlp" ]; then
    find "$bundle/Contents/Resources/Helpers/yt-dlp" -type f -print0 | while IFS= read -r -d '' file; do
        if file -b "$file" | grep -q "Mach-O"; then codesign --force --sign - "$file"; fi
    done
fi
codesign --force --sign - --options runtime --entitlements "$project_dir/entitlements.plist" "$bundle"
codesign --verify --deep --strict "$bundle"
ln -s /Applications "$staging_dir/Applications"
hdiutil create -volname "Music Drop" -srcfolder "$staging_dir" -ov -format UDZO "$destination/Music Drop.dmg"
echo "$destination/Music Drop.dmg"
