#!/usr/bin/env bash
set -uo pipefail

V0_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$V0_DIR/config.yaml}"

KB_REQUIRED_VERSION="v2.4.0"

resolve_kb() {
  # 1) Explicit override
  if [ -n "${KB_BIN:-}" ] && [ -x "$KB_BIN" ]; then
    if [ "${KB_ALLOW_ANY:-0}" != "1" ]; then
      if ! "$KB_BIN" version 2>&1 | grep -q "${KB_REQUIRED_VERSION#v}"; then
        echo "ERROR: KB_BIN ($KB_BIN) does not report $KB_REQUIRED_VERSION:"
        "$KB_BIN" version 2>&1 | head -5
        echo "Set KB_ALLOW_ANY=1 to accept any version, or point KB_BIN to a $KB_REQUIRED_VERSION binary."
        exit 1
      fi
    fi
    echo ">>> Using KB_BIN from environment: $KB_BIN"
    KB="$KB_BIN"
    return 0
  fi

  # 2) System kube-burner matching required version
  if command -v kube-burner &>/dev/null; then
    if kube-burner version 2>&1 | grep -q "${KB_REQUIRED_VERSION#v}"; then
      KB="$(command -v kube-burner)"
      echo ">>> Using system kube-burner ($KB_REQUIRED_VERSION): $KB"
      return 0
    fi
  fi

  # 3) Local binary, install if missing
  KB="$V0_DIR/bin/kube-burner"
  if [ ! -x "$KB" ]; then
    echo ">>> kube-burner not found — installing $KB_REQUIRED_VERSION"
    bash "$V0_DIR/scripts/install-kube-burner.sh"
  fi

  if [ ! -x "$KB" ]; then
    echo "ERROR: kube-burner binary not available at $KB"
    echo "Set KB_BIN to a local kube-burner path and re-run."
    exit 1
  fi
  echo ">>> Using local kube-burner: $KB"
}

resolve_kb
cd "$V0_DIR"

# ---------------------------------------------------------------------------
# Parse flat config.yaml into uppercased env vars (only if not already set)
# ---------------------------------------------------------------------------
parse_config() {
  local file="$1"
  [ -f "$file" ] || return 0
  while IFS='' read -r line; do
    line="${line%%#*}"                       # strip comments
    [[ -z "$line" || ! "$line" =~ : ]] && continue
    key="${line%%:*}"; key="${key// /}"
    val="${line#*:}";  val="${val# }"; val="${val% }"
    key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
    # only set if not already exported
    if [ -z "${!key+x}" ]; then
      export "$key=$val"
    fi
  done < "$file"
}

parse_config "$CONFIG_FILE"

# ---------------------------------------------------------------------------
# Defaults (overridable by config.yaml or environment)
# ---------------------------------------------------------------------------
BASELINE_PROBE_DURATION="${BASELINE_PROBE_DURATION:-10}"
BASELINE_PROBE_INTERVAL="${BASELINE_PROBE_INTERVAL:-2}"
RAMP_STEPS="${RAMP_STEPS:-2}"
RAMP_CPU_REPLICAS="${RAMP_CPU_REPLICAS:-1}"
RAMP_CPU_MILLICORES="${RAMP_CPU_MILLICORES:-50}"
RAMP_MEM_REPLICAS="${RAMP_MEM_REPLICAS:-1}"
RAMP_MEM_MB="${RAMP_MEM_MB:-32}"
RECOVERY_PROBE_DURATION="${RECOVERY_PROBE_DURATION:-10}"
RECOVERY_PROBE_INTERVAL="${RECOVERY_PROBE_INTERVAL:-2}"
RAMP_PROBE_DURATION="${RAMP_PROBE_DURATION:-10}"
RAMP_PROBE_INTERVAL="${RAMP_PROBE_INTERVAL:-2}"
KB_TIMEOUT="${KB_TIMEOUT:-5m}"
SKIP_LOG_FILE="${SKIP_LOG_FILE:-true}"
PROBE_READYZ="${PROBE_READYZ:-1}"

