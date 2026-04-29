# RPI Vision Cluster

A distributed image processing system built on a Raspberry Pi cluster using MPI (Message Passing Interface) over a cluster of Raspberry Pi nodes.

## Project Structure

```
rpi-vision-cluster/
├── README.md                 # This file
├── hostlists                 # MPI hostlist configuration
│
├── examples/                 # Example MPI programs
│   ├── hello_cluster.c       # Basic MPI test
│   ├── matrix_multiply.c     # Matrix multiplication with profiling
│   └── mpi_latency_test.c    # Communication benchmark
│
└── scripts/                  # Cluster management utilities
    ├── globals.sh           # Shared configuration
    ├── init.sh              # Initialize entire cluster
    ├── init_pi.sh           # Per-node setup (auto-detects master vs worker)
    ├── test.sh              # Test connectivity to all nodes
    ├── upload.sh            # Upload files to master's NFS share
    └── pswdless_ssh.sh      # Setup passwordless SSH
```

## Prerequisites

### Hardware
- Raspberry Pi cluster with hostnames: `rpi-master`, `rpi-worker1` through `rpi-worker<N>`
- Network connectivity between all nodes

### Device Configuration
Each Raspberry Pi must be configured using the Raspberry Pi Imager with the following settings:
- **OS:** Raspberry Pi OS Lite (64-bit)
- **Enable SSH:** Yes
- **Hostname:** `rpi-master` (master), `rpi-worker1`, `rpi-worker2`, etc. (workers)
- **Username/Password:** Same as hostname (e.g., username=`rpi-master`, password=`rpi-master`)
- **Network:** WiFi or Ethernet connection to same network

### Development Machine
- Connected to the same network as the cluster
- SSH installed
- MPI development tools: `mpicc`, `mpic++`, `mpirun`

---

## Setup Workflow

### Step 1: Test Connectivity

Verify all nodes are reachable from your dev machine:

```bash
./scripts/test.sh
./scripts/test.sh -n 3    # If testing with fewer workers
```

Expected output:
```
Result: success=6 fail=0
```

If any nodes fail, check network connectivity and hostname resolution before proceeding.

### Step 2: Setup Passwordless SSH from Dev Machine

Configure SSH keys on your dev machine for all cluster nodes:

```bash
./scripts/pswdless_ssh.sh -a
```

This script:
- Generates SSH keys (if not present)
- Copies keys to rpi-master and all rpi-worker nodes
- Sets correct permissions

You'll be prompted for Pi passwords during this process. Run it again to verify passwordless SSH is working.

### Step 3: Initialize Cluster

Install MPI, build tools, and NFS on all nodes:

```bash
./scripts/init.sh
```

This script:
- Uploads init_pi.sh to all nodes
- Configures NFS server on master node
- Mounts NFS on all worker nodes
- Creates shared folder `/rpi-vision-cluster` accessible from all nodes
- Uploads hostlist for MPI

Wait for completion. Each node initializes sequentially.

### Step 4: Setup Master-to-Worker Passwordless SSH

Master node needs passwordless SSH to workers for MPI to function. Copy and run the setup script:

```bash
./scripts/upload.sh ./scripts/pswdless_ssh.sh
ssh rpi-master@rpi-master.local "sudo bash /rpi-vision-cluster/pswdless_ssh.sh"
```

Without the `-a` flag, the script runs in "local" mode, setting up SSH between master and workers on the cluster.

### Step 5: Verify Setup

Test connectivity again to ensure everything is working:

```bash
./scripts/test.sh
```

Check that NFS is mounted on all nodes:

```bash
ssh rpi-master@rpi-master.local "ls /rpi-vision-cluster/"
ssh rpi-worker1@rpi-worker1.local "ls /rpi-vision-cluster/"
```

---

## Post-Setup Workflow

Once cluster is set up, the typical workflow is:

