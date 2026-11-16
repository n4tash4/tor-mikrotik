#!/usr/bin/env sh

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
