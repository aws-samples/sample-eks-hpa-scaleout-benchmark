#!/usr/bin/env bash
# run-benchmark.sh — run one matrix cell with RELIABLE data capture and a STANDARD stop
# target (so cells are comparable). Ramps in-cluster Fortio load; records scale-out curve
# and per-pod TTR to disk as it goes.
#
# Usage: run-benchmark.sh <tier> <buffer|nobuffer> [target_pods] [max_seconds]
#   target_pods : stop when ready pods >= this (default 150) — SAME across cells for fairness
#   max_seconds : hard cap (default 900)
#
# Fixes from prior sessions:
#   - Writes spike_start + curve immediately and flushes each poll (no lost files).
#   - Captures TTR into the run dir at the end of the ramp — the script itself, not a
#     fragile manual step — so data survives even if you tear down right after.
#   - Standard stop target makes Standard vs XL vs 2XL an apples-to-apples comparison.
#   - Run this in the FOREGROUND (do not background) so file writes complete. It prints a
#     clear "RESULTS CAPTURED" line when TTR is safely on disk — only tear down after that.
set -euo pipefail

TIER="${1:?tier}"; BUF="${2:?buffer|nobuffer}"; TARGET="${3:-150}"; MAXSEC="${4:-900}"
NS="benchmark"
# Override RESULTS_DIR to group runs, e.g. RESULTS_DIR=results/1.36 for a
# version-specific benchmark revision.
RESULTS_DIR="${RESULTS_DIR:-results}"
OUT="${RESULTS_DIR}/${TIER}-${BUF}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"

# Preflight
BASE=$(kubectl -n "$NS" get deploy scaleout-app -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
[ "${BASE:-0}" -lt 10 ] && { echo "ABORT: baseline ${BASE:-0}/10" >&2; exit 1; }
kubectl get deploy -n kube-system karpenter >/dev/null 2>&1 || { echo "ABORT: no Karpenter" >&2; exit 1; }

kubectl -n "$NS" apply -f load/loadgen.yaml >/dev/null
kubectl -n "$NS" scale deploy/loadgen --replicas=0 >/dev/null; sleep 3

SPIKE_START=$(date -u +%s)
echo "$SPIKE_START" > "$OUT/spike_start"; sync
echo "ts,ready,desired,cpu,bench_nodes,loaders" > "$OUT/scaleout-curve.csv"
echo "Run: $OUT  target=${TARGET} pods  spike_start=${SPIKE_START}"

last=0; DEADLINE=$(( SPIKE_START + MAXSEC ))
# Closed-loop load control: hold app CPU in a healthy band so pods scale out without
# starving. Below LOW -> add a loader; above HIGH -> remove one. This replaces the old
# open-loop ramp that overshot to 100%+ and caused readiness flapping.
LOW=60; HIGH=78; loaders=0; MAXLOADERS=24
while [ "$(date -u +%s)" -lt "$DEADLINE" ]; do
  now=$(date -u +%s)
  ready=$(kubectl -n "$NS" get deploy scaleout-app -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  desired=$(kubectl -n "$NS" get deploy scaleout-app -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  cpu=$(kubectl -n "$NS" get hpa scaleout-app -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || echo "")
  # NOTE: grep -c exits 1 when the count is 0; without the || guard, set -e
  # kills the whole benchmark the first time no benchmark node is Ready.
  nodes=$(kubectl get nodes -l role=benchmark --no-headers 2>/dev/null | { grep -c " Ready " || true; })
  lg=$(kubectl -n "$NS" get deploy loadgen -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  # Feedback: adjust loaders every ~20s based on current CPU vs band.
  if [ $(( now - last )) -ge 20 ] && [ -n "${cpu:-}" ]; then
    if [ "$cpu" -lt "$LOW" ] && [ $loaders -lt $MAXLOADERS ]; then loaders=$(( loaders + 2 ));
    elif [ "$cpu" -gt "$HIGH" ] && [ $loaders -gt 1 ]; then loaders=$(( loaders - 1 )); fi
    kubectl -n "$NS" scale deploy/loadgen --replicas=$loaders >/dev/null 2>&1 || true
    last=$now
  fi
  echo "${now},${ready:-0},${desired:-0},${cpu:-},${nodes:-0},${lg:-0}" >> "$OUT/scaleout-curve.csv"; sync
  echo "  [$(date +%H:%M:%S)] ready=${ready:-0}/${TARGET} desired=${desired:-0} cpu=${cpu:-?}% (band ${LOW}-${HIGH}) loaders=${loaders} nodes=${nodes:-0}"
  [ "${ready:-0}" -ge "$TARGET" ] && { echo ">>> reached target ${TARGET}"; break; }
  sleep 10
done

# CAPTURE TTR NOW — before any teardown.
bash scripts/measure-ttr.sh "$SPIKE_START" "$NS" "app=scaleout-app" > "$OUT/ttr.csv"; sync
ROWS=$(( $(wc -l < "$OUT/ttr.csv") - 1 ))
kubectl -n "$NS" get events --sort-by=.lastTimestamp > "$OUT/events.txt" 2>&1 || true
kubectl -n "$NS" scale deploy/loadgen --replicas=0 >/dev/null 2>&1 || true

PEAK=$(awk -F, 'NR>1{if($2>m)m=$2} END{print m+0}' "$OUT/scaleout-curve.csv")
echo "=========================================================="
echo "RESULTS CAPTURED: $OUT"
echo "  peak ready pods: $PEAK   |   TTR rows: $ROWS"
echo "  (Safe to tear down now — data is on disk.)"
echo "=========================================================="
