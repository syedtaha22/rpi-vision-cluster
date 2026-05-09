/**
 * @file httpws.h
 * @brief Minimal single-header HTTP/1.1 + WebSocket server for the ingestion node.
 *
 * Only implements what we need:
 *   - GET /          -> serve the embedded HTML page
 *   - GET /ws        -> upgrade to WebSocket, receive binary RGBA frames,
 *                       send binary RGBA result frames back
 *
 * Not production-grade. Sufficient for a LAN camera streaming demo.
 *
 * Usage:
 *   HttpWsServer server(8000, frame_callback, result_queue);
 *   server.start();   // spawns accept thread
 *   server.stop();    // graceful shutdown
 *
 * frame_callback is called from a worker thread with raw RGBA bytes each time
 * a WebSocket binary message arrives. It must be thread-safe.
 */

#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <functional>
#include <thread>
#include <mutex>
#include <queue>
#include <atomic>
#include <condition_variable>

// POSIX socket headers
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <fcntl.h>
#include <arpa/inet.h>

// SHA-1 for WebSocket handshake (we roll our own - tiny impl below)
#include <openssl/sha.h>
#include <openssl/bio.h>
#include <openssl/evp.h>
#include <openssl/buffer.h>

// ── Base64 encode (OpenSSL) ───────────────────────────────────────────────────
static inline std::string base64_encode(const uint8_t* data, size_t len) {
    BIO* b64 = BIO_new(BIO_f_base64());
    BIO* mem = BIO_new(BIO_s_mem());
    BIO_push(b64, mem);
    BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
    BIO_write(b64, data, (int)len);
    BIO_flush(b64);
    BUF_MEM* bptr;
    BIO_get_mem_ptr(b64, &bptr);
    std::string result(bptr->data, bptr->length);
    BIO_free_all(b64);
    return result;
}

// ── WebSocket frame builder ───────────────────────────────────────────────────
static inline std::vector<uint8_t> ws_frame_binary(const uint8_t* data, size_t len) {
    std::vector<uint8_t> frame;
    frame.push_back(0x82);  // FIN + binary opcode
    if (len <= 125) {
        frame.push_back((uint8_t)len);
    } else if (len <= 65535) {
        frame.push_back(126);
        frame.push_back((uint8_t)(len >> 8));
        frame.push_back((uint8_t)(len & 0xFF));
    } else {
        frame.push_back(127);
        for (int i = 7; i >= 0; --i)
            frame.push_back((uint8_t)((len >> (i * 8)) & 0xFF));
    }
    frame.insert(frame.end(), data, data + len);
    return frame;
}

// ── Read a WebSocket frame from fd (binary, no fragmentation) ────────────────
// Returns payload bytes or empty on error/close.
static inline std::vector<uint8_t> ws_read_frame(int fd) {
    auto readall = [&](uint8_t* buf, size_t n) -> bool {
        size_t got = 0;
        while (got < n) {
            ssize_t r = recv(fd, buf + got, n - got, 0);
            if (r <= 0) {
              fprintf(stderr, "[ws_read] recv returned %zd after %zu/%zu bytes\n", r, got, n);
              return false;
            } 
            got += r;
        }
        return true;
    };

    uint8_t hdr[2];
    if (!readall(hdr, 2)) return {};

    // bool fin    = (hdr[0] & 0x80) != 0;  // unused for now
    int  opcode = (hdr[0] & 0x0F);
    bool masked = (hdr[1] & 0x80) != 0;
    uint64_t payload_len = (hdr[1] & 0x7F);

    if (opcode == 0x8) return {};  // close frame

    if (payload_len == 126) {
        uint8_t ext[2]; if (!readall(ext, 2)) return {};
        payload_len = ((uint64_t)ext[0] << 8) | ext[1];
    } else if (payload_len == 127) {
        uint8_t ext[8]; if (!readall(ext, 8)) return {};
        payload_len = 0;
        for (int i = 0; i < 8; ++i) payload_len = (payload_len << 8) | ext[i];
    }

    uint8_t mask[4] = {0};
    if (masked) { if (!readall(mask, 4)) return {}; }

    std::vector<uint8_t> payload(payload_len);
    if (!readall(payload.data(), payload_len)) return {};

    if (masked) {
        for (size_t i = 0; i < payload_len; ++i)
            payload[i] ^= mask[i % 4];
    }
    fprintf(stderr, "[ws_read] opcode=%d masked=%d payload_len=%llu\n",
        opcode, (int)masked, (unsigned long long)payload_len);

    return payload;
}

