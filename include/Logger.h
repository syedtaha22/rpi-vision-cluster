/**
 * @file Logger.h
 * @brief Thread-safe logging interface for diagnostics and access logs.
 * @date 1st May, 2026
 * @author Syed Taha
 */

#pragma once

#include <mutex>
#include <string>

 /**
  * @class Logger
  * @brief Thread-safe file logger used by the HTTP server and processing pipeline.
  *
  * Provides dual-output logging capability with separate formatting for internal
  * diagnostics and Apache-style access logs. All public methods are thread-safe
  * via mutex protection.
  */
class Logger {
public:
    /**
     * @brief Creates a logger that appends to the given file path.
     * @param file_path path to log file (created if nonexistent)
     */
    explicit Logger(std::string file_path);

    /**
     * @brief Writes a log line with the supplied severity label.
     * @param level severity level (e.g., "INFO", "WARN", "ERROR")
     * @param message log message text
     */
    void log(const std::string& level, const std::string& message);

    /**
     * @brief Writes an informational log line.
     * @param message log message text
     */
    void info(const std::string& message);

    /**
     * @brief Writes a warning log line.
     * @param message log message text
     */
    void warn(const std::string& message);

    /**
     * @brief Writes an error log line.
     * @param message log message text
     */
    void error(const std::string& message);

    /**
     * @brief Writes an Apache-style access log line to both the terminal and the log file.
     * @param client_ip client IP address
     * @param method HTTP method (e.g., "GET", "POST")
     * @param path request path
     * @param protocol protocol version (e.g., "HTTP/1.1")
     * @param status_code HTTP status code
     */
    void access(const std::string& client_ip, const std::string& method, const std::string& path, const std::string& protocol, int status_code);

private:
    std::string file_path_;  ///< Path to log file
    std::mutex mutex_;        ///< Mutex protecting file writes

    /**
     * @brief Generates ISO 8601 timestamp (YYYY-MM-DD HH:MM:SS).
     * @return formatted timestamp string
     */
    std::string current_timestamp() const;

    /**
     * @brief Generates Apache access log timestamp (DD/Mon/YYYY HH:MM:SS).
     * @return formatted timestamp string
     */
    std::string current_access_timestamp() const;

    /**
     * @brief Appends a line to the log file.
     * @param line line to write
     */
    void write_line(const std::string& line);
};