```bash
# 1. Compile MPI program on dev machine
mpicc examples/hello_cluster.c -o ./hello_cluster -lm -O2

# 2. Upload binary to master (accessible to all nodes via NFS)
./scripts/upload.sh ./hello_cluster

# 3. Run on cluster via master
ssh rpi-master@rpi-master.local "mpirun --hostfile /rpi-vision-cluster/hostlists /rpi-vision-cluster/hello_cluster"
```

All nodes see `/rpi-vision-cluster` with the same files via NFS, eliminating file path issues across nodes.

---

## Configuration

Edit `scripts/globals.sh` to customize:

```bash
MPI_SHARED="/rpi-vision-cluster"     # Shared NFS folder path
NUM_WORKERS=5                         # Number of worker nodes
HOSTLIST_FILE="hostlists"            # MPI hostlist filename
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
MASTER_HOST="rpi-master.local"       # Master hostname
```

---

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `init.sh` | Initialize entire cluster (run once after setup) |
| `init_pi.sh` | Per-node setup (auto-detects master vs worker via hostname) |
| `test.sh` | Test connectivity to all nodes with ping |
| `upload.sh` | Upload files to master's NFS shared folder |
| `pswdless_ssh.sh` | Setup passwordless SSH (with `-a` for all nodes, or local mode for master-worker) |
| `globals.sh` | Shared configuration and utility functions |

---

## Example Programs

### 1. hello_cluster.c - Basic MPI Test

Simple hello world program for testing basic MPI functionality:

```bash
# Upload source to master
./scripts/upload.sh examples/hello_cluster.c

# SSH into master
ssh rpi-master@rpi-master.local
```

In master's shell:

```bash
cd /rpi-vision-cluster
mpicc examples/hello_cluster.c -o hello_cluster -lm -O2
mpirun --hostfile hostlists ./hello_cluster
```


### 2. matrix_multiply.c - Computational Benchmark

800x800 matrix multiplication with MPI profiling and performance metrics:

- Row-wise matrix distribution using `MPI_Scatter`
- Broadcast matrix B with `MPI_Bcast`
- Performance metrics:
  - Computation time (actual math)
  - Communication time (MPI overhead)
  - Per-process timing breakdown
  - GFLOPS calculation

### 3. mpi_latency_test.c - Communication Benchmark

Measures MPI communication overhead across different patterns

**Tests Performed:**
1. **Ping-Pong Latency:** Round-trip time between processes
   - Message sizes: 1B, 1KB, 10KB, 100KB, 1MB
   - 100 iterations with warmup
   - Calculates bandwidth (MB/s)

2. **All-to-All Communication:** Every process sends to every other process

3. **Broadcast Latency:** Master broadcasts to all workers

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

## Troubleshooting

### Nodes unreachable
```bash
# Test connectivity
./scripts/test.sh -n 1

# Test specific node
ping rpi-master.local
ssh rpi-master@rpi-master.local "hostname"
```

### SSH passwordless not working
```bash
# Re-run from dev machine
./scripts/pswdless_ssh.sh -a

# Verify it worked
ssh rpi-master@rpi-master.local "echo OK"
```

### NFS not mounted on workers
```bash
# Check from worker
ssh rpi-worker1@rpi-worker1.local "mount | grep rpi-vision-cluster"

# Check from master
ssh rpi-master@rpi-master.local "showmount -a"
```

### Init script fails on a node
- Check master is initialized first (it's always first in sequence)
- Verify passwordless SSH is working
- Run individually: `ssh rpi-worker1@rpi-worker1.local "sudo bash /tmp/init_pi.sh"`

### Files not visible on all nodes
- Verify NFS is mounted: `ssh rpi-worker1@rpi-worker1.local "mount | grep rpi-vision-cluster"`
- Upload files through master: `./scripts/upload.sh myfile.bin`

---

## Additional Resources

- [OpenMPI Documentation](https://www.open-mpi.org/) - MPI implementation
- [MPI Tutorial](https://mpitutorial.com/) - Comprehensive MPI guide
- [Raspberry Pi Documentation](https://www.raspberrypi.com/documentation/) - Pi setup and configuration
