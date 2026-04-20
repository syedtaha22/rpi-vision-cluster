#!/bin/bash
# =============================================================================
#  run_analysis_bsds.sh — BSDS500 performance + image quality analysis
#
#  Evaluates ALL four algorithms × four architectures on BSDS500 test images.
#  Also computes SSIM / Dice / Jaccard against BSDS500 ground-truth edge maps.
#  Resilience / Bully election → see resilience_analysis.sh
#
#  Usage:
#    ./run_analysis_bsds.sh                        # defaults (10 images)
#    ./run_analysis_bsds.sh --quick                # 3 images, fewer configs
#    ./run_analysis_bsds.sh --fix                  # wipe + redownload BSDS500, then run
#    ./run_analysis_bsds.sh --skip-build
#    ./run_analysis_bsds.sh --nodes 2,4 --threads 1,4
#    ./run_analysis_bsds.sh --n-images 50
#    ./run_analysis_bsds.sh --timeout 180          # per-run timeout (seconds)
# =============================================================================

set -uo pipefail

# ── Paths (defined first so BUILD_SENTINEL can reference SCRIPT_DIR) ──────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sentinel file written after a successful build so --skip-build is automatic
BUILD_SENTINEL="$SCRIPT_DIR/.build_ok_bsds"

# ── Defaults ──────────────────────────────────────────────────────────────────
NODE_COUNTS=(2 4 6)
THREAD_COUNTS=(1 2 4)
SKIP_BUILD=0
QUICK=0
FIX=0
VERIFY=0
BSDS_N=10
TIMEOUT_SECS=180

# Container workspace root (fixed by docker-compose bind-mount)
CONT_WS="/home/pi/workspace"
DS_ROOT="$CONT_WS/vision/datasets"

# Resolved dynamically in Step 2
BSDS_DIR=""
BSDS_GT_DIR=

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)      IFS=',' read -ra NODE_COUNTS   <<< "$2"; shift 2 ;;
        --threads)    IFS=',' read -ra THREAD_COUNTS <<< "$2"; shift 2 ;;
        --n-images)   BSDS_N="$2";                             shift 2 ;;
        --skip-build) SKIP_BUILD=1;                            shift   ;;
        --quick)      QUICK=1;                                 shift   ;;
        --fix)        FIX=1;                                   shift   ;;
        --verify)     VERIFY=1;                                shift   ;;
        --timeout)    TIMEOUT_SECS="$2";                       shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ $QUICK -eq 1 ]]; then
    NODE_COUNTS=(2 4)
    THREAD_COUNTS=(1 2)
    BSDS_N=3
fi

# ── Paths ─────────────────────────────────────────────────────────────────────
OUT_DIR="$SCRIPT_DIR/report_bsds"
LOG_FILE="$OUT_DIR/analysis_bsds.log"
WS="$SCRIPT_DIR/workspace"
BUILD="build"

mkdir -p "$OUT_DIR"

# ── Verify shortcut: just regenerate report from existing log ─────────────────
if [[ $VERIFY -eq 1 ]]; then
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "[VERIFY] No log found at $LOG_FILE — run without --verify first"
        exit 1
    fi
    echo "[VERIFY] Re-running BSDS report generator from: $LOG_FILE"
    ORIG_ARG=""
    [[ -d "$OUT_DIR/originals" ]] && ORIG_ARG="--orig-dir $OUT_DIR/originals"
    GT_ARG=""
    [[ -d "$OUT_DIR/gt" ]] && GT_ARG="--gt-dir $OUT_DIR/gt"
    python3 "$SCRIPT_DIR/generate_report_bsds.py" \
        --log           "$LOG_FILE" \
        --outdir        "$OUT_DIR" \
        --recon-dir     "$OUT_DIR/reconstructed" \
        --node-counts   "${NODE_COUNTS[*]}" \
        --thread-counts "${THREAD_COUNTS[*]}" \
        $ORIG_ARG $GT_ARG
    exit $?
fi

: > "$LOG_FILE"

# ── Logging ───────────────────────────────────────────────────────────────────
log()     { echo "$*" | tee -a "$LOG_FILE"; }
section() { log ""; log "================================================================="; log "  $*"; log "================================================================="; }
die()     { echo "[FATAL] $*" >&2; exit 1; }

