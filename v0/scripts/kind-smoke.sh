#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
V0_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

KIND_CLUSTER="${KIND_CLUSTER:-kb-smoke}"
CREATED_CLUSTER=false

echo "=== kind-smoke: kube-burner v0 harness smoke test ==="

# ------------------------------------------------------------------
# 1. Kind cluster
# ------------------------------------------------------------------
if ! command -v kind &>/dev/null; then
  echo "ERROR: 'kind' not found in PATH"; exit 1
fi

if ! kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
  echo ">>> Creating kind cluster: $KIND_CLUSTER"
  kind create cluster --name "$KIND_CLUSTER" --wait 120s
  CREATED_CLUSTER=true
else
  echo ">>> Reusing existing kind cluster: $KIND_CLUSTER"
fi

cleanup_cluster() {
  if [ "$CREATED_CLUSTER" = "true" ]; then
    echo ">>> Deleting kind cluster $KIND_CLUSTER"
    kind delete cluster --name "$KIND_CLUSTER" 2>/dev/null || true
  fi
}
trap cleanup_cluster EXIT

# Point kubectl at the kind cluster
kind export kubeconfig --name "$KIND_CLUSTER"

echo ">>> Waiting for node to be Ready"
kubectl wait --for=condition=Ready node --all --timeout=60s

# ------------------------------------------------------------------
# 1b. Pre-load bundled images into Kind cluster
# ------------------------------------------------------------------
IMAGES_TAR="$V0_DIR/images/harness-images.tar"
if [ -f "$IMAGES_TAR" ]; then
  echo ">>> Pre-loading bundled images into Kind cluster"
  kind load image-archive "$IMAGES_TAR" --name "$KIND_CLUSTER"
fi

# ------------------------------------------------------------------
# 2. Run harness with small values and disk OFF
# (run.sh resolves the kube-burner binary automatically)
# ------------------------------------------------------------------
echo ">>> Running harness with smoke-test parameters"
export BASELINE_PROBE_DURATION=10
export BASELINE_PROBE_INTERVAL=2
export RAMP_STEPS=1
export RAMP_CPU_REPLICAS=1
export RAMP_CPU_MILLICORES=50
export RAMP_MEM_REPLICAS=1
export RAMP_MEM_MB=32
export RECOVERY_PROBE_DURATION=10
export RECOVERY_PROBE_INTERVAL=2
export KB_TIMEOUT=3m
export SKIP_LOG_FILE=true
export SKIP_IMAGE_LOAD=1
export NONINTERACTIVE=1

SMOKE_RC=0
bash "$V0_DIR/run.sh" || SMOKE_RC=$?

# ------------------------------------------------------------------
# 3. Find the latest run directory
# ------------------------------------------------------------------
LATEST_RUN=$(ls -td "$V0_DIR/runs/"*/ 2>/dev/null | head -1)
if [ -z "$LATEST_RUN" ]; then
  echo "FAIL: no run directory created"
  exit 1
fi
echo ">>> Verifying artifacts in $LATEST_RUN"

# ------------------------------------------------------------------
# 4. Assertions
# ------------------------------------------------------------------
FAILURES=0

assert() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS: $desc"
  else
    echo "  FAIL: $desc"
    FAILURES=$((FAILURES + 1))
  fi
}

assert "probe.jsonl exists and is non-empty" test -s "${LATEST_RUN}probe.jsonl"
assert "phases.jsonl exists" test -s "${LATEST_RUN}phases.jsonl"
assert "summary.csv exists" test -s "${LATEST_RUN}summary.csv"
assert "kb-version.txt exists" test -s "${LATEST_RUN}kb-version.txt"

assert "baseline phase present in phases.jsonl" \
  grep -q '"phase":"baseline"' "${LATEST_RUN}phases.jsonl"
assert "ramp-step-1 phase present" \
  grep -q '"phase":"ramp-step-1"' "${LATEST_RUN}phases.jsonl"
assert "teardown phase present" \
  grep -q '"phase":"teardown"' "${LATEST_RUN}phases.jsonl"
assert "recovery phase present" \
  grep -q '"phase":"recovery"' "${LATEST_RUN}phases.jsonl"

assert "probe.jsonl has baseline entries" \
  grep -q '"phase":"baseline"' "${LATEST_RUN}probe.jsonl"
assert "probe.jsonl has ramp-step-1 entries" \
  grep -q '"phase":"ramp-step-1"' "${LATEST_RUN}probe.jsonl"
assert "probe.jsonl has recovery entries" \
  grep -q '"phase":"recovery"' "${LATEST_RUN}probe.jsonl"

# Check for YAML decode errors (strict mode violations)
assert "no 'not found in type' errors in logs" \
  bash -c "! grep -r 'not found in type' ${LATEST_RUN}phase-*.log 2>/dev/null"
assert "no 'unknown field' errors in logs" \
  bash -c "! grep -ri 'unknown field' ${LATEST_RUN}phase-*.log 2>/dev/null"

echo ""
echo "=== SMOKE TEST RESULTS ==="
echo "  harness exit code: $SMOKE_RC"
echo "  assertion failures: $FAILURES"
if [ "$FAILURES" -gt 0 ] || [ "$SMOKE_RC" -ne 0 ]; then
  echo "  VERDICT: FAIL"
  exit 1
fi
echo "  VERDICT: PASS"
