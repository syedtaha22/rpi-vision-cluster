#!/bin/bash
# =============================================================================
#  run_analysis.sh — Full automated analysis for RPI Vision Cluster (Milestone 2)
#
#  Usage:
#    ./run_analysis.sh                          # full run, defaults
#    ./run_analysis.sh --quick                  # 1 image, fewer configs
#    ./run_analysis.sh --skip-build             # skip recompiling binaries
#    ./run_analysis.sh --nodes 2,4 --threads 1,4
#    ./run_analysis.sh --image /path/to/img.png
# =============================================================================

set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
NODE_COUNTS=(2 4 6)
THREAD_COUNTS=(1 2 4)
SKIP_BUILD=0
QUICK=0
CUSTOM_IMAGE=""

# Default per-dataset images (inside the container)
CIFAR_IMG="/home/pi/workspace/vision/datasets/cifar-10/tabby_s_000074.png"
TINY_IMG="/home/pi/workspace/vision/datasets/tiny-imagenet-200/test/images/test_0.JPEG"
COCO_IMG="/home/pi/workspace/vision/datasets/coco-val2017/000000144003.jpg"
BSDS_DIR="/home/pi/workspace/vision/datasets/BSDS500/data/images/test"
BSDS_N=10          # number of BSD500 images to use in arch4 batch tests

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)       IFS=',' read -ra NODE_COUNTS   <<< "$2"; shift 2 ;;
        --threads)     IFS=',' read -ra THREAD_COUNTS <<< "$2"; shift 2 ;;
        --image)       CUSTOM_IMAGE="$2";              shift 2 ;;
        --skip-build)  SKIP_BUILD=1;                   shift   ;;
        --quick)       QUICK=1;                        shift   ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ $QUICK -eq 1 ]]; then
    NODE_COUNTS=(2 4)
    THREAD_COUNTS=(1 2)
    BSDS_N=3
fi

# Single-image mode overrides the IMAGES list
if [[ -n "$CUSTOM_IMAGE" ]]; then
    IMAGES=("$CUSTOM_IMAGE")
else
    IMAGES=("$CIFAR_IMG" "$TINY_IMG" "$COCO_IMG")
fi

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/analysis_results.log"
REPORT_DIR="$SCRIPT_DIR/report"
WS="$SCRIPT_DIR/workspace"     # host-side workspace (mounted into containers)
BUILD="build"                   # relative to /home/pi/workspace/ inside container

# ── Logging ───────────────────────────────────────────────────────────────────
mkdir -p "$REPORT_DIR"
: > "$LOG_FILE"

log()     { echo "$*" | tee -a "$LOG_FILE"; }
section() { log ""; log "================================================================="; log "  $*"; log "================================================================="; }
die()     { echo "[FATAL] $*" >&2; exit 1; }

log "RPI Vision Cluster — Full Performance Analysis"
log "Started: $(date)"
log "Nodes   : ${NODE_COUNTS[*]}"
log "Threads : ${THREAD_COUNTS[*]}"

# ── Step 0: Docker check ──────────────────────────────────────────────────────
section "STEP 0: Checking Docker"
command -v docker &>/dev/null || die "Docker not found on PATH"
docker compose version &>/dev/null || docker-compose --version &>/dev/null || die "Docker Compose not found"
log "Docker OK"

# ── Cluster helpers ───────────────────────────────────────────────────────────
MAX_NODES="${NODE_COUNTS[-1]}"

master_running() {
    docker ps --filter "name=rpic_master" --filter "status=running" \
               --format "{{.Names}}" 2>/dev/null | grep -q "rpic_master"
}

ensure_cluster() {
    local n="$MAX_NODES"
    if master_running; then
        local running
        running=$(docker ps --filter "name=rpic_" --filter "status=running" \
                             --format "{{.Names}}" 2>/dev/null | wc -l)
        if [[ $running -ge $n ]]; then
            log "  Cluster already running ($running containers)"; return 0
        fi
        log "  Only $running container(s) running, need $n — restarting..."
    else
        log "  Cluster not running — starting with $n nodes..."
    fi
    cd "$SCRIPT_DIR"
    docker compose --profile 2-nodes --profile 3-nodes --profile 4-nodes \
                   --profile 5-nodes --profile 6-nodes \
                   down --remove-orphans 2>&1 | tail -3 | tee -a "$LOG_FILE"
    docker compose --profile "${n}-nodes" up -d 2>&1 | tee -a "$LOG_FILE"
    log "  Waiting for rpic_master..."
    local retries=0
    until master_running || [[ $retries -ge 30 ]]; do sleep 2; retries=$((retries+1)); done
    master_running || die "rpic_master did not start after 60 s"
    sleep 3
    log "  Cluster ready ($n nodes)"
}

