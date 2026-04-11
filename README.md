# RPI Vision Cluster — Milestone 2

A distributed image processing system built on a Raspberry Pi cluster using MPI and OpenMP.
This project simulates a Raspberry Pi cluster environment using Docker with ARM64 emulation,
enabling development and testing on x86 machines.

## What's New in Milestone 2

Milestone 2 extends the FFT parallel architectures from Milestone 1 with a full implementation
of **Sobel**, **Canny**, and **LoG** edge detectors across four parallel architectures
(OpenMP Farm, OpenMP Pipeline, MPI Scatter-Gather, MPI Pipeline), benchmarked on **BSD500**
with Jaccard, Dice, and SSIM evaluation metrics. Full PRAM analysis (Amdahl, Brent, Isoefficiency)
is provided for each filter/architecture combination.

## Project Structure

```
rpi-vision-cluster/
├── Makefile                        # Cluster management & compilation commands
├── Dockerfile.cluster              # Container configuration with MPI, SSH, Python
├── docker-compose.yml              # Scalable cluster definition (2-6 nodes)
├── download_substantial_datasets.sh # Downloads CIFAR-10, Tiny ImageNet, COCO, BSD500
├── run_analysis.sh                 # Automated benchmark suite
├── generate_report.py              # Performance report generator
│
└── workspace/                      # All files mounted in cluster containers
    ├── hello_cluster.py            # MPI test script
    ├── plot.ipynb                  # Benchmark result visualisation notebook
    │
    ├── include/                    # Milestone 2: shared C++ headers
    │   ├── sobel.hpp               # SobelDetector class interface
    │   ├── canny.hpp               # CannyDetector class interface
    │   ├── image_io.hpp            # ImageIO + Image RAII wrapper (stb_image)
    │   ├── timing.hpp              # Timer class (chrono + MPI_Barrier sync)
    │   ├── utils.hpp               # ArgParser utility
    │   ├── stb_image.h             # Single-header image loader
    │   └── stb_image_write.h       # Single-header image writer
    │
    ├── src/                        # Milestone 2: detector implementations
    │   ├── sobel.cpp               # Sobel gradient computation (uint8 + float paths)
    │   └── canny.cpp               # Canny pipeline: Gaussian → Sobel → NMS → Hysteresis
    │
    ├── tests/
    │   └── test_detector.cpp       # CLI test harness: runs detectors on image directories
    │
    ├── examples/
    │   ├── matrix_multiply.c       # MPI matrix multiply benchmark (Milestone 1)
    │   └── mpi_latency_test.c      # MPI communication benchmark (Milestone 1)
    │
    └── vision/                     # Milestone 1: FFT architectures + baselines
        ├── baselines.cpp           # Sequential Sobel / Canny / LoG baselines
        ├── fft_arch1_farm.cpp      # OpenMP farm FFT
        ├── fft_arch2_pipeline.cpp  # OpenMP pipeline FFT
        ├── fft_arch3_dist_dynamic.cpp # MPI scatter-gather FFT
        ├── fft_arch4_dist_pipeline.cpp # MPI pipeline FFT
        ├── fft_utils.h             # FFT helper utilities
        ├── stb_image.h
        └── stb_image_write.h
```

---

## Quick Start

### Prerequisites
- Docker 29.2.1+
- Docker Compose 5.0.2+
- 8GB+ RAM, 15GB+ disk space

### 1. Start the Cluster

```bash
make setup          # Default: 2 nodes (1 master + 1 worker)
make setup NODES=4  # 4 nodes (1 master + 3 workers)
```

### 2. Download Datasets

```bash
./download_substantial_datasets.sh
```

This downloads into `workspace/vision/datasets/`:
- `cifar-10/` — 32×32 images
- `tiny-imagenet-200/` — 64×64 images
- `coco-val2017/` — high-resolution images
- `BSDS500/` — **BSD500** edge detection benchmark (Milestone 2 primary dataset)
  - `data/images/{train,val,test}/*.jpg` — 500 natural images (481×321 or 321×481)
  - `data/groundTruth/{train,val,test}/*.mat` — per-annotator boundary maps

