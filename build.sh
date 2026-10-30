#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
destination="${1:-$project_dir/build}"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
mkdir -p "$project_dir/build"
python3 "$project_dir/scripts/fetch_dependencies.py"
# The permission holder is a pinned build; UI releases must never silently re-sign it.
python3 - "$project_dir" <<'PYHELPER'
from pathlib import Path
import hashlib,json,sys
p=Path(sys.argv[1]); m=json.loads((p/'Resources/Cloud/helper-manifest.json').read_text())
assert hashlib.sha256((p/'Resources/Cloud/Music Drop Cloud.app/Contents/MacOS/MusicDropCloud').read_bytes()).hexdigest()==m['executableSHA256'], 'Cloud helper changed unexpectedly'
for name,digest in m['sources'].items():
 assert hashlib.sha256((p/name).read_bytes()).hexdigest()==digest, 'Cloud helper source changed: rebuild explicitly with build-cloud-helper.sh'
PYHELPER
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/musicdrop-build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
# Keep compiler inputs stable when the project lives in iCloud Documents.
cp "$project_dir"/Sources/*.swift "$build_dir/"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
for architecture in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -O -sdk "$sdk_path" \
        -target "$architecture-apple-macosx14.2" \
        "$build_dir"/*.swift \
        -o "$build_dir/MusicDrop-$architecture"
    cp "$build_dir/MusicDrop-$architecture" "$project_dir/build/MusicDrop-$architecture"
done
bash "$project_dir/package.sh" "$destination"
