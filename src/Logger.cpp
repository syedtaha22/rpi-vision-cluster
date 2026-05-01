/**
 * @file Logger.cpp
 * @brief Implementation of thread-safe dual-output logger.
 * @date 1st May, 2026
 * @author Syed Taha
 */

#include "Logger.h"

#include <ctime>
#include <fstream>
#include <iostream>
#include <utility>

Logger::Logger(std::string file_path) : file_path_(std::move(file_path)) {}

std::string Logger::current_timestamp() const {
    std::time_t now = std::time(nullptr);
    std::tm local_tm;
    localtime_r(&now, &local_tm);

    char buffer[32];
    std::strftime(buffer, sizeof(buffer), "%Y-%m-%d %H:%M:%S", &local_tm);
    return std::string(buffer);
}

std::string Logger::current_access_timestamp() const {
    std::time_t now = std::time(nullptr);
    std::tm local_tm;
    localtime_r(&now, &local_tm);

    char buffer[32];
    std::strftime(buffer, sizeof(buffer), "%d/%b/%Y %H:%M:%S", &local_tm);
    return std::string(buffer);
}

void Logger::write_line(const std::string& line) {
    std::ofstream log(file_path_, std::ios::app);
    if (!log) {
        return;
    }

    log << line << "\n";
}

void Logger::log(const std::string& level, const std::string& message) {
    std::lock_guard<std::mutex> lock(mutex_);
    write_line("[" + current_timestamp() + "] [" + level + "] " + message);
}

void Logger::info(const std::string& message) {
    log("INFO", message);
}

void Logger::warn(const std::string& message) {
    log("WARN", message);
}

void Logger::error(const std::string& message) {
    log("ERROR", message);
}

void Logger::access(const std::string& client_ip, const std::string& method, const std::string& path, const std::string& protocol, int status_code) {
    std::lock_guard<std::mutex> lock(mutex_);
    const std::string line = client_ip + " - - [" + current_access_timestamp() + "] \"" + method + " " + path + " " + protocol + "\" " + std::to_string(status_code) + " -";
    std::cout << line << std::endl;
    write_line(line);
}
