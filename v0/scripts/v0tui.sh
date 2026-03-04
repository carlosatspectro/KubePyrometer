#!/usr/bin/env bash
# ============================================================================
# v0tui.sh -- Interactive TUI for the v0 load-testing harness
#
# Dependencies (optional; graceful fallback when missing):
#   gum   - pretty menus, prompts, spinners  (REQUIRED -- auto-installed)
#   fzf   - fuzzy file picker                 (optional)
#   jq    - JSON processing                   (optional; falls back to python)
#
# Install:
#   macOS:  brew install gum fzf jq
#   Linux:  see https://github.com/charmbracelet/gum#installation
#           apt install fzf jq  OR  dnf install fzf jq
#
# Usage:
#   v0/scripts/v0tui.sh
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
V0_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
ensure_gum() {
  if command -v gum &>/dev/null; then return 0; fi
  echo "gum not found. Attempting install..."
  if command -v brew &>/dev/null; then
    brew install gum
  elif command -v go &>/dev/null; then
    go install github.com/charmbracelet/gum@latest
  else
    echo "Cannot auto-install gum. Install manually:"
    echo "  macOS:  brew install gum"
    echo "  Linux:  see https://github.com/charmbracelet/gum#installation"
    exit 1
  fi
  if ! command -v gum &>/dev/null; then
    echo "ERROR: gum install failed."
    exit 1
  fi
}

HAS_FZF=false
HAS_JQ=false
check_optional_deps() {
  command -v fzf &>/dev/null && HAS_FZF=true
  command -v jq  &>/dev/null && HAS_JQ=true
}

ensure_gum
check_optional_deps

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
heading() {
  echo ""
  gum style --bold --border double --padding "0 2" --border-foreground 212 "$@"
}

press_enter() {
  echo ""
  gum input --placeholder "Press Enter to continue..." > /dev/null 2>&1 || read -r -p "Press Enter to continue..."
}

pick_file() {
  local dir="$1" prompt="${2:-Pick a file}"
  if $HAS_FZF; then
    find "$dir" -maxdepth 2 -type f 2>/dev/null | fzf --prompt="$prompt > "
  else
    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -maxdepth 2 -type f 2>/dev/null | sort)
    if [ ${#files[@]} -eq 0 ]; then
      echo ""
      return
    fi
    gum choose --header "$prompt" "${files[@]}"
  fi
}

latest_run_dir() {
  ls -dt "$V0_DIR/runs/"*/ 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# Probe count helper (jq > python > grep)
# ---------------------------------------------------------------------------
probe_counts() {
  local file="$1"
  if [ ! -s "$file" ]; then
    echo "  (probe.jsonl is empty)"
    return
  fi
  if $HAS_JQ; then
    jq -r '.phase' "$file" 2>/dev/null | sort | uniq -c | sort -rn
  elif command -v python3 &>/dev/null; then
    python3 -c "
import json, collections, sys
c = collections.Counter()
for line in open(sys.argv[1]):
    try: c[json.loads(line)['phase']] += 1
    except: pass
for ph, n in sorted(c.items()): print(f'  {ph}: {n}')
" "$file"
  else
    echo "  baseline: $(grep -c '"phase":"baseline"' "$file" 2>/dev/null || echo 0)"
    echo "  recovery: $(grep -c '"phase":"recovery"' "$file" 2>/dev/null || echo 0)"
    grep -oP '"phase":"[^"]+"' "$file" 2>/dev/null | sort | uniq -c | sort -rn || true
  fi
}

# ---------------------------------------------------------------------------
# 1) Cluster info
# ---------------------------------------------------------------------------
action_cluster_info() {
  heading "Cluster Info"
  echo ""
  echo "Context: $(kubectl config current-context 2>/dev/null || echo '(none)')"
  echo ""
  kubectl cluster-info 2>/dev/null || echo "(cluster-info unavailable)"
  echo ""
  kubectl get nodes -o wide 2>/dev/null || echo "(cannot list nodes)"
  press_enter
}

# ---------------------------------------------------------------------------
# 2) Run harness
# ---------------------------------------------------------------------------
action_run_harness() {
  heading "Run Harness"

  local config_choice
  config_choice=$(gum choose --header "Config source" \
    "default (v0/config.yaml)" \
    "pick from v0/configs/" \
    "cancel")

  local config_file=""
  case "$config_choice" in
    default*) config_file="$V0_DIR/config.yaml" ;;
    pick*)
      config_file=$(pick_file "$V0_DIR/configs" "Select config")
      if [ -z "$config_file" ]; then
        echo "No config selected."
        press_enter
        return
      fi
      ;;
    *) return ;;
  esac

  echo "Config: $config_file"

  local env_overrides=""
  if gum confirm "Set environment overrides?" --default=false 2>/dev/null; then
    echo "Enter KEY=VALUE lines (one per line). Submit with Ctrl-D or empty line."
    env_overrides=$(gum write --placeholder "RAMP_STEPS=3\nRAMP_CPU_MILLICORES=200" 2>/dev/null || true)
  fi

  if ! gum confirm "Run v0/run.sh with this config?" 2>/dev/null; then
    return
  fi

  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  local logfile="/tmp/v0tui-${ts}.log"

  heading "Running harness..."
  echo "Log: $logfile"
  echo ""

  (
    export CONFIG_FILE="$config_file"
    if [ -n "$env_overrides" ]; then
      while IFS= read -r line; do
        line="${line%%#*}"
        [[ -z "$line" || ! "$line" =~ = ]] && continue
        export "$line" 2>/dev/null || true
      done <<< "$env_overrides"
    fi
    bash "$V0_DIR/run.sh"
  ) 2>&1 | tee "$logfile"
  local rc=${PIPESTATUS[0]}

  local run_dir
  run_dir=$(latest_run_dir)
  if [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
    cp "$logfile" "$run_dir/tui.log" 2>/dev/null || true
  fi

  echo ""
  if [ "$rc" -eq 0 ]; then
    gum style --foreground 46 --bold "Harness PASSED (rc=0)"
  else
    gum style --foreground 196 --bold "Harness FAILED (rc=$rc)"
  fi

  if [ -n "$run_dir" ]; then
    echo ""
    show_run_details "$run_dir"
  fi
  press_enter
}

