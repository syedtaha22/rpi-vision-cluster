/**
 * @file matrix_multiply.c
 * @brief Matrix multiplication with automatic MPI/Serial compilation detection
 *
 * This program performs NxN matrix multiplication and automatically adapts
 * its execution mode based on the compiler used:
 *   - Compiled with mpicc: Parallel execution using MPI with row-wise distribution
 *   - Compiled with gcc: Serial execution.
 *
 * Both modes use deterministic initialization for reproducible results.
 *
 * @author Syed Taha
 * @date 5th March, 2026
 *
 * Usage:
 *   MPI:    mpicc matrix_multiply.c -o matrix_multiply && mpirun -np N ./matrix_multiply
 *   Serial: gcc matrix_multiply.c -o matrix_multiply && ./matrix_multiply
 */

#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <sys/time.h>

#ifdef __has_include
#if __has_include(<mpi.h>)
#include <mpi.h>
#endif
#endif

#define N 800  /**< Matrix dimension (NxN) */

 /**
  * @brief Initialize matrices A and B with deterministic values
  *
  * Uses simple mathematical formulas instead of random numbers to ensure
  * reproducible results across multiple runs and different compilation modes.
  *
  * @param A Pointer to matrix A (size n*n)
  * @param B Pointer to matrix B (size n*n)
  * @param n Dimension of the square matrices
  */
void init_matrices(double* A, double* B, int n) {
    for (int i = 0; i < n * n; i++) {
        A[i] = (double)(i % 100) / 100.0;
        B[i] = (double)((i * 7 + 13) % 100) / 100.0;
    }
}

/**
 * @brief Perform matrix multiplication C = A * B
 *
 * @param A Pointer to matrix A (size rows * cols)
 * @param B Pointer to matrix B (size cols * cols)
 * @param C Pointer to result matrix C (size rows * cols)
 * @param rows Number of rows in A (and C)
 * @param cols Number of columns in A, B, and C
 */
void matmul(double* A, double* B, double* C, int rows, int cols) {
    for (int i = 0; i < rows; i++) {
        for (int j = 0; j < cols; j++) {
            C[i * cols + j] = 0.0;
            for (int k = 0; k < cols; k++) {
                C[i * cols + j] += A[i * cols + k] * B[k * cols + j];
            }
        }
    }
}

/**
 * @brief Print performance metrics and timing breakdown
 *
 * Displays matrix size, number of processes, timing breakdown, and performance in GFLOPS.
 *
 * @param n Matrix dimension
 * @param procs Number of processes (1 for serial, >1 for MPI)
 * @param total Total execution time in seconds
 * @param comp Computation time in seconds
 * @param comm Communication time in seconds (0 for serial)
 */
void print_performance(int n, int procs, double total, double comp, double comm) {
    printf("\n=== Performance Report (%s) ===\n", procs > 1 ? "MPI" : "Serial");
    printf("Matrix: %dx%d | Procs: %d\n", n, n, procs);
    printf("Total: %.4fs | Compute: %.4fs | Comm: %.4fs\n", total, comp, comm);
    printf("GFLOPS: %.2f\n", (2.0 * n * n * n) / (comp * 1e9));
}

/**
 * @brief Get current time in seconds with high precision
 *
 * Uses the appropriate timing function based on compilation mode:
 *   - MPI mode: MPI_Wtime() for wallclock time
 *   - Serial mode: gettimeofday() system call
 *
 * @return Current time in seconds as a double
 */
double get_time() {
#ifdef OMPI_MPI_H
    return MPI_Wtime();
#else
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec * 1e-6;
#endif
}

/**
 * @brief Main function - orchestrates matrix multiplication
 *
 * Execution flow:
 *   1. Initialize MPI (if compiled with mpicc)
 *   2. Allocate and initialize matrices (rank 0 only for A and C)
 *   3. Distribute data (MPI) or compute directly (serial)
 *   4. Perform matrix multiplication
 *   5. Gather results (MPI) and print performance
 *   6. Cleanup and finalize
 *
 * @param argc Argument count
 * @param argv Argument vector
 * @return Exit status (0 for success)
 */
int main(int argc, char** argv) {
    int rank = 0, size = 1;
    double start_t, comp_t, comm_t = 0, comm_start;
    double* A = NULL, * B = NULL, * C = NULL;

#ifdef OMPI_MPI_H
    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
#endif

    // 1. Everyone allocates B (Master and Workers alike)
    B = (double*)malloc(N * N * sizeof(double));

    // 2. Only Rank 0 (or Serial) allocates A and C, and initializes data
    if (rank == 0) {
        A = (double*)malloc(N * N * sizeof(double));
        C = (double*)malloc(N * N * sizeof(double));

        // Initialize the values in A and B
        init_matrices(A, B, N);
    }

    start_t = get_time();

#ifdef OMPI_MPI_H
    double* lA = (double*)malloc((N / size) * N * sizeof(double));
    double* lC = (double*)malloc((N / size) * N * sizeof(double));

    comm_start = get_time();
    MPI_Bcast(B, N * N, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    MPI_Scatter(A, (N / size) * N, MPI_DOUBLE, lA, (N / size) * N, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    comm_t += get_time() - comm_start;

    double c_now = get_time();
    matmul(lA, B, lC, N / size, N);
    comp_t = get_time() - c_now;

    comm_start = get_time();
    MPI_Gather(lC, (N / size) * N, MPI_DOUBLE, C, (N / size) * N, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    comm_t += get_time() - comm_start;

    free(lA); free(lC);
#else
    double c_now = get_time();
    matmul(A, B, C, N, N);
    comp_t = get_time() - c_now;
#endif

    double total_t = get_time() - start_t;

    if (rank == 0) {
        print_performance(N, size, total_t, comp_t, comm_t);
        free(A);
        free(C);
    }

    free(B);

#ifdef OMPI_MPI_H
    MPI_Finalize();
#endif
    return 0;
}
