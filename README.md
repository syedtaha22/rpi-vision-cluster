# RPI Vision Cluster — Milestone 2

A distributed image processing system built on a Raspberry Pi cluster using MPI and OpenMP.
This project simulates a Raspberry Pi cluster environment using Docker with ARM64 emulation,
enabling development and testing on x86 machines.

## What's New in Milestone 2

Milestone 2 extends the FFT parallel architectures from Milestone 1 with a full implementation
of **Sobel**, **Canny**, and **LoG** edge detectors across four parallel architectures
(OpenMP Farm, OpenMP Pipeline, MPI Scatter-Gather, MPI Pipeline), benchmarked on **BSDS500**
with Jaccard, Dice, and SSIM evaluation metrics.

---

## Project Structure

```
rpi-vision-cluster/
├── Makefile                          # Cluster management, compilation, and cleanup
├── Dockerfile.cluster                # Container image with MPI, SSH, Python
├── docker-compose.yml                # Scalable cluster definition (2-6 nodes)
├── download_substantial_datasets.sh  # Standalone convenience download script (optional)
├── run_analysis.sh                   # Benchmark: CIFAR / Tiny ImageNet / COCO image sizes
├── run_analysis_bsds.sh              # Benchmark: BSDS500 performance + quality metrics
├── resilience_analysis.sh            # Benchmark: fault tolerance & bully election
├── generate_report.py                # Performance report generator
├── generate_report_bsds.py           # BSDS500 report generator
├── generate_report_resilience.py     # Resilience report generator
│
├── rpi/                              # Physical cluster deployment & management
│   ├── config.env                    # Cluster IPs & credentials (gitignored)
│   ├── setup_cluster.sh              # Dependency & SSH provisioning
│   ├── deploy.sh                     # Compilation & binary distribution
│   ├── sync_images.sh                # Dataset syncing to nodes
│   ├── run_game.sh                   # Interactive MPI smoke test
│   └── verify.sh                     # Cluster health & diagnostics
│
├── _dev/                             # Development tools & scratchpad (not pushed)
│   ├── rough_plots.py                # Visual style guide reference
│   ├── game.cpp, play_game.sh        # Number guessing game code
│   └── workspace_to_md.py            # Utility scripts
│
└── workspace/                        # Mounted into every container at /home/pi/workspace/
├── hello_cluster.py                  # MPI connectivity test
├── plot.ipynb                        # Benchmark result visualisation notebook
├── run_bsds500_all.sh                # Full BSDS500 run (all filters x all archs)
│
├── include/                          # Shared C++ headers (sequential harness)
│   ├── sobel.hpp, canny.hpp, image_io.hpp, timing.hpp, utils.hpp
│   ├── stb_image.h, stb_image_write.h
│
├── src/                              # Sequential detector implementations
│   ├── sobel.cpp, canny.cpp
│
├── tests/
│   └── test_detector.cpp             # CLI harness: runs detectors on image directories
│
├── examples/
│   ├── matrix_multiply.c, mpi_latency_test.c
│
└── vision/                           # Parallel architecture source files
    ├── README_METRICS.md
    ├── sobel/                        # sobel_arch1–4
    ├── canny/                        # canny_arch1–4
    ├── log/                          # log_arch1–4
    ├── fft/                          # fft_arch1–4
    ├── resilience/                   # resilience_test.cpp, bully_election.cpp
    └── shared/                       # stb_image.h/write, fft_utils.h, halo_utils.h,
                                      # metrics.h, baselines.cpp
```

---

## Quick Start

### Prerequisites
- Docker 29.2.1+, Docker Compose 5.0.2+
- 8 GB+ RAM, 15 GB+ disk space

### 1. Start the cluster

```bash
make setup          # 2 nodes (1 master + 1 worker)
make setup NODES=4  # 4 nodes
```

### 2. Run a benchmark

Each analysis script **manages its own datasets automatically** — no separate download step needed.
On first run it downloads what it needs; on subsequent runs it reuses what's already present.

```bash
# Performance benchmark (CIFAR / Tiny ImageNet / COCO)
./run_analysis.sh

# BSDS500 quality benchmark
./run_analysis_bsds.sh

# Resilience & bully election
./resilience_analysis.sh
```

