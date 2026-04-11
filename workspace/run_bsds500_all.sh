#!/bin/bash
# run_bsds500_all.sh
# ============================================================================
# Full evaluation script: runs ALL architectures (FFT, Sobel, Canny, LoG)
# on the BSD500 test set, collects timing CSVs, generates performance plots,
# and reconstructs representative output images for visual inspection.
#
# Prerequisites:
#   - BSD500 dataset under $BSDS_ROOT (see download instructions below)
#   - All arch binaries compiled: make vision   (from workspace/)
#   - Python 3 with: pip install matplotlib numpy scipy pandas pillow kagglehub
#   - MPI cluster accessible via $HOSTFILE
#
# Usage:
#   bash run_bsds500_all.sh [--n-images N] [--threads T1,T2,...] [--nodes N1,N2,...]
#
# Download BSD500 (if not already present):
#   python3 -c "import kagglehub; p=kagglehub.dataset_download('balraj98/berkeley-segmentation-dataset-500-bsds500'); print(p)"
# ============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
BSDS_ROOT="${BSDS_ROOT:-./vision/datasets/BSDS500}"
IMAGES_DIR="$BSDS_ROOT/data/images/test"
BUILD_DIR="./build"
RESULTS_DIR="./results/bsds500"
PLOTS_DIR="$RESULTS_DIR/plots"
RECON_DIR="$RESULTS_DIR/reconstructed"
CSV="$RESULTS_DIR/benchmark_results.csv"
HOSTFILE="${HOSTFILE:-./hostfile}"

# Parse optional CLI overrides
N_IMAGES=10
THREAD_COUNTS=(1 2 4)
NODE_COUNTS=(2 4 6)
CHUNK_ROWS=32
STREAMING_BATCH=16

while [[ $# -gt 0 ]]; do
    case "$1" in
        --n-images)  N_IMAGES="$2";         shift 2;;
        --threads)   IFS=',' read -ra THREAD_COUNTS <<< "$2"; shift 2;;
        --nodes)     IFS=',' read -ra NODE_COUNTS   <<< "$2"; shift 2;;
        --chunk)     CHUNK_ROWS="$2";        shift 2;;
        --batch)     STREAMING_BATCH="$2";   shift 2;;
        *) echo "Unknown option: $1"; exit 1;;
    esac
done

# ── Validate environment ───────────────────────────────────────────────────────
check_bin() { [ -f "$BUILD_DIR/$1" ] || { echo "ERROR: $BUILD_DIR/$1 not found. Run 'make vision' first."; exit 1; }; }
for b in sobel_arch1 sobel_arch2 sobel_arch3 sobel_arch4 \
          log_arch1   log_arch2   log_arch3   log_arch4 \
          canny_arch1 canny_arch2 canny_arch3 canny_arch4 \
          fft_arch1   fft_arch2   fft_arch3   fft_arch4; do
    check_bin "$b"
done

if [ ! -d "$IMAGES_DIR" ]; then
    echo "BSD500 images not found at $IMAGES_DIR"
    echo "Download with: python3 -c \"import kagglehub; kagglehub.dataset_download('balraj98/berkeley-segmentation-dataset-500-bsds500')\""
    exit 1
fi

mkdir -p "$RESULTS_DIR" "$PLOTS_DIR" "$RECON_DIR"
mkdir -p "$RECON_DIR"/{sobel,log,canny,fft}

# ── Collect test images ────────────────────────────────────────────────────────
mapfile -t ALL_IMAGES < <(find "$IMAGES_DIR" -name "*.jpg" | sort)
IMAGES=("${ALL_IMAGES[@]:0:$N_IMAGES}")
echo "Using ${#IMAGES[@]} BSD500 test images"

# Write image list for streaming/arch4 tests
IMG_LIST="$RESULTS_DIR/img_list.txt"
printf "%s\n" "${IMAGES[@]}" > "$IMG_LIST"

# ── Helper: extract time from binary stdout ────────────────────────────────────
extract_time() {
    # Accepts lines like: [Sobel Farm] threads=4  time=0.01234 s
    # or:                  FFT Arch1 (Farm) Time: 0.01234 s using 4 threads.
    grep -oP '(?<=time=|Time: )\d+\.\d+' <<< "$1" | head -1
}

# ── CSV header ────────────────────────────────────────────────────────────────
echo "filter,arch,param_name,param_value,image,time_s" > "$CSV"

