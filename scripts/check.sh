#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swift build
swiftc Sources/MacRemoteCore/Protocol.swift \
    Sources/MacRemoteCore/RelayPath.swift \
    Sources/MacRemoteCore/RelayClient.swift \
    Sources/mac_remote_host/RegionEncoder.swift \
    Tests/SmokeTests.swift -o "$test_dir/smoke-tests"
"$test_dir/smoke-tests"
go -C relayd test -race ./...