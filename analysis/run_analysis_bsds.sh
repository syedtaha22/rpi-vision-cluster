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
NATIVE=0
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
        --native)     NATIVE=1;                                shift   ;;
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
WS="$SCRIPT_DIR/../workspace"
BUILD="build"
DS_ROOT="$CONT_WS/vision/datasets"
[[ $NATIVE -eq 1 ]] && DS_ROOT="$WS/vision/datasets"

# EXEC_PREFIX: Docker mode = docker exec; Native mode = ssh to master Pi
EXEC_PREFIX="docker exec -u pi rpic_master"
if [[ $NATIVE -eq 1 ]]; then
    RPI_CONFIG="$SCRIPT_DIR/../rpi/config.env"
    if [[ ! -f "$RPI_CONFIG" ]] || grep -q "__FILL_IN__" "$RPI_CONFIG" 2>/dev/null; then
        echo "  config.env missing — running gen_config.sh..."
        bash "$SCRIPT_DIR/../rpi/gen_config.sh" \
            || { echo "[FATAL] gen_config.sh failed"; exit 1; }
    fi
    source "$RPI_CONFIG"
    NATIVE_WS=$(ssh "${MASTER_USER}@${MASTER_IP}" "echo ${RPI_WORKSPACE_DIR}" 2>/dev/null) \
        || { echo "[FATAL] Cannot SSH to ${MASTER_USER}@${MASTER_IP}"; exit 1; }
    CONT_WS="$NATIVE_WS"
    DS_ROOT="$NATIVE_WS/vision/datasets"
    EXEC_PREFIX="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new ${MASTER_USER}@${MASTER_IP}"
fi

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
if [[ $NATIVE -eq 0 ]]; then
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
    $EXEC_PREFIX echo "ok" &>/dev/null
}

images_exist()   { docker image inspect pdc_project-master &>/dev/null; }

ensure_cluster() {
    local n="$MAX_NODES"
    if master_running && master_healthy; then
        local running
        running=$(docker ps --filter "name=rpic_" --filter "status=running" \
                     --format "{{.Names}}" 2>/dev/null | wc -l)
        if [[ $running -ge $n ]]; then
            log "  Cluster already running and healthy ($running containers)"; return 0
        fi
        log "  Only $running/$n containers — starting missing workers..."
        cd "$SCRIPT_DIR"
        docker compose --profile "${n}-nodes" up -d 2>&1 | tee -a "$LOG_FILE"
        sleep 3; return 0
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

# ── Ensure datasets exist (laptop or Pi) ──────────────────────────────────────
ensure_datasets() {
    local LOCAL_DS="$WS/vision/datasets"
    local -a needed=("$@")

    if [[ $NATIVE -eq 1 ]]; then
        # Native mode: check Pi, rsync from laptop if missing
        local REMOTE_DS="$NATIVE_WS/vision/datasets"
        $EXEC_PREFIX mkdir -p "$REMOTE_DS" 2>/dev/null || true
        for ds in "${needed[@]}"; do
            if ! $EXEC_PREFIX test -d "$REMOTE_DS/$ds" 2>/dev/null; then
                log "  Dataset '$ds' missing on Pi — pushing from laptop..."
                if [[ -d "$LOCAL_DS/$ds" ]]; then
                    rsync -az --info=progress2 \
                        "$LOCAL_DS/$ds/" \
                        "${MASTER_USER}@${MASTER_IP}:${REMOTE_DS}/${ds}/" \
                        2>&1 | tee -a "$LOG_FILE"
                    log "  ✓ '$ds' pushed to Pi"
                else
                    log "  [WARN] '$ds' also missing locally."
                    log "         Run Docker mode first to download: ./analysis/run_analysis_bsds.sh --fix"
                fi
            else
                log "  Dataset '$ds': already on Pi ✓"
            fi
        done
    else
        # Docker mode: run centralized downloader inside container
        local DL_FLAGS=""
        [[ $FIX -eq 1 ]] && DL_FLAGS="--fix"
        local needed_flags=""
        for ds in "${needed[@]}"; do
            case "$ds" in
                BSDS500) needed_flags="$needed_flags --bsds $BSDS_N" ;;
            esac
        done
        $EXEC_PREFIX bash "$CONT_WS/vision/shared/download_datasets.sh" \
            $DL_FLAGS $needed_flags 2>&1 | tee -a "$LOG_FILE"
    fi
}

# ── ensure_build_on_pi: deploy source + compile if binaries missing ───────────
ensure_build_on_pi() {
    if [[ $FIX -eq 1 ]] || ! $EXEC_PREFIX test -f "$NATIVE_WS/build/sobel_arch1" 2>/dev/null; then
        log "  Binaries missing on Pi (or --fix) — running deploy..."
        bash "$SCRIPT_DIR/../rpi/deploy.sh" 2>&1 | tee -a "$LOG_FILE"
        log "  ✓ Deploy complete"
    else
        log "  Binaries already on Pi ✓"
        SKIP_BUILD=1
    fi
}

