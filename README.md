# RPI Vision Cluster

A distributed image processing system built on a Raspberry Pi cluster using MPI (Message Passing Interface). This project simulates a Raspberry Pi cluster environment using Docker with ARM64 emulation, enabling development and testing on x86 machines.

## Project Structure

```
rpi-vision-cluster/
├── Makefile                  # Cluster management & compilation commands
├── Dockerfile.cluster        # Container configuration with MPI, SSH, Python
├── docker-compose.yml        # Scalable cluster definition (2-6 nodes)
├── README.md                 # This file
│
└── workspace/                # All files here are mounted in cluster containers
    ├── hello_cluster.py      # MPI test script
    └── examples/             # Example MPI programs
        ├── matrix_multiply.c     # 800x800 matrix multiplication with profiling
        └── mpi_latency_test.c    # Communication benchmark (ping-pong, all-to-all)
```

---

## Quick Start

### 0. Prerequisites
- Docker version 29.2.1 or later
- Docker Compose version 5.0.2 or later
- 8GB+ RAM recommended
- 10GB+ disk space for images

### 1. Makefile Commands

The Makefile provides simple commands for all cluster operations. Run `make help` to see all available commands:

```
RPI Vision Cluster - Makefile Commands

Setup:
  make setup [NODES=2]  - Enable ARM64 emulation and build cluster (2-6 nodes)
  make start [NODES=2]  - Start the cluster containers (2-6 nodes)
  make stop             - Stop the cluster containers
  make restart [NODES=2]- Restart the cluster with specified nodes

Testing:
  make verify     - Verify cluster is working
  make test       - Run MPI test (hello_cluster.py)
  make shell      - Open shell on master node

Compilation:
  make compile FILE=<file.c> [OUTPUT=name] - Compile C/C++ in cluster (ARM64 MPI)
  make run FILE=<file> [NODES=2]        - Run program (binary or .py) on cluster

Maintenance:
  make logs       - Show container logs
  make clean      - Stop and remove containers (keep images)
  make destroy    - Complete removal (containers, volumes, images)

Note: workspace/ folder is mounted at /home/pi/workspace/ on all nodes
      Place source files in workspace/ and binaries will be compiled there

Examples:
  make setup NODES=4                         - Start cluster with 1 master + 3 workers
  make compile FILE=matrix_multiply.c        - Compile C program in workspace/
  make run FILE=matrix_multiply NODES=4      - Run compiled binary on 4 nodes
  make run FILE=hello_cluster.py NODES=3     - Run Python script on 3 nodes
```

### 2. One-Command Setup

```bash
make setup          # Default: 2 nodes (1 master + 1 worker)
make setup NODES=4  # 4 nodes (1 master + 3 workers)
```

This command will:
1. Enable ARM64 emulation (if needed)
2. Build and launch the cluster containers
3. Configure MPI and SSH automatically
4. Verify the setup

**Node Configuration:**
- Minimum: 2 nodes (1 master + 1 worker)
- Maximum: 6 nodes (1 master + 5 workers)
- Default: 2 nodes if not specified

### 3. Verify Installation

```bash
make test NODES=2
```

Expected output:
```
Hello from rank 0 of 2 on host master
Hello from rank 1 of 2 on host worker1
Success! Cluster nodes found: ['master', 'worker1']
```

**Note:** All workspace files are automatically available in containers at `/home/pi/workspace/` - no manual copying needed.

---

## Working with the Cluster

### Start/Stop the Cluster

```bash
# Start with default 2 nodes
make start

# Start with specific node count
make start NODES=4

# Stop all containers
make stop

# Restart with specific node count
make restart NODES=3

# Remove everything
make destroy
```

### Access the Master Node

```bash
make shell
```

Inside the container, all workspace files are available at `/home/pi/workspace/`.

### Check Status

```bash
make status
```

---

## Compiling and Running Programs

### Workspace Access

All files in the `workspace/` folder are automatically mounted to `/home/pi/workspace/` in all containers. Place your programs in the workspace/ directory to make them available to the cluster.

