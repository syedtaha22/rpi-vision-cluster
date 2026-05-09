/**
 * @file workers.h
 * @brief Per-role worker loop implementations.
 *
 * Each worker_*() function is the main loop for that role.
 * They block until a TAG_SHUTDOWN message is received.
 *
 * Threading model inside each worker:
 *   - One MPI receive thread (blocks on MPI_Recv)
 *   - OpenMP parallel for over rows for compute
 *   - One or more MPI send threads (forward to downstream ranks)
 *
 * For simplicity in this version, recv -> compute -> send is sequential
 * within a frame, but frames pipeline across nodes simultaneously.
 */

#pragma once

#include "pipeline.h"
#include <mpi.h>
#include <omp.h>
#include <cmath>
#include <cstring>
#include <vector>
#include <cstdio>

// ── DBG globals (defined in main.cpp) ────────────────────────────────────────
int _dbg_rank = 0;
int _dbg_role = ROLE_UNKNOWN;

// ── MPI helpers ───────────────────────────────────────────────────────────────

/** Send header then payload to a single rank. */
static inline void mpi_send_frame(const FrameHeader& hdr,
                                   const std::vector<uint8_t>& payload,
                                   int dest, int rank) {
    DBG("-> send frame_id=%u rows=[%u,%u) ghost_top=%u ghost_bot=%u payload=%u bytes to rank %d",
        hdr.frame_id, hdr.row_start, hdr.row_end,
        hdr.ghost_top, hdr.ghost_bottom, hdr.payload_bytes, dest);

    MPI_Send(&hdr, sizeof(FrameHeader), MPI_BYTE, dest, TAG_FRAME_HEADER, MPI_COMM_WORLD);
    MPI_Send(payload.data(), (int)payload.size(), MPI_BYTE, dest, TAG_FRAME_PAYLOAD, MPI_COMM_WORLD);
}

/** Receive header then payload from any source or a specific rank. */
static inline bool mpi_recv_frame(FrameHeader& hdr,
                                   std::vector<uint8_t>& payload,
                                   int source, int rank) {
    MPI_Status status;
    MPI_Recv(&hdr, sizeof(FrameHeader), MPI_BYTE,
             source, TAG_FRAME_HEADER, MPI_COMM_WORLD, &status);

    // Check for shutdown poison pill embedded in a zero-payload header
    if (hdr.payload_bytes == 0) {
        DBG("received shutdown signal from rank %d", source);
        return false;
    }

    payload.resize(hdr.payload_bytes);
    MPI_Recv(payload.data(), (int)hdr.payload_bytes, MPI_BYTE,
             source, TAG_FRAME_PAYLOAD, MPI_COMM_WORLD, &status);

    DBG("<- recv frame_id=%u rows=[%u,%u) payload=%u bytes from rank %d",
        hdr.frame_id, hdr.row_start, hdr.row_end, hdr.payload_bytes, source);
    return true;
}

/** Broadcast shutdown to all downstream ranks. */
static inline void mpi_send_shutdown(const WorkerConfig& cfg) {
    FrameHeader shutdown_hdr{};
    shutdown_hdr.payload_bytes = 0;  // sentinel
    for (int i = 0; i < cfg.send_to_count; ++i) {
        DBG("sending shutdown to rank %d", cfg.send_to[i]);
        MPI_Send(&shutdown_hdr, sizeof(FrameHeader), MPI_BYTE,
                 cfg.send_to[i], TAG_FRAME_HEADER, MPI_COMM_WORLD);
    }
}

// ── ROLE_GRAYSCALE ────────────────────────────────────────────────────────────
/**
 * Receives full RGBA frame from INGESTION (rank recv_from).
 * Converts to grayscale with OpenMP.
 * Partitions rows across send_to[] workers (block partition + ghost rows).
 * Sends each block as a separate FrameHeader+payload.
 */