# ── Step 1: Start cluster / Prepare Pi ───────────────────────────────────────
if [[ $NATIVE -eq 0 ]]; then
    section "STEP 1: Starting cluster (${MAX_NODES} nodes)"
    cd "$SCRIPT_DIR"
    ensure_cluster
    log "Verifying MPI connectivity..."
    $EXEC_PREFIX mpirun --allow-run-as-root -n "$MAX_NODES" \
        --host "$(hostlist_for "$MAX_NODES")" hostname \
        2>&1 | tee -a "$LOG_FILE" \
        && log "Cluster verification: OK" \
        || log "[WARN] Cluster verification failed — continuing anyway"
else
    section "STEP 1: Preparing RPi cluster (${MAX_NODES} nodes, SSH)"
    ensure_build_on_pi
fi

# ── Run helper with timeout guard ─────────────────────────────────────────────
runc() {
    local nodes="$1" bin="$2"; shift 2
    local args="${*:-}"
    local hostlist
    hostlist="$(hostlist_for "$nodes")"
    log "  [RUN] $bin  nodes=$nodes  args=$args"

    local cmd="cd $CONT_WS && \
        mpirun --allow-run-as-root -n ${nodes} --host ${hostlist} \
        ${CONT_WS}/${bin} ${args}"

    if [[ "${TIMEOUT_SECS:-0}" -gt 0 ]]; then
        timeout "$TIMEOUT_SECS" \
            $EXEC_PREFIX bash -c "$cmd" \
            2>&1 | tee -a "$LOG_FILE"
        local ec=${PIPESTATUS[0]}
        if [[ $ec -eq 124 ]]; then
            log "  [TIMEOUT] $bin exceeded ${TIMEOUT_SECS}s — skipping this run"
        elif [[ $ec -ne 0 ]]; then
            log "  [WARN] $bin exited $ec (continuing)"
        fi
    else
        $EXEC_PREFIX bash -c "$cmd" \
            2>&1 | tee -a "$LOG_FILE" \
        || log "  [WARN] $bin exited non-zero (continuing)"
    fi
}

compile_binary() {
    local src_stem="$1" out_name="$2"
    log "  [COMPILE] $src_stem → $out_name"
    $EXEC_PREFIX bash -c \
        "cd $CONT_WS && \
         mkdir -p \$(dirname $out_name) && \
         mpic++ -std=c++17 -O2 -fopenmp -I./vision/shared ${src_stem}.cpp -o ${out_name} -lm" \
        2>&1 | tee -a "$LOG_FILE" \
    || log "  [WARN] Compile failed for $src_stem"
}

# ── Step 2: BSDS500 dataset ───────────────────────────────────────────────────
section "STEP 2: BSDS500 Dataset Management (--fix=$FIX)"

ensure_datasets "BSDS500"

BSDS_DIR="$DS_ROOT/BSDS500/images"
BSDS_GT_DIR="$DS_ROOT/BSDS500/groundTruth_png"

mkdir -p "$WS/results"
BSDS_LIST_HOST="$WS/results/bsds_img_list.txt"
BSDS_LIST_CONT="$CONT_WS/results/bsds_img_list.txt"

$EXEC_PREFIX bash -c \
    "find '$BSDS_DIR' -name '*.jpg' | sort | head -${BSDS_N}" \
    > "$BSDS_LIST_HOST"
ACTUAL_N=$(wc -l < "$BSDS_LIST_HOST")
[[ $ACTUAL_N -eq 0 ]] && die "BSDS image list is empty"
log "  Image list: $ACTUAL_N images -> $BSDS_LIST_HOST"

GT_AVAILABLE=0
if $EXEC_PREFIX test -d "$BSDS_GT_DIR" 2>/dev/null; then
    GT_AVAILABLE=1
    log "  Ground-truth directory found: $BSDS_GT_DIR"
else
    log "  [WARN] Ground-truth dir not found ($BSDS_GT_DIR) — quality metrics will be skipped"
fi

BSDS_OUT_CONT="$CONT_WS/results/bsds_out"
for sub in sobel_arch1 sobel_arch2 sobel_arch3 sobel_arch4 \
           canny_arch1 canny_arch2 canny_arch3 canny_arch4 \
           log_arch1  log_arch2  log_arch3  log_arch4  \
           fft_arch1  fft_arch2  fft_arch3  fft_arch4; do
    $EXEC_PREFIX mkdir -p "$BSDS_OUT_CONT/$sub" 2>/dev/null || true
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
$EXEC_PREFIX mkdir -p "$BSDS_OUT_CONT/canny_arch4" 2>/dev/null || true
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
if $EXEC_PREFIX test -d "$BSDS_OUT_CONT" 2>/dev/null; then
    $EXEC_PREFIX bash -c \
        "cd $CONT_WS/results && tar cf - bsds_out" \
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
        $EXEC_PREFIX bash -c \
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
    $EXEC_PREFIX bash -c \
        "cd '$DS_ROOT/BSDS500' && tar cf - groundTruth_png" \
        | tar xf - -C "$WS/results/gt/" 2>/dev/null || true
    GT_ARG="--gt-dir $WS/results/gt/groundTruth_png"
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