# ---------------------------------------------------------------------------
# Contention mode defaults
# ---------------------------------------------------------------------------
MODE_CPU="${MODE_CPU:-on}"
MODE_MEM="${MODE_MEM:-on}"
MODE_DISK="${MODE_DISK:-off}"
MODE_NETWORK="${MODE_NETWORK:-off}"
RAMP_DISK_REPLICAS="${RAMP_DISK_REPLICAS:-1}"
RAMP_DISK_MB="${RAMP_DISK_MB:-64}"
RAMP_NET_REPLICAS="${RAMP_NET_REPLICAS:-1}"
RAMP_NET_TARGET="${RAMP_NET_TARGET:-kubernetes.default.svc}"
RAMP_NET_INTERVAL="${RAMP_NET_INTERVAL:-0.5}"

# ---------------------------------------------------------------------------
# CLI flags (-i interactive, -c config prompts, -r registry prompts)
# ---------------------------------------------------------------------------
PROMPT_MODES=false
PROMPT_REGISTRY=false

while getopts "icrh" opt; do
  case "$opt" in
    i) PROMPT_MODES=true; PROMPT_REGISTRY=true ;;
    c) PROMPT_MODES=true ;;
    r) PROMPT_REGISTRY=true ;;
    h) echo "Usage: run.sh [-i] [-c] [-r]"
       echo "  -i  Interactive (prompt for everything)"
       echo "  -c  Prompt for contention mode selection/settings"
       echo "  -r  Prompt for image registry redirect and pull secret"
       echo "  Default: non-interactive, uses config.yaml / env var defaults"
       exit 0 ;;
    *) echo "Usage: run.sh [-i] [-c] [-r] [-h]" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

# Backward compat: NONINTERACTIVE=1 forces non-interactive regardless of flags
if [ "${NONINTERACTIVE:-0}" = "1" ]; then
  PROMPT_MODES=false
  PROMPT_REGISTRY=false
fi

# ---------------------------------------------------------------------------
# Interactive helpers
# ---------------------------------------------------------------------------
prompt_yn() {
  local prompt="$1" default="${2:-y}" answer=""
  printf '%s ' "$prompt" >/dev/tty 2>/dev/null || true
  read -r answer </dev/tty 2>/dev/null || answer=""
  case "${answer:-$default}" in
    [nN]|[nN][oO]) return 1 ;;
    *) return 0 ;;
  esac
}

prompt_value() {
  local prompt="$1" default="$2" answer=""
  printf '%s [%s]: ' "$prompt" "$default" >/dev/tty 2>/dev/null || true
  read -r answer </dev/tty 2>/dev/null || answer=""
  echo "${answer:-$default}"
}

