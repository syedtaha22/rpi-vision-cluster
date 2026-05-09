/**
 * @file main.cpp
 * @brief Sobel Pipeline - MPI entry point.
 *
 * Rank 0 (master/ingestion):
 *   1. Parses ./pipeline.conf
 *   2. Broadcasts WorkerConfig to all ranks via MPI_Scatter
 *   3. Starts HTTP/WebSocket server on port 8000
 *   4. Forwards incoming frames into the MPI pipeline
 *   5. Receives processed frames back and sends to browser
 *
 * All other ranks:
 *   1. Receive their WorkerConfig
 *   2. Dispatch to the appropriate worker loop based on role
 *
 * Build:
 *   mpicxx -O2 -fopenmp -std=c++17 main.cpp -o sobel_pipeline -lssl -lcrypto
 *
 * Run:
 *   mpirun -np 6 --hostfile hosts.txt ./sobel_pipeline
 */

#include <mpi.h>
#include <omp.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <thread>
#include <mutex>
#include <queue>
#include <condition_variable>
#include <atomic>

#include "include/pipeline.h"
#include "include/config.h"
#include "include/httpws.h"
#include "include/workers.h"

// ── Pending frame queue (HTTP thread -> MPI send thread) ─────────────────────
struct PendingFrame {
    uint32_t             frame_id;
    std::vector<uint8_t> rgba;
    int                  width;
    int                  height;
};

static std::queue<PendingFrame>    g_frame_queue;
static std::mutex                  g_frame_mutex;
static std::condition_variable     g_frame_cv;
static std::atomic<bool>           g_shutdown{false};

// ── Completed frame queue (MPI recv thread -> HTTP send thread) ───────────────
struct CompletedFrame {
    uint32_t             frame_id;
    std::vector<uint8_t> rgba;
};

static std::queue<CompletedFrame>  g_result_queue;
static std::mutex                  g_result_mutex;
static std::condition_variable     g_result_cv;

// ── Master ingestion worker ───────────────────────────────────────────────────
/**
 * @brief MPI send thread: dequeues pending frames, sends to downstream worker.
 */
void mpi_send_thread(const WorkerConfig& cfg) {
    _dbg_rank = cfg.rank;
    _dbg_role = cfg.role;

    DBG("MPI send thread started, forwarding to rank %d", cfg.send_to[0]);

    uint32_t frame_counter = 0;

    while (!g_shutdown.load()) {
        std::unique_lock<std::mutex> lk(g_frame_mutex);
        g_frame_cv.wait(lk, [] {
            return !g_frame_queue.empty() || g_shutdown.load();
        });

        if (g_shutdown.load() && g_frame_queue.empty()) break;

        PendingFrame pf = std::move(g_frame_queue.front());
        g_frame_queue.pop();
        lk.unlock();

        DBG("dequeued frame_id=%u, sending to rank %d", pf.frame_id, cfg.send_to[0]);

        FrameHeader hdr{};
        hdr.frame_id      = pf.frame_id;
        hdr.width         = (uint32_t)pf.width;
        hdr.height        = (uint32_t)pf.height;
        hdr.row_start     = 0;
        hdr.row_end       = (uint32_t)pf.height;
        hdr.ghost_top     = 0;
        hdr.ghost_bottom  = 0;
        hdr.payload_bytes = (uint32_t)pf.rgba.size();

        mpi_send_frame(hdr, pf.rgba, cfg.send_to[0], cfg.rank);
        frame_counter++;
    }

    // Send shutdown to downstream
    mpi_send_shutdown(cfg);
    DBG("MPI send thread exiting, sent %u frames total", frame_counter);
}

/**
 * @brief MPI recv thread: receives completed frames from THRESHOLD, enqueues for HTTP send.
 */
