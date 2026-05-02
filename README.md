# RPI Vision Cluster — Milestone 3

A distributed image processing system built on a Raspberry Pi cluster using MPI and OpenMP.
This project supports both a Docker-based emulation environment (x86 with ARM64 emulation) and
direct execution on a **physical 6-node Raspberry Pi cluster**.

## What's New in Milestone 3

Milestone 3 takes the full parallel vision pipeline from Milestone 2 and runs it natively on
physical Raspberry Pi hardware.  Key additions:

- **Physical cluster deployment automation** — `rpi/full_setup.sh`, `rpi/setup_cluster.sh`,
  `rpi/gen_config.sh`, and `rpi/deploy.sh` handle one-shot provisioning, SSH key exchange,
  binary compilation, and multi-node distribution.
- **Native benchmark execution** — all three analysis scripts (`run_analysis.sh`,
  `run_analysis_bsds.sh`, `resilience_analysis.sh`) now support `--native` to SSH into the
  cluster, run MPI jobs, and pull results back to the laptop.
- **`rpi/run_native.sh`** — unified entry point that verifies connectivity, auto-deploys if
  binaries are missing, and invokes the chosen benchmark with a single command.
- **`rpi/run_vision.sh`** — ad-hoc runner for any filter × architecture × node-count
  combination on a single image without a full benchmark sweep.
- **mDNS auto-discovery** (`rpi/gen_config.sh`) — resolves `rpi-master.local` /
  `rpi-workerN.local` hostnames via avahi/getent/ping and writes `rpi/config.env`
  automatically; no manual IP entry needed.
- **Graceful partial-cluster operation** — dead nodes are excluded at runtime rather than
  aborting; benchmarks continue with however many nodes are alive.
- **`rpi/teardown.sh`** — removes compiled artefacts from all nodes (`--full` also wipes
  `build/`).
- **BSDS500 native results** captured in `analysis/report_bsds_rpi/`.

---

## Project Structure

```
PDC_project/
├── Makefile                          # Docker cluster management & compilation
├── Dockerfile.cluster                # Container image with MPI, SSH, Python
├── docker-compose.yml                # Scalable cluster definition (2-6 nodes)
│
├── analysis/                         # Benchmark & report scripts
│   ├── run_analysis.sh               # Benchmark: CIFAR / Tiny ImageNet / COCO
│   ├── run_analysis_bsds.sh          # Benchmark: BSDS500 performance + quality metrics
│   ├── resilience_analysis.sh        # Benchmark: fault tolerance & bully election
│   ├── generate_report.py            # Performance report generator
│   ├── generate_report_bsds.py       # BSDS500 report generator
│   ├── generate_report_resilience.py # Resilience report generator
│   └── report_bsds_rpi/              # BSDS500 results from physical RPi cluster
│
├── rpi/                              # Physical cluster deployment & management
│   ├── config.env.template           # Config template (copy → config.env, fill in IPs)
│   ├── config.env                    # Cluster IPs & credentials (gitignored)
│   ├── gen_config.sh                 # Auto-resolve Pi IPs via mDNS → config.env
│   ├── full_setup.sh                 # Idempotent bootstrap: SSH keys + workspace dirs
│   ├── setup_cluster.sh              # Install mpich/libgomp + SSH provisioning
│   ├── deploy.sh                     # Compile & distribute binaries to all nodes
│   ├── verify.sh                     # Cluster health check (SSH + MPI + binaries)
│   ├── run_native.sh                 # Unified verify → deploy → benchmark entry point
│   ├── run_vision.sh                 # Ad-hoc single-image vision job on the cluster
│   ├── sync_images.sh                # Dataset syncing: laptop → master Pi
│   ├── teardown.sh                   # Remove compiled artefacts from all nodes
│   ├── run_game.sh                   # Interactive MPI smoke test
│   ├── game.cpp / play_game.sh       # Number guessing game (MPI communication demo)
│
└── workspace/                        # Mounted into every container at /home/pi/workspace/
    ├── Makefile                      # Build all binaries (make vision / make all)
    ├── examples/
    │   ├── hello_cluster.py          # MPI connectivity test
    │   ├── matrix_multiply.c
    │   └── mpi_latency_test.c
    └── vision/                       # Parallel architecture source files
        ├── sobel/                    # sobel_arch1–4
        ├── canny/                    # canny_arch1–4
        ├── log/                      # log_arch1–4
        ├── fft/                      # fft_arch1–4
        ├── resilience/               # resilience_test.cpp, bully_election.cpp
        └── shared/                   # stb_image.h/write, fft_utils.h, halo_utils.h,
                                      # metrics.h, baselines.cpp, mat_to_png.*
```

