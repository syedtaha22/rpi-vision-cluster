#!/usr/bin/env python3
"""
generate_report_bsds.py — BSDS500-focused Report Generator

Parses analysis_bsds.log and produces (all in --outdir):
  Performance charts
  ├── <filter>_arch<N>_panels.png         Speedup | Efficiency | Brent's Law — one per arch (4 per filter)
  │                                        aggregated mean ± std over all BSDS500 images, Amdahl curve overlaid
  ├── <filter>_all_archs_panels.png       Same 3 panels with all 4 archs overlaid on one figure
  ├── <filter>_speedup_<img>.png          per-image speedup + efficiency + Brent's law (all archs)
  ├── sio_efficiency_<filter>.png         SIO (scaled iso-efficiency) per filter
  ├── amdahl_comparison.png               Amdahl fitted serial fraction per arch
  ├── brents_law_all.png                  T_p vs 1/p for all filters & MPI archs
  ├── baseline_comparison.png             Serial time across all 4 filters
  └── arch_mean_time.png                  Mean time per arch per filter

  Quality metrics (Jaccard · Dice · SSIM vs BSDS500 GT)
  ├── metrics_jaccard.png
  ├── metrics_dice.png
  ├── metrics_ssim.png
  └── metrics_summary.csv

  Resilience & Bully Election
  ├── resilience_recovery_times.png      Bar chart of Test1/2/3 recovery times (ms)
  ├── resilience_test_images.png         Side-by-side of the 4 resilience output PNGs
  ├── bully_election_latency.png         Election latency per scenario (normal / 1-fail / 2-fail)
  └── bully_election_rounds.png          Election rounds per scenario

  ├── recon_comparison_<img>.png          All archs side-by-side per image
  └── recon_montage_all.png               Thumbnail grid of every reconstructed image

  summary_table.csv                       Full timing table

Usage:
  python3 generate_report_bsds.py                                  # defaults
  python3 generate_report_bsds.py --log report_bsds/analysis_bsds.log \\
      --outdir report_bsds --recon-dir report_bsds/reconstructed   \\
      --gt-dir workspace/vision/datasets/BSDS500/data/groundTruth/test
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
    import numpy as np
except ImportError:
    print("[ERROR] matplotlib / numpy not installed. pip install matplotlib numpy")
    sys.exit(1)

try:
    from PIL import Image as PILImage
    HAS_PIL = True
except ImportError:
    HAS_PIL = False
    print("[WARN] Pillow not installed — image comparison sections will be skipped")

# ── Constants ──────────────────────────────────────────────────────────────────
FILTERS = ["Sobel", "Canny", "LoG", "FFT"]
ARCHS   = [1, 2, 3, 4]

ARCH_LABELS = {
    1: "Arch1 OMP Farm",
    2: "Arch2 OMP Pipeline",
    3: "Arch3 MPI Scatter",
    4: "Arch4 MPI Pipeline",
}
ARCH_PARALLELISM = {1: "threads", 2: "threads", 3: "nodes", 4: "nodes"}

COLORS = ["#2196F3", "#4CAF50", "#FF5722", "#9C27B0"]
FILTER_COLORS = {
    "Sobel": "#2196F3",
    "Canny": "#F44336",
    "LoG":   "#4CAF50",
    "FFT":   "#FF9800",
}

# Log patterns (identical to run_analysis.sh output format)
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

# Jaccard / Dice / SSIM patterns emitted by binaries that use metrics.h
# Format expected: [Metrics] jaccard=0.123 dice=0.456 ssim=0.789
METRICS_RE = re.compile(
    r"\[Metrics\]\s+jaccard=(?P<jaccard>[\d.]+)\s+dice=(?P<dice>[\d.]+)\s+ssim=(?P<ssim>[\d.]+)"
)

# ── Resilience log patterns ────────────────────────────────────────────────────
RESILIENCE_PATTERNS = {
    1: re.compile(r"\[Test 1\] Recovery complete\. Total time:\s*(?P<time>[\d.]+) ms"),
    2: re.compile(r"\[Test 2\] Straggler detected: rank (?P<rank>\d+) \((?P<time>[\d.]+) ms delay"),
    3: re.compile(r"\[Test 3\] Coordinator recovery complete\. Time with new coord:\s*(?P<time>[\d.]+) ms"),
    4: re.compile(r"\[Test 4\] Partial result assembled"),
}
RESILIENCE_CHECKSUM_RE = re.compile(
    r"\[Resilience Test\] Image: (?P<w>\d+)x(?P<h>\d+)\s+Serial Sobel checksum: (?P<cs>[\d.]+)"
)
RESILIENCE_PERRANK_RE = re.compile(
    r"\[Test 2\] Per-rank times \(ms\): (?P<ranks>.+)"
)

# ── Bully election log patterns ───────────────────────────────────────────────
BULLY_RESULT_RE = re.compile(
    r"\[Rank\s*(?P<rank>\d+)\] Election complete\. Coordinator = (?P<coord>\d+)"
    r"\s+Latency = (?P<latency>[\d.]+) ms\s+Rounds = (?P<rounds>\d+)"
)


def parse_log(log_path, node_counts, thread_counts):
    """
    Returns:
      data[img_name][filter][arch]   = list of (parallelism_count, time_s)
      data[img_name]['baseline']     = {filter: time_s}
      data[img_name]['metrics'][arch_tag] = {jaccard, dice, ssim}   (arch_tag e.g. "Sobel_arch1")
    """
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
                    "metrics": {},
                    **{flt: {a: [] for a in ARCHS} for flt in FILTERS},
                }
            counters[current_img] = {(flt, a): 0 for flt in FILTERS for a in ARCHS}
            continue

        if current_img is None:
            continue

        img_data = data[current_img]

        # Baseline timings
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
                    if ARCH_PARALLELISM[arch] == "threads":
                        p = thread_counts[idx] if idx < len(thread_counts) else idx + 1
                    else:
                        p = node_counts[idx] if idx < len(node_counts) else idx + 2
                    counters[current_img][(flt, arch)] += 1
                img_data[flt][arch].append((p, time_val))

        # Quality metrics
        m = METRICS_RE.search(line)
        if m:
            # Try to associate the metric with the most recently active (filter, arch)
            # by scanning the preceding context — simple heuristic: last arch in log
            key = f"last"  # fallback
            for flt in FILTERS:
                for arch in ARCHS:
                    pat = PATTERNS.get((flt, arch))
                    if pat and pat.search(line):
                        key = f"{flt}_arch{arch}"
            img_data["metrics"].setdefault(key, []).append({
                "jaccard": float(m.group("jaccard")),
                "dice":    float(m.group("dice")),
                "ssim":    float(m.group("ssim")),
            })

    return data


# ── Performance chart helpers ──────────────────────────────────────────────────

def _speedup_subplots(ax_sp, ax_eff, ax_br, points, serial_time, arch, label):
    if not points:
        return
    ps = np.array([x[0] for x in points], dtype=float)
    ts = np.array([x[1] for x in points], dtype=float)
    speedup = serial_time / ts
    eff     = speedup / ps
    color   = COLORS[arch - 1]
    ax_sp.plot(ps, speedup, "o-", color=color, label=label)
    ax_eff.plot(ps, eff,    "o-", color=color, label=label)
    ax_br.plot(1.0 / ps, ts, "o-", color=color, label=label)


def plot_filter_perf(img_name, filter_name, arch_data, baseline_time, outdir):
    """Speedup / Efficiency / Brent's Law for one filter on one image."""
    fig, axes = plt.subplots(1, 3, figsize=(15, 4))
    fig.suptitle(f"{filter_name} — {img_name}", fontsize=12, fontweight="bold")
    ax_sp, ax_eff, ax_br = axes

    # Amdahl reference (90% parallel fraction)
    p_ref = np.linspace(1, 20, 200)
    f_par = 0.9
    ax_sp.plot(p_ref, 1 / ((1 - f_par) + f_par / p_ref),
               "k--", alpha=0.4, label="Amdahl f=0.90")

    any_data = False
    for arch in ARCHS:
        points = arch_data.get(arch, [])
        if not points:
            continue
        any_data = True
        _speedup_subplots(ax_sp, ax_eff, ax_br,
                          points, baseline_time, arch, ARCH_LABELS[arch])

    for ax, title, xlabel, ylabel in [
        (ax_sp,  "Speedup (vs Amdahl)",       "Parallelism p",  "Speedup S(p)"),
        (ax_eff, "SIO Efficiency  E = S/p",    "Parallelism p",  "Efficiency E"),
        (ax_br,  "Brent's Law  T_p vs 1/p",   "1/p",            "Time (s)"),
    ]:
        ax.set_title(title)
        ax.set_xlabel(xlabel)
        ax.set_ylabel(ylabel)
        ax.legend(fontsize=7)
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    safe = img_name.replace("/", "_").replace(" ", "_")
    path = os.path.join(outdir, f"{filter_name.lower()}_speedup_{safe}.png")
    plt.savefig(path, dpi=120)
    plt.close(fig)
    print(f"  Saved: {path}")
    if not any_data:
        print(f"  [WARN] No data for {filter_name} / {img_name}")


