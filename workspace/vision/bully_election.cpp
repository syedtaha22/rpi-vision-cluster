// bully_election.cpp
// Bully Algorithm — Leader Election for MPI Cluster
//
// The bully algorithm elects the highest-ranked surviving process as coordinator.
// A process that discovers a missing coordinator starts an election by sending
// ELECTION messages to all higher-ranked processes. If no response arrives within
// a timeout, the initiator declares itself coordinator and broadcasts COORDINATOR.
// Higher-ranked processes that receive ELECTION reply with OK and start their own
// election upward.
//
// This implementation:
//   - Simulates node failures by having designated ranks call MPI_Abort on
//     themselves after a configurable delay (--fail <rank_list>)
//   - Uses non-blocking probes with a wall-clock timeout to detect missing responses
//   - Measures and prints election latency and the number of rounds
//
// Usage:
//   mpirun -n <P> ./bully_election [--fail <r1,r2,...>] [--timeout <ms>]
//   Example (6 nodes, kill ranks 5 and 4 so rank 3 becomes leader):
//   mpirun -n 6 ./bully_election --fail 4,5 --timeout 500

#include <mpi.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <set>
#include <algorithm>
#include <chrono>
#include <thread>

// Message tags
#define TAG_ELECTION    10
#define TAG_OK          11
#define TAG_COORDINATOR 12
#define TAG_PING        13
#define TAG_PONG        14
#define TAG_ALIVE       15

static double timeout_ms = 500.0;  // election response timeout in ms

// Wall-clock elapsed since t0, in milliseconds
static double elapsed_ms(double t0) {
    return (MPI_Wtime() - t0) * 1000.0;
}

