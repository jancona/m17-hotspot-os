#!/bin/sh
# run-smoke.sh - run tests/smoke-rootfs.sh in a throwaway Alpine container
# Needs Docker. On an x86 host Docker must be able to run arm64 images
# (qemu/binfmt); on Apple Silicon or an arm64 Linux host it runs natively.
set -eu
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO_DIR/build.conf"
exec docker run --rm --platform linux/arm64 -v "$REPO_DIR":/repo:ro \
	"alpine:${ALPINE_VERSION}" sh /repo/tests/smoke-rootfs.sh
