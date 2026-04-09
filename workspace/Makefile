.PHONY: all clean detector help

# Compiler and flags
CXX := g++
CXXFLAGS := -std=c++17 -O2 -I./include
LDFLAGS := -lm

# Directories
BUILD_DIR := build
SRC_DIR := src
INCLUDE_DIR := include
TESTS_DIR := tests
RESULTS_DIR := results

# Shared source files
SHARED_SOURCES := $(SRC_DIR)/sobel.cpp $(SRC_DIR)/canny.cpp
SHARED_OBJECTS := $(patsubst $(SRC_DIR)/%.cpp, $(BUILD_DIR)/%.o, $(SHARED_SOURCES))

# Targets
TEST_DETECTOR := $(BUILD_DIR)/test_detector

# Default target
all: $(TEST_DETECTOR)

help:
	@echo "Usage: make [command]"
	@echo ""
	@echo "Commands:"
	@echo "  make all            - Build test_detector"
	@echo "  make detector       - Build test_detector"
	@echo "  make clean          - Remove build artifacts"
	@echo ""
	@echo "Running test_detector:"
	@echo "  ./build/test_detector --detector sobel -n 10"
	@echo "  ./build/test_detector --detector canny -n 10 --random"
	@echo "  ./build/test_detector --help"

# Compile shared objects
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.cpp
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -c $< -o $@

# Compile test_detector
$(TEST_DETECTOR): $(TESTS_DIR)/test_detector.cpp $(SHARED_OBJECTS)
	$(CXX) $(CXXFLAGS) $^ -o $@ $(LDFLAGS)

# Build target
detector: $(TEST_DETECTOR)
	@echo "Built: ./build/test_detector"

# Cleanup
clean:
	rm -rf $(BUILD_DIR) $(RESULTS_DIR)

.PRECIOUS: $(BUILD_DIR)/%.o
