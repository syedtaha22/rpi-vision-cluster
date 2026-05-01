/**
 * @file HttpServer.cpp
 * @brief Implementation of HTTP/WebSocket server with Sobel frame processing.
 * @date 1st May, 2026
 * @author Syed Taha
 */

#include "HttpServer.h"

#include "Logger.h"
#include "SobelProcessor.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdint>
#include <cstring>
#include <fstream>
#include <map>
#include <mutex>
#include <iostream>
#include <sstream>
#include <thread>
#include <utility>
#include <vector>

 /**
  * @brief Parsed HTTP request metadata used by the server implementation.
  */
struct HttpRequest {
    std::string method;
    std::string path;
    std::map<std::string, std::string> headers;
};

/**
 * @brief Trims ASCII whitespace from both ends of a string.
 * @param value Input string.
 * @return Trimmed string.
 */
static std::string trim(const std::string& value) {
    size_t start = 0;
    while (start < value.size() && (value[start] == ' ' || value[start] == '\t' || value[start] == '\r' || value[start] == '\n')) {
        ++start;
    }

    size_t end = value.size();
    while (end > start && (value[end - 1] == ' ' || value[end - 1] == '\t' || value[end - 1] == '\r' || value[end - 1] == '\n')) {
        --end;
    }

    return value.substr(start, end - start);
}

/**
 * @brief Converts a string to lowercase ASCII.
 * @param value Input string.
 * @return Lowercase string.
 */
static std::string to_lower(std::string value) {
    for (char& c : value) {
        if (c >= 'A' && c <= 'Z') {
            c = static_cast<char>(c - 'A' + 'a');
        }
    }
    return value;
}

/**
 * @brief Receives exactly the requested number of bytes from a socket.
 * @param fd Socket file descriptor.
 * @param out Output buffer.
 * @param size Number of bytes to receive.
 * @return true on success, false on disconnect or error.
 */
static bool recv_exact(int fd, uint8_t* out, size_t size) {
    size_t received = 0;
    while (received < size) {
        const ssize_t result = recv(fd, out + received, size - received, 0);
        if (result <= 0) {
            return false;
        }
        received += static_cast<size_t>(result);
    }
    return true;
}

/**
 * @brief Sends exactly the requested number of bytes to a socket.
 * @param fd Socket file descriptor.
 * @param data Data buffer.
 * @param size Number of bytes to send.
 * @return true on success, false on disconnect or error.
 */
static bool send_all(int fd, const uint8_t* data, size_t size) {
    size_t sent = 0;
    while (sent < size) {
        const ssize_t result = send(fd, data + sent, size - sent, 0);
        if (result <= 0) {
            return false;
        }
        sent += static_cast<size_t>(result);
    }
    return true;
}

/**
 * @brief Sends a string to a socket.
 * @param fd Socket file descriptor.
 * @param text Text to send.
 * @return true on success, false on failure.
 */
static bool send_string(int fd, const std::string& text) {
    return send_all(fd, reinterpret_cast<const uint8_t*>(text.data()), text.size());
}

/**
 * @brief Parses a raw HTTP request into a request object.
 * @param raw Full HTTP request header block.
 * @param request Output parsed request.
 * @return true if parsing succeeded, false otherwise.
 */
static bool parse_http_request(const std::string& raw, HttpRequest& request) {
    std::istringstream stream(raw);
    std::string line;

    if (!std::getline(stream, line)) {
        return false;
    }

    line = trim(line);
    std::istringstream first_line(line);
    if (!(first_line >> request.method >> request.path)) {
        return false;
    }

    while (std::getline(stream, line)) {
        line = trim(line);
        if (line.empty()) {
            break;
        }

        const size_t colon = line.find(':');
        if (colon == std::string::npos) {
            continue;
        }

        const std::string key = to_lower(trim(line.substr(0, colon)));
        const std::string value = trim(line.substr(colon + 1));
        request.headers[key] = value;
    }

    return true;
}

/**
 * @brief Reads HTTP headers until the blank line separator is found.
 * @param fd Socket file descriptor.
 * @return Raw header block, or empty string on error.
 */