---

## Quick Start

### Prerequisites

**Docker path**
- Docker 29.2.1+, Docker Compose 5.0.2+
- 8 GB+ RAM, 15 GB+ disk space

**Native RPi path**
- Physical Raspberry Pi cluster (1 master + up to 5 workers)
- Laptop on the same network as the Pis
- `avahi-utils` (for mDNS resolution) or the Pis' IPs filled in manually

---

### Docker Quick Start

#### 1. Start the cluster

```bash
make setup          # 2 nodes (1 master + 1 worker)
make setup NODES=4  # 4 nodes
```

#### 2. Run a benchmark

Each analysis script **manages its own datasets automatically** — no separate download step needed.
On first run it downloads what it needs; on subsequent runs it reuses what's already present.

```bash
./analysis/run_analysis.sh          # performance: CIFAR / Tiny ImageNet / COCO
./analysis/run_analysis_bsds.sh     # BSDS500 quality benchmark
./analysis/resilience_analysis.sh   # fault tolerance & bully election
```

Pass `--fix` to wipe and redownload from scratch:

```bash
./analysis/run_analysis.sh          --fix
./analysis/run_analysis_bsds.sh     --fix
./analysis/resilience_analysis.sh   --fix
```

#### 3. Clean generated outputs

```bash
make clean-results   # deletes report/, report_bsds/, report_resilience/, logs
```

---

## Physical RPi Cluster (Native Mode)

### One-Time Setup

Run this **once** after physically assembling the cluster and connecting it to the same network
as your laptop.

```bash
# Step 1 — Resolve Pi hostnames and generate config.env (needs avahi-utils)
bash rpi/gen_config.sh

# Step 2 — Full bootstrap: SSH key exchange, install mpich, create workspace dirs
bash rpi/full_setup.sh
```

`gen_config.sh` tries `avahi-resolve`, then `getent`, then `ping` to resolve
`rpi-master.local` / `rpi-worker{1-5}.local`.  If your Pis use different hostnames,
copy `rpi/config.env.template` to `rpi/config.env` and fill in the IPs manually before
running `full_setup.sh`.

> **Workspace path**: by default binaries and datasets live at
> `~/Desktop/rpi-vision-cluster/workspace` on the Pis and a shared binary dir at
> `/var/tmp/pdc_build` (identical path on every node, required by `mpirun`).
> To change this, edit `RPI_WS_PARENT`, `RPI_WORKSPACE_DIR`, and `RPI_SHARED_BIN` in
> `rpi/config.env` before deploying.

### Compile & Deploy Binaries

```bash
bash rpi/deploy.sh                  # sync workspace/, compile 18 binaries on master,
                                    # distribute to all workers
bash rpi/deploy.sh --skip-sync      # skip rsync (code unchanged)
bash rpi/deploy.sh --skip-compile   # skip compilation (use existing binaries)
bash rpi/deploy.sh --skip-dist      # skip worker distribution
```

### Verify Cluster Health

```bash
bash rpi/verify.sh          # SSH + mpich + binary check + mpirun test on all 6 nodes
bash rpi/verify.sh --quick  # connectivity only
```

### Run Benchmarks Natively

#### Recommended: unified entry point

`run_native.sh` verifies connectivity, auto-deploys if binaries are missing, then invokes the
chosen benchmark:

```bash
bash rpi/run_native.sh                   # performance analysis
bash rpi/run_native.sh --bsds            # BSDS500 quality analysis
bash rpi/run_native.sh --resilience      # resilience / bully election

# Extra flags are forwarded to the analysis script unchanged
bash rpi/run_native.sh --bsds --quick
bash rpi/run_native.sh --bsds --fix
bash rpi/run_native.sh --resilience --nodes 4
```

