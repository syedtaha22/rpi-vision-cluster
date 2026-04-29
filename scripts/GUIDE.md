# Cluster Setup Guide

Workflow for setting up and managing a Raspberry Pi MPI cluster.

## Prerequisites

Rasberry Pi's must be configured using the Rasberry Pi Imager with the following settings:
- OS: Raspberry Pi OS Lite (64-bit)
- Enable SSH
- Set hostname (e.g. `rpi-master`, `rpi-worker1`, etc.)
- Set username/password same as hostname
- Connect to WiFi (if not using Ethernet)

On the host machine (dev machine), ensure you are connected to the same network and have SSH and MPI installed. Additionally make sure you have the `hostlists` file configured with the correct hostnames and slots for your cluster.

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

If any nodes fail, check network connectivity before proceeding.

### Step 2: Setup Passwordless SSH from Dev Machine

Configure SSH keys on your dev machine for all cluster nodes:

```bash
./scripts/pswdless_ssh.sh -a
```

This script:
- Generates SSH keys (if not present)
- Copies keys to rpi-master and all rpi-worker nodes
- Sets correct permissions

You'll be prompted for Pi passwords during this process. Run again, to verify passwordless SSH is working

### Step 3: Initialize Cluster

Install MPI, build tools, and NFS on all nodes:

```bash
./scripts/init.sh
```

This script:
- Uploads init_pi.sh to all nodes
- Runs per-node setup (packages, NFS server on master, NFS client mounts on workers)
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

## Post-Setup Workflow

Once cluster is set up, the typical workflow is:

```bash
# 1. Compile MPI program on dev machine
# Note: This has not been tested as of yet. 
# May not work
mpicc examples/hello_cluster.c -o ./bin/hello_cluster -lm -O2

# 2. Upload binary to master (accessible to all nodes via NFS)
./scripts/upload.sh ./bin/hello_cluster

# 3. Run on cluster via master
ssh rpi-master@rpi-master.local "mpirun --hostfile /rpi-vision-cluster/hostlists /rpi-vision-cluster/hello_cluster"
```

All nodes see `/rpi-vision-cluster` with the same files, so file path issues are eliminated.

## Configuration

Edit `globals.sh` to change:

```bash
MPI_SHARED="/rpi-vision-cluster"     # Shared NFS folder path
NUM_WORKERS=5                        # Number of worker nodes
HOSTLIST_FILE="hostlists"            # MPI hostlist filename
SSH_OPTS="..."                       # SSH connection options
MASTER_HOST="rpi-master.local"       # Master hostname
```

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `init.sh` | Initialize entire cluster (run once after setup) |
| `init_pi.sh` | Per-node setup (auto-detects master vs worker) |
| `test.sh` | Test connectivity to all nodes |
| `upload.sh` | Upload files to master's shared folder |
| `pswdless_ssh.sh` | Setup passwordless SSH |
| `globals.sh` | Shared configuration (edit to customize) |
| `help.sh` | Quick reference (`-h` style help) |

## Troubleshooting

**Nodes unreachable:**
```bash
./scripts/test.sh -n 1
ping rpi-master.local
```

**SSH passwordless not working:**
```bash
./scripts/pswdless_ssh.sh -a    # From dev machine
```

**NFS not mounted on workers:**
```bash
ssh rpi-worker1@rpi-worker1.local "mount | grep rpi-vision-cluster"
```

**Init script fails on a node:**
- Check master is initialized first (it's always first in sequence)
- Verify passwordless SSH is working
- Run individually: `ssh rpi-worker1@rpi-worker1.local "sudo bash /tmp/init_pi.sh"`
