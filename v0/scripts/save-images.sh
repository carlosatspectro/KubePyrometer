#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
V0_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$V0_DIR/images"
TAR_FILE="$OUT_DIR/harness-images.tar"

# Pinned versions — update these when refreshing images.
# KUBECTL_TAG must match the image ref in templates/probe-job.yaml.
BUSYBOX_TAG="1.36.1"
KUBECTL_TAG="1.35.2"

mkdir -p "$OUT_DIR"

echo ">>> Pulling bitnami/kubectl:latest"
docker pull "bitnami/kubectl:latest"

ACTUAL_VER=$(docker inspect bitnami/kubectl:latest \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || echo "unknown")

if [ "$ACTUAL_VER" != "$KUBECTL_TAG" ]; then
  echo "WARN: pulled bitnami/kubectl:latest reports version $ACTUAL_VER"
  echo "      but KUBECTL_TAG is pinned to $KUBECTL_TAG"
  echo "      Update KUBECTL_TAG in this script and image ref in templates/probe-job.yaml"
fi

echo ">>> Tagging bitnami/kubectl:latest -> bitnami/kubectl:$KUBECTL_TAG"
docker tag "bitnami/kubectl:latest" "bitnami/kubectl:$KUBECTL_TAG"

echo ">>> Pulling busybox:$BUSYBOX_TAG"
docker pull "busybox:$BUSYBOX_TAG"

echo ">>> Saving images to $TAR_FILE"
docker save "busybox:$BUSYBOX_TAG" "bitnami/kubectl:$KUBECTL_TAG" -o "$TAR_FILE"

SIZE=$(du -h "$TAR_FILE" | cut -f1)
echo ">>> Done: $SIZE  $TAR_FILE"
echo ">>> Bundled: busybox:$BUSYBOX_TAG  bitnami/kubectl:$KUBECTL_TAG"