def plot_per_arch_panels(all_data, filter_name, outdir):
    """
    Generate one 3-panel chart (Speedup | Efficiency | Brent's Law) per arch,
    aggregated (mean ± std) over all BSDS500 images — matching the screenshot
    style exactly.

    Outputs  (one per arch, 4 per filter):
      <filter>_arch<N>_panels.png
    Plus one combined overlay figure with all 4 archs on the same axes:
      <filter>_all_archs_panels.png
    """
    # ── Collect mean timing per p-value, per arch ────────────────────────────
    # arch_buckets[arch][p] = [t, t, ...]  (one entry per image measurement)
    arch_buckets = {a: defaultdict(list) for a in ARCHS}
    baseline_vals = []

    for img_data in all_data.values():
        bl = img_data["baseline"].get(filter_name)
        if bl is not None:
            baseline_vals.append(bl)
        for arch in ARCHS:
            for p, t in img_data.get(filter_name, {}).get(arch, []):
                arch_buckets[arch][p].append(t)

    if not baseline_vals:
        # Fall back: use slowest observed time as pseudo-serial
        all_t = [t for a in ARCHS for buck in arch_buckets[a].values() for t in buck]
        if not all_t:
            print(f"  [WARN] No data for {filter_name} — skipping per-arch panels")
            return
        baseline_vals = [max(all_t)]

    T_serial_mean = float(np.mean(baseline_vals))
    T_serial_std  = float(np.std(baseline_vals))

    # Amdahl reference curve — fitted f from observed data, fallback 0.9
    # (fit per arch, used in the individual panels; overall for combined)
    def _fit_amdahl_f(ps_arr, sp_arr):
        """Return fitted parallel fraction f, or 0.9 on failure."""
        try:
            from scipy.optimize import curve_fit
            def amdahl(p, f):
                return 1.0 / ((1.0 - f) + f / p)
            popt, _ = curve_fit(amdahl, ps_arr, sp_arr,
                                p0=[0.9], bounds=(0.01, 0.9999))
            return float(popt[0])
        except Exception:
            f_vals = []
            for p, sp in zip(ps_arr, sp_arr):
                if p > 1 and sp > 0:
                    f_vals.append(min(1.0, max(0.0, (1 - 1.0/sp) / (1 - 1.0/p))))
            return float(np.mean(f_vals)) if f_vals else 0.9

    p_curve = np.linspace(1, 20, 300)

    MARKERS = ["o", "s", "^", "D"]

    # ── Individual 3-panel charts, one per arch ──────────────────────────────
    for arch in ARCHS:
        bucket = arch_buckets[arch]
        if not bucket:
            continue

        ps_sorted = sorted(bucket.keys())
        ps_arr  = np.array(ps_sorted, dtype=float)
        t_means = np.array([np.mean(bucket[p]) for p in ps_sorted])
        t_stds  = np.array([np.std(bucket[p])  for p in ps_sorted])

        sp_means = T_serial_mean / t_means
        sp_stds  = T_serial_mean / (t_means ** 2) * t_stds  # propagated

        eff_means = sp_means / ps_arr
        eff_stds  = sp_stds  / ps_arr

        inv_p = 1.0 / ps_arr

        # Fit Amdahl f for this arch
        f_fit = _fit_amdahl_f(ps_arr, sp_means)
        sp_amdahl = 1.0 / ((1.0 - f_fit) + f_fit / p_curve)

        color  = COLORS[arch - 1]
        marker = MARKERS[arch - 1]
        x_label = "Threads" if ARCH_PARALLELISM[arch] == "threads" else "Nodes"

        fig, axes = plt.subplots(1, 3, figsize=(15, 4))
        fig.suptitle(
            f"{filter_name} — {ARCH_LABELS[arch]}  (BSDS500 avg, n={len(all_data)} images)",
            fontsize=12, fontweight="bold"
        )
        ax_sp, ax_eff, ax_br = axes

        # ── Speedup panel ────────────────────────────────────────────────────
        ax_sp.plot(p_curve, sp_amdahl, "--",
                   color="#FF8C00", linewidth=1.8, alpha=0.85,
                   label=f"Amdahl (f={f_fit:.2f})")
        ax_sp.errorbar(ps_arr, sp_means, yerr=sp_stds,
                       fmt=f"{marker}-", color=color, linewidth=2,
                       markersize=7, capsize=4, label="Empirical")
        ax_sp.set_title("Speedup (Amdahl's Law)")
        ax_sp.set_xlabel(x_label)
        ax_sp.set_ylabel("Speedup")
        ax_sp.legend(fontsize=9)
        ax_sp.grid(True, alpha=0.3)

        # ── Efficiency panel ─────────────────────────────────────────────────
        ax_eff.errorbar(ps_arr, eff_means, yerr=eff_stds,
                        fmt=f"{marker}-", color=color, linewidth=2,
                        markersize=7, capsize=4)
        ax_eff.set_title("Efficiency")
        ax_eff.set_xlabel(x_label)
        ax_eff.set_ylabel("E = S/p")
        ax_eff.grid(True, alpha=0.3)

        # ── Brent's Law panel ────────────────────────────────────────────────
        ax_br.errorbar(inv_p, t_means, yerr=t_stds,
                       fmt=f"{marker}-", color=color, linewidth=2,
                       markersize=7, capsize=4, label="Empirical")
        if len(ps_arr) >= 2:
            coef = np.polyfit(inv_p, t_means, 1)
            x_fit = np.linspace(0, inv_p.max() * 1.15, 100)
            t_inf = coef[1]
            ax_br.plot(x_fit, np.polyval(coef, x_fit),
                       "--", color="#FF8C00", linewidth=1.6, alpha=0.8,
                       label=f"Fit  T∞≈{t_inf:.4f}s")
        ax_br.set_title("Brent's Law (T vs 1/p)")
        ax_br.set_xlabel("1/p")
        ax_br.set_ylabel("Time (s)")
        ax_br.legend(fontsize=9)
        ax_br.grid(True, alpha=0.3)

        plt.tight_layout()
        fname = f"{filter_name.lower()}_arch{arch}_panels.png"
        path  = os.path.join(outdir, fname)
        plt.savefig(path, dpi=130)
        plt.close(fig)
        print(f"  Saved: {path}")

    # ── Combined overlay: all 4 archs on the same 3 axes ────────────────────
    fig, axes = plt.subplots(1, 3, figsize=(15, 4))
    fig.suptitle(
        f"{filter_name} — All Architectures  (BSDS500 avg, n={len(all_data)} images)",
        fontsize=12, fontweight="bold"
    )
    ax_sp, ax_eff, ax_br = axes

    # Amdahl reference (f=0.9 canonical) for the combined chart
    ax_sp.plot(p_curve, 1.0 / (0.1 + 0.9 / p_curve),
               "k--", linewidth=1.5, alpha=0.35, label="Amdahl f=0.90")

    for arch in ARCHS:
        bucket = arch_buckets[arch]
        if not bucket:
            continue
        ps_sorted = sorted(bucket.keys())
        ps_arr  = np.array(ps_sorted, dtype=float)
        t_means = np.array([np.mean(bucket[p]) for p in ps_sorted])
        t_stds  = np.array([np.std(bucket[p])  for p in ps_sorted])
        sp_means = T_serial_mean / t_means
        eff_means = sp_means / ps_arr
        inv_p = 1.0 / ps_arr
        color  = COLORS[arch - 1]
        marker = MARKERS[arch - 1]
        lbl    = ARCH_LABELS[arch]

        ax_sp.errorbar(ps_arr, sp_means, yerr=T_serial_mean / (t_means**2) * t_stds,
                       fmt=f"{marker}-", color=color, linewidth=2,
                       markersize=6, capsize=3, label=lbl)
        ax_eff.errorbar(ps_arr, eff_means,
                        yerr=(T_serial_mean / (t_means**2) * t_stds) / ps_arr,
                        fmt=f"{marker}-", color=color, linewidth=2,
                        markersize=6, capsize=3, label=lbl)
        ax_br.errorbar(inv_p, t_means, yerr=t_stds,
                       fmt=f"{marker}-", color=color, linewidth=2,
                       markersize=6, capsize=3, label=lbl)
        if len(ps_arr) >= 2:
            coef = np.polyfit(inv_p, t_means, 1)
            x_fit = np.linspace(0, inv_p.max() * 1.1, 80)
            ax_br.plot(x_fit, np.polyval(coef, x_fit),
                       "--", color=color, linewidth=1.2, alpha=0.5)

    x_label_combined = "Parallelism (threads or nodes)"
    for ax, title, xl, yl in [
        (ax_sp,  "Speedup (Amdahl's Law)",     x_label_combined, "Speedup"),
        (ax_eff, "Efficiency  E = S/p",         x_label_combined, "E"),
        (ax_br,  "Brent's Law  T_p vs 1/p",    "1/p",            "Time (s)"),
    ]:
        ax.set_title(title)
        ax.set_xlabel(xl)
        ax.set_ylabel(yl)
        ax.legend(fontsize=7)
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    fname = f"{filter_name.lower()}_all_archs_panels.png"
    path  = os.path.join(outdir, fname)
    plt.savefig(path, dpi=130)
    plt.close(fig)
    print(f"  Saved: {path}")