// ── Embedded HTML page (served at GET /) ─────────────────────────────────────
static const char* HTML_PAGE = R"html(<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Sobel Vision Cluster</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Orbitron:wght@400;700;900&display=swap');

  :root {
    --green: #00ff88;
    --dim-green: #00cc66;
    --bg: #050a05;
    --panel: #090f09;
    --border: #0a2a0a;
    --red: #ff3344;
    --amber: #ffaa00;
  }

  * { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background: var(--bg);
    color: var(--green);
    font-family: 'Share Tech Mono', monospace;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 2rem 1rem;
    overflow-x: hidden;
  }

  /* scanline overlay */
  body::before {
    content: '';
    position: fixed; inset: 0;
    background: repeating-linear-gradient(
      0deg,
      transparent,
      transparent 2px,
      rgba(0,0,0,0.08) 2px,
      rgba(0,0,0,0.08) 4px
    );
    pointer-events: none;
    z-index: 9999;
  }

  h1 {
    font-family: 'Orbitron', sans-serif;
    font-weight: 900;
    font-size: clamp(1.2rem, 4vw, 2rem);
    letter-spacing: 0.3em;
    text-transform: uppercase;
    color: var(--green);
    text-shadow: 0 0 20px var(--green), 0 0 40px var(--dim-green);
    margin-bottom: 0.3rem;
  }

  .subtitle {
    font-size: 0.75rem;
    color: var(--dim-green);
    letter-spacing: 0.2em;
    margin-bottom: 2rem;
    opacity: 0.7;
  }

  .grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1.5rem;
    width: 100%;
    max-width: 1100px;
  }

  .panel {
    background: var(--panel);
    border: 1px solid var(--border);
    padding: 1rem;
    position: relative;
  }

  .panel::before {
    content: attr(data-label);
    position: absolute;
    top: -0.6rem; left: 1rem;
    background: var(--panel);
    padding: 0 0.5rem;
    font-size: 0.65rem;
    letter-spacing: 0.15em;
    color: var(--dim-green);
    text-transform: uppercase;
  }

  canvas {
    width: 100%;
    height: auto;
    display: block;
    background: #000;
    image-rendering: pixelated;
  }

  .controls {
    grid-column: 1 / -1;
    display: flex;
    gap: 1rem;
    align-items: center;
    flex-wrap: wrap;
  }

  button {
    font-family: 'Share Tech Mono', monospace;
    font-size: 0.85rem;
    letter-spacing: 0.1em;
    padding: 0.6rem 1.4rem;
    border: 1px solid var(--green);
    background: transparent;
    color: var(--green);
    cursor: pointer;
    text-transform: uppercase;
    transition: all 0.15s;
    position: relative;
    overflow: hidden;
  }

  button:hover {
    background: var(--green);
    color: var(--bg);
    box-shadow: 0 0 20px var(--green);
  }

  button:disabled {
    opacity: 0.3;
    cursor: not-allowed;
  }

  button.danger {
    border-color: var(--red);
    color: var(--red);
  }
  button.danger:hover {
    background: var(--red);
    color: var(--bg);
    box-shadow: 0 0 20px var(--red);
  }

  .status-row {
    display: flex;
    gap: 2rem;
    align-items: center;
    font-size: 0.75rem;
  }

  .dot {
    display: inline-block;
    width: 8px; height: 8px;
    border-radius: 50%;
    background: var(--red);
    margin-right: 0.4rem;
    box-shadow: 0 0 6px var(--red);
    animation: pulse-red 1.5s infinite;
  }
  .dot.live {
    background: var(--green);
    box-shadow: 0 0 6px var(--green);
    animation: pulse-green 1s infinite;
  }

  @keyframes pulse-red   { 0%,100%{opacity:1} 50%{opacity:0.3} }
  @keyframes pulse-green { 0%,100%{opacity:1} 50%{opacity:0.6} }

  .stat { color: var(--amber); }

  .log-panel {
    grid-column: 1 / -1;
    height: 120px;
    overflow-y: auto;
    font-size: 0.7rem;
    line-height: 1.6;
    color: #557755;
    border: 1px solid var(--border);
    background: var(--panel);
    padding: 0.5rem 0.8rem;
  }
  .log-panel p { margin: 0; }
  .log-panel p.err { color: var(--red); }
  .log-panel p.ok  { color: var(--green); }

  @media (max-width: 600px) {
    .grid { grid-template-columns: 1fr; }
    .controls { grid-column: 1; }
    .log-panel { grid-column: 1; }
  }
