#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
V0_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="$V0_DIR/bin/kube-burner"

KB_VERSION="v2.4.0"
VERSION_NO_V="${KB_VERSION#v}"

if [ -x "$OUTPUT" ] && "$OUTPUT" version 2>&1 | grep -q "$VERSION_NO_V"; then
  echo "kube-burner $KB_VERSION already installed at $OUTPUT"
  exit 0
fi

OS="$(uname -s)"
case "$OS" in
  Darwin) os="darwin" ;;
  Linux)  os="linux"  ;;
  *)      echo "ERROR: unsupported OS: $OS"; exit 1 ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)        arch="amd64" ;;
  arm64|aarch64) arch="arm64" ;;
  *)             echo "ERROR: unsupported arch: $ARCH"; exit 1 ;;
esac

echo ">>> Downloading kube-burner $KB_VERSION for ${os}/${arch}"

PATTERNS=(
  "kube-burner-V${VERSION_NO_V}-${os}-${arch}.tar.gz"
  "kube-burner-v${VERSION_NO_V}-${os}-${arch}.tar.gz"
  "kube-burner-${VERSION_NO_V}-${os}-${arch}.tar.gz"
  "kube-burner_${VERSION_NO_V}_${os}_${arch}.tar.gz"
  "kube-burner-${os}-${arch}.tar.gz"
)

BASE_URL="https://github.com/kube-burner/kube-burner/releases/download/${KB_VERSION}"
TMPDIR_DL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_DL"' EXIT

downloaded=""
for pattern in "${PATTERNS[@]}"; do
  url="${BASE_URL}/${pattern}"
  echo "  trying: $pattern"
  if curl -fSL --retry 2 --retry-delay 3 -o "$TMPDIR_DL/kube-burner.tar.gz" "$url" 2>/dev/null; then
    echo "  ✓ downloaded: $pattern"
    downloaded="$pattern"
    break
  fi
done

if [ -z "$downloaded" ]; then
  echo ""
  echo "ERROR: could not download kube-burner $KB_VERSION for ${os}/${arch}."
  echo "None of these asset names matched:"
  for p in "${PATTERNS[@]}"; do echo "  - $p"; done
  echo ""
  echo "Set KB_BIN to a local kube-burner binary path and re-run."
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
tar -xzf "$TMPDIR_DL/kube-burner.tar.gz" -C "$TMPDIR_DL"

extracted="$TMPDIR_DL/kube-burner"
if [ ! -f "$extracted" ]; then
  # some tarballs nest inside a directory
  extracted="$(find "$TMPDIR_DL" -name kube-burner -type f | head -1)"
fi
if [ -z "$extracted" ] || [ ! -f "$extracted" ]; then
  echo "ERROR: could not find kube-burner binary in downloaded archive"
  exit 1
fi

mv "$extracted" "$OUTPUT"
chmod +x "$OUTPUT"

version_out="$("$OUTPUT" version 2>&1)"
if ! echo "$version_out" | grep -q "$VERSION_NO_V"; then
  echo "ERROR: installed binary does not report $KB_VERSION"
  echo "$version_out"
  exit 1
fi

echo "$version_out" > "$(dirname "$OUTPUT")/.kb-version"
echo "Installed kube-burner: $OUTPUT ($(echo "$version_out" | head -1))"
