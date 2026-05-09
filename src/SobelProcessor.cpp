/**
 * @file SobelProcessor.cpp
 * @brief Forwards frames to the MPI Sobel pipeline via WebSocket.
 *
 * The local Sobel implementation has been removed. process() now:
 *   1. Lazily connects (or reconnects) to MPI rank 0 on host_:port_.
 *   2. Performs the WebSocket handshake if not already done.
 *   3. Sends the RGBA frame as a WebSocket binary frame.
 *   4. Reads back the processed RGBA frame from the pipeline.
 *   5. Returns it to HttpServer::handle_websocket.
 *
 * @date 1st May, 2026
 * @author Syed Taha
 */

#include "SobelProcessor.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>

/* ── Simple base64 (needed for the WebSocket handshake accept key) ── */

static const char B64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static std::string base64_encode(const uint8_t* src, size_t len) {
    std::string out;
    out.reserve(((len + 2) / 3) * 4);
    for (size_t i = 0; i < len; i += 3) {
        uint32_t a = src[i];
        uint32_t b = (i + 1 < len) ? src[i + 1] : 0;
        uint32_t c = (i + 2 < len) ? src[i + 2] : 0;
        uint32_t t = (a << 16) | (b << 8) | c;
        out += B64[(t >> 18) & 0x3F];
        out += B64[(t >> 12) & 0x3F];
        out += (i + 1 < len) ? B64[(t >> 6) & 0x3F] : '=';
        out += (i + 2 < len) ? B64[t & 0x3F]        : '=';
    }
    return out;
}

/* ── Minimal SHA-1 (needed to compute Sec-WebSocket-Accept) ── */

static uint32_t rotl32(uint32_t v, unsigned n) {
    return (v << n) | (v >> (32 - n));
}

static void sha1(const uint8_t* data, size_t len, uint8_t out[20]) {
    size_t padded = len + 1;
    while ((padded % 64) != 56) ++padded;
    padded += 8;

    auto* msg = new uint8_t[padded]();
    memcpy(msg, data, len);
    msg[len] = 0x80;
    uint64_t bits = static_cast<uint64_t>(len) * 8;
    for (int i = 7; i >= 0; --i)
        msg[padded - 8 + (7 - i)] = static_cast<uint8_t>((bits >> (i * 8)) & 0xFF);

    uint32_t h0 = 0x67452301u, h1 = 0xEFCDAB89u, h2 = 0x98BADCFEu,
             h3 = 0x10325476u, h4 = 0xC3D2E1F0u;

    for (size_t chunk = 0; chunk < padded; chunk += 64) {
        uint32_t w[80];
        for (int i = 0; i < 16; ++i) {
            size_t o = chunk + static_cast<size_t>(i) * 4;
            w[i] = (static_cast<uint32_t>(msg[o])   << 24)
                 | (static_cast<uint32_t>(msg[o+1]) << 16)
                 | (static_cast<uint32_t>(msg[o+2]) <<  8)
                 |  static_cast<uint32_t>(msg[o+3]);
        }
        for (int i = 16; i < 80; ++i)
            w[i] = rotl32(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1);

        uint32_t a = h0, b = h1, c = h2, d = h3, e = h4;
        for (int i = 0; i < 80; ++i) {
            uint32_t f, k;
            if      (i < 20) { f = (b & c) | (~b & d); k = 0x5A827999u; }
            else if (i < 40) { f =  b ^ c ^ d;          k = 0x6ED9EBA1u; }
            else if (i < 60) { f = (b&c)|(b&d)|(c&d);  k = 0x8F1BBCDCu; }
            else             { f =  b ^ c ^ d;          k = 0xCA62C1D6u; }
            uint32_t t = rotl32(a, 5) + f + e + k + w[i];
            e = d; d = c; c = rotl32(b, 30); b = a; a = t;
        }
        h0 += a; h1 += b; h2 += c; h3 += d; h4 += e;
    }
    delete[] msg;

    uint32_t words[5] = { h0, h1, h2, h3, h4 };
    for (int i = 0; i < 5; ++i) {
        out[i*4+0] = static_cast<uint8_t>((words[i] >> 24) & 0xFF);
        out[i*4+1] = static_cast<uint8_t>((words[i] >> 16) & 0xFF);
        out[i*4+2] = static_cast<uint8_t>((words[i] >>  8) & 0xFF);
        out[i*4+3] = static_cast<uint8_t>( words[i]        & 0xFF);
    }
}