### Python Programs

```bash
# Run Python script directly
make run FILE=hello_cluster.py NODES=2
make run FILE=hello_cluster.py NODES=3
```

### C/C++ Programs

```bash
# Compile for cluster (ARM64 with MPI)
make compile FILE=examples/matrix_multiply.c OUTPUT=matmul

# Run compiled binary
make run FILE=matmul NODES=2
make run FILE=matmul NODES=5
```

### Advanced: Manual Execution

```bash
# Enter the master container
make shell

# Inside container, workspace is at /home/pi/workspace/
cd /home/pi/workspace/

# Compile
mpicc examples/matrix_multiply.c -o matmul -lm

# Run with custom MPI options
mpirun -n 4 --host master,worker1,worker2,worker3 ./matmul
```

---

## Makefile Command Reference

### Cluster Lifecycle

| Command | Description | Example |
|---------|-------------|---------|
| `make setup` | Build and start cluster | `make setup NODES=4` |
| `make start` | Start existing cluster | `make start NODES=2` |
| `make stop` | Stop all containers | `make stop` |
| `make restart` | Stop and start | `make restart NODES=3` |
| `make clean` | Remove containers (keep images) | `make clean` |
| `make destroy` | Remove containers and images | `make destroy` |

### Testing & Verification

| Command | Description | Example |
|---------|-------------|---------|
| `make test` | Run hello_cluster.py test | `make test NODES=3` |
| `make verify` | Verify cluster connectivity | `make verify NODES=5` |
| `make shell` | SSH into master node | `make shell` |
| `make status` | Show container status | `make status` |

### Compilation & Execution

| Command | Description | Example |
|---------|-------------|---------|
| `make compile` | Compile C/C++ for cluster (ARM64) | `make compile FILE=prog.c OUTPUT=prog` |
| `make run` | Run program (binary or .py) | `make run FILE=prog NODES=4` |

**Parameters:**
- `NODES=N` - Number of nodes (2-6, default: 2)
- `FILE=path` - Program file path (relative to workspace)
- `OUTPUT=name` - Output binary name (for compile)

---

## Vision Baselines & FFT Architectures

We have implemented baseline edge detectors (Sobel, Canny, LoG) and four 2D Fast Fourier Transform (FFT) parallel architectures. The project uses `stb_image.h` and `stb_image_write.h`—lightweight, public domain, single-header C libraries—for image loading and saving without requiring heavy external dependencies like OpenCV.

### 1. Dataset Preparation

Before running the vision programs, you must download the necessary datasets. We provide a script that downloads and prepares CIFAR-10, Tiny ImageNet, and COCO (2017 Val) datasets.

```bash
# Download and extract datasets (approx. 1.2GB total)
./download_substantial_datasets.sh
```

This will populate `workspace/vision/datasets/` with:
- `cifar-10/`: Small 32x32 images.
- `tiny-imagenet-200/`: Medium 64x64 images.
- `coco-val2017/`: Large, high-resolution images.

### 1. Compile the Vision Programs

```bash
# Compile Baselines
make compile FILE=vision/baselines.cpp OUTPUT=baselines

# Compile FFT Architectures
make compile FILE=vision/fft_arch1_farm.cpp OUTPUT=fft_arch1
make compile FILE=vision/fft_arch2_pipeline.cpp OUTPUT=fft_arch2
make compile FILE=vision/fft_arch3_dist_dynamic.cpp OUTPUT=fft_arch3
make compile FILE=vision/fft_arch4_dist_pipeline.cpp OUTPUT=fft_arch4
```

### 2. Run the Vision Programs

Use the `ARGS` parameter to pass the image path to the compiled binary. Ensure your cluster is running first (`make start`).

