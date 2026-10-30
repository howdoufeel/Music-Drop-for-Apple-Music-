#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$project_dir/build"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/musicdrop-tests-build.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cp "$project_dir/Sources/Core.swift" "$project_dir/Sources/MusicBridge.swift" \
    "$project_dir/Sources/CloudUpdateBridge.swift" "$project_dir/Sources/CloudBridgeClient.swift" \
    "$project_dir/Sources/CloudBridgeProtocol.swift" "$project_dir/Sources/CloudMenu.swift" "$project_dir/Sources/ImportStore.swift" \
    "$project_dir/Sources/SoundCloudService.swift" "$project_dir/Sources/SoundCloudSearchClient.swift" "$project_dir/Sources/SoundCloudStore.swift" \
    "$project_dir/Sources/YouTubeFallback.swift" "$project_dir/Sources/YouTubeService.swift" "$project_dir/Sources/YouTubeStore.swift" \
    "$project_dir/Sources/ParallelDownload.swift" "$project_dir/Sources/LinkRoute.swift" \
    "$project_dir/Tests/Integration/main.swift" "$test_dir/"
xcrun swiftc -swift-version 5 \
    "$test_dir"/*.swift -o "$test_dir/IntegrationTests"
ditto --norsrc --noextattr "$project_dir/Resources/Cloud/Music Drop Cloud.app" "$test_dir/CloudFixture.app"
"$test_dir/IntegrationTests" "$project_dir/Tests/Fixtures/silence.mp3" "$test_dir/CloudFixture.app"