void worker_grayscale(const WorkerConfig& cfg) {
    _dbg_rank = cfg.rank;
    _dbg_role = cfg.role;
    omp_set_num_threads(cfg.omp_threads);

    const int W = cfg.image_width;
    const int H = cfg.image_height;
    const int N = cfg.send_to_count;  // number of convolution workers

    DBG("starting, will fan out to %d convolution workers", N);

    std::vector<uint8_t> gray(W * H);

    while (true) {
        // ── Receive RGBA frame from ingestion ──
        FrameHeader hdr;
        std::vector<uint8_t> rgba;
        if (!mpi_recv_frame(hdr, rgba, cfg.recv_from, cfg.rank)) break;

        DBG("processing frame_id=%u (%dx%d)", hdr.frame_id, W, H);

        // ── Grayscale conversion (OpenMP parallel) ──
        #pragma omp parallel for schedule(static)
        for (int i = 0; i < W * H; ++i) {
            const uint8_t r = rgba[(size_t)i * 4 + 0];
            const uint8_t g = rgba[(size_t)i * 4 + 1];
            const uint8_t b = rgba[(size_t)i * 4 + 2];
            // ITU-R BT.601 coefficients, integer arithmetic
            gray[i] = (uint8_t)((77 * r + 150 * g + 29 * b) >> 8);
        }

        // ── Partition rows across N convolution workers ──
        // Worker i owns rows [row_start_i, row_end_i).
        // Each worker also gets 1 ghost row above and below (clamped at borders).
        for (int wi = 0; wi < N; ++wi) {
            int row_start = (wi * H) / N;
            int row_end   = ((wi + 1) * H) / N;

            // Ghost rows
            int ghost_top    = (row_start > 0)   ? 1 : 0;
            int ghost_bottom = (row_end   < H)   ? 1 : 0;

            int send_row_start = row_start - ghost_top;
            int send_row_end   = row_end   + ghost_bottom;
            int send_rows      = send_row_end - send_row_start;

            FrameHeader out_hdr = hdr;
            out_hdr.row_start     = (uint32_t)row_start;
            out_hdr.row_end       = (uint32_t)row_end;
            out_hdr.ghost_top     = (uint32_t)ghost_top;
            out_hdr.ghost_bottom  = (uint32_t)ghost_bottom;
            out_hdr.payload_bytes = (uint32_t)(send_rows * W);  // 1 byte per pixel

            std::vector<uint8_t> block(out_hdr.payload_bytes);
            memcpy(block.data(), gray.data() + send_row_start * W,
                   out_hdr.payload_bytes);

            DBG("fan-out wi=%d rows=[%d,%d) ghost_top=%d ghost_bot=%d -> rank %d",
                wi, row_start, row_end, ghost_top, ghost_bottom, cfg.send_to[wi]);

            mpi_send_frame(out_hdr, block, cfg.send_to[wi], cfg.rank);
        }
    }

    mpi_send_shutdown(cfg);
    DBG("shutting down");
}

// ── ROLE_CONVOLUTION ──────────────────────────────────────────────────────────
/**
 * Receives a gray strip (with ghost rows) from GRAYSCALE.
 * Applies Sobel kernel with OpenMP.
 * Sends magnitude strip (RGBA, no ghost rows) to THRESHOLD.
 *
 * Output rows correspond to hdr.row_start..hdr.row_end (no ghosts).
 */
void worker_convolution(const WorkerConfig& cfg) {
    _dbg_rank = cfg.rank;
    _dbg_role = cfg.role;
    omp_set_num_threads(cfg.omp_threads);

    const int W = cfg.image_width;

    DBG("starting");

    while (true) {
        FrameHeader hdr;
        std::vector<uint8_t> block;
        if (!mpi_recv_frame(hdr, block, cfg.recv_from, cfg.rank)) break;

        const int row_start    = (int)hdr.row_start;
        const int row_end      = (int)hdr.row_end;
        const int ghost_top    = (int)hdr.ghost_top;
        // const int ghost_bottom = (int)hdr.ghost_bottom;  // not needed for indexing

        // block layout: [ghost_top rows][owned rows][ghost_bottom rows]
        // all single-channel uint8_t
        // To index into block: local_row = (global_row - row_start + ghost_top)
        // block[local_row * W + x]

        const int owned_rows = row_end - row_start;

        // Output: owned_rows rows, RGBA (4 bytes per pixel)
        std::vector<uint8_t> output((size_t)owned_rows * W * 4, 0);

        #pragma omp parallel for schedule(static)
        for (int yr = 0; yr < owned_rows; ++yr) {
            // Global row index
            int y = row_start + yr;

            for (int x = 0; x < W; ++x) {
                // Border pixels: zero-pad (already 0 from initialization)
                // Check if we have neighbors in the block
                bool has_top    = (yr + ghost_top - 1) >= 0;
                bool has_bottom = (yr + ghost_top + 1) < (int)(block.size() / W);
                bool has_left   = (x > 0);
                bool has_right  = (x < W - 1);

                if (!has_top || !has_bottom || !has_left || !has_right) {
                    // Border pixel: leave as black (already 0), set alpha
                    output[((size_t)yr * W + x) * 4 + 3] = 255;
                    continue;
                }

                // Local row index in block for row y
                int ly = yr + ghost_top;

                // Fetch 3x3 neighborhood
                const uint8_t p00 = block[(size_t)(ly - 1) * W + (x - 1)];
                const uint8_t p01 = block[(size_t)(ly - 1) * W +  x     ];
                const uint8_t p02 = block[(size_t)(ly - 1) * W + (x + 1)];
                const uint8_t p10 = block[(size_t) ly      * W + (x - 1)];
                const uint8_t p12 = block[(size_t) ly      * W + (x + 1)];
                const uint8_t p20 = block[(size_t)(ly + 1) * W + (x - 1)];
                const uint8_t p21 = block[(size_t)(ly + 1) * W +  x     ];
                const uint8_t p22 = block[(size_t)(ly + 1) * W + (x + 1)];

                // Sobel kernels
                const int gx = -p00 + p02 - 2*p10 + 2*p12 - p20 + p22;
                const int gy =  p00 + 2*p01 + p02 - p20 - 2*p21 - p22;

                // Magnitude — sqrtf is faster than sqrt for float
                int mag = (int)sqrtf((float)(gx*gx + gy*gy));
                if (mag > 255) mag = 255;

                const uint8_t v = (uint8_t)mag;
                size_t out_idx = ((size_t)yr * W + x) * 4;
                output[out_idx + 0] = v;
                output[out_idx + 1] = v;
                output[out_idx + 2] = v;
                output[out_idx + 3] = 255;
            }
        }

        // Forward to threshold worker(s)
        FrameHeader out_hdr = hdr;
        out_hdr.ghost_top    = 0;
        out_hdr.ghost_bottom = 0;
        out_hdr.payload_bytes = (uint32_t)output.size();

        for (int i = 0; i < cfg.send_to_count; ++i) {
            mpi_send_frame(out_hdr, output, cfg.send_to[i], cfg.rank);
        }
    }

    mpi_send_shutdown(cfg);
    DBG("shutting down");
}