static std::string read_http_headers(int fd) {
    std::string data;
    char buffer[2048];

    while (data.find("\r\n\r\n") == std::string::npos) {
        const ssize_t result = recv(fd, buffer, sizeof(buffer), 0);
        if (result <= 0) {
            return {};
        }

        data.append(buffer, static_cast<size_t>(result));
        if (data.size() > 16384) {
            return {};
        }
    }

    return data;
}

/**
 * @brief Encodes binary data using Base64.
 * @param data Input bytes.
 * @param size Number of bytes.
 * @return Base64-encoded string.
 */
static std::string base64_encode(const uint8_t* data, size_t size) {
    static const char* kAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve((size + 2) / 3 * 4);

    for (size_t i = 0; i < size; i += 3) {
        const uint32_t octet_a = data[i];
        const uint32_t octet_b = (i + 1 < size) ? data[i + 1] : 0;
        const uint32_t octet_c = (i + 2 < size) ? data[i + 2] : 0;
        const uint32_t triple = (octet_a << 16) | (octet_b << 8) | octet_c;

        out.push_back(kAlphabet[(triple >> 18) & 0x3F]);
        out.push_back(kAlphabet[(triple >> 12) & 0x3F]);
        out.push_back((i + 1 < size) ? kAlphabet[(triple >> 6) & 0x3F] : '=');
        out.push_back((i + 2 < size) ? kAlphabet[triple & 0x3F] : '=');
    }

    return out;
}

/**
 * @brief Rotates a 32-bit value left by the requested number of bits.
 * @param value Value to rotate.
 * @param bits Number of bits to rotate.
 * @return Rotated value.
 */
static uint32_t left_rotate(uint32_t value, uint32_t bits) {
    return (value << bits) | (value >> (32 - bits));
}

/**
 * @brief Computes a SHA-1 digest for the given string.
 * @param input Input data.
 * @return 20-byte digest.
 */
static std::vector<uint8_t> sha1(const std::string& input) {
    uint64_t bit_length = static_cast<uint64_t>(input.size()) * 8;
    std::vector<uint8_t> message(input.begin(), input.end());
    message.push_back(0x80);

    while ((message.size() % 64) != 56) {
        message.push_back(0x00);
    }

    for (int i = 7; i >= 0; --i) {
        message.push_back(static_cast<uint8_t>((bit_length >> (i * 8)) & 0xFF));
    }

    uint32_t h0 = 0x67452301;
    uint32_t h1 = 0xEFCDAB89;
    uint32_t h2 = 0x98BADCFE;
    uint32_t h3 = 0x10325476;
    uint32_t h4 = 0xC3D2E1F0;

    for (size_t chunk = 0; chunk < message.size(); chunk += 64) {
        uint32_t w[80] = { 0 };
        for (int i = 0; i < 16; ++i) {
            const size_t offset = chunk + static_cast<size_t>(i) * 4;
            w[i] = (static_cast<uint32_t>(message[offset]) << 24) |
                (static_cast<uint32_t>(message[offset + 1]) << 16) |
                (static_cast<uint32_t>(message[offset + 2]) << 8) |
                static_cast<uint32_t>(message[offset + 3]);
        }

        for (int i = 16; i < 80; ++i) {
            w[i] = left_rotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
        }

        uint32_t a = h0;
        uint32_t b = h1;
        uint32_t c = h2;
        uint32_t d = h3;
        uint32_t e = h4;

        for (int i = 0; i < 80; ++i) {
            uint32_t f = 0;
            uint32_t k = 0;

            if (i < 20) {
                f = (b & c) | ((~b) & d);
                k = 0x5A827999;
            }
            else if (i < 40) {
                f = b ^ c ^ d;
                k = 0x6ED9EBA1;
            }
            else if (i < 60) {
                f = (b & c) | (b & d) | (c & d);
                k = 0x8F1BBCDC;
            }
            else {
                f = b ^ c ^ d;
                k = 0xCA62C1D6;
            }

            const uint32_t temp = left_rotate(a, 5) + f + e + k + w[i];
            e = d;
            d = c;
            c = left_rotate(b, 30);
            b = a;
            a = temp;
        }

        h0 += a;
        h1 += b;
        h2 += c;
        h3 += d;
        h4 += e;
    }

    std::vector<uint8_t> digest(20);
    const uint32_t words[5] = { h0, h1, h2, h3, h4 };
    for (int i = 0; i < 5; ++i) {
        digest[static_cast<size_t>(i) * 4 + 0] = static_cast<uint8_t>((words[i] >> 24) & 0xFF);
        digest[static_cast<size_t>(i) * 4 + 1] = static_cast<uint8_t>((words[i] >> 16) & 0xFF);
        digest[static_cast<size_t>(i) * 4 + 2] = static_cast<uint8_t>((words[i] >> 8) & 0xFF);
        digest[static_cast<size_t>(i) * 4 + 3] = static_cast<uint8_t>(words[i] & 0xFF);
    }

    return digest;
}

