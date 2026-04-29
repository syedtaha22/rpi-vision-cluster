#!/usr/bin/env bash
# =============================================================================
#  resilience_analysis.sh — Fault tolerance and Bully election benchmarks
#
#  Runs the four resilience scenarios (worker crash, slow node, coordinator
#  recovery, partial result) and Bully election tests.
#  Performance benchmarks → see run_analysis.sh / run_analysis_bsds.sh
#
#  Usage:
#    ./resilience_analysis.sh                        # defaults
#    ./resilience_analysis.sh --quick               # single image, fewer tests
#    ./resilience_analysis.sh --native              # run on physical Pis (SSH)
#    ./resilience_analysis.sh --fix                 # wipe + redownload datasets, then run
#    ./resilience_analysis.sh --skip-build
#    ./resilience_analysis.sh --nodes 4             # min 3 required
#    ./resilience_analysis.sh --image /path/img.png # skip dataset check, use this image
#    ./resilience_analysis.sh --timeout 120         # per-test timeout
#
#  After completion, run the report generator manually:
#    python3 analysis/generate_report_resilience.py \
#        --log analysis/report_resilience/analysis_resilience.log \
#        --outdir analysis/report_resilience \
#        --resilience-dir analysis/report_resilience/resilience_images \
#        --nodes <N>
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SENTINEL="$SCRIPT_DIR/.build_ok_resilience"

# ── Defaults ──────────────────────────────────────────────────────────────────
RESILIENCE_NODES=6
SKIP_BUILD=0
QUICK=0
FIX=0
VERIFY=0
NATIVE=0
CUSTOM_IMAGE=""
TIMEOUT_SECS=120

CONT_WS="/home/pi/workspace"
DS_ROOT="$CONT_WS/vision/datasets"

BSDS_DIR=""

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)      RESILIENCE_NODES="$2";   shift 2 ;;
        --image)      CUSTOM_IMAGE="$2";       shift 2 ;;
        --skip-build) SKIP_BUILD=1;            shift   ;;
        --quick)      QUICK=1;                 shift   ;;
        --fix)        FIX=1;                   shift   ;;
        --verify)     VERIFY=1;                shift   ;;
        --native)     NATIVE=1;                shift   ;;
        --timeout)    TIMEOUT_SECS="$2";       shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ $FIX -eq 1 ]] && rm -f "$BUILD_SENTINEL"
[[ $RESILIENCE_NODES -lt 3 ]] && { echo "[ERROR] --nodes must be ≥ 3"; exit 1; }

# ── Paths ─────────────────────────────────────────────────────────────────────
OUT_DIR="$SCRIPT_DIR/report_resilience"
LOG_FILE="$OUT_DIR/analysis_resilience.log"
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
    NATIVE_WS=$(ssh "${MASTER_USER}@${MASTER_IP}" "bash -lc \"echo ${_q_ws}\"" 2>/dev/null) \
        || { echo "[FATAL] Cannot SSH to ${MASTER_USER}@${MASTER_IP}"; exit 1; }
    unset _q_ws
    CONT_WS="$NATIVE_WS"
    DS_ROOT="$NATIVE_WS/vision/datasets"
    EXEC_PREFIX="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new ${MASTER_USER}@${MASTER_IP}"
fi

mkdir -p "$OUT_DIR" "$WS/results/resilience"

# ── Verify shortcut ───────────────────────────────────────────────────────────
if [[ $VERIFY -eq 1 ]]; then
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "[VERIFY] No log found at $LOG_FILE — run without --verify first"
        exit 1
    fi
    echo "[VERIFY] Log is at: $LOG_FILE"
    echo "  Run manually: python3 $SCRIPT_DIR/generate_report_resilience.py \\"
    echo "      --log $LOG_FILE --outdir $OUT_DIR \\"
    echo "      --resilience-dir $OUT_DIR/resilience_images \\"
    echo "      --nodes $RESILIENCE_NODES"
    exit 0
fi

: > "$LOG_FILE"

# ── Logging ───────────────────────────────────────────────────────────────────
log()     { echo "$*" | tee -a "$LOG_FILE"; }
section() { log ""; log "================================================================="; log "  $*"; log "================================================================="; }
die()     { echo "[FATAL] $*" >&2; exit 1; }

log "RPI Vision Cluster — Resilience & Bully Election Analysis"
log "Started   : $(date)"
log "Nodes     : $RESILIENCE_NODES"
log "Timeout   : ${TIMEOUT_SECS}s per test"
log "Mode      : $([ $NATIVE -eq 1 ] && echo 'Native RPi (SSH)' || echo 'Docker containers (local)')"
if [[ $NATIVE -eq 1 ]]; then
    log "Hosts     : SSH ${MASTER_USER}@${MASTER_IP} (mpirun --host uses IPs)"
else
    log "Hosts     : Docker containers rpic_master/rpic_worker* (mpirun --host uses master/workerN)"
fi
log "Out dir   : $OUT_DIR"

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
command -v timeout &>/dev/null || { log "[WARN] 'timeout' not found — tests will not be time-limited"; TIMEOUT_SECS=0; }

