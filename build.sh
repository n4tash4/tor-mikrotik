#!/usr/bin/env sh
# Build a Tor transparent-proxy container for MikroTik RouterOS, for BOTH
# MikroTik CPU families, producing one container-archive tar per arch.
#
# Mirrors ../tailscale-mikrotik/build.sh:
#
#   tor-arm32.tar  linux/arm/v5  soft-float  -> hAP ax S / hEX Refresh (EN7562CT)
#   tor-arm64.tar  linux/arm64   ARMv8       -> RB5009 (Cortex-A72) & aarch64
#
# Unlike the tailscale build, Tor is installed from the Debian archive for the
# target arch, so there is no Go cross-compile — the whole build runs in the
# target-arch base image (under QEMU when cross-building).
#
# Requires Docker Buildx and skopeo. For cross-arch builds register QEMU once:
#   docker run --privileged --rm tonistiigi/binfmt --install all
#
# Usage:
#   ./build.sh          # both arches -> tor-arm32.tar AND tor-arm64.tar
#   ./build.sh arm64    # arm64 only
#   ./build.sh arm32    # arm32 only

VERSION=0.1.0

set -eu

build_arch() {
    _name="$1"
    _platform="$2"
    _runtime_base="$3"
    _out="tor-${_name}.tar"

    echo ">>> Building ${_name}  (${_platform}, base ${_runtime_base}) -> ${_out}"
    rm -f "${_out}"

    docker buildx build \
      --no-cache \
      --build-arg RUNTIME_BASE="${_runtime_base}" \
      --platform "${_platform}" \
      --load -t "tor-mikrotik:${VERSION}-${_name}" .

    skopeo copy \
      "docker-daemon:tor-mikrotik:${VERSION}-${_name}" \
      "docker-archive:${_out}"

    echo ">>> Done: ${_out}"
}

TARGET="${1:-all}"

if [ "$TARGET" = "all" ] || [ "$TARGET" = "arm32" ]; then
    build_arch arm32 "linux/arm/v5" "arm32v5/debian:bookworm-slim"
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "arm64" ]; then
    build_arch arm64 "linux/arm64"  "arm64v8/debian:bookworm-slim"
fi

echo ">>> All requested builds complete."
ls -lh tor-*.tar 2>/dev/null || true
