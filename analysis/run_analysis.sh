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
#    ./run_analysis.sh --with-coco              # include COCO-Val2017 (large, slow)
# =============================================================================

set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
NODE_COUNTS=(2 4 6)
THREAD_COUNTS=(1 2 4)
SKIP_BUILD=0
QUICK=0
FIX=0
VERIFY=0
NATIVE=0
WITH_COCO=0           # opt-in: --with-coco
CUSTOM_IMAGE=""
TIMEOUT_SECS=120

# Default per-dataset images (inside the container)
CIFAR_IMG="/home/pi/workspace/vision/datasets/cifar-10/tabby_s_000074.png"
TINY_IMG="/home/pi/workspace/vision/datasets/tiny-imagenet-200/test/images/test_0.JPEG"
COCO_IMG="/home/pi/workspace/vision/datasets/coco-val2017/000000144003.jpg"

# ── Parse arguments ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sentinel file written after a successful build so --skip-build is automatic
BUILD_SENTINEL="$SCRIPT_DIR/.build_ok"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)      IFS=',' read -ra NODE_COUNTS   <<< "$2"; shift 2 ;;
        --threads)    IFS=',' read -ra THREAD_COUNTS <<< "$2"; shift 2 ;;
        --image)      CUSTOM_IMAGE="$2";                       shift 2 ;;
        --skip-build) SKIP_BUILD=1;                            shift   ;;
        --quick)      QUICK=1;                                 shift   ;;
        --verify)     VERIFY=1;                                shift   ;;
        --native)     NATIVE=1;                                shift   ;;
        --fix)        FIX=1;                                   shift   ;;
        --with-coco)  WITH_COCO=1;                             shift   ;;
        --timeout)    TIMEOUT_SECS="$2";                       shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ $QUICK -eq 1 ]]; then
    NODE_COUNTS=(2 4)
    THREAD_COUNTS=(1 2)
fi

IMAGES=()

# ── Paths ─────────────────────────────────────────────────────────────────────
LOG_FILE="$SCRIPT_DIR/analysis_results.log"
REPORT_DIR="$SCRIPT_DIR/report"
CONT_WS="/home/pi/workspace"       # path inside Docker container
WS="$SCRIPT_DIR/../workspace"      # local workspace on laptop
BUILD="build"
DS_ROOT="$CONT_WS/vision/datasets"

# EXEC_PREFIX — command prefix for all cluster operations:
#   Docker mode : "docker exec -u pi rpic_master"
#   Native mode : "ssh -o BatchMode=yes rpi-master@<IP>"
EXEC_PREFIX="docker exec -u pi rpic_master"

if [[ $NATIVE -eq 1 ]]; then
    RPI_CONFIG="$SCRIPT_DIR/../rpi/config.env"
    # Auto-generate config if missing
    if [[ ! -f "$RPI_CONFIG" ]] || grep -q "__FILL_IN__" "$RPI_CONFIG" 2>/dev/null; then
        echo "  config.env missing — running gen_config.sh..."
        bash "$SCRIPT_DIR/../rpi/gen_config.sh" \
            || { echo "[FATAL] gen_config.sh failed"; exit 1; }
    fi
    source "$RPI_CONFIG"
    # Expand tilde: get the real absolute path on the Pi
    NATIVE_WS=$(ssh "${MASTER_USER}@${MASTER_IP}" \
        "echo ${RPI_WORKSPACE_DIR}" 2>/dev/null) \
        || { echo "[FATAL] Cannot SSH to ${MASTER_USER}@${MASTER_IP}. Check config.env and SSH keys."; exit 1; }
    CONT_WS="$NATIVE_WS"
    DS_ROOT="$NATIVE_WS/vision/datasets"
    EXEC_PREFIX="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new ${MASTER_USER}@${MASTER_IP}"
fi

mkdir -p "$REPORT_DIR" "$WS/results/out"

# ── Verify shortcut ───────────────────────────────────────────────────────────
if [[ $VERIFY -eq 1 ]]; then
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "[VERIFY] No log found at $LOG_FILE — run without --verify first"
        exit 1
    fi
    echo "[VERIFY] Re-running report generator from: $LOG_FILE"
    python3 "$SCRIPT_DIR/generate_report.py" \
        --log           "$LOG_FILE" \
        --outdir        "$REPORT_DIR" \
        --node-counts   "${NODE_COUNTS[*]}" \
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
log "Mode    : $([ $NATIVE -eq 1 ] && echo 'Native RPi (SSH)' || echo 'Docker (local)')"
log "COCO    : $([ $WITH_COCO -eq 1 ] && echo enabled || echo 'disabled -- use --with-coco to enable')"

MAX_NODES="${NODE_COUNTS[-1]}"

# ── hostlist_for — works in both Docker and Native modes ─────────────────────
hostlist_for() {
    local n="$1"
    if [[ $NATIVE -eq 1 ]]; then
        local ALL_IPS=("$MASTER_IP" "$WORKER1_IP" "$WORKER2_IP" "$WORKER3_IP" "$WORKER4_IP" "$WORKER5_IP")
        local hosts=()
        for ((i=0; i<n; i++)); do hosts+=("${ALL_IPS[$i]}"); done
        local IFS=','; echo "${hosts[*]}"
    else
        local hosts=(master)
        for ((i=1; i<n; i++)); do hosts+=("worker$i"); done
        local IFS=','; echo "${hosts[*]}"
    fi
}

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
            log "  [TIMEOUT] $bin exceeded ${TIMEOUT_SECS}s — skipping"
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
                    log "         Run Docker mode first to download: ./analysis/run_analysis.sh --fix"
                fi
            else
                log "  Dataset '$ds': already on Pi ✓"
            fi
        done
    else
        # Docker mode: run centralized downloader inside container
        local DL_FLAGS=""
        [[ $FIX -eq 1 ]] && DL_FLAGS="--fix"
        [[ $WITH_COCO -eq 1 ]] && DL_FLAGS="$DL_FLAGS --coco"
        local needed_flags=""
        for ds in "${needed[@]}"; do
            case "$ds" in
                cifar-10)           needed_flags="$needed_flags --cifar" ;;
                tiny-imagenet-200)  needed_flags="$needed_flags --tiny" ;;
                coco-val2017)       needed_flags="$needed_flags --coco" ;;
                BSDS500)            needed_flags="$needed_flags --bsds 1" ;;
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

