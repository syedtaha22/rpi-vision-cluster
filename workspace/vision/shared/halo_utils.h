#pragma once
#include <mpi.h>
#include <vector>
#include <algorithm>

// Exchange halo rows between adjacent ranks.
// Each rank sends its top/bottom boundary rows and receives halos from neighbours.
// halo = number of boundary rows needed (1 for 3x3 kernel, 2 for 5x5 kernel)
inline void exchange_halos(
    const std::vector<unsigned char>& local_rows,
    std::vector<unsigned char>& top_halo,
    std::vector<unsigned char>& bot_halo,
    int local_count, int width, int halo,
    int rank, int size, MPI_Comm comm)
{
    top_halo.assign(halo * width, 0);
    bot_halo.assign(halo * width, 0);

    // Send top rows to rank-1, receive bottom halo from rank-1
    if (rank > 0) {
        MPI_Sendrecv(
            local_rows.data(), halo * width, MPI_UNSIGNED_CHAR, rank-1, 0,
            top_halo.data(),   halo * width, MPI_UNSIGNED_CHAR, rank-1, 1,
            comm, MPI_STATUS_IGNORE);
    }
    // Send bottom rows to rank+1, receive top halo from rank+1
    if (rank < size-1) {
        MPI_Sendrecv(
            local_rows.data() + (local_count-halo)*width, halo*width, MPI_UNSIGNED_CHAR, rank+1, 1,
            bot_halo.data(), halo*width, MPI_UNSIGNED_CHAR, rank+1, 0,
            comm, MPI_STATUS_IGNORE);
    }
}

// Helper: safe pixel access across local partition + halos.
// y is relative to the start of the local partition (0-indexed, can be negative for halos)
inline unsigned char get_pixel(
    const std::vector<unsigned char>& top_halo,
    const std::vector<unsigned char>& local_rows,
    const std::vector<unsigned char>& bot_halo,
    int y, int x, int local_count, int width, int halo)
{
    if (y < 0) {
        int hy = y + halo;
        return (hy >= 0) ? top_halo[hy*width + x] : 0;
    }
    if (y >= local_count) {
        int hy = y - local_count;
        return (hy < halo) ? bot_halo[hy*width + x] : 0;
    }
    return local_rows[y*width + x];
}