# Build hostlist string for N nodes
hostlist_for() {
    local n="$1" hosts=(master)
    for ((i=1; i<n; i++)); do hosts+=("worker$i"); done
    local IFS=','; echo "${hosts[*]}"
}

# ── Step 1: Start cluster ─────────────────────────────────────────────────────
section "STEP 1: Starting cluster (${MAX_NODES} nodes)"
cd "$SCRIPT_DIR"
ensure_cluster
log "Verifying MPI connectivity..."
docker exec -u pi rpic_master \
    mpirun --allow-run-as-root -n "$MAX_NODES" \
    --host "$(hostlist_for "$MAX_NODES")" hostname \
    2>&1 | tee -a "$LOG_FILE" \
    && log "Cluster verification: OK" \
    || log "[WARN] Cluster verification failed — continuing anyway"

# ── Step 2: Dataset check ─────────────────────────────────────────────────────
section "STEP 2: Checking datasets"

# Check each standard image; warn but continue if missing
check_img() {
    docker exec -u pi rpic_master test -f "$1" 2>/dev/null \
        && log "  OK  $1" \
        || log "  MISSING  $1  (runs using this image will be skipped)"
}
for img in "${IMAGES[@]}"; do check_img "$img"; done

# Check / download BSDS500
BSDS_OK=0
if docker exec -u pi rpic_master test -d "$BSDS_DIR" 2>/dev/null && \
   [[ $(docker exec -u pi rpic_master bash -c "ls '$BSDS_DIR'/*.jpg 2>/dev/null | wc -l") -gt 0 ]]; then
    log "  BSD500 found at $BSDS_DIR"
    BSDS_OK=1
else
    log "  BSD500 not found — attempting download via kagglehub..."
    docker exec -u pi rpic_master bash -c \
        "pip install -q kagglehub && \
         python3 -c \"
import kagglehub, shutil, os
p = kagglehub.dataset_download('balraj98/berkeley-segmentation-dataset-500-bsds500')
dst = '/home/pi/workspace/vision/datasets/BSDS500'
if not os.path.exists(dst):
    shutil.copytree(p, dst)
    print('BSD500 downloaded to', dst)
else:
    print('BSD500 already exists at', dst)
\"" 2>&1 | tee -a "$LOG_FILE" \
    && BSDS_OK=1 \
    || log "  [WARN] BSD500 download failed — arch4 batch tests will be skipped"
fi

# Build a BSDS image list file (written inside workspace so container can read it)
BSDS_LIST_HOST="$WS/results/bsds_img_list.txt"
BSDS_LIST_CONT="/home/pi/workspace/results/bsds_img_list.txt"
BSDS_OUT_CONT="/home/pi/workspace/results/bsds_out"
if [[ $BSDS_OK -eq 1 ]]; then
    mkdir -p "$WS/results"
    docker exec -u pi rpic_master bash -c \
        "find '$BSDS_DIR' -name '*.jpg' | sort | head -${BSDS_N}" \
        > "$BSDS_LIST_HOST"
    ACTUAL_N=$(wc -l < "$BSDS_LIST_HOST")
    log "  BSD500 image list: $ACTUAL_N images → $BSDS_LIST_HOST"
fi

# ── Compile helper ────────────────────────────────────────────────────────────
compile_binary() {
    local src_stem="$1" out_name="$2"
    log "  [COMPILE] $src_stem → $out_name"
    docker exec -u pi rpic_master bash -c \
        "cd /home/pi/workspace && \
         mkdir -p \$(dirname $out_name) && \
         mpic++ -std=c++17 -O2 -fopenmp ${src_stem}.cpp -o ${out_name} -lm" \
        2>&1 | tee -a "$LOG_FILE" \
    || log "  [WARN] Compile failed for $src_stem"
}

# ── Run helper ────────────────────────────────────────────────────────────────
# runc <nodes> <binary_rel_to_workspace> <arg1> [arg2 ...]
# All paths in args must be absolute container paths.
runc() {
    local nodes="$1" bin="$2"; shift 2
    local args="${*:-}"
    local hostlist
    hostlist="$(hostlist_for "$nodes")"
    log "  [RUN] $bin  nodes=$nodes  args=$args"
    docker exec -u pi rpic_master bash -c \
        "cd /home/pi/workspace && \
         mpirun --allow-run-as-root -n ${nodes} --host ${hostlist} \
         /home/pi/workspace/${bin} ${args}" \
        2>&1 | tee -a "$LOG_FILE" \
    || log "  [WARN] $bin exited non-zero (continuing)"
}

