#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

rm -rf out
docker build -f build.Dockerfile --target export --output type=local,dest=out ../../..
docker build -f test.Dockerfile -t gpgui-free-deb-test .
docker run --rm gpgui-free-deb-test