/**
 * @brief Builds the WebSocket accept key for the handshake response.
 * @param key Client-supplied Sec-WebSocket-Key value.
 * @return Base64 encoded accept key.
 */
static std::string websocket_accept_key(const std::string& key) {
    static const std::string kGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const std::vector<uint8_t> digest = sha1(key + kGuid);
    return base64_encode(digest.data(), digest.size());
}

/**
 * @brief Returns a MIME type for a static asset path.
 * @param path Requested path.
 * @return Content type string.
 */
static std::string content_type_for(const std::string& path) {
    if (path.size() >= 5 && path.substr(path.size() - 5) == ".html") {
        return "text/html; charset=utf-8";
    }
    if (path.size() >= 4 && path.substr(path.size() - 4) == ".css") {
        return "text/css; charset=utf-8";
    }
    if (path.size() >= 3 && path.substr(path.size() - 3) == ".js") {
        return "application/javascript; charset=utf-8";
    }
    return "application/octet-stream";
}

HttpServer::HttpServer(int port, Logger& logger, SobelProcessor& processor, std::string static_root)
    : port_(port), logger_(logger), processor_(processor), static_root_(std::move(static_root)) {
}

void HttpServer::send_http_response(int client_fd, int status, const std::string& content_type, const std::string& body) {
    std::string status_text = "OK";
    if (status == 400) {
        status_text = "Bad Request";
    }
    else if (status == 404) {
        status_text = "Not Found";
    }

    std::ostringstream response;
    response << "HTTP/1.1 " << status << " " << status_text << "\r\n";
    response << "Content-Type: " << content_type << "\r\n";
    response << "Content-Length: " << body.size() << "\r\n";
    response << "Connection: close\r\n\r\n";
    response << body;
    send_string(client_fd, response.str());
}

void HttpServer::log_access(const std::string& client_ip, const std::string& method, const std::string& path, int status_code) {
    logger_.access(client_ip, method, path, "HTTP/1.1", status_code);
}

int HttpServer::server_static(int client_fd, const std::string& path) {
    std::string clean_path = path;
    if (clean_path == "/") {
        clean_path = "/index.html";
    }

    if (clean_path.find("..") != std::string::npos) {
        send_http_response(client_fd, 400, "text/plain; charset=utf-8", "Bad request");
        logger_.warn("Rejected static path traversal attempt: " + path);
        return 400;
    }

    const std::string full_path = static_root_ + clean_path;
    std::ifstream file(full_path, std::ios::binary);
    if (!file) {
        send_http_response(client_fd, 404, "text/plain; charset=utf-8", "Not found");
        logger_.warn("Static file not found: " + full_path);
        return 404;
    }

    std::ostringstream body;
    body << file.rdbuf();
    send_http_response(client_fd, 200, content_type_for(clean_path), body.str());
    logger_.info("Served static file: " + full_path);
    return 200;
}