def plot_sio_efficiency(all_data, filter_name, outdir):
    """
    Scaled Iso-efficiency (SIO): for each arch, plot E = S/p averaged over all
    images, both for thread-based (Arch1/2) and node-based (Arch3/4) scaling.
    One figure per filter.
    """
    fig, axes = plt.subplots(1, 2, figsize=(12, 4))
    fig.suptitle(f"SIO Efficiency — {filter_name} (averaged over BSDS500 images)",
                 fontsize=12, fontweight="bold")

    for ax, archs, x_label in [
        (axes[0], [1, 2], "Threads"),
        (axes[1], [3, 4], "MPI Nodes"),
    ]:
        for arch in archs:
            # Collect (p, E) pairs from all images
            bucket = defaultdict(list)
            for img_data in all_data.values():
                baseline = img_data["baseline"].get(filter_name)
                if baseline is None:
                    all_times = [t for _, t in img_data.get(filter_name, {}).get(arch, [])]
                    baseline = max(all_times) if all_times else None
                if baseline is None:
                    continue
                for p, t in img_data.get(filter_name, {}).get(arch, []):
                    speedup = baseline / t
                    eff     = speedup / p
                    bucket[p].append(eff)

            if not bucket:
                continue
            ps   = sorted(bucket.keys())
            effs = [np.mean(bucket[p]) for p in ps]
            stds = [np.std(bucket[p])  for p in ps]
            color = COLORS[arch - 1]
            ax.errorbar(ps, effs, yerr=stds, fmt="o-", color=color,
                        label=ARCH_LABELS[arch], capsize=4)

        ax.axhline(1.0, color="k", linestyle="--", alpha=0.4, label="Ideal (E=1)")
        ax.set_xlabel(x_label)
        ax.set_ylabel("Efficiency E = S/p")
        ax.set_title(f"SIO — {x_label} scaling")
        ax.legend(fontsize=8)
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    path = os.path.join(outdir, f"sio_efficiency_{filter_name.lower()}.png")
    plt.savefig(path, dpi=120)
    plt.close(fig)
    print(f"  Saved: {path}")