if [[ $NATIVE -eq 0 ]]; then
    if command -v free &>/dev/null; then
        FREE_MB=$(free -m | awk '/^Mem:/{print $7}')
        NEEDED_MB=$(( (RESILIENCE_NODES + 1) * 1024 ))
        log "RAM check: ${FREE_MB}MB free, ${NEEDED_MB}MB needed for ${RESILIENCE_NODES} nodes"
        if [[ $FREE_MB -lt $NEEDED_MB ]]; then
            log "[WARN] Low available RAM — expect swap-induced slowdowns."
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
master_healthy() { docker exec -u pi rpic_master echo "ok" &>/dev/null; }
images_exist()   { docker image inspect pdc_project-master &>/dev/null; }

ensure_cluster() {
    local n="$RESILIENCE_NODES"
    if master_running && master_healthy; then
        local running
        running=$(docker ps --filter "name=rpic_" --filter "status=running" \
                     --format "{{.Names}}" 2>/dev/null | wc -l)
        if [[ $running -ge $n ]]; then
            log "  Cluster already running ($running containers)"; return 0
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
        log "  No images — building (~5-10 min first run)..."
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

# ── ensure_datasets ───────────────────────────────────────────────────────────
ensure_datasets() {
    local LOCAL_DS="$WS/vision/datasets"
    local -a needed=("$@")

    if [[ $NATIVE -eq 1 ]]; then
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
                    log "         Run Docker mode first to download: ./analysis/resilience_analysis.sh --fix"
                fi
            else
                log "  Dataset '$ds': already on Pi ✓"
            fi
        done
    else
        local DL_FLAGS=""
        [[ $FIX -eq 1 ]] && DL_FLAGS="--fix"
        local needed_flags=""
        for ds in "${needed[@]}"; do
            case "$ds" in
                BSDS500) needed_flags="$needed_flags --bsds 1" ;;
            esac
        done
        $EXEC_PREFIX bash "$CONT_WS/vision/shared/download_datasets.sh" \
            $DL_FLAGS $needed_flags 2>&1 | tee -a "$LOG_FILE"
    fi
}

