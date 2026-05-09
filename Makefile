# ─────────────────────────────────────────────────────────────────────────────
# Sobel Pipeline Makefile
# ─────────────────────────────────────────────────────────────────────────────
# Targets:
#   make           - build the binary
#   make clean     - remove build artifacts
#   make deploy    - rsync source to all Pi nodes (edit HOSTS below)
#   make run-local - run locally with 6 fake MPI ranks (for testing on one machine)
#
# Requirements:
#   - mpicxx (OpenMPI or MPICH)
#   - OpenMP support (GCC >= 4.9)
#   - libssl-dev / openssl (for WebSocket SHA-1 + base64)
#
# Install on Raspberry Pi:
#   sudo apt install libopenmpi-dev libssl-dev build-essential
# ─────────────────────────────────────────────────────────────────────────────

CXX      := mpicxx
CXXFLAGS := -O2 -std=c++17 -fopenmp -Wall -Wextra
CXXFLAGS += -I.                          # include/ is relative to src/
LDFLAGS  := -lssl -lcrypto -fopenmp

TARGET   := sobel_pipeline
SRC      := src/main.cpp

# ── Pi hostnames or IPs (edit to match your cluster) ─────────────────────────
HOSTS    := rpi-master rpi-worker1 rpi-worker2 rpi-worker3 rpi-worker4 rpi-worker5
DEPLOY_DIR := ~/sobel_pipeline

# ── Build ─────────────────────────────────────────────────────────────────────
.PHONY: all clean deploy run-local

all: $(TARGET)

$(TARGET): $(SRC) include/pipeline.h include/config.h include/httpws.h include/workers.h
	$(CXX) $(CXXFLAGS) -o $@ $(SRC) $(LDFLAGS)
	@echo "✓ Built $(TARGET)"

# ── Clean ────────────────────────────────────────────────────────────────────
clean:
	rm -f $(TARGET)
	@echo "✓ Cleaned"

# ── Deploy to all Pis via rsync ───────────────────────────────────────────────
# Copies source + config. Each Pi compiles its own binary.
# Make sure SSH keys are set up between master and workers.
deploy:
	@for host in $(HOSTS); do \
		echo "→ deploying to $$host..."; \
		ssh $$host "mkdir -p $(DEPLOY_DIR)/src $(DEPLOY_DIR)/include"; \
		rsync -az src/ $$host:$(DEPLOY_DIR)/src/; \
		rsync -az include/ $$host:$(DEPLOY_DIR)/include/; \
		rsync -az Makefile pipeline.conf $$host:$(DEPLOY_DIR)/; \
		ssh $$host "cd $(DEPLOY_DIR) && make"; \
		echo "✓ $$host done"; \
	done

# ── Local test run (6 ranks on one machine, no real Pis needed) ───────────────
# Uses loopback — useful for testing message flow and crashes before cluster deploy.
run-local: $(TARGET)
	mpirun -np 6 ./$(TARGET)

# ── Cluster run (run from master Pi after deploy) ────────────────────────────
# Create hosts.txt with one hostname:slots entry per Pi.
# Example hosts.txt:
#   rpi-master:1
#   rpi-worker1:1
#   rpi-worker2:1
#   rpi-worker3:1
#   rpi-worker4:1
#   rpi-worker5:1
run-cluster: $(TARGET)
	mpirun -np 6 --hostfile hosts.txt $(DEPLOY_DIR)/$(TARGET)

# ── Show config ───────────────────────────────────────────────────────────────
show-config:
	@cat pipeline.conf