def plot_amdahl_comparison(all_data, outdir):
    """
    Fit the serial fraction f for each (filter, arch) via Amdahl's Law:
      S(p) = 1 / ((1-f) + f/p)  →  least-squares fit on observed speedups.
    Visualise as a heatmap / grouped bar chart.
    """
    filters_present = [flt for flt in FILTERS
                       if any(any(img_data.get(flt, {}).get(a) for a in ARCHS)
                              for img_data in all_data.values())]
    if not filters_present:
        print("  [WARN] No arch data for Amdahl comparison")
        return

    from scipy.optimize import curve_fit  # local import — optional

    def amdahl(p, f):
        return 1.0 / ((1.0 - f) + f / p)

    results = {}  # (filter, arch) → fitted f or None
    for flt in filters_present:
        for arch in ARCHS:
            all_ps, all_sp = [], []
            for img_data in all_data.values():
                baseline = img_data["baseline"].get(flt)
                if baseline is None:
                    continue
                for p, t in img_data.get(flt, {}).get(arch, []):
                    if t > 0:
                        all_ps.append(float(p))
                        all_sp.append(baseline / t)
            if len(all_ps) < 2:
                results[(flt, arch)] = None
                continue
            try:
                popt, _ = curve_fit(amdahl, all_ps, all_sp,
                                    p0=[0.9], bounds=(0.01, 0.9999))
                results[(flt, arch)] = float(popt[0])
            except Exception:
                # Fall back to simple estimate: f ≈ mean(1 - 1/S) / (1 - 1/p)
                f_vals = []
                for p, sp in zip(all_ps, all_sp):
                    if p > 1 and sp > 0:
                        f_vals.append(min(1.0, max(0.0,
                            (1 - 1.0/sp) / (1 - 1.0/p))))
                results[(flt, arch)] = float(np.mean(f_vals)) if f_vals else None

    n_archs = len(ARCHS)
    n_filters = len(filters_present)
    x = np.arange(n_filters)
    width = 0.18

    fig, ax = plt.subplots(figsize=(10, 5))
    for i, arch in enumerate(ARCHS):
        vals = [results.get((flt, arch)) for flt in filters_present]
        vals_plot = [v if v is not None else 0 for v in vals]
        bars = ax.bar(x + (i - 1.5) * width, vals_plot, width,
                      color=COLORS[i], label=ARCH_LABELS[arch], alpha=0.85)
        for bar, v in zip(bars, vals):
            if v is not None:
                ax.text(bar.get_x() + bar.get_width() / 2,
                        bar.get_height() + 0.005,
                        f"{v:.2f}", ha="center", va="bottom", fontsize=7)

    ax.set_xticks(x)
    ax.set_xticklabels(filters_present)
    ax.set_ylabel("Fitted parallel fraction  f  (Amdahl)")
    ax.set_title("Amdahl Parallel Fraction per Filter × Architecture\n"
                 "(higher = more parallelisable)", fontweight="bold")
    ax.set_ylim(0, 1.05)
    ax.legend(fontsize=8)
    ax.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()
    path = os.path.join(outdir, "amdahl_comparison.png")
    plt.savefig(path, dpi=120)
    plt.close(fig)
    print(f"  Saved: {path}")


def plot_brents_law_all(all_data, outdir, node_counts):
    """
    Brent's Law T_p ≤ T_1/p + T_∞:
    Plot T_p vs 1/p for each filter × MPI arch, with linear fit to
    extract T_∞ (critical path / y-intercept).
    """
    fig, axes = plt.subplots(2, 2, figsize=(12, 8))
    fig.suptitle("Brent's Law  T_p vs 1/p  (MPI architectures, BSDS500 average)",
                 fontsize=13, fontweight="bold")
    axes_flat = axes.flatten()

    for idx, flt in enumerate(FILTERS):
        ax = axes_flat[idx]
        ax.set_title(flt, fontsize=10)

        for arch in [3, 4]:
            bucket = defaultdict(list)
            for img_data in all_data.values():
                for p, t in img_data.get(flt, {}).get(arch, []):
                    bucket[p].append(t)
            if not bucket:
                continue
            ps   = np.array(sorted(bucket.keys()), dtype=float)
            ts   = np.array([np.mean(bucket[p]) for p in ps])
            inv_p = 1.0 / ps
            color = COLORS[arch - 1]
            ax.plot(inv_p, ts, "o-", color=color, label=ARCH_LABELS[arch])

            if len(ps) >= 2:
                coef = np.polyfit(inv_p, ts, 1)  # T_p ≈ (T1 - T_inf) * (1/p) + T_inf
                x_fit = np.linspace(0, inv_p.max() * 1.1, 80)
                t_inf = coef[1]
                ax.plot(x_fit, np.polyval(coef, x_fit),
                        "--", color=color, alpha=0.5,
                        label=f"A{arch} fit  T∞≈{t_inf:.4f}s")

        ax.set_xlabel("1/p")
        ax.set_ylabel("T_p (s)")
        ax.legend(fontsize=7)
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    path = os.path.join(outdir, "brents_law_all.png")
    plt.savefig(path, dpi=120)
    plt.close(fig)
    print(f"  Saved: {path}")


def plot_baseline_comparison(all_data, outdir):
    """Bar chart: mean serial baseline time across all BSDS images."""
    means, stds = {}, {}
    for flt in FILTERS:
        vals = [img_data["baseline"][flt]
                for img_data in all_data.values()
                if flt in img_data["baseline"]]
        if vals:
            means[flt] = np.mean(vals)
            stds[flt]  = np.std(vals)

    if not means:
        print("  [WARN] No baseline data")
        return

    fig, ax = plt.subplots(figsize=(7, 4))
    fkeys = list(means.keys())
    vals  = [means[f] for f in fkeys]
    errs  = [stds[f]  for f in fkeys]
    bars  = ax.bar(fkeys, vals, yerr=errs, capsize=5,
                   color=[FILTER_COLORS.get(f, "#888") for f in fkeys], alpha=0.85)
    ax.set_title("Serial Baseline — Mean over BSDS500 images", fontweight="bold")
    ax.set_ylabel("Time (s)")
    ax.set_xlabel("Filter")
    for bar, v in zip(bars, vals):
        ax.text(bar.get_x() + bar.get_width() / 2,
                bar.get_height() + max(vals) * 0.01,
                f"{v:.4f}s", ha="center", va="bottom", fontsize=9)
    ax.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()
    path = os.path.join(outdir, "baseline_comparison.png")
    plt.savefig(path, dpi=120)
    plt.close(fig)
    print(f"  Saved: {path}")


def plot_arch_mean_time(all_data, outdir):
    """Grouped bar: mean time per arch per filter across all BSDS images."""
    fig, axes = plt.subplots(1, len(FILTERS), figsize=(5 * len(FILTERS), 4))
    if len(FILTERS) == 1:
        axes = [axes]
    fig.suptitle("Mean Execution Time per Architecture (BSDS500)", fontsize=12, fontweight="bold")

    for ax, flt in zip(axes, FILTERS):
        means = []
        labels = []
        for arch in ARCHS:
            vals = [t for img_data in all_data.values()
                    for _, t in img_data.get(flt, {}).get(arch, [])]
            if vals:
                means.append(np.mean(vals))
                labels.append(ARCH_LABELS[arch].split()[0] + f"\nA{arch}")
        if not means:
            ax.set_title(flt); continue
        color = FILTER_COLORS.get(flt, "#888")
        bars = ax.bar(labels, means, color=color, alpha=0.8, edgecolor="black")
        ax.set_title(flt)
        ax.set_ylabel("Time (s)")
        for bar, v in zip(bars, means):
            ax.text(bar.get_x() + bar.get_width() / 2,
                    bar.get_height() + max(means) * 0.01,
                    f"{v:.4f}", ha="center", va="bottom", fontsize=8)
        ax.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()
    path = os.path.join(outdir, "arch_mean_time.png")
    plt.savefig(path, dpi=120)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Quality metrics (Jaccard / Dice / SSIM) ────────────────────────────────────

def _load_binary_image(path):
    """Return flat uint8 numpy array (0 or 255), or None on error."""
    if not HAS_PIL:
        return None
    try:
        img = PILImage.open(path).convert("L")
        arr = np.array(img, dtype=np.uint8)
        return arr.flatten()
    except Exception as e:
        print(f"  [WARN] Could not load {path}: {e}")
        return None


