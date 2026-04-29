#!/usr/bin/env bash
# =============================================================================
# run_vision.sh — Run a vision pipeline on the RPI cluster
# =============================================================================
# Runs any combination of filter × architecture on N nodes.
#
# Usage:
#   bash rpi/run_vision.sh --filter <sobel|canny|log|fft> \
#                          --arch <1|2|3|4> \
#                          --nodes <2-6> \
#                          --image <path/to/image.jpg> \
#                          [--output-dir <local/dir>]
#
# Examples:
#   bash rpi/run_vision.sh --filter sobel --arch 3 --nodes 6 --image cat.jpg
#   bash rpi/run_vision.sh --filter fft   --arch 4 --nodes 4 --image /tmp/img.jpg
#
# Architecture reference:
#   arch1 = OpenMP Farm
#   arch2 = OpenMP Pipeline
#   arch3 = MPI Scatter-Gather
#   arch4 = MPI Distributed Pipeline
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[run_vision]${NC} $*"; }
success() { echo -e "${GREEN}[run_vision] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[run_vision] ⚠${NC} $*"; }
die()     { echo -e "${RED}[run_vision] ✗${NC} $*" >&2; exit 1; }

# ── Parse arguments ───────────────────────────────────────────────────────────
FILTER=""; ARCH=""; NODES=""; IMAGE=""; OUTPUT_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --filter)     FILTER="$2";     shift 2 ;;
        --arch)       ARCH="$2";       shift 2 ;;
        --nodes)      NODES="$2";      shift 2 ;;
        --image)      IMAGE="$2";      shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "$FILTER" ]] || die "--filter is required (sobel|canny|log|fft)"
[[ -n "$ARCH"   ]] || die "--arch is required (1|2|3|4)"
[[ -n "$NODES"  ]] || die "--nodes is required (2-6)"
[[ -n "$IMAGE"  ]] || die "--image is required (path to input image)"

# Validate
[[ "$FILTER" =~ ^(sobel|canny|log|fft)$ ]] || die "Invalid filter: $FILTER. Must be sobel|canny|log|fft"
[[ "$ARCH"   =~ ^[1-4]$                 ]] || die "Invalid arch: $ARCH. Must be 1-4"
[[ "$NODES"  =~ ^[2-6]$                 ]] || die "Invalid nodes: $NODES. Must be 2-6"
[[ -f "$IMAGE" ]]                          || die "Image not found: $IMAGE"

[[ -f "$CONFIG" ]] || die "config.env not found. Run setup_cluster.sh first."
# shellcheck source=/dev/null
source "$CONFIG"

ALL_USERS=("$MASTER_USER"  "$WORKER1_USER" "$WORKER2_USER" "$WORKER3_USER" "$WORKER4_USER" "$WORKER5_USER")
ALL_IPS=(  "$MASTER_IP"    "$WORKER1_IP"   "$WORKER2_IP"   "$WORKER3_IP"   "$WORKER4_IP"   "$WORKER5_IP")

# Workspace path on the Pis — driven by config.env
RPI_WORKSPACE_DIR="${RPI_WORKSPACE_DIR:-~/Desktop/rpi-vision-cluster/workspace}"

# Expand on remote master explicitly so we don't rely on scp/ssh quirks.
q_ws=$(printf '%q' "$RPI_WORKSPACE_DIR")
RPI_WORKSPACE_DIR_EXPANDED=$(ssh "${MASTER_USER}@${MASTER_IP}" "bash -lc \"echo ${q_ws}\"" 2>/dev/null) \
    || die "Failed to expand RPI_WORKSPACE_DIR on master"
unset q_ws

# Build the hostfile subset for requested node count
HOSTFILE_SUBSET=""
for i in $(seq 0 $((NODES - 1))); do
    HOSTFILE_SUBSET+="${ALL_IPS[$i]}:1"$'\n'
done

BINARY="${FILTER}_arch${ARCH}"
REMOTE_IMAGE="/tmp/rpi_input_$(basename "${IMAGE}")"
REMOTE_OUTPUT_DIR="/tmp/rpi_output_$(date +%Y%m%d_%H%M%S)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "  Vision Job: ${FILTER} × arch${ARCH} on ${NODES} nodes"
echo -e "  Binary    : ${BINARY}"
echo -e "  Image     : $(basename "${IMAGE}")"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo ""

# ── Step 1: Copy image to all nodes ──────────────────────────────────────────
info "Copying input image to ${NODES} nodes..."
for i in $(seq 0 $((NODES - 1))); do
    USER="${ALL_USERS[$i]}"; IP="${ALL_IPS[$i]}"
    scp -q "${IMAGE}" "${USER}@${IP}:${REMOTE_IMAGE}"
    info "  → ${USER}@${IP}:${REMOTE_IMAGE}"
done
success "Image distributed"

# ── Step 2: Write a temporary hostfile for this run ──────────────────────────
info "Preparing ${NODES}-node hostfile on master..."
TEMP_HOSTFILE="/tmp/hostfile_${NODES}nodes"
ssh "${MASTER_USER}@${MASTER_IP}" "cat > ${TEMP_HOSTFILE}" <<< "$HOSTFILE_SUBSET"
success "Hostfile ready: ${TEMP_HOSTFILE}"

# ── Step 3: Launch mpirun on master ──────────────────────────────────────────
info "Launching: mpirun -np ${NODES} ${BINARY} ${REMOTE_IMAGE}"
echo ""
echo -e "${YELLOW}── MPI Output ──────────────────────────────────────────${NC}"

START_TIME=$(date +%s%N)

ssh "${MASTER_USER}@${MASTER_IP}" \
    "mpirun -np ${NODES} --hostfile ${TEMP_HOSTFILE} \
    ${RPI_WORKSPACE_DIR_EXPANDED}/build/${BINARY} ${REMOTE_IMAGE} 2>&1"

END_TIME=$(date +%s%N)
ELAPSED=$(( (END_TIME - START_TIME) / 1000000 ))

echo -e "${YELLOW}────────────────────────────────────────────────────────${NC}"
echo ""
success "Job finished in ${ELAPSED}ms"

# ── Step 4: Collect output from master ───────────────────────────────────────
if [[ -n "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR"
    info "Collecting output images from master..."
    # Most vision programs write output alongside the input file
    OUTNAME="${FILTER}_arch${ARCH}_out_${TIMESTAMP}"
    scp "${MASTER_USER}@${MASTER_IP}:/tmp/${FILTER}_*out*" \
        "${OUTPUT_DIR}/${OUTNAME}/" 2>/dev/null || warn "No output images found in /tmp/"
    success "Output saved to ${OUTPUT_DIR}/"
fi

# ── Step 5: Cleanup remote /tmp ───────────────────────────────────────────────
info "Cleaning up remote temp files..."
for i in $(seq 0 $((NODES - 1))); do
    USER="${ALL_USERS[$i]}"; IP="${ALL_IPS[$i]}"
    ssh "${USER}@${IP}" "rm -f ${REMOTE_IMAGE}" 2>/dev/null || true
done
ssh "${MASTER_USER}@${MASTER_IP}" "rm -f ${TEMP_HOSTFILE}" 2>/dev/null || true
success "Cleanup done"

echo ""
echo -e "${GREEN}${BOLD}Run complete!${NC}"
