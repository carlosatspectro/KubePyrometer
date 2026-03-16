#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: analyze.sh <run-dir>}"
RUN_DIR="${RUN_DIR%/}"

if [ ! -d "$RUN_DIR" ]; then
  echo "ERROR: directory not found: $RUN_DIR"
  exit 1
fi

PHASES_FILE="$RUN_DIR/phases.jsonl"
PROBE_FILE="$RUN_DIR/probe.jsonl"
FINGERPRINT_FILE="$RUN_DIR/cluster-fingerprint.txt"
SAFETY_FILE="$RUN_DIR/safety-plan.txt"

# ---------------------------------------------------------------------------
# Helpers — parse JSON fields without jq
# ---------------------------------------------------------------------------
json_str()  { sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p'; }
json_num()  { sed -n 's/.*"'"$1"'":\([0-9-]*\).*/\1/p'; }

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

divider() { echo "────────────────────────────────────────────────────────"; }

# ---------------------------------------------------------------------------
# 1) Run overview
# ---------------------------------------------------------------------------
section_overview() {
  bold "RUN OVERVIEW"
  divider

  echo "  Directory:  $RUN_DIR"

  if [ -f "$FINGERPRINT_FILE" ]; then
    local ctx
    ctx=$(grep '^Context:' "$FINGERPRINT_FILE" 2>/dev/null | head -1 | sed 's/^Context: *//' || echo "unknown")
    echo "  Cluster:    $ctx"

    local node_count
    node_count=$(grep -c 'node/' "$FINGERPRINT_FILE" 2>/dev/null || true)
    [ -z "$node_count" ] || [ "$node_count" = "0" ] && \
      node_count=$(grep '^Nodes:' "$FINGERPRINT_FILE" 2>/dev/null | head -1 | sed 's/^Nodes: *//' || echo "?")
    echo "  Nodes:      $node_count"

    local k8s_ver
    k8s_ver=$(grep -i 'server version' "$FINGERPRINT_FILE" 2>/dev/null | head -1 | sed 's/.*: *//' || echo "?")
    [ -n "$k8s_ver" ] && echo "  K8s:        $k8s_ver"
  fi

  if [ -f "$PHASES_FILE" ]; then
    local phase_count total_elapsed first_start last_end
    phase_count=$(wc -l < "$PHASES_FILE" | tr -d ' ')

    first_start=$(head -1 "$PHASES_FILE" | json_num start)
    last_end=$(tail -1 "$PHASES_FILE" | json_num end)
    if [ -n "$first_start" ] && [ -n "$last_end" ]; then
      total_elapsed=$((last_end - first_start))
      local mins=$((total_elapsed / 60))
      local secs=$((total_elapsed % 60))
      echo "  Phases:     $phase_count"
      echo "  Duration:   ${mins}m ${secs}s"
    fi

    local fail_count
    fail_count=$(grep -c '"rc":[1-9]' "$PHASES_FILE" 2>/dev/null || true)
    fail_count="${fail_count:-0}"
    if [ "$fail_count" = "0" ]; then
      green "  Verdict:    ALL PHASES PASSED"
    else
      red "  Verdict:    $fail_count PHASE(S) FAILED"
    fi
  else
    red "  No phases.jsonl found — incomplete run"
  fi

  echo ""
}

# ---------------------------------------------------------------------------
# 2) Phase-by-phase breakdown
# ---------------------------------------------------------------------------
section_phases() {
  [ ! -f "$PHASES_FILE" ] && return

  bold "PHASE BREAKDOWN"
  divider

  while IFS= read -r line; do
    local phase rc elapsed error
    phase=$(echo "$line" | json_str phase)
    rc=$(echo "$line" | json_num rc)
    elapsed=$(echo "$line" | json_num elapsed_s)
    error=$(echo "$line" | json_str error)

    local status_str
    if [ "$rc" = "0" ]; then
      status_str=$(green "PASS")
    else
      status_str=$(red "FAIL (rc=$rc)")
    fi

    printf '  %-22s %s  %s\n' "$phase" "${elapsed}s" "$status_str"

    if [ -n "$error" ]; then
      echo "    └─ $error"
    fi

    # Check phase log for known error patterns
    local logfile="$RUN_DIR/phase-${phase}.log"
    if [ "$rc" != "0" ] && [ -f "$logfile" ]; then
      if grep -q "timeout reached" "$logfile" 2>/dev/null; then
        yellow "    └─ kube-burner timed out waiting for objects to become ready"
        if grep -q "ImagePull" "$logfile" 2>/dev/null || grep -q "ErrImagePull" "$logfile" 2>/dev/null; then
          yellow "    └─ image pull errors detected — check image availability"
        fi
      fi
      if grep -q "not found in type" "$logfile" 2>/dev/null; then
        yellow "    └─ YAML schema error — workload template may be incompatible with this kube-burner version"
      fi
      if grep -q "unknown field" "$logfile" 2>/dev/null; then
        yellow "    └─ unknown field in workload — check template compatibility"
      fi
    fi
  done < "$PHASES_FILE"

  echo ""
}

# ---------------------------------------------------------------------------
# 3) Latency analysis
# ---------------------------------------------------------------------------
compute_latency_stats() {
  local phase="$1"
  local values count min_v max_v p50_v p95_v

  values=$(grep "\"phase\":\"${phase}\"" "$PROBE_FILE" \
    | json_num latency_ms \
    | sort -n)
  count=$(echo "$values" | grep -c . 2>/dev/null || true)
  count="${count:-0}"
  [ "$count" -eq 0 ] && return 1

  min_v=$(echo "$values" | head -1)
  max_v=$(echo "$values" | tail -1)

  local p50_idx=$(( (count * 50 + 99) / 100 ))
  local p95_idx=$(( (count * 95 + 99) / 100 ))
  [ "$p50_idx" -lt 1 ] && p50_idx=1
  [ "$p95_idx" -lt 1 ] && p95_idx=1
  [ "$p50_idx" -gt "$count" ] && p50_idx="$count"
  [ "$p95_idx" -gt "$count" ] && p95_idx="$count"
  p50_v=$(echo "$values" | sed -n "${p50_idx}p")
  p95_v=$(echo "$values" | sed -n "${p95_idx}p")

  echo "$count $min_v $p50_v $p95_v $max_v"
}

section_latency() {
  [ ! -s "$PROBE_FILE" ] && return

  bold "LATENCY ANALYSIS"
  divider

  printf '  %-22s %6s %8s %8s %8s %8s\n' "phase" "count" "min" "p50" "p95" "max"
  printf '  %-22s %6s %8s %8s %8s %8s\n' "─────" "─────" "───" "───" "───" "───"

  local baseline_p50="" baseline_p95=""
  local phases
  phases=$(grep -o '"phase":"[^"]*"' "$PROBE_FILE" | sort -u | sed 's/"phase":"//;s/"//')

  for ph in $phases; do
    local stats
    stats=$(compute_latency_stats "$ph") || continue
    local count min_v p50 p95 max_v
    read -r count min_v p50 p95 max_v <<< "$stats"

    printf '  %-22s %6s %6sms %6sms %6sms %6sms\n' "$ph" "$count" "$min_v" "$p50" "$p95" "$max_v"

    if [ "$ph" = "baseline" ]; then
      baseline_p50="$p50"
      baseline_p95="$p95"
    fi
  done

  echo ""

  # Degradation analysis (compare ramp/recovery to baseline)
  if [ -n "$baseline_p50" ] && [ "$baseline_p50" -gt 0 ]; then
    bold "DEGRADATION vs BASELINE"
    divider

    for ph in $phases; do
      [ "$ph" = "baseline" ] && continue
      local stats
      stats=$(compute_latency_stats "$ph") || continue
      local count min_v p50 p95 max_v
      read -r count min_v p50 p95 max_v <<< "$stats"

      # Calculate ratio (integer math with 1 decimal via x10)
      local ratio_x10=$(( p50 * 10 / baseline_p50 ))
      local ratio_whole=$((ratio_x10 / 10))
      local ratio_frac=$((ratio_x10 % 10))
      local ratio_str="${ratio_whole}.${ratio_frac}x"

      local delta=$((p50 - baseline_p50))

      local assessment=""
      if [ "$ratio_x10" -le 12 ]; then
        assessment=$(green "nominal  (${ratio_str} baseline)")
      elif [ "$ratio_x10" -le 20 ]; then
        assessment=$(yellow "elevated (${ratio_str} baseline, +${delta}ms)")
      elif [ "$ratio_x10" -le 50 ]; then
        assessment=$(yellow "degraded (${ratio_str} baseline, +${delta}ms)")
      else
        assessment=$(red "critical (${ratio_str} baseline, +${delta}ms)")
      fi

      printf '  %-22s p50 %5sms  %s\n' "$ph" "$p50" "$assessment"
    done

    # Recovery check
    local recovery_stats
    recovery_stats=$(compute_latency_stats "recovery" 2>/dev/null) || true
    if [ -n "$recovery_stats" ]; then
      local r_count r_min r_p50 r_p95 r_max
      read -r r_count r_min r_p50 r_p95 r_max <<< "$recovery_stats"
      local recovery_ratio_x10=$(( r_p50 * 10 / baseline_p50 ))

      echo ""
      if [ "$recovery_ratio_x10" -le 12 ]; then
        green "  Recovery: cluster returned to baseline latency levels"
      elif [ "$recovery_ratio_x10" -le 20 ]; then
        yellow "  Recovery: latency slightly elevated — cluster mostly recovered"
      else
        red "  Recovery: latency still ${recovery_ratio_x10}0% of baseline — cluster did NOT fully recover"
      fi
    fi

    echo ""
  fi
}

# ---------------------------------------------------------------------------
# 4) Stress config summary
# ---------------------------------------------------------------------------
section_config() {
  [ ! -f "$SAFETY_FILE" ] && return

  bold "STRESS CONFIGURATION"
  divider

  grep -E '^\s+(cpu|mem|disk|network|api|monitor)\s' "$SAFETY_FILE" 2>/dev/null | while IFS= read -r line; do
    echo "  $line"
  done

  local max_pods
  max_pods=$(grep 'Max cumulative pods:' "$SAFETY_FILE" 2>/dev/null | sed 's/.*: *//' || true)
  [ -n "$max_pods" ] && echo "  Max cumulative pods: $max_pods"

  echo ""
}

# ---------------------------------------------------------------------------
# 5) Failure diagnosis
# ---------------------------------------------------------------------------
section_failures() {
  [ ! -f "$PHASES_FILE" ] && return
  local fail_count
  fail_count=$(grep -c '"rc":[1-9]' "$PHASES_FILE" 2>/dev/null || true)
  fail_count="${fail_count:-0}"
  [ "$fail_count" = "0" ] && return

  bold "FAILURE DIAGNOSIS"
  divider

  while IFS= read -r line; do
    local phase rc
    phase=$(echo "$line" | json_str phase)
    rc=$(echo "$line" | json_num rc)
    [ "$rc" = "0" ] && continue

    local logfile="$RUN_DIR/phase-${phase}.log"
    echo "  $phase (exit code $rc):"

    if [ ! -f "$logfile" ]; then
      echo "    No log file found"
      continue
    fi

    local diagnosed=false

    if grep -q "timeout reached" "$logfile" 2>/dev/null; then
      local timeout_val
      timeout_val=$(grep "timeout reached" "$logfile" | head -1 | grep -o '[0-9]*m[0-9]*s\|[0-9]*s' | head -1 || echo "?")
      echo "    Cause: kube-burner hit the ${timeout_val} timeout"
      diagnosed=true

      if echo "$phase" | grep -q "probe\|baseline\|recovery"; then
        echo "    Detail: the probe pod did not complete within the timeout"
        echo "    Likely: image pull failure, pod scheduling issue, or insufficient resources"
      else
        echo "    Detail: stress workload objects did not reach Ready state"
        echo "    Likely: insufficient cluster resources, image pull issues, or node pressure"
      fi
    fi

    if grep -q "not found in type\|unknown field" "$logfile" 2>/dev/null; then
      echo "    Cause: workload template YAML error"
      local bad_fields
      bad_fields=$(grep -o '"[^"]*" not found in type\|unknown field "[^"]*"' "$logfile" 2>/dev/null | head -3 || true)
      [ -n "$bad_fields" ] && echo "    Fields: $bad_fields"
      echo "    Fix: check kube-burner version compatibility with workload templates"
      diagnosed=true
    fi

    if grep -qi "forbidden\|unauthorized" "$logfile" 2>/dev/null; then
      echo "    Cause: RBAC permission denied"
      echo "    Fix: ensure probe-rbac.yaml is applied and kubectl context has sufficient permissions"
      diagnosed=true
    fi

    if grep -qi "no matches for kind\|the server doesn't have a resource type" "$logfile" 2>/dev/null; then
      echo "    Cause: Kubernetes API resource not available on this cluster"
      diagnosed=true
    fi

    if [ "$diagnosed" = "false" ]; then
      echo "    Cause: unknown — check the phase log for details:"
      echo "    Log: $logfile"
      local last_error
      last_error=$(grep -i 'error\|fatal\|fail' "$logfile" 2>/dev/null | tail -3 || true)
      if [ -n "$last_error" ]; then
        echo "$last_error" | while IFS= read -r eline; do
          echo "      $(echo "$eline" | sed 's/.*msg="//' | sed 's/".*//' | head -c 120)"
        done
      fi
    fi

    echo ""
  done < "$PHASES_FILE"
}

# ---------------------------------------------------------------------------
# 6) Capacity context
# ---------------------------------------------------------------------------
section_capacity() {
  [ ! -f "$FINGERPRINT_FILE" ] && return
  [ ! -f "$SAFETY_FILE" ] && return

  local total_cpu total_mem
  total_cpu=$(grep -i 'total cpu' "$FINGERPRINT_FILE" 2>/dev/null | grep -o '[0-9]*' | head -1 || true)
  total_mem=$(grep -i 'total memory' "$FINGERPRINT_FILE" 2>/dev/null | grep -o '[0-9]*' | head -1 || true)

  [ -z "$total_cpu" ] && [ -z "$total_mem" ] && return

  bold "CAPACITY CONTEXT"
  divider

  if [ -n "$total_cpu" ]; then
    local cpu_millis
    cpu_millis=$(grep 'cpu.*replicas.*x' "$SAFETY_FILE" 2>/dev/null | grep -o '[0-9]*m' | head -1 | tr -d 'm' || true)
    local cpu_reps
    cpu_reps=$(grep 'cpu.*replicas.*x' "$SAFETY_FILE" 2>/dev/null | grep -o '[0-9]* replicas' | head -1 | grep -o '[0-9]*' || true)
    local steps
    steps=$(grep 'Ramp steps:' "$SAFETY_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "1")

    if [ -n "$cpu_millis" ] && [ -n "$cpu_reps" ]; then
      local total_stress_cpu=$((cpu_millis * cpu_reps * steps))
      local cluster_cpu_millis=$((total_cpu * 1000))
      if [ "$cluster_cpu_millis" -gt 0 ]; then
        local pct_x10=$((total_stress_cpu * 1000 / cluster_cpu_millis))
        local pct_whole=$((pct_x10 / 10))
        local pct_frac=$((pct_x10 % 10))
        echo "  CPU pressure:  ${total_stress_cpu}m requested / ${cluster_cpu_millis}m available (${pct_whole}.${pct_frac}%)"
      fi
    fi
  fi

  if [ -n "$total_mem" ]; then
    local mem_mb
    mem_mb=$(grep 'mem.*replicas.*x' "$SAFETY_FILE" 2>/dev/null | grep -o '[0-9]* MB' | head -1 | grep -o '[0-9]*' || true)
    local mem_reps
    mem_reps=$(grep 'mem.*replicas.*x' "$SAFETY_FILE" 2>/dev/null | grep -o '[0-9]* replicas' | head -1 | grep -o '[0-9]*' || true)
    local steps
    steps=$(grep 'Ramp steps:' "$SAFETY_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "1")

    if [ -n "$mem_mb" ] && [ -n "$mem_reps" ]; then
      local total_stress_mem=$((mem_mb * mem_reps * steps))
      local total_mem_mb=$((total_mem / 1024))
      if [ "$total_mem_mb" -gt 0 ]; then
        local pct_x10=$((total_stress_mem * 1000 / total_mem_mb))
        local pct_whole=$((pct_x10 / 10))
        local pct_frac=$((pct_x10 % 10))
        echo "  Mem pressure:  ${total_stress_mem}MB requested / ${total_mem_mb}MB available (${pct_whole}.${pct_frac}%)"
      fi
    fi
  fi

  echo ""
}

# ---------------------------------------------------------------------------
# 7) Actionable recommendations
# ---------------------------------------------------------------------------
section_recommendations() {
  [ ! -f "$PHASES_FILE" ] && return

  local recs=()

  # Check for failures
  local fail_count
  fail_count=$(grep -c '"rc":[1-9]' "$PHASES_FILE" 2>/dev/null || true)
  fail_count="${fail_count:-0}"

  if [ "$fail_count" -gt 0 ]; then
    local probe_fails ramp_fails
    probe_fails=$(grep '"rc":[1-9]' "$PHASES_FILE" 2>/dev/null | grep -c '"phase":".*probe\|baseline\|recovery"' 2>/dev/null || true)
    probe_fails="${probe_fails:-0}"
    ramp_fails=$(grep '"rc":[1-9]' "$PHASES_FILE" 2>/dev/null | grep -c '"phase":"ramp' 2>/dev/null || true)
    ramp_fails="${ramp_fails:-0}"

    if [ "$probe_fails" -gt 0 ]; then
      recs+=("Probe pods failed — verify images are available (run: kubectl get events -n kb-probe)")
      recs+=("Try increasing KB_TIMEOUT if image pulls are slow in your environment")
    fi
    if [ "$ramp_fails" -gt 0 ]; then
      recs+=("Ramp step failed — reduce stress intensity or check cluster capacity")
      recs+=("Try fewer RAMP_STEPS or lower replica counts for the next run")
    fi
  fi

  # Check latency degradation
  if [ -s "$PROBE_FILE" ]; then
    local baseline_stats recovery_stats
    baseline_stats=$(compute_latency_stats "baseline" 2>/dev/null) || true
    recovery_stats=$(compute_latency_stats "recovery" 2>/dev/null) || true

    if [ -n "$baseline_stats" ] && [ -n "$recovery_stats" ]; then
      local b_p50 r_p50
      b_p50=$(echo "$baseline_stats" | awk '{print $3}')
      r_p50=$(echo "$recovery_stats" | awk '{print $3}')

      if [ "$b_p50" -gt 0 ]; then
        local ratio_x10=$(( r_p50 * 10 / b_p50 ))
        if [ "$ratio_x10" -gt 20 ]; then
          recs+=("Recovery latency is still >2x baseline — consider longer RECOVERY_PROBE_DURATION to track stabilization")
          recs+=("The cluster may need more cooldown time or the stress exposed a persistent bottleneck")
        fi
      fi
    fi
  fi

  # Check if only 1 ramp step was used
  local ramp_count
  ramp_count=$(grep -c '"phase":"ramp-step' "$PHASES_FILE" 2>/dev/null || true)
  ramp_count="${ramp_count:-0}"
  if [ "$ramp_count" -le 1 ] && [ "$fail_count" = "0" ]; then
    recs+=("Only $ramp_count ramp step ran — increase RAMP_STEPS to find the degradation threshold")
  fi

  [ ${#recs[@]} -eq 0 ] && return

  bold "RECOMMENDATIONS"
  divider
  for r in "${recs[@]}"; do
    echo "  → $r"
  done
  echo ""
}

# ===========================================================================
#  Main
# ===========================================================================
echo ""
bold "╔══════════════════════════════════════╗"
bold "║   KubePyrometer Run Analysis         ║"
bold "╚══════════════════════════════════════╝"
echo ""

section_overview
section_config
section_phases
section_latency
section_failures
section_capacity
section_recommendations