def _compute_jaccard_dice_ssim(pred_arr, gt_arr, width, height):
    """Pure numpy implementation matching metrics.h."""
    p = (pred_arr > 128).astype(np.int32)
    g = (gt_arr   > 128).astype(np.int32)
    tp = int(np.sum(p & g))
    fp = int(np.sum(p & (1 - g)))
    fn = int(np.sum((1 - p) & g))
    jaccard = tp / (tp + fp + fn + 1e-6)
    dice    = 2 * tp / (2 * tp + fp + fn + 1e-6)

    # SSIM with 11×11 window
    c1, c2 = 6.5025, 58.5225
    pred2d = pred_arr.reshape(height, width).astype(np.float64)
    gt2d   = gt_arr.reshape(height, width).astype(np.float64)
    ssim_sum, count = 0.0, 0
    half = 5
    for y in range(half, height - half):
        for x in range(half, width - half):
            pw = pred2d[y - half:y + half + 1, x - half:x + half + 1].flatten()
            gw = gt2d[y - half:y + half + 1, x - half:x + half + 1].flatten()
            mu_p, mu_g = pw.mean(), gw.mean()
            dp, dg = pw - mu_p, gw - mu_g
            sp2 = (dp * dp).sum() / 120.0
            sg2 = (dg * dg).sum() / 120.0
            spg = (dp * dg).sum() / 120.0
            num = (2 * mu_p * mu_g + c1) * (2 * spg + c2)
            den = (mu_p**2 + mu_g**2 + c1) * (sp2 + sg2 + c2)
            if den > 0:
                ssim_sum += num / den
                count += 1
    ssim = ssim_sum / count if count > 0 else 0.0
    return float(jaccard), float(dice), float(ssim)


def _fast_ssim(pred2d, gt2d):
    """Vectorised SSIM using scipy uniform_filter for speed."""
    try:
        from scipy.ndimage import uniform_filter
    except ImportError:
        return None
    H, W = pred2d.shape
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


def compute_image_metrics(pred_path, gt_path):
    """Return (jaccard, dice, ssim) comparing pred PNG against GT PNG."""
    pred = _load_binary_image(pred_path)
    gt   = _load_binary_image(gt_path)
    if pred is None or gt is None:
        return None
    # Resize GT to match pred if sizes differ
    if len(pred) != len(gt):
        try:
            pred_img = PILImage.open(pred_path).convert("L")
            gt_img   = PILImage.open(gt_path).convert("L").resize(pred_img.size, PILImage.NEAREST)
            pred = np.array(pred_img).flatten()
            gt   = np.array(gt_img).flatten()
        except Exception as e:
            print(f"  [WARN] Size mismatch {pred_path} vs {gt_path}: {e}")
            return None
    H = W = int(np.sqrt(len(pred)))  # approximation; real dims from image
    try:
        img_pil = PILImage.open(pred_path).convert("L")
        W, H = img_pil.size
    except Exception:
        pass
    p2d = pred.reshape(H, W)
    g2d = gt.reshape(H, W)
    pbin = (p2d > 128).astype(np.int32).flatten()
    gbin = (g2d > 128).astype(np.int32).flatten()
    tp = int(np.sum(pbin & gbin))
    fp = int(np.sum(pbin & (1 - gbin)))
    fn = int(np.sum((1 - pbin) & gbin))
    jaccard = tp / (tp + fp + fn + 1e-6)
    dice    = 2 * tp / (2 * tp + fp + fn + 1e-6)
    ssim = _fast_ssim(p2d.astype(np.float64), g2d.astype(np.float64))
    if ssim is None:
        # Slow path — only on small images
        if H * W < 512 * 512:
            ssim = _compute_jaccard_dice_ssim(pred.astype(np.uint8), gt.astype(np.uint8), W, H)[2]
        else:
            ssim = 0.0
    return float(jaccard), float(dice), float(ssim)


def evaluate_quality_metrics(recon_dir, gt_dir, outdir):
    """
    Walk recon_dir for all reconstructed PNGs.  For each, find the matching
    BSDS ground-truth edge map and compute Jaccard / Dice / SSIM.

    Expected directory layout (produced by run_analysis_bsds.sh):
      recon_dir/
        sobel_arch1/   <filter>_arch<N>_<stem>.png
        canny_arch4/
        ...

    GT layout:
      gt_dir/
        <stem>.png     (binary edge map, 0/255)
    """
    if not HAS_PIL:
        print("  [SKIP] Pillow not installed — quality metrics skipped")
        return

    if not os.path.isdir(recon_dir):
        print(f"  [SKIP] Reconstructed dir not found: {recon_dir}")
        return

    if not os.path.isdir(gt_dir):
        print(f"  [WARN] GT dir not found: {gt_dir} — using dummy random GT for structure only")
        gt_dir = None

    rows = []  # {filter, arch, image, jaccard, dice, ssim}

    for sub in sorted(os.listdir(recon_dir)):
        sub_path = os.path.join(recon_dir, sub)
        if not os.path.isdir(sub_path):
            continue
        # Parse filter + arch from subdir name e.g. "sobel_arch1"
        m = re.match(r"(\w+)_arch(\d)", sub)
        if not m:
            continue
        flt_tag  = m.group(1).capitalize()
        arch_num = int(m.group(2))

        for fn in sorted(os.listdir(sub_path)):
            if not fn.endswith(".png"):
                continue
            pred_path = os.path.join(sub_path, fn)

            # Extract image stem: e.g. "sobel_arch1_t4_000001" → "000001"
            stem = re.sub(r"^[a-z]+_arch\d[^_]*_", "", fn.replace(".png", ""))

            gt_path = None
            if gt_dir:
                for ext in [".png", ".jpg"]:
                    candidate = os.path.join(gt_dir, stem + ext)
                    if os.path.exists(candidate):
                        gt_path = candidate
                        break

            if gt_path is None:
                continue

            result = compute_image_metrics(pred_path, gt_path)
            if result is None:
                continue
            jaccard, dice, ssim = result
            rows.append({
                "filter": flt_tag,
                "arch":   arch_num,
                "image":  stem,
                "jaccard": round(jaccard, 5),
                "dice":    round(dice,    5),
                "ssim":    round(ssim,    5),
            })

    if not rows:
        print("  [WARN] No quality metric data collected — check recon_dir / gt_dir paths")
        return

    # Write CSV
    csv_path = os.path.join(outdir, "metrics_summary.csv")
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["filter", "arch", "image",
                                                "jaccard", "dice", "ssim"])
        writer.writeheader()
        writer.writerows(rows)
    print(f"  Saved: {csv_path}")

    # Aggregate: mean per (filter, arch)
    agg = defaultdict(lambda: defaultdict(list))
    for r in rows:
        key = (r["filter"], r["arch"])
        agg[key]["jaccard"].append(r["jaccard"])
        agg[key]["dice"].append(r["dice"])
        agg[key]["ssim"].append(r["ssim"])

    filters_present = sorted({r["filter"] for r in rows})
    archs_present   = sorted({r["arch"] for r in rows})

    def _metric_bar_chart(metric_name, ylabel, fname):
        x = np.arange(len(filters_present))
        width = 0.2
        fig, ax = plt.subplots(figsize=(10, 5))
        for i, arch in enumerate(archs_present):
            means = []
            stds  = []
            for flt in filters_present:
                vals = agg[(flt, arch)].get(metric_name, [])
                means.append(np.mean(vals) if vals else 0.0)
                stds.append(np.std(vals)   if vals else 0.0)
            offset = (i - (len(archs_present) - 1) / 2) * width
            bars = ax.bar(x + offset, means, width, yerr=stds, capsize=3,
                          color=COLORS[arch - 1], label=ARCH_LABELS[arch], alpha=0.85)
        ax.set_xticks(x)
        ax.set_xticklabels(filters_present)
        ax.set_ylabel(ylabel)
        ax.set_title(f"{metric_name.capitalize()} vs BSDS500 Ground Truth  "
                     f"(mean ± std over test images)", fontweight="bold")
        ax.legend(fontsize=8)
        ax.grid(True, axis="y", alpha=0.3)
        plt.tight_layout()
        path = os.path.join(outdir, fname)
        plt.savefig(path, dpi=120)
        plt.close(fig)
        print(f"  Saved: {path}")

    _metric_bar_chart("jaccard", "Jaccard (IoU)",   "metrics_jaccard.png")
    _metric_bar_chart("dice",    "Dice / F1",        "metrics_dice.png")
    _metric_bar_chart("ssim",    "SSIM",             "metrics_ssim.png")
    print(f"  Quality metrics: {len(rows)} image-arch pairs evaluated")