/* ═══════════════════════════════════════════════════════════════════
   SobelProcessor
   ═══════════════════════════════════════════════════════════════════ */

SobelProcessor::SobelProcessor(int width, int height,
                                const std::string& host, int port)
    : width_(width)
    , height_(height)
    , frame_size_(static_cast<size_t>(width) * static_cast<size_t>(height) * 4)
    , host_(host)
    , port_(port)
    , sock_fd_(-1)
{}

SobelProcessor::~SobelProcessor() {
    disconnect();
}

size_t SobelProcessor::frame_size() const {
    return frame_size_;
}

/* ── Low-level socket helpers ── */

bool SobelProcessor::send_all(const uint8_t* buf, size_t len) const {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = ::send(sock_fd_, buf + sent, len - sent, MSG_NOSIGNAL);
        if (n <= 0) return false;
        sent += static_cast<size_t>(n);
    }
    return true;
}

bool SobelProcessor::recv_all(uint8_t* buf, size_t len) const {
    size_t got = 0;
    while (got < len) {
        ssize_t n = ::recv(sock_fd_, buf + got, len - got, 0);
        if (n <= 0) return false;
        got += static_cast<size_t>(n);
    }
    return true;
}

void SobelProcessor::disconnect() const {
    if (sock_fd_ >= 0) {
        ::close(sock_fd_);
        sock_fd_ = -1;
    }
}

/* ── WebSocket handshake (client side) ── */

bool SobelProcessor::connect() {
    disconnect();

    sock_fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
    if (sock_fd_ < 0) return false;

    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(static_cast<uint16_t>(port_));

    // Resolve host (numeric IP or hostname)
    struct hostent* he = ::gethostbyname(host_.c_str());
    if (!he) { disconnect(); return false; }
    memcpy(&addr.sin_addr, he->h_addr_list[0], static_cast<size_t>(he->h_length));

    if (::connect(sock_fd_,
                  reinterpret_cast<struct sockaddr*>(&addr),
                  sizeof(addr)) < 0) {
        disconnect();
        return false;
    }

    // -- HTTP upgrade request --
    // Use a fixed nonce; the pipeline verifies the accept key but we don't
    // need to validate the server's response for this internal connection.
    const std::string nonce = "dGhlIHNhbXBsZSBub25jZQ=="; // "the sample nonce" in base64
    std::string request =
        "GET / HTTP/1.1\r\n"
        "Host: " + host_ + ":" + std::to_string(port_) + "\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: " + nonce + "\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n";

    if (!send_all(reinterpret_cast<const uint8_t*>(request.data()), request.size())) {
        disconnect();
        return false;
    }

    // Read the 101 response (read until \r\n\r\n)
    char buf[2048] = {};
    int total = 0;
    while (total < static_cast<int>(sizeof(buf)) - 1) {
        ssize_t n = ::recv(sock_fd_, buf + total,
                           static_cast<size_t>(sizeof(buf) - 1 - total), 0);
        if (n <= 0) { disconnect(); return false; }
        total += static_cast<int>(n);
        buf[total] = '\0';
        if (strstr(buf, "\r\n\r\n")) break;
    }

    if (!strstr(buf, "101")) {
        // Didn't get a switching-protocols response
        disconnect();
        return false;
    }

    return true;
}

/* ── WebSocket framing ── */

