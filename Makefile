.PHONY: help setup start stop restart clean clean-results verify test logs shell destroy compile run \
        rpi-setup rpi-deploy rpi-verify rpi-run rpi-game rpi-teardown rpi-teardown-full rpi-sync rpi-help

# Configuration
NODES ?= 2
FILE ?=
OUTPUT ?= a.out
ARGS ?=

# Map node count to profile
PROFILE_2 = --profile 2-nodes
PROFILE_3 = --profile 3-nodes
PROFILE_4 = --profile 4-nodes
PROFILE_5 = --profile 5-nodes
PROFILE_6 = --profile 6-nodes
PROFILE = $(PROFILE_$(NODES))

# All profiles for cleanup operations
ALL_PROFILES = --profile 2-nodes --profile 3-nodes --profile 4-nodes --profile 5-nodes --profile 6-nodes

# Build hostlist dynamically based on NODES
HOSTLIST_1 = master
HOSTLIST_2 = master,worker1
HOSTLIST_3 = master,worker1,worker2
HOSTLIST_4 = master,worker1,worker2,worker3
HOSTLIST_5 = master,worker1,worker2,worker3,worker4
HOSTLIST_6 = master,worker1,worker2,worker3,worker4,worker5
HOSTLIST = $(HOSTLIST_$(NODES))

# Default target
help:
	@echo "RPI Vision Cluster - Makefile Commands"
	@echo ""
	@echo "Setup:"
	@echo "  make setup [NODES=2]  - Enable ARM64 emulation and build cluster (2-6 nodes)"
	@echo "  make start [NODES=2]  - Start the cluster containers (2-6 nodes)"
	@echo "  make stop             - Stop the cluster containers"
	@echo "  make restart [NODES=2]- Restart the cluster with specified nodes"
	@echo ""
	@echo "Testing:"
	@echo "  make verify     - Verify cluster is working"
	@echo "  make test       - Run MPI test (hello_cluster.py)"
	@echo "  make shell      - Open shell on master node"
	@echo ""
	@echo "Compilation:"
	@echo "  make compile FILE=<file.c> [OUTPUT=name] - Compile C/C++ in cluster (ARM64 MPI)"
	@echo "  make run FILE=<file> [NODES=2]        - Run program (binary or .py) on cluster"
	@echo ""
	@echo "Maintenance:"
	@echo "  make logs       - Show container logs"
	@echo "  make clean      - Stop and remove containers (keep images)"
	@echo "  make destroy    - Complete removal (containers, volumes, images)"
	@echo ""
	@echo "Note: workspace/ folder is mounted at /home/pi/workspace/ on all nodes"
	@echo "      Place source files in workspace/ and binaries will be compiled there"
	@echo ""
	@echo "Examples:"
	@echo "  make setup NODES=4                         - Start cluster with 1 master + 3 workers"
	@echo "  make compile FILE=matrix_multiply.c        - Compile C program in workspace/"
	@echo "  make run FILE=matrix_multiply NODES=4      - Run compiled binary on 4 nodes"
	@echo "  make run FILE=examples/hello_cluster.py NODES=3     - Run Python script on 3 nodes"
	@echo ""

# Check if Docker is installed
check-docker:
	@which docker > /dev/null || (echo "Error: Docker not installed" && exit 1)
	@docker compose version > /dev/null 2>&1 || docker-compose --version > /dev/null 2>&1 || (echo "Error: Docker Compose not installed" && exit 1)

