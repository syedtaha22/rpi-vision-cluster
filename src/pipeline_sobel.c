/**
 * @file pipeline_sobel.c
 * @brief MPI+OpenMP pipeline Sobel edge detection over a Pi cluster.
 *
 * Topology (configured via ./pipeline.conf, not hardcoded by rank):
 *   rank 0  — INGESTION   : TCP server, receives RGBA frames from WiFi client,
 *                            forwards raw bytes to GRAYSCALE worker via MPI.
 *                            Also receives processed frames back and sends to client.
 *   rank N  — GRAYSCALE   : RGBA -> gray, partitions rows, sends blocks+ghosts
 *                            to CONVOLUTION workers.
 *   rank N  — CONVOLUTION : Applies Sobel on its row block, sends magnitude rows
 *                           to THRESHOLD worker.
 *   rank N  — THRESHOLD   : Clamps magnitudes, rebuilds RGBA output frame,
 *                           sends back to INGESTION rank.
 *
 * Config file format (pipeline.conf):
 *   Each line: <rank> <role> <thread_count> <recv_from> <send_to0> [send_to1] [send_to2]
 *   Roles: INGESTION=0, GRAYSCALE=1, CONVOLUTION=2, THRESHOLD=3
 *   Use -1 for unused send_to slots.
 *
 * Example pipeline.conf for 6 Pis:
 *   0 0 4 -1  1  -1 -1
 *   1 1 4  0  2   3  4
 *   2 2 4  1  5  -1 -1
 *   3 2 4  1  5  -1 -1
 *   4 2 4  1  5  -1 -1
 *   5 3 4  2   0 -1 -1
 *
 * Message tags:
 *   TAG_FRAME_META  — frame_id, width, height before raw data
 *   TAG_FRAME_DATA  — raw pixel data (RGBA or gray depending on stage)
 *   TAG_ROW_BLOCK   — block of rows with ghost rows, includes header
 *   TAG_DONE        — sentinel to signal pipeline shutdown
 *
 * Build:
 *   mpicc -O2 -fopenmp pipeline_sobel.c -o pipeline_sobel -lm
 *
 * Run:
 *   mpirun -np 6 --hostfile hosts ./pipeline_sobel
 */

#include <mpi.h>
#include <omp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <math.h>
#include <errno.h>

/* POSIX sockets for TCP client communication */
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

/* ─── Constants ─────────────────────────────────────────────── */

#define CONFIG_PATH       "./src/pipeline.conf"
#define TCP_PORT          9000
#define TCP_BACKLOG       4
#define MAX_SEND_TO       3
#define MAX_RANKS         64

#define ROLE_INGESTION    0
#define ROLE_GRAYSCALE    1
#define ROLE_CONVOLUTION  2
#define ROLE_THRESHOLD    3

#define TAG_FRAME_META    10
#define TAG_FRAME_DATA    11
#define TAG_ROW_BLOCK     12
#define TAG_DONE          99

#define FRAME_WIDTH       640
#define FRAME_HEIGHT      480

/* ─── Structs ────────────────────────────────────────────────── */

typedef struct {
    int role;
    int thread_count;
    int recv_from;
    int send_to[MAX_SEND_TO];   /* -1 = unused */
} WorkerConfig;

/*
 * Header prepended to every TAG_ROW_BLOCK message.
 * Lets THRESHOLD reconstruct frame order from out-of-order arrivals.
 */
typedef struct {
    int frame_id;
    int width;
    int total_rows;     /* full frame height, for reassembly */
    int block_start;    /* first data row in this block (excluding top ghost) */
    int block_end;      /* last data row (exclusive) */
    int has_top_ghost;  /* 1 if first row of payload is a ghost */
    int has_bot_ghost;  /* 1 if last row of payload is a ghost */
} RowBlockHeader;

typedef struct {
    int frame_id;
    int width;
    int height;
} FrameMeta;

/* ─── Config loading ─────────────────────────────────────────── */

static int load_config(int my_rank, WorkerConfig *cfg) {
    FILE *f = fopen(CONFIG_PATH, "r");
    if (!f) {
        fprintf(stderr, "[rank %d] Cannot open %s: %s\n",
                my_rank, CONFIG_PATH, strerror(errno));
        return -1;
    }

    int rank, role, threads, recv_from, s0, s1, s2;
    int found = 0;

    while (fscanf(f, "%d %d %d %d %d %d %d",
                  &rank, &role, &threads, &recv_from, &s0, &s1, &s2) == 7) {
        if (rank == my_rank) {
            cfg->role         = role;
            cfg->thread_count = threads;
            cfg->recv_from    = recv_from;
            cfg->send_to[0]   = s0;
            cfg->send_to[1]   = s1;
            cfg->send_to[2]   = s2;
            found = 1;
            break;
        }
    }

    fclose(f);

    if (!found) {
        fprintf(stderr, "[rank %d] No entry in %s for this rank.\n",
                my_rank, CONFIG_PATH);
        return -1;
    }
    return 0;
}

/* ─── TCP helpers (INGESTION only) ──────────────────────────── */

/*
 * Blocking recv that retries on EINTR and handles partial reads.
 */
static int tcp_recv_all(int fd, void *buf, size_t len) {
    size_t got = 0;
    uint8_t *ptr = (uint8_t *)buf;
    while (got < len) {
        ssize_t n = recv(fd, ptr + got, len - got, 0);
        if (n <= 0) return -1;
        got += (size_t)n;
    }
    return 0;
}