required_binaries_ok() {
    local verbose="${1:-0}"
    local -a rel_bins=(
        "$BUILD/resilience_test"
        "$BUILD/bully_election"
        "$BUILD/baselines"
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

    local cmd="cd ${CONT_WS} && \
        mpirun --allow-run-as-root -n ${nodes} --host ${hostlist} \
        ${bin_path} ${args}"

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
        "cd ${CONT_WS} && \
         mkdir -p \$(dirname ${out_name}) && \
         mpic++ -std=c++17 -O2 -fopenmp -I./vision/shared ${src_stem}.cpp -o ${out_name} -lm" \
        2>&1 | tee -a "$LOG_FILE" \
    || log "  [WARN] Compile failed for $src_stem"
}

# ── Step 1: Start cluster / Prepare Pi ───────────────────────────────────────
if [[ $NATIVE -eq 0 ]]; then
    section "STEP 1: Starting cluster (${RESILIENCE_NODES} nodes)"
    cd "$SCRIPT_DIR"
    ensure_cluster
    log "Verifying MPI connectivity..."
    $EXEC_PREFIX mpirun --allow-run-as-root -n "$RESILIENCE_NODES" \
        --host "$(hostlist_for "$RESILIENCE_NODES")" hostname \
        2>&1 | tee -a "$LOG_FILE" \
        && log "Cluster verification: OK" \
        || log "[WARN] Cluster verification failed — continuing anyway"
else
    section "STEP 1: Preparing RPi cluster (${RESILIENCE_NODES} nodes, SSH)"
    ensure_build_on_pi
fi

# ── Step 2: Select test image ─────────────────────────────────────────────────
section "STEP 2: Dataset management + test image selection (--fix=$FIX)"
RES_IMG=""

if [[ -n "$CUSTOM_IMAGE" ]]; then
    $EXEC_PREFIX test -s "$CUSTOM_IMAGE" 2>/dev/null \
        || die "Custom image not found in container: $CUSTOM_IMAGE"
    RES_IMG="$CUSTOM_IMAGE"
    log "  Using custom image: $RES_IMG"
else
    ensure_datasets "BSDS500" || die "Dataset provisioning failed"

    BSDS_DIR="$DS_ROOT/BSDS500/images"
    RES_IMG=$($EXEC_PREFIX bash -c \
        "find '${BSDS_DIR}' -type f -name '*.jpg' -size +0c 2>/dev/null | sort | head -1" \
        2>/dev/null || true)

    if [[ -n "$RES_IMG" ]]; then
        log "  Using BSDS500 image: $RES_IMG"
    else
        log "  [WARN] BSDS500 unavailable — no test image found"
    fi

    [[ -z "$RES_IMG" ]] && die "No test image available. Use --fix or --image."
fi

log "RESILIENCE_IMAGE: $RES_IMG"

# ── Step 3: Build ─────────────────────────────────────────────────────────────
if [[ $SKIP_BUILD -eq 0 && $FIX -eq 0 && -f "$BUILD_SENTINEL" ]]; then
    if required_binaries_ok 0; then
        log "  [AUTO] Skipping build — sentinel present ($BUILD_SENTINEL)."
        SKIP_BUILD=1
    else
        log "  [WARN] Build sentinel present but binaries missing — rebuilding."
        rm -f "$BUILD_SENTINEL"
    fi
fi

if [[ $SKIP_BUILD -eq 0 ]]; then
    section "STEP 3: Building resilience and bully election binaries"
    compile_binary "vision/resilience/resilience_test"  "$BUILD/resilience_test"
    compile_binary "vision/resilience/bully_election"   "$BUILD/bully_election"
    compile_binary "vision/shared/baselines"            "$BUILD/baselines"
    log "Binaries compiled"
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

RES_CONT="$CONT_WS/results/resilience"
$EXEC_PREFIX mkdir -p "$RES_CONT" 2>/dev/null || true

# ── Step 4: Serial baseline (checksum reference) ─────────────────────────────
section "STEP 4: Serial baseline (checksum reference)"
log "IMAGE: $RES_IMG"
runc 1 "$BUILD/baselines" "$RES_IMG"

# ── Step 5: Resilience tests ──────────────────────────────────────────────────
section "STEP 5: Resilience Tests"
log "  Nodes for resilience: $RESILIENCE_NODES"
log "  Test image: $RES_IMG"

log ""
log "  [Resilience] Test 2: Slow Node / Straggler Detection"
runc "$RESILIENCE_NODES" "$BUILD/resilience_test" \
    "$RES_IMG $RES_CONT --test 2"

log ""
log "  [Resilience] Test 1: Worker Crash + Recovery"
runc "$RESILIENCE_NODES" "$BUILD/resilience_test" \
    "$RES_IMG $RES_CONT --test 1" || true

log ""
log "  [Resilience] Test 3: Coordinator Recovery"
runc "$RESILIENCE_NODES" "$BUILD/resilience_test" \
    "$RES_IMG $RES_CONT --test 3" || true

log ""
log "  [Resilience] Test 4: Partial Result Assembly"
runc "$RESILIENCE_NODES" "$BUILD/resilience_test" \
    "$RES_IMG $RES_CONT --test 4" || true

# ── Step 6: Bully election tests ──────────────────────────────────────────────
section "STEP 6: Bully Algorithm Leader Election"
log "BULLY_ELECTION_START"

log "  [Bully] Scenario 1: Normal election — no failures ($RESILIENCE_NODES nodes)"
runc "$RESILIENCE_NODES" "$BUILD/bully_election" || true

log "  [Bully] Scenario 2: Election with rank $((RESILIENCE_NODES-1)) failed"
runc "$RESILIENCE_NODES" "$BUILD/bully_election" \
    "--fail $((RESILIENCE_NODES-1))" || true

if [[ $RESILIENCE_NODES -ge 4 ]]; then
    log "  [Bully] Scenario 3: Election with ranks $((RESILIENCE_NODES-2)),$((RESILIENCE_NODES-1)) failed"
    runc "$RESILIENCE_NODES" "$BUILD/bully_election" \
        "--fail $((RESILIENCE_NODES-2)),$((RESILIENCE_NODES-1))" || true
fi

log "BULLY_ELECTION_END"

# ── Step 7: Extended tests (multi-node sweep) ─────────────────────────────────
if [[ $QUICK -eq 0 ]]; then
    section "STEP 7: Extended Tests (multi-node sweep)"
    for n in 3 4; do
        if [[ $n -le $RESILIENCE_NODES ]]; then
            log "IMAGE: $RES_IMG"
            log "  [Resilience] All tests at $n nodes"
            for t in 1 2 3 4; do
                runc "$n" "$BUILD/resilience_test" \
                    "$RES_IMG $RES_CONT --test $t" || true
            done
        fi
    done
fi

# ── Step 8: Copy reconstructed resilience images ──────────────────────────────
section "STEP 8: Copying resilience results to $OUT_DIR"
mkdir -p "$OUT_DIR/resilience_images"
if $EXEC_PREFIX test -d "$RES_CONT" 2>/dev/null; then
    $EXEC_PREFIX bash -c \
        "cd ${CONT_WS}/results && tar cf - resilience" \
        | tar xf - -C "$WS/results/" 2>/dev/null || true
    cp -r "$WS/results/resilience/." "$OUT_DIR/resilience_images/" 2>/dev/null || true
    log "  Resilience images → $OUT_DIR/resilience_images/"
else
    log "  [WARN] No resilience output directory found"
fi

section "ANALYSIS COMPLETE"
log "Log file : $LOG_FILE"
log "Report   : $OUT_DIR/"
log "Finished : $(date)"
log ""
log "  To generate report run:"
log "    python3 $SCRIPT_DIR/generate_report_resilience.py \\"
log "        --log $LOG_FILE \\"
log "        --outdir $OUT_DIR \\"
log "        --resilience-dir $OUT_DIR/resilience_images \\"
log "        --nodes $RESILIENCE_NODES"
