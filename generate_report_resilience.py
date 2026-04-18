#!/usr/bin/env python3
"""
generate_report_resilience.py — Resilience & Bully Election Report
Parses analysis_resilience.log (from resilience_analysis.sh) and produces:

  report_resilience/
  ├── fig1_recovery_times.png        Bar chart: recovery time per test
  ├── fig2_perrank_times.png         Per-rank execution time breakdown
  ├── fig3_bully_election.png        Election latency + rounds per scenario
  ├── fig4_bully_perrank.png         Per-rank latency breakdown (all scenarios)
  ├── fig5_resilience_images.png     Side-by-side of test output images
  └── resilience_summary.csv        Summary of all resilience metrics

Usage:
  python3 generate_report_resilience.py
  python3 generate_report_resilience.py --log report_resilience/analysis_resilience.log \\
      --outdir report_resilience --resilience-dir report_resilience/resilience_images
"""

import argparse
import csv
import os
import re
import sys

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np
except ImportError:
    print("[ERROR] matplotlib / numpy not installed: pip install matplotlib numpy")
    sys.exit(1)

try:
    from PIL import Image as PILImage
    HAS_PIL = True
except ImportError:
    HAS_PIL = False
    print("[WARN] Pillow not installed — image panels will be skipped")

# ── Shared style ──────────────────────────────────────────────────────────────
STYLE = {
    "font.family":       "DejaVu Sans",
    "font.size":         10,
    "axes.titlesize":    11,
    "axes.titleweight":  "bold",
    "axes.labelsize":    10,
    "xtick.labelsize":   9,
    "ytick.labelsize":   9,
    "legend.fontsize":   8,
    "legend.framealpha": 0.7,
    "axes.grid":         True,
    "grid.alpha":        0.3,
    "grid.linestyle":    "--",
    "axes.spines.top":   False,
    "axes.spines.right": False,
    "figure.dpi":        150,
    "savefig.dpi":       150,
    "savefig.bbox":      "tight",
}
plt.rcParams.update(STYLE)

# ── Log patterns ──────────────────────────────────────────────────────────────
RESILIENCE_PATTERNS = {
    1: re.compile(r"\[Test 1\] Recovery complete\. Total time:\s*(?P<time>[\d.]+) ms"),
    2: re.compile(r"\[Test 2\] Straggler detected: rank (?P<rank>\d+) \((?P<time>[\d.]+) ms delay"),
    3: re.compile(r"\[Test 3\] Coordinator recovery complete\. Time with new coord:\s*(?P<time>[\d.]+) ms"),
    4: re.compile(r"\[Test 4\] Partial result assembled"),
}
CHECKSUM_RE   = re.compile(r"\[Resilience Test\] Image: (?P<w>\d+)x(?P<h>\d+)\s+Serial Sobel checksum: (?P<cs>[\d.]+)")
PERRANK_RE    = re.compile(r"\[Test 2\] Per-rank times \(ms\): (?P<ranks>.+)")

BULLY_RESULT_RE = re.compile(
    r"\[Rank\s*(?P<rank>\d+)\] Election complete\. Coordinator = (?P<coord>\d+)"
    r"\s+Latency = (?P<latency>[\d.]+) ms\s+Rounds = (?P<rounds>\d+)"
)


