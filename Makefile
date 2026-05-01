CXX = g++
CXXFLAGS = -std=c++17 -O2 -Wall -Wextra -pedantic -Iinclude

TARGET = bin/server
SRC = main.cpp src/Logger.cpp src/SobelProcessor.cpp src/HttpServer.cpp

all: $(TARGET)

$(TARGET): $(SRC)
	mkdir -p bin logs
	$(CXX) $(CXXFLAGS) -o $(TARGET) $(SRC)

clean:
	rm -f $(TARGET)

.PHONY: all clean
