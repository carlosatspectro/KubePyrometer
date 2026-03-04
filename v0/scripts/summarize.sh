#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: summarize.sh <run-dir>}"

PHASES_FILE="$RUN_DIR/phases.jsonl"
SUMMARY_FILE="$RUN_DIR/summary.csv"
PROBE_FILE="$RUN_DIR/probe.jsonl"
PROBE_STATS_FILE="$RUN_DIR/probe-stats.csv"

# ---------------------------------------------------------------------------
# Phase summary (same as before)
# ---------------------------------------------------------------------------
if [ ! -f "$PHASES_FILE" ]; then
  echo "No phases.jsonl found in $RUN_DIR — nothing to summarize."
  exit 0
fi

echo "phase,uuid,exit_code,start_epoch,end_epoch,elapsed_seconds,status" > "$SUMMARY_FILE"

while IFS= read -r line; do
  phase=$(echo "$line"  | sed -n 's/.*"phase":"\([^"]*\)".*/\1/p')
  uuid=$(echo "$line"   | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')
  rc=$(echo "$line"     | sed -n 's/.*"rc":\([0-9]*\).*/\1/p')
  start=$(echo "$line"  | sed -n 's/.*"start":\([0-9]*\).*/\1/p')
  end_t=$(echo "$line"  | sed -n 's/.*"end":\([0-9]*\).*/\1/p')
  elapsed=$(echo "$line" | sed -n 's/.*"elapsed_s":\([0-9]*\).*/\1/p')
  if [ "$rc" = "0" ]; then status="pass"; else status="fail"; fi
  echo "${phase},${uuid},${rc},${start},${end_t},${elapsed},${status}" >> "$SUMMARY_FILE"
done < "$PHASES_FILE"

echo "Summary written to $SUMMARY_FILE"

# ---------------------------------------------------------------------------
# Probe latency stats (p50 / p95 / min / max per phase)
# ---------------------------------------------------------------------------
if [ ! -s "$PROBE_FILE" ]; then
  echo "No probe.jsonl — skipping probe stats."
  exit 0
fi

echo "phase,count,min_ms,p50_ms,p95_ms,max_ms" > "$PROBE_STATS_FILE"

phases=$(sed -n 's/.*"phase":"\([^"]*\)".*/\1/p' "$PROBE_FILE" | sort -u)

for ph in $phases; do
  values=$(grep "\"phase\":\"${ph}\"" "$PROBE_FILE" \
    | sed -n 's/.*"latency_ms":\([0-9]*\).*/\1/p' \
    | sort -n)
  count=$(echo "$values" | wc -l | tr -d ' ')
  [ "$count" -eq 0 ] && continue
  min_v=$(echo "$values" | head -1)
  max_v=$(echo "$values" | tail -1)
  p50_idx=$(( (count * 50 + 99) / 100 ))
  p95_idx=$(( (count * 95 + 99) / 100 ))
  [ "$p50_idx" -lt 1 ] && p50_idx=1
  [ "$p95_idx" -lt 1 ] && p95_idx=1
  [ "$p50_idx" -gt "$count" ] && p50_idx="$count"
  [ "$p95_idx" -gt "$count" ] && p95_idx="$count"
  p50_v=$(echo "$values" | sed -n "${p50_idx}p")
  p95_v=$(echo "$values" | sed -n "${p95_idx}p")
  echo "${ph},${count},${min_v},${p50_v},${p95_v},${max_v}" >> "$PROBE_STATS_FILE"
done

echo "Probe stats written to $PROBE_STATS_FILE"