# ── MPI run helper (falls back to localhost if no hostfile) ───────────────────
mpi_run() {
    local n="$1"; shift
    if [ -f "$HOSTFILE" ]; then
        mpirun -n "$n" --hostfile "$HOSTFILE" "$@"
    else
        mpirun -n "$n" "$@"
    fi
}

# ── Reconstruction helper (saves one output per filter per arch) ──────────────
RECON_IMAGE="${IMAGES[0]}"
RECON_BASE=$(basename "$RECON_IMAGE" .jpg)

reconstruct_all() {
    echo "--- Generating reconstructed images for $RECON_BASE ---"

    # Sobel
    "$BUILD_DIR/sobel_arch1" "$RECON_IMAGE" 4 "$RECON_DIR/sobel/sobel_arch1.png"
    "$BUILD_DIR/sobel_arch2" "$RECON_IMAGE" $CHUNK_ROWS "$RECON_DIR/sobel/sobel_arch2.png"
    mpi_run 4 "$BUILD_DIR/sobel_arch3" "$RECON_IMAGE" "$RECON_DIR/sobel/sobel_arch3.png"
    mpi_run 2 "$BUILD_DIR/sobel_arch4" "$RECON_IMAGE" "$RECON_DIR/sobel/sobel_arch4.png"

    # LoG
    "$BUILD_DIR/log_arch1" "$RECON_IMAGE" 4 "$RECON_DIR/log/log_arch1.png"
    "$BUILD_DIR/log_arch2" "$RECON_IMAGE" $CHUNK_ROWS "$RECON_DIR/log/log_arch2.png"
    mpi_run 4 "$BUILD_DIR/log_arch3" "$RECON_IMAGE" "$RECON_DIR/log/log_arch3.png"
    mpi_run 2 "$BUILD_DIR/log_arch4" "$RECON_IMAGE" "$RECON_DIR/log/log_arch4.png"

    # Canny
    "$BUILD_DIR/canny_arch1" "$RECON_IMAGE" 4 "$RECON_DIR/canny/canny_arch1.png"
    "$BUILD_DIR/canny_arch2" "$RECON_IMAGE" $CHUNK_ROWS "$RECON_DIR/canny/canny_arch2.png"
    mpi_run 4 "$BUILD_DIR/canny_arch3" "$RECON_IMAGE" "$RECON_DIR/canny/canny_arch3.png"
    # Canny arch4 needs image list + output dir
    echo "$RECON_IMAGE" > /tmp/_recon_list.txt
    mpi_run 4 "$BUILD_DIR/canny_arch4" /tmp/_recon_list.txt "$RECON_DIR/canny" 1

    # FFT (outputs to fixed filenames in cwd — move afterwards)
    pushd "$RECON_DIR/fft" > /dev/null
    "$BUILD_DIR/fft_arch1" "$RECON_IMAGE" 4
    mv -f fft_arch1_out.png fft_arch1.png 2>/dev/null || true
    "$BUILD_DIR/fft_arch2" "$RECON_IMAGE"
    mv -f fft_arch2_out.png fft_arch2.png 2>/dev/null || true
    mpi_run 4 "$BUILD_DIR/fft_arch3" "$RECON_IMAGE"
    mv -f fft_arch3_out.png fft_arch3.png 2>/dev/null || true
    mpi_run 2 "$BUILD_DIR/fft_arch4" "$RECON_IMAGE"
    mv -f fft_arch4_out.png fft_arch4.png 2>/dev/null || true
    popd > /dev/null

    echo "--- Reconstruction done → $RECON_DIR ---"
}

# ── Benchmark loop ─────────────────────────────────────────────────────────────
echo "Starting benchmark..."