# ── Step 3: Build all binaries ────────────────────────────────────────────────
if [[ $SKIP_BUILD -eq 0 ]]; then
    section "STEP 3: Building all architecture binaries"
    compile_binary "vision/baselines"               "$BUILD/baselines"
    compile_binary "vision/sobel_arch1_farm"        "$BUILD/sobel_arch1"
    compile_binary "vision/sobel_arch2_pipeline"    "$BUILD/sobel_arch2"
    compile_binary "vision/sobel_arch3_scatter"     "$BUILD/sobel_arch3"
    compile_binary "vision/sobel_arch4_pipeline"    "$BUILD/sobel_arch4"
    compile_binary "vision/canny_arch1_farm"        "$BUILD/canny_arch1"
    compile_binary "vision/canny_arch2_pipeline"    "$BUILD/canny_arch2"
    compile_binary "vision/canny_arch3_scatter"     "$BUILD/canny_arch3"
    compile_binary "vision/canny_arch4_pipeline"    "$BUILD/canny_arch4"
    compile_binary "vision/log_arch1_farm"          "$BUILD/log_arch1"
    compile_binary "vision/log_arch2_pipeline"      "$BUILD/log_arch2"
    compile_binary "vision/log_arch3_scatter"       "$BUILD/log_arch3"
    compile_binary "vision/log_arch4_pipeline"      "$BUILD/log_arch4"
    compile_binary "vision/fft_arch1_farm"          "$BUILD/fft_arch1"
    compile_binary "vision/fft_arch2_pipeline"      "$BUILD/fft_arch2"
    compile_binary "vision/fft_arch3_dist_dynamic"  "$BUILD/fft_arch3"
    compile_binary "vision/fft_arch4_dist_pipeline" "$BUILD/fft_arch4"
    compile_binary "vision/resilience_test"         "$BUILD/resilience_test"
    log "All binaries compiled into workspace/$BUILD/"
else
    log "Skipping build (--skip-build)"
fi

# ── Output dirs inside workspace ─────────────────────────────────────────────
mkdir -p "$WS/results/out" "$WS/results/resilience"
OUT_CONT="/home/pi/workspace/results/out"
RES_CONT="/home/pi/workspace/results/resilience"

# ── Step 4: Serial baselines ──────────────────────────────────────────────────
section "STEP 4: Serial Baselines"
for img in "${IMAGES[@]}"; do
    log "IMAGE: $img"
    runc 1 "$BUILD/baselines" "$img"
done

# ── Per-image loop helper: runs all 4 archs for one filter ───────────────────
# run_filter_all <FILTER_TAG> <arch1_bin> <arch2_bin> <arch3_bin> <arch4_bin>
# arch4 for Sobel/LoG/FFT uses single-image mode: <img> <output.png>
# arch4 for Canny uses batch mode:                 <img_list> <out_dir> <N>
run_filter_all() {
    local tag="$1" b1="$2" b2="$3" b3="$4" b4="$5"

    for img in "${IMAGES[@]}"; do
        log "IMAGE: $img"
        local stem
        stem=$(basename "$img" | sed 's/\.[^.]*$//')

        # -- Arch1: OMP Farm  <img> <threads> <output.png>
        for t in "${THREAD_COUNTS[@]}"; do
            runc 1 "$b1" "$img $t $OUT_CONT/${tag}_arch1_t${t}_${stem}.png"
        done

        # -- Arch2: OMP Pipeline  <img> [chunk_rows] <output.png>
        runc 1 "$b2" "$img 32 $OUT_CONT/${tag}_arch2_${stem}.png"

        # -- Arch3: MPI Scatter  <img> <output.png>
        for n in "${NODE_COUNTS[@]}"; do
            runc "$n" "$b3" "$img $OUT_CONT/${tag}_arch3_n${n}_${stem}.png"
        done

        # -- Arch4: MPI Pipeline  <img> <output.png>  (single-image mode)
        for n in "${NODE_COUNTS[@]}"; do
            runc "$n" "$b4" "$img $OUT_CONT/${tag}_arch4_n${n}_${stem}.png"
        done
    done

    # -- Arch4 BSDS batch mode (uses image list, needs ≥2 nodes)
    # Canny arch4 uses batch-only mode; others support single-image too, but we
    # also time the batch path here for throughput data.
    if [[ $BSDS_OK -eq 1 && -s "$BSDS_LIST_HOST" ]]; then
        local out_sub="$BSDS_OUT_CONT/${tag}_arch4_batch"
        docker exec -u pi rpic_master mkdir -p "$out_sub" 2>/dev/null || true
        log "  BSDS batch: $b4  n=${NODE_COUNTS[0]}  N=$ACTUAL_N"
        runc "${NODE_COUNTS[0]}" "$b4" \
            "$BSDS_LIST_CONT $out_sub $ACTUAL_N"
    fi
}

