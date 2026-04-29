// Program to check MPI latency and bandwidth for various message sizes and communication patterns.
// Use conditional compilation to ensure it runs in serial mode if MPI is not available.
// Also to prevent error squiggles in environment where MPI headers are not present.

#include <stdio.h>
#include <stdlib.h>

#ifdef __has_include
#if __has_include(<mpi.h>)
#include <mpi.h>
#endif
#endif

#ifdef OMPI_MPI_H
#define ITERS 100

// Helper to handle all the timing and printing logic
void run_test(const char* label, int size, int rank, int cluster_size, int is_coll) {
    char* sbuf = malloc(size), * rbuf = malloc(size);
    double start, total = 0;

    // Standardize rank 1 for P2P tests
    int partner = 1 % cluster_size;

    MPI_Barrier(MPI_COMM_WORLD);
    start = MPI_Wtime();

    for (int i = 0; i < ITERS / 10; i++) {
        if (is_coll == 1) MPI_Bcast(sbuf, size, MPI_CHAR, 0, MPI_COMM_WORLD);
        else if (is_coll == 2) MPI_Alltoall(sbuf, size / cluster_size, MPI_CHAR, rbuf, size / cluster_size, MPI_CHAR, MPI_COMM_WORLD);
        else { // Point-to-Point Ping-Pong
            if (rank == 0) {
                MPI_Send(sbuf, size, MPI_CHAR, partner, 0, MPI_COMM_WORLD);
                MPI_Recv(rbuf, size, MPI_CHAR, partner, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            }
            else if (rank == partner) {
                MPI_Recv(rbuf, size, MPI_CHAR, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                MPI_Send(sbuf, size, MPI_CHAR, 0, 0, MPI_COMM_WORLD);
            }
        }
    }

    total = MPI_Wtime() - start;
    if (rank == 0) {
        double avg = (total / (ITERS / 10)) * 1e6;
        printf("%-15s | Size: %7d B | Time: %10.2f us\n", label, size, avg);
    }
    free(sbuf); free(rbuf);
}

int main(int argc, char** argv) {
    int rank, size;
    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    if (rank == 0) printf("=== MPI Latency/Bandwidth Benchmark ===\n");

    // Ping-Pong Tests (Point-to-Point)
    int p2p_sizes[] = { 1, 1024, 10240, 102400, 1048576 };
    for (int i = 0; i < 5; i++) run_test("Ping-Pong", p2p_sizes[i], rank, size, 0);

    // Collective Tests (Bcast = 1, All-to-all = 2)
    if (size > 1) {
        run_test("Broadcast", 1024, rank, size, 1);
        run_test("Broadcast", 1048576, rank, size, 1);
        run_test("All-to-All", 1024 * size, rank, size, 2);
    }

    if (rank == 0) printf("=== Test Complete ===\n");
    MPI_Finalize();
    return 0;
}
#else 
int main() {
    printf("This program is designed to be run with MPI. Please compile with mpicc and run with mpirun.\n");
    return 0;
}
#endif