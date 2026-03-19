#!/bin/bash

# Exit on error
set -e

mkdir -p workspace/vision/datasets
cd workspace/vision/datasets

echo "==============================================="
echo "Downloading Datasets for Vision Processing Test"
echo "==============================================="

# 1. CIFAR-10 (Download, extract, and convert first 100 to images)
if [ ! -d "cifar-10" ]; then
    echo "[1/3] Downloading CIFAR-10 dataset..."
    wget -q -nc --show-progress https://www.cs.toronto.edu/~kriz/cifar-10-python.tar.gz
    tar -xzf cifar-10-python.tar.gz
    rm cifar-10-python.tar.gz
    
    echo "Extracting sample images from CIFAR-10 batches..."
    # Python inline script to extract images from the pickle file
    python3 -c "
import pickle
import numpy as np
import os
from PIL import Image

def unpickle(file):
    with open(file, 'rb') as fo:
        dict = pickle.load(fo, encoding='bytes')
    return dict

source_dir = 'cifar-10-batches-py'
out_dir = 'cifar-10'
os.makedirs(out_dir, exist_ok=True)

try:
    batch_1_file = os.path.join(source_dir, 'data_batch_1')
    batch_1 = unpickle(batch_1_file)
    data = batch_1[b'data']
    filenames = batch_1[b'filenames']

    # Extract first 100 images
    for i in range(100):
        img_flat = data[i]
        r = img_flat[0:1024].reshape(32, 32)
        g = img_flat[1024:2048].reshape(32, 32)
        b = img_flat[2048:3072].reshape(32, 32)
        img_array = np.dstack((r, g, b))
        img = Image.fromarray(img_array)
        filename = filenames[i].decode('utf-8')
        img.save(os.path.join(out_dir, filename))
except Exception as e:
    print(f'Error extracting CIFAR-10: {e}')
"
    rm -rf cifar-10-batches-py
    echo "CIFAR-10 ready in 'cifar-10/' folder."
else
    echo "[1/3] CIFAR-10 (cifar-10) already exists."
fi

# 2. Tiny ImageNet
if [ ! -d "tiny-imagenet-200" ]; then
    echo "[2/3] Downloading Tiny ImageNet..."
    wget -q -nc --show-progress http://cs231n.stanford.edu/tiny-imagenet-200.zip
    unzip -q tiny-imagenet-200.zip
    rm tiny-imagenet-200.zip
    echo "Tiny ImageNet ready in 'tiny-imagenet-200/' folder."
else
    echo "[2/3] Tiny ImageNet already exists."
fi

# 3. COCO (2017 Val images)
if [ ! -d "coco-val2017" ]; then
    echo "[3/3] Downloading COCO 2017 Val dataset (~1GB)..."
    wget -q -nc --show-progress http://images.cocodataset.org/zips/val2017.zip
    unzip -q val2017.zip
    mv val2017 coco-val2017
    rm val2017.zip
    echo "COCO 2017 Val ready in 'coco-val2017/' folder."
else
    echo "[3/3] COCO dataset (coco-val2017) already exists."
fi

echo "==============================================="
echo "All datasets downloaded and formatted successfully!"
echo "Final Directory Structure inside workspace/vision/datasets/:"
ls -la
