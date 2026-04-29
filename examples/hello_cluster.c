// Program to check MPI connectivity and print the hostname of each process in the cluster.
// Use conditional compilation to ensure it runs in serial mode if MPI is not available.
// Also to prevent error squiggles in environment where MPI headers are not present.

#include <stdio.h>

#ifdef __has_include
#if __has_include(<mpi.h>)
#include <mpi.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#endif
#endif

#ifdef OMPI_MPI_H


int main(int argc, char *argv[]) {
    MPI_Init(&argc, &argv);

    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    char hostname[256];
    if (gethostname(hostname, sizeof(hostname)) != 0) {
        perror("gethostname");
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    printf("Hello from rank %d of %d on host %s\n", rank, size, hostname);

    int name_len = strlen(hostname) + 1;
    int *recvcounts = NULL;
    int *displs = NULL;
    char *all_names = NULL;

    if (rank == 0) {
        recvcounts = malloc(size * sizeof(int));
        displs = malloc(size * sizeof(int));
        if (!recvcounts || !displs) {
            perror("malloc");
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
    }

    MPI_Gather(&name_len, 1, MPI_INT, recvcounts, 1, MPI_INT, 0, MPI_COMM_WORLD);

    if (rank == 0) {
        int total = 0;
        for (int i = 0; i < size; i++) {
            displs[i] = total;
            total += recvcounts[i];
        }
        all_names = malloc(total);
        if (!all_names) {
            perror("malloc");
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
    }

    MPI_Gatherv(hostname, name_len, MPI_CHAR,
                all_names, recvcounts, displs, MPI_CHAR,
                0, MPI_COMM_WORLD);

    if (rank == 0) {
        printf("Success! Cluster nodes found:\n");
        for (int i = 0; i < size; i++) {
            printf("  - %s\n", &all_names[displs[i]]);
        }
    }

    free(recvcounts);
    free(displs);
    free(all_names);

    MPI_Finalize();
    return 0;
}

#else 
int main() {
    printf("This program is designed to be run with MPI. Please compile with mpicc and run with mpirun.\n");
    return 0;
}
#endif