# ── Image comparison plots ─────────────────────────────────────────────────────

def _sorted_recon_images(recon_dir):
    """
    Returns a dict  img_stem → {arch_tag: filepath}  for all PNGs in recon_dir.
    arch_tag e.g. "sobel_arch1", "canny_arch4"
    """
    result = defaultdict(dict)
    if not os.path.isdir(recon_dir):
        return result
    for sub in sorted(os.listdir(recon_dir)):
        sub_path = os.path.join(recon_dir, sub)
        if not os.path.isdir(sub_path):
            continue
        for fn in sorted(os.listdir(sub_path)):
            if not fn.endswith(".png"):
                continue
            stem = re.sub(r"^[a-z]+_arch\d[^_]*_", "", fn.replace(".png", ""))
            result[stem][sub] = os.path.join(sub_path, fn)
    return result


def plot_recon_comparison(recon_dir, outdir, max_images=8):
    """
    For each unique image stem, produce a side-by-side panel showing the
    output of every architecture that produced a result.
    """
    if not HAS_PIL:
        print("  [SKIP] Pillow not installed — reconstruction comparison skipped")
        return

    mapping = _sorted_recon_images(recon_dir)
    if not mapping:
        print(f"  [WARN] No reconstructed images found in {recon_dir}")
        return

    stems = sorted(mapping.keys())[:max_images]

    for stem in stems:
        arch_map = mapping[stem]
        n = len(arch_map)
        if n == 0:
            continue

        fig, axes = plt.subplots(1, n, figsize=(3.5 * n, 3.5))
        if n == 1:
            axes = [axes]
        fig.suptitle(f"Reconstructed outputs — {stem}", fontsize=10, fontweight="bold")

        for ax, (arch_tag, fpath) in zip(axes, sorted(arch_map.items())):
            try:
                img = PILImage.open(fpath).convert("L")
                ax.imshow(np.array(img), cmap="gray")
            except Exception as e:
                ax.text(0.5, 0.5, f"Error\n{e}", ha="center", va="center",
                        transform=ax.transAxes, fontsize=7)
            ax.set_title(arch_tag.replace("_", "\n"), fontsize=8)
            ax.axis("off")

        plt.tight_layout()
        safe = stem.replace("/", "_").replace(" ", "_")
        path = os.path.join(outdir, f"recon_comparison_{safe}.png")
        plt.savefig(path, dpi=100)
        plt.close(fig)
        print(f"  Saved: {path}")


def plot_recon_montage(recon_dir, outdir, thumb_h=120, max_cols=10):
    """
    Thumbnail grid of ALL reconstructed images, grouped by filter/arch subdir.
    """
    if not HAS_PIL:
        print("  [SKIP] Pillow not installed — montage skipped")
        return

    if not os.path.isdir(recon_dir):
        return

    panels = []  # list of (label, thumb PIL)
    for sub in sorted(os.listdir(recon_dir)):
        sub_path = os.path.join(recon_dir, sub)
        if not os.path.isdir(sub_path):
            continue
        for fn in sorted(os.listdir(sub_path)):
            if not fn.endswith(".png"):
                continue
            fpath = os.path.join(sub_path, fn)
            try:
                img  = PILImage.open(fpath).convert("L")
                w_th = max(1, int(img.width * thumb_h / img.height))
                thumb = img.resize((w_th, thumb_h), PILImage.LANCZOS)
                panels.append((sub + "\n" + fn[:20], thumb))
            except Exception:
                pass

    if not panels:
        print("  [WARN] No images for montage")
        return

    n      = len(panels)
    n_cols = min(n, max_cols)
    n_rows = (n + n_cols - 1) // n_cols

    fig, axes = plt.subplots(n_rows, n_cols,
                             figsize=(2.5 * n_cols, 2.5 * n_rows))
    axes_flat = np.array(axes).flatten() if n > 1 else [axes]

    for ax, (label, thumb) in zip(axes_flat, panels):
        ax.imshow(np.array(thumb), cmap="gray")
        ax.set_title(label, fontsize=5)
        ax.axis("off")
    for ax in axes_flat[n:]:
        ax.axis("off")

    fig.suptitle("All Reconstructed Images — Thumbnail Grid", fontsize=11, fontweight="bold")
    plt.tight_layout()
    path = os.path.join(outdir, "recon_montage_all.png")
    plt.savefig(path, dpi=100)
    plt.close(fig)
    print(f"  Saved: {path}")



# ── Resilience + Bully log parsers ────────────────────────────────────────────

def parse_resilience_log(log_path):
    """
    Scan the log for resilience test output.
    Returns:
      {
        'checksum':   float | None,
        'test1_ms':   float | None,   # worker crash recovery time
        'test2_ms':   float | None,   # straggler delay
        'test2_perrank': [float, ...] | None,
        'test3_ms':   float | None,   # coordinator recovery time
        'test4':      bool,           # partial result assembled
      }
    """
    result = {
        'checksum': None, 'test1_ms': None,
        'test2_ms': None, 'test2_perrank': None,
        'test3_ms': None, 'test4': False,
    }
    with open(log_path, "r", errors="replace") as f:
        for line in f:
            m = RESILIENCE_CHECKSUM_RE.search(line)
            if m:
                result['checksum'] = float(m.group('cs'))
            m = RESILIENCE_PATTERNS[1].search(line)
            if m:
                result['test1_ms'] = float(m.group('time'))
            m = RESILIENCE_PATTERNS[2].search(line)
            if m:
                result['test2_ms'] = float(m.group('time'))
            m = RESILIENCE_PERRANK_RE.search(line)
            if m:
                parts = re.findall(r"rank\d+=(\d+\.?\d*)", m.group('ranks'))
                if parts:
                    result['test2_perrank'] = [float(x) for x in parts]
            m = RESILIENCE_PATTERNS[3].search(line)
            if m:
                result['test3_ms'] = float(m.group('time'))
            if RESILIENCE_PATTERNS[4].search(line):
                result['test4'] = True
    return result