log "RPI Vision Cluster — BSDS500 Performance + Quality Analysis"
log "Started : $(date)"
log "Nodes   : ${NODE_COUNTS[*]}"
log "Threads : ${THREAD_COUNTS[*]}"
log "N images: $BSDS_N"
log "Timeout : ${TIMEOUT_SECS}s per run"
log "Out dir : $OUT_DIR"

# ── Step 0: Docker + RAM check ────────────────────────────────────────────────
section "STEP 0: Checking Docker and available RAM"
command -v docker &>/dev/null || die "Docker not found on PATH"
docker compose version &>/dev/null || docker-compose --version &>/dev/null || die "Docker Compose not found"
command -v timeout &>/dev/null || { log "[WARN] 'timeout' not found — runs will not be time-limited"; TIMEOUT_SECS=0; }
log "Docker OK"

# Warn if free RAM is too low for the requested node count.
# Each container has mem_limit: 1g so we need at least (MAX_NODES + 1) GB free.
MAX_NODES="${NODE_COUNTS[-1]}"
if command -v free &>/dev/null; then
    FREE_MB=$(free -m | awk '/^Mem:/{print $7}')
    NEEDED_MB=$(( (MAX_NODES + 1) * 1024 ))
    log "RAM check: ${FREE_MB}MB free, ${NEEDED_MB}MB needed for ${MAX_NODES} nodes"
    if [[ $FREE_MB -lt $NEEDED_MB ]]; then
        log "[WARN] Low available RAM (${FREE_MB}MB < ${NEEDED_MB}MB)."
        log "       Consider --nodes $(( MAX_NODES / 2 )) or closing other applications."
        log "       Continuing anyway — expect swap-induced slowdowns."
    fi
else
    log "[WARN] 'free' not found — skipping RAM check"
fi

# ── Cluster helpers ───────────────────────────────────────────────────────────
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
        log "  Only $running/$n containers — starting missing workers..."
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
        log "  No images — building from scratch (~5-10 min first run)..."
        docker compose --profile "${n}-nodes" up -d --build \
            2>&1 | tee -a "$LOG_FILE" || die "docker compose up --build failed"
    fi

    log "  Waiting for rpic_master..."
    local retries=0
    until master_healthy || [[ $retries -ge 40 ]]; do
        sleep 3; retries=$((retries + 1))
        log "  ... waiting ($((retries * 3))s)"
    done
    master_healthy || die "rpic_master did not become healthy after $((40 * 3))s"
    sleep 3
    log "  Cluster ready ($n nodes)"
}

hostlist_for() {
    local n="$1" hosts=(master)
    for ((i=1; i<n; i++)); do hosts+=("worker$i"); done
    local IFS=','; echo "${hosts[*]}"
}

# ── Run helper with timeout guard ─────────────────────────────────────────────
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
            log "  [TIMEOUT] $bin exceeded ${TIMEOUT_SECS}s — skipping this run"
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

# ── Step 2: BSDS500 dataset ───────────────────────────────────────────────────
section "STEP 2: BSDS500 Dataset Management (--fix=$FIX)"

if [[ $FIX -eq 1 ]]; then
    log "  [FIX] Removing BSDS500 dataset for redownload..."
    docker exec -u pi rpic_master rm -rf "$DS_ROOT/BSDS500" 2>/dev/null || true
fi

BSDS_OK=0

BSDS_DIR="$DS_ROOT/BSDS500/data/images/test"
if docker exec -u pi rpic_master test -d "$BSDS_DIR" 2>/dev/null && \
   [[ $(docker exec -u pi rpic_master bash -c "find '$BSDS_DIR' -name '*.jpg' 2>/dev/null | wc -l") -gt 0 ]]; then
    log "  BSDS500 found at $BSDS_DIR"
    BSDS_OK=1
else
    FIRST=$(docker exec -u pi rpic_master bash -c \
        "find '$DS_ROOT/BSDS500' -name '*.jpg' 2>/dev/null | sort | head -1" 2>/dev/null || true)
    if [[ -n "$FIRST" ]]; then
        BSDS_DIR=$(docker exec -u pi rpic_master dirname "$FIRST")
        log "  BSDS500 images found at: $BSDS_DIR"
        BSDS_OK=1
    fi