If something looks wrong with the data, pass `--fix` to wipe and redownload from scratch:

```bash
./run_analysis.sh       --fix
./run_analysis_bsds.sh  --fix
./resilience_analysis.sh --fix
```

### 3. Clean generated outputs

```bash
make clean-results   # deletes reports/, logs, workspace/results/ — keeps compiled binaries
```

---

## Dataset Management

All three analysis scripts share the same download-once / reuse pattern:

| Default (no flag) | `--fix` |
|---|---|
| Check if dataset present in container | Wipe dataset dir in container |
| Skip download if images found | Re-download from source |
| Discover first image dynamically | Discover first image dynamically |
| Fail with helpful error if missing | Always gives fresh data |

All dataset paths are resolved dynamically via `find` after the ensure step, so the scripts
work regardless of minor differences in directory layout between machines or Kaggle download
versions. The container workspace root `/home/pi/workspace` is fixed by the Docker bind-mount
and treated as a constant (`CONT_WS`).

### Datasets used

| Script | Datasets | Source |
|---|---|---|
| `run_analysis.sh` | CIFAR-10, Tiny ImageNet, COCO Val2017 | Toronto / Stanford / COCO |
| `run_analysis_bsds.sh` | BSDS500 | Kaggle (balraj98/bsds500) |
| `resilience_analysis.sh` | BSDS500 (primary), COCO Val2017 (fallback) | same as above |

`download_substantial_datasets.sh` is still included as a convenience script if you want to
pre-download everything in one shot before running any analysis.

---

## Benchmark Scripts

### `run_analysis.sh` — Multi-image-size performance

Tests all 4 algorithms x 4 architectures on three image sizes (32px, 64px, ~1MP).

```bash
./run_analysis.sh                          # full run, defaults
./run_analysis.sh --quick                  # 1 image, fewer node/thread configs
./run_analysis.sh --fix                    # redownload all datasets first
./run_analysis.sh --skip-build             # skip recompilation
./run_analysis.sh --nodes 2,4 --threads 1,4
./run_analysis.sh --image /path/to/img.png # use a specific image, skip dataset check
./run_analysis.sh --timeout 90             # per-run timeout in seconds
```

Output: `report/` directory + `analysis_results.log`

### `run_analysis_bsds.sh` — BSDS500 quality benchmark

Tests all 4 algorithms x 4 architectures on BSDS500 test images with SSIM/Dice/Jaccard scoring
against ground-truth edge maps.

```bash
./run_analysis_bsds.sh                     # defaults (10 images)
./run_analysis_bsds.sh --n-images 50
./run_analysis_bsds.sh --quick             # 3 images, fewer configs
./run_analysis_bsds.sh --fix               # redownload BSDS500 first
./run_analysis_bsds.sh --skip-build
./run_analysis_bsds.sh --nodes 2,4 --threads 1,4
./run_analysis_bsds.sh --timeout 180
```

Output: `report_bsds/` directory + `report_bsds/analysis_bsds.log`

### `resilience_analysis.sh` — Fault tolerance & bully election

Runs four resilience scenarios (worker crash, slow node, coordinator recovery, partial result)
and three bully election scenarios.

```bash
./resilience_analysis.sh                   # defaults (6 nodes)
./resilience_analysis.sh --nodes 4         # min 3 required
./resilience_analysis.sh --quick
./resilience_analysis.sh --fix             # redownload BSDS500/COCO first
./resilience_analysis.sh --image /path     # use a specific image
./resilience_analysis.sh --timeout 120
```

Output: `report_resilience/` directory + `report_resilience/analysis_resilience.log`

---

## Building the Architecture Binaries

From inside the cluster (`make shell`):

```bash
cd /home/pi/workspace
make vision     # builds all 16 filter×arch binaries + bully + resilience into build/
make all        # builds build/test_detector (sequential harness)
```

Or one at a time from the host:

```bash
make compile FILE=vision/sobel/sobel_arch1_farm.cpp OUTPUT=sobel_arch1
make compile FILE=vision/resilience/bully_election.cpp OUTPUT=bully_election
```