# Enable ARM64 emulation
enable-emulation:
	@echo "Checking ARM64 emulation..."
	@if [ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && grep -q enabled /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then \
		echo "ARM64 emulation already enabled"; \
	else \
		echo "Enabling ARM64 emulation..."; \
		docker run --privileged --rm tonistiigi/binfmt --install all; \
		echo "ARM64 emulation enabled"; \
	fi

# Build and start cluster
setup: check-docker enable-emulation
	@echo ""
	@echo "Building cluster images ($(NODES) nodes: 1 master + $(shell echo $$(($(NODES)-1))) workers)..."
	docker compose $(PROFILE) up -d --build
	@echo ""
	@echo "Waiting for containers to start..."
	@sleep 5
	@echo ""
	@echo "Cluster setup complete!"
	@echo ""
	@make verify

# Start existing cluster
start: check-docker
	@echo "Starting cluster ($(NODES) nodes)..."
	docker compose $(PROFILE) up -d
	@echo "Cluster started"
	@make status

# Stop cluster
stop:
	@echo "Stopping all cluster containers..."
	docker compose $(ALL_PROFILES) down
	@echo "Cluster stopped"

# Restart cluster
restart: stop start

# Show status
status:
	@echo ""
	@echo "Container Status:"
	@docker ps --filter "name=rpic" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "No containers running"
	@echo ""

# Verify cluster
verify: status
	@echo "Verifying cluster connectivity ($(NODES) nodes)..."
	@docker exec -u pi rpic_master mpirun -n $(NODES) --host $(HOSTLIST) hostname 2>/dev/null && echo "Cluster verification: OK" || echo "Cluster verification: FAILED"
	@echo ""

# Run MPI test
test:
	@echo "Running MPI test ($(NODES) nodes)..."
	@echo ""
	docker exec -u pi rpic_master mpirun -n $(NODES) --host $(HOSTLIST) python3 /home/pi/workspace/examples/hello_cluster.py
	@echo ""

# Open shell on master
shell:
	docker exec -it -u pi rpic_master bash

# Show logs
logs:
	docker compose logs --tail=50

# Clean (remove containers, keep images)
clean:
	@echo "Removing all cluster containers..."
	docker compose $(ALL_PROFILES) down
	@echo "Containers removed (images preserved)"

# Complete destruction
destroy:
	@echo "WARNING: This will remove all containers, volumes, and images"
	@echo "Press Ctrl+C to cancel, or wait 5 seconds to continue..."
	@sleep 5
	docker compose $(ALL_PROFILES) down -v --rmi all
	@echo "Complete removal done"

# Delete generated output files (reports, logs, result images)
# Does NOT remove compiled binaries (workspace/build/) or datasets
clean-results:
	@echo "Removing generated reports, logs, and result images..."
	rm -rf report/ report_bsds/ report_resilience/
	rm -f analysis_results.log report_bsds/analysis_bsds.log report_resilience/analysis_resilience.log
	@echo "Removing result images and lists from workspace/results/..."
	rm -rf workspace/results/
	@echo "Done — run any analysis script to regenerate"

# Delete compiled binaries and build sentinel files
clean-builds:
	@echo "Removing compiled binaries and build sentinels..."
	rm -rf workspace/build/*
	rm -f analysis/.build_ok*
	rm -f .build_ok*
	@echo "Build artifacts removed."

# Compile C/C++ in cluster (ARM64 with MPI)
compile:
	@if [ -z "$(FILE)" ]; then \
		echo "Error: FILE parameter required"; \
		echo "Usage: make compile FILE=program.c [OUTPUT=program]"; \
		exit 1; \
	fi
	@echo "Compiling $(FILE) in cluster with MPI..."
	@EXT=$${FILE##*.}; \
	BASENAME=$$(basename $(FILE) .c); \
	BASENAME=$${BASENAME%.cpp}; \
	OUT=$${OUTPUT:-$$BASENAME}; \
	if [ "$$EXT" = "cpp" ] || [ "$$EXT" = "cc" ]; then \
		docker exec -u pi rpic_master bash -c "cd /home/pi/workspace && mpic++ $(FILE) -o $$OUT -lm -O2 -fopenmp"; \
	else \
		docker exec -u pi rpic_master bash -c "cd /home/pi/workspace && mpicc $(FILE) -o $$OUT -lm -O2 -fopenmp"; \
	fi
	@echo "Compiled in cluster: $(FILE) -> workspace/$${OUTPUT:-$$(basename $(FILE) | sed 's/\.[^.]*$$//')}"

# Run program (binary or Python script) on cluster
run:
	@if [ -z "$(FILE)" ]; then \
		echo "Error: FILE parameter required"; \
		echo "Usage: make run FILE=<program> [NODES=2]"; \
		exit 1; \
	fi
	@echo "Running $(FILE) on $(NODES) nodes..."
	@echo ""
	@EXT=$${FILE##*.}; \
	if [ "$$EXT" = "py" ]; then \
		docker exec -u pi rpic_master bash -c "cd /home/pi/workspace && mpirun -n $(NODES) --host $(HOSTLIST) python3 /home/pi/workspace/$(FILE) $(ARGS)"; \
	else \
		docker exec -u pi rpic_master bash -c "cd /home/pi/workspace && mpirun -n $(NODES) --host $(HOSTLIST) /home/pi/workspace/$(FILE) $(ARGS)"; \
	fi
	@echo ""

# =============================================================================
# RPI Real-Hardware Targets
# =============================================================================
# These targets delegate to the rpi/ shell scripts which manage the actual
# Raspberry Pi cluster. All configuration lives in rpi/config.env (gitignored).
# Run 'make rpi-help' for usage, or 'make rpi-setup' to get started.
#
# Environment isolation:
#   - Docker targets (above) use openmpi via the Dockerfile.cluster image.
#   - RPI targets install openmpi-bin + libopenmpi-dev directly on each Pi.
#   - Binaries are ALWAYS compiled on the target platform; never shared.
# =============================================================================

RPI_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))rpi

rpi-help:
	@echo ""
	@echo "RPI Cluster — Real Hardware Targets"
	@echo ""
	@echo "  Setup:"
	@echo "    make rpi-setup             One-time cluster setup (install packages, SSH keys, hostfile)"
	@echo ""
	@echo "  Deploy:"
	@echo "    make rpi-deploy            Sync workspace/ + compile all 18 binaries on cluster"
	@echo "    make rpi-deploy SKIP=sync  Skip rsync, recompile only"
	@echo ""
	@echo "  Run:"
	@echo "    make rpi-run FILTER=sobel ARCH=3 NODES=6 IMAGE=path/to/img.jpg"
	@echo "    make rpi-run FILTER=fft   ARCH=4 NODES=4 IMAGE=path/to/img.jpg"
	@echo "    make rpi-game              MPI number game (smoke test, 3 nodes)"
	@echo ""
	@echo "  Verify / Cleanup:"
	@echo "    make rpi-verify            Full health check (SSH + mpich + binaries + MPI test)"
	@echo "    make rpi-teardown          Clean /tmp artefacts from all nodes"
	@echo "    make rpi-teardown-full     Also wipe ~/workspace/build/ (requires redeploy)"
	@echo ""
	@echo "  Images (scp from laptop, no internet needed on Pis):"
	@echo "    make rpi-sync              Copy BSD(20)+COCO+CIFAR+TinyIN images to all nodes"
	@echo "    make rpi-sync BSD_COUNT=50 Copy up to 50 BSD images"
	@echo ""
	@echo "  Filters : sobel | canny | log | fft"
	@echo "  Archs   : 1 (OMP Farm) | 2 (OMP Pipeline) | 3 (MPI Scatter) | 4 (MPI Pipeline)"
	@echo "  Nodes   : 2 – 6"
	@echo ""
	@echo "  Config  : rpi/config.env (copy from rpi/config.env.template, never committed)"
	@echo ""

rpi-setup:
	@echo "Running RPI cluster setup..."
	@bash $(RPI_DIR)/setup_cluster.sh

rpi-deploy:
	@if [ "$(SKIP)" = "sync" ]; then \
		bash $(RPI_DIR)/deploy.sh --skip-sync; \
	else \
		bash $(RPI_DIR)/deploy.sh; \
	fi

rpi-run:
	@if [ -z "$(FILTER)" ] || [ -z "$(ARCH)" ] || [ -z "$(NODES)" ] || [ -z "$(IMAGE)" ]; then \
		echo "Usage: make rpi-run FILTER=<sobel|canny|log|fft> ARCH=<1-4> NODES=<2-6> IMAGE=<path>"; \
		exit 1; \
	fi
	@bash $(RPI_DIR)/run_vision.sh \
		--filter $(FILTER) --arch $(ARCH) --nodes $(NODES) --image $(IMAGE) \
		$(if $(OUTPUT_DIR),--output-dir $(OUTPUT_DIR),)

rpi-game:
	@bash $(RPI_DIR)/run_game.sh

rpi-verify:
	@bash $(RPI_DIR)/verify.sh

rpi-teardown:
	@bash $(RPI_DIR)/teardown.sh

rpi-teardown-full:
	@bash $(RPI_DIR)/teardown.sh --full

rpi-sync:
	@bash $(RPI_DIR)/sync_images.sh $(if $(BSD_COUNT),--bsd-count $(BSD_COUNT),)