section "STEP 5: Sobel — All Architectures"
run_filter_all sobel "$BUILD/sobel_arch1" "$BUILD/sobel_arch2" \
                     "$BUILD/sobel_arch3" "$BUILD/sobel_arch4"

section "STEP 6: Canny — All Architectures"
# Canny arch4 is batch-ONLY: <image_list> <out_dir> <N>
# We handle it specially below; pass the same binary for consistency.
for img in "${IMAGES[@]}"; do
    log "IMAGE: $img"
    stem=$(basename "$img" | sed 's/\.[^.]*$//')

    # Arch1
    for t in "${THREAD_COUNTS[@]}"; do
        runc 1 "$BUILD/canny_arch1" "$img $t $OUT_CONT/canny_arch1_t${t}_${stem}.png"
    done

    # Arch2 (fixed 4 stages, needs the patched canny_arch2)
    runc 1 "$BUILD/canny_arch2" "$img 32 $OUT_CONT/canny_arch2_${stem}.png"

    # Arch3
    for n in "${NODE_COUNTS[@]}"; do
        runc "$n" "$BUILD/canny_arch3" "$img $OUT_CONT/canny_arch3_n${n}_${stem}.png"
    done
done
# Arch4 — batch only, requires an image list file
if [[ $BSDS_OK -eq 1 && -s "$BSDS_LIST_HOST" ]]; then
    local_out="$BSDS_OUT_CONT/canny_arch4_batch"
    docker exec -u pi rpic_master mkdir -p "$local_out" 2>/dev/null || true
    log "  Canny ARCH4 batch: nodes=4  list=$BSDS_LIST_CONT  N=$ACTUAL_N"
    runc 4 "$BUILD/canny_arch4" "$BSDS_LIST_CONT $local_out $ACTUAL_N"
else
    log "  [SKIP] Canny arch4 requires BSD500 image list — not available"
fi

section "STEP 7: LoG — All Architectures"
run_filter_all log "$BUILD/log_arch1" "$BUILD/log_arch2" \
                   "$BUILD/log_arch3" "$BUILD/log_arch4"

section "STEP 8: FFT — All Architectures"
# FFT arch1/arch2/arch3/arch4 don't take an output path — they write fixed filenames
for img in "${IMAGES[@]}"; do
    log "IMAGE: $img"
    stem=$(basename "$img" | sed 's/\.[^.]*$//')

    # Arch1: <img> [num_threads]  (no output arg — writes fft_arch1_out.png)
    for t in "${THREAD_COUNTS[@]}"; do
        runc 1 "$BUILD/fft_arch1" "$img $t"
    done

    # Arch2: <img>
    runc 1 "$BUILD/fft_arch2" "$img"

    # Arch3: <img>
    for n in "${NODE_COUNTS[@]}"; do
        runc "$n" "$BUILD/fft_arch3" "$img"
    done

    # Arch4: <img>
    for n in "${NODE_COUNTS[@]}"; do
        runc "$n" "$BUILD/fft_arch4" "$img"
    done
done

# ── Step 9: Resilience test ───────────────────────────────────────────────────
section "STEP 9: Resilience Test"
RESILIENCE_NODES=$MAX_NODES
[[ $RESILIENCE_NODES -lt 3 ]] && RESILIENCE_NODES=3
for img in "${IMAGES[@]}"; do
    log "IMAGE: $img  NODES=$RESILIENCE_NODES"
    runc "$RESILIENCE_NODES" "$BUILD/resilience_test" "$img $RES_CONT"
done

# ── Step 10: Generate report ──────────────────────────────────────────────────
section "STEP 10: Generating Report"
if command -v python3 &>/dev/null; then
    python3 "$SCRIPT_DIR/generate_report.py" \
        --log "$LOG_FILE" \
        --outdir "$REPORT_DIR" \
        --node-counts "${NODE_COUNTS[*]}" \
        --thread-counts "${THREAD_COUNTS[*]}" \
        2>&1 | tee -a "$LOG_FILE"
else
    log "[WARN] python3 not found on host — run generate_report.py manually"
fi

section "ANALYSIS COMPLETE"
log "Log file  : $LOG_FILE"
log "Report dir: $REPORT_DIR/"
log "Finished  : $(date)"