# ── Step 0: Docker check (Docker mode only) ───────────────────────────────────
if [[ $NATIVE -eq 0 ]]; then
    section "STEP 0: Checking Docker and available RAM"
    command -v docker &>/dev/null || die "Docker not found on PATH"
    docker compose version &>/dev/null || docker-compose --version &>/dev/null \
        || die "Docker Compose not found"
    command -v timeout &>/dev/null \
        || { log "[WARN] 'timeout' not found — runs will not be time-limited"; TIMEOUT_SECS=0; }
    log "Docker OK"
    if command -v free &>/dev/null; then
        FREE_MB=$(free -m | awk '/^Mem:/{print $7}')
        NEEDED_MB=$(( (MAX_NODES + 1) * 1024 ))
        log "RAM check: ${FREE_MB}MB free, ${NEEDED_MB}MB needed for ${MAX_NODES} nodes"
        [[ $FREE_MB -lt $NEEDED_MB ]] && \
            log "[WARN] Low RAM — expect swap-induced slowdowns."
    fi
fi

# ── Docker cluster helpers (Docker mode only) ─────────────────────────────────
master_running() {
    local status
    status=$(docker inspect --format '{{.State.Status}}' rpic_master 2>/dev/null)
    [[ "$status" == "running" ]]
}
master_healthy() { $EXEC_PREFIX echo "ok" &>/dev/null; }
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
        log "  Only $running/$n containers up — starting missing workers..."
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

# ── Step 1: Start cluster / Prepare Pi ───────────────────────────────────────
if [[ $NATIVE -eq 0 ]]; then
    section "STEP 1: Starting Docker cluster (${MAX_NODES} nodes)"
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

# ── Step 2: Dataset management ───────────────────────────────────────────────
section "STEP 2: Dataset management (--fix=$FIX)"
IMAGES=()
NEEDED_DS=("cifar-10" "tiny-imagenet-200")
[[ $WITH_COCO -eq 1 ]] && NEEDED_DS+=("coco-val2017")

if [[ -n "$CUSTOM_IMAGE" ]]; then
    $EXEC_PREFIX test -f "$CUSTOM_IMAGE" 2>/dev/null \
        || die "Custom image not found: $CUSTOM_IMAGE"
    IMAGES=("$CUSTOM_IMAGE")
else
    ensure_datasets "${NEEDED_DS[@]}"

    CIFAR_IMG=$($EXEC_PREFIX bash -c "find '$DS_ROOT/cifar-10' -name '*.jpg' -o -name '*.png' | head -1" 2>/dev/null || true)
    TINY_IMG=$($EXEC_PREFIX bash -c "find '$DS_ROOT/tiny-imagenet-200' -name '*.jpg' -o -name '*.JPEG' | head -1" 2>/dev/null || true)

    for img in "$CIFAR_IMG" "$TINY_IMG"; do
        [[ -n "$img" ]] && IMAGES+=("$img")
    done

    if [[ $WITH_COCO -eq 1 ]]; then
        COCO_IMG=$($EXEC_PREFIX bash -c "find '$DS_ROOT/coco-val2017' -name '*.jpg' | head -1" 2>/dev/null || true)
        [[ -n "$COCO_IMG" ]] && IMAGES+=("$COCO_IMG")
    else
        log "  [SKIP] COCO-Val2017 skipped (pass --with-coco to enable)"
    fi

    [[ ${#IMAGES[@]} -eq 0 ]] && die "No dataset images available — check datasets or run with --fix"
    log "  Running on ${#IMAGES[@]} image(s): ${IMAGES[*]}"
fi


# ── Step 3: Build all binaries ────────────────────────────────────────────────
# Auto-skip if a previous build succeeded and --fix was not given.
# A successful build writes a sentinel file; --fix or explicit --skip-build=0
# forces a rebuild and refreshes the sentinel.

BUILD_SENTINEL="$SCRIPT_DIR/.build_ok"

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
    # Mark build as done so next run skips automatically
    touch "$BUILD_SENTINEL"
else
    section "STEP 3: Build (skipped)"
    log "  Using existing binaries in workspace/$BUILD/"
fi

OUT_CONT="$CONT_WS/results/out"
$EXEC_PREFIX bash -c "mkdir -p $OUT_CONT" 2>/dev/null || true

# ── Step 4: Serial baselines ──────────────────────────────────────────────────
section "STEP 4: Serial Baselines"
for img in "${IMAGES[@]}"; do
    log "IMAGE: $img"
    runc 1 "$BUILD/baselines" "$img"
done

# ── Per-filter runner ─────────────────────────────────────────────────────────
# Binaries use original positional args: <img> <param> <output.png>
# One mpirun per image keeps compatibility; the speed gains from earlier
# changes (COCO opt-out, build sentinel, RAM check) still apply.

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

        # Arch3 / Arch4: MPI  <img> <output.png>
        for n in "${NODE_COUNTS[@]}"; do
            runc "$n" "$b3" "$img $OUT_CONT/${tag}_arch3_n${n}_${stem}.png"
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