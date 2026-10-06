#!/usr/bin/env python3
"""plot-curve.py — render the scale-out curve figure for the blog.

Reads one or more results/<run>/scaleout-curve.csv files
(ts,ready,desired,cpu,bench_nodes,loaders) and plots ready pods vs.
seconds-since-spike for each run on a single chart.

Usage:
  python3 scripts/plot-curve.py results/standard-nobuffer-<ts> results/standard-buffer-<ts> [...]
Output:
  scaleout-curve.png in the current directory.

Requires: matplotlib (pip install matplotlib)
"""
import csv
import sys
from pathlib import Path

import matplotlib.pyplot as plt


def load_run(run_dir: Path):
    spike_start = int((run_dir / "spike_start").read_text().strip())
    xs, ys = [], []
    with open(run_dir / "scaleout-curve.csv") as f:
        for row in csv.DictReader(f):
            xs.append(int(row["ts"]) - spike_start)
            ys.append(int(row["ready"] or 0))
    return xs, ys


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    fig, ax = plt.subplots(figsize=(9, 5))
    for arg in sys.argv[1:]:
        run = Path(arg)
        xs, ys = load_run(run)
        # Label: "standard-buffer" from "standard-buffer-20260905T022913Z"
        label = "-".join(run.name.split("-")[:-1])
        ax.plot(xs, ys, marker="o", markersize=3, label=label)
    ax.set_xlabel("Seconds since traffic spike")
    ax.set_ylabel("Ready pods")
    ax.set_title("HPA scale-out: ready pods vs. time")
    ax.axhline(150, color="gray", linestyle="--", linewidth=1, label="target (150 pods)")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig("scaleout-curve.png", dpi=150)
    print("wrote scaleout-curve.png")


if __name__ == "__main__":
    main()