</style>
</head>
<body>

<h1>Sobel Vision Cluster</h1>
<p class="subtitle">RPI Pipeline &mdash; Edge Detection Stream</p>

<div class="grid">
  <div class="panel" data-label="Camera Input">
    <video id="video" autoplay playsinline muted style="width:100%;display:block;background:#000"></video>
    <canvas id="srcCanvas" style="display:none"></canvas>
  </div>

  <div class="panel" data-label="Sobel Output">
    <canvas id="dstCanvas"></canvas>
  </div>

  <div class="controls">
    <div class="status-row">
      <span><span class="dot" id="dot"></span><span id="statusText">DISCONNECTED</span></span>
      <span>FPS: <span class="stat" id="fps">0</span></span>
      <span>Latency: <span class="stat" id="lat">—</span> ms</span>
      <span>Frames: <span class="stat" id="frameCount">0</span></span>
    </div>
    <button id="startBtn">Start Camera</button>
    <button id="connectBtn" disabled>Connect</button>
    <button id="stopBtn" class="danger" disabled>Stop</button>
  </div>

  <div class="log-panel" id="log"></div>
</div>

<script>
  const video       = document.getElementById('video');
  const srcCanvas   = document.getElementById('srcCanvas');
  const dstCanvas   = document.getElementById('dstCanvas');
  const dot         = document.getElementById('dot');
  const statusText  = document.getElementById('statusText');
  const fpsEl       = document.getElementById('fps');
  const latEl       = document.getElementById('lat');
  const frameCountEl= document.getElementById('frameCount');
  const startBtn    = document.getElementById('startBtn');
  const connectBtn  = document.getElementById('connectBtn');
  const stopBtn     = document.getElementById('stopBtn');
  const logEl       = document.getElementById('log');

  const srcCtx = srcCanvas.getContext('2d');
  const dstCtx = dstCanvas.getContext('2d');

  let ws = null;
  let streaming = false;
  let frameId = 0;
  let frameCount = 0;
  let lastFpsTime = performance.now();
  let fpsFrames = 0;
  let sendTimes = {};  // frameId -> timestamp for latency

  // Capture resolution
  const W = 640, H = 480;
  srcCanvas.width  = W; srcCanvas.height  = H;
  dstCanvas.width  = W; dstCanvas.height  = H;

  function log(msg, cls='') {
    const p = document.createElement('p');
    if (cls) p.className = cls;
    p.textContent = '[' + new Date().toLocaleTimeString() + '] ' + msg;
    logEl.appendChild(p);
    logEl.scrollTop = logEl.scrollHeight;
  }

  function setStatus(label, live) {
    statusText.textContent = label;
    dot.classList.toggle('live', live);
  }

  // ── Camera ────────────────────────────────────────────────────────────────
  startBtn.addEventListener('click', async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { width: W, height: H, facingMode: 'user' }, audio: false
      });
      video.srcObject = stream;
      await video.play();
      log('Camera started', 'ok');
      connectBtn.disabled = false;
      startBtn.disabled = true;
    } catch(e) {
      log('Camera error: ' + e.message, 'err');
    }
  });

  // ── WebSocket ─────────────────────────────────────────────────────────────
  connectBtn.addEventListener('click', () => {
    const host = location.hostname;
    const url  = 'ws://' + host + ':' + location.port + '/ws';
    log('Connecting to ' + url + '...');
    ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';

    ws.onopen = () => {
      setStatus('CONNECTED', true);
      log('WebSocket connected', 'ok');
      connectBtn.disabled = true;
      stopBtn.disabled = false;
      streaming = true;
      requestAnimationFrame(sendFrame);
    };

    ws.onclose = () => {
      setStatus('DISCONNECTED', false);
      log('WebSocket closed');
      streaming = false;
      connectBtn.disabled = false;
      stopBtn.disabled = true;
    };

    ws.onerror = (e) => {
      log('WebSocket error', 'err');
    };

    ws.onmessage = (evt) => {
      // Received a processed RGBA frame back from the cluster
      const data = new Uint8Array(evt.data);

      // First 4 bytes = frame_id (uint32 big-endian) for latency tracking
      const recvFrameId = (data[0]<<24)|(data[1]<<16)|(data[2]<<8)|data[3];
      if (sendTimes[recvFrameId]) {
        const lat = Math.round(performance.now() - sendTimes[recvFrameId]);
        latEl.textContent = lat;
        delete sendTimes[recvFrameId];
      }

      const rgba = data.slice(4);
      const imageData = new ImageData(new Uint8ClampedArray(rgba), W, H);
      dstCtx.putImageData(imageData, 0, 0);

      frameCount++;
      frameCountEl.textContent = frameCount;
      fpsFrames++;
      const now = performance.now();
      if (now - lastFpsTime >= 1000) {
        fpsEl.textContent = fpsFrames;
        fpsFrames = 0;
        lastFpsTime = now;
      }
    };
  });

  stopBtn.addEventListener('click', () => {
    streaming = false;
    if (ws) ws.close();
  });

  // ── Frame capture + send ──────────────────────────────────────────────────
  function sendFrame() {
    if (!streaming || !ws || ws.readyState !== WebSocket.OPEN) return;

    srcCtx.drawImage(video, 0, 0, W, H);
    // Note: getImageData returns a Uint8ClampedArray which may have a larger buffer than W*H*4.
    const pixels = srcCtx.getImageData(0, 0, W, H);
    const id = frameId++ & 0xFFFFFFFF;
    // Allocate exact size, don't trust pixels.data.buffer length
    const raw = new Uint8Array(4 + W * H * 4);
    raw[0] = (id >> 24) & 0xFF;
    raw[1] = (id >> 16) & 0xFF;
    raw[2] = (id >>  8) & 0xFF;
    raw[3] =  id        & 0xFF;
    // pixels.data is Uint8ClampedArray — copy exactly W*H*4 bytes
    for (let i = 0; i < W * H * 4; i++) raw[4 + i] = pixels.data[i];
    sendTimes[id] = performance.now();
    ws.send(raw.buffer);

    // ~30 fps
    setTimeout(() => requestAnimationFrame(sendFrame), 33);
  }