for IMG in "${IMAGES[@]}"; do
    BASE=$(basename "$IMG")
    echo "  Image: $BASE"

    # ── Architecture 1 (OpenMP Farm) — vary threads ────────────────────────
    for T in "${THREAD_COUNTS[@]}"; do
        for FILTER in sobel log canny fft; do
            OUT=/tmp/_out_${FILTER}_arch1_t${T}.png
            RAW=$("$BUILD_DIR/${FILTER}_arch1" "$IMG" "$T" "$OUT" 2>&1 || true)
            TIME=$(extract_time "$RAW")
            [ -z "$TIME" ] && TIME="NA"
            echo "$FILTER,arch1,threads,$T,$BASE,$TIME" >> "$CSV"
        done
    done

    # ── Architecture 2 (OpenMP Pipeline) — vary chunk_rows ────────────────
    for CR in 16 32 64; do
        for FILTER in sobel log canny fft; do
            OUT=/tmp/_out_${FILTER}_arch2_cr${CR}.png
            RAW=$("$BUILD_DIR/${FILTER}_arch2" "$IMG" "$CR" "$OUT" 2>&1 || true)
            TIME=$(extract_time "$RAW")
            [ -z "$TIME" ] && TIME="NA"
            echo "$FILTER,arch2,chunk_rows,$CR,$BASE,$TIME" >> "$CSV"
        done
    done

    # ── Architecture 3 (MPI Scatter-Gather) — vary node count ─────────────
    for N in "${NODE_COUNTS[@]}"; do
        for FILTER in sobel log canny fft; do
            OUT=/tmp/_out_${FILTER}_arch3_n${N}.png
            RAW=$(mpi_run "$N" "$BUILD_DIR/${FILTER}_arch3" "$IMG" "$OUT" 2>&1 || true)
            TIME=$(extract_time "$RAW")
            [ -z "$TIME" ] && TIME="NA"
            echo "$FILTER,arch3,nodes,$N,$BASE,$TIME" >> "$CSV"
        done
    done
done

# ── Architecture 4 (MPI Pipeline, streaming) — vary batch size ────────────────
for NB in 1 4 8 $STREAMING_BATCH; do
    # Build sub-list of NB images
    SUB_LIST="$RESULTS_DIR/img_list_n${NB}.txt"
    head -"$NB" "$IMG_LIST" > "$SUB_LIST" || cp "$IMG_LIST" "$SUB_LIST"

    for FILTER in sobel log canny fft; do
        OUT_SUBDIR="$RESULTS_DIR/arch4_${FILTER}_n${NB}"
        mkdir -p "$OUT_SUBDIR"
        RAW=$(mpi_run 4 "$BUILD_DIR/${FILTER}_arch4" "$SUB_LIST" "$OUT_SUBDIR" "$NB" 2>&1 || true)
        TIME=$(extract_time "$RAW")
        [ -z "$TIME" ] && TIME="NA"
        echo "$FILTER,arch4,batch_size,$NB,batch_N${NB},$TIME" >> "$CSV"
    done
done

# ── Resilience tests (Test 2 — slow node, safe) ───────────────────────────────
echo "Running resilience tests (safe: slow-node only)..."
RTEST_DIR="$RESULTS_DIR/resilience"
mkdir -p "$RTEST_DIR"
mpi_run 4 "$BUILD_DIR/resilience_test" "${IMAGES[0]}" "$RTEST_DIR" --test 2 \
    2>&1 | tee "$RTEST_DIR/slow_node.log" || true

# ── Bully election test ───────────────────────────────────────────────────────
echo "Running bully election test..."
mpi_run 6 "$BUILD_DIR/bully_election" --timeout 500 \
    2>&1 | tee "$RESULTS_DIR/bully_election.log" || true

# Simulated failure (kill highest 2 ranks)
echo "Running bully election with simulated failures (ranks 4,5)..."
mpi_run 6 "$BUILD_DIR/bully_election" --fail 4,5 --timeout 500 \
    2>&1 | tee "$RESULTS_DIR/bully_election_failure.log" || true

# ── Reconstruct representative images ─────────────────────────────────────────
reconstruct_all

# ── Generate plots ─────────────────────────────────────────────────────────────
echo "Generating plots..."
python3 - << 'PYEOF'
import pandas as pd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
import os, sys

CSV      = os.environ.get('CSV', './results/bsds500/benchmark_results.csv')
PLOTS    = os.environ.get('PLOTS_DIR', './results/bsds500/plots')
RECON    = os.environ.get('RECON_DIR', './results/bsds500/reconstructed')
os.makedirs(PLOTS, exist_ok=True)

try:
    df = pd.read_csv(CSV)
except Exception as e:
    print(f"Warning: could not read CSV: {e}")
    sys.exit(0)

df['time_s'] = pd.to_numeric(df['time_s'], errors='coerce')
df = df.dropna(subset=['time_s'])

FILTERS = df['filter'].unique().tolist()
ARCHS   = ['arch1', 'arch2', 'arch3', 'arch4']
COLORS  = {'sobel': '#2196F3', 'canny': '#F44336', 'log': '#4CAF50', 'fft': '#FF9800'}

