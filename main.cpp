/**
 * @file main.cpp
 * @brief Program entry point for the image processing server.
 * @date 1st May, 2026
 * @author Syed Taha
 */

#include "HttpServer.h"
#include "Logger.h"
#include "SobelProcessor.h"

#include <cstdlib>
#include <iostream>

 /**
  * @brief Main entry point initializing and running the HTTP server.
  * @param argc argument count
  * @param argv command line arguments (optional port number)
  * @return exit code
  */
int main(int argc, char** argv) {
    printf("Main::main: Starting server...\n");
    constexpr int kDefaultPort = 8080;
    constexpr int kFrameWidth = 640;
    constexpr int kFrameHeight = 480;

    int port = kDefaultPort;
    if (argc == 2) {
        port = std::atoi(argv[1]);
        if (port <= 0 || port > 65535) {
            std::cerr << "Invalid port\n";
            return 1;
        }
    }

    Logger logger("logs/server.log");
    SobelProcessor processor(kFrameWidth, kFrameHeight, "192.168.1.250", 9000);
    HttpServer server(port, logger, processor);
    server.run();
    return 0;
}