static int tcp_send_all(int fd, const void *buf, size_t len) {
    size_t sent = 0;
    const uint8_t *ptr = (const uint8_t *)buf;
    while (sent < len) {
        ssize_t n = send(fd, ptr + sent, len - sent, MSG_NOSIGNAL);
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

/* ─── Grayscale conversion ───────────────────────────────────── */

/*
 * Fixed-point luma: 0.299R + 0.587G + 0.114B
 * Coefficients scaled to sum to 256 for a clean >> 8 shift.
 */
static inline uint8_t rgba_to_gray(uint8_t r, uint8_t g, uint8_t b) {
    return (uint8_t)((77 * (int)r + 150 * (int)g + 29 * (int)b) >> 8);
}

/* ─── Sobel kernel ───────────────────────────────────────────── */

/*
 * Computes Sobel magnitude for one pixel at (x, y) in a gray buffer.
 * Caller guarantees 1 <= x <= w-2 and 1 <= y <= h-2.
 * Uses integer approximation |Gx|+|Gy| — avoids sqrt per pixel.
 */
static inline int sobel_magnitude(const uint8_t *gray, int w, int x, int y) {
    const int p00 = gray[(y-1)*w + (x-1)];
    const int p01 = gray[(y-1)*w +  x   ];
    const int p02 = gray[(y-1)*w + (x+1)];
    const int p10 = gray[ y   *w + (x-1)];
    const int p12 = gray[ y   *w + (x+1)];
    const int p20 = gray[(y+1)*w + (x-1)];
    const int p21 = gray[(y+1)*w +  x   ];
    const int p22 = gray[(y+1)*w + (x+1)];

    const int gx = -p00 + p02 - 2*p10 + 2*p12 - p20 + p22;
    const int gy =  p00 + 2*p01 + p02 - p20 - 2*p21 - p22;

    int mag = abs(gx) + abs(gy);   /* L1 norm: fast, good enough */
    return mag > 255 ? 255 : mag;
}

/* ─── WebSocket helpers (INGESTION only) ─────────────────────── */

/*
 * Timestamped debug print — always flushes so logs appear in order
 * even when MPI output from multiple ranks is interleaved.
 */
static void ws_dbg(int rank, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stdout, "[INGESTION rank %d | t=%.3f] ", rank, MPI_Wtime());
    vfprintf(stdout, fmt, ap);
    fprintf(stdout, "\n");
    fflush(stdout);
    va_end(ap);
}

/*
 * Rotate left — used by SHA-1.
 */
static uint32_t ws_rotl32(uint32_t v, unsigned n) {
    return (v << n) | (v >> (32 - n));
}

/*
 * SHA-1 over an arbitrary byte string.
 * Output: 20-byte digest written to `out`.
 */
static void ws_sha1(const uint8_t *data, size_t len, uint8_t out[20]) {
    /* Build padded message */
    size_t padded_len = len + 1;
    while ((padded_len % 64) != 56) padded_len++;
    padded_len += 8;

    uint8_t *msg = calloc(padded_len, 1);
    memcpy(msg, data, len);
    msg[len] = 0x80;

    uint64_t bit_len = (uint64_t)len * 8;
    for (int i = 7; i >= 0; i--)
        msg[padded_len - 8 + (7 - i)] = (uint8_t)((bit_len >> (i * 8)) & 0xFF);

    uint32_t h0 = 0x67452301u;
    uint32_t h1 = 0xEFCDAB89u;
    uint32_t h2 = 0x98BADCFEu;
    uint32_t h3 = 0x10325476u;
    uint32_t h4 = 0xC3D2E1F0u;

    for (size_t chunk = 0; chunk < padded_len; chunk += 64) {
        uint32_t w[80];
        for (int i = 0; i < 16; i++) {
            size_t o = chunk + (size_t)i * 4;
            w[i] = ((uint32_t)msg[o]   << 24) | ((uint32_t)msg[o+1] << 16)
                 | ((uint32_t)msg[o+2] <<  8) |  (uint32_t)msg[o+3];
        }
        for (int i = 16; i < 80; i++)
            w[i] = ws_rotl32(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1);

        uint32_t a = h0, b = h1, c = h2, d = h3, e = h4;
        for (int i = 0; i < 80; i++) {
            uint32_t f, k;
            if      (i < 20) { f = (b & c) | (~b & d); k = 0x5A827999u; }
            else if (i < 40) { f = b ^ c ^ d;           k = 0x6ED9EBA1u; }
            else if (i < 60) { f = (b&c)|(b&d)|(c&d);  k = 0x8F1BBCDCu; }
            else             { f = b ^ c ^ d;            k = 0xCA62C1D6u; }
            uint32_t t = ws_rotl32(a, 5) + f + e + k + w[i];
            e = d; d = c; c = ws_rotl32(b, 30); b = a; a = t;
        }
        h0 += a; h1 += b; h2 += c; h3 += d; h4 += e;
    }
    free(msg);

    uint32_t words[5] = { h0, h1, h2, h3, h4 };
    for (int i = 0; i < 5; i++) {
        out[i*4+0] = (uint8_t)((words[i] >> 24) & 0xFF);
        out[i*4+1] = (uint8_t)((words[i] >> 16) & 0xFF);
        out[i*4+2] = (uint8_t)((words[i] >>  8) & 0xFF);
        out[i*4+3] = (uint8_t)( words[i]         & 0xFF);
    }
}

/* Base64 alphabet */
static const char WS_B64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/*
 * Base64-encodes `len` bytes from `src` into `dst`.
 * `dst` must be at least ((len+2)/3)*4 + 1 bytes.
 * Returns number of characters written (excluding null terminator).
 */
static size_t ws_base64_encode(const uint8_t *src, size_t len, char *dst) {
    size_t out = 0;
    for (size_t i = 0; i < len; i += 3) {
        uint32_t a = src[i];
        uint32_t b = (i+1 < len) ? src[i+1] : 0;
        uint32_t c = (i+2 < len) ? src[i+2] : 0;
        uint32_t t = (a << 16) | (b << 8) | c;
        dst[out++] = WS_B64[(t >> 18) & 0x3F];
        dst[out++] = WS_B64[(t >> 12) & 0x3F];
        dst[out++] = (i+1 < len) ? WS_B64[(t >> 6) & 0x3F] : '=';
        dst[out++] = (i+2 < len) ? WS_B64[ t       & 0x3F] : '=';
    }
    dst[out] = '\0';
    return out;
}

/*
 * Reads raw bytes from socket until "\r\n\r\n" is found or buffer fills.
 * Returns total bytes read into buf, or -1 on error/overflow.
 * buf_size should be at least 4096.
 */
static int ws_read_http_headers(int fd, char *buf, int buf_size) {
    int total = 0;
    while (total < buf_size - 1) {
        ssize_t n = recv(fd, buf + total, (size_t)(buf_size - 1 - total), 0);
        if (n <= 0) return -1;
        total += (int)n;
        buf[total] = '\0';
        if (strstr(buf, "\r\n\r\n")) return total;
    }
    return -1;   /* overflow */
}

/*
 * Extracts the value of an HTTP header field (case-insensitive key).
 * Writes value into `out` (max out_size bytes including null).
 * Returns 1 on success, 0 if header not found.
 */
static int ws_get_header(const char *headers, const char *key, char *out, int out_size) {
    const char *p = headers;
    size_t klen = strlen(key);
    while (*p) {
        /* Find next line */
        const char *line_end = strstr(p, "\r\n");
        if (!line_end) break;

        /* Case-insensitive key match */
        if ((size_t)(line_end - p) > klen + 1) {
            int match = 1;
            for (size_t i = 0; i < klen; i++) {
                char a = p[i], b = key[i];
                if (a >= 'A' && a <= 'Z') a += 32;
                if (b >= 'A' && b <= 'Z') b += 32;
                if (a != b) { match = 0; break; }
            }
            if (match && p[klen] == ':') {
                const char *val = p + klen + 1;
                while (*val == ' ') val++;
                int len = (int)(line_end - val);
                if (len >= out_size) len = out_size - 1;
                memcpy(out, val, (size_t)len);
                out[len] = '\0';
                return 1;
            }
        }
        p = line_end + 2;
    }
    return 0;
}

/*
 * Performs the WebSocket server handshake on an already-accepted fd.
 * Returns 0 on success, -1 on failure.
 *
 * Expects the client to send a valid HTTP/1.1 Upgrade request.
 * Responds with 101 Switching Protocols.
 */
static int ws_handshake(int fd, int rank) {
    char buf[4096];
    ws_dbg(rank, "Waiting for HTTP upgrade request...");

    int n = ws_read_http_headers(fd, buf, (int)sizeof(buf));
    if (n < 0) {
        ws_dbg(rank, "ERROR: failed to read HTTP headers (n=%d)", n);
        return -1;
    }
    ws_dbg(rank, "Received %d bytes of HTTP headers", n);

    /* Extract Sec-WebSocket-Key */
    char ws_key[256] = {0};
    if (!ws_get_header(buf, "Sec-WebSocket-Key", ws_key, (int)sizeof(ws_key))) {
        ws_dbg(rank, "ERROR: Sec-WebSocket-Key header not found in request");
        ws_dbg(rank, "--- Header dump ---\n%s\n---", buf);
        return -1;
    }
    ws_dbg(rank, "Sec-WebSocket-Key: [%s]", ws_key);

    /* Compute accept key: SHA1(key + GUID) base64-encoded */
    static const char *WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    char combined[512];
    snprintf(combined, sizeof(combined), "%s%s", ws_key, WS_GUID);

    uint8_t digest[20];
    ws_sha1((const uint8_t *)combined, strlen(combined), digest);

    char accept_key[64];
    ws_base64_encode(digest, 20, accept_key);
    ws_dbg(rank, "Computed Sec-WebSocket-Accept: [%s]", accept_key);

    /* Send 101 response */
    char response[512];
    int resp_len = snprintf(response, sizeof(response),
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Accept: %s\r\n\r\n",
        accept_key);

    if (tcp_send_all(fd, (const uint8_t *)response, (size_t)resp_len) < 0) {
        ws_dbg(rank, "ERROR: failed to send 101 response");
        return -1;
    }
    ws_dbg(rank, "Sent 101 Switching Protocols — handshake complete");
    return 0;
}

/*
 * Reads one WebSocket frame from fd.
 * Only handles binary frames (opcode 0x2) and close/ping.
 * Allocates and returns the unmasked payload in *payload_out.
 * Caller must free(*payload_out).
 * Returns payload length on success, -1 on error, -2 on close frame.
 */
static ssize_t ws_recv_frame(int fd, uint8_t **payload_out, int rank) {
    uint8_t header[2];
    if (tcp_recv_all(fd, header, 2) < 0) {
        ws_dbg(rank, "ERROR: failed to read WebSocket frame header (client disconnected?)");
        return -1;
    }

    uint8_t opcode  = header[0] & 0x0F;
    int     fin     = (header[0] & 0x80) != 0;
    int     masked  = (header[1] & 0x80) != 0;
    uint64_t plen   = header[1] & 0x7F;

    ws_dbg(rank, "WS frame: opcode=0x%X fin=%d masked=%d raw_plen=%llu",
           opcode, fin, masked, (unsigned long long)plen);

    if (!fin) {
        /* We don't support fragmented frames — log and bail */
        ws_dbg(rank, "ERROR: received fragmented WebSocket frame (FIN=0), not supported");
        return -1;
    }

    /* Extended payload length */
    if (plen == 126) {
        uint8_t ext[2];
        if (tcp_recv_all(fd, ext, 2) < 0) {
            ws_dbg(rank, "ERROR: failed to read 16-bit extended length");
            return -1;
        }
        plen = ((uint64_t)ext[0] << 8) | ext[1];
        ws_dbg(rank, "Extended payload length (16-bit): %llu", (unsigned long long)plen);
    } else if (plen == 127) {
        uint8_t ext[8];
        if (tcp_recv_all(fd, ext, 8) < 0) {
            ws_dbg(rank, "ERROR: failed to read 64-bit extended length");
            return -1;
        }
        plen = 0;
        for (int i = 0; i < 8; i++) plen = (plen << 8) | ext[i];
        ws_dbg(rank, "Extended payload length (64-bit): %llu", (unsigned long long)plen);
    }

    /* Masking key */
    uint8_t mask[4] = {0, 0, 0, 0};
    if (masked) {
        if (tcp_recv_all(fd, mask, 4) < 0) {
            ws_dbg(rank, "ERROR: failed to read masking key");
            return -1;
        }
        ws_dbg(rank, "Masking key: %02X %02X %02X %02X",
               mask[0], mask[1], mask[2], mask[3]);
    } else {
        ws_dbg(rank, "WARNING: frame is not masked (browser frames should always be masked)");
    }

    /* Handle control frames before allocating payload */
    if (opcode == 0x8) {
        ws_dbg(rank, "Received WebSocket close frame");
        return -2;
    }
    if (opcode == 0x9) {
        ws_dbg(rank, "Received ping, sending pong");
        uint8_t pong_hdr[2] = { 0x8A, (uint8_t)(plen & 0x7F) };
        tcp_send_all(fd, pong_hdr, 2);
        /* drain ping payload */
        if (plen > 0) {
            uint8_t *tmp = malloc(plen);
            tcp_recv_all(fd, tmp, plen);
            free(tmp);
        }
        *payload_out = NULL;
        return 0;
    }
    if (opcode != 0x2) {
        ws_dbg(rank, "WARNING: unexpected opcode 0x%X, skipping frame", opcode);
        if (plen > 0) {
            uint8_t *tmp = malloc(plen);
            tcp_recv_all(fd, tmp, plen);
            free(tmp);
        }
        *payload_out = NULL;
        return 0;
    }

    /* Binary frame — read and unmask payload */
    uint8_t *payload = malloc(plen);
    if (!payload) {
        ws_dbg(rank, "ERROR: OOM allocating %llu bytes for payload", (unsigned long long)plen);
        return -1;
    }
    if (tcp_recv_all(fd, payload, plen) < 0) {
        ws_dbg(rank, "ERROR: failed to read %llu payload bytes", (unsigned long long)plen);
        free(payload);
        return -1;
    }
    if (masked) {
        for (uint64_t i = 0; i < plen; i++)
            payload[i] ^= mask[i % 4];
    }

    ws_dbg(rank, "Binary frame received: %llu bytes unmasked", (unsigned long long)plen);
    *payload_out = payload;
    return (ssize_t)plen;
}

/*
 * Sends a WebSocket binary frame containing `len` bytes from `data`.
 * No masking — server-to-client frames are never masked per RFC 6455.
 */
static int ws_send_frame(int fd, const uint8_t *data, size_t len, int rank) {
    uint8_t hdr[10];
    int hdr_len = 0;

    hdr[hdr_len++] = 0x82;   /* FIN=1, opcode=binary */

    if (len <= 125) {
        hdr[hdr_len++] = (uint8_t)len;
    } else if (len <= 65535) {
        hdr[hdr_len++] = 126;
        hdr[hdr_len++] = (uint8_t)((len >> 8) & 0xFF);
        hdr[hdr_len++] = (uint8_t)( len        & 0xFF);
    } else {
        hdr[hdr_len++] = 127;
        for (int i = 7; i >= 0; i--)
            hdr[hdr_len++] = (uint8_t)((len >> (i * 8)) & 0xFF);
    }

    ws_dbg(rank, "Sending WS binary frame: %zu bytes (header %d bytes)", len, hdr_len);

    if (tcp_send_all(fd, hdr, (size_t)hdr_len) < 0) {
        ws_dbg(rank, "ERROR: failed to send WS frame header");
        return -1;
    }
    if (tcp_send_all(fd, data, len) < 0) {
        ws_dbg(rank, "ERROR: failed to send WS frame payload");
        return -1;
    }
    ws_dbg(rank, "WS frame sent successfully");
    return 0;
}

/* ─── Role: INGESTION ────────────────────────────────────────── */

/*
 * Opens a TCP server socket and performs a WebSocket upgrade handshake
 * with the browser client (compatible with HttpServer.cpp's /ws endpoint).
 *
 * Wire protocol after handshake:
 *   Client → server: WebSocket binary frame containing:
 *     [4B width (uint32 LE)][4B height (uint32 LE)][W*H*4 RGBA bytes]
 *   Server → client: WebSocket binary frame containing:
 *     [W*H*4 RGBA bytes]  (processed edge-detection result)
 *
 * For each frame:
 *   1. Read WebSocket binary frame, extract dims + RGBA
 *   2. MPI_Send meta + RGBA to GRAYSCALE worker
 *   3. MPI_Recv result from THRESHOLD worker
 *   4. Send result back as WebSocket binary frame
 *
 * Debug output is timestamped with MPI_Wtime() and always flushed.
 */
static void run_ingestion(int my_rank, const WorkerConfig *cfg) {
    int grayscale_rank = cfg->send_to[0];
    int threshold_rank = cfg->recv_from;

    ws_dbg(my_rank, "Starting — grayscale_rank=%d threshold_rank=%d",
           grayscale_rank, threshold_rank);

    /* ── TCP server setup ── */
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        ws_dbg(my_rank, "ERROR: socket() failed: %s", strerror(errno));
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port        = htons(TCP_PORT);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        ws_dbg(my_rank, "ERROR: bind() on port %d failed: %s", TCP_PORT, strerror(errno));
        MPI_Abort(MPI_COMM_WORLD, 1);
    }
    listen(server_fd, TCP_BACKLOG);
    ws_dbg(my_rank, "TCP server listening on port %d", TCP_PORT);

    /* Accept one client — re-accept on disconnect */
reconnect:;
    ws_dbg(my_rank, "Waiting for client connection...");
    struct sockaddr_in client_addr;
    socklen_t client_len = sizeof(client_addr);
    int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &client_len);
    if (client_fd < 0) {
        ws_dbg(my_rank, "ERROR: accept() failed: %s", strerror(errno));
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    char client_ip[INET_ADDRSTRLEN] = "unknown";
    inet_ntop(AF_INET, &client_addr.sin_addr, client_ip, sizeof(client_ip));
    ws_dbg(my_rank, "Client connected from %s", client_ip);

    /* ── WebSocket handshake ── */
    if (ws_handshake(client_fd, my_rank) < 0) {
        ws_dbg(my_rank, "Handshake failed — closing client and waiting for reconnect");
        close(client_fd);
        goto reconnect;
    }

    omp_set_num_threads(cfg->thread_count);

    int frame_id = 0;

    while (1) {
        ws_dbg(my_rank, "--- Waiting for frame %d from client ---", frame_id);

        /* ── Read WebSocket binary frame ── */
        uint8_t *payload = NULL;
        ssize_t payload_len = ws_recv_frame(client_fd, &payload, my_rank);

        if (payload_len == -2) {
            ws_dbg(my_rank, "Client sent close frame — shutting down");
            free(payload);
            break;
        }
        if (payload_len < 0) {
            ws_dbg(my_rank, "Frame read error — client likely disconnected, waiting for reconnect");
            close(client_fd);
            goto reconnect;
        }
        if (payload_len == 0) {
            /* ping/pong or skipped opcode — no frame data */
            ws_dbg(my_rank, "Non-data frame (ping/pong/skip), continuing");
            continue;
        }

        /* ── Parse dims from first 8 bytes ── */
        if (payload_len < 8) {
            ws_dbg(my_rank, "ERROR: payload too short to contain dims (%zd bytes)", payload_len);
            free(payload);
            continue;
        }

        /* instead of reading dims from payload */
        int W = FRAME_WIDTH;
        int H = FRAME_HEIGHT;
        size_t frame_bytes = (size_t)W * H * 4;

        if ((size_t)payload_len != frame_bytes) {
            ws_dbg(my_rank, "ERROR: payload size mismatch — expected %zu got %zd, dropping frame",
                frame_bytes, payload_len);
            free(payload);
            continue;
        }

        const uint8_t *rgba_in = payload;  /* no 8-byte offset */


        /* ── Forward to GRAYSCALE ── */
        FrameMeta meta = { frame_id, W, H };
        ws_dbg(my_rank, "MPI_Send FrameMeta to rank %d (frame_id=%d W=%d H=%d)",
               grayscale_rank, frame_id, W, H);
        MPI_Send(&meta, sizeof(FrameMeta), MPI_BYTE,
                 grayscale_rank, TAG_FRAME_META, MPI_COMM_WORLD);

        ws_dbg(my_rank, "MPI_Send RGBA data to rank %d (%zu bytes)", grayscale_rank, frame_bytes);
        MPI_Send(rgba_in, (int)frame_bytes, MPI_BYTE,
                 grayscale_rank, TAG_FRAME_DATA, MPI_COMM_WORLD);

        free(payload);
        ws_dbg(my_rank, "Forwarded frame %d to grayscale, waiting for result from rank %d",
               frame_id, threshold_rank);

        /* ── Recv result from THRESHOLD ── */
        uint8_t *rgba_out = malloc(frame_bytes);
        if (!rgba_out) {
            ws_dbg(my_rank, "ERROR: OOM allocating %zu bytes for result", frame_bytes);
            MPI_Abort(MPI_COMM_WORLD, 1);
        }

        FrameMeta result_meta;
        ws_dbg(my_rank, "MPI_Recv result FrameMeta from rank %d...", threshold_rank);
        MPI_Recv(&result_meta, sizeof(FrameMeta), MPI_BYTE,
                 threshold_rank, TAG_FRAME_META, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        ws_dbg(my_rank, "Got result meta: frame_id=%d W=%d H=%d",
               result_meta.frame_id, result_meta.width, result_meta.height);

        ws_dbg(my_rank, "MPI_Recv result RGBA from rank %d (%zu bytes)...", threshold_rank, frame_bytes);
        MPI_Recv(rgba_out, (int)frame_bytes, MPI_BYTE,
                 threshold_rank, TAG_FRAME_DATA, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        ws_dbg(my_rank, "Result received for frame %d", frame_id);

        /* ── Send result back to client via WebSocket ── */
        ws_dbg(my_rank, "Sending result frame %d to client (%zu bytes)", frame_id, frame_bytes);
        if (ws_send_frame(client_fd, rgba_out, frame_bytes, my_rank) < 0) {
            ws_dbg(my_rank, "Send failed — client disconnected, waiting for reconnect");
            free(rgba_out);
            close(client_fd);
            goto reconnect;
        }
        free(rgba_out);

        ws_dbg(my_rank, "Frame %d complete. Round-trip done.", frame_id);
        frame_id++;
    }

    /* ── Propagate shutdown to pipeline ── */
    ws_dbg(my_rank, "Sending TAG_DONE to grayscale rank %d", grayscale_rank);
    FrameMeta done = { -1, 0, 0 };
    MPI_Send(&done, sizeof(FrameMeta), MPI_BYTE,
             grayscale_rank, TAG_DONE, MPI_COMM_WORLD);

    close(client_fd);
    close(server_fd);
    ws_dbg(my_rank, "Ingestion shut down cleanly");
}

/* ─── Role: GRAYSCALE ────────────────────────────────────────── */

/*
 * Receives RGBA frames from INGESTION.
 * Converts to grayscale with OpenMP parallel for.
 * Partitions rows into blocks (one per CONVOLUTION worker).
 * Sends each block with 1 ghost row top and bottom.
 *
 * Block layout sent to each convolution worker:
 *   [RowBlockHeader][gray row data: (block_rows + ghosts) * width bytes]
 */
static void run_grayscale(int my_rank, const WorkerConfig *cfg) {
    /* Count how many convolution workers we're sending to */
    int n_conv = 0;
    for (int i = 0; i < MAX_SEND_TO; i++)
        if (cfg->send_to[i] >= 0) n_conv++;

    if (n_conv == 0) {
        fprintf(stderr, "[GRAYSCALE rank %d] No send_to targets.\n", my_rank);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    omp_set_num_threads(cfg->thread_count);

    while (1) {
        /* ── Recv frame meta ── */
        FrameMeta meta;
        MPI_Status status;
        MPI_Recv(&meta, sizeof(FrameMeta), MPI_BYTE,
                 cfg->recv_from, MPI_ANY_TAG, MPI_COMM_WORLD, &status);

        if (status.MPI_TAG == TAG_DONE) {
            /* Propagate shutdown to all convolution workers */
            RowBlockHeader done_hdr = { -1, 0, 0, 0, 0, 0, 0 };
            for (int i = 0; i < MAX_SEND_TO; i++)
                if (cfg->send_to[i] >= 0)
                    MPI_Send(&done_hdr, sizeof(RowBlockHeader), MPI_BYTE,
                             cfg->send_to[i], TAG_DONE, MPI_COMM_WORLD);
            break;
        }

        int W = meta.width, H = meta.height;
        size_t frame_bytes = (size_t)W * H * 4;
        size_t gray_bytes  = (size_t)W * H;

        uint8_t *rgba = malloc(frame_bytes);
        uint8_t *gray = malloc(gray_bytes);
        if (!rgba || !gray) { fprintf(stderr, "[GRAYSCALE] OOM\n"); MPI_Abort(MPI_COMM_WORLD, 1); }

        MPI_Recv(rgba, (int)frame_bytes, MPI_BYTE,
                 cfg->recv_from, TAG_FRAME_DATA, MPI_COMM_WORLD, MPI_STATUS_IGNORE);

        /* ── Grayscale conversion — OpenMP parallel ── */
        #pragma omp parallel for schedule(static)
        for (int i = 0; i < W * H; i++) {
            gray[i] = rgba_to_gray(rgba[i*4], rgba[i*4+1], rgba[i*4+2]);
        }
        free(rgba);

        /* ── Partition rows and send blocks with ghosts ── */
        int base      = H / n_conv;
        int remainder = H % n_conv;
        int row_start = 0;

        for (int ci = 0; ci < n_conv; ci++) {
            if (cfg->send_to[ci] < 0) continue;

            int block_rows = base + (ci < remainder ? 1 : 0);
            int row_end    = row_start + block_rows;   /* exclusive */

            /* Ghost rows: clamp to image boundaries */
            int ghost_top = (row_start > 0)  ? 1 : 0;
            int ghost_bot = (row_end   < H)  ? 1 : 0;

            int payload_start = row_start - ghost_top;
            int payload_end   = row_end   + ghost_bot;
            int payload_rows  = payload_end - payload_start;

            RowBlockHeader hdr = {
                meta.frame_id,
                W, H,
                row_start, row_end,
                ghost_top, ghost_bot
            };

            size_t payload_bytes = (size_t)payload_rows * W;

            /* Pack header + data into one buffer for a single MPI_Send */
            uint8_t *msg = malloc(sizeof(RowBlockHeader) + payload_bytes);
            if (!msg) { fprintf(stderr, "[GRAYSCALE] OOM msg\n"); MPI_Abort(MPI_COMM_WORLD, 1); }

            memcpy(msg, &hdr, sizeof(RowBlockHeader));
            memcpy(msg + sizeof(RowBlockHeader),
                   gray + (size_t)payload_start * W,
                   payload_bytes);

            MPI_Send(msg, (int)(sizeof(RowBlockHeader) + payload_bytes), MPI_BYTE,
                     cfg->send_to[ci], TAG_ROW_BLOCK, MPI_COMM_WORLD);

            free(msg);
            row_start = row_end;
        }

        free(gray);
    }
}

/* ─── Role: CONVOLUTION ──────────────────────────────────────── */

/*
 * Receives gray row blocks (with ghost rows) from GRAYSCALE.
 * Applies Sobel on owned rows only (skips ghosts).
 * OpenMP parallel for across rows in the block.
 * Sends magnitude rows (as uint8_t, not RGBA) to THRESHOLD.
 * Header preserved so THRESHOLD can reassemble in order.
 */
static void run_convolution(int my_rank, const WorkerConfig *cfg) {
    int threshold_rank = cfg->send_to[0];
    omp_set_num_threads(cfg->thread_count);

    while (1) {
        /* Probe to get message size before allocating */
        MPI_Status status;
        MPI_Probe(cfg->recv_from, MPI_ANY_TAG, MPI_COMM_WORLD, &status);

        if (status.MPI_TAG == TAG_DONE) {
            MPI_Recv(NULL, 0, MPI_BYTE, cfg->recv_from,
                     TAG_DONE, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            RowBlockHeader done_hdr = { -1, 0, 0, 0, 0, 0, 0 };
            MPI_Send(&done_hdr, sizeof(RowBlockHeader), MPI_BYTE,
                     threshold_rank, TAG_DONE, MPI_COMM_WORLD);
            break;
        }

        int msg_bytes;
        MPI_Get_count(&status, MPI_BYTE, &msg_bytes);

        uint8_t *msg = malloc((size_t)msg_bytes);
        if (!msg) { fprintf(stderr, "[CONVOLUTION rank %d] OOM\n", my_rank); MPI_Abort(MPI_COMM_WORLD, 1); }

        MPI_Recv(msg, msg_bytes, MPI_BYTE,
                 cfg->recv_from, TAG_ROW_BLOCK, MPI_COMM_WORLD, MPI_STATUS_IGNORE);

        RowBlockHeader hdr;
        memcpy(&hdr, msg, sizeof(RowBlockHeader));

        int W             = hdr.width;
        int payload_rows  = (hdr.block_end - hdr.block_start)
                          + hdr.has_top_ghost + hdr.has_bot_ghost;
        int owned_rows    = hdr.block_end - hdr.block_start;

        const uint8_t *gray_block = msg + sizeof(RowBlockHeader);

        /* Output: only owned rows, single channel magnitude */
        uint8_t *mag = malloc((size_t)owned_rows * W);
        if (!mag) { fprintf(stderr, "[CONVOLUTION rank %d] OOM mag\n", my_rank); MPI_Abort(MPI_COMM_WORLD, 1); }

        /*
         * Within the payload buffer:
         *   row 0              = top ghost (if has_top_ghost)
         *   row has_top_ghost  = first owned row
         *   ...
         *   last row           = bottom ghost (if has_bot_ghost)
         *
         * We run Sobel on owned rows only.
         * Boundary owned rows that have no ghost on one side are left black (mag=0).
         */
        #pragma omp parallel for schedule(static)
        for (int oy = 0; oy < owned_rows; oy++) {
            int py = oy + hdr.has_top_ghost;   /* row index in payload buffer */

            for (int x = 0; x < W; x++) {
                /* Need py-1 and py+1 in payload; skip if out of bounds */
                if (py == 0 || py == payload_rows - 1 || x == 0 || x == W - 1) {
                    mag[oy * W + x] = 0;
                    continue;
                }
                mag[oy * W + x] = (uint8_t)sobel_magnitude(gray_block, W, x, py);
            }
        }

        free(msg);

        /* Send header + magnitude rows to THRESHOLD */
        size_t out_bytes = sizeof(RowBlockHeader) + (size_t)owned_rows * W;
        uint8_t *out_msg = malloc(out_bytes);
        if (!out_msg) { fprintf(stderr, "[CONVOLUTION rank %d] OOM out\n", my_rank); MPI_Abort(MPI_COMM_WORLD, 1); }

        memcpy(out_msg, &hdr, sizeof(RowBlockHeader));
        memcpy(out_msg + sizeof(RowBlockHeader), mag, (size_t)owned_rows * W);

        MPI_Send(out_msg, (int)out_bytes, MPI_BYTE,
                 threshold_rank, TAG_ROW_BLOCK, MPI_COMM_WORLD);

        free(mag);
        free(out_msg);
    }
}

/* ─── Role: THRESHOLD ────────────────────────────────────────── */

/*
 * Receives magnitude row blocks from all CONVOLUTION workers.
 * Reassembles full frame in correct row order using frame_id + block_start.
 * Converts single-channel magnitude to RGBA (gray RGBA).
 * Sends complete RGBA frame back to INGESTION.
 *
 * Reassembly: maintains a simple frame buffer per frame_id.
 * Since only one frame is in flight at a time (INGESTION blocks on recv),
 * we only need one frame buffer. If you pipeline multiple frames later,
 * expand this to a frame_id -> buffer map.
 */
static void run_threshold(int my_rank, const WorkerConfig *cfg) {
    int ingestion_rank = cfg->send_to[0];

    /* Count convolution senders */
    int n_conv = 0;
    /* recv_from in config points to one conv worker, but we receive from all.
     * We use MPI_ANY_SOURCE since multiple conv workers send to us. */

    omp_set_num_threads(cfg->thread_count);

    /* We don't know n_conv here without extra config, so we track
     * blocks received vs expected from frame dimensions. */

    int running = 1;
    int done_count = 0;  /* count TAG_DONE from conv workers */

    /* Count expected conv workers by scanning config isn't available here.
     * Simple workaround: THRESHOLD receives until it has all rows of a frame.
     * It knows total_rows from RowBlockHeader. */

    uint8_t *frame_gray = NULL;
    int cur_frame_id    = -1;
    int cur_W = 0, cur_H = 0;
    int rows_received   = 0;

    /* We need to know how many conv workers exist to detect TAG_DONE from all.
     * Pass this as an env var or extend the config. For now read from env. */
    int n_conv_workers = 3;   /* default; override with SOBEL_N_CONV env var */
    const char *env = getenv("SOBEL_N_CONV");
    if (env) n_conv_workers = atoi(env);

    while (running) {
        MPI_Status status;
        MPI_Probe(MPI_ANY_SOURCE, MPI_ANY_TAG, MPI_COMM_WORLD, &status);

        if (status.MPI_TAG == TAG_DONE) {
            /* Drain the zero-byte done message */
            RowBlockHeader done_hdr;
            MPI_Recv(&done_hdr, sizeof(RowBlockHeader), MPI_BYTE,
                     status.MPI_SOURCE, TAG_DONE, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            done_count++;
            if (done_count >= n_conv_workers) {
                running = 0;
            }
            continue;
        }

        int msg_bytes;
        MPI_Get_count(&status, MPI_BYTE, &msg_bytes);
        uint8_t *msg = malloc((size_t)msg_bytes);
        if (!msg) { fprintf(stderr, "[THRESHOLD rank %d] OOM\n", my_rank); MPI_Abort(MPI_COMM_WORLD, 1); }

        MPI_Recv(msg, msg_bytes, MPI_BYTE,
                 status.MPI_SOURCE, TAG_ROW_BLOCK, MPI_COMM_WORLD, MPI_STATUS_IGNORE);

        RowBlockHeader hdr;
        memcpy(&hdr, msg, sizeof(RowBlockHeader));

        int W         = hdr.width;
        int H         = hdr.total_rows;
        int owned     = hdr.block_end - hdr.block_start;
        const uint8_t *block_mag = msg + sizeof(RowBlockHeader);

        /* New frame: allocate buffer */
        if (hdr.frame_id != cur_frame_id) {
            free(frame_gray);
            frame_gray    = calloc((size_t)W * H, 1);
            cur_frame_id  = hdr.frame_id;
            cur_W         = W;
            cur_H         = H;
            rows_received = 0;
        }

        /* Copy block into frame buffer at correct position */
        memcpy(frame_gray + (size_t)hdr.block_start * W,
               block_mag,
               (size_t)owned * W);
        rows_received += owned;

        free(msg);

        /* When all rows received, convert to RGBA and send to INGESTION */
        if (rows_received >= cur_H) {
            size_t rgba_bytes = (size_t)cur_W * cur_H * 4;
            uint8_t *rgba_out = malloc(rgba_bytes);
            if (!rgba_out) { fprintf(stderr, "[THRESHOLD] OOM rgba\n"); MPI_Abort(MPI_COMM_WORLD, 1); }

            /* Threshold + RGBA conversion — OpenMP parallel */
            #pragma omp parallel for schedule(static)
            for (int i = 0; i < cur_W * cur_H; i++) {
                uint8_t v        = frame_gray[i];   /* already clamped by conv */
                rgba_out[i*4+0]  = v;
                rgba_out[i*4+1]  = v;
                rgba_out[i*4+2]  = v;
                rgba_out[i*4+3]  = 255;
            }

            FrameMeta result = { cur_frame_id, cur_W, cur_H };
            MPI_Send(&result,   sizeof(FrameMeta), MPI_BYTE,
                     ingestion_rank, TAG_FRAME_META, MPI_COMM_WORLD);
            MPI_Send(rgba_out,  (int)rgba_bytes,   MPI_BYTE,
                     ingestion_rank, TAG_FRAME_DATA, MPI_COMM_WORLD);

            free(rgba_out);
            rows_received = 0;
        }
    }

    free(frame_gray);

    /* Signal ingestion to shut down */
    FrameMeta done = { -1, 0, 0 };
    MPI_Send(&done, sizeof(FrameMeta), MPI_BYTE,
             ingestion_rank, TAG_DONE, MPI_COMM_WORLD);
}

/* ─── Main ───────────────────────────────────────────────────── */

int main(int argc, char **argv) {
    int provided;
    MPI_Init_thread(&argc, &argv, MPI_THREAD_SERIALIZED, &provided);
    if (provided < MPI_THREAD_SERIALIZED) {
        fprintf(stderr, "MPI does not support MPI_THREAD_SERIALIZED\n");
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    int my_rank, world_size;
    MPI_Comm_rank(MPI_COMM_WORLD, &my_rank);
    MPI_Comm_size(MPI_COMM_WORLD, &world_size);

    WorkerConfig cfg;
    if (load_config(my_rank, &cfg) < 0) {
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    omp_set_num_threads(cfg.thread_count);

    printf("[rank %d] role=%d threads=%d recv_from=%d send_to=[%d,%d,%d]\n",
           my_rank, cfg.role, cfg.thread_count, cfg.recv_from,
           cfg.send_to[0], cfg.send_to[1], cfg.send_to[2]);
    fflush(stdout);

    MPI_Barrier(MPI_COMM_WORLD);   /* all ranks ready before any sends */

    switch (cfg.role) {
        case ROLE_INGESTION:   run_ingestion(my_rank, &cfg);   break;
        case ROLE_GRAYSCALE:   run_grayscale(my_rank, &cfg);   break;
        case ROLE_CONVOLUTION: run_convolution(my_rank, &cfg); break;
        case ROLE_THRESHOLD:   run_threshold(my_rank, &cfg);   break;
        default:
            fprintf(stderr, "[rank %d] Unknown role %d\n", my_rank, cfg.role);
            MPI_Abort(MPI_COMM_WORLD, 1);
    }

    MPI_Finalize();
    return 0;
}