# ---------------------------------------------------------------------------
# 3) Cleanup
# ---------------------------------------------------------------------------
action_cleanup() {
  heading "Cleanup Harness Resources"

  local cleanup_script="$V0_DIR/scripts/cleanup-harness.sh"
  if [ ! -x "$cleanup_script" ]; then
    echo "Cleanup script not found: $cleanup_script"
    press_enter
    return
  fi

  local flags=()
  local mode
  mode=$(gum choose --header "Cleanup mode" \
    "--dry-run (preview only)" \
    "--all (full cleanup)" \
    "--all --force-finalize (dangerous)" \
    "cancel")

  case "$mode" in
    *cancel*) return ;;
    *dry-run*)  flags+=(--dry-run) ;;
    *force*)
      if ! gum confirm "Force-finalize will remove finalizers. Are you sure?" 2>/dev/null; then return; fi
      if ! gum confirm "REALLY sure? This is irreversible." 2>/dev/null; then return; fi
      flags+=(--all --force-finalize)
      ;;
    *all*) flags+=(--all) ;;
  esac

  echo "Running: $cleanup_script ${flags[*]}"
  bash "$cleanup_script" "${flags[@]}" 2>&1
  press_enter
}

# ---------------------------------------------------------------------------
# 4) Show results
# ---------------------------------------------------------------------------
show_run_details() {
  local run_dir="$1"
  echo "RUN_DIR: $run_dir"
  echo ""

  if [ -f "$run_dir/kb-version.txt" ]; then
    echo "--- kube-burner version ---"
    head -3 "$run_dir/kb-version.txt"
    echo ""
  fi

  if [ -f "$run_dir/summary.csv" ]; then
    echo "--- summary.csv ---"
    column -t -s',' "$run_dir/summary.csv" 2>/dev/null || cat "$run_dir/summary.csv"
    echo ""
  fi

  if [ -f "$run_dir/probe.jsonl" ]; then
    echo "--- probe counts by phase ---"
    probe_counts "$run_dir/probe.jsonl"
    echo ""
  fi

  local show_logs
  show_logs=$(gum choose --header "Show phase logs?" \
    "skip" \
    "tail (last 60 lines each)" 2>/dev/null || echo "skip")

  if [ "$show_logs" = "tail (last 60 lines each)" ]; then
    for f in "$run_dir"/phase-*.log; do
      [ -f "$f" ] || continue
      echo ""
      echo "--- $(basename "$f") (last 60 lines) ---"
      tail -60 "$f"
    done
  fi
}

