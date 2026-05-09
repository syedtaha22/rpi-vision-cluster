CXX = g++
CXXFLAGS = -std=c++17 -O2 -Wall -Wextra -pedantic -Iinclude

MPI_RANKS = 6
HOSTFILE = hostlists

TARGET = bin/server
SRC = main.cpp src/Logger.cpp src/SobelProcessor.cpp src/HttpServer.cpp

PIPELINE_SRC = pipeline_sobel.c
PIPELINE_BIN = bin/pipeline_sobel

all: $(TARGET) $(PIPELINE_BIN)

$(TARGET): $(SRC)
	mkdir -p bin logs
	$(CXX) $(CXXFLAGS) -pthread -o $(TARGET) $(SRC)

$(PIPELINE_BIN): $(PIPELINE_SRC)
	mkdir -p bin
	mpicc -O2 -fopenmp $(PIPELINE_SRC) -o $(PIPELINE_BIN) -lm
	chmod +x $(PIPELINE_BIN)

run-pipeline:
	mpirun -np $(MPI_RANKS) --hostfile $(HOSTFILE) $(PIPELINE_BIN)

run-server:
	./$(TARGET) 8000

clean:
	rm -f $(TARGET) $(PIPELINE_BIN)

.PHONY: all run-pipeline run-server clean