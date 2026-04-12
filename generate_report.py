#!/usr/bin/env python3
"""
generate_report.py — Milestone 2 Full Report Generator
Parses analysis_results.log and produces:
  - Per-filter speedup / efficiency / Brent's-law charts (all 4 archs)
  - Cross-filter comparison charts
  - Resilience test summary
  - visual_comparison.png  (output images side-by-side)
  - summary_table.csv

Usage:
  python3 generate_report.py                           # defaults
  python3 generate_report.py --log my.log --outdir out
  python3 generate_report.py --node-counts "2 4 6" --thread-counts "1 2 4"
"""

import argparse
import os
import re
import sys
import csv
from collections import defaultdict

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np
except ImportError:
    print("[ERROR] matplotlib / numpy not installed. Install with: pip install matplotlib numpy")
    sys.exit(1)

try:
    from PIL import Image as PILImage
    HAS_PIL = True
except ImportError:
    HAS_PIL = False

# ── Constants ─────────────────────────────────────────────────────────────────
FILTERS  = ["Sobel", "Canny", "LoG", "FFT"]
ARCHS    = [1, 2, 3, 4]

ARCH_LABELS = {
    1: "Arch1 OMP Farm",
    2: "Arch2 OMP Pipeline",
    3: "Arch3 MPI Scatter",
    4: "Arch4 MPI Pipeline",
}

ARCH_PARALLELISM = {
    1: "threads",   # OMP → scales with threads
    2: "threads",
    3: "nodes",     # MPI → scales with nodes
    4: "nodes",
}

# Regex patterns keyed by (filter, arch).
# Each pattern must have a 'time' named group and either 'p' (parallelism count)
# or the count can be inferred from the run order.
PATTERNS = {
    # ── Baselines ─────────────────────────────────────────────────────────────
    ("Sobel",  0): re.compile(r"Sobel time:\s*(?P<time>[\d.]+)"),
    ("LoG",    0): re.compile(r"LoG time:\s*(?P<time>[\d.]+)"),
    ("Canny",  0): re.compile(r"Canny time:\s*(?P<time>[\d.]+)"),
    ("FFT",    0): re.compile(r"FFT Edge time:\s*(?P<time>[\d.]+)"),

    # ── Sobel ─────────────────────────────────────────────────────────────────
    ("Sobel",  1): re.compile(r"\[Sobel Farm\] threads=(?P<p>\d+)\s+time=(?P<time>[\d.]+)"),
    ("Sobel",  2): re.compile(r"\[Sobel Pipeline\] chunk_rows=\d+\s+time=(?P<time>[\d.]+)"),
    ("Sobel",  3): re.compile(r"\[Sobel Scatter\] ranks=(?P<p>\d+)\s+compute_time=(?P<time>[\d.]+)"),
    ("Sobel",  4): re.compile(r"\[Sobel MPI Pipeline\] N=(?P<p>\d+)\s+total_time=(?P<time>[\d.]+)"),

    # ── Canny ─────────────────────────────────────────────────────────────────
    ("Canny",  1): re.compile(r"\[Canny Farm\] threads=(?P<p>\d+)\s+time=(?P<time>[\d.]+)"),
    ("Canny",  2): re.compile(r"\[Canny Pipeline\] chunk_rows=\d+\s+time=(?P<time>[\d.]+)"),
    ("Canny",  3): re.compile(r"\[Canny Scatter\] ranks=(?P<p>\d+)\s+total_time=(?P<time>[\d.]+)"),
    ("Canny",  4): re.compile(r"\[Canny Pipeline\] N=(?P<p>\d+)\s+total_time=(?P<time>[\d.]+)"),

    # ── LoG ───────────────────────────────────────────────────────────────────
    ("LoG",    1): re.compile(r"\[LoG Farm\] threads=(?P<p>\d+)\s+time=(?P<time>[\d.]+)"),
    ("LoG",    2): re.compile(r"\[LoG Pipeline\] chunk_rows=\d+\s+time=(?P<time>[\d.]+)"),
    ("LoG",    3): re.compile(r"\[LoG Scatter\] ranks=(?P<p>\d+)\s+compute_time=(?P<time>[\d.]+)"),
    ("LoG",    4): re.compile(r"\[LoG MPI Pipeline\] N=(?P<p>\d+)\s+total_time=(?P<time>[\d.]+)"),

    # ── FFT ───────────────────────────────────────────────────────────────────
    ("FFT",    1): re.compile(r"FFT Arch1 \(Farm\) Time:\s*(?P<time>[\d.]+) s using (?P<p>\d+) threads"),
    ("FFT",    2): re.compile(r"FFT Arch2 \(Pipeline\) Time:\s*(?P<time>[\d.]+)"),
    ("FFT",    3): re.compile(r"FFT Arch3 \(Dist Dynamic/Scatter-Gather\) Time:\s*(?P<time>[\d.]+)"),
    ("FFT",    4): re.compile(r"FFT Arch4 \(Dist Pipeline\) Total Time:\s*(?P<time>[\d.]+)"),

    # ── Resilience ────────────────────────────────────────────────────────────
    ("resilience", 1): re.compile(r"\[Test 1\] Recovery complete\. Total time:\s*(?P<time>[\d.]+) ms"),
    ("resilience", 2): re.compile(r"\[Test 2\] Straggler detected: rank (?P<rank>\d+) \((?P<time>[\d.]+) ms delay"),
    ("resilience", 3): re.compile(r"\[Test 3\] Coordinator recovery complete\. Time with new coord:\s*(?P<time>[\d.]+) ms"),
    ("resilience", 4): re.compile(r"\[Test 4\] Partial result assembled"),
}