</script>
</body>
</html>
)html";

// ── Client connection state ───────────────────────────────────────────────────
struct WsClient {
    int fd;
    bool upgraded;  // false = still HTTP, true = WebSocket
};

using FrameCallback = std::function<void(uint32_t frame_id,
                                         const std::vector<uint8_t>& rgba,
                                         int width, int height)>;

// ── HttpWsServer ──────────────────────────────────────────────────────────────
class HttpWsServer {
public:
    HttpWsServer(int port, int width, int height, FrameCallback on_frame)
        : port_(port), width_(width), height_(height),
          on_frame_(on_frame), running_(false), listen_fd_(-1) {}

    ~HttpWsServer() { stop(); }

    // Call this to push a processed frame back to the connected WebSocket client.
    void send_result(uint32_t frame_id, const std::vector<uint8_t>& rgba) {
        std::lock_guard<std::mutex> lk(ws_fd_mutex_);
        if (ws_fd_ < 0) return;

        // Prepend frame_id (4 bytes BE) then RGBA
        std::vector<uint8_t> payload(4 + rgba.size());
        payload[0] = (frame_id >> 24) & 0xFF;
        payload[1] = (frame_id >> 16) & 0xFF;
        payload[2] = (frame_id >>  8) & 0xFF;
        payload[3] =  frame_id        & 0xFF;
        memcpy(payload.data() + 4, rgba.data(), rgba.size());

        auto frame = ws_frame_binary(payload.data(), payload.size());
        ssize_t sent = send(ws_fd_, frame.data(), frame.size(), MSG_NOSIGNAL);
        if (sent < 0) {
            fprintf(stderr, "[httpws] send_result failed, client likely closed\n");
        }
    }

    void start() {
        running_ = true;
        accept_thread_ = std::thread(&HttpWsServer::accept_loop, this);
        fprintf(stderr, "[httpws] server started on port %d\n", port_);
    }

    void stop() {
        running_ = false;
        if (listen_fd_ >= 0) { close(listen_fd_); listen_fd_ = -1; }
        if (accept_thread_.joinable()) accept_thread_.join();
    }

private:
    int port_, width_, height_;
    FrameCallback on_frame_;
    std::atomic<bool> running_;
    int listen_fd_;
    std::thread accept_thread_;
    std::mutex ws_fd_mutex_;
    int ws_fd_ = -1;  // only one WS client at a time

