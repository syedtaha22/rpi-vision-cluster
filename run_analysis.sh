#!/bin/bash
# =============================================================================
#  run_analysis.sh — Multi-image-size performance analysis (CIFAR / Tiny / COCO)
#
#  Benchmarks all 4 algorithms × 4 architectures on three image sizes to study
#  how image resolution affects parallel speedup and efficiency.
#  Resilience / bully election → see resilience_analysis.sh
#  BSDS500 benchmarks           → see run_analysis_bsds.sh
#
#  Usage:
#    ./run_analysis.sh                          # full run, defaults
#    ./run_analysis.sh --quick                  # 1 image, fewer configs
#    ./run_analysis.sh --fix                    # wipe + redownload datasets, then run
#    ./run_analysis.sh --skip-build             # skip recompiling binaries
#    ./run_analysis.sh --nodes 2,4 --threads 1,4
#    ./run_analysis.sh --image /path/to/img.png # skip dataset check, use this image
#    ./run_analysis.sh --timeout 90             # per-run timeout (seconds)
# =============================================================================

set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
NODE_COUNTS=(2 4 6)
THREAD_COUNTS=(1 2 4)
SKIP_BUILD=0
QUICK=0
FIX=0
VERIFY=0            # --verify: skip cluster/run, just regenerate report from existing log
CUSTOM_IMAGE=""
TIMEOUT_SECS=120    # per-run guard against blocking MPI calls

# Default per-dataset images (inside the container)
CIFAR_IMG="/home/pi/workspace/vision/datasets/cifar-10/tabby_s_000074.png"
TINY_IMG="/home/pi/workspace/vision/datasets/tiny-imagenet-200/test/images/test_0.JPEG"
COCO_IMG="/home/pi/workspace/vision/datasets/coco-val2017/000000144003.jpg"

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)      IFS=',' read -ra NODE_COUNTS   <<< "$2"; shift 2 ;;
        --threads)    IFS=',' read -ra THREAD_COUNTS <<< "$2"; shift 2 ;;
        --image)      CUSTOM_IMAGE="$2";                       shift 2 ;;
        --skip-build) SKIP_BUILD=1;                            shift   ;;
        --quick)      QUICK=1;                                 shift   ;;
        --verify)     VERIFY=1;                                shift   ;;
        --fix)        FIX=1;                                   shift   ;;
        --timeout)    TIMEOUT_SECS="$2";                       shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ $QUICK -eq 1 ]]; then
    NODE_COUNTS=(2 4)
    THREAD_COUNTS=(1 2)
fi

# IMAGES array is built in Step 2 after dataset verification
# (unless --image was given, in which case we skip dataset management)
IMAGES=()

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/analysis_results.log"
REPORT_DIR="$SCRIPT_DIR/report"
WS="$SCRIPT_DIR/workspace"
BUILD="build"
DS_ROOT="/home/pi/workspace/vision/datasets"

mkdir -p "$REPORT_DIR" "$WS/results/out"

# ── Verify shortcut: just regenerate report from existing log ─────────────────
if [[ $VERIFY -eq 1 ]]; then
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "[VERIFY] No log found at $LOG_FILE — run without --verify first"
        exit 1
    fi
    echo "[VERIFY] Re-running report generator from: $LOG_FILE"
    python3 "$SCRIPT_DIR/generate_report.py" \
        --log          "$LOG_FILE" \
        --outdir       "$REPORT_DIR" \
        --node-counts  "${NODE_COUNTS[*]}" \
        --thread-counts "${THREAD_COUNTS[*]}"
    exit $?
fi

: > "$LOG_FILE"

# ── Logging ───────────────────────────────────────────────────────────────────
log()     { echo "$*" | tee -a "$LOG_FILE"; }
section() { log ""; log "================================================================="; log "  $*"; log "================================================================="; }
die()     { echo "[FATAL] $*" >&2; exit 1; }

log "RPI Vision Cluster — Multi-Size Performance Analysis"
log "Started : $(date)"
log "Nodes   : ${NODE_COUNTS[*]}"
log "Threads : ${THREAD_COUNTS[*]}"
log "Timeout : ${TIMEOUT_SECS}s per run"