# ── Parser ────────────────────────────────────────────────────────────────────

def parse_log(log_path, node_counts, thread_counts):
    """
    Returns a nested dict:
      data[img_name][filter][arch] = list of (parallelism_count, time_s)
      data[img_name]['baseline'][filter] = time_s
      data[img_name]['resilience'] = {test_id: value}
    """
    data = {}
    current_img = None

    # Track per-image counters so we know which node/thread value to pair
    # with patterns that don't embed the count in their output.
    counters = {}

    def img_key(path):
        return os.path.basename(path)

    with open(log_path, "r", errors="replace") as f:
        lines = f.readlines()

    for line in lines:
        line = line.rstrip()

        # ── New image block ───────────────────────────────────────────────────
        if line.startswith("IMAGE:"):
            raw = line.split("IMAGE:", 1)[1].strip()
            current_img = img_key(raw)
            if current_img not in data:
                data[current_img] = {
                    "baseline": {},
                    "resilience": {},
                    **{f: {a: [] for a in ARCHS} for f in FILTERS},
                }
            # Reset counters for this image
            counters[current_img] = {
                (f, a): 0 for f in FILTERS for a in ARCHS
            }
            counters[current_img][("resilience",)] = 0
            continue

        if current_img is None:
            continue

        img_data = data[current_img]

        # ── Baseline ─────────────────────────────────────────────────────────
        for flt in FILTERS:
            pat = PATTERNS.get((flt, 0))
            if pat:
                m = pat.search(line)
                if m:
                    img_data["baseline"][flt] = float(m.group("time"))

        # ── Arch results ─────────────────────────────────────────────────────
        for flt in FILTERS:
            for arch in ARCHS:
                pat = PATTERNS.get((flt, arch))
                if pat is None:
                    continue
                m = pat.search(line)
                if not m:
                    continue

                time_val = float(m.group("time"))

                # Try to get parallelism count directly from the match
                try:
                    p = int(m.group("p"))
                except IndexError:
                    # Pattern has no 'p' group — use counter to index into the
                    # appropriate list (threads for arch1/2, nodes for arch3/4)
                    idx = counters[current_img][(flt, arch)]
                    if ARCH_PARALLELISM[arch] == "threads":
                        p = thread_counts[idx] if idx < len(thread_counts) else idx + 1
                    else:
                        p = node_counts[idx] if idx < len(node_counts) else idx + 2
                    counters[current_img][(flt, arch)] += 1

                img_data[flt][arch].append((p, time_val))

        # ── Resilience ───────────────────────────────────────────────────────
        for test_id in [1, 2, 3, 4]:
            pat = PATTERNS.get(("resilience", test_id))
            if pat is None:
                continue
            m = pat.search(line)
            if m:
                try:
                    img_data["resilience"][test_id] = float(m.group("time"))
                except IndexError:
                    img_data["resilience"][test_id] = "passed"

    return data