def parse_log(log_path):
    """
    Returns:
      {
        'image':       str | None,
        'checksum':    float | None,
        'test1_ms':    [float, ...]   # may have multiple measurements
        'test2_ms':    [float, ...]
        'test2_perrank': [[float,...], ...],
        'test3_ms':    [float, ...]
        'test4':       bool,
        'bully_scenarios': [{'scenario': str, 'ranks': [...]}, ...],
      }
    """
    result = {
        'image': None, 'checksum': None,
        'test1_ms': [], 'test2_ms': [], 'test2_perrank': [],
        'test3_ms': [], 'test4': False,
        'bully_scenarios': [],
    }

    current_bully_label = None
    current_bully_ranks = []

    with open(log_path, "r", errors="replace") as f:
        for line in f:
            line = line.rstrip()

            # Test image
            if line.startswith("RESILIENCE_IMAGE:"):
                result['image'] = line.split(":", 1)[1].strip()

            # Checksum
            m = CHECKSUM_RE.search(line)
            if m:
                result['checksum'] = float(m.group('cs'))

            # Test 1
            m = RESILIENCE_PATTERNS[1].search(line)
            if m:
                result['test1_ms'].append(float(m.group('time')))

            # Test 2 (straggler delay)
            m = RESILIENCE_PATTERNS[2].search(line)
            if m:
                result['test2_ms'].append(float(m.group('time')))

            # Test 2 per-rank
            m = PERRANK_RE.search(line)
            if m:
                parts = re.findall(r"rank\d+=([\d.]+)", m.group('ranks'))
                if parts:
                    result['test2_perrank'].append([float(x) for x in parts])

            # Test 3
            m = RESILIENCE_PATTERNS[3].search(line)
            if m:
                result['test3_ms'].append(float(m.group('time')))

            # Test 4
            if RESILIENCE_PATTERNS[4].search(line):
                result['test4'] = True

            # Bully scenarios
            if "[Bully] Normal election" in line:
                if current_bully_label is not None:
                    result['bully_scenarios'].append(
                        {'scenario': current_bully_label, 'ranks': current_bully_ranks})
                current_bully_label = "Normal"
                current_bully_ranks = []
            elif "[Bully] Election with rank" in line:
                if current_bully_label is not None:
                    result['bully_scenarios'].append(
                        {'scenario': current_bully_label, 'ranks': current_bully_ranks})
                m_sc = re.search(r"ranks? ([\d,]+) failed", line)
                current_bully_label = f"Fail {m_sc.group(1)}" if m_sc else "Fail"
                current_bully_ranks = []
            elif "BULLY_ELECTION_END" in line:
                if current_bully_label is not None:
                    result['bully_scenarios'].append(
                        {'scenario': current_bully_label, 'ranks': current_bully_ranks})
                current_bully_label = None
                current_bully_ranks = []

            m = BULLY_RESULT_RE.search(line)
            if m and current_bully_label is not None:
                current_bully_ranks.append({
                    'rank':       int(m.group('rank')),
                    'coord':      int(m.group('coord')),
                    'latency_ms': float(m.group('latency')),
                    'rounds':     int(m.group('rounds')),
                })

    # Flush last bully block
    if current_bully_label is not None and current_bully_ranks:
        result['bully_scenarios'].append(
            {'scenario': current_bully_label, 'ranks': current_bully_ranks})

    return result


# ── Chart helpers ─────────────────────────────────────────────────────────────
def _annotate_bars(ax, bars, values, fmt="{:.1f} ms", pad_frac=0.02):
    if not values:
        return
    pad = max(v for v in values if v > 0) * pad_frac if any(v > 0 for v in values) else 0.5
    for bar, v in zip(bars, values):
        if v > 0:
            ax.text(bar.get_x() + bar.get_width() / 2,
                    bar.get_height() + pad,
                    fmt.format(v), ha="center", va="bottom", fontsize=9)


