#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

PKGVER="${PKGVER:-0.1.0}"

rm -rf out
docker build -f build.Dockerfile --target export \
    --build-arg PKGVER="$PKGVER" \
    --output type=local,dest=out ../../..
docker build -f test.Dockerfile -t gpgui-free-arch-test .
docker run --rm gpgui-free-arch-test
