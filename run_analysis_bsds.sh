#!/bin/bash
# =============================================================================
#  run_analysis_bsds.sh — BSDS500-focused automated analysis
#
#  Evaluates ALL four architectures (Sobel, Canny, LoG, FFT) exclusively on
#  the BSDS500 test set.  Keeps SIO efficiency, Brent's law and Amdahl
#  calculations identical to run_analysis.sh.
#
#  All outputs land in a single directory: $SCRIPT_DIR/report_bsds/
#
#  Usage:
#    ./run_analysis_bsds.sh                        # defaults (10 images)
#    ./run_analysis_bsds.sh --quick                # 3 images, fewer configs
#    ./run_analysis_bsds.sh --skip-build
#    ./run_analysis_bsds.sh --nodes 2,4 --threads 1,4
#    ./run_analysis_bsds.sh --n-images 50
# =============================================================================

set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
NODE_COUNTS=(2 4 6)
THREAD_COUNTS=(1 2 4)
SKIP_BUILD=0
QUICK=0
BSDS_N=10       # number of BSDS500 images to evaluate

BSDS_DIR="/home/pi/workspace/vision/datasets/BSDS500/images/test"
BSDS_GT_DIR="/home/pi/workspace/vision/datasets/BSDS500/groundTruth/test"

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)      IFS=',' read -ra NODE_COUNTS    <<< "$2"; shift 2 ;;
        --threads)    IFS=',' read -ra THREAD_COUNTS  <<< "$2"; shift 2 ;;
        --n-images)   BSDS_N="$2";                              shift 2 ;;
        --skip-build) SKIP_BUILD=1;                             shift   ;;
        --quick)      QUICK=1;                                  shift   ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ $QUICK -eq 1 ]]; then
    NODE_COUNTS=(2 4)
    THREAD_COUNTS=(1 2)
    BSDS_N=3
fi

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/report_bsds"
LOG_FILE="$OUT_DIR/analysis_bsds.log"
WS="$SCRIPT_DIR/workspace"
BUILD="build"

mkdir -p "$OUT_DIR"
: > "$LOG_FILE"

# ── Logging ───────────────────────────────────────────────────────────────────
log()     { echo "$*" | tee -a "$LOG_FILE"; }
section() { log ""; log "================================================================="; log "  $*"; log "================================================================="; }
die()     { echo "[FATAL] $*" >&2; exit 1; }

log "RPI Vision Cluster — BSDS500 Performance Analysis"
log "Started : $(date)"
log "Nodes   : ${NODE_COUNTS[*]}"
log "Threads : ${THREAD_COUNTS[*]}"
log "N images: $BSDS_N"
log "Out dir : $OUT_DIR"

# ── Step 0: Docker check ──────────────────────────────────────────────────────
section "STEP 0: Checking Docker"
command -v docker &>/dev/null || die "Docker not found on PATH"
docker compose version &>/dev/null || docker-compose --version &>/dev/null || die "Docker Compose not found"
log "Docker OK"

# ── ARM64 Emulation ───────────────────────────────────────────────────────────
# Required on x86_64 hosts — the cluster images are built for linux/arm64
# (simulating Raspberry Pi hardware). QEMU binfmt_misc handles the translation.
section "STEP 0b: Enabling ARM64 (QEMU) Emulation"
HOST_ARCH="$(uname -m)"
log "  Host architecture: $HOST_ARCH"

