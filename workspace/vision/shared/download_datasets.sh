#!/bin/bash
# =============================================================================
#  download_datasets.sh — Need-basis, Zero-Wastage Dataset Downloader
#
#  Usage:
#    bash download_datasets.sh [--fix] [--cifar] [--tiny] [--coco] [--bsds N]
# =============================================================================

set -euo pipefail

DS_ROOT="${DS_ROOT:-/home/pi/workspace/vision/datasets}"
SHARED_DIR="${SHARED_DIR:-/home/pi/workspace/vision/shared}"

FIX=0
DO_CIFAR=0
DO_TINY=0
DO_COCO=0
DO_BSDS=0
BSDS_N=10

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)   FIX=1; shift ;;
        --cifar) DO_CIFAR=1; shift ;;
        --tiny)  DO_TINY=1; shift ;;
        --coco)  DO_COCO=1; shift ;;
        --bsds)  DO_BSDS=1; BSDS_N="$2"; shift 2 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

mkdir -p "$DS_ROOT"

file_ok() {
    local path="$1"
    [[ -f "$path" && -s "$path" ]]
}

have_any_image() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    find "$dir" -type f \( -name '*.jpg' -o -name '*.jpeg' -o -name '*.JPEG' -o -name '*.png' \) -size +0c -print -quit 2>/dev/null | grep -q .
}

