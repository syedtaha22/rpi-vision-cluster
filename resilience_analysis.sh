#!/bin/bash
# =============================================================================
#  resilience_analysis.sh — Fault tolerance and Bully election benchmarks
#
#  Runs the four resilience scenarios (worker crash, slow node, coordinator
#  recovery, partial result) and Bully election tests, then generates a
#  dedicated report with recovery-time charts and election-latency charts.
#
#  Resilience tests use a single BSDS500 image (or a custom image).
#  Performance benchmarks → see run_analysis.sh / run_analysis_bsds.sh
#
#  Usage:
#    ./resilience_analysis.sh                        # defaults
#    ./resilience_analysis.sh --quick               # single image, fewer tests
#    ./resilience_analysis.sh --fix                 # wipe + redownload datasets, then run
#    ./resilience_analysis.sh --skip-build
#    ./resilience_analysis.sh --nodes 4             # min 3 required
#    ./resilience_analysis.sh --image /path/img.png # skip dataset check, use this image
#    ./resilience_analysis.sh --timeout 120         # per-test timeout
# =============================================================================

set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
RESILIENCE_NODES=6      # must be ≥ 3
SKIP_BUILD=0
QUICK=0
FIX=0               # --fix: wipe + redownload datasets
VERIFY=0            # --verify: skip cluster/run, just regenerate report from existing log
CUSTOM_IMAGE=""
TIMEOUT_SECS=120

# Container workspace root (fixed by docker-compose bind-mount)
CONT_WS="/home/pi/workspace"
DS_ROOT="$CONT_WS/vision/datasets"

# Resolved dynamically in Step 2
BSDS_DIR=""
COCO_IMG=""  

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)      RESILIENCE_NODES="$2";   shift 2 ;;
        --image)      CUSTOM_IMAGE="$2";       shift 2 ;;
        --skip-build) SKIP_BUILD=1;            shift   ;;
        --quick)      QUICK=1;                 shift   ;;
        --fix)        FIX=1;                   shift   ;;
        --verify)     VERIFY=1;                shift   ;;
        --timeout)    TIMEOUT_SECS="$2";       shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ $RESILIENCE_NODES -lt 3 ]] && { echo "[ERROR] --nodes must be ≥ 3"; exit 1; }

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/report_resilience"
LOG_FILE="$OUT_DIR/analysis_resilience.log"
WS="$SCRIPT_DIR/workspace"
BUILD="build"

mkdir -p "$OUT_DIR" "$WS/results/resilience"

# ── Verify shortcut: just regenerate report from existing log ─────────────────
if [[ $VERIFY -eq 1 ]]; then
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "[VERIFY] No log found at $LOG_FILE — run without --verify first"
        exit 1
    fi
    echo "[VERIFY] Re-running resilience report generator from: $LOG_FILE"
    python3 "$SCRIPT_DIR/generate_report_resilience.py" \
        --log            "$LOG_FILE" \
        --outdir         "$OUT_DIR" \
        --resilience-dir "$OUT_DIR/resilience_images"
    exit $?
fi

: > "$LOG_FILE"

# ── Logging ───────────────────────────────────────────────────────────────────
log()     { echo "$*" | tee -a "$LOG_FILE"; }
section() { log ""; log "================================================================="; log "  $*"; log "================================================================="; }
die()     { echo "[FATAL] $*" >&2; exit 1; }

log "RPI Vision Cluster — Resilience & Bully Election Analysis"
log "Started : $(date)"
log "Nodes   : $RESILIENCE_NODES"
log "Timeout : ${TIMEOUT_SECS}s per test"
log "Out dir : $OUT_DIR"

# ── Step 0: Docker check ──────────────────────────────────────────────────────
section "STEP 0: Checking Docker"
command -v docker &>/dev/null || die "Docker not found on PATH"
docker compose version &>/dev/null || docker-compose --version &>/dev/null || die "Docker Compose not found"
command -v timeout &>/dev/null || { log "[WARN] 'timeout' not found — tests will not be time-limited"; TIMEOUT_SECS=0; }
log "Docker OK"

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
    local n="$RESILIENCE_NODES"

    if master_running && master_healthy; then
        local running
        running=$(docker ps --filter "name=rpic_" --filter "status=running" \
                             --format "{{.Names}}" 2>/dev/null | wc -l)
        if [[ $running -ge $n ]]; then
            log "  Cluster already running ($running containers)"
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
section "STEP 1: Starting cluster ($RESILIENCE_NODES nodes)"
cd "$SCRIPT_DIR"
ensure_cluster

