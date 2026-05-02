#!/usr/bin/env bash
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
#    ./run_analysis_bsds.sh --native               # run on physical Pis (SSH)
#    ./run_analysis_bsds.sh --fix                  # wipe + redownload BSDS500, then run
#    ./run_analysis_bsds.sh --skip-build
#    ./run_analysis_bsds.sh --nodes 2,4 --threads 1,4
#    ./run_analysis_bsds.sh --n-images 50
#    ./run_analysis_bsds.sh --timeout 180          # per-run timeout (seconds)
#
#  After completion, run the report generator manually:
#    python3 analysis/generate_report_bsds.py \
#        --log analysis/report_bsds/analysis_bsds.log \
#        --outdir analysis/report_bsds \
#        --recon-dir analysis/report_bsds/reconstructed \
#        --node-counts "2 4 6" --thread-counts "1 2 4"
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

CONT_WS="/home/pi/workspace"
DS_ROOT="$CONT_WS/vision/datasets"

BSDS_DIR=""
BSDS_GT_DIR=""

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

[[ $FIX -eq 1 ]] && rm -f "$BUILD_SENTINEL"

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

EXEC_PREFIX="docker exec -u pi rpic_master"
if [[ $NATIVE -eq 1 ]]; then
    RPI_CONFIG="$SCRIPT_DIR/../rpi/config.env"
    if [[ ! -f "$RPI_CONFIG" ]] || grep -q "__FILL_IN__" "$RPI_CONFIG" 2>/dev/null; then
        echo "  config.env missing — running gen_config.sh..."
        bash "$SCRIPT_DIR/../rpi/gen_config.sh" \
            || { echo "[FATAL] gen_config.sh failed"; exit 1; }
    fi
    source "$RPI_CONFIG"
    _q_ws=$(printf '%q' "${RPI_WORKSPACE_DIR}")
    NATIVE_WS=$(ssh "${MASTER_USER}@${MASTER_HOST}" "bash -lc \"echo ${_q_ws}\"" 2>/dev/null) \
        || { echo "[FATAL] Cannot SSH to ${MASTER_USER}@${MASTER_HOST}"; exit 1; }
    unset _q_ws
    CONT_WS="$NATIVE_WS"
    DS_ROOT="$NATIVE_WS/vision/datasets"
    EXEC_PREFIX="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new ${MASTER_USER}@${MASTER_HOST}"
fi

if [[ $NATIVE -eq 1 ]]; then
    OUT_DIR="$SCRIPT_DIR/report_bsds_rpi"
    LOG_FILE="$OUT_DIR/analysis_bsds_rpi.log"
fi

mkdir -p "$OUT_DIR"

# ── Verify shortcut ───────────────────────────────────────────────────────────
if [[ $VERIFY -eq 1 ]]; then
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "[VERIFY] No log found at $LOG_FILE — run without --verify first"
        exit 1
    fi
    echo "[VERIFY] Log is at: $LOG_FILE"
    ORIG_ARG=""; GT_ARG=""
    [[ -d "$OUT_DIR/originals" ]] && ORIG_ARG="--orig-dir $OUT_DIR/originals"
    [[ -d "$OUT_DIR/gt" ]]        && GT_ARG="--gt-dir $OUT_DIR/gt"
    echo "  Run manually: python3 $SCRIPT_DIR/generate_report_bsds.py \\"
    echo "      --log $LOG_FILE --outdir $OUT_DIR \\"
    echo "      --recon-dir $OUT_DIR/reconstructed \\"
    echo "      --node-counts \"${NODE_COUNTS[*]}\" --thread-counts \"${THREAD_COUNTS[*]}\" \\"
    echo "      ${ORIG_ARG} ${GT_ARG}"
    exit 0
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
log "Mode    : $([ $NATIVE -eq 1 ] && echo 'Native RPi (SSH)' || echo 'Docker containers (local)')"
if [[ $NATIVE -eq 1 ]]; then
    log "Hosts   : SSH ${MASTER_USER}@${MASTER_HOST} (mpirun --host uses .local names)"
else
    log "Hosts   : Docker containers rpic_master/rpic_worker* (mpirun --host uses master/workerN)"
fi
log "Out dir : $OUT_DIR"

