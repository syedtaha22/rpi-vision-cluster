/**
 * @file HttpServer.h
 * @brief HTTP/WebSocket server interface for frontend and frame processing.
 *
 *
 * @date 1st May, 2026
 * @author Syed Taha
 */

#pragma once

#include <string>

 // Forward declarations to avoid circular dependencies
class Logger;
class SobelProcessor;

/**
 * @class HttpServer
 * @brief Minimal HTTP/WebSocket server for serving the frontend and processing frames.
 *
 * Handles concurrent HTTP requests for static files and JSON endpoints,
 * plus WebSocket streams for real-time frame processing with Sobel edge detection.
 */
class HttpServer {
public:
    /**
     * @brief Creates a server bound to the given port and configured helpers.
     * @param port TCP port to bind to
     * @param logger Logger instance for diagnostics and access logs
     * @param processor SobelProcessor instance for image processing
     * @param static_root root directory for static file serving (default: "public")
     */
    HttpServer(int port, Logger& logger, SobelProcessor& processor, std::string static_root = "public");

    /**
     * @brief Starts accepting connections and handling requests.
     *
     * Enters the main server loop, accepting incoming connections
     * and spawning a thread for each to handle independently.
     */
    void run();

private:
    int port_;                      ///< TCP port number
    Logger& logger_;                ///< Reference to Logger instance
    SobelProcessor& processor_;     ///< Reference to SobelProcessor instance
    std::string static_root_;       ///< Root directory for static files

    /**
     * @brief Processes a single HTTP client request.
     * @param client_fd connected client socket file descriptor
     * @param client_ip client IP address string
     */
    void handle_client(int client_fd, const std::string& client_ip);

    /**
     * @brief Processes WebSocket frames for real-time frame processing.
     * @param client_fd connected WebSocket client socket file descriptor
     */
    void handle_websocket(int client_fd);

    /**
     * @brief Serves a static file from the static_root directory.
     * @param client_fd client socket file descriptor
     * @param path requested file path
     * @return HTTP status code (200, 400, or 404)
     */
    int server_static(int client_fd, const std::string& path);

    /**
     * @brief Sends an HTTP response to the client.
     * @param client_fd client socket file descriptor
     * @param status HTTP status code
     * @param content_type MIME type string
     * @param body response body content
     */
    void send_http_response(int client_fd, int status, const std::string& content_type, const std::string& body);

    /**
     * @brief Logs an HTTP access entry via Logger::access().
     * @param client_ip client IP address
     * @param method HTTP method
     * @param path request path
     * @param status_code HTTP status code
     */
    void log_access(const std::string& client_ip, const std::string& method, const std::string& path, int status_code);
};
