#!/usr/bin/env bash
# Runs the IslandCore unit tests on Linux inside the official Swift image.
# Usage: Scripts/test-core-linux.sh [extra swift test args]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${SWIFT_IMAGE:-swift:6.1-noble}"
docker run --rm -v "$ROOT/Packages/IslandCore:/pkg" -w /pkg "$IMAGE" \
  bash -c "swift build --build-path /tmp/.build && swift test --build-path /tmp/.build $*"