void mpi_recv_thread(const WorkerConfig& cfg) {
    _dbg_rank = cfg.rank;
    _dbg_role = cfg.role;

    // Threshold worker's rank is in cfg.recv_from for ingestion
    // (set in config as the rank of the threshold worker)
    DBG("MPI recv thread started, receiving results from rank %d", cfg.recv_from);

    while (!g_shutdown.load()) {
        FrameHeader hdr;
        std::vector<uint8_t> rgba;

        // Non-blocking probe so we can check g_shutdown
        int flag = 0;
        MPI_Status status;
        while (!flag && !g_shutdown.load()) {
            MPI_Iprobe(cfg.recv_from, TAG_FRAME_HEADER, MPI_COMM_WORLD, &flag, &status);
            if (!flag) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        if (g_shutdown.load()) break;

        if (!mpi_recv_frame(hdr, rgba, cfg.recv_from, cfg.rank)) break;

        DBG("received completed frame_id=%u (%u bytes)", hdr.frame_id, hdr.payload_bytes);

        {
            std::lock_guard<std::mutex> lk(g_result_mutex);
            g_result_queue.push({hdr.frame_id, std::move(rgba)});
        }
        g_result_cv.notify_one();
    }

    DBG("MPI recv thread exiting");
}

/**
 * @brief Result dispatch thread: dequeues completed frames, sends via WebSocket.
 */
void result_dispatch_thread(HttpWsServer* server) {
    while (!g_shutdown.load()) {
        std::unique_lock<std::mutex> lk(g_result_mutex);
        g_result_cv.wait(lk, [] {
            return !g_result_queue.empty() || g_shutdown.load();
        });

        if (g_shutdown.load() && g_result_queue.empty()) break;

        CompletedFrame cf = std::move(g_result_queue.front());
        g_result_queue.pop();
        lk.unlock();

        server->send_result(cf.frame_id, cf.rgba);
    }
}

/**
 * @brief Frame callback: called by HTTP server when a new frame arrives from browser.
 */
void on_frame_received(uint32_t frame_id,
                       const std::vector<uint8_t>& rgba,
                       int width, int height) {
    {
        std::lock_guard<std::mutex> lk(g_frame_mutex);
        // Drop frame if queue is backed up — keep at most 2 frames queued
        if (g_frame_queue.size() >= 2) {
            fprintf(stderr, "[ingestion] dropping frame_id=%u (queue full)\n", frame_id);
            return;
        }
        g_frame_queue.push({frame_id, rgba, width, height});
    }
    g_frame_cv.notify_one();
}

// ── Worker role dispatch ──────────────────────────────────────────────────────
void run_worker(const WorkerConfig& cfg) {
    fprintf(stderr, "[rank %d] role=%s omp_threads=%d recv_from=%d send_to_count=%d\n",
            cfg.rank, role_name(cfg.role), cfg.omp_threads,
            cfg.recv_from, cfg.send_to_count);

    switch (cfg.role) {
        case ROLE_GRAYSCALE:
            worker_grayscale(cfg);
            break;
        case ROLE_CONVOLUTION:
            worker_convolution(cfg);
            break;
        case ROLE_THRESHOLD:
            worker_threshold(cfg);
            break;
        default:
            fprintf(stderr, "[rank %d] ERROR: unknown role %d\n", cfg.rank, cfg.role);
            break;
    }
}

// ── Main ─────────────────────────────────────────────────────────────────────
int main(int argc, char** argv) {
    // MPI_THREAD_MULTIPLE because rank 0 will have multiple threads calling MPI
    int provided;
    MPI_Init_thread(&argc, &argv, MPI_THREAD_MULTIPLE, &provided);
    if (provided < MPI_THREAD_MULTIPLE) {
        fprintf(stderr, "WARNING: MPI does not fully support MPI_THREAD_MULTIPLE "
                        "(provided=%d). Thread safety not guaranteed.\n", provided);
    }

    int world_rank, world_size;
    MPI_Comm_rank(MPI_COMM_WORLD, &world_rank);
    MPI_Comm_size(MPI_COMM_WORLD, &world_size);

    fprintf(stderr, "[rank %d/%d] started\n", world_rank, world_size);

    // ── Parse and broadcast config (rank 0 only) ──────────────────────────────
    std::vector<WorkerConfig> all_configs;

    if (world_rank == 0) {
        fprintf(stderr, "[rank 0] parsing config from '%s'\n", PIPELINE_CONFIG_PATH);
        if (!parse_config(PIPELINE_CONFIG_PATH, all_configs)) {
            fprintf(stderr, "[rank 0] FATAL: config parse failed\n");
            MPI_Abort(MPI_COMM_WORLD, 1);
            return 1;
        }

        if ((int)all_configs.size() != world_size) {
            fprintf(stderr, "[rank 0] FATAL: config has %zu entries but MPI world size is %d\n",
                    all_configs.size(), world_size);
            MPI_Abort(MPI_COMM_WORLD, 1);
            return 1;
        }

        fprintf(stderr, "[rank 0] broadcasting %zu configs\n", all_configs.size());
    } else {
        all_configs.resize(world_size);
    }

    // Broadcast all configs to all ranks
    MPI_Bcast(all_configs.data(),
              (int)(world_size * sizeof(WorkerConfig)),
              MPI_BYTE, 0, MPI_COMM_WORLD);

    WorkerConfig my_config = all_configs[world_rank];

    MPI_Barrier(MPI_COMM_WORLD);
    fprintf(stderr, "[rank %d] config received: role=%s\n",
            world_rank, role_name(my_config.role));

    // ── Dispatch ──────────────────────────────────────────────────────────────
    if (my_config.role == ROLE_INGESTION) {
        // Rank 0: HTTP server + MPI bridge
        _dbg_rank = my_config.rank;
        _dbg_role = my_config.role;

        DBG("starting HTTP server on port %d", HTTP_PORT);

        HttpWsServer server(HTTP_PORT,
                            my_config.image_width,
                            my_config.image_height,
                            on_frame_received);
        server.start();

        // Spawn MPI bridge threads
        std::thread send_t(mpi_send_thread, my_config);
        std::thread recv_t(mpi_recv_thread, my_config);
        std::thread disp_t(result_dispatch_thread, &server);

        DBG("all threads started, open http://<pi-ip>:%d in your browser", HTTP_PORT);

        // Block until Ctrl+C
        // In production you'd install a signal handler; for now just join
        send_t.join();
        recv_t.join();

        g_shutdown.store(true);
        g_result_cv.notify_all();
        disp_t.join();

        server.stop();
    } else {
        run_worker(my_config);
    }

    MPI_Finalize();
    fprintf(stderr, "[rank %d] exited cleanly\n", world_rank);
    return 0;
}
