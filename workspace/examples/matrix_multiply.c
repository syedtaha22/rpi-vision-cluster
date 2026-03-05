/*
 * MPI Matrix Multiplication Example
 * Demonstrates parallel computation and communication overhead
 */

#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define N 800  // Matrix size

void matrix_multiply(double* A, double* B, double* C, int rows, int n) {
    for (int i = 0; i < rows; i++) {
        for (int j = 0; j < n; j++) {
            C[i * n + j] = 0.0;
            for (int k = 0; k < n; k++) {
                C[i * n + j] += A[i * n + k] * B[k * n + j];
            }
        }
    }
}

int main(int argc, char** argv) {
    int rank, size;
    double start_time, end_time;
    double total_time, compute_time, comm_time;
    double comm_start, comm_end;

    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    start_time = MPI_Wtime();

    double* A = NULL;
    double* B = (double*)malloc(N * N * sizeof(double));
    double* local_A = (double*)malloc((N / size) * N * sizeof(double));
    double* local_C = (double*)malloc((N / size) * N * sizeof(double));
    double* C = NULL;

    if (rank == 0) {
        A = (double*)malloc(N * N * sizeof(double));
        C = (double*)malloc(N * N * sizeof(double));

        // Initialize matrices
        srand(time(NULL));
        for (int i = 0; i < N * N; i++) {
            A[i] = (double)rand() / RAND_MAX;
            B[i] = (double)rand() / RAND_MAX;
        }
        printf("Rank 0: Initialized %dx%d matrices\n", N, N);
    }

    comm_start = MPI_Wtime();

    // Broadcast matrix B to all processes
    MPI_Bcast(B, N * N, MPI_DOUBLE, 0, MPI_COMM_WORLD);

    // Scatter rows of A
    MPI_Scatter(A, (N / size) * N, MPI_DOUBLE,
        local_A, (N / size) * N, MPI_DOUBLE,
        0, MPI_COMM_WORLD);

    comm_end = MPI_Wtime();
    comm_time = comm_end - comm_start;

    // Compute local matrix multiplication
    double comp_start = MPI_Wtime();
    matrix_multiply(local_A, B, local_C, N / size, N);
    double comp_end = MPI_Wtime();
    compute_time = comp_end - comp_start;

    printf("Rank %d: Computed %d rows in %.4fs\n", rank, N / size, compute_time);

    comm_start = MPI_Wtime();

    // Gather results
    MPI_Gather(local_C, (N / size) * N, MPI_DOUBLE,
        C, (N / size) * N, MPI_DOUBLE,
        0, MPI_COMM_WORLD);

    comm_end = MPI_Wtime();
    comm_time += (comm_end - comm_start);

    end_time = MPI_Wtime();
    total_time = end_time - start_time;

    if (rank == 0) {
        double flops = 2.0 * N * N * N;
        double gflops = flops / (compute_time * 1e9);

        printf("\n=== Performance Report ===\n");
        printf("Matrix Size:       %dx%d\n", N, N);
        printf("Processes:         %d\n", size);
        printf("Total Time:        %.4f seconds\n", total_time);
        printf("Computation Time:  %.4f seconds\n", compute_time);
        printf("Communication Time: %.4f seconds\n", comm_time);
        printf("Compute/Total:     %.2f%%\n", (compute_time / total_time) * 100);
        printf("Comm/Total:        %.2f%%\n", (comm_time / total_time) * 100);
        printf("Performance:       %.2f GFLOPS\n", gflops);
        printf("Result checksum:   %.6f\n", C[0] + C[N * N - 1]);

        free(A);
        free(C);
    }

    free(B);
    free(local_A);
    free(local_C);

    MPI_Finalize();
    return 0;
}
