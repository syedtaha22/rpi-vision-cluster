#!/usr/bin/env python3
"""
generate_report.py — Multi-Image-Size Performance Report
Parses analysis_results.log (from run_analysis.sh) and produces:

  report/
  ├── fig1_serial_baselines.png          Bar chart of serial times per image size
  ├── fig2_fft_arch_comparison.png       Grouped bar: FFT all configurations
  ├── fig3_arch3_speedup_efficiency.png  Speedup + efficiency curves for Arch3
  ├── fig4_openmp_scaling.png            OpenMP thread scaling (anti-speedup)
  ├── fig5_spatial_arch3_speedup.png     Arch3 Scatter-Gather for Sobel/Canny/LoG
  ├── fig6_architecture_summary.png      Summary table as heat-map bar chart
  ├── fig7_brents_law.png                Brent's Law T_p vs 1/p
  └── summary_table.csv

Usage:
  python3 generate_report.py                            # defaults
  python3 generate_report.py --log my.log --outdir out
  python3 generate_report.py --node-counts "2 4 6" --thread-counts "1 2 4"
"""

import argparse
import csv
import os
import re
import sys
from collections import defaultdict

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
    import numpy as np
except ImportError:
    print("[ERROR] matplotlib / numpy not installed: pip install matplotlib numpy")
    sys.exit(1)

try:
    from PIL import Image as PILImage
    HAS_PIL = True
except ImportError:
    HAS_PIL = False

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

FILTERS       = ["Sobel", "Canny", "LoG", "FFT"]
ARCHS         = [1, 2, 3, 4]
ARCH_LABELS   = {
    1: "Arch1\nOMP Farm",
    2: "Arch2\nOMP Pipeline",
    3: "Arch3\nMPI Scatter",
    4: "Arch4\nMPI Pipeline",
}
ARCH_LABELS_SHORT = {1: "Arch1 (OMP Farm)", 2: "Arch2 (OMP Pipeline)",
                      3: "Arch3 (MPI Scatter)", 4: "Arch4 (MPI Pipeline)"}
ARCH_PAR = {1: "threads", 2: "threads", 3: "nodes", 4: "nodes"}

# Color palette consistent with the PDF report
ARCH_COLORS   = ["#2196F3", "#4CAF50", "#FF5722", "#9C27B0"]
FILTER_COLORS = {"Sobel": "#2196F3", "Canny": "#F44336",
                 "LoG": "#4CAF50", "FFT": "#FF9800"}

# Image size labels
SIZE_LABELS = {
    "tabby_s_000074":   "CIFAR-10 (32×32)",
    "test_0":           "Tiny-ImageNet (64×64)",
    "000000144003":     "COCO (480×640)",
}