# ── Step 0: Docker check ──────────────────────────────────────────────────────
section "STEP 0: Checking Docker"
command -v docker &>/dev/null || die "Docker not found on PATH"
docker compose version &>/dev/null || docker-compose --version &>/dev/null || die "Docker Compose not found"
command -v timeout &>/dev/null || { log "[WARN] 'timeout' not found — runs will not be time-limited"; TIMEOUT_SECS=0; }
log "Docker OK"

# ── Cluster helpers ───────────────────────────────────────────────────────────
MAX_NODES="${NODE_COUNTS[-1]}"

master_running() {
    local status
    status=$(docker inspect --format '{{.State.Status}}' rpic_master 2>/dev/null)
    [[ "$status" == "running" ]]
}

master_healthy() {
    docker exec -u pi rpic_master echo "ok" &>/dev/null
}

images_exist() {
    docker image inspect pdc_project-master &>/dev/null
}

ensure_cluster() {
    local n="$MAX_NODES"

    if master_running && master_healthy; then
        local running
        running=$(docker ps --filter "name=rpic_" --filter "status=running" \
                             --format "{{.Names}}" 2>/dev/null | wc -l)
        if [[ $running -ge $n ]]; then
            log "  Cluster already running and healthy ($running containers)"
            return 0
        fi
        log "  Only $running/$n containers up — starting missing workers..."
        cd "$SCRIPT_DIR"
        docker compose --profile "${n}-nodes" up -d 2>&1 | tee -a "$LOG_FILE"
        sleep 3
        return 0
    fi

    cd "$SCRIPT_DIR"

    if images_exist; then
    docker compose \
        --profile 2-nodes --profile 3-nodes --profile 4-nodes \
        --profile 5-nodes --profile 6-nodes \
        down --remove-orphans 2>&1 | tail -3 | tee -a "$LOG_FILE"
    docker compose --profile "${n}-nodes" up -d \
        2>&1 | tee -a "$LOG_FILE" || die "docker compose up failed"
    else
        log "  No images — building from scratch (first run ~5-10 min)..."
        docker compose --profile "${n}-nodes" up -d --build \
            2>&1 | tee -a "$LOG_FILE" || die "docker compose up --build failed"
    fi

    log "  Waiting for rpic_master..."
    local retries=0
    until master_healthy || [[ $retries -ge 40 ]]; do
        sleep 3; retries=$((retries + 1))
        log "  ... waiting ($((retries * 3))s)"
    done
    master_healthy || die "rpic_master did not become healthy"
    sleep 3
    log "  Cluster ready ($n nodes)"
}

hostlist_for() {
    local n="$1" hosts=(master)
    for ((i=1; i<n; i++)); do hosts+=("worker$i"); done
    local IFS=','; echo "${hosts[*]}"
}

# ── Run helper with timeout guard ─────────────────────────────────────────────
# runc <nodes> <binary_rel_to_workspace> [args...]
runc() {
    local nodes="$1" bin="$2"; shift 2
    local args="${*:-}"
    local hostlist
    hostlist="$(hostlist_for "$nodes")"
    log "  [RUN] $bin  nodes=$nodes  args=$args"

    local cmd="cd /home/pi/workspace && \
        mpirun --allow-run-as-root -n ${nodes} --host ${hostlist} \
        /home/pi/workspace/${bin} ${args}"

    if [[ "${TIMEOUT_SECS:-0}" -gt 0 ]]; then
        timeout "$TIMEOUT_SECS" \
            docker exec -u pi rpic_master bash -c "$cmd" \
            2>&1 | tee -a "$LOG_FILE"
        local ec=${PIPESTATUS[0]}
        if [[ $ec -eq 124 ]]; then
            log "  [TIMEOUT] $bin exceeded ${TIMEOUT_SECS}s — skipping"
        elif [[ $ec -ne 0 ]]; then
            log "  [WARN] $bin exited $ec (continuing)"
        fi
    else
        docker exec -u pi rpic_master bash -c "$cmd" \
            2>&1 | tee -a "$LOG_FILE" \
        || log "  [WARN] $bin exited non-zero (continuing)"
    fi
}

