#!/usr/bin/env bash
# analyze.sh — summarize run dirs' TTR with a DATA-QUALITY gate.
# Usage: analyze.sh results/<run> [more runs...]
# Flags runs where too many pods never reached Ready (flapping/starvation = unclean data).
set -euo pipefail
pct(){ sort -n | awk -v p="$1" '{a[NR]=$1} END{if(NR)printf "%s",a[int(NR*p)+(NR*p==int(NR*p)?0:1)];else printf "-"}'; }

printf "%-40s %6s %6s %8s %8s %9s %10s %s\n" "RUN" "TOTAL" "READY" "p50" "p90" "warm_p50" "newnode_p50" "QUALITY"
for d in "$@"; do
  [ -f "$d/ttr.csv" ] || { printf "%-40s  (no ttr.csv)\n" "$(basename "$d")"; continue; }
  total=$(tail -n +2 "$d/ttr.csv" | wc -l | tr -d ' ')
  # column 6 = ttr_created_to_ready_s; empty means pod never became Ready
  ready=$(tail -n +2 "$d/ttr.csv" | awk -F, '$6!=""' | wc -l | tr -d ' ')
  all=$(tail -n +2 "$d/ttr.csv" | awk -F, '$6!=""{print $6}')
  p50=$(echo "$all" | pct 0.5); p90=$(echo "$all" | pct 0.9)
  warm=$(echo "$all" | awk '$1<60' | pct 0.5); newn=$(echo "$all" | awk '$1>=60' | pct 0.5)
  # Quality: fraction of pods that reached Ready. <80% = contaminated.
  q="OK"; [ "$total" -gt 0 ] && frac=$(( ready*100/total )) || frac=0
  [ "$frac" -lt 80 ] && q="⚠ SUSPECT (${frac}% ready)"
  printf "%-40s %6s %6s %7ss %7ss %8ss %9ss %s\n" "$(basename "$d")" "$total" "$ready" "${p50:--}" "${p90:--}" "${warm:--}" "${newn:--}" "$q"
done
echo "Note: only runs marked OK (>=80% pods reached Ready) are valid for the blog."