# ── Log patterns ──────────────────────────────────────────────────────────────
PATTERNS = {
    ("Sobel", 0): re.compile(r"Sobel time:\s*(?P<time>[\d.]+)"),
    ("LoG",   0): re.compile(r"LoG time:\s*(?P<time>[\d.]+)"),
    ("Canny", 0): re.compile(r"Canny time:\s*(?P<time>[\d.]+)"),
    ("FFT",   0): re.compile(r"FFT Edge time:\s*(?P<time>[\d.]+)"),

    ("Sobel", 1): re.compile(r"\[Sobel Farm\] threads=(?P<p>\d+)\s+time=(?P<time>[\d.]+)"),
    ("Sobel", 2): re.compile(r"\[Sobel Pipeline\] chunk_rows=\d+\s+time=(?P<time>[\d.]+)"),
    ("Sobel", 3): re.compile(r"\[Sobel Scatter\] ranks=(?P<p>\d+)\s+compute_time=(?P<time>[\d.]+)"),
    ("Sobel", 4): re.compile(r"\[Sobel MPI Pipeline\] N=(?P<p>\d+)\s+total_time=(?P<time>[\d.]+)"),

    ("Canny", 1): re.compile(r"\[Canny Farm\] threads=(?P<p>\d+)\s+time=(?P<time>[\d.]+)"),
    ("Canny", 2): re.compile(r"\[Canny Pipeline\] chunk_rows=\d+\s+time=(?P<time>[\d.]+)"),
    ("Canny", 3): re.compile(r"\[Canny Scatter\] ranks=(?P<p>\d+)\s+total_time=(?P<time>[\d.]+)"),
    ("Canny", 4): re.compile(r"\[Canny Pipeline\] N=(?P<p>\d+)\s+total_time=(?P<time>[\d.]+)"),

    ("LoG",   1): re.compile(r"\[LoG Farm\] threads=(?P<p>\d+)\s+time=(?P<time>[\d.]+)"),
    ("LoG",   2): re.compile(r"\[LoG Pipeline\] chunk_rows=\d+\s+time=(?P<time>[\d.]+)"),
    ("LoG",   3): re.compile(r"\[LoG Scatter\] ranks=(?P<p>\d+)\s+compute_time=(?P<time>[\d.]+)"),
    ("LoG",   4): re.compile(r"\[LoG MPI Pipeline\] N=(?P<p>\d+)\s+total_time=(?P<time>[\d.]+)"),

    ("FFT",   1): re.compile(r"FFT Arch1 \(Farm\) Time:\s*(?P<time>[\d.]+) s using (?P<p>\d+) threads"),
    ("FFT",   2): re.compile(r"FFT Arch2 \(Pipeline\) Time:\s*(?P<time>[\d.]+)"),
    ("FFT",   3): re.compile(r"FFT Arch3 \(Dist Dynamic/Scatter-Gather\) Time:\s*(?P<time>[\d.]+)"),
    ("FFT",   4): re.compile(r"FFT Arch4 \(Dist Pipeline\) Total Time:\s*(?P<time>[\d.]+)"),
}


def parse_log(log_path, node_counts, thread_counts):
    data = {}
    current_img = None
    counters = {}

    def img_key(path):
        return os.path.basename(path)

    with open(log_path, "r", errors="replace") as f:
        lines = f.readlines()

    for line in lines:
        line = line.rstrip()
        if line.startswith("IMAGE:"):
            raw = line.split("IMAGE:", 1)[1].strip()
            current_img = img_key(raw)
            if current_img not in data:
                data[current_img] = {
                    "baseline": {},
                    **{flt: {a: [] for a in ARCHS} for flt in FILTERS},
                }
            counters[current_img] = {(flt, a): 0 for flt in FILTERS for a in ARCHS}
            continue

        if current_img is None:
            continue

        img_data = data[current_img]

        for flt in FILTERS:
            pat = PATTERNS.get((flt, 0))
            if pat:
                m = pat.search(line)
                if m:
                    img_data["baseline"][flt] = float(m.group("time"))

        for flt in FILTERS:
            for arch in ARCHS:
                pat = PATTERNS.get((flt, arch))
                if pat is None:
                    continue
                m = pat.search(line)
                if not m:
                    continue
                time_val = float(m.group("time"))
                try:
                    p = int(m.group("p"))
                except IndexError:
                    idx = counters[current_img][(flt, arch)]
                    pool = thread_counts if ARCH_PAR[arch] == "threads" else node_counts
                    p = pool[idx] if idx < len(pool) else idx + 1
                    counters[current_img][(flt, arch)] += 1
                img_data[flt][arch].append((p, time_val))

    return data


def _size_label(img_name):
    stem = img_name.replace(".", "_")
    for key, lbl in SIZE_LABELS.items():
        if key in stem:
            return lbl
    return img_name


def _annotate_bars(ax, bars, values, fmt="{:.3f}s", pad_frac=0.015):
    if not values:
        return
    pad = max(values) * pad_frac
    for bar, v in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width() / 2,
                bar.get_height() + pad,
                fmt.format(v), ha="center", va="bottom", fontsize=8)