# ---------------------------------------------------------------------------
# Contention mode selection (interactive or non-interactive defaults)
# ---------------------------------------------------------------------------
setup_contention_modes() {
  if [ "$PROMPT_MODES" = "true" ]; then
    echo ""
    echo ">>> Contention mode selection"

    if prompt_yn "Enable cpu contention? [Y/n]"; then
      MODE_CPU="on"
      if prompt_yn "Edit cpu settings for this run? [Y/n]"; then
        RAMP_CPU_REPLICAS="$(prompt_value '  CPU replicas per step' "$RAMP_CPU_REPLICAS")"
        RAMP_CPU_MILLICORES="$(prompt_value '  CPU millicores per pod' "$RAMP_CPU_MILLICORES")"
      fi
    else
      MODE_CPU="off"
    fi

    if prompt_yn "Enable mem contention? [Y/n]"; then
      MODE_MEM="on"
      if prompt_yn "Edit mem settings for this run? [Y/n]"; then
        RAMP_MEM_REPLICAS="$(prompt_value '  MEM replicas per step' "$RAMP_MEM_REPLICAS")"
        RAMP_MEM_MB="$(prompt_value '  MEM MB per pod' "$RAMP_MEM_MB")"
      fi
    else
      MODE_MEM="off"
    fi

    if prompt_yn "Enable disk contention? [Y/n]"; then
      MODE_DISK="on"
      if prompt_yn "Edit disk settings for this run? [Y/n]"; then
        RAMP_DISK_REPLICAS="$(prompt_value '  DISK replicas per step' "$RAMP_DISK_REPLICAS")"
        RAMP_DISK_MB="$(prompt_value '  DISK MB to write per pod' "$RAMP_DISK_MB")"
      fi
    else
      MODE_DISK="off"
    fi

    if prompt_yn "Enable network contention? [Y/n]"; then
      MODE_NETWORK="on"
      if prompt_yn "Edit network settings for this run? [Y/n]"; then
        RAMP_NET_REPLICAS="$(prompt_value '  NET replicas per step' "$RAMP_NET_REPLICAS")"
        RAMP_NET_TARGET="$(prompt_value '  NET target host' "$RAMP_NET_TARGET")"
        RAMP_NET_INTERVAL="$(prompt_value '  NET request interval (seconds)' "$RAMP_NET_INTERVAL")"
      fi
    else
      MODE_NETWORK="off"
    fi
  fi

  # --- Persist configuration ---
  cat > "$RUN_DIR/modes.env" <<EOF
MODE_CPU=$MODE_CPU
MODE_MEM=$MODE_MEM
MODE_DISK=$MODE_DISK
MODE_NETWORK=$MODE_NETWORK
RAMP_CPU_REPLICAS=$RAMP_CPU_REPLICAS
RAMP_CPU_MILLICORES=$RAMP_CPU_MILLICORES
RAMP_MEM_REPLICAS=$RAMP_MEM_REPLICAS
RAMP_MEM_MB=$RAMP_MEM_MB
RAMP_DISK_REPLICAS=$RAMP_DISK_REPLICAS
RAMP_DISK_MB=$RAMP_DISK_MB
RAMP_NET_REPLICAS=$RAMP_NET_REPLICAS
RAMP_NET_TARGET=$RAMP_NET_TARGET
RAMP_NET_INTERVAL=$RAMP_NET_INTERVAL
EOF

  local cpu_en mem_en disk_en net_en
  [ "$MODE_CPU" = "on" ] && cpu_en=true || cpu_en=false
  [ "$MODE_MEM" = "on" ] && mem_en=true || mem_en=false
  [ "$MODE_DISK" = "on" ] && disk_en=true || disk_en=false
  [ "$MODE_NETWORK" = "on" ] && net_en=true || net_en=false

  cat > "$RUN_DIR/modes.json" <<EOF
{
  "modes": {
    "cpu":     {"enabled": $cpu_en, "replicas": $RAMP_CPU_REPLICAS, "millicores": $RAMP_CPU_MILLICORES},
    "mem":     {"enabled": $mem_en, "replicas": $RAMP_MEM_REPLICAS, "memMb": $RAMP_MEM_MB},
    "disk":    {"enabled": $disk_en, "replicas": $RAMP_DISK_REPLICAS, "diskMb": $RAMP_DISK_MB},
    "network": {"enabled": $net_en, "replicas": $RAMP_NET_REPLICAS, "target": "$RAMP_NET_TARGET", "intervalSec": "$RAMP_NET_INTERVAL"}
  }
}
EOF

  echo ""
  echo ">>> Contention modes:"
  printf "    cpu     = %-3s  (replicas=%s, millicores=%s)\n" "$MODE_CPU" "$RAMP_CPU_REPLICAS" "$RAMP_CPU_MILLICORES"
  printf "    mem     = %-3s  (replicas=%s, mb=%s)\n" "$MODE_MEM" "$RAMP_MEM_REPLICAS" "$RAMP_MEM_MB"
  printf "    disk    = %-3s  (replicas=%s, mb=%s)\n" "$MODE_DISK" "$RAMP_DISK_REPLICAS" "$RAMP_DISK_MB"
  printf "    network = %-3s  (replicas=%s, target=%s, interval=%ss)\n" "$MODE_NETWORK" "$RAMP_NET_REPLICAS" "$RAMP_NET_TARGET" "$RAMP_NET_INTERVAL"
}

# ---------------------------------------------------------------------------
# Staging: copy templates/workloads for this run
# ---------------------------------------------------------------------------
ensure_staging() {
  local staging="$RUN_DIR/staging"
  if [ ! -d "$staging/templates" ]; then
    mkdir -p "$staging"
    cp -r "$V0_DIR/templates" "$staging/"
    cp -r "$V0_DIR/workloads" "$staging/"
    cp -r "$V0_DIR/manifests" "$staging/"
  fi
  WORK_DIR="$staging"
  echo ">>> Staging directory: $WORK_DIR"
}