fi

if [[ $BSDS_OK -eq 0 ]]; then
    log "  BSDS500 not found — downloading via kagglehub..."

    cat > /tmp/download_bsds.py << PYEOF
import kagglehub, shutil, os
print('  Downloading BSDS500 from Kaggle...')
path = kagglehub.dataset_download('balraj98/berkeley-segmentation-dataset-500-bsds500')
print(f'  Downloaded to: {path}')
dst = '$DS_ROOT/BSDS500'
if os.path.exists(dst):
    shutil.rmtree(dst)
shutil.copytree(path, dst)
print('  BSDS500 ready at', dst)
PYEOF

    docker cp /tmp/download_bsds.py rpic_master:/tmp/download_bsds.py
    docker exec -u pi rpic_master bash -c "
        pip install -q kagglehub scipy 2>/dev/null || true
        python3 /tmp/download_bsds.py
    " 2>&1 | tee -a "$LOG_FILE" && BSDS_OK=1 || die "BSDS500 download failed — cannot continue"

    FIRST=$(docker exec -u pi rpic_master bash -c \
        "find '$DS_ROOT/BSDS500' -name '*.jpg' 2>/dev/null | sort | head -1" 2>/dev/null || true)
    if [[ -n "$FIRST" ]]; then
        BSDS_DIR=$(docker exec -u pi rpic_master dirname "$FIRST")
        log "  Images at: $BSDS_DIR"
    else
        die "BSDS500 download succeeded but no .jpg images found"
    fi
fi

BSDS_GT_DIR="${BSDS_DIR/data\/images/data\/groundTruth}"
if ! docker exec -u pi rpic_master test -d "$BSDS_GT_DIR" 2>/dev/null; then
    FOUND_GT=$(docker exec -u pi rpic_master bash -c \
        "find '$DS_ROOT/BSDS500' -type d -name test | grep groundTruth | head -1" \
        2>/dev/null || true)
    [[ -n "$FOUND_GT" ]] && BSDS_GT_DIR="$FOUND_GT"
fi

mkdir -p "$WS/results"
BSDS_LIST_HOST="$WS/results/bsds_img_list.txt"
BSDS_LIST_CONT="$CONT_WS/results/bsds_img_list.txt"

docker exec -u pi rpic_master bash -c \
    "find '$BSDS_DIR' -name '*.jpg' | sort | head -${BSDS_N}" \
    > "$BSDS_LIST_HOST"
ACTUAL_N=$(wc -l < "$BSDS_LIST_HOST")
[[ $ACTUAL_N -eq 0 ]] && die "BSDS image list is empty"
log "  Image list: $ACTUAL_N images -> $BSDS_LIST_HOST"

GT_AVAILABLE=0
if docker exec -u pi rpic_master test -d "$BSDS_GT_DIR" 2>/dev/null; then
    GT_AVAILABLE=1
    log "  Ground-truth directory found: $BSDS_GT_DIR"
else
    log "  [WARN] Ground-truth dir not found ($BSDS_GT_DIR) — quality metrics will be skipped"
fi

BSDS_OUT_CONT="/home/pi/workspace/results/bsds_out"
for sub in sobel_arch1 sobel_arch2 sobel_arch3 sobel_arch4 \
           canny_arch1 canny_arch2 canny_arch3 canny_arch4 \
           log_arch1  log_arch2  log_arch3  log_arch4  \
           fft_arch1  fft_arch2  fft_arch3  fft_arch4; do
    docker exec -u pi rpic_master mkdir -p "$BSDS_OUT_CONT/$sub" 2>/dev/null || true
done

# ── Step 3: Build ─────────────────────────────────────────────────────────────
# Auto-skip if a previous build succeeded and --fix was not given.
# Shares the sentinel with run_analysis.sh via the same directory.
# Use a separate sentinel name so the two scripts track independently.

if [[ $SKIP_BUILD -eq 0 && $FIX -eq 0 && -f "$BUILD_SENTINEL" ]]; then
    log "  [AUTO] Skipping build — sentinel present ($BUILD_SENTINEL)."
    log "         Delete the sentinel or pass --fix to force a rebuild."
    SKIP_BUILD=1