# ── Figure 1: Serial baseline comparison ─────────────────────────────────────
def fig1_serial_baselines(data, outdir):
    """Grouped bar chart of serial baseline times across image sizes."""
    imgs = list(data.keys())
    if not imgs:
        return

    # Determine filters with data
    filters_with_data = [flt for flt in FILTERS
                         if any(flt in data[img]["baseline"] for img in imgs)]
    if not filters_with_data:
        print("  [WARN] No baseline data for Fig 1")
        return

    x = np.arange(len(filters_with_data))
    n_imgs = len(imgs)
    width = 0.7 / n_imgs

    fig, ax = plt.subplots(figsize=(9, 5))
    img_colors = ["#1565C0", "#2E7D32", "#BF360C"][:n_imgs]

    for i, img in enumerate(imgs):
        vals = [data[img]["baseline"].get(flt, 0) for flt in filters_with_data]
        offset = (i - (n_imgs - 1) / 2) * width
        bars = ax.bar(x + offset, vals, width, label=_size_label(img),
                      color=img_colors[i % len(img_colors)], alpha=0.85, edgecolor="white")
        _annotate_bars(ax, bars, vals, fmt="{:.3f}s")

    ax.set_title("Serial Baseline Filter Times — All Image Sizes")
    ax.set_xlabel("Filter")
    ax.set_ylabel("Mean Wall-Clock Time (s)")
    ax.set_xticks(x)
    ax.set_xticklabels(filters_with_data)
    ax.legend(title="Image Size", loc="upper left")
    ax.yaxis.set_major_formatter(ticker.FormatStrFormatter("%.3f"))

    path = os.path.join(outdir, "fig1_serial_baselines.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 2: FFT architecture comparison (like report Figure 2) ─────────────
def fig2_fft_arch_comparison(data, node_counts, thread_counts, outdir):
    """Grouped bar of FFT wall-clock time for every configuration."""
    # Collect all configs for one representative image
    imgs = list(data.keys())
    if not imgs:
        return
    # Use the image with the most data
    img = max(imgs, key=lambda i: sum(len(data[i]["FFT"][a]) for a in ARCHS))
    img_data = data[img]
    baseline = img_data["baseline"].get("FFT", None)

    configs, times, labels = [], [], []

    # Arch1 threads
    for p, t in sorted(img_data["FFT"][1]):
        configs.append(f"Arch1\nT={p}")
        times.append(t)

    # Arch2 single entry
    for _, t in img_data["FFT"][2]:
        configs.append("Arch2\n(pipeline)")
        times.append(t)
        break

    # Arch3 nodes
    for p, t in sorted(img_data["FFT"][3]):
        configs.append(f"Arch3\n{p} nodes")
        times.append(t)

    # Arch4 nodes
    for p, t in sorted(img_data["FFT"][4]):
        configs.append(f"Arch4\n{p} nodes")
        times.append(t)

    if not configs:
        print("  [WARN] No FFT data for Fig 2")
        return

    # Color by arch
    bar_colors = []
    for cfg in configs:
        if "Arch1" in cfg: bar_colors.append(ARCH_COLORS[0])
        elif "Arch2" in cfg: bar_colors.append(ARCH_COLORS[1])
        elif "Arch3" in cfg: bar_colors.append(ARCH_COLORS[2])
        else: bar_colors.append(ARCH_COLORS[3])

    fig, ax = plt.subplots(figsize=(max(10, len(configs) * 0.9), 5))
    bars = ax.bar(configs, times, color=bar_colors, alpha=0.85, edgecolor="white", width=0.6)
    _annotate_bars(ax, bars, times)

    if baseline:
        ax.axhline(baseline, color="black", linestyle="--", alpha=0.5,
                   label=f"Serial baseline ({baseline:.3f}s)")
        ax.legend()

    ax.set_title(f"FFT Architecture Comparison — {_size_label(img)}")
    ax.set_ylabel("Mean Wall-Clock Time (s)")
    ax.set_xlabel("Configuration")

    # Add arch legend patches
    from matplotlib.patches import Patch
    legend_elems = [Patch(facecolor=ARCH_COLORS[i], label=ARCH_LABELS_SHORT[i+1])
                    for i in range(4)]
    ax.legend(handles=legend_elems, loc="upper right", fontsize=8)

    path = os.path.join(outdir, "fig2_fft_arch_comparison.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 3: Arch3 speedup + efficiency curves ───────────────────────────────
def fig3_arch3_speedup_efficiency(data, outdir):
    """Left: Speedup vs node count with Amdahl fit. Right: Efficiency."""
    imgs = list(data.keys())
    if not imgs:
        return

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    fig.suptitle("Arch3 (MPI Scatter-Gather) — Speedup & Efficiency")

    for img, color in zip(imgs, ["#1565C0", "#2E7D32", "#BF360C"]):
        img_data = data[img]
        lbl = _size_label(img)
        for flt in ["FFT"]:  # FFT shows the clearest speedup
            baseline = img_data["baseline"].get(flt)
            points = sorted(img_data[flt][3])
            if not points or baseline is None:
                continue
            ps = np.array([x[0] for x in points], dtype=float)
            ts = np.array([x[1] for x in points], dtype=float)
            sp = baseline / ts
            eff = sp / ps

            axes[0].plot(ps, sp, "o-", color=color, label=lbl, linewidth=2, markersize=7)
            axes[1].plot(ps, eff, "o-", color=color, label=lbl, linewidth=2, markersize=7)

            # Annotate peak speedup
            best_idx = np.argmax(sp)
            axes[0].annotate(f"{sp[best_idx]:.2f}×",
                             xy=(ps[best_idx], sp[best_idx]),
                             xytext=(5, 5), textcoords="offset points", fontsize=8)

    # Amdahl reference
    p_ref = np.linspace(1, max([max([x[0] for x in data[i]["FFT"][3]] or [1])
                                for i in imgs] or [6]) + 1, 200)
    for f_par, ls in [(0.92, "--"), (0.9, ":")]:
        axes[0].plot(p_ref, 1 / ((1 - f_par) + f_par / p_ref),
                     ls, color="gray", alpha=0.5, linewidth=1.2,
                     label=f"Amdahl f={f_par}")

    axes[0].axhline(1.0, color="black", linestyle=":", alpha=0.3)
    axes[1].axhline(1.0, color="black", linestyle="--", alpha=0.4, label="Ideal E=1")
    axes[1].axhline(0.5, color="orange", linestyle=":", alpha=0.4, label="E=0.5")

    for ax, ylabel, title in [
        (axes[0], "Speedup S(p)", "Speedup (Amdahl's Law)"),
        (axes[1], "Efficiency E = S/p", "Parallel Efficiency"),
    ]:
        ax.set_xlabel("MPI Ranks (p)")
        ax.set_ylabel(ylabel)
        ax.set_title(title)
        ax.legend(fontsize=8)

    path = os.path.join(outdir, "fig3_arch3_speedup_efficiency.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 4: OpenMP scaling (anti-speedup under QEMU) ───────────────────────
def fig4_openmp_scaling(data, outdir):
    """Line chart: wall-clock time vs thread count for spatial filters (Arch1)."""
    imgs = list(data.keys())
    if not imgs:
        return

    spatial = ["Sobel", "Canny", "LoG"]
    fig, axes = plt.subplots(1, len(imgs), figsize=(5 * len(imgs), 4), sharey=False)
    if len(imgs) == 1:
        axes = [axes]
    fig.suptitle("OpenMP Farm (Arch1) Scaling — All Image Sizes\n"
                 "(Anti-speedup is a QEMU emulation artefact, not a hardware result)")

    markers = ["o", "s", "^"]
    for ax, img in zip(axes, imgs):
        ax.set_title(_size_label(img))
        for flt, marker in zip(spatial, markers):
            points = sorted(data[img][flt].get(1, []))
            if not points:
                continue
            ps = [x[0] for x in points]
            ts = [x[1] for x in points]
            ax.plot(ps, ts, f"{marker}-",
                    color=FILTER_COLORS[flt], label=flt,
                    linewidth=2, markersize=7)
        ax.set_xlabel("OpenMP Threads")
        ax.set_ylabel("Time (s)")
        ax.legend()

    path = os.path.join(outdir, "fig4_openmp_scaling.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 5: Arch3 scatter-gather speedup for spatial filters ───────────────
def fig5_spatial_arch3_speedup(data, outdir):
    """3-panel: Speedup | Efficiency | Brent's Law for Sobel, Canny, LoG via Arch3."""
    spatial = ["Sobel", "Canny", "LoG"]
    imgs = list(data.keys())
    if not imgs:
        return

    # Use image with most data
    img = max(imgs, key=lambda i: sum(len(data[i][flt][3]) for flt in spatial))
    img_data = data[img]

    fig, axes = plt.subplots(1, 3, figsize=(15, 5))
    fig.suptitle(f"Arch3 (MPI Scatter-Gather) — Spatial Filters — {_size_label(img)}")

    ax_sp, ax_eff, ax_br = axes

    # Amdahl reference
    p_ref = np.linspace(1, 10, 200)
    ax_sp.plot(p_ref, 1 / (0.1 + 0.9 / p_ref), "k--", alpha=0.3,
               linewidth=1.2, label="Amdahl f=0.90")
    ax_sp.axhline(1.0, color="black", linestyle=":", alpha=0.2)

    for flt, color in zip(spatial, [FILTER_COLORS[f] for f in spatial]):
        baseline = img_data["baseline"].get(flt)
        points = sorted(img_data[flt][3])
        if not points or baseline is None:
            continue
        ps = np.array([x[0] for x in points], dtype=float)
        ts = np.array([x[1] for x in points], dtype=float)
        sp = baseline / ts
        eff = sp / ps
        inv_p = 1.0 / ps

        ax_sp.plot(ps, sp, "o-", color=color, label=flt, linewidth=2, markersize=7)
        ax_eff.plot(ps, eff, "o-", color=color, label=flt, linewidth=2, markersize=7)
        ax_br.plot(inv_p, ts, "o-", color=color, label=flt, linewidth=2, markersize=7)

        # Annotate values on speedup
        for p_val, sp_val in zip(ps, sp):
            ax_sp.annotate(f"{sp_val:.2f}×", xy=(p_val, sp_val),
                           xytext=(4, 4), textcoords="offset points", fontsize=7)

        # Brent's Law linear fit
        if len(ps) >= 2:
            coef = np.polyfit(inv_p, ts, 1)
            t_inf = coef[1]
            x_fit = np.linspace(0, inv_p.max() * 1.1, 80)
            ax_br.plot(x_fit, np.polyval(coef, x_fit), "--",
                       color=color, alpha=0.5, linewidth=1.2,
                       label=f"{flt} T∞≈{t_inf:.4f}s")

    ax_eff.axhline(1.0, color="black", linestyle="--", alpha=0.3, label="Ideal E=1")

    for ax, title, xl, yl in [
        (ax_sp,  "Speedup (Amdahl's Law)", "MPI Ranks", "Speedup"),
        (ax_eff, "Efficiency E = S/p",      "MPI Ranks", "Efficiency"),
        (ax_br,  "Brent's Law T_p vs 1/p", "1/p",       "Time (s)"),
    ]:
        ax.set_title(title)
        ax.set_xlabel(xl)
        ax.set_ylabel(yl)
        ax.legend(fontsize=8)

    path = os.path.join(outdir, "fig5_spatial_arch3_speedup.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 6: Architecture summary (best time per filter per arch) ─────────────
def fig6_architecture_summary(data, outdir):
    """Grouped bars: best observed time per (filter, arch) across all images."""
    imgs = list(data.keys())
    if not imgs:
        return

    x = np.arange(len(FILTERS))
    width = 0.18
    fig, ax = plt.subplots(figsize=(11, 5))

    for i, arch in enumerate(ARCHS):
        best_times = []
        for flt in FILTERS:
            all_t = [t for img in imgs
                     for _, t in data[img][flt].get(arch, [])]
            best_times.append(min(all_t) if all_t else 0)
        offset = (i - 1.5) * width
        bars = ax.bar(x + offset, best_times, width,
                      color=ARCH_COLORS[i], label=ARCH_LABELS_SHORT[arch],
                      alpha=0.85, edgecolor="white")
        for bar, v in zip(bars, best_times):
            if v > 0:
                ax.text(bar.get_x() + bar.get_width() / 2,
                        bar.get_height() + 0.001,
                        f"{v:.3f}", ha="center", va="bottom", fontsize=7)

    ax.set_title("Architecture Summary — Best Observed Time per Filter")
    ax.set_xlabel("Filter")
    ax.set_ylabel("Best Time (s)  [lower is better]")
    ax.set_xticks(x)
    ax.set_xticklabels(FILTERS)
    ax.legend(fontsize=8)

    path = os.path.join(outdir, "fig6_architecture_summary.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 7: Brent's Law (T_p vs 1/p) ───────────────────────────────────────
def fig7_brents_law(data, outdir):
    """2×2 grid: Brent's Law for each filter, Arch3 and Arch4."""
    imgs = list(data.keys())
    if not imgs:
        return

    fig, axes = plt.subplots(2, 2, figsize=(12, 8))
    fig.suptitle("Brent's Law  T_p vs 1/p  (MPI Architectures)")
    axes_flat = axes.flatten()

    for idx, flt in enumerate(FILTERS):
        ax = axes_flat[idx]
        ax.set_title(flt)

        for arch, color in zip([3, 4], [ARCH_COLORS[2], ARCH_COLORS[3]]):
            # Aggregate across images
            bucket = defaultdict(list)
            for img in imgs:
                for p, t in data[img][flt].get(arch, []):
                    bucket[p].append(t)
            if not bucket:
                continue
            ps = np.array(sorted(bucket.keys()), dtype=float)
            ts = np.array([np.mean(bucket[p]) for p in ps])
            inv_p = 1.0 / ps
            ax.plot(inv_p, ts, "o-", color=color, label=ARCH_LABELS_SHORT[arch],
                    linewidth=2, markersize=6)
            if len(ps) >= 2:
                coef = np.polyfit(inv_p, ts, 1)
                t_inf = coef[1]
                x_fit = np.linspace(0, inv_p.max() * 1.1, 60)
                ax.plot(x_fit, np.polyval(coef, x_fit), "--", color=color,
                        alpha=0.5, linewidth=1.2, label=f"A{arch} T∞≈{t_inf:.4f}s")

        ax.set_xlabel("1/p")
        ax.set_ylabel("T_p (s)")
        ax.legend(fontsize=7)

    plt.tight_layout()
    path = os.path.join(outdir, "fig7_brents_law.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Visual comparison grid ────────────────────────────────────────────────────
def fig8_visual_comparison(data, workspace_dir, outdir):
    """Side-by-side filter output comparison if output images are present."""
    if not HAS_PIL:
        print("  [SKIP] Pillow not installed — visual comparison skipped")
        return

    slots = [
        ("workspace/results/out", "sobel_arch1"),
        ("workspace/results/out", "sobel_arch3"),
        ("workspace/results/out", "canny_arch1"),
        ("workspace/results/out", "canny_arch3"),
        ("workspace/results/out", "log_arch1"),
        ("workspace/results/out", "log_arch3"),
    ]

    found = []
    if os.path.isdir(os.path.join(workspace_dir, "results/out")):
        out_dir = os.path.join(workspace_dir, "results/out")
        for fn in sorted(os.listdir(out_dir)):
            if fn.endswith(".png"):
                found.append((fn.replace(".png", ""), os.path.join(out_dir, fn)))

    if not found:
        print("  [SKIP] No output images found for visual comparison")
        return

    # Show up to 12 images in a 3×4 grid
    found = found[:12]
    n_cols = min(4, len(found))
    n_rows = (len(found) + n_cols - 1) // n_cols
    fig, axes = plt.subplots(n_rows, n_cols, figsize=(3.5 * n_cols, 3.5 * n_rows))
    axes_flat = np.array(axes).flatten()
    fig.suptitle("Reconstructed Filter Outputs", fontsize=12, fontweight="bold")

    for ax, (label, fpath) in zip(axes_flat, found):
        try:
            img = PILImage.open(fpath).convert("L")
            ax.imshow(np.array(img), cmap="gray", interpolation="lanczos")
        except Exception:
            ax.text(0.5, 0.5, "Error", ha="center", va="center",
                    transform=ax.transAxes)
        ax.set_title(label[:25], fontsize=7)
        ax.axis("off")
    for ax in axes_flat[len(found):]:
        ax.axis("off")

    path = os.path.join(outdir, "fig8_visual_comparison.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── CSV summary ───────────────────────────────────────────────────────────────
def write_csv(data, outdir):
    rows = []
    for img, img_data in data.items():
        for flt, t in img_data.get("baseline", {}).items():
            rows.append({"image": img, "filter": flt, "arch": "serial",
                         "par_type": "-", "p": 1, "time_s": f"{t:.6f}"})
        for flt in FILTERS:
            for arch in ARCHS:
                for p, t in img_data.get(flt, {}).get(arch, []):
                    rows.append({"image": img, "filter": flt, "arch": arch,
                                 "par_type": ARCH_PAR[arch], "p": p,
                                 "time_s": f"{t:.6f}"})
    if not rows:
        print("  [WARN] No data to write to CSV")
        return
    path = os.path.join(outdir, "summary_table.csv")
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["image", "filter", "arch",
                                                "par_type", "p", "time_s"])
        writer.writeheader()
        writer.writerows(rows)
    print(f"  Saved: {path}")


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Generate multi-size analysis report")
    parser.add_argument("--log",           default="analysis_results.log")
    parser.add_argument("--outdir",        default="report")
    parser.add_argument("--workspace",     default="workspace")
    parser.add_argument("--node-counts",   default="2 4 6")
    parser.add_argument("--thread-counts", default="1 2 4")
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
        print("[ERROR] No IMAGE: blocks found in log.")
        sys.exit(1)

    print(f"Found {len(data)} image(s): {list(data.keys())}\n")

    print("Generating figures …")
    fig1_serial_baselines(data, args.outdir)
    fig2_fft_arch_comparison(data, node_counts, thread_counts, args.outdir)
    fig3_arch3_speedup_efficiency(data, args.outdir)
    fig4_openmp_scaling(data, args.outdir)
    fig5_spatial_arch3_speedup(data, args.outdir)
    fig6_architecture_summary(data, args.outdir)
    fig7_brents_law(data, args.outdir)
    fig8_visual_comparison(data, args.workspace, args.outdir)
    write_csv(data, args.outdir)

    charts = sorted(f for f in os.listdir(args.outdir) if f.endswith(".png"))
    print(f"\nReport complete → {args.outdir}/  ({len(charts)} figures)")
    for c in charts:
        print(f"  {args.outdir}/{c}")


if __name__ == "__main__":
    main()