# ── Plotting helpers ──────────────────────────────────────────────────────────

COLORS = ["#2196F3", "#4CAF50", "#FF5722", "#9C27B0"]


def _speedup_plots(ax_sp, ax_eff, ax_br, points, serial_time, arch, label):
    """Fill three axes: speedup, efficiency, Brent's law."""
    if not points:
        return
    ps = np.array([x[0] for x in points])
    ts = np.array([x[1] for x in points])

    speedup = serial_time / ts
    eff     = speedup / ps

    color = COLORS[arch - 1]

    ax_sp.plot(ps, speedup, "o-", color=color, label=label)
    ax_eff.plot(ps, eff,    "o-", color=color, label=label)
    ax_br.plot(1 / ps, ts,  "o-", color=color, label=label)


def plot_filter(img_name, filter_name, arch_data, baseline_time, outdir):
    """One figure per filter: speedup / efficiency / Brent's law for all archs."""
    fig, axes = plt.subplots(1, 3, figsize=(15, 4))
    fig.suptitle(f"{filter_name} — {img_name}", fontsize=12, fontweight="bold")

    ax_sp, ax_eff, ax_br = axes

    # Amdahl reference curve (assumes 90 % parallel fraction)
    p_ref = np.linspace(1, 20, 200)
    f_par = 0.9
    ax_sp.plot(p_ref, 1 / ((1 - f_par) + f_par / p_ref),
               "k--", alpha=0.4, label="Amdahl f=0.9")

    any_data = False
    for arch in ARCHS:
        points = arch_data.get(arch, [])
        if not points:
            continue
        any_data = True
        _speedup_plots(ax_sp, ax_eff, ax_br,
                       points, baseline_time, arch, ARCH_LABELS[arch])

    for ax, title, xlabel, ylabel in [
        (ax_sp,  "Speedup (Amdahl)",         "Parallelism (p)", "Speedup"),
        (ax_eff, "Efficiency",                "Parallelism (p)", "E = S/p"),
        (ax_br,  "Brent's Law (T vs 1/p)",   "1/p",             "Time (s)"),
    ]:
        ax.set_title(title)
        ax.set_xlabel(xlabel)
        ax.set_ylabel(ylabel)
        ax.legend(fontsize=7)
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    safe = img_name.replace("/", "_").replace(" ", "_")
    path = os.path.join(outdir, f"{filter_name.lower()}_{safe}.png")
    plt.savefig(path, dpi=120)
    plt.close(fig)
    print(f"  Saved: {path}")

    if not any_data:
        print(f"  [WARN] No data for {filter_name} / {img_name} — plot is blank")


def plot_cross_filter_comparison(img_name, img_data, outdir):
    """Bar chart comparing serial baseline times across all four filters."""
    baselines = img_data.get("baseline", {})
    if not baselines:
        return

    filters = [f for f in FILTERS if f in baselines]
    times   = [baselines[f] for f in filters]

    fig, ax = plt.subplots(figsize=(7, 4))
    bars = ax.bar(filters, times, color=COLORS[:len(filters)])
    ax.set_title(f"Serial Baseline Comparison — {img_name}", fontweight="bold")
    ax.set_ylabel("Time (s)")
    ax.set_xlabel("Filter")
    for bar, t in zip(bars, times):
        ax.text(bar.get_x() + bar.get_width() / 2,
                bar.get_height() + max(times) * 0.01,
                f"{t:.3f}s", ha="center", va="bottom", fontsize=9)
    ax.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()

    safe = img_name.replace("/", "_").replace(" ", "_")
    path = os.path.join(outdir, f"baseline_comparison_{safe}.png")
    plt.savefig(path, dpi=120)
    plt.close(fig)
    print(f"  Saved: {path}")


