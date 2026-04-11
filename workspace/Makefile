.PHONY: all clean detector vision help

# ── Compiler flags ────────────────────────────────────────────────────────────
CXX      := g++
CXXFLAGS := -std=c++17 -O2 -I./include
LDFLAGS  := -lm

MPICXX      := mpic++
MPICXXFLAGS := -std=c++17 -O2

# ── Directories ───────────────────────────────────────────────────────────────
BUILD_DIR := build
SRC_DIR   := src
TESTS_DIR := tests
VISION    := vision

# ── Milestone 2: test_detector (sequential class-based harness) ───────────────
SHARED_SRC := $(SRC_DIR)/sobel.cpp $(SRC_DIR)/canny.cpp
SHARED_OBJ := $(patsubst $(SRC_DIR)/%.cpp, $(BUILD_DIR)/%.o, $(SHARED_SRC))
TEST_BIN   := $(BUILD_DIR)/test_detector

# ── Milestone 2: parallel architecture binaries (built inside cluster) ────────
ARCH1_OMP  := sobel_arch1 log_arch1 canny_arch1
ARCH2_OMP  := sobel_arch2 canny_arch2
ARCH3_MPI  := sobel_arch3 log_arch3 canny_arch3
ARCH4_MPI  := canny_arch4

# ── Default ───────────────────────────────────────────────────────────────────
all: $(TEST_BIN)

help:
	@echo "──────────────────────────────────────────────────────────────"
	@echo " Milestone 2 — workspace Makefile"
	@echo "──────────────────────────────────────────────────────────────"
	@echo " make all          Build test_detector (sequential harness)"
	@echo " make detector     Alias for make all"
	@echo " make vision       Build all 9 parallel architecture binaries"
	@echo " make clean        Remove build/ and results/"
	@echo ""
	@echo " Running test_detector (point at any image directory):"
	@echo "   ./build/test_detector --detector sobel -n 10"
	@echo "   ./build/test_detector --detector canny -n 50 --random \\"
	@echo "     --images-path vision/datasets/BSDS500/data/images/test"
	@echo ""
	@echo " Architecture binaries (compile once, run via root Makefile):"
	@echo "   Arch1 (OMP Farm):     sobel_arch1  log_arch1  canny_arch1"
	@echo "   Arch2 (OMP Pipeline): sobel_arch2  canny_arch2"
	@echo "   Arch3 (MPI Scatter):  sobel_arch3  log_arch3  canny_arch3"
	@echo "   Arch4 (MPI Pipeline): canny_arch4"
	@echo "──────────────────────────────────────────────────────────────"

# ── test_detector ─────────────────────────────────────────────────────────────
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.cpp
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(TEST_BIN): $(TESTS_DIR)/test_detector.cpp $(SHARED_OBJ)
	$(CXX) $(CXXFLAGS) $^ -o $@ $(LDFLAGS)

detector: $(TEST_BIN)
	@echo "Built: ./build/test_detector"

# ── Parallel architecture binaries ───────────────────────────────────────────
# These require mpic++ and are built inside the cluster container.
# Run from the repo root: make compile FILE=vision/sobel_arch1_farm.cpp OUTPUT=sobel_arch1
#
# Or build all at once (must be inside the container shell):
vision:
	@mkdir -p $(BUILD_DIR)
	$(MPICXX) $(MPICXXFLAGS) -fopenmp $(VISION)/sobel_arch1_farm.cpp  -o $(BUILD_DIR)/sobel_arch1 -lm
	$(MPICXX) $(MPICXXFLAGS) -fopenmp $(VISION)/log_arch1_farm.cpp    -o $(BUILD_DIR)/log_arch1   -lm
	$(MPICXX) $(MPICXXFLAGS) -fopenmp $(VISION)/canny_arch1_farm.cpp  -o $(BUILD_DIR)/canny_arch1 -lm
	$(MPICXX) $(MPICXXFLAGS) -fopenmp $(VISION)/sobel_arch2_pipeline.cpp -o $(BUILD_DIR)/sobel_arch2 -lm
	$(MPICXX) $(MPICXXFLAGS) -fopenmp $(VISION)/canny_arch2_pipeline.cpp -o $(BUILD_DIR)/canny_arch2 -lm
	$(MPICXX) $(MPICXXFLAGS) $(VISION)/sobel_arch3_scatter.cpp -o $(BUILD_DIR)/sobel_arch3 -lm
	$(MPICXX) $(MPICXXFLAGS) $(VISION)/log_arch3_scatter.cpp   -o $(BUILD_DIR)/log_arch3   -lm
	$(MPICXX) $(MPICXXFLAGS) $(VISION)/canny_arch3_scatter.cpp -o $(BUILD_DIR)/canny_arch3 -lm
	$(MPICXX) $(MPICXXFLAGS) $(VISION)/canny_arch4_pipeline.cpp -o $(BUILD_DIR)/canny_arch4 -lm
	@echo "All architecture binaries built in ./build/"

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -rf $(BUILD_DIR) results/

.PRECIOUS: $(BUILD_DIR)/%.o