```bash
# Run Baselines (Sequential, 1 node)
make run FILE=baselines NODES=1 ARGS="vision/datasets/coco-val2017/000000000139.jpg"

# Run Architecture 1: Single Node Farm (OpenMP)
make run FILE=fft_arch1 NODES=1 ARGS="vision/datasets/cifar-10/data_batch_1_img_0.png"

# Run Architecture 2: Single Node Pipeline (OpenMP)
make run FILE=fft_arch2 NODES=1 ARGS="vision/datasets/tiny-imagenet-200/test/images/test_0.JPEG"

# Run Architecture 3: Distributed Dynamic (MPI Scatter/Gather)
make run FILE=fft_arch3 NODES=4 ARGS="vision/datasets/coco-val2017/000000000139.jpg"

# Run Architecture 4: Distributed Pipeline (MPI)
make run FILE=fft_arch4 NODES=2 ARGS="vision/datasets/coco-val2017/000000000139.jpg"
```

### 3. Automated Performance Analysis

We provide an automated script to run benchmarks across different architectures, node counts, and thread counts. This script generates a comprehensive log of the results.

```bash
# Ensure the cluster is running (e.g., with 6 nodes)
make start NODES=6

# Run the full analysis suite
./run_analysis.sh
```

The script will:
- Test Serial Baselines.
- Test OpenMP scaling (Arch 1) with 1, 2, and 4 threads.
- Test MPI scaling (Arch 3) with 2, 4, and 6 nodes.
- Test fixed configurations for Arch 2 and Arch 4.
- Save all results to `analysis_results.log`.

---

## Example Programs

### 1. hello_cluster.py - MPI Synchronization Test

Demonstrates proper MPI synchronization using `allgather()`:

```bash
make run FILE=hello_cluster.py NODES=2
```

**Why `allgather` vs `gather`?**
- `gather(root=0)`: Only rank 0 receives data, other ranks can hang
- `allgather()`: All ranks receive data, guaranteed synchronization

### 2. matrix_multiply.c - Computational Benchmark

800x800 matrix multiplication with MPI profiling:

```bash
# Compile
make compile FILE=examples/matrix_multiply.c OUTPUT=matmul

# Run on 2 nodes
make run FILE=matmul NODES=2
```

**Features:**
- Row-wise matrix distribution using `MPI_Scatter`
- Broadcast matrix B with `MPI_Bcast`
- Internal timing with `MPI_Wtime()` showing:
  - Computation time (actual math)
  - Communication time (MPI overhead)
  - Per-process timing breakdown
- GFLOPS calculation

**Measured Results:**

2 Nodes (1 master + 1 worker):
```
Matrix Size:       800x800
Processes:         2
Total Time:        21.6649 seconds
Computation Time:  21.5692 seconds
Communication Time: 0.0942 seconds
Compute/Total:     99.56%
Comm/Total:        0.43%
Performance:       0.05 GFLOPS
```

5 Nodes (1 master + 4 workers):
```
Matrix Size:       800x800
Processes:         5
Total Time:        7.5548 seconds
Computation Time:  6.9004 seconds
Communication Time: 0.6535 seconds
Compute/Total:     91.34%
Comm/Total:        8.65%
Performance:       0.15 GFLOPS
```

**Analysis:**
- Speedup: 2.87x when going from 2 to 5 nodes
- Communication overhead increases: 0.43% to 8.65%
- Performance scales well due to optimized loop ordering and deterministic initialization

### 3. mpi_latency_test.c - Communication Benchmark

Measures MPI communication overhead across different patterns:

```bash
# Compile
make compile FILE=examples/mpi_latency_test.c OUTPUT=latency_test

# Run on 2 nodes
make run FILE=latency_test NODES=2

# Run on 5 nodes
make run FILE=latency_test NODES=5
```

**Tests Performed:**
1. **Ping-Pong Latency:** Round-trip time between master and worker1
   - Message sizes: 1B, 1KB, 10KB, 100KB, 1MB
   - 100 iterations with warmup
   - Calculates bandwidth (MB/s)

2. **All-to-All Communication:** Every process sends to every other process
   - Tests O(n²) scaling behavior

