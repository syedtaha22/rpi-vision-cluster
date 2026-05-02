#!/usr/bin/env bash
# =============================================================================
# run_native.sh — Iterative verify → deploy → run workflow for physical RPi cluster
# =============================================================================
#
# Usage:
#   bash rpi/run_native.sh [--bsds] [--resilience] [--quick] [--fix]
#                          [--skip-build] [--nodes N,M] [--threads N,M]
#                          [--timeout N] [--image /path]
#
# Modes (default = performance analysis):
#   --bsds        Run BSDS500 quality analysis (run_analysis_bsds.sh)
#   --resilience  Run resilience / bully election tests (resilience_analysis.sh)
#
# Extra flags are forwarded to the chosen analysis script unchanged.
#
# What it does:
#   1. Validates / generates config.env
#   2. Quick SSH connectivity check — shows which nodes are UP/DOWN
#   3. Checks if required binaries exist on the cluster
#   4. If missing → runs deploy.sh automatically
#   5. Full verify (binaries + MPI)
#   6. Runs the analysis with --native + any forwarded flags
#   7. On failure prints actionable guidance
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[native]${NC} $*"; }
success() { echo -e "${GREEN}[native] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[native] ⚠${NC} $*"; }
die()     { echo -e "${RED}[native] ✗ FATAL:${NC} $*" >&2; exit 1; }
banner()  { echo -e "\n${BOLD}══ $* ══${NC}"; }

# ── Parse arguments ───────────────────────────────────────────────────────────
MODE="perf"          # perf | bsds | resilience
FORWARD_ARGS=()      # passed straight through to analysis script

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bsds)        MODE="bsds";        shift ;;
        --resilience)  MODE="resilience";  shift ;;
        --quick|--fix|--skip-build|--verify)
                       FORWARD_ARGS+=("$1"); shift ;;
        --nodes|--threads|--timeout|--image)
                       FORWARD_ARGS+=("$1" "$2"); shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Step 0: Ensure config.env ─────────────────────────────────────────────────
banner "STEP 0: Config"
if [[ ! -f "$CONFIG" ]] || grep -q "__FILL_IN__" "$CONFIG" 2>/dev/null; then
    info "config.env missing or incomplete — running gen_config.sh..."
    bash "${SCRIPT_DIR}/gen_config.sh" || die "gen_config.sh failed"
fi
# shellcheck source=/dev/null
source "$CONFIG"
success "config.env loaded (master=${MASTER_USER}@${MASTER_HOST})"

ALL_USERS=("$MASTER_USER"  "$WORKER1_USER" "$WORKER2_USER" "$WORKER3_USER" "$WORKER4_USER" "$WORKER5_USER")
ALL_HOSTS=("$MASTER_HOST"  "$WORKER1_HOST" "$WORKER2_HOST" "$WORKER3_HOST" "$WORKER4_HOST" "$WORKER5_HOST")
ALL_LABELS=("master" "worker1" "worker2" "worker3" "worker4" "worker5")

# ── Step 1: Quick connectivity check ─────────────────────────────────────────
banner "STEP 1: Node liveness check"
ALIVE_NODES=0
DEAD_NODES=()
for i in "${!ALL_HOSTS[@]}"; do
    u="${ALL_USERS[$i]}" h="${ALL_HOSTS[$i]}" label="${ALL_LABELS[$i]}"
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "${u}@${h}" "hostname" &>/dev/null; then
        ALIVE_NODES=$((ALIVE_NODES + 1))
        echo -e "  ${GREEN}✓${NC} ${label} (${u}@${h})"
    else
        DEAD_NODES+=("${label}(${h})")
        echo -e "  ${RED}✗${NC} ${label} (${u}@${h}) — UNREACHABLE"
    fi
done