compile_binary() {
    local src_stem="$1" out_name="$2"
    log "  [COMPILE] $src_stem → $out_name"
    docker exec -u pi rpic_master bash -c \
        "cd /home/pi/workspace && \
         mkdir -p \$(dirname $out_name) && \
         mpic++ -std=c++17 -O2 -fopenmp -I./vision/shared ${src_stem}.cpp -o ${out_name} -lm" \
        2>&1 | tee -a "$LOG_FILE" \
    || log "  [WARN] Compile failed for $src_stem"
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

# ── Step 2: Dataset management ───────────────────────────────────────────────
section "STEP 2: Dataset management (--fix=$FIX)"

## ensure_dataset <label> <dir_in_container> <find_pattern> <var_name>
# Downloads dataset if absent (or wipes + redownloads if FIX=1).
# Sets the named variable to the first discovered image path.
ensure_dataset() {
    local label="$1" ds_dir="$2" pattern="$3" retvar="$4"

    if [[ $FIX -eq 1 ]]; then
        log "  [FIX] Removing $label for redownload..."
        docker exec -u pi rpic_master rm -rf "$ds_dir" 2>/dev/null || true
    fi

    local count
    count=$(docker exec -u pi rpic_master bash -c \
        "find '$ds_dir' -name '$pattern' 2>/dev/null | wc -l" 2>/dev/null || echo 0)

    if [[ $count -gt 0 ]]; then
        log "  [OK] $label already present ($count images)"
    else
        log "  Downloading $label..."
        case "$label" in
            CIFAR-10)
                # Write Python script to a temp file to avoid quoting issues
                cat > /tmp/extract_cifar.py << 'PYEOF'
import pickle, numpy as np, os, sys
from PIL import Image
ds_root = sys.argv[1]
out_dir = sys.argv[2]
src = os.path.join(ds_root, 'cifar-10-batches-py', 'data_batch_1')
os.makedirs(out_dir, exist_ok=True)
with open(src, 'rb') as f:
    d = pickle.load(f, encoding='bytes')
data, names = d[b'data'], d[b'filenames']
for i in range(min(100, len(data))):
    r = data[i][:1024].reshape(32, 32)
    g = data[i][1024:2048].reshape(32, 32)
    b = data[i][2048:].reshape(32, 32)
    Image.fromarray(np.dstack((r, g, b))).save(
        os.path.join(out_dir, names[i].decode()))
print('CIFAR-10 extracted')
PYEOF
                docker cp /tmp/extract_cifar.py rpic_master:/tmp/extract_cifar.py
                docker exec -u pi rpic_master bash -c "
                    pip install -q Pillow numpy 2>/dev/null || true
                    mkdir -p '$ds_dir'
                    cd '$DS_ROOT'
                    wget -q -nc --show-progress https://www.cs.toronto.edu/~kriz/cifar-10-python.tar.gz 2>&1 || true
                    tar -xzf cifar-10-python.tar.gz 2>/dev/null || true
                    python3 /tmp/extract_cifar.py '$DS_ROOT' '$ds_dir'
                    rm -rf '$DS_ROOT/cifar-10-batches-py' '$DS_ROOT/cifar-10-python.tar.gz' 2>/dev/null || true
                " 2>&1 | tee -a "$LOG_FILE" || log "  [WARN] CIFAR-10 download failed"
                ;;
            TinyImageNet)
                docker exec -u pi rpic_master bash -c "
                    mkdir -p '$DS_ROOT'
                    cd '$DS_ROOT'
                    wget -q -nc --show-progress http://cs231n.stanford.edu/tiny-imagenet-200.zip 2>&1 || true
                    unzip -q tiny-imagenet-200.zip 2>/dev/null || true
                    rm -f tiny-imagenet-200.zip 2>/dev/null || true
                " 2>&1 | tee -a "$LOG_FILE" || log "  [WARN] TinyImageNet download failed"
                ;;
            COCO-Val2017)
                docker exec -u pi rpic_master bash -c "
                    mkdir -p '$DS_ROOT'
                    cd '$DS_ROOT'
                    wget -q -nc --show-progress http://images.cocodataset.org/zips/val2017.zip 2>&1 || true
                    unzip -q val2017.zip 2>/dev/null || true
                    mv val2017 coco-val2017 2>/dev/null || true
                    rm -f val2017.zip 2>/dev/null || true
                " 2>&1 | tee -a "$LOG_FILE" || log "  [WARN] COCO download failed"
                ;;
        esac
    fi

    # Discover first image dynamically
    local img
    img=$(docker exec -u pi rpic_master bash -c \
        "find '$ds_dir' -name '$pattern' 2>/dev/null | sort | head -1" 2>/dev/null || true)

    if [[ -z "$img" ]]; then
        log "  [WARN] No $pattern found under $ds_dir — $label runs will be skipped"
    else
        log "  [IMG] $label -> $img"
    fi
    printf -v "$retvar" '%s' "$img"
}

