#!/bin/bash
# =============================================================================
#  download_datasets.sh — Need-basis, Zero-Wastage Dataset Downloader
#
#  Usage:
#    bash download_datasets.sh [--fix] [--cifar] [--tiny] [--coco] [--bsds N]
# =============================================================================

set -euo pipefail

DS_ROOT="/home/pi/workspace/vision/datasets"
SHARED_DIR="/home/pi/workspace/vision/shared"

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

# ── CIFAR-10 (Single Image) ──────────────────────────────────────────────────
if [[ $DO_CIFAR -eq 1 ]]; then
    DIR="$DS_ROOT/cifar-10"
    [[ $FIX -eq 1 ]] && rm -rf "$DIR"
    if [[ ! -f "$DIR/tabby.jpg" ]]; then
        echo "  [DOWNLOADING] CIFAR-10 (1 image)..."
        mkdir -p "$DIR"
        wget -q -O "$DIR/tabby.jpg" "https://raw.githubusercontent.com/YoongiKim/CIFAR-10-images/master/test/cat/0004.jpg" || true
    fi
    echo "  [OK] CIFAR-10 ready."
fi

# ── TinyImageNet (Single Image) ──────────────────────────────────────────────
if [[ $DO_TINY -eq 1 ]]; then
    DIR="$DS_ROOT/tiny-imagenet-200"
    [[ $FIX -eq 1 ]] && rm -rf "$DIR"
    if [[ ! -f "$DIR/val_0.JPEG" ]]; then
        echo "  [DOWNLOADING] TinyImageNet (1 image)..."
        mkdir -p "$DIR"
        wget -q -O "$DIR/val_0.JPEG" "https://raw.githubusercontent.com/tjmoon0104/pytorch-tiny-imagenet/master/val/images/val_0.JPEG" || true
    fi
    echo "  [OK] TinyImageNet ready."
fi

# ── COCO (Single Image) ──────────────────────────────────────────────────────
if [[ $DO_COCO -eq 1 ]]; then
    DIR="$DS_ROOT/coco-val2017"
    [[ $FIX -eq 1 ]] && rm -rf "$DIR"
    if [[ ! -f "$DIR/000000144003.jpg" ]]; then
        echo "  [DOWNLOADING] COCO Val2017 (1 image)..."
        mkdir -p "$DIR"
        wget -q -O "$DIR/000000144003.jpg" "http://images.cocodataset.org/val2017/000000144003.jpg" || true
    fi
    echo "  [OK] COCO ready."
fi

# ── BSDS500 (Zero-Wastage N Images + Ground Truth) ───────────────────────────
if [[ $DO_BSDS -eq 1 ]]; then
    DIR="$DS_ROOT/BSDS500"
    [[ $FIX -eq 1 ]] && rm -rf "$DIR"

    # Check if we already have exactly BSDS_N images
    CUR_N=$(find "$DIR/images" -name "*.jpg" 2>/dev/null | wc -l || echo 0)
    
    if [[ $CUR_N -lt $BSDS_N ]]; then
        echo "  [DOWNLOADING] BSDS500 dataset via Kagglehub..."
        rm -rf "$DIR"
        mkdir -p "$DIR"
        
        # Download via python
        cat > /tmp/dl_bsds.py << 'PYEOF'
import kagglehub, shutil, os
path = kagglehub.dataset_download('balraj98/berkeley-segmentation-dataset-500-bsds500')
dst = '/home/pi/workspace/vision/datasets/BSDS500_tmp'
if os.path.exists(dst): shutil.rmtree(dst)
shutil.copytree(path, dst)
PYEOF
        pip install -q kagglehub scipy 2>/dev/null || true
        python3 /tmp/dl_bsds.py

        # Compile mat_to_png
        echo "  [COMPILING] mat_to_png.cpp for ground truth extraction..."
        g++ -std=c++17 -O2 -I"$SHARED_DIR" "$SHARED_DIR/mat_to_png.cpp" -o /tmp/mat_to_png

        # Setup target directories
        mkdir -p "$DIR/images" "$DIR/groundTruth_png"

        echo "  [EXTRACTING] Processing $BSDS_N images and discarding the rest..."
        # Find all test images in the downloaded temp folder
        TMP_DIR="/home/pi/workspace/vision/datasets/BSDS500_tmp"
        mapfile -t ALL_IMGS < <(find "$TMP_DIR/data/images/test" -name "*.jpg" | sort)
        
        N_PROC=0
        for IMG_PATH in "${ALL_IMGS[@]}"; do
            if [[ $N_PROC -ge $BSDS_N ]]; then break; fi
            
            BASE=$(basename "$IMG_PATH" .jpg)
            MAT_PATH="$TMP_DIR/data/groundTruth/test/${BASE}.mat"
            
            if [[ -f "$MAT_PATH" ]]; then
                # Copy image
                cp "$IMG_PATH" "$DIR/images/"
                # Reconstruct ground truth PNG
                /tmp/mat_to_png "$MAT_PATH" "$DIR/groundTruth_png/${BASE}_gt.png" >/dev/null 2>&1
                N_PROC=$((N_PROC + 1))
            fi
        done
        
        # Aggressive cleanup: delete the entire 33MB Kaggle download!
        echo "  [CLEANUP] Deleting unused Kaggle dataset files (Zero Wastage)..."
        rm -rf "$TMP_DIR"
        rm -f /tmp/mat_to_png
        
        echo "  [OK] BSDS500 ready ($N_PROC images & boundaries)."
    else
        echo "  [OK] BSDS500 ready ($CUR_N images)."
    fi
fi

echo "Dataset provisioning complete."