# ── Figure 1: Recovery times bar chart ───────────────────────────────────────
def fig1_recovery_times(res, nodes, outdir):
    labels, values, colors = [], [], []
    color_map = {1: "#E53935", 2: "#FB8C00", 3: "#8E24AA"}

    for test_id, label in [
        (1, "Test 1\nWorker Crash\nRecovery"),
        (2, "Test 2\nSlow Node\nDetection"),
        (3, "Test 3\nCoordinator\nRecovery"),
    ]:
        vals = res[f'test{test_id}_ms']
        if vals:
            labels.append(label)
            values.append(float(np.mean(vals)))
            colors.append(color_map[test_id])

    note = "Test 4 (Partial Result): assembled ✓" if res['test4'] else \
           "Test 4 (Partial Result): not detected"

    if not values:
        print("  [WARN] No resilience timing data — Fig 1 skipped")
        return

    fig, ax = plt.subplots(figsize=(8, 5))
    bars = ax.bar(labels, values, color=colors, alpha=0.85,
                  edgecolor="white", width=0.5)
    _annotate_bars(ax, bars, values)

    img_name = os.path.basename(res['image']) if res['image'] else "unknown"
    checksum_note = f"  Serial Sobel checksum: {res['checksum']:.1f}" \
                    if res['checksum'] else ""
    ax.set_title(f"Resilience — Recovery & Detection Times (ms)\n"
                 f"{note}  |  Image: {img_name}{checksum_note}")
    ax.set_ylabel("Time (ms)")

    # Error bars if multiple measurements
    for bar, test_id, lbl in zip(bars, [1, 2, 3], labels):
        vals = res[f'test{test_id}_ms']
        if len(vals) > 1:
            ax.errorbar(bar.get_x() + bar.get_width() / 2,
                        np.mean(vals), yerr=np.std(vals),
                        fmt="none", color="black", capsize=5, linewidth=2)

    path = os.path.join(outdir, "fig1_recovery_times.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 2: Per-rank execution time breakdown ───────────────────────────────
def fig2_perrank_times(res, outdir):
    if not res['test2_perrank']:
        print("  [WARN] No per-rank data — Fig 2 skipped")
        return

    # Aggregate across repeated measurements
    max_ranks = max(len(r) for r in res['test2_perrank'])
    means = [np.mean([run[i] for run in res['test2_perrank'] if i < len(run)])
             for i in range(max_ranks)]
    stds  = [np.std([run[i] for run in res['test2_perrank'] if i < len(run)])
             for i in range(max_ranks)]

    fig, ax = plt.subplots(figsize=(max(6, max_ranks * 1.2), 5))
    ranks = list(range(max_ranks))
    bars = ax.bar(ranks, means, yerr=stds, capsize=4,
                  color=["#E53935" if i == np.argmax(means) else "#FB8C00"
                         for i in ranks],
                  alpha=0.85, edgecolor="white")

    # Mark the straggler
    straggler_idx = int(np.argmax(means))
    ax.annotate(f"← Straggler\nrank {straggler_idx}",
                xy=(straggler_idx, means[straggler_idx]),
                xytext=(straggler_idx + 0.5, means[straggler_idx] * 0.85),
                fontsize=9, color="#E53935",
                arrowprops=dict(arrowstyle="->", color="#E53935"))

    _annotate_bars(ax, bars, means)
    ax.set_title("Test 2 — Per-Rank Execution Time (ms)\n"
                 "Red bar = straggler (slow node detected)")
    ax.set_xlabel("Rank")
    ax.set_ylabel("Time (ms)")
    ax.set_xticks(ranks)
    ax.set_xticklabels([f"rank {r}" for r in ranks], fontsize=9)

    path = os.path.join(outdir, "fig2_perrank_times.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 3: Bully election latency + rounds ─────────────────────────────────
def fig3_bully_election(scenarios, outdir):
    if not scenarios:
        print("  [WARN] No bully election data — Fig 3 skipped")
        return

    scene_labels = [s['scenario'] for s in scenarios]
    latencies = [np.mean([r['latency_ms'] for r in s['ranks']]) if s['ranks'] else 0
                 for s in scenarios]
    lat_stds  = [np.std([r['latency_ms'] for r in s['ranks']]) if len(s['ranks']) > 1 else 0
                 for s in scenarios]
    rounds    = [np.mean([r['rounds'] for r in s['ranks']]) if s['ranks'] else 0
                 for s in scenarios]
    rnd_stds  = [np.std([r['rounds'] for r in s['ranks']]) if len(s['ranks']) > 1 else 0
                 for s in scenarios]

    bar_colors = ["#2196F3", "#FF5722", "#9C27B0"][:len(scenarios)]

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    fig.suptitle("Bully Algorithm Leader Election — Performance Summary")

    # Latency
    ax = axes[0]
    bars = ax.bar(scene_labels, latencies, yerr=lat_stds, capsize=5,
                  color=bar_colors, alpha=0.85, edgecolor="white", width=0.5)
    _annotate_bars(ax, bars, latencies, fmt="{:.1f} ms")
    ax.set_title("Mean Election Latency per Scenario")
    ax.set_ylabel("Latency (ms)")
    ax.set_xlabel("Failure Scenario")

    # Rounds
    ax = axes[1]
    bars = ax.bar(scene_labels, rounds, yerr=rnd_stds, capsize=5,
                  color=bar_colors, alpha=0.85, edgecolor="white", width=0.5)
    _annotate_bars(ax, bars, rounds, fmt="{:.1f} rounds")
    ax.set_title("Mean Election Rounds per Scenario")
    ax.set_ylabel("Rounds")
    ax.set_xlabel("Failure Scenario")

    path = os.path.join(outdir, "fig3_bully_election.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 4: Per-rank bully latency ─────────────────────────────────────────
def fig4_bully_perrank(scenarios, outdir):
    if not scenarios:
        return

    bar_colors = ["#2196F3", "#FF5722", "#9C27B0"]

    fig, ax = plt.subplots(figsize=(max(8, len(scenarios) * 4), 5))
    fig.suptitle("Bully Election — Per-Rank Latency Breakdown\n"
                 "(Each cluster = one failure scenario)")

    x_base = 0
    tick_positions, tick_labels = [], []
    legend_handles = []

    for i, s in enumerate(scenarios):
        if not s['ranks']:
            continue
        rk_list = sorted(s['ranks'], key=lambda r: r['rank'])
        x_pos = np.arange(len(rk_list)) + x_base
        lats  = [r['latency_ms'] for r in rk_list]
        color = bar_colors[i % len(bar_colors)]

        bars = ax.bar(x_pos, lats, color=color, alpha=0.85,
                      edgecolor="white", label=s['scenario'])
        # Mark coordinator
        for r_data, xp in zip(rk_list, x_pos):
            if r_data['rank'] == r_data['coord']:
                ax.annotate("✓ coord", xy=(xp, r_data['latency_ms']),
                            xytext=(xp, r_data['latency_ms'] + max(lats) * 0.05),
                            ha="center", fontsize=7, color=color)

        tick_positions.extend(x_pos.tolist())
        tick_labels.extend([f"r{r['rank']}" for r in rk_list])
        x_base += len(rk_list) + 1.5  # gap between scenarios

        # Scenario label
        mid = x_pos[len(x_pos) // 2]
        ax.text(mid, -max(lats) * 0.08, s['scenario'],
                ha="center", fontsize=9, color=color, fontweight="bold")

    ax.set_xticks(tick_positions)
    ax.set_xticklabels(tick_labels, fontsize=8)
    ax.set_ylabel("Latency (ms)")
    ax.legend(fontsize=9)

    path = os.path.join(outdir, "fig4_bully_perrank.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 5: Resilience output images ───────────────────────────────────────
def fig5_resilience_images(resilience_dir, outdir):
    if not HAS_PIL:
        print("  [SKIP] Pillow not installed")
        return
    if not os.path.isdir(resilience_dir):
        print(f"  [WARN] Resilience image dir not found: {resilience_dir}")
        return

    slots = [
        ("resilience_test1_crash.png",         "Test 1\nWorker Crash"),
        ("resilience_test2_slow.png",          "Test 2\nSlow Node"),
        ("resilience_test3_coord_recovery.png","Test 3\nCoord Recovery"),
        ("resilience_test4_partial.png",       "Test 4\nPartial Result"),
    ]
    valid = [(os.path.join(resilience_dir, fn), lbl)
             for fn, lbl in slots
             if os.path.exists(os.path.join(resilience_dir, fn))]

    if not valid:
        print("  [WARN] No resilience output PNGs found")
        return

    n = len(valid)
    fig, axes = plt.subplots(1, n, figsize=(4 * n, 4))
    if n == 1:
        axes = [axes]
    fig.suptitle("Resilience Test — Sobel Output Images\n"
                 "(output should match serial reference with minor boundary differences)",
                 fontsize=11, fontweight="bold")

    test_colors = ["#E53935", "#FB8C00", "#8E24AA", "#0288D1"]
    for ax, (fpath, lbl), color in zip(axes, valid, test_colors):
        try:
            img = PILImage.open(fpath).convert("L")
            ax.imshow(np.array(img), cmap="gray", interpolation="lanczos")
        except Exception as e:
            ax.text(0.5, 0.5, str(e), ha="center", va="center",
                    transform=ax.transAxes, fontsize=8)
        ax.set_title(lbl, fontsize=10, color=color, fontweight="bold")
        ax.axis("off")
        for spine in ax.spines.values():
            spine.set_edgecolor(color)
            spine.set_linewidth(2)

    path = os.path.join(outdir, "fig5_resilience_images.png")
    plt.savefig(path, dpi=120)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── CSV summary ───────────────────────────────────────────────────────────────
def write_csv(res, scenarios, outdir):
    rows = []

    for test_id, label in [(1, "worker_crash"), (2, "slow_node"), (3, "coord_recovery")]:
        for i, v in enumerate(res[f'test{test_id}_ms']):
            rows.append({"category": "resilience", "test": label,
                         "run": i, "metric": "recovery_ms", "value": f"{v:.3f}"})

    if res['test4']:
        rows.append({"category": "resilience", "test": "partial_result",
                     "run": 0, "metric": "status", "value": "assembled"})

    for s in scenarios:
        for r in s['ranks']:
            rows.append({
                "category": "bully",
                "test": s['scenario'],
                "run": r['rank'],
                "metric": "latency_ms",
                "value": f"{r['latency_ms']:.3f}",
            })
            rows.append({
                "category": "bully",
                "test": s['scenario'],
                "run": r['rank'],
                "metric": "rounds",
                "value": str(r['rounds']),
            })

    if not rows:
        return

    path = os.path.join(outdir, "resilience_summary.csv")
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["category", "test", "run",
                                                "metric", "value"])
        writer.writeheader()
        writer.writerows(rows)
    print(f"  Saved: {path}")


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Resilience Analysis Report")
    parser.add_argument("--log",            default="report_resilience/analysis_resilience.log")
    parser.add_argument("--outdir",         default="report_resilience")
    parser.add_argument("--resilience-dir", default="report_resilience/resilience_images")
    parser.add_argument("--nodes",          type=int, default=6)
    args = parser.parse_args()

    if not os.path.exists(args.log):
        print(f"[ERROR] Log not found: {args.log}")
        print("Run ./resilience_analysis.sh first.")
        sys.exit(1)

    os.makedirs(args.outdir, exist_ok=True)

    print(f"\nParsing {args.log} …")
    res = parse_log(args.log)

    print(f"  Image tested: {res['image']}")
    print(f"  Test 1 (crash):      {len(res['test1_ms'])} measurement(s)")
    print(f"  Test 2 (slow node):  {len(res['test2_ms'])} measurement(s)")
    print(f"  Test 3 (coord):      {len(res['test3_ms'])} measurement(s)")
    print(f"  Test 4 (partial):    {'yes' if res['test4'] else 'no'}")
    print(f"  Bully scenarios:     {len(res['bully_scenarios'])}")

    print("\nGenerating figures …")
    fig1_recovery_times(res, args.nodes, args.outdir)
    fig2_perrank_times(res, args.outdir)
    fig3_bully_election(res['bully_scenarios'], args.outdir)
    fig4_bully_perrank(res['bully_scenarios'], args.outdir)
    fig5_resilience_images(args.resilience_dir, args.outdir)
    write_csv(res, res['bully_scenarios'], args.outdir)

    charts = sorted(f for f in os.listdir(args.outdir) if f.endswith(".png"))
    print(f"\nReport complete → {args.outdir}/  ({len(charts)} figures)")
    for c in charts:
        print(f"  {args.outdir}/{c}")


if __name__ == "__main__":
    main()
