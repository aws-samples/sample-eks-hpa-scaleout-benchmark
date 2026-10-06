#!/usr/bin/env python3
"""plot-version-compare.py: render the cross-version p50 TTR comparison figure.

Hard-codes the quality-gated p50 values from the two benchmark revisions in
this repository (results/ for Kubernetes 1.31, results/1.36/ for 1.36) so the
figure is reproducible from the published data. Re-derive any value with:
    scripts/analyze.sh results/<run>  (column p50)

Usage:
  python3 scripts/plot-version-compare.py
Output:
  version-compare.png in the current directory.

Requires: matplotlib (pip install matplotlib)
"""
import matplotlib.pyplot as plt

CONFIGS = ["Standard", "Provisioned XL", "Provisioned 2XL", "Standard + buffer"]
# p50 TTR seconds per configuration (see results/ and results/1.36/).
P50_131 = [38, 38, 40, 18]
# 1.36 buffer cell was run twice (62s and 76s); the lower run is plotted and
# the spread is shown as an error bar.
P50_136 = [25, 39, 38, 62]
BUF_136_SPREAD = 14  # 76s - 62s between the two buffer runs

def main():
    x = range(len(CONFIGS))
    w = 0.38
    fig, ax = plt.subplots(figsize=(9, 5))
    b1 = ax.bar([i - w / 2 for i in x], P50_131, w,
                label="Kubernetes 1.31", color="#4C72B0")
    yerr = [[0, 0, 0, 0], [0, 0, 0, BUF_136_SPREAD]]
    b2 = ax.bar([i + w / 2 for i in x], P50_136, w, yerr=yerr, capsize=6,
                label="Kubernetes 1.36", color="#DD8452")
    ax.bar_label(b1, fmt="%ds")
    ax.bar_label(b2, fmt="%ds")
    ax.set_xticks(list(x))
    ax.set_xticklabels(CONFIGS)
    ax.set_ylabel("p50 time-to-ready (seconds)")
    ax.set_title("HPA scale-out p50 TTR by configuration and Kubernetes version")
    ax.legend()
    ax.grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig("version-compare.png", dpi=150)
    print("wrote version-compare.png")

if __name__ == "__main__":
    main()