// ── ROLE_THRESHOLD ────────────────────────────────────────────────────────────
/**
 * Receives RGBA magnitude strips from multiple convolution workers.
 * Reassembles full frame (by row_start/row_end).
 * Sends complete RGBA frame back to INGESTION (rank 0) for WebSocket delivery.
 *
 * Uses a simple frame accumulator: collects strips until all rows are covered,
 * then forwards the assembled frame.
 */

#include <map>
#include <unordered_map>

struct FrameAccumulator {
    uint32_t frame_id;
    int      total_rows;
    int      rows_received;
    std::vector<uint8_t> rgba;  // full frame RGBA

    FrameAccumulator() = default;
    FrameAccumulator(uint32_t fid, int W, int H)
        : frame_id(fid), total_rows(H), rows_received(0),
          rgba((size_t)W * H * 4, 0) {}
};

void worker_threshold(const WorkerConfig& cfg) {
    _dbg_rank = cfg.rank;
    _dbg_role = cfg.role;
    omp_set_num_threads(cfg.omp_threads);

    const int W = cfg.image_width;
    const int H = cfg.image_height;
    const int n_conv_workers = cfg.recv_from;
    // NOTE: recv_from in config for threshold should be set to the number of
    // convolution workers (not a rank), since we recv from MPI_ANY_SOURCE.
    // We detect completion by row coverage, not message count.

    DBG("starting, expecting frames from multiple convolution workers (MPI_ANY_SOURCE)");

    // frame_id -> accumulator
    std::unordered_map<uint32_t, FrameAccumulator> accum;

    while (true) {
        FrameHeader hdr;
        std::vector<uint8_t> strip;

        // Receive from any convolution worker
        MPI_Status status;
        FrameHeader raw_hdr;
        MPI_Recv(&raw_hdr, sizeof(FrameHeader), MPI_BYTE,
                 MPI_ANY_SOURCE, TAG_FRAME_HEADER, MPI_COMM_WORLD, &status);

        if (raw_hdr.payload_bytes == 0) {
            // Shutdown signal from one convolution worker
            DBG("got shutdown from rank %d", status.MPI_SOURCE);
            // We'd need to count shutdowns to know when all conv workers are done.
            // For simplicity, break on first shutdown (fine for demo).
            break;
        }

        strip.resize(raw_hdr.payload_bytes);
        MPI_Recv(strip.data(), (int)strip.size(), MPI_BYTE,
                 status.MPI_SOURCE, TAG_FRAME_PAYLOAD, MPI_COMM_WORLD, &status);

        hdr = raw_hdr;
        DBG("recv strip frame_id=%u rows=[%u,%u) from rank %d",
            hdr.frame_id, hdr.row_start, hdr.row_end, status.MPI_SOURCE);

        // Get or create accumulator for this frame
        auto it = accum.find(hdr.frame_id);
        if (it == accum.end()) {
            accum[hdr.frame_id] = FrameAccumulator(hdr.frame_id, W, H);
            it = accum.find(hdr.frame_id);
        }

        FrameAccumulator& fa = it->second;
        int row_start = (int)hdr.row_start;
        int row_end   = (int)hdr.row_end;
        int rows      = row_end - row_start;

        // Copy strip into correct position in assembled frame
        memcpy(fa.rgba.data() + (size_t)row_start * W * 4,
               strip.data(),
               (size_t)rows * W * 4);

        fa.rows_received += rows;

        DBG("frame_id=%u: %d/%d rows received",
            hdr.frame_id, fa.rows_received, fa.total_rows);

        if (fa.rows_received >= fa.total_rows) {
            // Frame complete — forward to ingestion (rank 0)
            DBG("frame_id=%u complete, forwarding to rank %d",
                hdr.frame_id, cfg.send_to[0]);

            FrameHeader out_hdr = hdr;
            out_hdr.row_start     = 0;
            out_hdr.row_end       = (uint32_t)H;
            out_hdr.ghost_top     = 0;
            out_hdr.ghost_bottom  = 0;
            out_hdr.payload_bytes = (uint32_t)fa.rgba.size();

            mpi_send_frame(out_hdr, fa.rgba, cfg.send_to[0], cfg.rank);
            accum.erase(it);
        }
    }

    mpi_send_shutdown(cfg);
    DBG("shutting down");
}