def parse_bully_log(log_path):
    """
    Scan the log for bully election output blocks (normal / 1-fail / 2-fail).
    Returns list of dicts:
      [{'scenario': str, 'ranks': [{'rank':int,'coord':int,'latency_ms':float,'rounds':int}]}]
    """
    scenarios = []
    current_label = None
    current_ranks = []

    with open(log_path, "r", errors="replace") as f:
        for line in f:
            line = line.rstrip()
            # Detect scenario label lines written by the shell script
            if "[Bully] Normal election" in line:
                if current_label:
                    scenarios.append({'scenario': current_label, 'ranks': current_ranks})
                current_label = "Normal"
                current_ranks = []
            elif "[Bully] Election with rank" in line:
                if current_label:
                    scenarios.append({'scenario': current_label, 'ranks': current_ranks})
                # Extract failed rank count from the label
                m = re.search(r"ranks? ([\d,]+) failed", line)
                label = f"Fail {m.group(1)}" if m else "Fail"
                current_label = label
                current_ranks = []
            elif "BULLY_ELECTION_END" in line:
                if current_label:
                    scenarios.append({'scenario': current_label, 'ranks': current_ranks})
                current_label = None
                current_ranks = []

            m = BULLY_RESULT_RE.search(line)
            if m and current_label is not None:
                current_ranks.append({
                    'rank':      int(m.group('rank')),
                    'coord':     int(m.group('coord')),
                    'latency_ms': float(m.group('latency')),
                    'rounds':    int(m.group('rounds')),
                })

    if current_label and current_ranks:
        scenarios.append({'scenario': current_label, 'ranks': current_ranks})

    return scenarios


# ── Resilience charts ─────────────────────────────────────────────────────────

def plot_resilience(res, resilience_dir, outdir):
    """
    Two charts:
      1. resilience_recovery_times.png  — bar chart of T1/T2/T3 recovery times
      2. resilience_test_images.png     — side-by-side of output PNGs saved by
                                          resilience_test (if Pillow available)
    """
    # ── Recovery time bar chart ───────────────────────────────────────────────
    labels, values, colors_bar = [], [], []
    color_map = {"Test 1\nWorker Crash": "#E53935",
                 "Test 2\nSlow Node":    "#FB8C00",
                 "Test 3\nCoord\nRecovery": "#8E24AA"}

    if res['test1_ms'] is not None:
        labels.append("Test 1\nWorker Crash")
        values.append(res['test1_ms'])
        colors_bar.append("#E53935")
    if res['test2_ms'] is not None:
        labels.append("Test 2\nSlow Node")
        values.append(res['test2_ms'])
        colors_bar.append("#FB8C00")
    if res['test3_ms'] is not None:
        labels.append("Test 3\nCoord\nRecovery")
        values.append(res['test3_ms'])
        colors_bar.append("#8E24AA")

    note = "Test 4 (Partial Result): assembled ✓" if res['test4'] else ""

    if values:
        fig, axes = plt.subplots(1, 2 if res['test2_perrank'] else 1,
                                 figsize=(12 if res['test2_perrank'] else 7, 4))
        if not res['test2_perrank']:
            axes = [axes]

        ax_bar = axes[0]
        bars = ax_bar.bar(labels, values, color=colors_bar, edgecolor="black", alpha=0.85)
        ax_bar.set_title(f"Resilience — Recovery / Detection Times (ms)\n{note}",
                         fontweight="bold")
        ax_bar.set_ylabel("Time (ms)")
        for bar, v in zip(bars, values):
            ax_bar.text(bar.get_x() + bar.get_width() / 2,
                        bar.get_height() + max(values) * 0.02,
                        f"{v:.1f} ms", ha="center", va="bottom", fontsize=9)
        ax_bar.grid(True, axis="y", alpha=0.3)

        if res['test2_perrank']:
            ax_rk = axes[1]
            ranks = list(range(len(res['test2_perrank'])))
            ax_rk.bar(ranks, res['test2_perrank'], color="#FB8C00", alpha=0.8, edgecolor="black")
            ax_rk.set_title("Test 2 — Per-Rank Execution Time (ms)")
            ax_rk.set_xlabel("Rank")
            ax_rk.set_ylabel("Time (ms)")
            ax_rk.set_xticks(ranks)
            ax_rk.set_xticklabels([f"rank{r}" for r in ranks], fontsize=8)
            ax_rk.grid(True, axis="y", alpha=0.3)

        plt.tight_layout()
        path = os.path.join(outdir, "resilience_recovery_times.png")
        plt.savefig(path, dpi=120)
        plt.close(fig)
        print(f"  Saved: {path}")
    else:
        print("  [WARN] No numeric resilience times found in log")

    # ── Side-by-side resilience output images ────────────────────────────────
    if not HAS_PIL:
        return
    if not os.path.isdir(resilience_dir):
        print(f"  [WARN] Resilience image dir not found: {resilience_dir}")
        return

    slots = [
        ("resilience_test1_crash.png",          "T1: Worker Crash"),
        ("resilience_test2_slow.png",            "T2: Slow Node"),
        ("resilience_test3_coord_recovery.png",  "T3: Coord Recovery"),
        ("resilience_test4_partial.png",         "T4: Partial Result"),
    ]
    valid = [(os.path.join(resilience_dir, fn), lbl)
             for fn, lbl in slots
             if os.path.exists(os.path.join(resilience_dir, fn))]
    if not valid:
        print("  [WARN] No resilience output PNGs found")
        return

    fig, axes = plt.subplots(1, len(valid), figsize=(4 * len(valid), 4))
    if len(valid) == 1:
        axes = [axes]
    fig.suptitle("Resilience Test — Output Images", fontsize=11, fontweight="bold")
    for ax, (fpath, lbl) in zip(axes, valid):
        try:
            img = PILImage.open(fpath).convert("L")
            ax.imshow(np.array(img), cmap="gray")
        except Exception as e:
            ax.text(0.5, 0.5, str(e), ha="center", va="center",
                    transform=ax.transAxes, fontsize=7)
        ax.set_title(lbl, fontsize=9)
        ax.axis("off")
    plt.tight_layout()
    path = os.path.join(outdir, "resilience_test_images.png")
    plt.savefig(path, dpi=100)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── Bully election charts ─────────────────────────────────────────────────────

