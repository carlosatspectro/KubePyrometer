#!/usr/bin/env bash
# --------------------------------------------------------------------------
# OPTIONAL: build kube-burner from source (requires Go >= 1.23).
# This script is NOT called automatically.  run.sh downloads a pre-built
# release binary via install-kube-burner.sh instead.
#
# To force a source build:
#   KB_BUILD_FROM_SOURCE=1 bash v0/scripts/build-kube-burner.sh
# --------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
V0_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="$V0_DIR/bin/kube-burner"

KB_SOURCE="${KB_SOURCE:-$V0_DIR/../kube-burner}"
KB_TAG="${KB_TAG:-v2.4.0}"

if [ -x "$OUTPUT" ]; then
  echo "kube-burner binary already exists at $OUTPUT"
  "$OUTPUT" version
  exit 0
fi

if [ ! -d "$KB_SOURCE" ]; then
  echo "kube-burner source not found at $KB_SOURCE"
  echo "Clone it:  git clone --branch $KB_TAG https://github.com/kube-burner/kube-burner.git $KB_SOURCE"
  exit 1
fi

if ! command -v go &>/dev/null; then
  echo "Go toolchain required to build kube-burner. Install Go >= 1.23."
  exit 1
fi

GIT_COMMIT="$(cd "$KB_SOURCE" && git rev-parse HEAD)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VERSION_PKG="github.com/cloud-bulldozer/go-commons/v2/version"

LDFLAGS="-X ${VERSION_PKG}.Version=${KB_TAG}"
LDFLAGS="${LDFLAGS} -X ${VERSION_PKG}.GitCommit=${GIT_COMMIT}"
LDFLAGS="${LDFLAGS} -X ${VERSION_PKG}.BuildDate=${BUILD_DATE}"

echo "Building kube-burner ${KB_TAG} (${GIT_COMMIT:0:12}) ..."
mkdir -p "$(dirname "$OUTPUT")"
(cd "$KB_SOURCE" && go build -ldflags "${LDFLAGS}" -o "$OUTPUT" ./cmd/kube-burner/)

echo "Built successfully:"
"$OUTPUT" version
