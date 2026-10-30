#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
helper_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/musicdrop-cloud-build.XXXXXX")"
trap 'rm -rf "$helper_build_dir"' EXIT
cp "$project_dir/Sources/CloudMenu.swift" "$project_dir/Sources/CloudBridgeProtocol.swift" "$project_dir/CloudHelper/NativeCloudUpdateBridge.swift" "$project_dir/CloudHelper/main.swift" "$helper_build_dir/"
helper_bundle="$helper_build_dir/Music Drop Cloud.app"
mkdir -p "$helper_bundle/Contents/MacOS" "$helper_bundle/Contents/Resources"
cp "$project_dir/CloudHelper/Info.plist" "$helper_bundle/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$helper_bundle/Contents/Resources/AppIcon.icns"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
for architecture in arm64 x86_64; do
 xcrun swiftc -swift-version 5 -O -sdk "$sdk_path" -target "$architecture-apple-macosx14.2" "$helper_build_dir"/*.swift -o "$helper_build_dir/Cloud-$architecture"
done
lipo -create "$helper_build_dir/Cloud-arm64" "$helper_build_dir/Cloud-x86_64" -output "$helper_bundle/Contents/MacOS/MusicDropCloud"
codesign --force --sign - --options runtime "$helper_bundle"
codesign --verify --deep --strict "$helper_bundle"
mkdir -p "$project_dir/Resources/Cloud"
ditto --norsrc --noextattr "$helper_bundle" "$project_dir/Resources/Cloud/Music Drop Cloud.app"
python3 - "$project_dir" <<'PY'
from pathlib import Path
import hashlib,json,sys
p=Path(sys.argv[1]); executable=p/'Resources/Cloud/Music Drop Cloud.app/Contents/MacOS/MusicDropCloud'
sources=['Sources/CloudMenu.swift','Sources/CloudBridgeProtocol.swift','CloudHelper/NativeCloudUpdateBridge.swift','CloudHelper/main.swift','CloudHelper/Info.plist']
manifest={'version':1,'executableSHA256':hashlib.sha256(executable.read_bytes()).hexdigest(),'sources':{x:hashlib.sha256((p/x).read_bytes()).hexdigest() for x in sources}}
(p/'Resources/Cloud/helper-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Pinned Cloud helper built:',manifest['executableSHA256'])
PY