All vision source files expect `-I./vision/shared`. This is set automatically by `make vision`
and all three `run_analysis*.sh` scripts. For manual compilation:

```bash
mpic++ -std=c++17 -O2 -fopenmp -I./vision/shared \
  vision/sobel/sobel_arch1_farm.cpp -o build/sobel_arch1 -lm
```

| Architecture | File pattern | Parallelism |
|---|---|---|
| Arch 1 | `*_arch1_farm.cpp` | OpenMP fork-join farm |
| Arch 2 | `*_arch2_pipeline.cpp` | OpenMP stage pipeline |
| Arch 3 | `*_arch3_scatter.cpp` | MPI scatter-gather |
| Arch 4 | `*_arch4_pipeline.cpp` | MPI distributed pipeline |

---

## Makefile Reference

### Cluster lifecycle

| Command | Description | Example |
|---|---|---|
| `make setup` | Build and start cluster | `make setup NODES=4` |
| `make start` | Start existing cluster | `make start NODES=2` |
| `make stop` | Stop all containers | `make stop` |
| `make restart` | Stop and start | `make restart NODES=3` |
| `make clean` | Remove containers (keep images) | `make clean` |
| `make destroy` | Remove containers and images | `make destroy` |

### Output management

| Command | What it removes |
|---|---|
| `make clean-results` | `report/`, `report_bsds/`, `report_resilience/`, `workspace/results/`, log files |
| `make clean` | Docker containers (not images, not results) |
| `make destroy` | Docker containers + volumes + images (not results) |

> `make clean-results` does **not** touch compiled binaries (`workspace/build/`) or datasets.
> Run it before re-running an analysis script to ensure you're looking at fresh output.

### Compilation

| Command | Description | Example |
|---|---|---|
| `make compile FILE=...` | Compile C/C++ for ARM64 MPI | `make compile FILE=vision/sobel/sobel_arch1_farm.cpp OUTPUT=sobel_arch1` |
| `make run FILE=... ARGS=...` | Run binary or Python script | `make run FILE=sobel_arch1 NODES=4` |

Parameters: `NODES=N` (2-6), `FILE=path`, `OUTPUT=name`, `ARGS="..."`

---

## Milestones

- [x] **M0: Virtual cluster & toolchain setup**
- [x] **M1: Parallel FFT architectures + vision baselines**
- [ ] **M2: Sobel/Canny/LoG across 4 architectures + BSDS500 evaluation** <- current
- [ ] **M3: Physical cluster assembly & MPI**
- [ ] **M4: Non-blocking communication & failover**
- [ ] **M5: Integration & final benchmarks**

---

## Troubleshooting

**Container not running:** `make start NODES=2`

**Dataset missing / corrupt data:**
```bash
./run_analysis.sh       --fix
./run_analysis_bsds.sh  --fix
./resilience_analysis.sh --fix
```

**Ground-truth metrics skipped:** The BSDS500 download from Kaggle always includes ground-truth
`.mat` files. If this warning appears it usually means the download was interrupted. Run
`./run_analysis_bsds.sh --fix` to redownload.

**Stale reports from a previous run:**
```bash
make clean-results
./run_analysis_bsds.sh    # regenerates from scratch
```

**ARM64 emulation not working:**
```bash
docker run --privileged --rm tonistiigi/binfmt --install all
```

**Header not found compiling vision files:**
Always include `-I./vision/shared`. The `make vision` target and all benchmark scripts add
this automatically. For manual compilation add it explicitly.

**Permission denied:**
```bash
docker exec -u root rpic_master chown -R pi:pi /home/pi/
```

---

## Additional Resources

- [MPI4Py Documentation](https://mpi4py.readthedocs.io/)
- [OpenMPI Documentation](https://www.open-mpi.org/)
- [BSDS500 on Kaggle](https://www.kaggle.com/datasets/balraj98/berkeley-segmentation-dataset-500-bsds500)
- [BSDS500 Paper](https://www2.eecs.berkeley.edu/Research/Projects/CS/vision/grouping/resources.html)