# ── Plot 1: Speedup vs Threads (Arch 1) ──────────────────────────────────────
fig, axes = plt.subplots(1, len(FILTERS), figsize=(5*len(FILTERS), 4), sharey=False)
if len(FILTERS) == 1: axes = [axes]
for ax, filt in zip(axes, FILTERS):
    sub = df[(df['filter']==filt) & (df['arch']=='arch1') & (df['param_name']=='threads')]
    if sub.empty: continue
    agg = sub.groupby('param_value')['time_s'].mean().reset_index()
    agg = agg.sort_values('param_value')
    t1 = agg[agg['param_value']==1]['time_s'].values
    if len(t1) == 0: continue
    agg['speedup'] = t1[0] / agg['time_s']
    ax.plot(agg['param_value'], agg['speedup'], 'o-', color=COLORS.get(filt,'grey'), lw=2)
    ax.plot([1, agg['param_value'].max()], [1, agg['param_value'].max()],
            'k--', alpha=0.3, label='Ideal')
    ax.set_title(f'{filt.upper()} Arch1 Speedup')
    ax.set_xlabel('Threads')
    ax.set_ylabel('Speedup')
    ax.legend()
    ax.grid(True, alpha=0.3)
plt.suptitle('OpenMP Farm (Arch1): Speedup vs Thread Count (BSD500)', fontsize=12)
plt.tight_layout()
plt.savefig(f'{PLOTS}/arch1_speedup_threads.png', dpi=150, bbox_inches='tight')
plt.close()

# ── Plot 2: Speedup vs MPI Nodes (Arch 3) ─────────────────────────────────────
fig, axes = plt.subplots(1, len(FILTERS), figsize=(5*len(FILTERS), 4), sharey=False)
if len(FILTERS) == 1: axes = [axes]
for ax, filt in zip(axes, FILTERS):
    sub = df[(df['filter']==filt) & (df['arch']=='arch3') & (df['param_name']=='nodes')]
    if sub.empty: continue
    agg = sub.groupby('param_value')['time_s'].mean().reset_index()
    agg = agg.sort_values('param_value')
    t1 = agg[agg['param_value']==agg['param_value'].min()]['time_s'].values
    if len(t1) == 0: continue
    agg['speedup'] = t1[0] / agg['time_s']
    ax.plot(agg['param_value'], agg['speedup'], 's-', color=COLORS.get(filt,'grey'), lw=2)
    ax.plot([agg['param_value'].min(), agg['param_value'].max()],
            [1, agg['param_value'].max()/agg['param_value'].min()], 'k--', alpha=0.3, label='Ideal')
    ax.set_title(f'{filt.upper()} Arch3 Speedup')
    ax.set_xlabel('MPI Nodes')
    ax.set_ylabel('Speedup')
    ax.legend()
    ax.grid(True, alpha=0.3)
plt.suptitle('MPI Scatter-Gather (Arch3): Speedup vs Node Count (BSD500)', fontsize=12)
plt.tight_layout()
plt.savefig(f'{PLOTS}/arch3_speedup_nodes.png', dpi=150, bbox_inches='tight')
plt.close()

# ── Plot 3: Architecture comparison bar chart (mean time, best config) ────────
fig, axes = plt.subplots(1, len(FILTERS), figsize=(5*len(FILTERS), 4))
if len(FILTERS) == 1: axes = [axes]
for ax, filt in zip(axes, FILTERS):
    means = []
    labels = []
    for arch in ARCHS:
        sub = df[(df['filter']==filt) & (df['arch']==arch)]
        if sub.empty: continue
        means.append(sub['time_s'].mean())
        labels.append(arch.upper())
    bars = ax.bar(labels, means, color=[COLORS.get(filt,'grey')]*len(labels), alpha=0.8, edgecolor='black')
    ax.set_title(f'{filt.upper()} Mean Time')
    ax.set_ylabel('Time (s)')
    ax.set_xlabel('Architecture')
    for bar, val in zip(bars, means):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height(),
                f'{val:.4f}', ha='center', va='bottom', fontsize=8)
    ax.grid(True, alpha=0.3, axis='y')
plt.suptitle('Mean Execution Time per Architecture (BSD500)', fontsize=12)
plt.tight_layout()
plt.savefig(f'{PLOTS}/arch_comparison_mean_time.png', dpi=150, bbox_inches='tight')
plt.close()

# ── Plot 4: Arch4 Streaming Throughput (batch size vs img/s) ─────────────────
fig, ax = plt.subplots(figsize=(8, 4))
for filt in FILTERS:
    sub = df[(df['filter']==filt) & (df['arch']=='arch4') & (df['param_name']=='batch_size')]
    if sub.empty: continue
    agg = sub.groupby('param_value')['time_s'].mean().reset_index()
    agg = agg.sort_values('param_value')
    agg['throughput'] = agg['param_value'].astype(float) / agg['time_s']
    ax.plot(agg['param_value'], agg['throughput'], 'o-',
            color=COLORS.get(filt,'grey'), label=filt.upper(), lw=2)
