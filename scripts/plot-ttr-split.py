#!/usr/bin/env python3
"""plot-ttr-split.py — render the warm-vs-new-node TTR bar chart for the blog.

Reads results/<run>/ttr.csv files (pod,created,scheduled,ready,
ttr_from_spike_s,ttr_created_to_ready_s) and plots, per configuration,
the p50 TTR split by whether the pod landed on a warm node (<60s) or
waited for a new node (>=60s) — the same split analyze.sh reports.

Usage:
  python3 scripts/plot-ttr-split.py results/<run1> results/<run2> [...]
Output:
  ttr-split.png in the current directory.

Requires: matplotlib (pip install matplotlib)
"""
import csv
import math
import sys
from pathlib import Path

import matplotlib.pyplot as plt

WARM_CUTOFF_S = 60  # same threshold as analyze.sh / blog methodology


def pct(values, p):
    """Same percentile selection as analyze.sh (a[ceil(NR*p)], 1-indexed)."""
    if not values:
        return 0
    s = sorted(values)
    return s[math.ceil(len(s) * p) - 1]


def load_ttrs(run_dir: Path):
    ttrs = []
    with open(run_dir / "ttr.csv") as f:
        for row in csv.DictReader(f):
            v = row.get("ttr_created_to_ready_s", "")
            if v not in ("", None):
                ttrs.append(int(v))
    return ttrs


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    labels, warm_p50s, cold_p50s = [], [], []
    for arg in sys.argv[1:]:
        run = Path(arg)
        ttrs = load_ttrs(run)
        warm = [t for t in ttrs if t < WARM_CUTOFF_S]
        cold = [t for t in ttrs if t >= WARM_CUTOFF_S]
        labels.append("-".join(run.name.split("-")[:-1]))
        warm_p50s.append(pct(warm, 0.5))
        cold_p50s.append(pct(cold, 0.5))

    x = range(len(labels))
    width = 0.38
    fig, ax = plt.subplots(figsize=(9, 5))
    bars_w = ax.bar([i - width / 2 for i in x], warm_p50s, width,
                    label="Landed on a warm node (p50)", color="#2ca02c")
    bars_c = ax.bar([i + width / 2 for i in x], cold_p50s, width,
                    label="Waited for a new node (p50)", color="#d62728")
    ax.bar_label(bars_w, fmt="%ds")
    ax.bar_label(bars_c, fmt="%ds")
    ax.set_xticks(list(x))
    ax.set_xticklabels(labels)
    ax.set_ylabel("Time-to-ready (seconds)")
    ax.set_title("Per-pod TTR: warm node vs. cold node launch")
    ax.legend()
    ax.grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig("ttr-split.png", dpi=150)
    print("wrote ttr-split.png")


if __name__ == "__main__":
    main()
