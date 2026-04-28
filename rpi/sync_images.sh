#!/usr/bin/env bash
# =============================================================================
# sync_images.sh — Copy curated test images from laptop to all RPI nodes
# =============================================================================
# Transfers a small, curated benchmark image set from your local machine to
# every node in the cluster. No internet access required on the Pis.
#
# Image set:
#   - BSD500  : 10–50 images + their .mat ground truth files
#   - COCO    : 1 representative image
#   - CIFAR   : 1 representative image (PNG, upscaled from 32x32)
#   - TinyIN  : 1 representative image
#
# The images land at ~/workspace/vision/datasets/<dataset>/ on every node,
# mirroring the same path used by Docker (workspace/vision/datasets/).
#
# Usage:
#   bash rpi/sync_images.sh [--bsd-count N] [--dry-run]
#
# Options:
#   --bsd-count N   Number of BSD images to transfer (default: 20, max: 50)
#   --dry-run       Show what would be transferred without actually doing it
#
# Prerequisites:
#   - rpi/config.env filled in
#   - Passwordless SSH to all nodes (run setup_cluster.sh first)
#   - Local dataset paths below must exist (or override with env vars)
#
# Override local dataset paths:
#   LOCAL_BSD_IMAGES=path/to/BSDS500/images/test \
#   LOCAL_BSD_GT=path/to/BSDS500/ground_truth/test \
#   LOCAL_COCO_IMG=path/to/image.jpg \
#   LOCAL_CIFAR_IMG=path/to/image.png \
#   LOCAL_TINYIN_IMG=path/to/image.JPEG \
#   bash rpi/sync_images.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[sync_images]${NC} $*"; }
success() { echo -e "${GREEN}[sync_images] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[sync_images] ⚠${NC} $*"; }
die()     { echo -e "${RED}[sync_images] ✗${NC} $*" >&2; exit 1; }

# ── Parse args ────────────────────────────────────────────────────────────────
BSD_COUNT=20
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bsd-count) BSD_COUNT="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# Cap BSD count
(( BSD_COUNT > 50 )) && BSD_COUNT=50
(( BSD_COUNT < 1  )) && BSD_COUNT=1

# ── Local dataset paths (override via env if needed) ─────────────────────────
DATASETS_ROOT="${REPO_ROOT}/workspace/vision/datasets"

LOCAL_BSD_IMAGES="${LOCAL_BSD_IMAGES:-${DATASETS_ROOT}/BSDS500/images/test}"
LOCAL_BSD_GT="${LOCAL_BSD_GT:-${DATASETS_ROOT}/BSDS500/ground_truth/test}"
LOCAL_COCO_IMG="${LOCAL_COCO_IMG:-}"
LOCAL_CIFAR_IMG="${LOCAL_CIFAR_IMG:-}"
LOCAL_TINYIN_IMG="${LOCAL_TINYIN_IMG:-}"

# ── Load config ───────────────────────────────────────────────────────────────
[[ -f "$CONFIG" ]] || die "config.env not found. Run setup_cluster.sh first."
# shellcheck source=/dev/null
source "$CONFIG"

ALL_USERS=("$MASTER_USER"  "$WORKER1_USER" "$WORKER2_USER" "$WORKER3_USER" "$WORKER4_USER" "$WORKER5_USER")
ALL_IPS=(  "$MASTER_IP"    "$WORKER1_IP"   "$WORKER2_IP"   "$WORKER3_IP"   "$WORKER4_IP"   "$WORKER5_IP")
ALL_LABELS=("master" "worker1" "worker2" "worker3" "worker4" "worker5")

# ── Auto-detect single images if not provided ─────────────────────────────────
auto_pick_image() {
    local DIR="$1"
    local PATTERN="$2"
    if [[ -d "$DIR" ]]; then
        find "$DIR" -maxdepth 2 -name "$PATTERN" | sort | head -1
    fi
}

if [[ -z "$LOCAL_COCO_IMG" ]]; then
    LOCAL_COCO_IMG=$(auto_pick_image "${DATASETS_ROOT}/coco-val2017" "*.jpg" 2>/dev/null || true)
fi
if [[ -z "$LOCAL_CIFAR_IMG" ]]; then
    LOCAL_CIFAR_IMG=$(auto_pick_image "${DATASETS_ROOT}/cifar-10" "*.png" 2>/dev/null || true)
fi
if [[ -z "$LOCAL_TINYIN_IMG" ]]; then
    LOCAL_TINYIN_IMG=$(auto_pick_image "${DATASETS_ROOT}/tiny-imagenet-200" "*.JPEG" 2>/dev/null || \
                       auto_pick_image "${DATASETS_ROOT}/tiny-imagenet-200" "*.jpg"  2>/dev/null || true)
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "  Image Sync Plan"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "  BSD500 images : ${LOCAL_BSD_IMAGES}"
echo -e "  BSD500 GT     : ${LOCAL_BSD_GT}"
echo -e "  BSD count     : ${BSD_COUNT}"
echo -e "  COCO image    : ${LOCAL_COCO_IMG:-NOT FOUND}"
echo -e "  CIFAR image   : ${LOCAL_CIFAR_IMG:-NOT FOUND}"
echo -e "  TinyIN image  : ${LOCAL_TINYIN_IMG:-NOT FOUND}"
echo -e "  Nodes         : ${#ALL_USERS[@]}"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
    warn "DRY RUN — no files transferred"
    exit 0
fi

# ── Validate local sources ────────────────────────────────────────────────────
[[ -d "$LOCAL_BSD_IMAGES" ]] || die "BSD images dir not found: ${LOCAL_BSD_IMAGES}\n  Set LOCAL_BSD_IMAGES=path/to/dir"
[[ -d "$LOCAL_BSD_GT"     ]] || die "BSD ground truth dir not found: ${LOCAL_BSD_GT}\n  Set LOCAL_BSD_GT=path/to/dir"