if [[ "$HOST_ARCH" == "x86_64" || "$HOST_ARCH" == "amd64" ]]; then
    if [[ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] && \
       grep -q "enabled" /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
        log "  ARM64 emulation already enabled — skipping"
    else
        log "  Enabling ARM64 emulation via tonistiigi/binfmt..."
        docker run --privileged --rm tonistiigi/binfmt --install all \
            2>&1 | tee -a "$LOG_FILE" \
            || die "Failed to enable ARM64 emulation. Try: docker run --privileged --rm tonistiigi/binfmt --install all"
        log "  ARM64 emulation enabled"
    fi
else
    log "  Native ARM64 host — no emulation needed"
fi

# ── Cluster helpers ───────────────────────────────────────────────────────────
MAX_NODES="${NODE_COUNTS[-1]}"

master_running() {
    # Check the container exists AND is actually running (not just created/exited)
    local status
    status=$(docker inspect --format '{{.State.Status}}' rpic_master 2>/dev/null)
    [[ "$status" == "running" ]]
}

master_healthy() {
    # Confirm we can actually exec into the master (guards against arm64 exec errors)
    docker exec -u pi rpic_master echo "ok" &>/dev/null
}

images_exist() {
    # Returns true only if the master image already exists locally
    docker image inspect pdc_project-master &>/dev/null
}

ensure_cluster() {
    local n="$MAX_NODES"

    # ── Best case: cluster is already up and healthy ───────────────────────
    if master_running && master_healthy; then
        local running
        running=$(docker ps --filter "name=rpic_" --filter "status=running" \
                             --format "{{.Names}}" 2>/dev/null | wc -l)
        if [[ $running -ge $n ]]; then
            log "  Cluster already running and healthy ($running containers) — skipping start"
            return 0
        fi
        log "  Master healthy but only $running/$n containers up — starting missing workers..."
        cd "$SCRIPT_DIR"
        docker compose --profile "${n}-nodes" up -d \
            2>&1 | tee -a "$LOG_FILE"
        sleep 3
        log "  Cluster ready ($n nodes)"
        return 0
    fi

    cd "$SCRIPT_DIR"

    # ── Images exist but containers stopped/crashed ────────────────────────
    # Test whether the existing image is actually executable (arm64 via QEMU).
    # We do this by running a trivial command in a throwaway container.
    if images_exist; then
        log "  Images exist — testing if they are executable (arm64 check)..."
        if docker run --rm --platform linux/arm64 pdc_project-master \
               /bin/echo "arm64-ok" &>/dev/null; then
            log "  Images are healthy — starting containers (no rebuild needed)"
            docker compose \
                --profile 2-nodes --profile 3-nodes --profile 4-nodes \
                --profile 5-nodes --profile 6-nodes \
                down --remove-orphans 2>&1 | tail -3 | tee -a "$LOG_FILE"
            docker compose --profile "${n}-nodes" up -d \
                2>&1 | tee -a "$LOG_FILE" \
                || die "docker compose up failed"
        else
            log "  Images exist but are NOT executable (wrong platform) — rebuilding..."
            docker compose \
                --profile 2-nodes --profile 3-nodes --profile 4-nodes \
                --profile 5-nodes --profile 6-nodes \
                down --remove-orphans 2>&1 | tail -3 | tee -a "$LOG_FILE"
            docker rmi pdc_project-master pdc_project-worker1 pdc_project-worker2 \
                       pdc_project-worker3 pdc_project-worker4 pdc_project-worker5 \
                       2>/dev/null || true
            docker compose --profile "${n}-nodes" up -d --build \
                2>&1 | tee -a "$LOG_FILE" \
                || die "docker compose up --build failed"
        fi
    else
        # ── No images at all — first run, must build ───────────────────────
        log "  No images found — building from scratch (this takes ~5-10 min on first run)..."
        docker compose --profile "${n}-nodes" up -d --build \
            2>&1 | tee -a "$LOG_FILE" \
            || die "docker compose up --build failed"
    fi

    log "  Waiting for rpic_master to become ready..."
    local retries=0
    until master_healthy || [[ $retries -ge 40 ]]; do
        sleep 3
        retries=$((retries + 1))
        log "  ... waiting ($((retries * 3))s)"
    done

    master_healthy || die "rpic_master did not become healthy after $((40 * 3))s. \
Run: docker logs rpic_master"

    sleep 3
    log "  Cluster ready ($n nodes)"
}

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

# ── Step 2: BSDS500 dataset ───────────────────────────────────────────────────
section "STEP 2: Checking / Downloading BSDS500"
BSDS_OK=0

if docker exec -u pi rpic_master test -d "$BSDS_DIR" 2>/dev/null && \
   [[ $(docker exec -u pi rpic_master bash -c "ls '$BSDS_DIR'/*.jpg 2>/dev/null | wc -l") -gt 0 ]]; then
    log "  BSDS500 found at $BSDS_DIR"
    BSDS_OK=1
elif docker exec -u pi rpic_master test -d "/home/pi/workspace/vision/datasets/BSDS500/images" 2>/dev/null; then
    log "  BSDS500 found but 'test' split missing — checking for any images..."
    FIRST=$(docker exec -u pi rpic_master bash -c \
        "find /home/pi/workspace/vision/datasets/BSDS500/images -name '*.jpg' | head -1")
    if [[ -n "$FIRST" ]]; then
        BSDS_DIR=$(docker exec -u pi rpic_master bash -c \
            "find /home/pi/workspace/vision/datasets/BSDS500/images -name '*.jpg' | head -1 | xargs dirname")
        log "  Using images from: $BSDS_DIR"
        BSDS_OK=1
    else
        log "  [WARN] No .jpg files found under BSDS500/images"
        BSDS_OK=0
    fi
else
    log "  BSDS500 not found — attempting download via kagglehub..."
    docker exec -u pi rpic_master bash -c \
        "pip install -q kagglehub && \
         python3 -c \"
import kagglehub, shutil, os
p = kagglehub.dataset_download('balraj98/berkeley-segmentation-dataset-500-bsds500')
dst = '/home/pi/workspace/vision/datasets/BSDS500'
if not os.path.exists(dst):
    shutil.copytree(p, dst)
    print('BSDS500 downloaded to', dst)
else:
    print('BSDS500 already at', dst)
\"" 2>&1 | tee -a "$LOG_FILE" \
    && BSDS_OK=1 \
    || die "BSDS500 download failed — cannot continue without dataset"
fi

# Build image list
mkdir -p "$WS/results"
BSDS_LIST_HOST="$WS/results/bsds_img_list.txt"
BSDS_LIST_CONT="/home/pi/workspace/results/bsds_img_list.txt"

docker exec -u pi rpic_master bash -c \
    "find '$BSDS_DIR' -name '*.jpg' | sort | head -${BSDS_N}" \
    > "$BSDS_LIST_HOST"
ACTUAL_N=$(wc -l < "$BSDS_LIST_HOST")
[[ $ACTUAL_N -eq 0 ]] && die "BSDS image list is empty"
log "  Image list: $ACTUAL_N images → $BSDS_LIST_HOST"

# Container-side output directories
BSDS_OUT_CONT="/home/pi/workspace/results/bsds_out"
for sub in sobel_arch1 sobel_arch2 sobel_arch3 sobel_arch4 \
           canny_arch1 canny_arch2 canny_arch3 canny_arch4 \
           log_arch1  log_arch2  log_arch3  log_arch4  \
           fft_arch1  fft_arch2  fft_arch3  fft_arch4; do
    docker exec -u pi rpic_master mkdir -p "$BSDS_OUT_CONT/$sub" 2>/dev/null || true
done

# ── Compile helper ─────────────────────────────────────────────────────────────
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

# ── Run helper ─────────────────────────────────────────────────────────────────
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

# ── Step 3: Build ─────────────────────────────────────────────────────────────
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

# =============================================================================
#  STEP 4 — Serial baselines on every BSDS image
# =============================================================================
section "STEP 4: Serial Baselines (BSDS500)"

while IFS= read -r img; do
    log "IMAGE: $img"
    runc 1 "$BUILD/baselines" "$img"
done < "$BSDS_LIST_HOST"

# =============================================================================
#  STEP 5-8 — All four architectures, all four filters
# =============================================================================

run_filter_bsds() {
    local tag="$1" b1="$2" b2="$3" b3="$4" b4="$5"

    while IFS= read -r img; do
        log "IMAGE: $img"
        local stem
        stem=$(basename "$img" | sed 's/\.[^.]*$//')

        # Arch1: OMP Farm  <img> <threads> <output.png>
        for t in "${THREAD_COUNTS[@]}"; do
            runc 1 "$b1" "$img $t $BSDS_OUT_CONT/${tag}_arch1/${tag}_arch1_t${t}_${stem}.png"
        done

        # Arch2: OMP Pipeline  <img> <chunk_rows> <output.png>
        runc 1 "$b2" "$img 32 $BSDS_OUT_CONT/${tag}_arch2/${tag}_arch2_${stem}.png"

        # Arch3: MPI Scatter  <img> <output.png>
        for n in "${NODE_COUNTS[@]}"; do
            runc "$n" "$b3" "$img $BSDS_OUT_CONT/${tag}_arch3/${tag}_arch3_n${n}_${stem}.png"
        done

        # Arch4: MPI Pipeline single-image  <img> <output.png>
        for n in "${NODE_COUNTS[@]}"; do
            runc "$n" "$b4" "$img $BSDS_OUT_CONT/${tag}_arch4/${tag}_arch4_n${n}_${stem}.png"
        done

    done < "$BSDS_LIST_HOST"

    # Arch4 batch mode (all images, pipeline throughput)
    log "  [BATCH] $b4  n=${NODE_COUNTS[0]}  N=$ACTUAL_N"
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

# Canny Arch4 — batch only
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

# =============================================================================
#  STEP 9 — Resilience tests
# =============================================================================
section "STEP 9: Resilience Tests"

RESILIENCE_NODES=$MAX_NODES
[[ $RESILIENCE_NODES -lt 3 ]] && RESILIENCE_NODES=3

RES_CONT="/home/pi/workspace/results/resilience"
docker exec -u pi rpic_master mkdir -p "$RES_CONT" 2>/dev/null || true
mkdir -p "$WS/results/resilience"

RESILIENCE_IMG=$(head -1 "$BSDS_LIST_HOST")
if [[ -z "$RESILIENCE_IMG" ]]; then
    log "  [WARN] No BSDS image available for resilience tests — skipping"
else
    log "  Resilience image: $RESILIENCE_IMG"
    log "RESILIENCE_IMAGE: $RESILIENCE_IMG"

    log "  [Resilience] Test 2: Slow Node"
    runc "$RESILIENCE_NODES" "$BUILD/resilience_test" \
        "$RESILIENCE_IMG $RES_CONT --test 2"

    log "  [Resilience] Test 1: Worker Crash"
    runc "$RESILIENCE_NODES" "$BUILD/resilience_test" \
        "$RESILIENCE_IMG $RES_CONT --test 1" || true

    log "  [Resilience] Test 3: Coordinator Recovery"
    runc "$RESILIENCE_NODES" "$BUILD/resilience_test" \
        "$RESILIENCE_IMG $RES_CONT --test 3" || true

    log "  [Resilience] Test 4: Partial Result"
    runc "$RESILIENCE_NODES" "$BUILD/resilience_test" \
        "$RESILIENCE_IMG $RES_CONT --test 4" || true
fi

# =============================================================================
#  STEP 10 — Bully Election tests
# =============================================================================
section "STEP 10: Bully Election Tests"

compile_binary "vision/bully_election" "$BUILD/bully_election"

log "BULLY_ELECTION_START"

log "  [Bully] Normal election (${MAX_NODES} nodes, no failures)"
runc "$MAX_NODES" "$BUILD/bully_election" || true

log "  [Bully] Election with rank $((MAX_NODES-1)) failed"
runc "$MAX_NODES" "$BUILD/bully_election" "--fail $((MAX_NODES-1))" || true

if [[ $MAX_NODES -ge 4 ]]; then
    log "  [Bully] Election with ranks $((MAX_NODES-1)),$((MAX_NODES-2)) failed"
    runc "$MAX_NODES" "$BUILD/bully_election" \
        "--fail $((MAX_NODES-2)),$((MAX_NODES-1))" || true
fi

log "BULLY_ELECTION_END"

# =============================================================================
#  STEP 11 — Copy all reconstructed images to report_bsds/
# =============================================================================
section "STEP 11: Copying reconstructed images to $OUT_DIR"
mkdir -p "$OUT_DIR/reconstructed" "$OUT_DIR/resilience"
if [[ -d "$WS/results/bsds_out" ]]; then
    cp -r "$WS/results/bsds_out/." "$OUT_DIR/reconstructed/"
    log "  Reconstructed images → $OUT_DIR/reconstructed/"
else
    log "  [WARN] $WS/results/bsds_out not found — nothing to copy"
fi
if [[ -d "$WS/results/resilience" ]]; then
    cp -r "$WS/results/resilience/." "$OUT_DIR/resilience/"
    log "  Resilience images → $OUT_DIR/resilience/"
fi

# =============================================================================
#  STEP 12 — Generate report
# =============================================================================
section "STEP 12: Generating BSDS500 Report"
if command -v python3 &>/dev/null; then
    python3 "$SCRIPT_DIR/generate_report_bsds.py" \
        --log            "$LOG_FILE" \
        --outdir         "$OUT_DIR" \
        --recon-dir      "$OUT_DIR/reconstructed" \
        --resilience-dir "$OUT_DIR/resilience" \
        --gt-dir         "$WS/vision/datasets/BSDS500/groundTruth/test" \
        --node-counts    "${NODE_COUNTS[*]}" \
        --thread-counts  "${THREAD_COUNTS[*]}" \
        2>&1 | tee -a "$LOG_FILE"
else
    log "[WARN] python3 not found — run generate_report_bsds.py manually"
fi

section "ANALYSIS COMPLETE"
log "Log file : $LOG_FILE"
log "Report   : $OUT_DIR/"
log "Finished : $(date)"