bool SobelProcessor::ws_send_frame(const std::vector<uint8_t>& data) const {
    // Client frames must be masked (RFC 6455 §5.3)
    // Use a fixed mask key for simplicity — this is an internal connection.
    const uint8_t mask[4] = { 0x37, 0xfa, 0x21, 0x3d };

    uint8_t hdr[10];
    int hdr_len = 0;
    hdr[hdr_len++] = 0x82;   // FIN=1, opcode=binary

    const size_t len = data.size();
    if (len <= 125) {
        hdr[hdr_len++] = static_cast<uint8_t>(0x80 | len);   // MASK bit set
    } else if (len <= 65535) {
        hdr[hdr_len++] = 0x80 | 126;
        hdr[hdr_len++] = static_cast<uint8_t>((len >> 8) & 0xFF);
        hdr[hdr_len++] = static_cast<uint8_t>( len       & 0xFF);
    } else {
        hdr[hdr_len++] = 0x80 | 127;
        for (int i = 7; i >= 0; --i)
            hdr[hdr_len++] = static_cast<uint8_t>((len >> (i * 8)) & 0xFF);
    }

    // Append 4-byte masking key
    hdr[hdr_len++] = mask[0];
    hdr[hdr_len++] = mask[1];
    hdr[hdr_len++] = mask[2];
    hdr[hdr_len++] = mask[3];

    if (!send_all(hdr, static_cast<size_t>(hdr_len))) return false;

    // Mask and send payload
    std::vector<uint8_t> masked(len);
    for (size_t i = 0; i < len; ++i)
        masked[i] = data[i] ^ mask[i % 4];

    return send_all(masked.data(), len);
}

std::vector<uint8_t> SobelProcessor::ws_recv_frame() const {
    while (true) {
        uint8_t header[2];
        if (!recv_all(header, 2)) return {};

        const uint8_t opcode = header[0] & 0x0F;
        const bool    masked  = (header[1] & 0x80) != 0;
        uint64_t      plen    = header[1] & 0x7F;

        if (plen == 126) {
            uint8_t ext[2];
            if (!recv_all(ext, 2)) return {};
            plen = (static_cast<uint64_t>(ext[0]) << 8) | ext[1];
        } else if (plen == 127) {
            uint8_t ext[8];
            if (!recv_all(ext, 8)) return {};
            plen = 0;
            for (int i = 0; i < 8; ++i)
                plen = (plen << 8) | ext[i];
        }

        uint8_t mask[4] = {};
        if (masked && !recv_all(mask, 4)) return {};

        std::vector<uint8_t> payload(static_cast<size_t>(plen));
        if (plen > 0 && !recv_all(payload.data(), static_cast<size_t>(plen))) return {};

        if (masked)
            for (size_t i = 0; i < payload.size(); ++i)
                payload[i] ^= mask[i % 4];

        if (opcode == 0x8) return {};   // close frame

        if (opcode == 0x9) {
            // Ping — reply with pong and loop
            uint8_t pong_hdr[2] = { 0x8A, static_cast<uint8_t>(plen & 0x7F) };
            send_all(pong_hdr, 2);
            if (plen > 0) send_all(payload.data(), static_cast<size_t>(plen));
            continue;
        }

        if (opcode == 0x2) return payload;   // binary frame — what we want

        // Any other opcode (text, continuation): skip and loop
    }
}

/* ── Public process() ── */

std::vector<uint8_t> SobelProcessor::process(const std::vector<uint8_t>& rgba) const {
    if (rgba.size() != frame_size_) return {};

    // Lazy connect / reconnect on first call or after a drop
    if (sock_fd_ < 0) {
        if (!const_cast<SobelProcessor*>(this)->connect()) {
            fprintf(stderr, "[SobelProcessor] Failed to connect to pipeline at %s:%d\n",
                    host_.c_str(), port_);
            return {};
        }
    }

    // Send frame to pipeline
    if (!ws_send_frame(rgba)) {
        fprintf(stderr, "[SobelProcessor] Send failed — attempting reconnect\n");
        disconnect();
        if (!const_cast<SobelProcessor*>(this)->connect() || !ws_send_frame(rgba)) {
            fprintf(stderr, "[SobelProcessor] Reconnect failed\n");
            return {};
        }
    }

    // Block until pipeline returns the processed frame
    std::vector<uint8_t> result = ws_recv_frame();
    if (result.empty()) {
        fprintf(stderr, "[SobelProcessor] Recv failed — pipeline may have closed\n");
        disconnect();
        return {};
    }

    if (result.size() != frame_size_) {
        fprintf(stderr, "[SobelProcessor] Result size mismatch: expected %zu got %zu\n",
                frame_size_, result.size());
        return {};
    }

    return result;
}