# ── Select BSD files ──────────────────────────────────────────────────────────
info "Selecting ${BSD_COUNT} BSD500 images..."
# Use mapfile to collect sorted jpegs
mapfile -t BSD_ALL_IMGS < <(find "$LOCAL_BSD_IMAGES" -maxdepth 1 -name "*.jpg" | sort)
TOTAL_BSD=${#BSD_ALL_IMGS[@]}
[[ $TOTAL_BSD -gt 0 ]] || die "No .jpg files found in ${LOCAL_BSD_IMAGES}"

# Take first N (sorted, reproducible)
BSD_SELECTED=("${BSD_ALL_IMGS[@]:0:${BSD_COUNT}}")
info "  Selected ${#BSD_SELECTED[@]} of ${TOTAL_BSD} available BSD images"

# Corresponding .mat ground truth files
BSD_GT_FILES=()
for IMG in "${BSD_SELECTED[@]}"; do
    STEM=$(basename "$IMG" .jpg)
    GT="${LOCAL_BSD_GT}/${STEM}.mat"
    [[ -f "$GT" ]] && BSD_GT_FILES+=("$GT") || warn "  No GT found for ${STEM}"
done
info "  Found ${#BSD_GT_FILES[@]} matching ground truth .mat files"

# ── Transfer function ─────────────────────────────────────────────────────────
transfer_to_node() {
    local USER="$1"; local IP="$2"; local LABEL="$3"

    # Create remote dirs
    ssh "${USER}@${IP}" "
        mkdir -p ~/workspace/vision/datasets/BSDS500/images/test
        mkdir -p ~/workspace/vision/datasets/BSDS500/ground_truth/test
        mkdir -p ~/workspace/vision/datasets/coco-val2017
        mkdir -p ~/workspace/vision/datasets/cifar-10
        mkdir -p ~/workspace/vision/datasets/tiny-imagenet-200
    "

    # BSD images
    if [[ ${#BSD_SELECTED[@]} -gt 0 ]]; then
        info "  ${LABEL}: syncing ${#BSD_SELECTED[@]} BSD images..."
        rsync -az --progress "${BSD_SELECTED[@]}" \
            "${USER}@${IP}:~/workspace/vision/datasets/BSDS500/images/test/"
    fi

    # BSD ground truth (.mat files)
    if [[ ${#BSD_GT_FILES[@]} -gt 0 ]]; then
        info "  ${LABEL}: syncing ${#BSD_GT_FILES[@]} BSD .mat ground truth files..."
        rsync -az "${BSD_GT_FILES[@]}" \
            "${USER}@${IP}:~/workspace/vision/datasets/BSDS500/ground_truth/test/"
    fi

    # COCO (1 image)
    if [[ -n "${LOCAL_COCO_IMG:-}" && -f "${LOCAL_COCO_IMG}" ]]; then
        info "  ${LABEL}: copying COCO image..."
        scp -q "${LOCAL_COCO_IMG}" \
            "${USER}@${IP}:~/workspace/vision/datasets/coco-val2017/$(basename "${LOCAL_COCO_IMG}")"
    else
        warn "  ${LABEL}: COCO image not found — skipping"
    fi

    # CIFAR (1 image)
    if [[ -n "${LOCAL_CIFAR_IMG:-}" && -f "${LOCAL_CIFAR_IMG}" ]]; then
        info "  ${LABEL}: copying CIFAR image..."
        scp -q "${LOCAL_CIFAR_IMG}" \
            "${USER}@${IP}:~/workspace/vision/datasets/cifar-10/$(basename "${LOCAL_CIFAR_IMG}")"
    else
        warn "  ${LABEL}: CIFAR image not found — skipping"
    fi

    # TinyImageNet (1 image)
    if [[ -n "${LOCAL_TINYIN_IMG:-}" && -f "${LOCAL_TINYIN_IMG}" ]]; then
        info "  ${LABEL}: copying TinyImageNet image..."
        scp -q "${LOCAL_TINYIN_IMG}" \
            "${USER}@${IP}:~/workspace/vision/datasets/tiny-imagenet-200/$(basename "${LOCAL_TINYIN_IMG}")"
    else
        warn "  ${LABEL}: TinyImageNet image not found — skipping"
    fi

    success "  ${LABEL}: transfer complete"
}

# ── Transfer to all nodes ─────────────────────────────────────────────────────
for i in $(seq 0 5); do
    echo ""
    info "── Node: ${ALL_LABELS[$i]} (${ALL_USERS[$i]}@${ALL_IPS[$i]}) ──"
    transfer_to_node "${ALL_USERS[$i]}" "${ALL_IPS[$i]}" "${ALL_LABELS[$i]}"
done

echo ""
echo -e "${GREEN}${BOLD}════════ Image sync complete ════════${NC}"
echo -e "  BSD500 : ${#BSD_SELECTED[@]} images + ${#BSD_GT_FILES[@]} .mat GT files"
[[ -n "${LOCAL_COCO_IMG:-}"    ]] && echo "  COCO   : 1 image" || echo "  COCO   : skipped (not found)"
[[ -n "${LOCAL_CIFAR_IMG:-}"   ]] && echo "  CIFAR  : 1 image" || echo "  CIFAR  : skipped (not found)"
[[ -n "${LOCAL_TINYIN_IMG:-}"  ]] && echo "  TinyIN : 1 image" || echo "  TinyIN : skipped (not found)"
echo ""
echo "Next: make rpi-run FILTER=sobel ARCH=3 NODES=6 IMAGE=~/workspace/vision/datasets/BSDS500/images/test/<name>.jpg"