def plot_resilience(resilience_data, outdir):
    """Bar chart for the resilience test recovery times."""
    if not resilience_data:
        print("  [WARN] No resilience data found")
        return

    labels = {
        1: "Test 1\nWorker Crash",
        2: "Test 2\nSlow Node\n(straggler delay)",
        3: "Test 3\nCoord Recovery",
    }

    test_ids = [t for t in [1, 2, 3] if t in resilience_data and
                isinstance(resilience_data[t], float)]

    if not test_ids:
        print("  [WARN] No numeric resilience times to plot")
        return

    fig, ax = plt.subplots(figsize=(7, 4))
    values = [resilience_data[t] for t in test_ids]
    lbls   = [labels[t] for t in test_ids]
    bars   = ax.bar(lbls, values, color=["#E53935", "#FB8C00", "#8E24AA"])

    # Test 4 note (partial result — pass/fail, no time)
    note = ""
    if 4 in resilience_data:
        note = "\nTest 4 (Partial Result): passed"

    ax.set_title(f"Resilience — Recovery Times (ms){note}", fontweight="bold")
    ax.set_ylabel("Recovery Time (ms)")
    for bar, v in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width() / 2,
                bar.get_height() + max(values) * 0.01,
                f"{v:.1f} ms", ha="center", va="bottom", fontsize=9)
    ax.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()

    path = os.path.join(outdir, "resilience_summary.png")
    plt.savefig(path, dpi=120)
    plt.close(fig)
    print(f"  Saved: {path}")


def create_visual_comparison(outdir):
    """Assemble output images from all filters/archs into one side-by-side figure."""
    if not HAS_PIL:
        print("  [WARN] Pillow not installed — skipping visual comparison")
        return

    slots = [
        ("workspace/original_gray.png",  "Original Gray"),
        ("workspace/sobel_out.png",       "Sobel"),
        ("workspace/canny_out.png",       "Canny"),
        ("workspace/log_out.png",         "LoG"),
        ("workspace/fft_edge_out.png",    "FFT Edge"),
        ("workspace/sobel_arch1_out.png", "Sobel A1"),
        ("workspace/sobel_arch3_out.png", "Sobel A3"),
        ("workspace/canny_arch1_out.png", "Canny A1"),
        ("workspace/canny_arch3_out.png", "Canny A3"),
        ("workspace/fft_arch1_out.png",   "FFT A1"),
        ("workspace/fft_arch3_out.png",   "FFT A3"),
    ]

    valid = [(p, t) for p, t in slots if os.path.exists(p)]
    if not valid:
        print("  [WARN] No output images found for visual comparison")
        return

    n = len(valid)
    fig, axes = plt.subplots(1, n, figsize=(4 * n, 4))
    if n == 1:
        axes = [axes]

    for ax, (fpath, title) in zip(axes, valid):
        try:
            img = PILImage.open(fpath).convert("L")
            ax.imshow(img, cmap="gray")
            ax.set_title(title, fontsize=9)
        except Exception as e:
            ax.set_title(f"{title}\n(load error)", fontsize=8)
        ax.axis("off")

    plt.suptitle("Visual Output Comparison", fontsize=12, fontweight="bold")
    plt.tight_layout()
    path = os.path.join(outdir, "visual_comparison.png")
    plt.savefig(path, dpi=100)
    plt.close(fig)
    print(f"  Saved: {path}")