fi

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
    touch "$BUILD_SENTINEL"
else
    section "STEP 3: Build (skipped)"
    log "  Using existing binaries in workspace/$BUILD/"
fi

# ── Step 4: Serial baselines ──────────────────────────────────────────────────
section "STEP 4: Serial Baselines (BSDS500)"
while IFS= read -r img; do
    log "IMAGE: $img"
    runc 1 "$BUILD/baselines" "$img"
done < "$BSDS_LIST_HOST"

# ── Filter benchmark helper ───────────────────────────────────────────────────
run_filter_bsds() {
    local tag="$1" b1="$2" b2="$3" b3="$4" b4="$5"

    while IFS= read -r img; do
        log "IMAGE: $img"
        local stem
        stem=$(basename "$img" | sed 's/\.[^.]*$//')

        # Arch1: OMP Farm
        for t in "${THREAD_COUNTS[@]}"; do
            runc 1 "$b1" "$img $t $BSDS_OUT_CONT/${tag}_arch1/${tag}_arch1_t${t}_${stem}.png"
        done

        # Arch2: OMP Pipeline
        runc 1 "$b2" "$img 32 $BSDS_OUT_CONT/${tag}_arch2/${tag}_arch2_${stem}.png"

        # Arch3: MPI Scatter
        for n in "${NODE_COUNTS[@]}"; do
            runc "$n" "$b3" "$img $BSDS_OUT_CONT/${tag}_arch3/${tag}_arch3_n${n}_${stem}.png"
        done

        # Arch4: MPI Pipeline single-image
        for n in "${NODE_COUNTS[@]}"; do
            runc "$n" "$b4" "$img $BSDS_OUT_CONT/${tag}_arch4/${tag}_arch4_n${n}_${stem}.png"
        done
    done < "$BSDS_LIST_HOST"

    # Arch4 batch throughput (uses image list)
    log "IMAGE: BSDS_BATCH_${tag^^}"
    runc "${NODE_COUNTS[0]}" "$b4" \
        "$BSDS_LIST_CONT $BSDS_OUT_CONT/${tag}_arch4 $ACTUAL_N"
}

section "STEP 5: Sobel — All Architectures (BSDS500)"
run_filter_bsds sobel "$BUILD/sobel_arch1" "$BUILD/sobel_arch2" \
                      "$BUILD/sobel_arch3" "$BUILD/sobel_arch4"

section "STEP 6: Canny — All Architectures (BSDS500)"
while IFS= read -r img; do
    log "IMAGE: $img"
    stem=$(basename "$img" | sed 's/\.[^.]*$//')
    for t in "${THREAD_COUNTS[@]}"; do
        runc 1 "$BUILD/canny_arch1" "$img $t $BSDS_OUT_CONT/canny_arch1/canny_arch1_t${t}_${stem}.png"
    done
    runc 1 "$BUILD/canny_arch2" "$img 32 $BSDS_OUT_CONT/canny_arch2/canny_arch2_${stem}.png"
    for n in "${NODE_COUNTS[@]}"; do
        runc "$n" "$BUILD/canny_arch3" "$img $BSDS_OUT_CONT/canny_arch3/canny_arch3_n${n}_${stem}.png"
    done
done < "$BSDS_LIST_HOST"
log "IMAGE: BSDS_BATCH_CANNY"
docker exec -u pi rpic_master mkdir -p "$BSDS_OUT_CONT/canny_arch4" 2>/dev/null || true
runc 4 "$BUILD/canny_arch4" "$BSDS_LIST_CONT $BSDS_OUT_CONT/canny_arch4 $ACTUAL_N"

section "STEP 7: LoG — All Architectures (BSDS500)"
run_filter_bsds log "$BUILD/log_arch1" "$BUILD/log_arch2" \
                    "$BUILD/log_arch3" "$BUILD/log_arch4"