MAX_NODES="${NODE_COUNTS[-1]}"

# ── Alive-node tracking (native mode only) ────────────────────────────────────
ALIVE_IPS=()

probe_alive_nodes() {
    local all_users=("$MASTER_USER"  "$WORKER1_USER" "$WORKER2_USER" "$WORKER3_USER" "$WORKER4_USER" "$WORKER5_USER")
    local all_hosts=("$MASTER_HOST"  "$WORKER1_HOST" "$WORKER2_HOST" "$WORKER3_HOST" "$WORKER4_HOST" "$WORKER5_HOST")
    ALIVE_IPS=()
    for i in "${!all_hosts[@]}"; do
        local u="${all_users[$i]}" h="${all_hosts[$i]}"
        if ssh -o ConnectTimeout=5 -o BatchMode=yes "${u}@${h}" "hostname" &>/dev/null; then
            ALIVE_IPS+=("$h")
            log "  [UP]   ${u}@${h}"
        else
            log "  [DOWN] ${u}@${h} — excluded from MPI hostlists"
        fi
    done
    if [[ ${#ALIVE_IPS[@]} -lt 2 ]]; then
        die "Only ${#ALIVE_IPS[@]} node(s) reachable — need ≥ 2 for MPI. Check SSH keys (re-run rpi/setup_cluster.sh)."
    fi
    log "  Alive: ${#ALIVE_IPS[@]}/6 nodes — ${ALIVE_IPS[*]}"
}

pre_connect_workers() {
    local all_hosts=("$WORKER1_HOST" "$WORKER2_HOST" "$WORKER3_HOST" "$WORKER4_HOST" "$WORKER5_HOST")
    log "Pre-connecting SSH ControlMaster from master to alive workers..."
    for h in "${all_hosts[@]}"; do
        if [[ " ${ALIVE_IPS[*]} " == *" $h "* ]]; then
            ssh -o BatchMode=yes "${MASTER_USER}@${MASTER_HOST}" \
                "ssh -fN '$h'" \
                2>/dev/null \
                && log "  [MUX UP] master→${h}" \
                || log "  [MUX SKIP] master→${h} — already connected (non-fatal)"
        fi
    done
}

# ── Step 0: Docker + RAM check ────────────────────────────────────────────────
if [[ $NATIVE -eq 0 ]]; then
    section "STEP 0: Checking Docker and available RAM"
    command -v docker &>/dev/null || die "Docker not found on PATH"
    docker compose version &>/dev/null || docker-compose --version &>/dev/null || die "Docker Compose not found"
    log "Docker OK"
else
    section "STEP 0: Native mode (SSH)"
    log "Docker checks skipped"
fi
command -v timeout &>/dev/null || { log "[WARN] 'timeout' not found — runs will not be time-limited"; TIMEOUT_SECS=0; }

if [[ $NATIVE -eq 0 ]]; then
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
else
    log "RAM check: skipped (native mode)"
fi

# ── Cluster helpers ───────────────────────────────────────────────────────────
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

# ── ensure_datasets ───────────────────────────────────────────────────────────
ensure_datasets() {
    local LOCAL_DS="$WS/vision/datasets"
    local -a needed=("$@")

    if [[ $NATIVE -eq 1 ]]; then
        local REMOTE_DS="$NATIVE_WS/vision/datasets"
        $EXEC_PREFIX mkdir -p "$REMOTE_DS" 2>/dev/null || true
        for ds in "${needed[@]}"; do
            # Check if Pi already has enough images (and GT if BSDS500)
            local needs_sync=0
            local remote_count
            remote_count=$(ssh -o BatchMode=yes "${MASTER_USER}@${MASTER_HOST}" \
                "find '${REMOTE_DS}/${ds}/images' -type f -name '*.jpg' -size +0c 2>/dev/null | wc -l" \
                2>/dev/null || echo 0)
            if [[ "$remote_count" -lt "$BSDS_N" ]]; then
                needs_sync=1
            elif [[ "$ds" == "BSDS500" ]] && \
                 ! ssh -o BatchMode=yes "${MASTER_USER}@${MASTER_HOST}" \
                   "test -d '${REMOTE_DS}/${ds}/groundTruth_png'" 2>/dev/null; then
                log "  Dataset '$ds' on Pi is missing groundTruth_png — re-syncing..."
                needs_sync=1
            fi

            if [[ $needs_sync -eq 1 ]]; then
                log "  Dataset '$ds' missing/incomplete on Pi — pushing ${BSDS_N} images + GT from laptop..."
                if [[ -d "$LOCAL_DS/$ds" ]]; then
                    # Collect the first BSDS_N images locally (same sort order the script uses)
                    local -a local_imgs=()
                    while IFS= read -r f; do local_imgs+=("$f"); done < <(
                        find "$LOCAL_DS/$ds/images" -type f -name '*.jpg' -size +0c 2>/dev/null \
                            | sort | head -"$BSDS_N"
                    )
                    if [[ ${#local_imgs[@]} -eq 0 ]]; then
                        log "  [WARN] '$ds' has no images locally — run Docker mode first: ./run_analysis_bsds.sh --fix"
                    else
                        # Push the selected image files
                        local REMOTE_IMG_DIR="${REMOTE_DS}/${ds}/images"
                        $EXEC_PREFIX mkdir -p "$REMOTE_IMG_DIR" 2>/dev/null || true
                        rsync -az --info=progress2 \
                            "${local_imgs[@]}" \
                            "${MASTER_USER}@${MASTER_HOST}:${REMOTE_IMG_DIR}/" \
                            2>&1 | tee -a "$LOG_FILE"
                        log "  ✓ ${#local_imgs[@]} images pushed to Pi"

                        # Push the corresponding ground truth PNGs (same basenames, .png extension)
                        local LOCAL_GT_DIR="$LOCAL_DS/$ds/groundTruth_png"
                        if [[ -d "$LOCAL_GT_DIR" ]]; then
                            local REMOTE_GT_DIR="${REMOTE_DS}/${ds}/groundTruth_png"
                            $EXEC_PREFIX mkdir -p "$REMOTE_GT_DIR" 2>/dev/null || true
                            local -a gt_files=()
                            for img in "${local_imgs[@]}"; do
                                local stem
                                stem=$(basename "$img" | sed 's/\.[^.]*$//')
                                local gt
                                gt=$(find "$LOCAL_GT_DIR" \( -name "${stem}.png" -o -name "${stem}_gt.png" \) 2>/dev/null | head -1)
                                [[ -n "$gt" ]] && gt_files+=("$gt")
                            done
                            if [[ ${#gt_files[@]} -gt 0 ]]; then
                                rsync -az --info=progress2 \
                                    "${gt_files[@]}" \
                                    "${MASTER_USER}@${MASTER_HOST}:${REMOTE_GT_DIR}/" \
                                    2>&1 | tee -a "$LOG_FILE"
                                log "  ✓ ${#gt_files[@]} GT files pushed to Pi"
                            else
                                log "  [WARN] No GT files found locally for the selected images"
                            fi
                        fi
                    fi
                else
                    log "  [WARN] '$ds' also missing locally."
                    log "         Run Docker mode first to download: ./analysis/run_analysis_bsds.sh --fix"
                fi
            else
                log "  Dataset '$ds': already on Pi ✓ (${remote_count} images)"
            fi
        done
    else
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

required_binaries_ok() {
    local verbose="${1:-0}"
    local -a rel_bins=(
        "$BUILD/baselines"
        "$BUILD/sobel_arch1" "$BUILD/sobel_arch2" "$BUILD/sobel_arch3" "$BUILD/sobel_arch4"
        "$BUILD/canny_arch1" "$BUILD/canny_arch2" "$BUILD/canny_arch3" "$BUILD/canny_arch4"
        "$BUILD/log_arch1"   "$BUILD/log_arch2"   "$BUILD/log_arch3"   "$BUILD/log_arch4"
        "$BUILD/fft_arch1"   "$BUILD/fft_arch2"   "$BUILD/fft_arch3"   "$BUILD/fft_arch4"
    )
    local ok=1
    for rel in "${rel_bins[@]}"; do
        local abs
        if [[ $NATIVE -eq 1 ]]; then
            abs="${RPI_SHARED_BIN}/$(basename "${rel}")"
        else
            abs="$CONT_WS/$rel"
        fi
        if ! $EXEC_PREFIX test -s "$abs" 2>/dev/null || ! $EXEC_PREFIX test -x "$abs" 2>/dev/null; then
            [[ "$verbose" -eq 1 ]] && log "  [WARN] Missing or non-executable binary: $abs"
            ok=0
        fi
    done
    [[ $ok -eq 1 ]]
}

ensure_build_on_pi() {
    if [[ $FIX -eq 1 ]]; then
        log "  --fix set — running deploy..."
        bash "$SCRIPT_DIR/../rpi/deploy.sh" 2>&1 | tee -a "$LOG_FILE"
        if required_binaries_ok 0; then
            log "  ✓ Deploy complete"
            SKIP_BUILD=1
        else
            log "  [WARN] Deploy finished but required binaries are still missing."
            required_binaries_ok 1 || true
        fi
        return 0
    fi

    if required_binaries_ok 0; then
        log "  Binaries already on Pi ✓"
        SKIP_BUILD=1
        return 0
    fi

    log "  Binaries missing on Pi — running deploy..."
    bash "$SCRIPT_DIR/../rpi/deploy.sh" 2>&1 | tee -a "$LOG_FILE"
    if required_binaries_ok 0; then
        log "  ✓ Deploy complete"
        SKIP_BUILD=1
    else
        log "  [WARN] Deploy finished but required binaries are still missing."
        required_binaries_ok 1 || true
    fi
}

# ── hostlist_for ──────────────────────────────────────────────────────────────
hostlist_for() {
    local n="$1"
    if [[ $NATIVE -eq 1 ]]; then
        local avail="${#ALIVE_IPS[@]}"
        if [[ $n -gt $avail ]]; then
            log "  [WARN] Requested $n nodes but only $avail alive — clamping"
            n="$avail"
        fi
        local hosts=()
        for ((i=0; i<n; i++)); do hosts+=("${ALIVE_IPS[$i]}"); done
        local IFS=','; echo "${hosts[*]}"
    else
        local hosts=(master)
        for ((i=1; i<n; i++)); do hosts+=("worker$i"); done
        local IFS=','; echo "${hosts[*]}"
    fi
}

# ── runc: run an MPI command with optional timeout ────────────────────────────
runc() {
    local nodes="$1" bin="$2"; shift 2
    local args="${*:-}"
    local hostlist
    hostlist="$(hostlist_for "$nodes")"

    local bin_path
    if [[ $NATIVE -eq 1 ]]; then
        bin_path="${RPI_SHARED_BIN}/$(basename "${bin}")"
    else
        bin_path="${CONT_WS}/${bin}"
    fi

    log "  [RUN] $bin  nodes=$nodes  args=$args"

    local mpi_ssh_args=""
    [[ $NATIVE -eq 1 ]] && mpi_ssh_args="--prtemca plm_rsh_args \"-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=10 -o ServerAliveCountMax=6\""
    local cmd="cd ${CONT_WS} && \
        mpirun --allow-run-as-root --oversubscribe -n ${nodes} --host ${hostlist} \
        ${mpi_ssh_args} ${bin_path} ${args}"

    if [[ "${TIMEOUT_SECS:-0}" -gt 0 ]]; then
        if [[ $NATIVE -eq 1 ]]; then
            timeout "$TIMEOUT_SECS" \
                ssh -o BatchMode=yes "${MASTER_USER}@${MASTER_HOST}" "$cmd" \
                2>&1 | tee -a "$LOG_FILE"
        else
            timeout "$TIMEOUT_SECS" \
                $EXEC_PREFIX bash -c "$cmd" \
                2>&1 | tee -a "$LOG_FILE"
        fi
        local ec=${PIPESTATUS[0]}
        if [[ $ec -eq 124 ]]; then
            log "  [TIMEOUT] $bin exceeded ${TIMEOUT_SECS}s — skipping this run"
        elif [[ $ec -ne 0 ]]; then
            log "  [WARN] $bin exited $ec (continuing)"
        fi
    else
        if [[ $NATIVE -eq 1 ]]; then
            ssh -o BatchMode=yes "${MASTER_USER}@${MASTER_HOST}" "$cmd" \
                2>&1 | tee -a "$LOG_FILE" \
            || log "  [WARN] $bin exited non-zero (continuing)"
        else
            $EXEC_PREFIX bash -c "$cmd" \
                2>&1 | tee -a "$LOG_FILE" \
            || log "  [WARN] $bin exited non-zero (continuing)"
        fi
    fi
}

compile_binary() {
    local src_stem="$1" out_name="$2"
    log "  [COMPILE] $src_stem → $out_name"
    $EXEC_PREFIX bash -c \
        "cd ${CONT_WS} && \
         mkdir -p \$(dirname ${out_name}) && \
         mpic++ -std=c++17 -O2 -fopenmp -I./vision/shared ${src_stem}.cpp -o ${out_name} -lm" \
        2>&1 | tee -a "$LOG_FILE" \
    || log "  [WARN] Compile failed for $src_stem"
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
    log "Probing node liveness..."
    probe_alive_nodes
    pre_connect_workers
    ensure_build_on_pi
fi

# ── Step 2: BSDS500 dataset ───────────────────────────────────────────────────
section "STEP 2: BSDS500 Dataset Management (--fix=$FIX)"

ensure_datasets "BSDS500" || die "Dataset provisioning failed"

BSDS_DIR="$DS_ROOT/BSDS500/images"
BSDS_GT_DIR="$DS_ROOT/BSDS500/groundTruth_png"

mkdir -p "$WS/results"
BSDS_LIST_HOST="$WS/results/bsds_img_list.txt"
BSDS_LIST_CONT="$CONT_WS/results/bsds_img_list.txt"

if [[ $NATIVE -eq 1 ]]; then
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${MASTER_USER}@${MASTER_HOST}" \
        "find '${BSDS_DIR}' -type f -name '*.jpg' -size +0c 2>/dev/null | sort | head -${BSDS_N}" \
        > "$BSDS_LIST_HOST"
else
    $EXEC_PREFIX bash -c \
        "find '${BSDS_DIR}' -type f -name '*.jpg' -size +0c 2>/dev/null | sort | head -${BSDS_N}" \
        > "$BSDS_LIST_HOST"
fi
ACTUAL_N=$(wc -l < "$BSDS_LIST_HOST")
[[ $ACTUAL_N -eq 0 ]] && die "BSDS image list is empty"
log "  Image list: $ACTUAL_N images -> $BSDS_LIST_HOST"

# In native mode the list lives on the laptop; push it to the master Pi
# so the arch4 batch binary can read it at BSDS_LIST_CONT.
if [[ $NATIVE -eq 1 ]]; then
    ssh "${MASTER_USER}@${MASTER_HOST}" "mkdir -p $(dirname "${BSDS_LIST_CONT}")"
    scp "$BSDS_LIST_HOST" "${MASTER_USER}@${MASTER_HOST}:${BSDS_LIST_CONT}" \
        2>&1 | tee -a "$LOG_FILE" \
        && log "  ✓ Image list pushed to Pi: $BSDS_LIST_CONT" \
        || log "  [WARN] Failed to push image list to Pi"
fi

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
    $EXEC_PREFIX mkdir -p "${BSDS_OUT_CONT}/$sub" 2>/dev/null || true
done

# ── Step 3: Build ─────────────────────────────────────────────────────────────
if [[ $SKIP_BUILD -eq 0 && $FIX -eq 0 && -f "$BUILD_SENTINEL" ]]; then
    if required_binaries_ok 0; then
        log "  [AUTO] Skipping build — sentinel present ($BUILD_SENTINEL)."
        SKIP_BUILD=1
    else
        log "  [WARN] Build sentinel present but required binaries are missing — rebuilding."
        rm -f "$BUILD_SENTINEL"
    fi
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
    compile_binary "vision/log/log_arch1_farm"            "$BUILD/log_arch1"
    compile_binary "vision/log/log_arch2_pipeline"        "$BUILD/log_arch2"
    compile_binary "vision/log/log_arch3_scatter"         "$BUILD/log_arch3"
    compile_binary "vision/log/log_arch4_pipeline"        "$BUILD/log_arch4"
    compile_binary "vision/fft/fft_arch1_farm"            "$BUILD/fft_arch1"
    compile_binary "vision/fft/fft_arch2_pipeline"        "$BUILD/fft_arch2"
    compile_binary "vision/fft/fft_arch3_dist_dynamic"    "$BUILD/fft_arch3"
    compile_binary "vision/fft/fft_arch4_dist_pipeline"   "$BUILD/fft_arch4"
    log "All binaries compiled into workspace/$BUILD/"
    if required_binaries_ok 0; then
        touch "$BUILD_SENTINEL"
    else
        log "  [WARN] Not writing build sentinel — one or more binaries are missing."
        required_binaries_ok 1 || true
        rm -f "$BUILD_SENTINEL"
    fi
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

        for t in "${THREAD_COUNTS[@]}"; do
            runc 1 "$b1" "$img $t ${BSDS_OUT_CONT}/${tag}_arch1/${tag}_arch1_t${t}_${stem}.png"
        done

        runc 1 "$b2" "$img 32 ${BSDS_OUT_CONT}/${tag}_arch2/${tag}_arch2_${stem}.png"

        for n in "${NODE_COUNTS[@]}"; do
            runc "$n" "$b3" "$img ${BSDS_OUT_CONT}/${tag}_arch3/${tag}_arch3_n${n}_${stem}.png"
        done

        for n in "${NODE_COUNTS[@]}"; do
            runc "$n" "$b4" "$img ${BSDS_OUT_CONT}/${tag}_arch4/${tag}_arch4_n${n}_${stem}.png"
        done
    done < "$BSDS_LIST_HOST"

    # Arch4 batch throughput (uses image list on Pi)
    log "IMAGE: BSDS_BATCH_${tag^^}"
    runc "${NODE_COUNTS[0]}" "$b4" \
        "${BSDS_LIST_CONT} ${BSDS_OUT_CONT}/${tag}_arch4 ${ACTUAL_N}"
}

section "STEP 5: Sobel — All Architectures (BSDS500)"
run_filter_bsds sobel "$BUILD/sobel_arch1" "$BUILD/sobel_arch2" \
                      "$BUILD/sobel_arch3" "$BUILD/sobel_arch4"

section "STEP 6: Canny — All Architectures (BSDS500)"
while IFS= read -r img; do
    log "IMAGE: $img"
    stem=$(basename "$img" | sed 's/\.[^.]*$//')
    for t in "${THREAD_COUNTS[@]}"; do
        runc 1 "$BUILD/canny_arch1" "$img $t ${BSDS_OUT_CONT}/canny_arch1/canny_arch1_t${t}_${stem}.png"
    done
    runc 1 "$BUILD/canny_arch2" "$img 32 ${BSDS_OUT_CONT}/canny_arch2/canny_arch2_${stem}.png"
    for n in "${NODE_COUNTS[@]}"; do
        runc "$n" "$BUILD/canny_arch3" "$img ${BSDS_OUT_CONT}/canny_arch3/canny_arch3_n${n}_${stem}.png"
    done
done < "$BSDS_LIST_HOST"
log "IMAGE: BSDS_BATCH_CANNY"
$EXEC_PREFIX mkdir -p "${BSDS_OUT_CONT}/canny_arch4" 2>/dev/null || true
runc 4 "$BUILD/canny_arch4" "${BSDS_LIST_CONT} ${BSDS_OUT_CONT}/canny_arch4 ${ACTUAL_N}"

section "STEP 7: LoG — All Architectures (BSDS500)"
run_filter_bsds log "$BUILD/log_arch1" "$BUILD/log_arch2" \
                    "$BUILD/log_arch3" "$BUILD/log_arch4"

section "STEP 8: FFT — All Architectures (BSDS500)"
while IFS= read -r img; do
    log "IMAGE: $img"
    stem=$(basename "$img" | sed 's/\.[^.]*$//')
    for t in "${THREAD_COUNTS[@]}"; do
        runc 1 "$BUILD/fft_arch1" \
            "$img $t ${BSDS_OUT_CONT}/fft_arch1/fft_arch1_t${t}_${stem}.png"
    done
    runc 1 "$BUILD/fft_arch2" \
        "$img ${BSDS_OUT_CONT}/fft_arch2/fft_arch2_${stem}.png"
    for n in "${NODE_COUNTS[@]}"; do
        runc "$n" "$BUILD/fft_arch3" \
            "$img ${BSDS_OUT_CONT}/fft_arch3/fft_arch3_n${n}_${stem}.png"
        runc "$n" "$BUILD/fft_arch4" \
            "$img ${BSDS_OUT_CONT}/fft_arch4/fft_arch4_n${n}_${stem}.png"
    done
done < "$BSDS_LIST_HOST"

# ── Step 9: Copy reconstructed images ────────────────────────────────────────
section "STEP 9: Copying reconstructed images to $OUT_DIR"
mkdir -p "$OUT_DIR/reconstructed"
if $EXEC_PREFIX test -d "$BSDS_OUT_CONT" 2>/dev/null; then
    if [[ $NATIVE -eq 1 ]]; then
        ssh -o BatchMode=yes "${MASTER_USER}@${MASTER_HOST}" \
            "cd ${CONT_WS}/results && tar cf - bsds_out" \
            | tar xf - -C "$WS/results/" 2>/dev/null || true
    else
        $EXEC_PREFIX bash -c \
            "cd ${CONT_WS}/results && tar cf - bsds_out" \
            | tar xf - -C "$WS/results/" 2>/dev/null || true
    fi
    cp -r "$WS/results/bsds_out/." "$OUT_DIR/reconstructed/" 2>/dev/null || true
    log "  Reconstructed images → $OUT_DIR/reconstructed/"
else
    log "  [WARN] No reconstructed images found — bsds_out missing"
fi

mkdir -p "$OUT_DIR/originals"
if [[ -f "$BSDS_LIST_HOST" ]]; then
    while IFS= read -r orig_img; do
        if [[ $NATIVE -eq 1 ]]; then
            ssh -o BatchMode=yes "${MASTER_USER}@${MASTER_HOST}" \
                "cat '${orig_img}'" > "$OUT_DIR/originals/$(basename "$orig_img")" 2>/dev/null || true
        else
            $EXEC_PREFIX bash -c \
                "cat '${orig_img}'" > "$OUT_DIR/originals/$(basename "$orig_img")" 2>/dev/null || true
        fi
    done < "$BSDS_LIST_HOST"
    orig_count=$(find "$OUT_DIR/originals" \( -name "*.jpg" -o -name "*.png" \) 2>/dev/null | wc -l)
    log "  Original images → $OUT_DIR/originals/ ($orig_count files)"
else
    log "  [WARN] bsds_img_list.txt not found — originals not copied"
fi

# ── Step 10: Copy ground-truth PNGs ──────────────────────────────────────────
if [[ $GT_AVAILABLE -eq 1 ]]; then
    mkdir -p "$WS/results/gt"
    if [[ $NATIVE -eq 1 ]]; then
        ssh -o BatchMode=yes "${MASTER_USER}@${MASTER_HOST}" \
            "cd '${DS_ROOT}/BSDS500' && tar cf - groundTruth_png" \
            | tar xf - -C "$WS/results/gt/" 2>/dev/null || true
    else
        $EXEC_PREFIX bash -c \
            "cd '${DS_ROOT}/BSDS500' && tar cf - groundTruth_png" \
            | tar xf - -C "$WS/results/gt/" 2>/dev/null || true
    fi
    log "  Ground-truth PNGs → $WS/results/gt/groundTruth_png/"
fi

section "ANALYSIS COMPLETE"
log "Log file : $LOG_FILE"
log "Report   : $OUT_DIR/"
log "Finished : $(date)"
log ""
log "  To generate report run:"
log "    python3 $SCRIPT_DIR/generate_report_bsds.py \\"
log "        --log $LOG_FILE \\"
log "        --outdir $OUT_DIR \\"
log "        --recon-dir $OUT_DIR/reconstructed \\"
log "        --node-counts \"${NODE_COUNTS[*]}\" \\"
log "        --thread-counts \"${THREAD_COUNTS[*]}\""
if [[ $GT_AVAILABLE -eq 1 ]]; then
    log "        --gt-dir $WS/results/gt/groundTruth_png \\"
fi
if [[ -d "$OUT_DIR/originals" ]]; then
    log "        --orig-dir $OUT_DIR/originals"
fi