ax.set_xlabel('Batch Size (N images)')
ax.set_ylabel('Throughput (images/s)')
ax.set_title('Arch4 MPI Pipeline: Streaming Throughput vs Batch Size')
ax.legend()
ax.grid(True, alpha=0.3)
plt.tight_layout()
plt.savefig(f'{PLOTS}/arch4_streaming_throughput.png', dpi=150, bbox_inches='tight')
plt.close()

# ── Plot 5: Brent's Theorem — T_P vs 1/P (Arch3 only) ───────────────────────
fig, axes = plt.subplots(1, len(FILTERS), figsize=(5*len(FILTERS), 4))
if len(FILTERS) == 1: axes = [axes]
for ax, filt in zip(axes, FILTERS):
    sub = df[(df['filter']==filt) & (df['arch']=='arch3') & (df['param_name']=='nodes')]
    if sub.empty: continue
    agg = sub.groupby('param_value')['time_s'].mean().reset_index()
    agg = agg.sort_values('param_value')
    agg['inv_p'] = 1.0 / agg['param_value']
    ax.plot(agg['inv_p'], agg['time_s'], 'o-', color=COLORS.get(filt,'grey'), lw=2)
    # Fit linear regression (Brent: T_P = (W - T_inf)/P + T_inf)
    if len(agg) >= 2:
        coef = np.polyfit(agg['inv_p'], agg['time_s'], 1)
        x_fit = np.linspace(0, agg['inv_p'].max(), 50)
        ax.plot(x_fit, np.polyval(coef, x_fit), 'r--', alpha=0.6,
                label=f'Fit: T∞≈{coef[1]:.4f}s')
        ax.legend(fontsize=8)
    ax.set_title(f'{filt.upper()} Brent Validation')
    ax.set_xlabel('1/P (1/nodes)')
    ax.set_ylabel('T_P (s)')
    ax.grid(True, alpha=0.3)
plt.suptitle("Brent's Theorem: T_P vs 1/P — Arch3 MPI Scatter-Gather", fontsize=12)
plt.tight_layout()
plt.savefig(f'{PLOTS}/brents_theorem_arch3.png', dpi=150, bbox_inches='tight')
plt.close()

# ── Plot 6: Reconstructed image comparison montage ────────────────────────────
try:
    from PIL import Image
    for filt in ['sobel', 'log', 'canny', 'fft']:
        filt_dir = os.path.join(RECON, filt)
        imgs = sorted([f for f in os.listdir(filt_dir) if f.endswith('.png')])
        if not imgs: continue
        pils = []
        for fn in imgs:
            try: pils.append(Image.open(os.path.join(filt_dir, fn)).convert('L'))
            except: pass
        if not pils: continue
        # Resize all to same height
        H = 200
        resized = [p.resize((int(p.width * H / p.height), H)) for p in pils]
        total_w = sum(r.width for r in resized) + 10*(len(resized)-1)
        montage = Image.new('L', (total_w, H + 25), color=200)
        x_off = 0
        for i, (r, fn) in enumerate(zip(resized, imgs)):
            montage.paste(r, (x_off, 25))
            x_off += r.width + 10
        from PIL import ImageDraw
        draw = ImageDraw.Draw(montage)
        x_off = 0
        for r, fn in zip(resized, imgs):
            draw.text((x_off + 2, 2), fn.replace('.png',''), fill=0)
            x_off += r.width + 10
        montage.save(f'{PLOTS}/{filt}_arch_montage.png')
        print(f"Saved {filt} montage")
except ImportError:
    print("Pillow not installed — skipping montage generation")

print(f"\nPlots saved to: {PLOTS}/")
print(f"  arch1_speedup_threads.png")
print(f"  arch3_speedup_nodes.png")
print(f"  arch_comparison_mean_time.png")
print(f"  arch4_streaming_throughput.png")
print(f"  brents_theorem_arch3.png")
print(f"  <filter>_arch_montage.png  (x4 filters)")
PYEOF

echo ""
echo "============================================================"
echo "  BSD500 Full Evaluation Complete"
echo "  Results:       $RESULTS_DIR"
echo "  CSV:           $CSV"
echo "  Plots:         $PLOTS_DIR"
echo "  Reconstructed: $RECON_DIR"
echo "============================================================"