def write_summary_csv(data, outdir):
    """Write a flat CSV with all measured times."""
    path = os.path.join(outdir, "summary_table.csv")
    rows = []
    for img, img_data in data.items():
        # Baselines
        for flt, t in img_data.get("baseline", {}).items():
            rows.append({
                "image": img, "filter": flt, "arch": "serial",
                "parallelism_type": "-", "p": 1, "time_s": f"{t:.6f}"
            })
        # Arch results
        for flt in FILTERS:
            for arch in ARCHS:
                for p, t in img_data.get(flt, {}).get(arch, []):
                    rows.append({
                        "image": img, "filter": flt,
                        "arch": arch,
                        "parallelism_type": ARCH_PARALLELISM[arch],
                        "p": p, "time_s": f"{t:.6f}"
                    })
        # Resilience
        for tid, val in img_data.get("resilience", {}).items():
            rows.append({
                "image": img, "filter": "resilience",
                "arch": f"test{tid}",
                "parallelism_type": "-",
                "p": "-",
                "time_s": str(val)
            })

    if not rows:
        print("  [WARN] No data to write to CSV")
        return

    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["image","filter","arch","parallelism_type","p","time_s"])
        writer.writeheader()
        writer.writerows(rows)
    print(f"  Saved: {path}")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Generate Milestone 2 analysis report")
    parser.add_argument("--log",            default="analysis_results.log")
    parser.add_argument("--outdir",         default="report")
    parser.add_argument("--node-counts",    default="2 4 6")
    parser.add_argument("--thread-counts",  default="1 2 4")
    args = parser.parse_args()

    node_counts   = [int(x) for x in args.node_counts.split()]
    thread_counts = [int(x) for x in args.thread_counts.split()]

    if not os.path.exists(args.log):
        print(f"[ERROR] Log file not found: {args.log}")
        print("Run ./run_analysis.sh first.")
        sys.exit(1)

    os.makedirs(args.outdir, exist_ok=True)

    print(f"\nParsing {args.log} …")
    data = parse_log(args.log, node_counts, thread_counts)

    if not data:
        print("[ERROR] No IMAGE: blocks found in log. Nothing to plot.")
        sys.exit(1)

    print(f"Found {len(data)} image(s): {list(data.keys())}\n")

    # ── Per-image plots ───────────────────────────────────────────────────────
    for img_name, img_data in data.items():
        print(f"── {img_name} ──")

        # Baseline comparison
        plot_cross_filter_comparison(img_name, img_data, args.outdir)

        # Per-filter speedup charts
        for flt in FILTERS:
            baseline = img_data["baseline"].get(flt)
            if baseline is None:
                # Fall back to slowest arch time as pseudo-serial
                all_times = [t for a in ARCHS
                             for _, t in img_data.get(flt, {}).get(a, [])]
                baseline = max(all_times) if all_times else 1.0
                if all_times:
                    print(f"  [INFO] No serial baseline for {flt}; using max arch time as T1")

            plot_filter(img_name, flt, img_data.get(flt, {}), baseline, args.outdir)

    # ── Resilience (aggregate across images) ─────────────────────────────────
    print("── Resilience ──")
    merged_resilience = {}
    for img_data in data.values():
        for tid, val in img_data.get("resilience", {}).items():
            if isinstance(val, float):
                merged_resilience.setdefault(tid, []).append(val)

    avg_resilience = {tid: sum(vs) / len(vs) for tid, vs in merged_resilience.items()}
    plot_resilience(avg_resilience, args.outdir)

    # ── Visual comparison ─────────────────────────────────────────────────────
    print("── Visual comparison ──")
    create_visual_comparison(args.outdir)

    # ── CSV summary ───────────────────────────────────────────────────────────
    print("── Summary CSV ──")
    write_summary_csv(data, args.outdir)

    print(f"\nReport complete → {args.outdir}/")
    charts = [f for f in os.listdir(args.outdir) if f.endswith(".png")]
    print(f"Charts generated: {len(charts)}")
    for c in sorted(charts):
        print(f"  {args.outdir}/{c}")


if __name__ == "__main__":
    main()