log "Verifying MPI connectivity..."
docker exec -u pi rpic_master \
    mpirun --allow-run-as-root -n "$RESILIENCE_NODES" \
    --host "$(hostlist_for "$RESILIENCE_NODES")" hostname \
    2>&1 | tee -a "$LOG_FILE" \
    && log "Cluster verification: OK" \
    || log "[WARN] Cluster verification failed — continuing anyway"

# ── Step 2: Select test image ─────────────────────────────────────────────────
section "STEP 2: Dataset management + test image selection (--fix=$FIX)"
RES_IMG=""

if [[ -n "$CUSTOM_IMAGE" ]]; then
    docker exec -u pi rpic_master test -f "$CUSTOM_IMAGE" 2>/dev/null \
        || die "Custom image not found in container: $CUSTOM_IMAGE"
    RES_IMG="$CUSTOM_IMAGE"
    log "  Using custom image: $RES_IMG"
else
    # ── Ensure BSDS500 (primary) ──────────────────────────────────────────────
    if [[ $FIX -eq 1 ]]; then
        log "  [FIX] Removing BSDS500 for redownload..."
        docker exec -u pi rpic_master rm -rf "$DS_ROOT/BSDS500" 2>/dev/null || true
    fi

    BSDS_DIR="$DS_ROOT/BSDS500/data/images/test"
    BSDS_OK=0
    if docker exec -u pi rpic_master test -d "$BSDS_DIR" 2>/dev/null && \
       [[ $(docker exec -u pi rpic_master bash -c \
           "find '$BSDS_DIR' -name '*.jpg' 2>/dev/null | wc -l") -gt 0 ]]; then
        log "  BSDS500 found at $BSDS_DIR"
        BSDS_OK=1
    else
        # Search anywhere under BSDS500
        FIRST=$(docker exec -u pi rpic_master bash -c \
            "find '$DS_ROOT/BSDS500' -name '*.jpg' 2>/dev/null | sort | head -1" \
            2>/dev/null || true)
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
    " 2>&1 | tee -a "$LOG_FILE" && BSDS_OK=1 || true

    if [[ $BSDS_OK -eq 1 ]]; then
        FIRST=$(docker exec -u pi rpic_master bash -c \
            "find '$DS_ROOT/BSDS500' -name '*.jpg' 2>/dev/null | sort | head -1" \
            2>/dev/null || true)
        [[ -n "$FIRST" ]] && BSDS_DIR=$(docker exec -u pi rpic_master dirname "$FIRST")
    fi
fi
    if [[ $BSDS_OK -eq 1 ]]; then
        RES_IMG=$(docker exec -u pi rpic_master bash -c \
            "find '$BSDS_DIR' -name '*.jpg' 2>/dev/null | sort | head -1" \
            2>/dev/null || true)
        [[ -n "$RES_IMG" ]] && log "  Using BSDS500 image: $RES_IMG"
    fi

    # ── COCO fallback ─────────────────────────────────────────────────────────
    if [[ -z "$RES_IMG" ]]; then
        log "  BSDS500 unavailable — trying COCO fallback..."
        if [[ $FIX -eq 1 ]]; then
            docker exec -u pi rpic_master rm -rf "$DS_ROOT/coco-val2017" 2>/dev/null || true
        fi
        COCO_COUNT=$(docker exec -u pi rpic_master bash -c \
            "find '$DS_ROOT/coco-val2017' -name '*.jpg' 2>/dev/null | wc -l" \
            2>/dev/null || echo 0)
        if [[ $COCO_COUNT -eq 0 ]]; then
            log "  Downloading COCO Val2017..."
            docker exec -u pi rpic_master bash -c "