echo ""
if [[ ${#DEAD_NODES[@]} -gt 0 ]]; then
    warn "Unreachable nodes: ${DEAD_NODES[*]}"
    warn "To fix SSH keys run:  bash rpi/setup_cluster.sh"
    if [[ $ALIVE_NODES -lt 2 ]]; then
        die "Only $ALIVE_NODES node(s) alive — need ≥ 2 for MPI. Aborting."
    fi
    warn "Continuing with $ALIVE_NODES alive node(s) — dead nodes will be excluded."
else
    success "All 6 nodes are reachable"
fi

# ── Step 2: Binary check ──────────────────────────────────────────────────────
banner "STEP 2: Binary presence on cluster"
RPI_SHARED_BIN="${RPI_SHARED_BIN:-/var/tmp/pdc_build}"

REQUIRED_BINS=(baselines
    sobel_arch1 sobel_arch2 sobel_arch3 sobel_arch4
    canny_arch1 canny_arch2 canny_arch3 canny_arch4
    log_arch1   log_arch2   log_arch3   log_arch4
    fft_arch1   fft_arch2   fft_arch3   fft_arch4
    bully_election resilience_test)

BINS_OK=1
for BIN in "${REQUIRED_BINS[@]}"; do
    if ! ssh -o BatchMode=yes "${MASTER_USER}@${MASTER_HOST}" \
        "[ -s ${RPI_SHARED_BIN}/${BIN} ] && [ -x ${RPI_SHARED_BIN}/${BIN} ]" &>/dev/null; then
        warn "Missing on master: ${BIN}"
        BINS_OK=0
    fi
done

if [[ $BINS_OK -eq 0 ]]; then
    info "Binaries missing — running deploy.sh..."
    bash "${SCRIPT_DIR}/deploy.sh" || warn "Deploy finished with warnings (check output above)"
    # Re-check
    BINS_OK=1
    for BIN in "${REQUIRED_BINS[@]}"; do
        if ! ssh -o BatchMode=yes "${MASTER_USER}@${MASTER_HOST}" \
            "[ -s ${RPI_SHARED_BIN}/${BIN} ] && [ -x ${RPI_SHARED_BIN}/${BIN} ]" &>/dev/null; then
            warn "Still missing after deploy: ${BIN}"
            BINS_OK=0
        fi
    done
    if [[ $BINS_OK -eq 0 ]]; then
        die "Binaries still missing after deploy. Check compilation errors above."
    fi
fi
success "Required binaries present on master"

# ── Step 3: Full cluster verify ───────────────────────────────────────────────
banner "STEP 3: Full cluster verify"
bash "${SCRIPT_DIR}/verify.sh" || warn "Verify reported issues — continuing anyway (MPI will skip dead nodes)"

# ── Step 4: Run analysis ──────────────────────────────────────────────────────
banner "STEP 4: Running ${MODE} analysis with --native"

case "$MODE" in
    perf)
        ANALYSIS_SCRIPT="${REPO_ROOT}/analysis/run_analysis.sh"
        ANALYSIS_NAME="performance (run_analysis.sh)"
        ;;
    bsds)
        ANALYSIS_SCRIPT="${REPO_ROOT}/analysis/run_analysis_bsds.sh"
        ANALYSIS_NAME="BSDS500 quality (run_analysis_bsds.sh)"
        ;;
    resilience)
        ANALYSIS_SCRIPT="${REPO_ROOT}/analysis/resilience_analysis.sh"
        ANALYSIS_NAME="resilience (resilience_analysis.sh)"
        ;;
esac

info "Script : $ANALYSIS_SCRIPT"
info "Args   : --native ${FORWARD_ARGS[*]:-}"
echo ""

if bash "$ANALYSIS_SCRIPT" --native "${FORWARD_ARGS[@]}"; then
    echo ""
    success "Analysis complete — see log in analysis/ directory"
else
    EXIT_CODE=$?
    echo ""
    echo -e "${RED}${BOLD}Analysis exited with code $EXIT_CODE${NC}"
    echo ""
    echo "Troubleshooting checklist:"
    echo "  1. Re-run this script to retry:  bash rpi/run_native.sh ${FORWARD_ARGS[*]:-}"
    echo "  2. Fix SSH keys for dead nodes:  bash rpi/setup_cluster.sh"
    echo "  3. Force redeploy binaries:      bash rpi/deploy.sh"
    echo "  4. Force dataset re-push:        bash rpi/run_native.sh --fix ${FORWARD_ARGS[*]:-}"
    echo "  5. Check cluster health:         bash rpi/verify.sh"
    exit $EXIT_CODE
fi