### 3. Build the Milestone 2 Detectors

Inside the cluster (via `make shell`), build using the workspace Makefile:

```bash
make shell
cd /home/pi/workspace
make all        # builds build/test_detector
```

Or from the host via the root Makefile:

```bash
make compile FILE=src/sobel.cpp OUTPUT=sobel_obj   # compile individual objects
# Or compile the full test harness:
make compile FILE=tests/test_detector.cpp OUTPUT=test_detector
```

### 4. Run the Test Harness

```bash
# Run Sobel on 10 images from the BSD500 test set
make run FILE=test_detector NODES=1 \
  ARGS="--detector sobel -n 10 --images-path vision/datasets/BSDS500/data/images/test"

# Run Canny on 50 random images, saving outputs
make run FILE=test_detector NODES=1 \
  ARGS="--detector canny -n 50 --random --images-path vision/datasets/BSDS500/data/images/test"

# Full flag reference:
#   --detector sobel|canny     (required)
#   -n N                       number of images (default: 1)
#   --random                   shuffle image selection
#   --output true|false        save PNG outputs (default: true)
#   --seed N                   RNG seed (default: 42)
#   --images-path PATH         path to image directory
```

Results are saved to `workspace/results/<detector>/`:
- `results.csv` — per-image timing and throughput
- `images/*.png` — edge-detected output images

---

## Compiling the Full Architecture Suite (Milestone 2 Plan)

The four parallel architectures from `milestone2_execution_plan.md` compile as follows:

```bash
# Architecture 1 — OpenMP Farm
mpic++ workspace/vision/sobel_arch1_farm.cpp  -O2 -fopenmp -o sobel_arch1  -lm
mpic++ workspace/vision/log_arch1_farm.cpp    -O2 -fopenmp -o log_arch1    -lm
mpic++ workspace/vision/canny_arch1_farm.cpp  -O2 -fopenmp -o canny_arch1  -lm

# Architecture 2 — OpenMP Pipeline
mpic++ workspace/vision/sobel_arch2_pipeline.cpp -O2 -fopenmp -o sobel_arch2 -lm
mpic++ workspace/vision/canny_arch2_pipeline.cpp -O2 -fopenmp -o canny_arch2 -lm

# Architecture 3 — MPI Scatter-Gather
mpic++ workspace/vision/sobel_arch3_scatter.cpp -O2 -o sobel_arch3 -lm
mpic++ workspace/vision/log_arch3_scatter.cpp   -O2 -o log_arch3   -lm
mpic++ workspace/vision/canny_arch3_scatter.cpp -O2 -o canny_arch3 -lm

# Architecture 4 — MPI Pipeline
mpic++ workspace/vision/canny_arch4_pipeline.cpp -O2 -o canny_arch4 -lm
```

Or use the root Makefile (builds inside the ARM64 container with `-fopenmp` automatically):

```bash
make compile FILE=vision/sobel_arch1_farm.cpp OUTPUT=sobel_arch1
make run FILE=sobel_arch1 NODES=1 ARGS="vision/datasets/BSDS500/data/images/test/100075.jpg /tmp/out.png 4"
```

---

## BSD500 Ground Truth Loading (Python)

```python
import scipy.io
import numpy as np

def load_ground_truth(mat_path):
    """Load union of all annotator boundary maps from a BSDS500 .mat file."""
    gt = scipy.io.loadmat(mat_path)['groundTruth']
    num_annotators = gt.shape[1]
    union = np.zeros_like(gt[0, 0]['Boundaries'][0, 0], dtype=np.uint8)
    for i in range(num_annotators):
        boundary = gt[0, i]['Boundaries'][0, 0]
        union = np.logical_or(union, boundary).astype(np.uint8)
    return union * 255  # binary edge map: 0 or 255
```

Images are 481×321 or 321×481. Pad to 512×512 for FFT architectures:
```python
from scipy.fft import next_fast_len
size = next_fast_len(max(481, 321))  # = 512
```

---

## Benchmark Harness