void HttpServer::handle_websocket(int client_fd) {
    std::vector<uint8_t> incoming;
    bool mismatch_logged = false;

    while (true) {
        uint8_t opcode = 0;
        uint64_t payload_len = 0;
        uint8_t mask[4] = { 0, 0, 0, 0 };

        uint8_t header[2];
        if (!recv_exact(client_fd, header, 2)) {
            logger_.info("WebSocket read ended");
            break;
        }

        opcode = header[0] & 0x0F;
        const bool masked = (header[1] & 0x80) != 0;
        payload_len = header[1] & 0x7F;

        if (payload_len == 126) {
            uint8_t ext[2];
            if (!recv_exact(client_fd, ext, 2)) {
                logger_.warn("Failed to read extended WebSocket payload length");
                break;
            }
            payload_len = (static_cast<uint64_t>(ext[0]) << 8) | static_cast<uint64_t>(ext[1]);
        }
        else if (payload_len == 127) {
            uint8_t ext[8];
            if (!recv_exact(client_fd, ext, 8)) {
                logger_.warn("Failed to read 64-bit WebSocket payload length");
                break;
            }
            payload_len = 0;
            for (int i = 0; i < 8; ++i) {
                payload_len = (payload_len << 8) | static_cast<uint64_t>(ext[i]);
            }
        }

        if (masked && !recv_exact(client_fd, mask, 4)) {
            logger_.warn("Failed to read WebSocket masking key");
            break;
        }

        incoming.resize(static_cast<size_t>(payload_len));
        if (payload_len > 0 && !recv_exact(client_fd, incoming.data(), static_cast<size_t>(payload_len))) {
            logger_.warn("Failed to read WebSocket payload");
            break;
        }

        if (masked) {
            for (size_t i = 0; i < incoming.size(); ++i) {
                incoming[i] ^= mask[i % 4];
            }
        }

        if (opcode == 0x8) {
            logger_.info("WebSocket close frame received");
            break;
        }

        if (opcode == 0x9) {
            std::vector<uint8_t> pong;
            pong.reserve(incoming.size());
            pong.insert(pong.end(), incoming.begin(), incoming.end());
            std::vector<uint8_t> out;
            out.push_back(0x8A);
            out.push_back(static_cast<uint8_t>(pong.size()));
            out.insert(out.end(), pong.begin(), pong.end());
            send_all(client_fd, out.data(), out.size());
            continue;
        }

        if (opcode != 0x2) {
            continue;
        }

        const size_t expected = processor_.frame_size();
        if (incoming.size() != expected) {
            if (!mismatch_logged) {
                logger_.warn("WebSocket frame size mismatch: expected " + std::to_string(expected) +
                             " bytes, received " + std::to_string(incoming.size()) + " bytes");
                mismatch_logged = true;
            }
            continue;
        }

        const std::vector<uint8_t> output = processor_.process(incoming);
        if (output.empty()) {
            logger_.warn("Processor returned empty output for matching-size frame");
            continue;
        }

        std::vector<uint8_t> out;
        out.reserve(2 + output.size());
        out.push_back(0x82);

        if (output.size() <= 125) {
            out.push_back(static_cast<uint8_t>(output.size()));
        }
        else if (output.size() <= 65535) {
            out.push_back(126);
            out.push_back(static_cast<uint8_t>((output.size() >> 8) & 0xFF));
            out.push_back(static_cast<uint8_t>(output.size() & 0xFF));
        }
        else {
            out.push_back(127);
            const uint64_t size = output.size();
            for (int i = 7; i >= 0; --i) {
                out.push_back(static_cast<uint8_t>((size >> (i * 8)) & 0xFF));
            }
        }

        out.insert(out.end(), output.begin(), output.end());
        if (!send_all(client_fd, out.data(), out.size())) {
            logger_.warn("Failed sending processed WebSocket frame");
            break;
        }
    }

    logger_.info("WebSocket session ended");
}