def plot_bully_election(scenarios, outdir):
    """
    Two charts:
      bully_election_latency.png  — mean election latency per scenario
      bully_election_rounds.png   — mean election rounds per scenario
    """
    if not scenarios:
        print("  [WARN] No bully election data found in log")
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

    fig, axes = plt.subplots(1, 2, figsize=(12, 4))
    fig.suptitle("Bully Election Algorithm — Performance", fontsize=12, fontweight="bold")

    # Latency
    ax = axes[0]
    bars = ax.bar(scene_labels, latencies, yerr=lat_stds, capsize=5,
                  color=bar_colors, edgecolor="black", alpha=0.85)
    ax.set_title("Mean Election Latency per Scenario")
    ax.set_ylabel("Latency (ms)")
    ax.set_xlabel("Scenario")
    for bar, v in zip(bars, latencies):
        ax.text(bar.get_x() + bar.get_width() / 2,
                bar.get_height() + max(latencies) * 0.02,
                f"{v:.1f} ms", ha="center", va="bottom", fontsize=9)
    ax.grid(True, axis="y", alpha=0.3)

    # Rounds
    ax = axes[1]
    bars = ax.bar(scene_labels, rounds, yerr=rnd_stds, capsize=5,
                  color=bar_colors, edgecolor="black", alpha=0.85)
    ax.set_title("Mean Election Rounds per Scenario")
    ax.set_ylabel("Rounds")
    ax.set_xlabel("Scenario")
    for bar, v in zip(bars, rounds):
        ax.text(bar.get_x() + bar.get_width() / 2,
                bar.get_height() + max(rounds + [0.1]) * 0.02,
                f"{v:.1f}", ha="center", va="bottom", fontsize=9)
    ax.grid(True, axis="y", alpha=0.3)

    plt.tight_layout()
    path = os.path.join(outdir, "bully_election_latency.png")
    plt.savefig(path, dpi=120)
    plt.close(fig)
    print(f"  Saved: {path}")

    # Per-rank latency breakdown (one grouped bar per scenario)
    fig, ax = plt.subplots(figsize=(max(8, 2 * len(scenarios) * 3), 4))
    x_base = 0
    tick_positions, tick_labels = [], []
    for i, s in enumerate(scenarios):
        if not s['ranks']:
            continue
        rk_list = sorted(s['ranks'], key=lambda r: r['rank'])
        x_pos = np.arange(len(rk_list)) + x_base
        lats  = [r['latency_ms'] for r in rk_list]
        ax.bar(x_pos, lats, color=bar_colors[i % len(bar_colors)],
               edgecolor="black", alpha=0.8, label=s['scenario'])
        tick_positions.extend(x_pos.tolist())
        tick_labels.extend([f"r{r['rank']}" for r in rk_list])
        x_base += len(rk_list) + 1

    ax.set_xticks(tick_positions)
    ax.set_xticklabels(tick_labels, fontsize=8)
    ax.set_title("Bully Election — Per-Rank Latency Breakdown")
    ax.set_ylabel("Latency (ms)")
    ax.legend(fontsize=9)
    ax.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()
    path = os.path.join(outdir, "bully_election_rounds.png")
    plt.savefig(path, dpi=120)
    plt.close(fig)
    print(f"  Saved: {path}")


# ── CSV summary ────────────────────────────────────────────────────────────────

def write_summary_csv(data, outdir):
    rows = []
    for img, img_data in data.items():
        for flt, t in img_data.get("baseline", {}).items():
            rows.append({"image": img, "filter": flt, "arch": "serial",
                         "parallelism_type": "-", "p": 1, "time_s": f"{t:.6f}"})
        for flt in FILTERS:
            for arch in ARCHS:
                for p, t in img_data.get(flt, {}).get(arch, []):
                    rows.append({"image": img, "filter": flt, "arch": arch,
                                 "parallelism_type": ARCH_PARALLELISM[arch],
                                 "p": p, "time_s": f"{t:.6f}"})
    if not rows:
        print("  [WARN] No timing data for CSV")
        return
    path = os.path.join(outdir, "summary_table.csv")
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["image", "filter", "arch",
                                                "parallelism_type", "p", "time_s"])
        writer.writeheader()
        writer.writerows(rows)
    print(f"  Saved: {path}")


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="BSDS500 Analysis Report Generator")
    parser.add_argument("--log",            default="report_bsds/analysis_bsds.log")
    parser.add_argument("--outdir",         default="report_bsds")
    parser.add_argument("--recon-dir",      default="report_bsds/reconstructed")
    parser.add_argument("--resilience-dir",  default="report_bsds/resilience")
    parser.add_argument("--gt-dir",         default="")
    parser.add_argument("--node-counts",    default="2 4 6")
    parser.add_argument("--thread-counts",  default="1 2 4")
    args = parser.parse_args()

    node_counts   = [int(x) for x in args.node_counts.split()]
    thread_counts = [int(x) for x in args.thread_counts.split()]

    if not os.path.exists(args.log):
        print(f"[ERROR] Log file not found: {args.log}")
        print("Run ./run_analysis_bsds.sh first.")
        sys.exit(1)

    os.makedirs(args.outdir, exist_ok=True)

    print(f"\nParsing {args.log} …")
    data = parse_log(args.log, node_counts, thread_counts)

    if not data:
        print("[ERROR] No IMAGE: blocks found in log — nothing to plot.")
        sys.exit(1)

    print(f"Found {len(data)} image(s): {list(data.keys())[:5]}{'...' if len(data)>5 else ''}\n")

    # ── Per-image speedup / efficiency / Brent's Law ──────────────────────────
    print("── Per-image performance charts ──")
    for img_name, img_data in data.items():
        for flt in FILTERS:
            baseline = img_data["baseline"].get(flt)
            if baseline is None:
                all_times = [t for a in ARCHS
                             for _, t in img_data.get(flt, {}).get(a, [])]
                baseline = max(all_times) if all_times else 1.0
            plot_filter_perf(img_name, flt, img_data.get(flt, {}),
                             baseline, args.outdir)

    # ── Per-arch 3-panel charts (Speedup | Efficiency | Brent's Law) ─────────
    print("\n── Per-arch panels (aggregated over BSDS500 images) ──")
    for flt in FILTERS:
        plot_per_arch_panels(data, flt, args.outdir)

    # ── SIO Efficiency (per filter, aggregated) ───────────────────────────────
    print("\n── SIO Efficiency charts ──")
    for flt in FILTERS:
        plot_sio_efficiency(data, flt, args.outdir)

    # ── Amdahl comparison ─────────────────────────────────────────────────────
    print("\n── Amdahl parallel-fraction comparison ──")
    try:
        plot_amdahl_comparison(data, args.outdir)
    except Exception as e:
        print(f"  [WARN] Amdahl plot failed: {e} (install scipy for curve fitting)")

    # ── Brent's Law aggregate ─────────────────────────────────────────────────
    print("\n── Brent's Law (T_p vs 1/p) ──")
    plot_brents_law_all(data, args.outdir, node_counts)

    # ── Serial baseline comparison ────────────────────────────────────────────
    print("\n── Serial baseline comparison ──")
    plot_baseline_comparison(data, args.outdir)

    # ── Arch mean time ────────────────────────────────────────────────────────
    print("\n── Arch mean time ──")
    plot_arch_mean_time(data, args.outdir)

    # ── Quality metrics (Jaccard / Dice / SSIM) ───────────────────────────────
    print("\n── Quality metrics (Jaccard / Dice / SSIM vs BSDS500 GT) ──")
    gt_dir = args.gt_dir if args.gt_dir else None
    evaluate_quality_metrics(args.recon_dir, gt_dir, args.outdir)

    # ── Reconstructed image comparison ───────────────────────────────────────
    print("\n── Reconstructed image comparison ──")
    plot_recon_comparison(args.recon_dir, args.outdir)
    plot_recon_montage(args.recon_dir, args.outdir)

    # ── Resilience tests ──────────────────────────────────────────────────────
    print("\n── Resilience tests ──")
    res = parse_resilience_log(args.log)
    plot_resilience(res, args.resilience_dir, args.outdir)

    # ── Bully election ────────────────────────────────────────────────────────
    print("\n── Bully election ──")
    bully_scenarios = parse_bully_log(args.log)
    plot_bully_election(bully_scenarios, args.outdir)

    # ── CSV summary ───────────────────────────────────────────────────────────
    print("\n── Summary CSV ──")
    write_summary_csv(data, args.outdir)

    print(f"\nReport complete → {args.outdir}/")
    charts = sorted(f for f in os.listdir(args.outdir) if f.endswith(".png"))
    print(f"Charts generated: {len(charts)}")
    for c in charts:
        print(f"  {args.outdir}/{c}")


if __name__ == "__main__":
    main()