#!/usr/bin/env python3
"""
generate_report_bsds.py — BSDS500 Performance + Quality Metrics Report
Parses analysis_bsds.log (from run_analysis_bsds.sh) and produces:

  report_bsds/
  ├── fig1_serial_baselines.png              Bar chart with error bars
  ├── fig2_fft_arch_comparison.png           Grouped bar: all FFT configs
  ├── fig3_fft_arch3_speedup.png             Speedup + efficiency + Brent's Law
  ├── fig4_omp_scaling.png                   OpenMP anti-speedup
  ├── fig5_spatial_arch3_speedup.png         Arch3 for Sobel/Canny/LoG
  ├── fig6_all_archs_<filter>.png            All archs per filter (4 files)
  ├── fig7_amdahl_comparison.png             Fitted f per (filter, arch)
  ├── fig8_brents_law.png                    Brent's Law 2x2 grid
  ├── fig9_metrics_jaccard_dice_ssim.png     Quality metrics combined
  ├── fig10_recon_<filter>.png               Filter-organized output grid (4 files)
  ├── fig11_arch_mean_time.png               Mean time per arch per filter
  └── summary_table.csv

Usage:
  python3 generate_report_bsds.py
  python3 generate_report_bsds.py --log report_bsds/analysis_bsds.log \\
      --outdir report_bsds --recon-dir report_bsds/reconstructed \\
      --gt-dir workspace/results/gt/groundTruth/test
"""

import argparse
import csv
import os
import re
import sys
from collections import defaultdict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

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
    print("[WARN] Pillow not installed — image sections will be skipped")

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

FILTERS     = ["Sobel", "Canny", "LoG", "FFT"]
ARCHS       = [1, 2, 3, 4]
ARCH_LABELS = {
    1: "Arch1 (OMP Farm)",
    2: "Arch2 (OMP Pipeline)",
    3: "Arch3 (MPI Scatter)",
    4: "Arch4 (MPI Pipeline)",
}
ARCH_PAR = {1: "threads", 2: "threads", 3: "nodes", 4: "nodes"}
MARKERS = ["o", "s", "^", "D"]

# Colourblind-safe palette — same as rough_plots.py
C = ['#2c7bb6',   # blue   – Arch1 / Sobel
     '#d7191c',   # red    – Arch2 / Canny
     '#1a9641',   # green  – Arch3 / LoG
     '#fd8d3c',   # orange – Arch4 / FFT
     '#756bb1',   # purple
     '#636363']   # grey

ARCH_COLORS   = C[:4]
FILTER_COLORS = {"Sobel": C[0], "Canny": C[1], "LoG": C[2], "FFT": C[3]}

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

METRICS_RE = re.compile(
    r"\[Metrics\]\s+jaccard=(?P<jaccard>[\d.]+)\s+dice=(?P<dice>[\d.]+)\s+ssim=(?P<ssim>[\d.]+)"
)


def parse_log(log_path, node_counts, thread_counts):
    data = {}
    current_img = None
    counters = {}
    last_filter_arch = None   # track context for metric association

    def img_key(p):
        return os.path.basename(p)

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
                    "metrics":  {},
                    **{flt: {a: [] for a in ARCHS} for flt in FILTERS},
                }
            counters[current_img] = {(flt, a): 0 for flt in FILTERS for a in ARCHS}
            last_filter_arch = None
            continue

        if current_img is None:
            continue

        img_data = data[current_img]

        # Baseline
        for flt in FILTERS:
            pat = PATTERNS.get((flt, 0))
            if pat:
                m = pat.search(line)
                if m:
                    img_data["baseline"][flt] = float(m.group("time"))

        # Arch timings
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
                last_filter_arch = f"{flt}_arch{arch}"

        # Quality metrics — associate with most recent (flt, arch)
        m = METRICS_RE.search(line)
        if m and last_filter_arch:
            key = last_filter_arch
            img_data["metrics"].setdefault(key, []).append({
                "jaccard": float(m.group("jaccard")),
                "dice":    float(m.group("dice")),
                "ssim":    float(m.group("ssim")),
            })

    return data


# ── Aggregation helpers ───────────────────────────────────────────────────────

def _aggregate(all_data, flt, arch):
    """Return (ps_sorted, t_means, t_stds, baseline_mean) over all images."""
    bucket = defaultdict(list)
    baseline_vals = []
    for img_data in all_data.values():
        bl = img_data["baseline"].get(flt)
        if bl is not None:
            baseline_vals.append(bl)
        for p, t in img_data.get(flt, {}).get(arch, []):
            bucket[p].append(t)
    if not bucket:
        return None, None, None, None
    ps = np.array(sorted(bucket.keys()), dtype=float)
    t_means = np.array([np.mean(bucket[p]) for p in ps])
    t_stds  = np.array([np.std(bucket[p])  for p in ps])
    baseline_mean = float(np.mean(baseline_vals)) if baseline_vals else t_means.max()
    return ps, t_means, t_stds, baseline_mean


def _annotate_bars(ax, bars, values, fmt="{:.4f}s", pad_frac=0.01):
    if not values:
        return
    pad = max(v for v in values if v > 0) * pad_frac if any(v > 0 for v in values) else 0.001
    for bar, v in zip(bars, values):
        if v > 0:
            ax.text(bar.get_x() + bar.get_width() / 2,
                    bar.get_height() + pad,
                    fmt.format(v), ha="center", va="bottom", fontsize=8)


def _fit_amdahl_f(ps, sp):
    """Return fitted parallel fraction f (Amdahl's Law)."""
    try:
        from scipy.optimize import curve_fit
        popt, _ = curve_fit(lambda p, f: 1.0 / ((1 - f) + f / p),
                            ps, sp, p0=[0.9], bounds=(0.01, 0.9999))
        return float(popt[0])
    except Exception:
        f_vals = [(1 - 1.0/s) / (1 - 1.0/p) for p, s in zip(ps, sp)
                  if p > 1 and s > 0]
        return float(np.clip(np.mean(f_vals), 0.01, 0.9999)) if f_vals else 0.9