if [[ -n "$CUSTOM_IMAGE" ]]; then
    log "  Custom image specified — skipping dataset management"
    docker exec -u pi rpic_master test -f "$CUSTOM_IMAGE" 2>/dev/null \
        || die "Custom image not found in container: $CUSTOM_IMAGE"
    IMAGES=("$CUSTOM_IMAGE")
else
    ensure_dataset "CIFAR-10"     "$DS_ROOT/cifar-10"          "*.png"  CIFAR_IMG
    ensure_dataset "TinyImageNet" "$DS_ROOT/tiny-imagenet-200" "*.JPEG" TINY_IMG
    if [[ -z "$TINY_IMG" ]]; then
        ensure_dataset "TinyImageNet" "$DS_ROOT/tiny-imagenet-200" "*.jpeg" TINY_IMG
    fi
    if [[ -z "$TINY_IMG" ]]; then
        ensure_dataset "TinyImageNet" "$DS_ROOT/tiny-imagenet-200" "*.jpg"  TINY_IMG
    fi
    ensure_dataset "COCO-Val2017" "$DS_ROOT/coco-val2017"      "*.jpg"  COCO_IMG

    for img in "$CIFAR_IMG" "$TINY_IMG" "$COCO_IMG"; do
        [[ -n "$img" ]] && IMAGES+=("$img")
    done
    [[ ${#IMAGES[@]} -eq 0 ]] && die "No dataset images available — use --fix to redownload"
    log "  Running on ${#IMAGES[@]} image(s): ${IMAGES[*]}"
fi

# ── Step 3: Build all binaries ────────────────────────────────────────────────
if [[ $SKIP_BUILD -eq 0 ]]; then
    section "STEP 3: Building all architecture binaries"
    compile_binary "vision/shared/baselines"               "$BUILD/baselines"
    compile_binary "vision/sobel/sobel_arch1_farm"        "$BUILD/sobel_arch1"
    compile_binary "vision/sobel/sobel_arch2_pipeline"    "$BUILD/sobel_arch2"
    compile_binary "vision/sobel/sobel_arch3_scatter"     "$BUILD/sobel_arch3"
    compile_binary "vision/sobel/sobel_arch4_pipeline"    "$BUILD/sobel_arch4"
    compile_binary "vision/canny/canny_arch1_farm"        "$BUILD/canny_arch1"
    compile_binary "vision/canny/canny_arch2_pipeline"    "$BUILD/canny_arch2"
    compile_binary "vision/canny/canny_arch3_scatter"     "$BUILD/canny_arch3"
    compile_binary "vision/canny/canny_arch4_pipeline"    "$BUILD/canny_arch4"
    compile_binary "vision/log/log_arch1_farm"          "$BUILD/log_arch1"
    compile_binary "vision/log/log_arch2_pipeline"      "$BUILD/log_arch2"
    compile_binary "vision/log/log_arch3_scatter"       "$BUILD/log_arch3"
    compile_binary "vision/log/log_arch4_pipeline"      "$BUILD/log_arch4"
    compile_binary "vision/fft/fft_arch1_farm"          "$BUILD/fft_arch1"
    compile_binary "vision/fft/fft_arch2_pipeline"      "$BUILD/fft_arch2"
    compile_binary "vision/fft/fft_arch3_dist_dynamic"  "$BUILD/fft_arch3"
    compile_binary "vision/fft/fft_arch4_dist_pipeline" "$BUILD/fft_arch4"
    log "All binaries compiled into workspace/$BUILD/"
else
    log "Skipping build (--skip-build)"
fi

OUT_CONT="/home/pi/workspace/results/out"
docker exec -u pi rpic_master mkdir -p "$OUT_CONT" 2>/dev/null || true

# ── Step 4: Serial baselines ──────────────────────────────────────────────────
section "STEP 4: Serial Baselines"
for img in "${IMAGES[@]}"; do
    log "IMAGE: $img"
    runc 1 "$BUILD/baselines" "$img"
done

# ── Per-image loop: runs all 4 archs for one filter ──────────────────────────
run_filter_all() {
    local tag="$1" b1="$2" b2="$3" b3="$4" b4="$5"

    for img in "${IMAGES[@]}"; do
        log "IMAGE: $img"
        local stem
        stem=$(basename "$img" | sed 's/\.[^.]*$//')

        # Arch1: OMP Farm  <img> <threads> <output.png>
        for t in "${THREAD_COUNTS[@]}"; do
            runc 1 "$b1" "$img $t $OUT_CONT/${tag}_arch1_t${t}_${stem}.png"
        done

        # Arch2: OMP Pipeline  <img> <chunk_rows> <output.png>
        runc 1 "$b2" "$img 32 $OUT_CONT/${tag}_arch2_${stem}.png"

        # Arch3: MPI Scatter  <img> <output.png>
        for n in "${NODE_COUNTS[@]}"; do
            runc "$n" "$b3" "$img $OUT_CONT/${tag}_arch3_n${n}_${stem}.png"
        done

        # Arch4: MPI Pipeline  <img> <output.png>
        for n in "${NODE_COUNTS[@]}"; do
            runc "$n" "$b4" "$img $OUT_CONT/${tag}_arch4_n${n}_${stem}.png"
        done
    done
}

section "STEP 5: Sobel — All Architectures"
run_filter_all sobel "$BUILD/sobel_arch1" "$BUILD/sobel_arch2" \
                     "$BUILD/sobel_arch3" "$BUILD/sobel_arch4"

section "STEP 6: Canny — All Architectures"
for img in "${IMAGES[@]}"; do
    log "IMAGE: $img"
    stem=$(basename "$img" | sed 's/\.[^.]*$//')

    for t in "${THREAD_COUNTS[@]}"; do
        runc 1 "$BUILD/canny_arch1" "$img $t $OUT_CONT/canny_arch1_t${t}_${stem}.png"
    done
    runc 1 "$BUILD/canny_arch2" "$img 32 $OUT_CONT/canny_arch2_${stem}.png"
    for n in "${NODE_COUNTS[@]}"; do
        runc "$n" "$BUILD/canny_arch3" "$img $OUT_CONT/canny_arch3_n${n}_${stem}.png"
    done
    # Arch4 for Canny is batch-only; skip single-image mode
done
log "  [NOTE] Canny Arch4 (batch-only) → run run_analysis_bsds.sh for throughput"

section "STEP 7: LoG — All Architectures"
run_filter_all log "$BUILD/log_arch1" "$BUILD/log_arch2" \
                   "$BUILD/log_arch3" "$BUILD/log_arch4"

section "STEP 8: FFT — All Architectures"
for img in "${IMAGES[@]}"; do
    log "IMAGE: $img"

    # Arch1: <img> [num_threads]
    for t in "${THREAD_COUNTS[@]}"; do
        runc 1 "$BUILD/fft_arch1" "$img $t"
    done

    # Arch2: <img>
    runc 1 "$BUILD/fft_arch2" "$img"

    # Arch3 / Arch4: <img>
    for n in "${NODE_COUNTS[@]}"; do
        runc "$n" "$BUILD/fft_arch3" "$img"
        runc "$n" "$BUILD/fft_arch4" "$img"
    done
done

# ── Step 9: Generate report ───────────────────────────────────────────────────
section "STEP 9: Generating Report"
if command -v python3 &>/dev/null; then
    python3 "$SCRIPT_DIR/generate_report.py" \
        --log "$LOG_FILE" \
        --outdir "$REPORT_DIR" \
        --node-counts "${NODE_COUNTS[*]}" \
        --thread-counts "${THREAD_COUNTS[*]}" \
        2>&1 | tee -a "$LOG_FILE"
else
    log "[WARN] python3 not found — run generate_report.py manually"
fi

section "ANALYSIS COMPLETE"
log "Log file  : $LOG_FILE"
log "Report dir: $REPORT_DIR/"
log "Finished  : $(date)"
