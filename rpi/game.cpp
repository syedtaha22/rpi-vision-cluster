// ============================================================
// Pi Cluster Number Game — MPI Edition
// Compile: mpic++ -o game game.cpp
// Run:     mpirun -np N --hostfile ~/hostfile -wdir /tmp /tmp/game
// ============================================================
//
// WORKFLOW:
//   1. Worker 1 (SSH): echo YOUR_NUMBER > /tmp/my_number.txt
//   2. Worker 2 (SSH): echo YOUR_NUMBER > /tmp/my_number.txt
//   ...
//   N. Master:         mpirun -np N --hostfile ~/hostfile -wdir /tmp /tmp/game
//   N+1. Workers:      cat /tmp/result.txt  (to see the result)
//
// Rules: closest to master's number wins. Ties go to lower rank.
// ============================================================

#include <mpi.h>
#include <iostream>
#include <fstream>
#include <cstdlib>
#include <ctime>
#include <string>
#include <chrono>
#include <thread>
#include <vector>
#include <cmath>

int main(int argc, char* argv[]) {
    MPI_Init(&argc, &argv);

    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    if (size < 3 || size > 6) {
        if (rank == 0) std::cerr << "Need 3 to 6 processes (1 master + 2 to 5 workers).\n";
        MPI_Finalize();
        return 1;
    }

    const int TIMEOUT = 60;
    int num_workers = size - 1;

    // MASTER
    if (rank == 0) {
        srand(static_cast<unsigned>(time(nullptr)));
        int my_num = rand() % 100 + 1;
        std::cout << "[Master] Generated number: " << my_num << "\n" << std::flush;

        std::vector<int> worker_nums(num_workers, -1);
        std::vector<MPI_Request> reqs(num_workers);
        std::vector<MPI_Status> stats(num_workers);

        for (int i = 0; i < num_workers; i++) {
            MPI_Irecv(&worker_nums[i], 1, MPI_INT, i + 1, 0, MPI_COMM_WORLD, &reqs[i]);
        }

        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(TIMEOUT);
        std::vector<bool> done(num_workers, false);
        int done_count = 0;

        while (done_count < num_workers) {
            if (std::chrono::steady_clock::now() >= deadline) {
                for (int i = 0; i < num_workers; i++) {
                    if (!done[i]) {
                        MPI_Cancel(&reqs[i]);
                        MPI_Request_free(&reqs[i]);
                        std::cerr << "[Master] Timeout waiting for worker " << (i+1) << "!\n";
                    }
                }
                MPI_Finalize();
                return 1;
            }
            for (int i = 0; i < num_workers; i++) {
                if (!done[i]) {
                    int flag = 0;
                    MPI_Test(&reqs[i], &flag, &stats[i]);
                    if (flag) {
                        done[i] = true;
                        done_count++;
                    }
                }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }

        // Closest to master's number wins
        int winner_rank = 0;
        int winner_num  = my_num;
        int best_diff   = 1000; // Infinity

        // Consider workers
        for (int i = 0; i < num_workers; i++) {
            int diff = std::abs(worker_nums[i] - my_num);
            if (diff < best_diff) {
                best_diff = diff;
                winner_num = worker_nums[i];
                winner_rank = i + 1;
            }
        }

        std::string winner_name = (winner_rank == 0) ? "Master" : ("Worker " + std::to_string(winner_rank));

        std::cout << "\n╔══════════════ RESULTS ══════════════╗\n";
        std::cout << "║  Master's number : " << my_num << "\n";
        std::cout << "╠═════════════════════════════════════╣\n";
        for (int i = 0; i < num_workers; i++) {
            std::cout << "║  Worker " << (i+1) << ": " << worker_nums[i] << "  (diff: " << std::abs(worker_nums[i]-my_num) << ")\n";
        }
        std::cout << "╠═════════════════════════════════════╣\n";
        std::cout << "║  WINNER : " << winner_name << " with " << winner_num << " (off by " << best_diff << ")\n";
        std::cout << "╚═════════════════════════════════════╝\n" << std::flush;

        int result[2] = {winner_rank, winner_num};
        MPI_Bcast(result, 2, MPI_INT, 0, MPI_COMM_WORLD);

    // WORKERS
    } else {
        std::ifstream file("/tmp/my_number.txt");
        if (!file.is_open()) {
            std::cerr << "[Worker " << rank << "] /tmp/my_number.txt not found!\n"
                      << "  Run: echo YOUR_NUMBER > /tmp/my_number.txt\n";
            MPI_Abort(MPI_COMM_WORLD, 1);
            return 1;
        }

        int my_num = -1;
        file >> my_num;

        if (my_num < 1 || my_num > 100) {
            std::cerr << "[Worker " << rank << "] Number must be 1-100 (got " << my_num << ").\n";
            MPI_Abort(MPI_COMM_WORLD, 1);
            return 1;
        }

        std::cout << "[Worker " << rank << "] Submitted: " << my_num << "\n" << std::flush;
        MPI_Send(&my_num, 1, MPI_INT, 0, 0, MPI_COMM_WORLD);

        int result[2] = {-1, -1};
        MPI_Bcast(result, 2, MPI_INT, 0, MPI_COMM_WORLD);

        std::string winner_name = (result[0] == 0) ? "Master" : ("Worker " + std::to_string(result[0]));

        // Save result to file so worker can see it in their terminal
        std::ofstream result_file("/tmp/result.txt");
        result_file << "\n╔══════════════ RESULTS ══════════════╗\n";
        result_file << "║  WINNER : " << winner_name << " with " << result[1] << "\n";
        result_file << "╚═════════════════════════════════════╝\n";
        result_file.close();

        std::cout << "[Worker " << rank << "] Done! Run: cat /tmp/result.txt\n" << std::flush;
    }

    MPI_Finalize();
    return 0;
}
