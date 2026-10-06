#!/usr/bin/env bash
# measure-ttr.sh — compute HPA scale-out Time-To-Ready (TTR) from pod timestamps.
#
# Emits CSV: pod,created,scheduled,ready,ttr_created_to_ready_s,sched_delay_s,ready_delay_s
# Aggregate across pods to get the scale-out curve + medians for the blog.
#
# Usage: measure-ttr.sh <spike_start_epoch> [namespace] [label]
#   spike_start_epoch : `date +%s` captured the instant you launched the spike
set -euo pipefail

SPIKE_START="${1:?spike start epoch required (date +%s at spike launch)}"
NS="${2:-benchmark}"
LABEL="${3:-app=scaleout-app}"

to_epoch() { [ -z "$1" ] || [ "$1" = "null" ] && echo "" || date -u -d "$1" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$1" +%s; }

echo "pod,created,scheduled,ready,ttr_from_spike_s,ttr_created_to_ready_s"
kubectl get pods -n "$NS" -l "$LABEL" -o json | jq -r '
  .items[] | [
    .metadata.name,
    .metadata.creationTimestamp,
    ((.status.conditions[]? | select(.type=="PodScheduled" and .status=="True") | .lastTransitionTime) // "null"),
    ((.status.conditions[]? | select(.type=="Ready" and .status=="True") | .lastTransitionTime) // "null")
  ] | @tsv' | while IFS=$'\t' read -r name created scheduled ready; do
    c=$(to_epoch "$created"); r=$(to_epoch "$ready")
    # Only count pods created at/after the spike — these are the scaled-out pods.
    # Baseline pods (created before the spike) are excluded so TTR is meaningful.
    [ -z "$c" ] && continue
    [ "$c" -lt "$SPIKE_START" ] && continue
    ttr_spike=""; ttr_cr=""
    [ -n "$r" ] && ttr_spike=$(( r - SPIKE_START ))
    [ -n "$r" ] && ttr_cr=$(( r - c ))
    echo "${name},${created},${scheduled},${ready},${ttr_spike},${ttr_cr}"
  done

echo "# Aggregate in your analysis: p50/p90 of ttr_from_spike_s = the headline scale-out latency." >&2
echo "# Compare across tiers (Standard/XL/2XL) and buffer on/off." >&2