# ── Figure 1: Serial baseline ─────────────────────────────────────────────────
def fig1_serial_baselines(all_data, outdir):
    means, stds = {}, {}
    for flt in FILTERS:
        vals = [img_data["baseline"][flt]
                for img_data in all_data.values()
                if flt in img_data["baseline"]]
        if vals:
            means[flt] = np.mean(vals)
            stds[flt]  = np.std(vals)

    if not means:
        print("  [WARN] No baseline data for Fig 1")
        return

    fig, ax = plt.subplots(figsize=(8, 5))
    fkeys = list(means.keys())
    vals  = [means[f] for f in fkeys]
    errs  = [stds[f]  for f in fkeys]
    bars  = ax.bar(fkeys, vals, yerr=errs, capsize=5,
                   color=[FILTER_COLORS.get(f, "#888") for f in fkeys],
                   alpha=0.85, edgecolor="white", width=0.5)
    _annotate_bars(ax, bars, vals)
    ax.set_title(f"Serial Baseline Filter Times — BSDS500\n"
                 f"(mean ± std, n={len(all_data)} images, 481×321)")
    ax.set_ylabel("Mean Wall-Clock Time (s)")
    ax.set_xlabel("Filter")

    # Relative speedup annotation under each bar
    if vals:
        base = vals[0]
        for bar, v in zip(bars, vals):
            if v > 0 and base > 0:
                ax.text(bar.get_x() + bar.get_width() / 2,
                        -max(vals) * 0.06,
                        f"{v/base:.1f}×", ha="center", va="top",
                        fontsize=8, color="gray")

    path = os.path.join(outdir, "fig1_serial_baselines.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 2: FFT architecture comparison ────────────────────────────────────
def fig2_fft_arch_comparison(all_data, outdir):
    """Grouped bar of mean FFT wall-clock across all nodes/thread configs."""
    bucket_t1 = defaultdict(list)
    for img_data in all_data.values():
        for arch in ARCHS:
            for p, t in img_data["FFT"].get(arch, []):
                bucket_t1[(arch, p)].append(t)

    if not bucket_t1:
        print("  [WARN] No FFT data for Fig 2")
        return

    configs, times, colors, xlabels = [], [], [], []
    for arch in ARCHS:
        ps = sorted({p for a, p in bucket_t1 if a == arch})
        for p in ps:
            key = (arch, p)
            t_mean = np.mean(bucket_t1[key])
            configs.append(key)
            times.append(t_mean)
            colors.append(ARCH_COLORS[arch - 1])
            par_type = "T" if ARCH_PAR[arch] == "threads" else "N"
            xlabels.append(f"A{arch}\n{par_type}={p}")

    fig, ax = plt.subplots(figsize=(max(10, len(configs) * 0.85), 5))
    bars = ax.bar(range(len(configs)), times, color=colors, alpha=0.85,
                  edgecolor="white", width=0.6)
    _annotate_bars(ax, bars, times)

    # Baseline reference line
    bl_vals = [img_data["baseline"].get("FFT", 0) for img_data in all_data.values()]
    bl_vals = [v for v in bl_vals if v > 0]
    if bl_vals:
        bl_mean = np.mean(bl_vals)
        ax.axhline(bl_mean, color="black", linestyle="--", alpha=0.5,
                   label=f"Serial baseline ({bl_mean:.3f}s)")

    ax.set_title("FFT Architecture Comparison — BSDS500\n"
                 "(mean over test images, 481×321 → 512×512 padded)")
    ax.set_ylabel("Mean Wall-Clock Time (s)")
    ax.set_xticks(range(len(xlabels)))
    ax.set_xticklabels(xlabels, fontsize=8)

    from matplotlib.patches import Patch
    legend_handles = [Patch(facecolor=ARCH_COLORS[i], label=ARCH_LABELS[i+1])
                      for i in range(4)]
    if bl_vals:
        from matplotlib.lines import Line2D
        legend_handles.append(Line2D([0], [0], color="black", linestyle="--",
                                     label=f"Serial ({bl_mean:.3f}s)"))
    ax.legend(handles=legend_handles, fontsize=8, loc="upper right")

    path = os.path.join(outdir, "fig2_fft_arch_comparison.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 3: FFT Arch3 speedup + efficiency + Brent's Law ───────────────────
def fig3_fft_arch3_panels(all_data, outdir):
    """Matches Figure 3 in the PDF report exactly."""
    ps, t_means, t_stds, bl_mean = _aggregate(all_data, "FFT", 3)
    if ps is None:
        print("  [WARN] No FFT Arch3 data for Fig 3")
        return

    sp_means = bl_mean / t_means
    sp_stds  = bl_mean / (t_means ** 2) * t_stds
    eff_means = sp_means / ps
    eff_stds  = sp_stds  / ps
    inv_p = 1.0 / ps

    # Fit Amdahl
    f_fit = _fit_amdahl_f(ps, sp_means)
    p_curve = np.linspace(1, ps.max() + 1, 300)
    sp_curve = 1.0 / ((1 - f_fit) + f_fit / p_curve)

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    fig.suptitle(f"FFT Arch3 (MPI Scatter-Gather) — Speedup & Efficiency\n"
                 f"(BSDS500, n={len(all_data)} images, Amdahl f={f_fit:.2f})")

    color = ARCH_COLORS[2]

    # Speedup panel
    ax = axes[0]
    ax.plot(p_curve, sp_curve, "--", color="#FF8C00", linewidth=1.8,
            alpha=0.85, label=f"Amdahl (f={f_fit:.2f})")
    ax.plot(p_curve, p_curve, ":", color="gray", alpha=0.3, linewidth=1.2,
            label="Ideal")
    ax.errorbar(ps, sp_means, yerr=sp_stds, fmt="o-", color=color,
                linewidth=2, markersize=8, capsize=4, label="Empirical",
                zorder=5)
    # Annotate each point
    for p_val, sp_val in zip(ps, sp_means):
        ax.annotate(f"{sp_val:.2f}×", xy=(p_val, sp_val),
                    xytext=(5, 6), textcoords="offset points", fontsize=9)
    ax.axhline(1.0, color="black", linestyle=":", alpha=0.2)
    ax.set_title("Speedup (Amdahl's Law)")
    ax.set_xlabel("MPI Ranks (P)")
    ax.set_ylabel("Speedup S(P)")
    ax.legend()

    # Efficiency panel
    ax = axes[1]
    ax.axhline(0.9, color="#FF8C00", linestyle="--", alpha=0.6, label="E=0.90")
    ax.axhline(0.5, color="orange", linestyle=":", alpha=0.5, label="E=0.50")
    ax.errorbar(ps, eff_means, yerr=eff_stds, fmt="o-", color=color,
                linewidth=2, markersize=8, capsize=4, label="Empirical",
                zorder=5)
    for p_val, e_val in zip(ps, eff_means):
        ax.annotate(f"{e_val:.2f}", xy=(p_val, e_val),
                    xytext=(5, 6), textcoords="offset points", fontsize=9)
    ax.set_title("Parallel Efficiency")
    ax.set_xlabel("MPI Ranks (P)")
    ax.set_ylabel("Efficiency E = S/P")
    ax.set_ylim(0, 1.15)
    ax.legend()

    path = os.path.join(outdir, "fig3_fft_arch3_speedup.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 4: OpenMP anti-speedup ────────────────────────────────────────────
def fig4_omp_scaling(all_data, outdir):
    """Matches Figure 4 in the PDF."""
    spatial = ["Sobel", "Canny", "LoG"]

    bucket = {flt: defaultdict(list) for flt in spatial}
    for img_data in all_data.values():
        for flt in spatial:
            for p, t in img_data[flt].get(1, []):
                bucket[flt][p].append(t)

    if not any(bucket[flt] for flt in spatial):
        print("  [WARN] No Arch1 data for Fig 4")
        return

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.set_title("OpenMP Farm (Arch1) Scaling — BSDS500\n"
                 "(Anti-speedup under QEMU: all threads share the same translation cache)")

    for flt, marker in zip(spatial, MARKERS):
        buck = bucket[flt]
        if not buck:
            continue
        ps = sorted(buck.keys())
        t_means = [np.mean(buck[p]) for p in ps]
        t_stds  = [np.std(buck[p])  for p in ps]
        ax.errorbar(ps, t_means, yerr=t_stds, fmt=f"{marker}-",
                    color=FILTER_COLORS[flt], label=flt,
                    linewidth=2, markersize=7, capsize=4)

    ax.set_xlabel("OpenMP Thread Count")
    ax.set_ylabel("Mean Wall-Clock Time (s)")
    ax.legend()

    path = os.path.join(outdir, "fig4_omp_scaling.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 5: Spatial filter Arch3 speedup (3 panels) ───────────────────────
def fig5_spatial_arch3_speedup(all_data, outdir):
    """Matches Figure 5 in the PDF — 3 subplots side by side."""
    spatial = ["Sobel", "Canny", "LoG"]
    fig, axes = plt.subplots(1, 3, figsize=(15, 5))
    fig.suptitle("Arch3 (MPI Scatter-Gather) — Spatial Filters — BSDS500\n"
                 f"(n={len(all_data)} images, error bars = std over images)")

    p_curve = np.linspace(1, 8, 200)

    for ax, flt in zip(axes, spatial):
        ps, t_means, t_stds, bl_mean = _aggregate(all_data, flt, 3)
        if ps is None:
            ax.set_title(flt); ax.set_xlabel("MPI Ranks"); continue

        sp_means = bl_mean / t_means
        sp_stds  = bl_mean / (t_means ** 2) * t_stds
        eff_means = sp_means / ps
        color = FILTER_COLORS[flt]

        # Fit Amdahl for this filter
        f_fit = _fit_amdahl_f(ps, sp_means)
        sp_amdahl = 1.0 / ((1 - f_fit) + f_fit / p_curve)

        # Plot speedup
        ax.plot(p_curve, sp_amdahl, "--", color="#FF8C00", linewidth=1.5,
                alpha=0.8, label=f"Amdahl f={f_fit:.2f}")
        ax.plot(p_curve, p_curve, ":", color="gray", alpha=0.2, linewidth=1)
        ax.errorbar(ps, sp_means, yerr=sp_stds, fmt="o-", color=color,
                    linewidth=2.5, markersize=8, capsize=4, label="Speedup",
                    zorder=5)
        # Efficiency on secondary y-axis
        ax2 = ax.twinx()
        ax2.plot(ps, eff_means, "^--", color=color, alpha=0.55,
                 linewidth=1.5, markersize=7, label="Efficiency")
        ax2.set_ylabel("Efficiency E", fontsize=9, color=color)
        ax2.tick_params(axis="y", labelcolor=color, labelsize=8)
        ax2.set_ylim(0, 1.2)
        ax2.axhline(1.0, color=color, linestyle=":", alpha=0.25)

        # Annotate speedup values
        for p_val, sp_val in zip(ps, sp_means):
            ax.annotate(f"{sp_val:.2f}×", xy=(p_val, sp_val),
                        xytext=(4, 5), textcoords="offset points", fontsize=8)

        ax.set_title(flt)
        ax.set_xlabel("MPI Ranks")
        if ax is axes[0]:
            ax.set_ylabel("Speedup")
        # Combined legend
        h1, l1 = ax.get_legend_handles_labels()
        h2, l2 = ax2.get_legend_handles_labels()
        ax.legend(h1 + h2, l1 + l2, fontsize=7, loc="upper left")
        ax.axhline(1.0, color="black", linestyle=":", alpha=0.2)

    path = os.path.join(outdir, "fig5_spatial_arch3_speedup.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 6: All archs per filter ───────────────────────────────────────────
def fig6_all_archs_per_filter(all_data, outdir):
    """One 3-panel figure per filter: Speedup | Efficiency | Brent's Law."""
    p_curve = np.linspace(1, 10, 200)

    for flt in FILTERS:
        fig, axes = plt.subplots(1, 3, figsize=(15, 5))
        fig.suptitle(f"{flt} — All Architectures — BSDS500\n"
                     f"(aggregated mean ± std, n={len(all_data)} images)")
        ax_sp, ax_eff, ax_br = axes

        ax_sp.plot(p_curve, 1.0 / (0.1 + 0.9 / p_curve),
                   "k--", alpha=0.3, linewidth=1.2, label="Amdahl f=0.90")

        for arch in ARCHS:
            ps, t_means, t_stds, bl_mean = _aggregate(all_data, flt, arch)
            if ps is None:
                continue
            sp_means = bl_mean / t_means
            sp_stds  = bl_mean / (t_means ** 2) * t_stds
            eff_means = sp_means / ps
            eff_stds  = sp_stds  / ps
            inv_p = 1.0 / ps
            color  = ARCH_COLORS[arch - 1]
            marker = MARKERS[arch - 1]
            lbl    = ARCH_LABELS[arch]

            ax_sp.errorbar(ps, sp_means, yerr=sp_stds, fmt=f"{marker}-",
                           color=color, linewidth=2, markersize=6,
                           capsize=3, label=lbl)
            ax_eff.errorbar(ps, eff_means, yerr=eff_stds, fmt=f"{marker}-",
                            color=color, linewidth=2, markersize=6,
                            capsize=3, label=lbl)
            ax_br.errorbar(inv_p, t_means, yerr=t_stds, fmt=f"{marker}-",
                           color=color, linewidth=2, markersize=6,
                           capsize=3, label=lbl)
            if len(ps) >= 2:
                coef = np.polyfit(inv_p, t_means, 1)
                x_fit = np.linspace(0, inv_p.max() * 1.1, 80)
                ax_br.plot(x_fit, np.polyval(coef, x_fit), "--",
                           color=color, alpha=0.4, linewidth=1.2)

        ax_eff.axhline(1.0, color="black", linestyle="--", alpha=0.3, label="Ideal E=1")
        ax_eff.axhline(0.5, color="orange", linestyle=":", alpha=0.3)

        for ax, title, xl, yl in [
            (ax_sp,  "Speedup (Amdahl's Law)", "Parallelism (threads or nodes)", "Speedup"),
            (ax_eff, "Efficiency E = S/p",      "Parallelism (threads or nodes)", "E"),
            (ax_br,  "Brent's Law T_p vs 1/p", "1/p",                            "Time (s)"),
        ]:
            ax.set_title(title)
            ax.set_xlabel(xl)
            ax.set_ylabel(yl)
            ax.legend(fontsize=7)

        path = os.path.join(outdir, f"fig6_all_archs_{flt.lower()}.png")
        plt.savefig(path)
        plt.close(fig)
        print(f"  Saved: {path}")


# ── Figure 7: Amdahl fitted f comparison ─────────────────────────────────────
def fig7_amdahl_comparison(all_data, outdir):
    filters_present = [flt for flt in FILTERS
                       if any(all_data[img]["baseline"].get(flt) for img in all_data)]
    if not filters_present:
        return

    results = {}
    for flt in filters_present:
        for arch in ARCHS:
            ps_all, sp_all = [], []
            for img_data in all_data.values():
                bl = img_data["baseline"].get(flt)
                if bl is None:
                    continue
                for p, t in img_data[flt].get(arch, []):
                    if t > 0:
                        ps_all.append(float(p))
                        sp_all.append(bl / t)
            if len(ps_all) >= 2:
                results[(flt, arch)] = _fit_amdahl_f(np.array(ps_all), np.array(sp_all))
            else:
                results[(flt, arch)] = None

    n_filters = len(filters_present)
    x = np.arange(n_filters)
    width = 0.18

    fig, ax = plt.subplots(figsize=(10, 5))
    for i, arch in enumerate(ARCHS):
        vals = [results.get((flt, arch), 0) or 0 for flt in filters_present]
        offset = (i - 1.5) * width
        bars = ax.bar(x + offset, vals, width, color=ARCH_COLORS[i],
                      label=ARCH_LABELS[arch], alpha=0.85, edgecolor="white")
        for bar, v in zip(bars, vals):
            if v and v > 0.01:
                ax.text(bar.get_x() + bar.get_width() / 2,
                        bar.get_height() + 0.008,
                        f"{v:.2f}", ha="center", va="bottom", fontsize=8)

    ax.set_title("Amdahl's Law — Fitted Parallel Fraction  f\n"
                 "(higher = more parallelisable; BSDS500 average)")
    ax.set_xlabel("Filter")
    ax.set_ylabel("Parallel fraction  f")
    ax.set_xticks(x)
    ax.set_xticklabels(filters_present)
    ax.set_ylim(0, 1.08)
    ax.legend(fontsize=8)

    path = os.path.join(outdir, "fig7_amdahl_comparison.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 8: Brent's Law 2×2 ────────────────────────────────────────────────
def fig8_brents_law(all_data, outdir):
    fig, axes = plt.subplots(2, 2, figsize=(12, 8))
    fig.suptitle("Brent's Law  T_p vs 1/p  (MPI Architectures, BSDS500 average)")
    axes_flat = axes.flatten()

    for idx, flt in enumerate(FILTERS):
        ax = axes_flat[idx]
        ax.set_title(flt)
        for arch in [3, 4]:
            ps, t_means, t_stds, _ = _aggregate(all_data, flt, arch)
            if ps is None:
                continue
            inv_p = 1.0 / ps
            color = ARCH_COLORS[arch - 1]
            ax.errorbar(inv_p, t_means, yerr=t_stds, fmt="o-",
                        color=color, label=ARCH_LABELS[arch],
                        linewidth=2, markersize=6, capsize=3)
            if len(ps) >= 2:
                coef = np.polyfit(inv_p, t_means, 1)
                t_inf = coef[1]
                x_fit = np.linspace(0, inv_p.max() * 1.15, 80)
                ax.plot(x_fit, np.polyval(coef, x_fit), "--",
                        color=color, alpha=0.5, linewidth=1.2,
                        label=f"A{arch} T∞≈{t_inf:.4f}s")
        ax.set_xlabel("1/p")
        ax.set_ylabel("T_p (s)")
        ax.legend(fontsize=7)

    plt.tight_layout()
    path = os.path.join(outdir, "fig8_brents_law.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 9: Quality metrics (Jaccard / Dice / SSIM) ─────────────────────────
def _fast_ssim(pred2d, gt2d):
    try:
        from scipy.ndimage import uniform_filter
        size = 11
        c1, c2 = 6.5025, 58.5225
        p = pred2d.astype(np.float64)
        g = gt2d.astype(np.float64)
        mu_p = uniform_filter(p, size)
        mu_g = uniform_filter(g, size)
        mu_pp = uniform_filter(p * p, size) - mu_p**2
        mu_gg = uniform_filter(g * g, size) - mu_g**2
        mu_pg = uniform_filter(p * g, size) - mu_p * mu_g
        num = (2 * mu_p * mu_g + c1) * (2 * mu_pg + c2)
        den = (mu_p**2 + mu_g**2 + c1) * (mu_pp + mu_gg + c2)
        valid = den > 0
        return float(np.mean(num[valid] / den[valid])) if valid.any() else 0.0
    except ImportError:
        return None


def compute_metrics_from_images(pred_path, gt_path):
    if not HAS_PIL:
        return None
    try:
        pred_img = PILImage.open(pred_path).convert("L")
        gt_img   = PILImage.open(gt_path).convert("L")
        if pred_img.size != gt_img.size:
            gt_img = gt_img.resize(pred_img.size, PILImage.NEAREST)
        p2d = np.array(pred_img, dtype=np.uint8)
        g2d = np.array(gt_img,   dtype=np.uint8)
        pbin = (p2d > 128).astype(np.int32).flatten()
        gbin = (g2d > 128).astype(np.int32).flatten()
        tp = int(np.sum(pbin & gbin))
        fp = int(np.sum(pbin & (1 - gbin)))
        fn = int(np.sum((1 - pbin) & gbin))
        jaccard = tp / (tp + fp + fn + 1e-8)
        dice    = 2 * tp / (2 * tp + fp + fn + 1e-8)
        ssim = _fast_ssim(p2d.astype(np.float64), g2d.astype(np.float64))
        if ssim is None:
            ssim = 0.0
        return float(jaccard), float(dice), float(ssim)
    except Exception as e:
        print(f"  [WARN] Metric compute failed {pred_path}: {e}")
        return None


def _resolve_gt_path(gt_dir, stem):
    """Find the GT file matching an image stem."""
    if not gt_dir:
        return None
    # Try exact match then strip suffixes
    for ext in [".png", ".jpg"]:
        p = os.path.join(gt_dir, stem + ext)
        if os.path.exists(p):
            return p
    # Stem might have extra tokens — try progressively shorter
    parts = stem.split("_")
    for n in range(len(parts), 0, -1):
        candidate = "_".join(parts[-n:])
        for ext in [".png", ".jpg"]:
            p = os.path.join(gt_dir, candidate + ext)
            if os.path.exists(p):
                return p
    return None


def fig9_quality_metrics(recon_dir, gt_dir, outdir):
    """Compute and plot Jaccard / Dice / SSIM vs BSDS500 GT."""
    if not HAS_PIL:
        print("  [SKIP] Pillow not installed")
        return
    if not os.path.isdir(recon_dir):
        print(f"  [SKIP] recon_dir not found: {recon_dir}")
        return

    rows = []
    gt_avail = gt_dir and os.path.isdir(gt_dir)
    if not gt_avail:
        print(f"  [SKIP] GT dir not found ({gt_dir}) — quality metrics skipped")
        return

    for sub in sorted(os.listdir(recon_dir)):
        sub_path = os.path.join(recon_dir, sub)
        if not os.path.isdir(sub_path):
            continue
        m = re.match(r"(\w+)_arch(\d)", sub)
        if not m:
            continue
        flt_tag  = m.group(1).capitalize()
        arch_num = int(m.group(2))

        for fn in sorted(os.listdir(sub_path)):
            if not fn.endswith(".png"):
                continue
            pred_path = os.path.join(sub_path, fn)
            # Extract stem: everything after the last arch/config prefix
            stem = re.sub(r"^[a-z]+_arch\d[^_]*_", "", fn.replace(".png", ""))
            gt_path = _resolve_gt_path(gt_dir, stem)
            if gt_path is None:
                continue
            result = compute_metrics_from_images(pred_path, gt_path)
            if result is None:
                continue
            jac, dice, ssim = result
            rows.append({"filter": flt_tag, "arch": arch_num,
                         "image": stem, "jaccard": jac, "dice": dice, "ssim": ssim})

    if not rows:
        print("  [WARN] No quality metric data — check recon_dir / gt_dir")
        return

    # Save CSV
    csv_path = os.path.join(outdir, "metrics_summary.csv")
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["filter", "arch", "image",
                                                "jaccard", "dice", "ssim"])
        writer.writeheader()
        writer.writerows(rows)
    print(f"  Saved: {csv_path}  ({len(rows)} pairs)")

    # Aggregate
    agg = defaultdict(lambda: defaultdict(list))
    for r in rows:
        key = (r["filter"], r["arch"])
        for metric in ["jaccard", "dice", "ssim"]:
            agg[key][metric].append(r[metric])

    filters_present = sorted({r["filter"] for r in rows})
    archs_present   = sorted({r["arch"] for r in rows})

    # One figure with 3 subplots: Jaccard | Dice | SSIM
    fig, axes = plt.subplots(1, 3, figsize=(15, 5))
    fig.suptitle("Image Quality Metrics vs BSDS500 Ground Truth\n"
                 "(mean ± std over test images)")
    x = np.arange(len(filters_present))
    width = 0.7 / max(len(archs_present), 1)
    thresholds = {"jaccard": 0.90, "dice": 0.95, "ssim": 0.99}
    ylabels = {"jaccard": "Jaccard (IoU)", "dice": "Dice / F1", "ssim": "SSIM"}

    for ax, metric in zip(axes, ["jaccard", "dice", "ssim"]):
        for i, arch in enumerate(archs_present):
            means, stds = [], []
            for flt in filters_present:
                vals = agg[(flt, arch)].get(metric, [])
                means.append(np.mean(vals) if vals else 0.0)
                stds.append(np.std(vals)   if vals else 0.0)
            offset = (i - (len(archs_present) - 1) / 2) * width
            bars = ax.bar(x + offset, means, width, yerr=stds, capsize=3,
                          color=ARCH_COLORS[arch - 1], label=ARCH_LABELS[arch],
                          alpha=0.85, edgecolor="white")
        ax.axhline(thresholds[metric], color="red", linestyle="--",
                   alpha=0.6, linewidth=1.2,
                   label=f"Threshold ({thresholds[metric]})")
        ax.set_xticks(x)
        ax.set_xticklabels(filters_present)
        ax.set_ylabel(ylabels[metric])
        ax.set_title(ylabels[metric])
        ax.set_ylim(0, 1.05)
        ax.legend(fontsize=7)

    path = os.path.join(outdir, "fig9_metrics_jaccard_dice_ssim.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 10: Reconstructed image grid per filter ────────────────────────────
def fig10_recon_per_filter(recon_dir, outdir, max_cols=5):
    """
    One figure per filter organized as a grid:
      rows = architectures, columns = images (up to max_cols)
    This produces clean, report-ready comparison panels.
    """
    if not HAS_PIL:
        print("  [SKIP] Pillow not installed")
        return
    if not os.path.isdir(recon_dir):
        print(f"  [SKIP] recon_dir not found: {recon_dir}")
        return

    # Load all images grouped by (filter, arch, stem)
    grid_data = {}  # (flt_tag, arch_num) → {stem: path}
    for sub in sorted(os.listdir(recon_dir)):
        sub_path = os.path.join(recon_dir, sub)
        if not os.path.isdir(sub_path):
            continue
        m = re.match(r"(\w+)_arch(\d)", sub)
        if not m:
            continue
        flt_tag  = m.group(1).capitalize()
        arch_num = int(m.group(2))
        key = (flt_tag, arch_num)
        grid_data.setdefault(key, {})
        for fn in sorted(os.listdir(sub_path)):
            if fn.endswith(".png"):
                stem = re.sub(r"^[a-z]+_arch\d[^_]*_", "", fn.replace(".png", ""))
                grid_data[key][stem] = os.path.join(sub_path, fn)

    # Group by filter
    for flt in FILTERS:
        # Collect all archs and stems for this filter
        archs_for_flt = sorted({an for ft, an in grid_data if ft == flt})
        if not archs_for_flt:
            continue
        # Find union of stems
        all_stems = sorted({stem
                             for an in archs_for_flt
                             for stem in grid_data.get((flt, an), {})})[:max_cols]
        if not all_stems:
            continue

        n_rows = len(archs_for_flt)
        n_cols = len(all_stems)
        thumb_h = 80

        fig, axes = plt.subplots(n_rows, n_cols,
                                 figsize=(2.5 * n_cols, 2.5 * n_rows))
        if n_rows == 1:
            axes = [axes] if n_cols == 1 else [axes]
        if n_cols == 1:
            axes = [[ax] for ax in axes]
        else:
            axes = [list(row) for row in np.array(axes).reshape(n_rows, n_cols)]

        fig.suptitle(f"{flt} Filter — Reconstructed Outputs by Architecture",
                     fontsize=11, fontweight="bold")

        for ri, arch in enumerate(archs_for_flt):
            arch_dict = grid_data.get((flt, arch), {})
            for ci, stem in enumerate(all_stems):
                ax = axes[ri][ci]
                fpath = arch_dict.get(stem)
                if fpath and os.path.exists(fpath):
                    try:
                        img = PILImage.open(fpath).convert("L")
                        ax.imshow(np.array(img), cmap="gray", interpolation="lanczos")
                    except Exception as e:
                        ax.text(0.5, 0.5, str(e)[:20], ha="center", va="center",
                                transform=ax.transAxes, fontsize=6)
                else:
                    ax.text(0.5, 0.5, "—", ha="center", va="center",
                            transform=ax.transAxes, fontsize=12, color="gray")
                ax.axis("off")
                if ri == 0:
                    ax.set_title(stem[:12], fontsize=7)
                if ci == 0:
                    ax.set_ylabel(ARCH_LABELS[arch].replace("(", "\n("),
                                  fontsize=7, rotation=0, ha="right",
                                  va="center", labelpad=50)

        plt.tight_layout()
        path = os.path.join(outdir, f"fig10_recon_{flt.lower()}.png")
        plt.savefig(path, dpi=120)
        plt.close(fig)
        print(f"  Saved: {path}")


# ── Figure 11: Mean time per arch per filter ──────────────────────────────────
def fig11_arch_mean_time(all_data, outdir):
    fig, axes = plt.subplots(1, len(FILTERS), figsize=(5 * len(FILTERS), 4))
    fig.suptitle("Mean Execution Time per Architecture — BSDS500")

    for ax, flt in zip(axes, FILTERS):
        means, labels = [], []
        for arch in ARCHS:
            vals = [t for img_data in all_data.values()
                    for _, t in img_data.get(flt, {}).get(arch, [])]
            if vals:
                means.append(np.mean(vals))
                labels.append(f"A{arch}")
        if not means:
            ax.set_title(flt); continue
        bars = ax.bar(labels, means,
                      color=[ARCH_COLORS[i] for i in range(len(means))],
                      alpha=0.85, edgecolor="white")
        _annotate_bars(ax, bars, means, fmt="{:.4f}")
        ax.set_title(flt)
        ax.set_ylabel("Time (s)")

    plt.tight_layout()
    path = os.path.join(outdir, "fig11_arch_mean_time.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 1b: Serial baseline scatter (individual images) ───────────────────
def fig1b_serial_baselines_scatter(all_data, outdir):
    """Scatter of per-image baseline times alongside means — reveals spread."""
    by_filter = defaultdict(list)
    for img_data in all_data.values():
        for flt in FILTERS:
            v = img_data["baseline"].get(flt)
            if v is not None:
                by_filter[flt].append(v)

    if not by_filter:
        print("  [WARN] No baseline data for Fig 1b")
        return

    fkeys = [f for f in FILTERS if f in by_filter]
    fig, ax = plt.subplots(figsize=(8, 5))

    rng = np.random.default_rng(42)
    for xi, flt in enumerate(fkeys):
        vals = np.array(by_filter[flt])
        color = FILTER_COLORS.get(flt, "#888")
        # mean bar (light fill, no errbar — scatter shows spread)
        ax.bar(xi, np.mean(vals), color=color, alpha=0.35,
               edgecolor=color, linewidth=1.2, width=0.5, zorder=1)
        ax.axhline(0, color="none")  # dummy for axis scaling
        # individual image points with jitter
        jitter = rng.uniform(-0.15, 0.15, size=len(vals))
        ax.scatter(xi + jitter, vals, color=color, s=40, zorder=3,
                   edgecolors="white", linewidths=0.5, alpha=0.85)
        # mean marker
        ax.scatter(xi, np.mean(vals), color=color, s=120, marker="D",
                   zorder=4, edgecolors="black", linewidths=0.8)
        ax.text(xi, np.mean(vals) + np.mean(vals) * 0.03,
                f"{np.mean(vals):.3f}s", ha="center", va="bottom",
                fontsize=8, fontweight="bold")

    ax.set_title(f"Serial Baseline Filter Times — BSDS500\n"
                 f"(each dot = 1 image, ◆ = mean, n={len(all_data)} images, 481×321)")
    ax.set_ylabel("Wall-Clock Time (s)")
    ax.set_xticks(range(len(fkeys)))
    ax.set_xticklabels(fkeys)
    ax.set_xlim(-0.6, len(fkeys) - 0.4)

    path = os.path.join(outdir, "fig1b_serial_baselines_scatter.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 5b: Arch3 spatial scatter — per-image speedup points ──────────────
def fig5b_spatial_arch3_scatter(all_data, outdir):
    """
    Per-image speedup scatter overlaid on mean line for Sobel / Canny / LoG
    at Arch3 (MPI Scatter-Gather). Complements the mean+errorbar of fig5.
    """
    spatial = ["Sobel", "Canny", "LoG"]
    fig, axes = plt.subplots(1, 3, figsize=(15, 5))
    fig.suptitle("Arch3 (MPI Scatter-Gather) — Per-Image Speedup Scatter — BSDS500\n"
                 "(each dot = 1 image; line = mean over images)")

    rng = np.random.default_rng(0)

    for ax, flt in zip(axes, spatial):
        color = FILTER_COLORS[flt]

        # Collect per-image speedups
        per_img_sp = defaultdict(list)
        baseline_vals = [img_data["baseline"].get(flt)
                         for img_data in all_data.values()
                         if img_data["baseline"].get(flt)]
        if not baseline_vals:
            ax.set_title(flt); ax.set_xlabel("MPI Ranks"); continue
        bl_mean = np.mean(baseline_vals)

        for img_data in all_data.values():
            bl = img_data["baseline"].get(flt)
            if bl is None:
                continue
            for p, t in img_data[flt].get(3, []):
                if t > 0:
                    per_img_sp[p].append(bl / t)

        if not per_img_sp:
            ax.set_title(flt); ax.set_xlabel("MPI Ranks"); continue

        ps_sorted = sorted(per_img_sp.keys())
        means = [np.mean(per_img_sp[p]) for p in ps_sorted]

        # Scatter individual points with jitter
        for p, sp_list in sorted(per_img_sp.items()):
            jitter = rng.uniform(-0.12, 0.12, size=len(sp_list))
            ax.scatter(np.array([p] * len(sp_list)) + jitter, sp_list,
                       color=color, s=30, alpha=0.55,
                       edgecolors="none", zorder=2)

        # Mean line on top
        ax.plot(ps_sorted, means, "o-", color=color,
                linewidth=2.5, markersize=8, zorder=4, label="Mean speedup")
        for p_val, sp_val in zip(ps_sorted, means):
            ax.annotate(f"{sp_val:.2f}×", xy=(p_val, sp_val),
                        xytext=(5, 6), textcoords="offset points", fontsize=8)
        ax.axhline(1.0, color="black", linestyle=":", alpha=0.25)

        ax.set_title(flt)
        ax.set_xlabel("MPI Ranks")
        if ax is axes[0]:
            ax.set_ylabel("Speedup S(P)")
        ax.legend(fontsize=8)

    path = os.path.join(outdir, "fig5b_spatial_arch3_scatter.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 10b: Per-image comparison (Original | Sobel | Canny | LoG | FFT) ──
def fig10b_recon_per_image(recon_dir, orig_dir, outdir, max_images=6):
    """
    Report-style panel: each row = one test image.
    Columns: Original | Sobel (best arch) | Canny (best arch) | LoG | FFT.
    Matches the 'Original / Canny / Sobel' layout shown in the report figure.
    Uses the highest-parallelism Arch3 output when available, else any output.
    """
    if not HAS_PIL:
        print("  [SKIP] Pillow not installed")
        return
    if not os.path.isdir(recon_dir):
        print(f"  [SKIP] recon_dir not found: {recon_dir}")
        return

    # ── 1. Build lookup: filter → {stem: best_path} ──────────────────────────
    # Priority: arch3 (any node count), then arch1, then whatever exists
    FILTER_TAGS = ["sobel", "canny", "log", "fft"]
    FILTER_DISPLAY = ["Sobel", "Canny", "LoG", "FFT"]
    ARCH_PRIORITY = [3, 1, 2, 4]  # prefer arch3 (MPI scatter best result)

    best = {tag: {} for tag in FILTER_TAGS}  # tag → {stem: path}

    if os.path.isdir(recon_dir):
        for sub in sorted(os.listdir(recon_dir)):
            sub_path = os.path.join(recon_dir, sub)
            if not os.path.isdir(sub_path):
                continue
            m = re.match(r"(\w+)_arch(\d)", sub)
            if not m:
                continue
            tag = m.group(1).lower()
            arch_num = int(m.group(2))
            if tag not in best:
                continue
            for fn in sorted(os.listdir(sub_path)):
                if not fn.endswith(".png"):
                    continue
                stem = re.sub(r"^[a-z]+_arch\d[^_]*_", "", fn.replace(".png", ""))
                existing = best[tag].get(stem)
                if existing is None:
                    best[tag][stem] = os.path.join(sub_path, fn)
                else:
                    # Prefer higher-priority arch
                    existing_arch = int(re.search(r"arch(\d)", os.path.basename(
                        os.path.dirname(existing))).group(1))
                    if ARCH_PRIORITY.index(arch_num) < ARCH_PRIORITY.index(existing_arch):
                        best[tag][stem] = os.path.join(sub_path, fn)

    # ── 2. Collect stems that have at least one filter result ────────────────
    all_stems = set()
    for tag in FILTER_TAGS:
        all_stems.update(best[tag].keys())
    stems = sorted(all_stems)[:max_images]

    if not stems:
        print("  [SKIP] No reconstructed images found for per-image panel")
        return

    # ── 3. Build orig lookup ──────────────────────────────────────────────────
    orig_lookup = {}
    if orig_dir and os.path.isdir(orig_dir):
        for fn in os.listdir(orig_dir):
            stem_key = os.path.splitext(fn)[0]
            orig_lookup[stem_key] = os.path.join(orig_dir, fn)

    # ── 4. Layout: rows=images, cols=Original+filters ────────────────────────
    has_orig = any(s in orig_lookup for s in stems)
    col_labels = (["Original"] if has_orig else []) + FILTER_DISPLAY
    n_cols = len(col_labels)
    n_rows = len(stems)

    fig, axes = plt.subplots(n_rows, n_cols,
                             figsize=(2.8 * n_cols, 2.8 * n_rows),
                             squeeze=False)
    fig.suptitle("Per-Image Filter Comparison — BSDS500 Test Set\n"
                 "(Arch3 MPI Scatter-Gather output where available)",
                 fontsize=12, fontweight="bold")

    for ri, stem in enumerate(stems):
        col_idx = 0

        # Original column
        if has_orig:
            ax = axes[ri][col_idx]
            orig_path = orig_lookup.get(stem)
            if orig_path and os.path.exists(orig_path):
                try:
                    img = PILImage.open(orig_path).convert("L")
                    ax.imshow(np.array(img), cmap="gray", interpolation="lanczos")
                except Exception:
                    ax.text(0.5, 0.5, "err", ha="center", va="center",
                            transform=ax.transAxes, fontsize=8)
            else:
                ax.text(0.5, 0.5, "N/A", ha="center", va="center",
                        transform=ax.transAxes, fontsize=10, color="gray")
            ax.axis("off")
            if ri == 0:
                ax.set_title("Original", fontsize=9, fontweight="bold",
                             pad=4)
            col_idx += 1

        # Filter columns
        for tag, disp in zip(FILTER_TAGS, FILTER_DISPLAY):
            ax = axes[ri][col_idx]
            fpath = best[tag].get(stem)
            if fpath and os.path.exists(fpath):
                try:
                    img = PILImage.open(fpath).convert("L")
                    ax.imshow(np.array(img), cmap="gray", interpolation="lanczos")
                except Exception:
                    ax.text(0.5, 0.5, "err", ha="center", va="center",
                            transform=ax.transAxes, fontsize=8)
            else:
                ax.text(0.5, 0.5, "—", ha="center", va="center",
                        transform=ax.transAxes, fontsize=14, color="#aaa")
            ax.axis("off")
            if ri == 0:
                ax.set_title(disp, fontsize=9, fontweight="bold", pad=4)
            col_idx += 1

        # Row label (image stem)
        axes[ri][0].set_ylabel(stem[:14], fontsize=7, rotation=0,
                               ha="right", va="center", labelpad=48)

    plt.tight_layout()
    path = os.path.join(outdir, "fig10b_recon_per_image.png")
    plt.savefig(path, dpi=120)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Figure 12: Isoefficiency for BSDS500 ─────────────────────────────────────
def fig12_isoefficiency_bsds(all_data, outdir):
    """
    Validates Section 7.3 of the report: E ≈ 1 / (1 + P/log₂(MN)) for FFT Arch3.
    Left:  Theoretical curve + observed efficiency data points.
    Right: Required log₂(MN) to sustain target efficiency as p increases,
           with BSDS500 (512×512 padded) marked as a reference line.
    """
    # BSDS500 pads 481×321 → 512×512
    MN_BSDS = 512 * 512
    LOG2_MN  = np.log2(MN_BSDS)          # ≈ 18.0

    p_arr = np.linspace(1, 8, 300)
    eff_theory = 1.0 / (1.0 + p_arr / LOG2_MN)

    fig, (ax_left, ax_right) = plt.subplots(1, 2, figsize=(13, 5))
    fig.suptitle(f"Isoefficiency Analysis — BSDS500 FFT Arch3\n"
                 f"(512×512 padded, log₂(MN) = {LOG2_MN:.0f};  "
                 f"formula: E ≈ 1 / (1 + p / log₂(MN)))")

    # ── Left: theoretical E curve + observed points ───────────────────────────
    ax_left.plot(p_arr, eff_theory, color="#FF5722", linewidth=2.5,
                 label=f"Theoretical  (log₂MN={LOG2_MN:.0f})")

    # Overlay reference curves for smaller / larger images
    for mn_ref, lbl_ref, col_ref in [
        (32 * 32,     "CIFAR (32×32)",     "#E53935"),
        (64 * 64,     "Tiny (64×64)",      "#FB8C00"),
        (4096 * 4096, "4K (4096×4096)",    "#43A047"),
    ]:
        e_ref = 1.0 / (1.0 + p_arr / np.log2(mn_ref))
        ax_left.plot(p_arr, e_ref, linestyle=":", linewidth=1.4,
                     color=col_ref, alpha=0.65, label=lbl_ref)

    # Observed efficiency from data (Arch3, FFT)
    obs_ps, obs_effs = [], []
    for img_data in all_data.values():
        bl = img_data["baseline"].get("FFT")
        for p, t in img_data["FFT"].get(3, []):
            if bl and t > 0:
                sp = bl / t
                obs_ps.append(p)
                obs_effs.append(sp / p)

    if obs_ps:
        # Mean per p
        from collections import defaultdict as _dd
        bucket = _dd(list)
        for p, e in zip(obs_ps, obs_effs):
            bucket[p].append(e)
        for p_val in sorted(bucket):
            vals = bucket[p_val]
            ax_left.scatter([p_val] * len(vals), vals,
                            color="#9C27B0", s=30, alpha=0.45, zorder=4)
            ax_left.scatter(p_val, np.mean(vals),
                            color="#9C27B0", s=90, marker="D",
                            edgecolors="white", linewidths=0.7, zorder=5)
        # Annotate
        for p_val in sorted(bucket):
            mean_e = np.mean(bucket[p_val])
            ax_left.annotate(f"{mean_e:.2f}",
                             xy=(p_val, mean_e),
                             xytext=(5, 6), textcoords="offset points", fontsize=8)

    ax_left.axhline(0.9, color="black", linestyle="--", alpha=0.45,
                    linewidth=1.2, label="E=0.90 target")
    ax_left.axhline(0.5, color="gray",  linestyle=":",  alpha=0.35,
                    linewidth=1.0, label="E=0.50")
    ax_left.set_xlabel("MPI Ranks (p)")
    ax_left.set_ylabel("Parallel Efficiency  E")
    ax_left.set_title("E vs p  (◆ = empirical mean, · = per-image)")
    ax_left.set_xlim(1, 8)
    ax_left.set_ylim(0, 1.08)
    ax_left.legend(fontsize=8)

    # ── Right: required log₂(MN) to maintain E=0.9 ───────────────────────────
    E_target  = 0.9
    p_x       = np.linspace(1, 8, 200)
    req_arch3 = p_x / (1.0 / E_target - 1.0)   # = 9p at E=0.9
    req_omp   = p_x * 1.0                        # linear (shared memory)

    ax_right.plot(p_x, req_arch3, color="#FF5722", linewidth=2.5, zorder=4,
                  label="Arch3/4 (MPI) — steep  [= 9p at E=0.9]")
    ax_right.plot(p_x, req_omp,   color="#2196F3", linewidth=2.5, linestyle="--",
                  zorder=4, label="Arch1/2 (OpenMP) — linear")

    # Mark BSDS500 actual size
    ax_right.axhline(LOG2_MN, color="#FF9800", linestyle="-.", linewidth=1.8,
                     label=f"BSDS500 512² (log₂MN≈{LOG2_MN:.0f})")

    # Shade below BSDS500 as "already insufficient" region
    ax_right.fill_between(p_x, req_arch3, LOG2_MN,
                          where=(req_arch3 > LOG2_MN),
                          alpha=0.12, color="#FF5722",
                          label="Region where E<0.9 for BSDS500")

    # Annotate the crossover point
    crossover_p = LOG2_MN / 9.0
    if 1 < crossover_p < 8:
        ax_right.axvline(crossover_p, color="#FF9800", linestyle=":",
                         alpha=0.6, linewidth=1.2)
        ax_right.annotate(f"Crossover\np≈{crossover_p:.1f}",
                          xy=(crossover_p, LOG2_MN),
                          xytext=(crossover_p + 0.3, LOG2_MN * 0.9),
                          fontsize=8, color="#BF360C",
                          arrowprops=dict(arrowstyle="->", color="#BF360C",
                                          lw=0.8))

    ax_right.set_xlabel("Number of Processors (p)")
    ax_right.set_ylabel("Required  log₂(MN)  to maintain E=0.90")
    ax_right.set_title(f"Isoefficiency: Work Needed to Sustain E={E_target}\n"
                       "(doc: 4K frames needed for 6-node efficiency)")
    ax_right.set_xlim(1, 8)
    ax_right.set_ylim(0, max(req_arch3[-1], LOG2_MN) * 1.2)
    ax_right.legend(fontsize=7)

    plt.tight_layout()
    path = os.path.join(outdir, "fig12_isoefficiency_bsds.png")
    plt.savefig(path)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── CSV summary ───────────────────────────────────────────────────────────────
def write_csv(all_data, outdir):
    rows = []
    for img, img_data in all_data.items():
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
        print("  [WARN] No data to write")
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
    parser = argparse.ArgumentParser(description="BSDS500 Analysis Report Generator")
    parser.add_argument("--log",           default=os.path.join(SCRIPT_DIR, "report_bsds/analysis_bsds.log"))
    parser.add_argument("--outdir",        default=os.path.join(SCRIPT_DIR, "report_bsds"))
    parser.add_argument("--recon-dir",     default=os.path.join(SCRIPT_DIR, "report_bsds/reconstructed"))
    parser.add_argument("--orig-dir",      default="",
                        help="Directory of original BSDS test images for side-by-side comparison")
    parser.add_argument("--gt-dir",        default="")
    parser.add_argument("--node-counts",   default="2 4 6")
    parser.add_argument("--thread-counts", default="1 2 4")
    args = parser.parse_args()

    node_counts   = [int(x) for x in args.node_counts.split()]
    thread_counts = [int(x) for x in args.thread_counts.split()]
    gt_dir   = args.gt_dir   if args.gt_dir   else None
    orig_dir = args.orig_dir if args.orig_dir else None

    if not os.path.exists(args.log):
        print(f"[ERROR] Log not found: {args.log}")
        print("Run ./run_analysis_bsds.sh first.")
        sys.exit(1)

    os.makedirs(args.outdir, exist_ok=True)

    print(f"\nParsing {args.log} …")
    data = parse_log(args.log, node_counts, thread_counts)
    if not data:
        print("[ERROR] No IMAGE: blocks found in log.")
        sys.exit(1)
    print(f"Found {len(data)} image(s)\n")

    print("Generating performance figures …")
    fig1_serial_baselines(data, args.outdir)
    fig1b_serial_baselines_scatter(data, args.outdir)
    fig2_fft_arch_comparison(data, args.outdir)
    fig3_fft_arch3_panels(data, args.outdir)
    fig4_omp_scaling(data, args.outdir)
    fig5_spatial_arch3_speedup(data, args.outdir)
    fig5b_spatial_arch3_scatter(data, args.outdir)
    fig6_all_archs_per_filter(data, args.outdir)
    fig7_amdahl_comparison(data, args.outdir)
    fig8_brents_law(data, args.outdir)
    fig11_arch_mean_time(data, args.outdir)
    fig12_isoefficiency_bsds(data, args.outdir)

    print("\nGenerating quality metrics …")
    fig9_quality_metrics(args.recon_dir, gt_dir, args.outdir)

    print("\nGenerating reconstructed image grids …")
    fig10_recon_per_filter(args.recon_dir, args.outdir)
    fig10b_recon_per_image(args.recon_dir, orig_dir, args.outdir)

    print("\nGenerating summary CSV …")
    write_csv(data, args.outdir)

    charts = sorted(f for f in os.listdir(args.outdir) if f.endswith(".png"))
    print(f"\nReport complete → {args.outdir}/  ({len(charts)} figures)")
    for c in charts:
        print(f"  {args.outdir}/{c}")


if __name__ == "__main__":
    main()