```bash
# Ensure cluster is running with 6 nodes
make start NODES=6

# Run full benchmark suite (generates benchmark_results.csv)
./run_analysis.sh
```

The `run_analysis.sh` script tests:
- Serial baselines
- OpenMP scaling (Arch 1): T = 1, 2, 4 threads
- MPI scaling (Arch 3): P = 2, 4, 6 nodes
- Fixed configurations for Arch 2 and Arch 4
- Arch 4 pipeline streaming: batch sizes N = 1, 4, 8, 16, 32

---

## Makefile Reference

### Cluster Lifecycle

| Command | Description | Example |
|---|---|---|
| `make setup` | Build and start cluster | `make setup NODES=4` |
| `make start` | Start existing cluster | `make start NODES=2` |
| `make stop` | Stop all containers | `make stop` |
| `make restart` | Stop and start | `make restart NODES=3` |
| `make clean` | Remove containers (keep images) | `make clean` |
| `make destroy` | Remove containers and images | `make destroy` |

### Testing & Verification

| Command | Description | Example |
|---|---|---|
| `make test` | Run hello_cluster.py | `make test NODES=3` |
| `make verify` | Verify cluster connectivity | `make verify NODES=5` |
| `make shell` | SSH into master node | `make shell` |
| `make status` | Show container status | `make status` |

### Compilation & Execution

| Command | Description | Example |
|---|---|---|
| `make compile FILE=...` | Compile C/C++ for ARM64 cluster | `make compile FILE=src/sobel.cpp` |
| `make run FILE=... ARGS=...` | Run binary or Python script | `make run FILE=test_detector NODES=1 ARGS="--detector sobel -n 5"` |

Parameters: `NODES=N` (2-6), `FILE=path`, `OUTPUT=name`, `ARGS="..."`

---

## Milestones

- [x] **M0: Virtual cluster & toolchain setup**
  - Docker-based ARM64 emulation (2-6 nodes)
  - Automated setup with `make setup`
  - MPI latency and computation benchmarks
- [x] **M1: Parallel FFT architectures + vision baselines**
  - Four FFT parallel architectures (OpenMP farm/pipeline, MPI scatter/pipeline)
  - Sequential baselines for Sobel, Canny, LoG
  - CIFAR-10, Tiny ImageNet, COCO datasets
- [ ] **M2: Sobel/Canny/LoG across 4 architectures + BSD500 evaluation** ← *current*
  - Modular `SobelDetector` and `CannyDetector` C++ classes
  - BSD500 dataset integration with ground-truth boundary evaluation
  - Four parallel architectures for each filter
  - PRAM analysis: Amdahl, Brent, Isoefficiency for each combination
  - Jaccard, Dice, SSIM metrics in C++ (`metrics.h`)
- [ ] **M3: Physical cluster assembly & MPI**
- [ ] **M4: Non-blocking communication & failover**
- [ ] **M5: Integration & final benchmarks**

---

## Troubleshooting

### "Container not running"
```bash
make start NODES=2
```

### "Permission denied" errors
```bash
docker exec -u root rpic_master chown -R pi:pi /home/pi/
```

### "SSH connection refused"
```bash
sleep 3
docker exec -u pi rpic_master mpirun -n 2 --host master,worker1 hostname
```

### ARM64 emulation not working
```bash
docker run --privileged --rm tonistiigi/binfmt --install all
docker buildx ls
```

### BSD500 .mat files not loading
```bash
pip install scipy kagglehub
# Verify ground truth path:
ls workspace/vision/datasets/BSDS500/data/groundTruth/test/
```

---

## Additional Resources

- [MPI4Py Documentation](https://mpi4py.readthedocs.io/)
- [OpenMPI Documentation](https://www.open-mpi.org/)
- [BSD500 Dataset on Kaggle](https://www.kaggle.com/datasets/balraj98/berkeley-segmentation-dataset-500-bsds500)
- [BSDS500 Paper](https://www2.eecs.berkeley.edu/Research/Projects/CS/vision/grouping/resources.html)
- Milestone 2 execution plan: `milestone2_execution_plan.md` (see repo root or project docs)
