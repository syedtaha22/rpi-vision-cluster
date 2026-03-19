#!/bin/bash

LOG_FILE="analysis_results.log"
echo "Performance Analysis Log - $(date)" | tee $LOG_FILE

# Datasets
IMAGES=(
    "/home/pi/workspace/vision/datasets/cifar-10/tabby_s_000074.png"
    "/home/pi/workspace/vision/datasets/tiny-imagenet-200/test/images/test_0.JPEG"
    "/home/pi/workspace/vision/datasets/coco-val2017/000000144003.jpg"
)

# Nodes to test for MPI
NODE_COUNTS=(2 4 6)
# Threads to test for OpenMP
THREAD_COUNTS=(1 2 4)

for img in "${IMAGES[@]}"; do
    echo "=========================================================" | tee -a $LOG_FILE
    echo "IMAGE: $img" | tee -a $LOG_FILE
    echo "=========================================================" | tee -a $LOG_FILE
    
    # 1. Baselines (Serial)
    echo "Running Baselines..." | tee -a $LOG_FILE
    make run FILE=vision/baselines NODES=1 ARGS="$img" 2>&1 | tee -a $LOG_FILE

    # 2. OpenMP Scaling (Arch 1)
    for t in "${THREAD_COUNTS[@]}"; do
        echo "Running Arch 1 (Farm) Threads: $t" | tee -a $LOG_FILE
        make run FILE=vision/fft_arch1_farm NODES=1 ARGS="$img $t" 2>&1 | tee -a $LOG_FILE
    done

    # 3. MPI Scaling (Arch 3)
    for n in "${NODE_COUNTS[@]}"; do
        echo "Running Arch 3 (Dist Dynamic) Nodes: $n" | tee -a $LOG_FILE
        make run FILE=vision/fft_arch3_dist_dynamic NODES=$n ARGS="$img" 2>&1 | tee -a $LOG_FILE
    done
    
    # 4. Arch 2 & 4 (Static configs)
    echo "Running Arch 2..." | tee -a $LOG_FILE
    make run FILE=vision/fft_arch2_pipeline NODES=1 ARGS="$img" 2>&1 | tee -a $LOG_FILE
    echo "Running Arch 4..." | tee -a $LOG_FILE
    make run FILE=vision/fft_arch4_dist_pipeline NODES=2 ARGS="$img" 2>&1 | tee -a $LOG_FILE
done

echo "Analysis complete. Results saved to $LOG_FILE" | tee -a $LOG_FILE