section "STEP 8: FFT — All Architectures (BSDS500)"
while IFS= read -r img; do
    log "IMAGE: $img"
    for t in "${THREAD_COUNTS[@]}"; do
        runc 1 "$BUILD/fft_arch1" "$img $t"
    done
    runc 1 "$BUILD/fft_arch2" "$img"
    for n in "${NODE_COUNTS[@]}"; do
        runc "$n" "$BUILD/fft_arch3" "$img"
        runc "$n" "$BUILD/fft_arch4" "$img"
    done
done < "$BSDS_LIST_HOST"

# ── Step 9: Copy reconstructed images ─────────────────────────────────────────
section "STEP 9: Copying reconstructed images to $OUT_DIR"
mkdir -p "$OUT_DIR/reconstructed"
if docker exec -u pi rpic_master test -d "$BSDS_OUT_CONT" 2>/dev/null; then
    docker exec -u pi rpic_master bash -c \
        "cd /home/pi/workspace/results && tar cf - bsds_out" \
        | tar xf - -C "$WS/results/" 2>/dev/null || true
    cp -r "$WS/results/bsds_out/." "$OUT_DIR/reconstructed/" 2>/dev/null || true
    log "  Reconstructed images → $OUT_DIR/reconstructed/"
else
    log "  [WARN] No reconstructed images found — bsds_out missing"
fi

mkdir -p "$OUT_DIR/originals"
if [[ -n "$BSDS_LIST_HOST" && -f "$BSDS_LIST_HOST" ]]; then
    while IFS= read -r orig_img; do
        cp_dest="$OUT_DIR/originals/$(basename "$orig_img")"
        docker exec -u pi rpic_master bash -c \
            "cat '$orig_img'" > "$cp_dest" 2>/dev/null || true
    done < "$BSDS_LIST_HOST"
    orig_count=$(find "$OUT_DIR/originals" -name "*.jpg" -o -name "*.png" 2>/dev/null | wc -l)
    log "  Original images → $OUT_DIR/originals/ ($orig_count files)"
else
    log "  [WARN] bsds_img_list.txt not found — originals not copied"
fi

# ── Step 10: Generate report ──────────────────────────────────────────────────
section "STEP 10: Generating BSDS500 Report"
GT_ARG=""
if [[ $GT_AVAILABLE -eq 1 ]]; then
    mkdir -p "$WS/results/gt"
    # Strip everything from /data/ onward to get base, then append /data
    _bsds_base=$(docker exec -u pi rpic_master bash -c \
        "echo '$BSDS_GT_DIR' | sed 's|/data/.*||'" 2>/dev/null \
        || echo "$DS_ROOT/BSDS500")
    BSDS500_DATA_ROOT="${_bsds_base}/data"
    GT_REL=$(docker exec -u pi rpic_master bash -c \
        "echo '$BSDS_GT_DIR' | sed 's|.*BSDS500/data/||'" 2>/dev/null \
        || echo "groundTruth/test")
    docker exec -u pi rpic_master bash -c \
        "cd '$BSDS500_DATA_ROOT' && tar cf - '$GT_REL'" \
        | tar xf - -C "$WS/results/gt/" 2>/dev/null || true
    GT_ARG="--gt-dir $WS/results/gt/$GT_REL"
fi

if command -v python3 &>/dev/null; then
    ORIG_ARG=""
    if [[ -d "$OUT_DIR/originals" ]]; then
        orig_count=$(find "$OUT_DIR/originals" -maxdepth 1 \
            \( -name "*.jpg" -o -name "*.png" \) 2>/dev/null | wc -l)
        [[ $orig_count -gt 0 ]] && ORIG_ARG="--orig-dir $OUT_DIR/originals"
    fi
    python3 "$SCRIPT_DIR/generate_report_bsds.py" \
        --log         "$LOG_FILE" \
        --outdir      "$OUT_DIR" \
        --recon-dir   "$OUT_DIR/reconstructed" \
        --node-counts "${NODE_COUNTS[*]}" \
        --thread-counts "${THREAD_COUNTS[*]}" \
        $GT_ARG $ORIG_ARG \
        2>&1 | tee -a "$LOG_FILE"
else
    log "[WARN] python3 not found — run generate_report_bsds.py manually"
fi

section "ANALYSIS COMPLETE"
log "Log file : $LOG_FILE"
log "Report   : $OUT_DIR/"
log "Finished : $(date)"