void HttpServer::handle_client(int client_fd, const std::string& client_ip) {
    const std::string raw = read_http_headers(client_fd);
    if (raw.empty()) {
        logger_.warn("Failed to read HTTP headers");
        return;
    }

    HttpRequest request;
    if (!parse_http_request(raw, request)) {
        send_http_response(client_fd, 400, "text/plain; charset=utf-8", "Bad request");
        logger_.warn("Failed to parse HTTP request");
        return;
    }

    logger_.info("Incoming request: " + request.method + " " + request.path);

    if (request.method == "GET" && request.path == "/ws") {
        const auto upgrade_it = request.headers.find("upgrade");
        const auto connection_it = request.headers.find("connection");
        const auto key_it = request.headers.find("sec-websocket-key");

        const bool wants_websocket = upgrade_it != request.headers.end() && to_lower(upgrade_it->second) == "websocket" &&
            connection_it != request.headers.end() && to_lower(connection_it->second).find("upgrade") != std::string::npos &&
            key_it != request.headers.end();

        if (!wants_websocket) {
            send_http_response(client_fd, 400, "text/plain; charset=utf-8", "Missing WebSocket headers");
            logger_.warn("Rejected WebSocket upgrade due to missing headers");
            log_access(client_ip, request.method, request.path, 400);
            return;
        }

        const std::string accept_key = websocket_accept_key(key_it->second);
        std::ostringstream response;
        response << "HTTP/1.1 101 Switching Protocols\r\n";
        response << "Upgrade: websocket\r\n";
        response << "Connection: Upgrade\r\n";
        response << "Sec-WebSocket-Accept: " << accept_key << "\r\n\r\n";
        send_string(client_fd, response.str());
        logger_.info("WebSocket upgrade accepted");
        log_access(client_ip, request.method, request.path, 101);

        handle_websocket(client_fd);
        return;
    }

    if (request.method == "GET" && request.path == "/health") {
        send_http_response(client_fd, 200, "application/json; charset=utf-8", "{\"status\":\"ok\"}");
        logger_.info("Health endpoint served");
        log_access(client_ip, request.method, request.path, 200);
        return;
    }

    if (request.method == "GET" && request.path == "/ready") {
        send_http_response(client_fd, 200, "application/json; charset=utf-8", "{\"ready\":true}");
        logger_.info("Readiness endpoint served");
        log_access(client_ip, request.method, request.path, 200);
        return;
    }

    if (request.method == "GET") {
        const int status = server_static(client_fd, request.path);
        log_access(client_ip, request.method, request.path, status);
        return;
    }

    send_http_response(client_fd, 400, "text/plain; charset=utf-8", "Unsupported method");
    logger_.warn("Unsupported HTTP method: " + request.method);
    log_access(client_ip, request.method, request.path, 400);
}

void HttpServer::run() {
    const int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        logger_.error("Failed to create server socket");
        return;
    }

    int yes = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(static_cast<uint16_t>(port_));

    if (bind(server_fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        logger_.error("Failed to bind socket on port " + std::to_string(port_));
        close(server_fd);
        return;
    }

    if (listen(server_fd, 8) < 0) {
        logger_.error("Failed to listen on server socket");
        close(server_fd);
        return;
    }

    logger_.info("Server listening on port " + std::to_string(port_));
    std::cout << "Serving HTTP on 0.0.0.0 port " << port_ << " (http://0.0.0.0:" << port_ << "/) ..." << std::endl;

    while (true) {
        sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        const int client_fd = accept(server_fd, reinterpret_cast<sockaddr*>(&client_addr), &client_len);
        if (client_fd < 0) {
            logger_.warn("Failed to accept incoming connection");
            continue;
        }

        logger_.info("Accepted incoming connection");

        char client_ip_buffer[INET_ADDRSTRLEN] = { 0 };
        if (!inet_ntop(AF_INET, &client_addr.sin_addr, client_ip_buffer, sizeof(client_ip_buffer))) {
            std::snprintf(client_ip_buffer, sizeof(client_ip_buffer), "unknown");
        }
        std::string client_ip = client_ip_buffer;

        std::thread([this, client_fd, client_ip]() {
            handle_client(client_fd, client_ip);
            close(client_fd);
            }).detach();
    }

    close(server_fd);
}