    void accept_loop() {
        listen_fd_ = socket(AF_INET, SOCK_STREAM, 0);
        if (listen_fd_ < 0) { perror("[httpws] socket"); return; }

        int opt = 1;
        setsockopt(listen_fd_, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

        sockaddr_in addr{};
        addr.sin_family      = AF_INET;
        addr.sin_addr.s_addr = INADDR_ANY;
        addr.sin_port        = htons(port_);

        if (bind(listen_fd_, (sockaddr*)&addr, sizeof(addr)) < 0) {
            perror("[httpws] bind"); return;
        }
        listen(listen_fd_, 8);
        fprintf(stderr, "[httpws] listening on 0.0.0.0:%d\n", port_);

        while (running_) {
            sockaddr_in client_addr{};
            socklen_t   client_len = sizeof(client_addr);
            int cfd = accept(listen_fd_, (sockaddr*)&client_addr, &client_len);
            if (cfd < 0) { if (running_) perror("[httpws] accept"); break; }

            char ip[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &client_addr.sin_addr, ip, sizeof(ip));
            fprintf(stderr, "[httpws] new connection from %s\n", ip);

            // Handle in a detached thread
            std::thread([this, cfd]() { handle_client(cfd); }).detach();
        }
    }

    void handle_client(int fd) {
        // Read HTTP request
        char buf[4096] = {0};
        ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
        if (n <= 0) { close(fd); return; }
        buf[n] = '\0';

        std::string req(buf);
        bool is_ws_upgrade = (req.find("Upgrade: websocket") != std::string::npos ||
                               req.find("Upgrade: WebSocket") != std::string::npos);
        bool is_ws_path    = (req.find("GET /ws") != std::string::npos);

        if (is_ws_upgrade && is_ws_path) {
            handle_ws_upgrade(fd, req);
        } else {
            serve_http(fd, req);
        }
    }

    void serve_http(int fd, const std::string& req) {
        (void)req;
        std::string body(HTML_PAGE);
        std::string response =
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: text/html; charset=utf-8\r\n"
            "Content-Length: " + std::to_string(body.size()) + "\r\n"
            "Connection: close\r\n"
            "\r\n" + body;
        send(fd, response.c_str(), response.size(), MSG_NOSIGNAL);
        close(fd);
    }

    void handle_ws_upgrade(int fd, const std::string& req) {
        // Extract Sec-WebSocket-Key
        const char* key_header = "Sec-WebSocket-Key: ";
        size_t pos = req.find(key_header);
        if (pos == std::string::npos) { close(fd); return; }
        pos += strlen(key_header);
        size_t end = req.find("\r\n", pos);
        std::string ws_key = req.substr(pos, end - pos);

        // Compute accept key: SHA1(key + magic) -> base64
        const std::string magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        std::string concat = ws_key + magic;
        uint8_t sha1[20];
        SHA1((const uint8_t*)concat.c_str(), concat.size(), sha1);
        std::string accept = base64_encode(sha1, 20);

        std::string handshake =
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: " + accept + "\r\n"
            "\r\n";
        send(fd, handshake.c_str(), handshake.size(), MSG_NOSIGNAL);
        fprintf(stderr, "[httpws] WebSocket handshake complete fd=%d\n", fd);

        {
            std::lock_guard<std::mutex> lk(ws_fd_mutex_);
            if (ws_fd_ >= 0) {
                fprintf(stderr, "[httpws] replacing existing WS client\n");
                close(ws_fd_);
            }
            ws_fd_ = fd;
        }

        // Read frames in a loop
        while (running_) {
            std::vector<uint8_t> payload = ws_read_frame(fd);
            if (payload.empty()) {
                fprintf(stderr, "[httpws] WS client disconnected\n");
                break;
            }
            if (payload.size() < 4) continue;

            // Parse: [frame_id: 4 bytes BE][RGBA]
            uint32_t fid = ((uint32_t)payload[0] << 24) |
                           ((uint32_t)payload[1] << 16) |
                           ((uint32_t)payload[2] <<  8) |
                            (uint32_t)payload[3];

            std::vector<uint8_t> rgba(payload.begin() + 4, payload.end());
            size_t expected = (size_t)width_ * height_ * 4;
            if (rgba.size() != expected) {
                fprintf(stderr, "[httpws] bad frame size: got %zu expected %zu\n",
                        rgba.size(), expected);
                continue;
            }

            fprintf(stderr, "[httpws] got frame_id=%u size=%zu\n", fid, rgba.size());
            on_frame_(fid, rgba, width_, height_);
        }

        {
            std::lock_guard<std::mutex> lk(ws_fd_mutex_);
            if (ws_fd_ == fd) ws_fd_ = -1;
        }
        close(fd);
    }
};