#### Direct analysis scripts with `--native`

All three analysis scripts also accept `--native` directly:

```bash
./analysis/run_analysis.sh         --native
./analysis/run_analysis_bsds.sh    --native
./analysis/resilience_analysis.sh  --native
```

### Ad-hoc Single-Image Vision Job

```bash
bash rpi/run_vision.sh \
    --filter sobel \
    --arch 3 \
    --nodes 6 \
    --image /path/to/image.jpg \
    --output-dir ./my_results/
```

| Flag | Values | Description |
|---|---|---|
| `--filter` | `sobel`, `canny`, `log`, `fft` | Edge detector |
| `--arch` | `1`–`4` | Parallel architecture |
| `--nodes` | `2`–`6` | MPI node count |
| `--image` | path | Input image (must be local) |
| `--output-dir` | path | Where to save the output image (optional) |

### Interactive Game (MPI Smoke Test)

```bash
bash rpi/deploy.sh       # once, if not already deployed
bash rpi/run_game.sh     # number guessing game across all nodes
```

### Teardown

```bash
bash rpi/teardown.sh         # removes /tmp artefacts from all nodes
bash rpi/teardown.sh --full  # also wipes workspace/build/ on all nodes
```

---

## Benchmark Scripts Reference

### `run_analysis.sh` — Multi-image-size performance

Tests all 4 algorithms × 4 architectures on three image sizes (32 px, 64 px, ~1 MP).

```bash
./analysis/run_analysis.sh                             # full run (Docker)
./analysis/run_analysis.sh --native                    # run on physical RPi cluster
./analysis/run_analysis.sh --quick                     # 1 image, fewer node/thread configs
./analysis/run_analysis.sh --fix                       # redownload datasets first
./analysis/run_analysis.sh --skip-build
./analysis/run_analysis.sh --nodes 2,4 --threads 1,4
./analysis/run_analysis.sh --image /path/to/img.png
./analysis/run_analysis.sh --timeout 90
```

Output: `report/` + `analysis/analysis_results.log`

### `run_analysis_bsds.sh` — BSDS500 quality benchmark

Tests all 4 algorithms × 4 architectures on BSDS500 test images with SSIM / Dice / Jaccard
scoring against ground-truth edge maps.

```bash
./analysis/run_analysis_bsds.sh                        # defaults: 10 images (Docker)
./analysis/run_analysis_bsds.sh --native               # run on physical RPi cluster
./analysis/run_analysis_bsds.sh --n-images 50
./analysis/run_analysis_bsds.sh --quick                # 3 images, fewer configs
./analysis/run_analysis_bsds.sh --fix
./analysis/run_analysis_bsds.sh --skip-build
./analysis/run_analysis_bsds.sh --nodes 2,4 --threads 1,4
./analysis/run_analysis_bsds.sh --timeout 180
```

Output: `report_bsds/` + `report_bsds/analysis_bsds.log`
Native output: `analysis/report_bsds_rpi/`

### `resilience_analysis.sh` — Fault tolerance & bully election

Runs four resilience scenarios (worker crash, slow node, coordinator recovery, partial result)
and three bully election scenarios.

```bash
./analysis/resilience_analysis.sh                      # defaults: 6 nodes (Docker)
./analysis/resilience_analysis.sh --native             # run on physical RPi cluster
./analysis/resilience_analysis.sh --nodes 4            # min 3 required
./analysis/resilience_analysis.sh --quick
./analysis/resilience_analysis.sh --fix
./analysis/resilience_analysis.sh --image /path
./analysis/resilience_analysis.sh --timeout 120
```

Output: `report_resilience/` + `report_resilience/analysis_resilience.log`

---

## Dataset Management

All three analysis scripts share the same download-once / reuse pattern:

| Default (no flag) | `--fix` |
|---|---|
| Check if dataset present | Wipe dataset dir |
| Skip download if images found | Re-download from source |
| Discover first image dynamically | Discover first image dynamically |
| Fail with helpful error if missing | Always gives fresh data |

### Datasets used