mkdir -p $DS_ROOT && cd $DS_ROOT
wget -q -nc --show-progress http://images.cocodataset.org/zips/val2017.zip 2>&1 || true
unzip -q val2017.zip 2>/dev/null || true
mv val2017 coco-val2017 2>/dev/null || true
rm -f val2017.zip 2>/dev/null || true" 2>&1 | tee -a "$LOG_FILE" || true
        fi
        COCO_IMG=$(docker exec -u pi rpic_master bash -c \
            "find '$DS_ROOT/coco-val2017' -name '*.jpg' 2>/dev/null | sort | head -1" \
            2>/dev/null || true)
        if [[ -n "$COCO_IMG" ]]; then
            RES_IMG="$COCO_IMG"
            log "  Using COCO image: $RES_IMG"
        fi
    fi

    [[ -z "$RES_IMG" ]] && die "No test image available. Use --fix to redownload datasets or --image to specify one."
fi

log "RESILIENCE_IMAGE: $RES_IMG"

# ── Step 3: Build ─────────────────────────────────────────────────────────────
if [[ $SKIP_BUILD -eq 0 ]]; then
    section "STEP 3: Building resilience and bully election binaries"
    compile_binary "vision/resilience/resilience_test"  "$BUILD/resilience_test"
    compile_binary "vision/resilience/bully_election"   "$BUILD/bully_election"
    # Also build a baseline for the reference checksum
    compile_binary "vision/shared/baselines"        "$BUILD/baselines"
    log "Binaries compiled"
else
    log "Skipping build (--skip-build)"
fi

RES_CONT="/home/pi/workspace/results/resilience"
docker exec -u pi rpic_master mkdir -p "$RES_CONT" 2>/dev/null || true

# ── Step 4: Serial baseline (for checksum reference) ─────────────────────────
section "STEP 4: Serial baseline (checksum reference)"
log "IMAGE: $RES_IMG"
runc 1 "$BUILD/baselines" "$RES_IMG"

# ── Step 5: Resilience tests ──────────────────────────────────────────────────
section "STEP 5: Resilience Tests"
log "  Nodes for resilience: $RESILIENCE_NODES"
log "  Test image: $RES_IMG"

# Test 2 (slow node) first — it is non-destructive and always terminates
log ""
log "  [Resilience] Test 2: Slow Node / Straggler Detection"
runc "$RESILIENCE_NODES" "$BUILD/resilience_test" \
    "$RES_IMG $RES_CONT --test 2"

# Test 1 — worker crash (may terminate early)
log ""
log "  [Resilience] Test 1: Worker Crash + Recovery"
runc "$RESILIENCE_NODES" "$BUILD/resilience_test" \
    "$RES_IMG $RES_CONT --test 1" || true

# Test 3 — coordinator crash + re-election
log ""
log "  [Resilience] Test 3: Coordinator Recovery"
runc "$RESILIENCE_NODES" "$BUILD/resilience_test" \
    "$RES_IMG $RES_CONT --test 3" || true

# Test 4 — partial result assembly
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

# ── Step 7: Quick mode — additional scenarios ─────────────────────────────────
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

# ── Step 8: Copy resilience output images ─────────────────────────────────────
section "STEP 8: Collecting output images"
if docker exec -u pi rpic_master test -d "$RES_CONT" 2>/dev/null; then
    docker exec -u pi rpic_master bash -c \
        "cd /home/pi/workspace/results && tar cf - resilience" \
        | tar xf - -C "$WS/results/" 2>/dev/null || true
    cp -r "$WS/results/resilience/." "$OUT_DIR/resilience_images/" 2>/dev/null || true
    log "  Resilience images → $OUT_DIR/resilience_images/"
else
    log "  [WARN] No resilience output directory found"
fi
mkdir -p "$OUT_DIR/resilience_images"

# ── Step 9: Generate report ───────────────────────────────────────────────────
section "STEP 9: Generating Resilience Report"
if command -v python3 &>/dev/null; then
    python3 "$SCRIPT_DIR/generate_report_resilience.py" \
        --log              "$LOG_FILE" \
        --outdir           "$OUT_DIR" \
        --resilience-dir   "$OUT_DIR/resilience_images" \
        --nodes            "$RESILIENCE_NODES" \
        2>&1 | tee -a "$LOG_FILE"
else
    log "[WARN] python3 not found — run generate_report_resilience.py manually"
fi

section "ANALYSIS COMPLETE"
log "Log file : $LOG_FILE"
log "Report   : $OUT_DIR/"
log "Finished : $(date)"