# Returns 0 if file starts with JPEG magic bytes (FF D8 FF).
# Falls back to trusting the file if xxd/python3 are unavailable.
validate_jpeg() {
    local f="$1"
    file_ok "$f" || return 1
    local magic
    if command -v xxd &>/dev/null; then
        magic=$(xxd -l 3 -p "$f" 2>/dev/null || true)
    elif command -v python3 &>/dev/null; then
        magic=$(python3 -c "
import sys
with open(sys.argv[1],'rb') as fh:
    print(fh.read(3).hex())
" "$f" 2>/dev/null || true)
    else
        return 0  # no tool available — trust the file
    fi
    [[ "$magic" == "ffd8ff" ]]
}

download_file() {
    local url="$1" dest="$2" label="$3"
    mkdir -p "$(dirname "$dest")"
    rm -f "$dest"
    if ! wget -q -O "$dest" "$url"; then
        rm -f "$dest"
        echo "  [ERROR] Download failed: $label"
        echo "          URL : $url"
        echo "          Dest: $dest"
        return 1
    fi
    if ! file_ok "$dest"; then
        rm -f "$dest"
        echo "  [ERROR] Download produced an empty file: $label"
        return 1
    fi
}

# ── CIFAR-10 (Single Image extracted from official archive) ──────────────────
if [[ $DO_CIFAR -eq 1 ]]; then
    DIR="$DS_ROOT/cifar-10"
    [[ $FIX -eq 1 ]] && rm -rf "$DIR"
    DEST="$DIR/tabby.jpg"

    if ! file_ok "$DEST"; then
        echo "  [DOWNLOADING] CIFAR-10 archive from cs.toronto.edu (~163 MB)..."
        mkdir -p "$DIR"
        TMP_TAR="$DIR/cifar-10-python.tar.gz"
        if download_file \
                "https://www.cs.toronto.edu/~kriz/cifar-10-python.tar.gz" \
                "$TMP_TAR" "CIFAR-10 archive"; then
            echo "  [EXTRACTING] Unpacking CIFAR-10 archive..."
            tar -xzf "$TMP_TAR" -C "$DIR"
            echo "  [EXTRACTING] Saving one test image as JPEG..."
            CIFAR_DIR="$DIR" CIFAR_DEST="$DEST" python3 - <<'PYEOF'
import pickle, os, sys
try:
    import numpy as np
    from PIL import Image
except ImportError:
    sys.exit("PIL/numpy missing: pip install pillow numpy")
batch = os.path.join(os.environ["CIFAR_DIR"], "cifar-10-batches-py", "test_batch")
with open(batch, "rb") as f:
    d = pickle.load(f, encoding="bytes")
img = d[b"data"][0].reshape(3, 32, 32).transpose(1, 2, 0)
Image.fromarray(img).save(os.environ["CIFAR_DEST"])
PYEOF
            rm -rf "$DIR/cifar-10-batches-py" "$TMP_TAR"
        fi

        if ! file_ok "$DEST"; then
            if have_any_image "$DIR"; then
                echo "  [WARN] CIFAR download/extraction failed, but existing images are present — continuing."
            else
                echo "  [FATAL] CIFAR-10 image missing and download failed."
                exit 1
            fi
        fi
    fi
    echo "  [OK] CIFAR-10 ready."
fi

# ── TinyImageNet (Single Image extracted from official archive) ───────────────
if [[ $DO_TINY -eq 1 ]]; then
    DIR="$DS_ROOT/tiny-imagenet-200"
    [[ $FIX -eq 1 ]] && rm -rf "$DIR"
    DEST="$DIR/val_0.JPEG"

    # Clean up any leftover zip from a previous run
    [[ -f "$DIR/tiny-imagenet-200.zip" ]] && rm -f "$DIR/tiny-imagenet-200.zip"

    # Delete if it exists but is not a valid JPEG (e.g. a cached HTML 404 page)
    if file_ok "$DEST" && ! validate_jpeg "$DEST"; then
        echo "  [WARN] $DEST is not a valid JPEG — removing and re-downloading."
        rm -f "$DEST"
    fi

    if ! file_ok "$DEST"; then
        echo "  [DOWNLOADING] TinyImageNet archive from cs231n.stanford.edu (~237 MB)..."
        mkdir -p "$DIR"
        TMP_ZIP="$DIR/tiny-imagenet-200.zip"
        downloaded=0

        if download_file \
                "http://cs231n.stanford.edu/tiny-imagenet-200.zip" \
                "$TMP_ZIP" "TinyImageNet archive"; then
            echo "  [EXTRACTING] Unpacking one validation image from zip..."
            if unzip -j -q "$TMP_ZIP" \
                    "tiny-imagenet-200/val/images/val_0.JPEG" \
                    -d "$DIR" 2>/dev/null && validate_jpeg "$DEST"; then
                downloaded=1
            fi
            rm -f "$TMP_ZIP"
        fi

        # Final fallback: reuse the already-downloaded CIFAR-10 image
        if [[ $downloaded -eq 0 ]]; then
            rm -f "$TMP_ZIP" 2>/dev/null || true
            CIFAR_IMG="$DS_ROOT/cifar-10/tabby.jpg"
            if [[ -f "$CIFAR_IMG" ]]; then
                echo "  [WARN] TinyImageNet archive failed — using CIFAR-10 image as substitute."
                cp "$CIFAR_IMG" "$DEST"
                downloaded=1
            fi
        fi

        if [[ $downloaded -eq 0 ]]; then
            if have_any_image "$DIR"; then
                echo "  [WARN] TinyImageNet download failed, but existing images are present — continuing."
            else
                echo "  [FATAL] TinyImageNet image missing and all downloads failed."
                exit 1
            fi
        fi
    fi
    echo "  [OK] TinyImageNet ready."
fi

# ── COCO (Single Image) ──────────────────────────────────────────────────────
if [[ $DO_COCO -eq 1 ]]; then
    DIR="$DS_ROOT/coco-val2017"
    [[ $FIX -eq 1 ]] && rm -rf "$DIR"
    DEST="$DIR/000000144003.jpg"
    if ! file_ok "$DEST"; then
        echo "  [DOWNLOADING] COCO Val2017 (1 image)..."
        if ! download_file \
            "http://images.cocodataset.org/val2017/000000144003.jpg" \
            "$DEST" \
            "COCO 000000144003.jpg"; then
            if have_any_image "$DIR"; then
                echo "  [WARN] COCO download failed, but existing images are present — continuing."
            else
                echo "  [FATAL] COCO image missing and download failed."
                exit 1
            fi
        fi
    fi
    echo "  [OK] COCO ready."
fi

# ── BSDS500 (Zero-Wastage N Images + Ground Truth) ───────────────────────────
if [[ $DO_BSDS -eq 1 ]]; then
    DIR="$DS_ROOT/BSDS500"
    [[ $FIX -eq 1 ]] && rm -rf "$DIR"

    CUR_N=$(find "$DIR/images" -name "*.jpg" 2>/dev/null | wc -l 2>/dev/null || true)
    CUR_N=$(( ${CUR_N:-0} + 0 ))

    if [[ $CUR_N -lt $BSDS_N ]]; then
        echo "  [DOWNLOADING] BSDS500 dataset via Kagglehub..."
        rm -rf "$DIR"
        mkdir -p "$DIR"

        BSDS_TMP="${DS_ROOT}/BSDS500_tmp"

        cat > /tmp/dl_bsds.py << PYEOF
import kagglehub, shutil, os
path = kagglehub.dataset_download('balraj98/berkeley-segmentation-dataset-500-bsds500')
dst = os.environ.get('BSDS_TMP', '/tmp/BSDS500_tmp')
if os.path.exists(dst):
    shutil.rmtree(dst)
shutil.copytree(path, dst)
PYEOF
        pip install -q kagglehub 2>/dev/null
        BSDS_TMP="$BSDS_TMP" python3 /tmp/dl_bsds.py

        mkdir -p "$DIR/images" "$DIR/groundTruth_png" "$DIR/ground_truth/test"

        echo "  [EXTRACTING] Processing $BSDS_N images..."
        mapfile -t ALL_IMGS < <(find "$BSDS_TMP/data/images/test" -name "*.jpg" 2>/dev/null | sort)

        N_PROC=0
        for IMG_PATH in "${ALL_IMGS[@]}"; do
            [[ $N_PROC -ge $BSDS_N ]] && break
            BASE=$(basename "$IMG_PATH" .jpg)
            MAT_PATH="$BSDS_TMP/data/groundTruth/test/${BASE}.mat"
            if [[ -f "$MAT_PATH" ]]; then
                cp "$IMG_PATH" "$DIR/images/"
                cp "$MAT_PATH" "$DIR/ground_truth/test/"
                python3 "$SHARED_DIR/mat_to_png.py" \
                    "$MAT_PATH" "$DIR/groundTruth_png/${BASE}_gt.png" 2>/dev/null
                N_PROC=$((N_PROC + 1))
            fi
        done

        echo "  [CLEANUP] Deleting Kaggle download cache..."
        rm -rf "$BSDS_TMP"

        echo "  [OK] BSDS500 ready ($N_PROC images + ground truth PNGs)."
    else
        echo "  [OK] BSDS500 images already present ($CUR_N images)."

        # Ground truth PNG conversion: run even when images already exist
        GT_N=$(find "$DIR/groundTruth_png" -name "*.png" 2>/dev/null | wc -l 2>/dev/null || true)
        GT_N=$(( ${GT_N:-0} + 0 ))
        if [[ $GT_N -lt $BSDS_N ]]; then
            echo "  [GT] groundTruth_png has $GT_N PNGs (need $BSDS_N) — converting from .mat files..."

            # Find .mat files: prefer ground_truth/test/ (existing structure), else bail
            MAT_SRC=""
            if [[ -d "$DIR/ground_truth/test" ]] && \
               find "$DIR/ground_truth/test" -name "*.mat" -print -quit 2>/dev/null | grep -q .; then
                MAT_SRC="$DIR/ground_truth/test"
            elif [[ -d "$DIR/groundTruth/test" ]] && \
               find "$DIR/groundTruth/test" -name "*.mat" -print -quit 2>/dev/null | grep -q .; then
                MAT_SRC="$DIR/groundTruth/test"
            fi

            if [[ -z "$MAT_SRC" ]]; then
                echo "  [WARN] No .mat files found under $DIR/ground_truth/test — skipping GT conversion."
                echo "         Run with --fix to re-download BSDS500 and regenerate ground truth."
            else
                echo "  [CONVERTING] mat_to_png (python stdlib)..."
                mkdir -p "$DIR/groundTruth_png"
                python3 "$SHARED_DIR/mat_to_png.py" --batch "$MAT_SRC" "$DIR/groundTruth_png"
                GT_DONE=$(find "$DIR/groundTruth_png" -name "*.png" 2>/dev/null | wc -l 2>/dev/null || true)
                GT_DONE=$(( ${GT_DONE:-0} + 0 ))
                echo "  [OK] Ground truth ready ($GT_DONE PNGs in groundTruth_png/)."
            fi
        else
            echo "  [OK] Ground truth PNGs already present ($GT_N PNGs)."
        fi
    fi
fi

echo "Dataset provisioning complete."
