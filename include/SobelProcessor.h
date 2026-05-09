/**
 * @file SobelProcessor.h
 * @brief Image processing interface for Sobel edge detection.
 *
 * process() forwards frames to the MPI pipeline running on the Pi cluster
 * via a WebSocket connection to the INGESTION rank (rank 0, port 9000).
 * The local C++ Sobel implementation is no longer used.
 *
 * @date 1st May, 2026
 * @author Syed Taha
 */

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

/**
 * @class SobelProcessor
 * @brief Forwards RGBA frames to the MPI Sobel pipeline and returns results.
 *
 * Maintains a persistent WebSocket connection to the INGESTION rank.
 * If the connection drops it attempts one reconnect before returning an
 * empty vector so HttpServer can log the failure gracefully.
 *
 * Wire protocol (matches pipeline_sobel.c INGESTION rank expectations):
 *   Send:    WebSocket binary frame — W*H*4 raw RGBA bytes (no dim header)
 *   Receive: WebSocket binary frame — W*H*4 processed RGBA bytes
 */
class SobelProcessor {
public:
    /**
     * @brief Creates a processor that will connect to the given pipeline host.
     * @param width   image width in pixels  (must match FRAME_WIDTH  in pipeline_sobel.c)
     * @param height  image height in pixels (must match FRAME_HEIGHT in pipeline_sobel.c)
     * @param host    hostname or IP of the Pi running MPI rank 0
     * @param port    TCP port rank 0 listens on (default 9000)
     */
    SobelProcessor(int width, int height,
                   const std::string& host = "127.0.0.1",
                   int port = 9000);

    /**
     * @brief Closes the WebSocket connection to the pipeline.
     */
    ~SobelProcessor();

    // Non-copyable — owns a socket fd
    SobelProcessor(const SobelProcessor&)            = delete;
    SobelProcessor& operator=(const SobelProcessor&) = delete;

    /**
     * @brief Sends an RGBA frame to the MPI pipeline and returns the result.
     *
     * Blocks until the pipeline returns the processed frame.
     * Returns an empty vector on any network or protocol error.
     *
     * @param rgba input RGBA pixel data (must be exactly frame_size() bytes)
     * @return processed RGBA edge data, or empty vector on error
     */
    std::vector<uint8_t> process(const std::vector<uint8_t>& rgba) const;

    /**
     * @brief Returns the configured frame size in bytes (width * height * 4).
     */
    size_t frame_size() const;

private:
    int         width_;
    int         height_;
    size_t      frame_size_;
    std::string host_;
    int         port_;

    mutable int sock_fd_;   ///< Persistent TCP socket to rank 0 (-1 = disconnected)

    /** Opens a TCP connection and performs the WebSocket handshake. */
    bool connect();

    /** Closes the socket. */
    void disconnect() const;

    /** Sends exactly len bytes; returns false on error. */
    bool send_all(const uint8_t* buf, size_t len) const;

    /** Receives exactly len bytes; returns false on error. */
    bool recv_all(uint8_t* buf, size_t len) const;

    /** Wraps data in a WebSocket binary frame and sends it. */
    bool ws_send_frame(const std::vector<uint8_t>& data) const;

    /**
     * Reads one WebSocket frame from the pipeline.
     * Handles ping (replies with pong) and close frames.
     * Returns payload bytes, or empty vector on error/close.
     */
    std::vector<uint8_t> ws_recv_frame() const;
};