| Script | Datasets | Source |
|---|---|---|
| `run_analysis.sh` | CIFAR-10, Tiny ImageNet, COCO Val2017 | Toronto / Stanford / COCO |
| `run_analysis_bsds.sh` | BSDS500 | Kaggle (balraj98/bsds500) |
| `resilience_analysis.sh` | BSDS500 (primary), COCO Val2017 (fallback) | same as above |

For native mode, `--native` syncs required datasets from the laptop to the master Pi before
running (`rpi/sync_images.sh` is invoked automatically).

---

## Building the Architecture Binaries

From inside the cluster (`make shell`) or on the master Pi:

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

All vision source files require `-I./vision/shared`. This is set automatically by `make vision`
and all three benchmark scripts. For manual compilation:

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

## Makefile Reference (Docker)

### Cluster lifecycle

| Command | Description |
|---|---|
| `make setup [NODES=N]` | Build image and start N-node cluster |
| `make start [NODES=N]` | Start existing cluster |
| `make stop` | Stop all containers |
| `make restart [NODES=N]` | Stop and start |
| `make clean` | Remove containers (keep images) |
| `make destroy` | Remove containers and images |

### Output management

| Command | What it removes |
|---|---|
| `make clean-results` | `report/`, `report_bsds/`, `report_resilience/`, `workspace/results/`, log files |
| `make clean` | Docker containers (not images, not results) |
| `make destroy` | Docker containers + volumes + images (not results) |

> `make clean-results` does **not** touch compiled binaries (`workspace/build/`) or datasets.

### Compilation

| Command | Description |
|---|---|
| `make compile FILE=... OUTPUT=...` | Compile C/C++ for ARM64 MPI |
| `make run FILE=... ARGS=...` | Run binary or Python script |

Parameters: `NODES=N` (2–6), `FILE=path`, `OUTPUT=name`, `ARGS="..."`

---

## Milestones

- [x] **M0: Virtual cluster & toolchain setup**
- [x] **M1: Parallel FFT architectures + vision baselines**
- [x] **M2: Sobel / Canny / LoG across 4 architectures + BSDS500 evaluation**
- [x] **M3: Physical cluster assembly, MPI deployment & native benchmarks** ← current
- [ ] **M4: Non-blocking communication & failover**
- [ ] **M5: Integration & final benchmarks**

---

## Troubleshooting

**Container not running:**
```bash
make start NODES=2
```

**Dataset missing / corrupt data:**
```bash
./analysis/run_analysis.sh        --fix
./analysis/run_analysis_bsds.sh   --fix
./analysis/resilience_analysis.sh --fix
```

**Ground-truth metrics skipped:** BSDS500 `.mat` files are missing — usually an interrupted
download. Run `./analysis/run_analysis_bsds.sh --fix`.

**Stale reports from a previous run:**
```bash
make clean-results
./analysis/run_analysis_bsds.sh
```

**ARM64 emulation not working:**
```bash
docker run --privileged --rm tonistiigi/binfmt --install all
```

**Header not found compiling vision files:**
Always include `-I./vision/shared`. The `make vision` target and all benchmark scripts add this
automatically. For manual compilation add it explicitly.

**Permission denied in container:**
```bash
docker exec -u root rpic_master chown -R pi:pi /home/pi/
```

**RPi node unreachable / SSH key rejected:**
```bash
bash rpi/full_setup.sh     # re-run bootstrap (idempotent)
bash rpi/verify.sh         # confirm which nodes pass
```

**Binaries missing on cluster after reboot:**
```bash
bash rpi/deploy.sh         # recompile and redistribute
```

**mpirun hangs or exits unexpectedly:**
```bash
bash rpi/verify.sh         # check that all nodes are alive and have binaries
bash rpi/run_native.sh --fix   # force dataset re-push + fresh run
```

---

## Additional Resources

- [MPI4Py Documentation](https://mpi4py.readthedocs.io/)
- [OpenMPI Documentation](https://www.open-mpi.org/)
- [BSDS500 on Kaggle](https://www.kaggle.com/datasets/balraj98/berkeley-segmentation-dataset-500-bsds500)
- [BSDS500 Paper](https://www2.eecs.berkeley.edu/Research/Projects/CS/vision/grouping/resources.html)
