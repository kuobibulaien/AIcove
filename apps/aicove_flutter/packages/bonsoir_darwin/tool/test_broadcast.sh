#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="$(mktemp -d "${TMPDIR:-/tmp}/bonsoir-broadcast-test.XXXXXX")"
source_dir="$root/darwin/bonsoir_darwin/Sources/bonsoir_darwin"
sources=("$root/tool/broadcast_test_support.swift" "$root/tool/broadcast_test_main.swift" "$source_dir/BonsoirService.swift" "$source_dir/Generated.swift" "$source_dir/Broadcast/BonsoirServiceBroadcast.swift")
xcrun swiftc -swift-version 5 -D SUPPRESS_BONJOUR_CALLBACKS "${sources[@]}" -o "$output/no_callback"
"$output/no_callback" no-callback
"$output/no_callback" cancel
xcrun swiftc -swift-version 5 "${sources[@]}" -o "$output/real_overlap"
"$output/real_overlap" overlap