3. **Broadcast Latency:** Master broadcasts to all workers
   - Message sizes: 1KB, 100KB, 1MB

**Measured Results:**

2 Nodes:
```
Ping-Pong       | Size:       1 B | Time:    1301.72 μs
Ping-Pong       | Size:    1024 B | Time:     114.16 μs
Ping-Pong       | Size:   10240 B | Time:     140.65 μs
Ping-Pong       | Size:  102400 B | Time:    1812.50 μs
Ping-Pong       | Size: 1048576 B | Time:    1258.84 μs
Broadcast       | Size:    1024 B | Time:     325.77 μs
Broadcast       | Size: 1048576 B | Time:    1369.34 μs
All-to-All      | Size:    2048 B | Time:     709.82 μs
```

5 Nodes:
```
Ping-Pong       | Size:       1 B | Time:     993.01 μs
Ping-Pong       | Size:    1024 B | Time:     423.73 μs
Ping-Pong       | Size:   10240 B | Time:     618.92 μs
Ping-Pong       | Size:  102400 B | Time:    3710.34 μs
Ping-Pong       | Size: 1048576 B | Time:    4045.55 μs
Broadcast       | Size:    1024 B | Time:     958.04 μs
Broadcast       | Size: 1048576 B | Time:   17537.10 μs
All-to-All      | Size:    5120 B | Time:    3490.50 μs
```

**Observations:**
- All-to-All communication scales poorly: 710μs (2 nodes) → 3491μs (5 nodes) - 4.9x increase
- Broadcast 1MB scales poorly: 1369μs (2 nodes) → 17537μs (5 nodes) - 12.8x increase
- Ping-Pong latency for 1MB: 1259μs (2 nodes) → 4046μs (5 nodes) - 3.2x increase

---

## Performance Measurement with MPI_Wtime()

Add timing directly to your programs to measure computation vs communication overhead:

```c
#include <mpi.h>
#include <stdio.h>

int main(int argc, char** argv) {
    double t_start, t_compute_start, t_compute_end;
    
    MPI_Init(&argc, &argv);
    t_start = MPI_Wtime();
    
    // Your computation
    t_compute_start = MPI_Wtime();
    // ... your code ...
    t_compute_end = MPI_Wtime();
    
    int rank;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    
    if (rank == 0) {
        printf("Computation time: %.6f s\n", t_compute_end - t_compute_start);
        printf("Total time: %.6f s\n", MPI_Wtime() - t_start);
    }
    
    MPI_Finalize();
    return 0;
}
```

See [examples/matrix_multiply.c](examples/matrix_multiply.c) for a complete implementation.

---

## Milestones

- [x] **M0: Virtual cluster & toolchain setup**
  - Docker-based ARM64 emulation (2-6 nodes)
  - Automated setup with `make setup`
  - Workspace volume mounting (no manual file copying)
  - C/C++ and Python compilation workflows
  - MPI latency and computation benchmarks
- [ ] **M1: Multi-threaded single-node processing**
- [ ] **M2: Shared memory IPC & PRAM analysis**
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
# Wait a few seconds after starting containers
sleep 3
docker exec -u pi rpic_master mpirun -n 2 --host master,worker1 hostname
```

### ARM64 emulation not working
```bash
# Manually enable emulation
docker run --privileged --rm tonistiigi/binfmt --install all

# Verify
docker buildx ls
```

### View container logs
```bash
docker logs rpic_master
docker logs rpic_worker1
```

### File not found errors
```bash
# All workspace files are automatically mounted at /home/pi/workspace/
# Use relative paths from project root:
make run FILE=examples/program NODES=2

# Or absolute paths inside container:
make shell
cd /home/pi/workspace/examples/
./program
```

---

## Additional Resources

- [MPI4Py Documentation](https://mpi4py.readthedocs.io/) - Python MPI library
- [OpenMPI Documentation](https://www.open-mpi.org/) - MPI implementation
- [MPI Tutorial](https://mpitutorial.com/) - Comprehensive MPI guide
