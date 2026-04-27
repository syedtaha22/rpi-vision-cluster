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

# ── Shared style — matches rough_plots.py ────────────────────────────────────
STYLE = {
    "font.family":        "serif",
    "font.size":          11,
    "axes.titlesize":     12,
    "axes.labelsize":     11,
    "xtick.labelsize":    9,
    "ytick.labelsize":    9,
    "legend.fontsize":    9,
    "legend.framealpha":  0.85,
    "legend.edgecolor":   "#cccccc",
    "axes.grid":          False,
    "axes.spines.top":    False,
    "axes.spines.right":  False,
    "figure.dpi":         150,
    "savefig.dpi":        150,
    "savefig.bbox":       "tight",
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

# Colourblind-safe palette — same as rough_plots.py
C = ['#2c7bb6',   # blue   – Arch1 / Sobel
     '#d7191c',   # red    – Arch2 / Canny
     '#1a9641',   # green  – Arch3 / LoG
     '#fd8d3c',   # orange – Arch4 / FFT
     '#756bb1',   # purple
     '#636363']   # grey

ARCH_COLORS   = C[:4]
FILTER_COLORS = {"Sobel": C[0], "Canny": C[1], "LoG": C[2], "FFT": C[3]}

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


# ── Amdahl helper (shared with new figures) ──────────────────────────────────
def _fit_amdahl_f(ps, sp):
    """Fit Amdahl parallel fraction f to observed (p, speedup) pairs."""
    try:
        from scipy.optimize import curve_fit
        popt, _ = curve_fit(lambda p, f: 1.0 / ((1 - f) + f / p),
                            ps, sp, p0=[0.9], bounds=(0.01, 0.9999))
        return float(popt[0])
    except Exception:
        vals = [(1 - 1.0 / s) / (1 - 1.0 / p)
                for p, s in zip(ps, sp) if p > 1 and s > 0]
        return float(np.clip(np.mean(vals), 0.01, 0.9999)) if vals else 0.9


# ── Figure 8b: Fitted Amdahl f vs image size ─────────────────────────────────
def fig8b_amdahl_f_vs_size(data, outdir):
    """
    Validates the doc's claim: CIFAR → f low, COCO → f≈0.95+.
    Shows fitted parallel fraction f for FFT Arch3 across all image sizes.
    """
    # Map image stem → pixel count for x-axis ordering
    SIZE_MN = {
        "tabby_s_000074": 32 * 32,       # CIFAR-10  (32×32 padded to 64×64)
        "test_0":         64 * 64,        # Tiny-ImageNet (64×64 padded to 64×64)
        "000000144003":   512 * 512,      # COCO (480×640 padded to 512×512 → use 512²)
    }

    results = {}   # img_stem → (label, MN, f_fft_arch3, f_sobel_arch3)
    for img, img_data in data.items():
        bl_fft = img_data["baseline"].get("FFT")
        pts    = img_data["FFT"].get(3, [])
        if not pts or bl_fft is None:
            continue
        ps = np.array([p for p, _ in pts], dtype=float)
        sp = np.array([bl_fft / t for _, t in pts])
        if len(ps) < 2:
            continue
        f_fft = _fit_amdahl_f(ps, sp)

        # Also fit Sobel Arch3 as a reference spatial filter
        bl_sob = img_data["baseline"].get("Sobel")
        pts_s  = img_data["Sobel"].get(3, [])
        f_sob  = None
        if pts_s and bl_sob:
            ps_s = np.array([p for p, _ in pts_s], dtype=float)
            sp_s = np.array([bl_sob / t for _, t in pts_s])
            if len(ps_s) >= 2:
                f_sob = _fit_amdahl_f(ps_s, sp_s)

        mn = SIZE_MN.get(img, None)
        label = _size_label(img)
        results[img] = (label, mn, f_fft, f_sob)

    if not results:
        print("  [WARN] No multi-size data for fig8b")
        return

    # Sort by MN (ascending image size)
    ordered = sorted(results.values(), key=lambda x: (x[1] or 0))
    labels  = [r[0] for r in ordered]
    f_fft   = [r[2] for r in ordered]
    f_sob   = [r[3] if r[3] is not None else 0 for r in ordered]
    x       = np.arange(len(labels))

    fig, ax = plt.subplots(figsize=(8, 5))
    width = 0.35
    bars1 = ax.bar(x - width / 2, f_fft, width,
                   color="#FF9800", label="FFT (Arch3)", alpha=0.85,
                   edgecolor="white")
    bars2 = ax.bar(x + width / 2, f_sob, width,
                   color="#2196F3", label="Sobel (Arch3)", alpha=0.85,
                   edgecolor="white")

    for bars, vals in [(bars1, f_fft), (bars2, f_sob)]:
        for bar, v in zip(bars, vals):
            if v > 0.01:
                ax.text(bar.get_x() + bar.get_width() / 2,
                        bar.get_height() + 0.008,
                        f"{v:.2f}", ha="center", va="bottom", fontsize=9)

    # Theoretical prediction lines
    ax.axhline(0.95, color="green", linestyle="--", alpha=0.5, linewidth=1.2,
               label="Doc prediction: COCO f≈0.95+")
    ax.axhline(0.90, color="orange", linestyle=":", alpha=0.5, linewidth=1.2,
               label="f=0.90 reference")

    ax.set_title("Amdahl's Law — Fitted Parallel Fraction  f  vs Image Size\n"
                 "(validates: CIFAR → low f; COCO → f≈0.95+)")
    ax.set_ylabel("Fitted parallel fraction  f")
    ax.set_xlabel("Dataset / Image Size")
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=9)
    ax.set_ylim(0, 1.08)
    ax.legend(fontsize=8)

    path = os.path.join(outdir, "fig8b_amdahl_f_vs_size.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 8c: Isoefficiency curves ──────────────────────────────────────────
def fig8c_isoefficiency(data, outdir):
    """
    Two-panel isoefficiency figure that directly validates the doc:
      Left:  Theoretical E vs p for each dataset size under FFT Arch3
             formula: E ≈ 1 / (1 + p / log2(MN))
             Shows CIFAR collapses fast; COCO holds up longer.
      Right: Required log2(MN) to maintain target efficiency E=0.9 as p grows.
             Shows MPI Arch3 needs exponential W growth (steep curve).
             Arch1/2 (shared memory) requires only linear growth.
    Also overlays any observed efficiency points from the data.
    """
    # Dataset sizes (padded to nearest power of 2 for FFT)
    SIZES = {
        "CIFAR-10\n(32×32)":         1024,       # 32×32
        "Tiny-ImageNet\n(64×64)":    4096,       # 64×64
        "COCO / BSDS\n(512×512)":    512 * 512,  # 481×321 or 480×640 pads to 512²
    }
    SIZE_COLORS = ["#E53935", "#FB8C00", "#43A047"]

    p_arr = np.linspace(1, 8, 200)

    fig, (ax_left, ax_right) = plt.subplots(1, 2, figsize=(13, 5))
    fig.suptitle("Isoefficiency Analysis — FFT Arch3 (MPI Scatter-Gather)\n"
                 "(formula: E ≈ 1 / (1 + p / log₂(MN)),  "
                 "doc: Arch1/2 linear scaling vs Arch3/4 exponential)")

    # ── Left panel: E vs p for each dataset ──────────────────────────────────
    for (lbl, mn), col in zip(SIZES.items(), SIZE_COLORS):
        log2_mn = np.log2(mn)
        eff = 1.0 / (1.0 + p_arr / log2_mn)
        ax_left.plot(p_arr, eff, color=col, linewidth=2.2,
                     label=f"{lbl}  (log₂MN={log2_mn:.0f})")

    # Overlay observed efficiency from log data (Arch3, FFT)
    obs_colors = ["#1565C0", "#2E7D32", "#BF360C"]
    for (img, img_data), obs_col in zip(data.items(), obs_colors):
        bl = img_data["baseline"].get("FFT")
        pts = img_data["FFT"].get(3, [])
        if not pts or bl is None:
            continue
        for p, t in pts:
            if t > 0:
                sp  = bl / t
                eff = sp / p
                ax_left.scatter(p, eff, color=obs_col, s=55, zorder=5,
                                marker="D", edgecolors="white", linewidths=0.6)

    ax_left.axhline(0.9,  color="black", linestyle="--", alpha=0.4,
                    linewidth=1.2, label="E=0.90 target")
    ax_left.axhline(0.5,  color="gray",  linestyle=":",  alpha=0.4,
                    linewidth=1.0, label="E=0.50")
    ax_left.set_xlabel("Number of MPI Ranks (p)")
    ax_left.set_ylabel("Parallel Efficiency  E")
    ax_left.set_title("Efficiency vs Processors\n(diamonds = observed data)")
    ax_left.set_xlim(1, 8)
    ax_left.set_ylim(0, 1.05)
    ax_left.legend(fontsize=8)

    # ── Right panel: required log2(MN) to maintain E=0.9 ────────────────────
    # Arch3/4 (MPI FFT): E = 1/(1 + p/log2(MN))  →  log2(MN) = p / (1/E - 1)
    # Arch1/2 (OpenMP shared memory): communication is O(1), so isoefficiency
    #   is approximately linear: log2(MN_required) ≈ c_omp * p (c_omp ≈ 1)
    E_target = 0.9
    p_x = np.linspace(1, 8, 200)

    req_mpi = p_x / (1.0 / E_target - 1.0)          # log2(MN) needed for Arch3/4
    req_omp = p_x * 1.0                              # linear for shared memory (approx)

    # Mark known dataset sizes as horizontal reference lines
    for (lbl, mn), col in zip(SIZES.items(), SIZE_COLORS):
        ax_right.axhline(np.log2(mn), color=col, linestyle=":", alpha=0.55,
                         linewidth=1.4, label=f"{lbl.replace(chr(10),' ')} log₂MN={np.log2(mn):.0f}")

    ax_right.plot(p_x, req_mpi, color="#FF5722", linewidth=2.5, zorder=4,
                  label="Arch3/4 (MPI) — steep")
    ax_right.plot(p_x, req_omp, color="#2196F3", linewidth=2.5, zorder=4,
                  linestyle="--", label="Arch1/2 (OpenMP) — linear")

    # Shade region above the COCO line as "reachable"
    coco_log2 = np.log2(512 * 512)
    ax_right.fill_between(p_x, 0, coco_log2, alpha=0.07, color="green",
                           label="Current image size range")

    ax_right.set_xlabel("Number of Processors (p)")
    ax_right.set_ylabel("Required  log₂(MN)  to maintain E=0.90")
    ax_right.set_title(f"Isoefficiency: Work Needed to Sustain E={E_target}\n"
                       "(MPI needs exponential growth; OpenMP is linear)")
    ax_right.set_xlim(1, 8)
    ax_right.set_ylim(0, max(req_mpi[-1], coco_log2) * 1.15)
    ax_right.legend(fontsize=7)

    plt.tight_layout()
    path = os.path.join(outdir, "fig8c_isoefficiency.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 7b: Arch4 single-image ceiling annotation ────────────────────────
def fig7b_arch4_ceiling(data, outdir):
    """
    Annotates the theoretical ≤2× single-image speedup ceiling for Arch4.
    The doc states: Arch4 critical path = T_row_pass + T_comm + T_col_pass,
    giving at most ~2× improvement minus communication.  Plots observed Arch4
    speedup vs the 2× ceiling, per image size.
    """
    imgs = list(data.keys())
    if not imgs:
        return

    has_arch4 = any(data[i]["FFT"].get(4) for i in imgs)
    if not has_arch4:
        print("  [SKIP] No Arch4 FFT data for fig7b")
        return

    p_ref = np.linspace(1, 8, 200)

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.set_title("Brent's Law — Arch4 Theoretical Ceiling (FFT)\n"
                 "(doc: single-image Arch4 ≤ 2× speedup; pipeline fills only with image streams)")

    colors = ["#1565C0", "#2E7D32", "#BF360C"]
    for img, col in zip(imgs, colors):
        bl = data[img]["baseline"].get("FFT")
        pts = data[img]["FFT"].get(4, [])
        if not pts or bl is None:
            continue
        ps = np.array([p for p, _ in pts], dtype=float)
        sp = np.array([bl / t for _, t in pts])
        ax.plot(ps, sp, "o-", color=col, linewidth=2, markersize=7,
                label=_size_label(img))
        for p_val, sp_val in zip(ps, sp):
            ax.annotate(f"{sp_val:.2f}×", xy=(p_val, sp_val),
                        xytext=(4, 5), textcoords="offset points", fontsize=8)

    # Theoretical ceiling line: ≤2× (ignoring comm overhead entirely)
    ax.axhline(2.0, color="#FF5722", linestyle="--", linewidth=2, alpha=0.8,
               label="Theoretical ceiling: 2× (zero-comm ideal)")
    ax.fill_between(p_ref, 1.8, 2.0, alpha=0.10, color="#FF5722",
                    label="Comm overhead reduces ceiling below 2×")
    ax.axhline(1.0, color="black", linestyle=":", alpha=0.3)

    # Ideal speedup for reference
    ax.plot(p_ref, p_ref, ":", color="gray", alpha=0.25, linewidth=1.2,
            label="Ideal (linear)")

    ax.set_xlabel("MPI Ranks (p)")
    ax.set_ylabel("Speedup S(p) = T_serial / T_parallel")
    ax.set_xlim(1, 7)
    ax.set_ylim(0, max(3.0, ax.get_ylim()[1]))
    ax.legend(fontsize=8)

    path = os.path.join(outdir, "fig7b_arch4_ceiling.png")
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
    fig7b_arch4_ceiling(data, args.outdir)
    fig8_visual_comparison(data, args.workspace, args.outdir)
    fig8b_amdahl_f_vs_size(data, args.outdir)
    fig8c_isoefficiency(data, args.outdir)
    write_csv(data, args.outdir)

    charts = sorted(f for f in os.listdir(args.outdir) if f.endswith(".png"))
    print(f"\nReport complete → {args.outdir}/  ({len(charts)} figures)")
    for c in charts:
        print(f"  {args.outdir}/{c}")


if __name__ == "__main__":
    main()