# ---------------------------------------------------------------------------
# Generate ramp-step.yaml with only enabled contention modes
# ---------------------------------------------------------------------------
generate_ramp_step() {
  local out="$WORK_DIR/workloads/ramp-step.yaml"
  local has_stress=false
  [[ "$MODE_CPU" = "on" || "$MODE_MEM" = "on" || "$MODE_DISK" = "on" || "$MODE_NETWORK" = "on" ]] && has_stress=true

  cat > "$out" <<'YAML'
global:
  gc: false
jobs:
YAML

  if [ "$has_stress" = "true" ]; then
    cat >> "$out" <<'YAML'
  - name: "ramp-step-{{.STEP}}"
    jobType: create
    jobIterations: 1
    namespace: "kb-stress-{{.STEP}}"
    namespacedIterations: false
    cleanup: false
    waitWhenFinished: true
    maxWaitTimeout: 2m
    preLoadImages: false
    verifyObjects: true
    errorOnVerify: false
    objects:
YAML

    [ "$MODE_CPU" = "on" ] && cat >> "$out" <<'YAML'
      - objectTemplate: templates/cpu-stress.yaml
        replicas: 1
        inputVars:
          step: "{{.STEP}}"
          millicores: "{{.CPU_MILLICORES}}"
          podReplicas: "{{.CPU_REPLICAS}}"
YAML

    [ "$MODE_MEM" = "on" ] && cat >> "$out" <<'YAML'
      - objectTemplate: templates/mem-stress.yaml
        replicas: 1
        inputVars:
          step: "{{.STEP}}"
          memMb: "{{.MEM_MB}}"
          podReplicas: "{{.MEM_REPLICAS}}"
YAML

    [ "$MODE_DISK" = "on" ] && cat >> "$out" <<'YAML'
      - objectTemplate: templates/disk-stress.yaml
        replicas: 1
        inputVars:
          step: "{{.STEP}}"
          diskMb: "{{.DISK_MB}}"
          podReplicas: "{{.DISK_REPLICAS}}"
YAML

    [ "$MODE_NETWORK" = "on" ] && cat >> "$out" <<'YAML'
      - objectTemplate: templates/net-stress.yaml
        replicas: 1
        inputVars:
          step: "{{.STEP}}"
          targetHost: "{{.NET_TARGET}}"
          netInterval: "{{.NET_INTERVAL}}"
          podReplicas: "{{.NET_REPLICAS}}"
YAML
  fi

  cat >> "$out" <<'YAML'
  - name: "probe-ramp-step-{{.STEP}}"
    jobType: create
    jobIterations: 1
    namespacedIterations: false
    cleanup: true
    waitWhenFinished: true
    maxWaitTimeout: 3m
    preLoadImages: false
    verifyObjects: true
    errorOnVerify: false
    objects:
      - objectTemplate: templates/probe-job.yaml
        replicas: 1
        inputVars:
          phase: "ramp-step-{{.STEP}}"
          duration: "{{.RAMP_PROBE_DURATION}}"
          interval: "{{.RAMP_PROBE_INTERVAL}}"
          probeReadyz: "{{.PROBE_READYZ}}"
YAML
}

# ---------------------------------------------------------------------------
# Image registry redirect (split: collect decisions, then apply to staging)
# ---------------------------------------------------------------------------
WORK_DIR="$V0_DIR"
IMAGE_MAP_ORIG=()
IMAGE_MAP_REPL=()
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-}"

