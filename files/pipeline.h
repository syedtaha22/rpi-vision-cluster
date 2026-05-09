#pragma once
/**
 * @file pipeline.h
 * @brief Shared types, roles, and message protocol for the Sobel pipeline.
 *
 * MESSAGE PROTOCOL
 * ----------------
 * Every MPI message is prefixed with a FrameHeader. Workers inspect the
 * header before reading the payload so the pipeline is self-describing.
 *
 *   [ FrameHeader ][ payload bytes ... ]
 *
 * Payload layout per role:
 *   INGESTION   -> sends full RGBA frame   (width * height * 4 bytes)
 *   GRAYSCALE   -> sends gray strip + ghosts (see GrayBlock)
 *   CONVOLUTION -> sends magnitude strip    (rows * width * 4 bytes RGBA)
 *   THRESHOLD   -> sends final RGBA frame   (width * height * 4 bytes)
 */

#include <cstdint>
#include <cstddef>

// ── Roles ────────────────────────────────────────────────────────────────────
enum Role {
    ROLE_INGESTION   = 0,   // Pi 1: HTTP server + MPI forwarder
    ROLE_GRAYSCALE   = 1,   // Pi 2: RGBA -> gray, partitions rows
    ROLE_CONVOLUTION = 2,   // Pi 3/4/5: Sobel kernel
    ROLE_THRESHOLD   = 3,   // Pi 6: clamp + reconstruct frame
    ROLE_UNKNOWN     = 99
};

// ── MPI tags ─────────────────────────────────────────────────────────────────
enum MsgTag {
    TAG_FRAME_HEADER  = 10,  // FrameHeader struct
    TAG_FRAME_PAYLOAD = 11,  // raw pixel data following a header
    TAG_SHUTDOWN      = 99   // poison pill - tells worker to exit
};

// ── Frame header (sent before every payload) ─────────────────────────────────
struct FrameHeader {
    uint32_t frame_id;       // monotonically increasing frame counter
    uint32_t width;          // image width  in pixels
    uint32_t height;         // image height in pixels
    uint32_t row_start;      // first row this payload covers (inclusive)
    uint32_t row_end;        // last  row this payload covers (exclusive)
    uint32_t ghost_top;      // 1 if payload includes an extra ghost row at top
    uint32_t ghost_bottom;   // 1 if payload includes an extra ghost row at bottom
    uint32_t payload_bytes;  // byte length of following payload message
};

// ── Gray block metadata (GRAYSCALE -> CONVOLUTION) ───────────────────────────
// The payload is (row_end - row_start + ghost_top + ghost_bottom) rows
// of single-channel uint8_t, each row is `width` bytes wide.

// ── Worker configuration (broadcast from master at startup) ──────────────────
#define MAX_SEND_TO 4

struct WorkerConfig {
    int  rank;                      // this worker's MPI rank
    int  role;                      // enum Role
    int  send_to[MAX_SEND_TO];      // ranks to forward output to (-1 = unused)
    int  send_to_count;             // how many entries in send_to are valid
    int  recv_from;                 // rank to receive input from (-1 = none)
    int  omp_threads;               // OpenMP thread count for this worker
    int  image_width;               // frame dimensions (same for all workers)
    int  image_height;
};

// ── Config file path ─────────────────────────────────────────────────────────
#define PIPELINE_CONFIG_PATH "./pipeline.conf"

// ── HTTP server port ──────────────────────────────────────────────────────────
#define HTTP_PORT 8000

// ── Debug macro ──────────────────────────────────────────────────────────────
#include <cstdio>
#include <ctime>

static inline const char* role_name(int r) {
    switch(r) {
        case ROLE_INGESTION:   return "INGESTION";
        case ROLE_GRAYSCALE:   return "GRAYSCALE";
        case ROLE_CONVOLUTION: return "CONVOLUTION";
        case ROLE_THRESHOLD:   return "THRESHOLD";
        default:               return "UNKNOWN";
    }
}

#define DBG(fmt, ...) do { \
    time_t _t = time(NULL); \
    struct tm* _tm = localtime(&_t); \
    char _ts[16]; \
    strftime(_ts, sizeof(_ts), "%H:%M:%S", _tm); \
    fprintf(stderr, "[%s][rank %d][%s] " fmt "\n", \
            _ts, _dbg_rank, role_name(_dbg_role), ##__VA_ARGS__); \
    fflush(stderr); \
} while(0)

// Set these at the top of each worker's main loop:
//   int _dbg_rank = my_config.rank;
//   int _dbg_role = my_config.role;
extern int _dbg_rank;
extern int _dbg_role;