action_show_results() {
  heading "Run Results"

  local choice
  choice=$(gum choose --header "Which run?" \
    "latest" \
    "pick from v0/runs/" \
    "cancel")

  local run_dir=""
  case "$choice" in
    latest)
      run_dir=$(latest_run_dir)
      if [ -z "$run_dir" ]; then
        echo "No runs found under v0/runs/"
        press_enter
        return
      fi
      ;;
    pick*)
      local dirs=()
      while IFS= read -r d; do dirs+=("$d"); done < <(ls -dt "$V0_DIR/runs/"*/ 2>/dev/null)
      if [ ${#dirs[@]} -eq 0 ]; then
        echo "No runs found."
        press_enter
        return
      fi
      if $HAS_FZF; then
        run_dir=$(printf '%s\n' "${dirs[@]}" | fzf --prompt="Select run > ")
      else
        run_dir=$(gum choose --header "Select run" "${dirs[@]}")
      fi
      if [ -z "$run_dir" ]; then
        press_enter
        return
      fi
      ;;
    *) return ;;
  esac

  show_run_details "$run_dir"
  press_enter
}

# ---------------------------------------------------------------------------
# 5) Edit config
# ---------------------------------------------------------------------------
action_edit_config() {
  heading "Edit Config"

  local choice
  choice=$(gum choose --header "Which file?" \
    "v0/config.yaml (defaults)" \
    "pick from v0/configs/" \
    "cancel")

  local target=""
  case "$choice" in
    *defaults*) target="$V0_DIR/config.yaml" ;;
    pick*)
      target=$(pick_file "$V0_DIR/configs" "Select config to edit")
      if [ -z "$target" ]; then
        echo "No file selected."
        press_enter
        return
      fi
      ;;
    *) return ;;
  esac

  ${EDITOR:-vi} "$target"
}

# ---------------------------------------------------------------------------
# 6) Kind smoke test
# ---------------------------------------------------------------------------
action_kind_smoke() {
  heading "Kind Smoke Test"

  if ! gum confirm "Run v0/scripts/kind-smoke.sh?" 2>/dev/null; then
    return
  fi

  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  local logfile="/tmp/v0tui-smoke-${ts}.log"

  bash "$V0_DIR/scripts/kind-smoke.sh" 2>&1 | tee "$logfile"
  local rc=${PIPESTATUS[0]}

  echo ""
  if [ "$rc" -eq 0 ]; then
    gum style --foreground 46 --bold "Smoke test PASSED"
  else
    gum style --foreground 196 --bold "Smoke test FAILED (rc=$rc)"
  fi

  local run_dir
  run_dir=$(latest_run_dir)
  if [ -n "$run_dir" ]; then
    echo ""
    show_run_details "$run_dir"
  fi
  press_enter
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
main_menu() {
  local items=(
    "1) Cluster info"
    "2) Run harness"
    "3) Cleanup resources"
    "4) Show results"
    "5) Edit config"
  )

  if [ -x "$V0_DIR/scripts/kind-smoke.sh" ] && command -v kind &>/dev/null; then
    items+=("6) Kind smoke test")
  fi

  items+=("7) Exit")

  while true; do
    heading "v0 Load-Testing Harness"
    local choice
    choice=$(gum choose --header "Select an action" "${items[@]}")

    case "$choice" in
      1*) action_cluster_info ;;
      2*) action_run_harness ;;
      3*) action_cleanup ;;
      4*) action_show_results ;;
      5*) action_edit_config ;;
      6*) action_kind_smoke ;;
      7*|"") break ;;
    esac
  done

  echo "Bye."
}

main_menu
