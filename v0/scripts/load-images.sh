#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
V0_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TAR_FILE="${1:-$V0_DIR/images/harness-images.tar}"

if [ ! -f "$TAR_FILE" ]; then
  echo "ERROR: image archive not found: $TAR_FILE"
  echo "Run scripts/save-images.sh to create it."
  exit 1
fi

CONTEXT="$(kubectl config current-context 2>/dev/null || true)"

if [[ "$CONTEXT" == kind-* ]]; then
  CLUSTER_NAME="${CONTEXT#kind-}"
  echo ">>> Loading images into Kind cluster: $CLUSTER_NAME"
  kind load image-archive "$TAR_FILE" --name "$CLUSTER_NAME"
elif command -v k3d &>/dev/null && k3d cluster list 2>/dev/null | grep -q .; then
  echo ">>> Loading images into k3d cluster"
  k3d image import "$TAR_FILE"
else
  echo ">>> Loading images via docker load"
  docker load < "$TAR_FILE"
  echo "NOTE: For remote clusters (EKS/GKE/AKS), images must be in a"
  echo "reachable registry. Use -r to redirect images to your registry."
fi