// Non-blocking probe with timeout — returns true if message arrived
static bool probe_with_timeout(int source, int tag, MPI_Comm comm, double timeout) {
    double t0 = MPI_Wtime();
    int flag = 0;
    while (!flag && elapsed_ms(t0) < timeout) {
        MPI_Iprobe(source, tag, comm, &flag, MPI_STATUS_IGNORE);
        if (!flag) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return (bool)flag;
}

int main(int argc, char** argv) {
    MPI_Init(&argc, &argv);
    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    // Parse --fail and --timeout arguments
    std::set<int> failed_ranks;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--fail") == 0 && i + 1 < argc) {
            char* token = strtok(argv[i+1], ",");
            while (token) { failed_ranks.insert(atoi(token)); token = strtok(nullptr, ","); }
            ++i;
        } else if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc) {
            timeout_ms = atof(argv[i+1]);
            ++i;
        }
    }

    // Simulate node failure: the designated ranks exit after a brief delay
    // so other ranks perceive them as dead (no response to ELECTION/PING).
    if (failed_ranks.count(rank)) {
        printf("[Rank %d] Simulating failure (exiting).\n", rank);
        fflush(stdout);
        // Small delay so other ranks have time to start their ping check
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        MPI_Finalize();  // clean exit — real fault would use MPI_Abort or process kill
        return 0;
    }

    MPI_Barrier(MPI_COMM_WORLD);  // synchronise surviving ranks
    double t_election_start = MPI_Wtime();

    // ── Phase 1: Discover coordinator via PING ─────────────────────────────
    // Assume initial coordinator is rank size-1 (highest).
    // Each rank pings the assumed coordinator. If no PONG → start election.
    int assumed_coordinator = size - 1;
    bool need_election = false;

    if (rank != assumed_coordinator) {
        // Check if assumed coordinator is in failed set (simulated failure detection)
        if (failed_ranks.count(assumed_coordinator)) {
            need_election = true;
        } else {
            // Send PING
            int ping = rank;
            MPI_Send(&ping, 1, MPI_INT, assumed_coordinator, TAG_PING, MPI_COMM_WORLD);
            // Wait for PONG with timeout
            bool got_pong = probe_with_timeout(assumed_coordinator, TAG_PONG, MPI_COMM_WORLD, timeout_ms);
            if (got_pong) {
                int pong;
                MPI_Recv(&pong, 1, MPI_INT, assumed_coordinator, TAG_PONG, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            } else {
                need_election = true;
                if (rank == 0)
                    printf("[Rank %d] Coordinator %d not responding — starting election.\n",
                           rank, assumed_coordinator);
            }
        }
    } else {
        // We are the assumed coordinator: respond to any PINGs
        // Drain incoming PINGs (non-blocking, give 200ms window)
        double t0 = MPI_Wtime();
        while (elapsed_ms(t0) < 200.0) {
            int flag = 0;
            MPI_Status st;
            MPI_Iprobe(MPI_ANY_SOURCE, TAG_PING, MPI_COMM_WORLD, &flag, &st);
            if (flag) {
                int ping;
                MPI_Recv(&ping, 1, MPI_INT, st.MPI_SOURCE, TAG_PING, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                int pong = rank;
                MPI_Send(&pong, 1, MPI_INT, st.MPI_SOURCE, TAG_PONG, MPI_COMM_WORLD);
            } else {
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
            }
        }
        // Coordinator is alive — announce
        for (int dest = 0; dest < size; ++dest) {
            if (dest == rank || failed_ranks.count(dest)) continue;
            int coord = rank;
            MPI_Send(&coord, 1, MPI_INT, dest, TAG_COORDINATOR, MPI_COMM_WORLD);
        }
        double t_done = MPI_Wtime();
        printf("[Rank %d] Coordinator alive. Announced self. (%.3f ms)\n",
               rank, (t_done - t_election_start) * 1000.0);
        MPI_Finalize();
        return 0;
    }

    // ── Phase 2: Bully Election ────────────────────────────────────────────
    // Only ranks where need_election == true participate.
    // Each rank sends ELECTION to all higher-ranked surviving ranks.
    // If no OK received within timeout, declare self coordinator.

    int elected_coordinator = -1;
    int election_rounds = 0;

    if (need_election) {
        ++election_rounds;
        bool got_ok = false;

        // Send ELECTION to all higher ranks (skip known-failed)
        for (int dest = rank + 1; dest < size; ++dest) {
            if (failed_ranks.count(dest)) continue;
            int msg = rank;
            MPI_Send(&msg, 1, MPI_INT, dest, TAG_ELECTION, MPI_COMM_WORLD);
        }

        // Wait for any OK response (any higher rank is still alive)
        double t0 = MPI_Wtime();
        while (!got_ok && elapsed_ms(t0) < timeout_ms) {
            int flag = 0;
            MPI_Status st;
            MPI_Iprobe(MPI_ANY_SOURCE, TAG_OK, MPI_COMM_WORLD, &flag, &st);
            if (flag) {
                int ok;
                MPI_Recv(&ok, 1, MPI_INT, st.MPI_SOURCE, TAG_OK, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                got_ok = true;
                // A higher rank responded — it will continue the election upward
            }
            if (!got_ok) std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }

        if (!got_ok) {
            // No higher rank responded — we are the new coordinator
            elected_coordinator = rank;
            printf("[Rank %d] No higher rank responded — I am the new coordinator!\n", rank);

            // Broadcast COORDINATOR to all lower ranks
            for (int dest = 0; dest < rank; ++dest) {
                if (failed_ranks.count(dest)) continue;
                int coord = rank;
                MPI_Send(&coord, 1, MPI_INT, dest, TAG_COORDINATOR, MPI_COMM_WORLD);
            }
        }
    }

    // ── Phase 3: Respond to ELECTION messages from lower ranks ────────────
    // Drain any ELECTION messages directed at us (even if we already started our own)
    {
        double t0 = MPI_Wtime();
        while (elapsed_ms(t0) < timeout_ms) {
            int flag = 0;
            MPI_Status st;
            MPI_Iprobe(MPI_ANY_SOURCE, TAG_ELECTION, MPI_COMM_WORLD, &flag, &st);
            if (flag) {
                int election_msg;
                MPI_Recv(&election_msg, 1, MPI_INT, st.MPI_SOURCE, TAG_ELECTION,
                         MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                // Reply OK — we are alive and higher ranked
                int ok = rank;
                MPI_Send(&ok, 1, MPI_INT, st.MPI_SOURCE, TAG_OK, MPI_COMM_WORLD);
                // Initiate our own upward election if needed
                if (rank < size - 1 && need_election == false) {
                    need_election = true;
                    ++election_rounds;
                    for (int dest = rank + 1; dest < size; ++dest) {
                        if (failed_ranks.count(dest)) continue;
                        int msg = rank;
                        MPI_Send(&msg, 1, MPI_INT, dest, TAG_ELECTION, MPI_COMM_WORLD);
                    }
                }
            } else {
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
            }
        }
    }

    // ── Phase 4: Receive COORDINATOR announcement (if we didn't win) ──────
    if (elected_coordinator < 0) {
        bool got_coord = probe_with_timeout(MPI_ANY_SOURCE, TAG_COORDINATOR,
                                            MPI_COMM_WORLD, timeout_ms * 2);
        if (got_coord) {
            MPI_Status st;
            MPI_Recv(&elected_coordinator, 1, MPI_INT, MPI_ANY_SOURCE, TAG_COORDINATOR,
                     MPI_COMM_WORLD, &st);
        } else {
            // Fallback: assume highest surviving rank
            for (int r = size - 1; r >= 0; --r) {
                if (!failed_ranks.count(r) && r != rank) { elected_coordinator = r; break; }
                if (r == rank) { elected_coordinator = rank; break; }
            }
        }
    }

    double t_election_end = MPI_Wtime();
    double latency_ms = (t_election_end - t_election_start) * 1000.0;

    printf("[Rank %2d] Election complete. Coordinator = %d  "
           "Latency = %.2f ms  Rounds = %d\n",
           rank, elected_coordinator, latency_ms, election_rounds);
    fflush(stdout);

    MPI_Finalize();
    return 0;
}