collect_image_redirects() {
  local img_list=()
  local seen=""

  while IFS= read -r line; do
    local img
    img=$(echo "$line" | sed 's/^[[:space:]]*image:[[:space:]]*//' | sed "s/^[\"']//;s/[\"']$//" | sed 's/[[:space:]]*$//')
    [[ -z "$img" ]] && continue
    case "$seen" in *"|${img}|"*) continue ;; esac
    seen="${seen}|${img}|"
    img_list+=("$img")
  done < <(grep -h 'image:' "$V0_DIR"/templates/*.yaml "$V0_DIR"/manifests/*.yaml 2>/dev/null || true)

  if [ ${#img_list[@]} -eq 0 ]; then
    return 0
  fi

  echo ">>> Images detected:"
  for img in "${img_list[@]}"; do echo "    $img"; done

  if [ -n "${IMAGE_MAP_FILE:-}" ] && [ -f "${IMAGE_MAP_FILE:-}" ]; then
    echo ">>> Loading image map from $IMAGE_MAP_FILE"
    while IFS='=' read -r orig repl; do
      orig=$(echo "$orig" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      repl=$(echo "$repl" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ -z "$orig" || -z "$repl" || "$orig" = \#* ]] && continue
      IMAGE_MAP_ORIG+=("$orig")
      IMAGE_MAP_REPL+=("$repl")
    done < "$IMAGE_MAP_FILE"
  elif [ "$PROMPT_REGISTRY" = "true" ]; then
    for img in "${img_list[@]}"; do
      if prompt_yn "Redirect image registry for '${img}'? [y/N]" "n"; then
        local replacement=""
        printf '  Enter replacement (full image ref OR registry host): ' >/dev/tty 2>/dev/null || true
        read -r replacement </dev/tty 2>/dev/null || replacement=""
        [[ -z "$replacement" ]] && continue
        replacement="${replacement%/}"
        if [[ "$replacement" == */* ]]; then
          IMAGE_MAP_ORIG+=("$img")
          IMAGE_MAP_REPL+=("$replacement")
        else
          IMAGE_MAP_ORIG+=("$img")
          IMAGE_MAP_REPL+=("${replacement}/${img}")
        fi
      fi
    done
  fi

  if [ ${#IMAGE_MAP_ORIG[@]} -gt 0 ] && [ -z "$IMAGE_PULL_SECRET" ] && [ "$PROMPT_REGISTRY" = "true" ]; then
    printf 'Image pull secret name (leave empty for none): ' >/dev/tty 2>/dev/null || true
    read -r IMAGE_PULL_SECRET </dev/tty 2>/dev/null || IMAGE_PULL_SECRET=""
  fi
}

apply_image_redirects() {
  if [ ${#IMAGE_MAP_ORIG[@]} -eq 0 ]; then
    echo "(no rewrites)" > "$RUN_DIR/image-map.txt"
    echo ">>> No image rewrites."
    return 0
  fi

  echo ">>> Image rewrites:"
  local i
  for i in $(seq 0 $((${#IMAGE_MAP_ORIG[@]} - 1))); do
    echo "    ${IMAGE_MAP_ORIG[$i]} -> ${IMAGE_MAP_REPL[$i]}"
    echo "${IMAGE_MAP_ORIG[$i]}=${IMAGE_MAP_REPL[$i]}" >> "$RUN_DIR/image-map.txt"
  done

  for i in $(seq 0 $((${#IMAGE_MAP_ORIG[@]} - 1))); do
    local orig="${IMAGE_MAP_ORIG[$i]}"
    local repl="${IMAGE_MAP_REPL[$i]}"
    local orig_esc
    orig_esc=$(printf '%s' "$orig" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
    while IFS= read -r f; do
      sed "s|${orig_esc}|${repl}|g" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
    done < <(find "$WORK_DIR" -name '*.yaml' -type f)
  done

  echo ">>> Image rewrites applied to staging."
}

# ---------------------------------------------------------------------------
# Inject imagePullSecrets into staged templates
# ---------------------------------------------------------------------------
apply_image_pull_secret() {
  [ -z "${IMAGE_PULL_SECRET:-}" ] && return 0
  echo ">>> Injecting imagePullSecrets: $IMAGE_PULL_SECRET"
  while IFS= read -r f; do
    awk -v secret="$IMAGE_PULL_SECRET" '
      /^[[:space:]]*containers:/ {
        match($0, /^[[:space:]]*/);
        indent = substr($0, RSTART, RLENGTH);
        printf "%s%s\n", indent, "imagePullSecrets:";
        printf "%s  - name: %s\n", indent, secret;
      }
      { print }
    ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
  done < <(find "$WORK_DIR/templates" -name '*.yaml' -type f)
  echo "IMAGE_PULL_SECRET=$IMAGE_PULL_SECRET" >> "$RUN_DIR/modes.env"
}

# ---------------------------------------------------------------------------
# Run directory — all artifacts land here
# ---------------------------------------------------------------------------
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RUN_DIR:-$V0_DIR/runs/$RUN_ID}"
mkdir -p "$RUN_DIR"
echo ">>> Run artifacts: $RUN_DIR"

setup_contention_modes
collect_image_redirects
ensure_staging
generate_ramp_step
apply_image_redirects
apply_image_pull_secret
cd "$WORK_DIR"

MAIN_RC=0

# ---------------------------------------------------------------------------
# Artifact salvage — ALWAYS runs, even on failure
# ---------------------------------------------------------------------------
collect_artifacts() {
  echo ">>> Collecting artifacts into $RUN_DIR"
  # kube-burner log files
  for f in "$V0_DIR"/kube-burner-*.log; do
    [ -f "$f" ] && mv "$f" "$RUN_DIR/" 2>/dev/null || true
  done
  # collected-metrics dirs
  if [ -d "$V0_DIR/collected-metrics" ]; then
    mv "$V0_DIR/collected-metrics" "$RUN_DIR/" 2>/dev/null || true
  fi
  # generate summary
  bash "$V0_DIR/scripts/summarize.sh" "$RUN_DIR" 2>/dev/null || true
  echo ">>> Artifacts collected. main_rc=$MAIN_RC"
}
trap collect_artifacts EXIT

# ---------------------------------------------------------------------------
# Log kube-burner binary path and version
# ---------------------------------------------------------------------------
{
  echo "binary: $KB"
  "$KB" version 2>&1
} > "$RUN_DIR/kb-version.txt"
echo ">>> kube-burner version:"
cat "$RUN_DIR/kb-version.txt"

# ---------------------------------------------------------------------------
# Helper: record a phase result into phases.jsonl
# ---------------------------------------------------------------------------
record_phase() {
  local phase="$1" uuid="$2" rc="$3" start="$4" end_t="$5"
  local elapsed=$((end_t - start))
  printf '{"phase":"%s","uuid":"%s","rc":%d,"start":%d,"end":%d,"elapsed_s":%d}\n' \
    "$phase" "$uuid" "$rc" "$start" "$end_t" "$elapsed" \
    >> "$RUN_DIR/phases.jsonl"
}

# ---------------------------------------------------------------------------
# Helper: collect probe pod logs → probe.jsonl
# ---------------------------------------------------------------------------
collect_probe_logs() {
  local phase="$1"
  local job_name="probe-${phase}"
  echo ">>> Collecting probe logs for phase=$phase job=$job_name"
  kubectl logs -n kb-probe "job/${job_name}" --tail=-1 \
    >> "$RUN_DIR/probe.jsonl" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: run a probe phase via kube-burner
# ---------------------------------------------------------------------------
run_probe() {
  local phase="$1" duration="$2" interval="$3"
  local uuid
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')
  local start_ts rc
  start_ts=$(date +%s)

  echo ""
  echo "========================================"
  echo "  PROBE: $phase  (${duration}s every ${interval}s)"
  echo "========================================"

  local kb_flags=()
  kb_flags+=(-c "$WORK_DIR/workloads/probe.yaml")
  kb_flags+=(--uuid "$uuid")
  kb_flags+=(--timeout "$KB_TIMEOUT")
  if [ "$SKIP_LOG_FILE" = "true" ]; then
    kb_flags+=(--skip-log-file)
  fi

  export PHASE="$phase"
  export PROBE_DURATION="$duration"
  export PROBE_INTERVAL="$interval"
  export PROBE_READYZ

  rc=0
  "$KB" init "${kb_flags[@]}" 2>&1 | tee "$RUN_DIR/phase-${phase}.log" || rc=$?

  local end_ts
  end_ts=$(date +%s)
  record_phase "$phase" "$uuid" "$rc" "$start_ts" "$end_ts"
  collect_probe_logs "$phase"
  return $rc
}

# ---------------------------------------------------------------------------
# Helper: run a ramp step via kube-burner
# ---------------------------------------------------------------------------
run_ramp_step() {
  local step="$1"
  local uuid
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')
  local start_ts rc
  start_ts=$(date +%s)

  echo ""
  echo "========================================"
  echo "  RAMP STEP $step"
  echo "========================================"

  local kb_flags=()
  kb_flags+=(-c "$WORK_DIR/workloads/ramp-step.yaml")
  kb_flags+=(--uuid "$uuid")
  kb_flags+=(--timeout "$KB_TIMEOUT")
  if [ "$SKIP_LOG_FILE" = "true" ]; then
    kb_flags+=(--skip-log-file)
  fi

  export STEP="$step"
  export CPU_MILLICORES="$RAMP_CPU_MILLICORES"
  export CPU_REPLICAS="$RAMP_CPU_REPLICAS"
  export MEM_MB="$RAMP_MEM_MB"
  export MEM_REPLICAS="$RAMP_MEM_REPLICAS"
  export DISK_MB="$RAMP_DISK_MB"
  export DISK_REPLICAS="$RAMP_DISK_REPLICAS"
  export NET_TARGET="$RAMP_NET_TARGET"
  export NET_REPLICAS="$RAMP_NET_REPLICAS"
  export NET_INTERVAL="$RAMP_NET_INTERVAL"
  export RAMP_PROBE_DURATION
  export RAMP_PROBE_INTERVAL
  export PROBE_READYZ

  rc=0
  "$KB" init "${kb_flags[@]}" 2>&1 | tee "$RUN_DIR/phase-ramp-step-${step}.log" || rc=$?

  local end_ts
  end_ts=$(date +%s)
  record_phase "ramp-step-${step}" "$uuid" "$rc" "$start_ts" "$end_ts"
  collect_probe_logs "ramp-step-${step}"
  return $rc
}

# ---------------------------------------------------------------------------
# Helper: teardown stress namespaces
# ---------------------------------------------------------------------------
teardown_stress() {
  echo ""
  echo "========================================"
  echo "  TEARDOWN"
  echo "========================================"
  local start_ts rc=0
  start_ts=$(date +%s)

  for i in $(seq 1 "$RAMP_STEPS"); do
    echo ">>> Deleting namespace kb-stress-$i"
    kubectl delete ns "kb-stress-$i" --ignore-not-found --wait=true --timeout=120s 2>&1 || true
  done

  local end_ts
  end_ts=$(date +%s)
  record_phase "teardown" "n/a" "$rc" "$start_ts" "$end_ts"
}

# ===========================================================================
#  MAIN SEQUENCE
# ===========================================================================
# ---------------------------------------------------------------------------
# Pre-load bundled images (skip if -r / IMAGE_MAP_FILE / SKIP_IMAGE_LOAD)
# ---------------------------------------------------------------------------
IMAGES_TAR="$V0_DIR/images/harness-images.tar"
if [ -f "$IMAGES_TAR" ] \
   && [ "$PROMPT_REGISTRY" = "false" ] \
   && [ -z "${IMAGE_MAP_FILE:-}" ] \
   && [ "${SKIP_IMAGE_LOAD:-0}" != "1" ]; then
  echo ">>> Loading bundled images from $IMAGES_TAR"
  bash "$V0_DIR/scripts/load-images.sh" "$IMAGES_TAR" || {
    echo "WARN: image load failed; pods will attempt registry pull"
  }
else
  if [ ! -f "$IMAGES_TAR" ]; then
    echo ">>> No bundled image archive found; pods will pull from registry"
  else
    echo ">>> Skipping bundled image load (registry redirect active or SKIP_IMAGE_LOAD=1)"
  fi
fi

echo ">>> Setting up RBAC for probes"
kubectl apply -f "$WORK_DIR/manifests/probe-rbac.yaml"

# --- BASELINE ---
run_probe "baseline" "$BASELINE_PROBE_DURATION" "$BASELINE_PROBE_INTERVAL" || MAIN_RC=1

# --- RAMP STEPS ---
for step in $(seq 1 "$RAMP_STEPS"); do
  run_ramp_step "$step" || MAIN_RC=1
done

# --- TEARDOWN (always, even if ramp failed) ---
teardown_stress || true

# --- RECOVERY ---
run_probe "recovery" "$RECOVERY_PROBE_DURATION" "$RECOVERY_PROBE_INTERVAL" || MAIN_RC=1

echo ""
echo "========================================"
if [ "$MAIN_RC" -eq 0 ]; then
  echo "  ALL PHASES PASSED"
else
  echo "  ONE OR MORE PHASES FAILED (rc=$MAIN_RC)"
fi
echo "  Artifacts: $RUN_DIR"
echo "========================================"

exit "$MAIN_RC"
