// sobel_arch3_scatter.cpp
// Architecture 3 — MPI Scatter-Gather: distribute image rows, 1-row halo exchange for 3x3 kernel.
// Usage: mpirun -n <P> ./sobel_arch3 <input_image> <output.png>
#include <mpi.h>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include "halo_utils.h"
#include <cmath>
#include <vector>
#include <algorithm>
#include <cstdio>

static const int Kx[3][3] = {{-1,0,1},{-2,0,2},{-1,0,1}};
static const int Ky[3][3] = {{-1,-2,-1},{0,0,0},{1,2,1}};

int main(int argc, char** argv) {
    MPI_Init(&argc, &argv);
    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    if (argc < 3) {
        if (rank == 0) printf("Usage: mpirun -n <P> %s <input_image> <output.png>\n", argv[0]);
        MPI_Finalize(); return 1;
    }

    int dims[2] = {0, 0};
    std::vector<unsigned char> img_flat;

    if (rank == 0) {
        int ch;
        unsigned char* img = stbi_load(argv[1], &dims[0], &dims[1], &ch, 1);
        if (!img) { fprintf(stderr, "Failed to load image\n"); MPI_Abort(MPI_COMM_WORLD,1); }
        img_flat.assign(img, img + dims[0]*dims[1]);
        stbi_image_free(img);
    }
    MPI_Bcast(dims, 2, MPI_INT, 0, MPI_COMM_WORLD);
    int width=dims[0], height=dims[1];

    // Distribute rows across ranks
    int base = height / size, rem = height % size;
    std::vector<int> counts(size), offsets(size);
    for (int i=0; i<size; ++i) {
        counts[i]  = (base + (i < rem ? 1 : 0)) * width;
        offsets[i] = (i==0) ? 0 : offsets[i-1]+counts[i-1];
    }
    int local_rows_count = counts[rank] / width;

    std::vector<unsigned char> local_data(counts[rank]);
    MPI_Scatterv(rank==0 ? img_flat.data() : nullptr,
                 counts.data(), offsets.data(), MPI_UNSIGNED_CHAR,
                 local_data.data(), counts[rank], MPI_UNSIGNED_CHAR,
                 0, MPI_COMM_WORLD);

    // 1-row halo exchange for 3×3 Sobel kernel
    std::vector<unsigned char> top_halo, bot_halo;
    exchange_halos(local_data, top_halo, bot_halo,
                   local_rows_count, width, 1, rank, size, MPI_COMM_WORLD);

    double t0 = MPI_Wtime();

    std::vector<float> mag_local(counts[rank], 0.0f);
    for (int y=0; y<local_rows_count; ++y)
        for (int x=0; x<width; ++x) {
            float gx=0, gy=0;
            for (int ky=-1; ky<=1; ++ky)
                for (int kx=-1; kx<=1; ++kx) {
                    int nx = std::max(0, std::min(width-1, x+kx));
                    unsigned char p = get_pixel(top_halo, local_data, bot_halo,
                                                y+ky, nx, local_rows_count, width, 1);
                    gx += p * Kx[ky+1][kx+1];
                    gy += p * Ky[ky+1][kx+1];
                }
            mag_local[y*width+x] = std::sqrt(gx*gx + gy*gy);
        }

    double t1 = MPI_Wtime();

    // Gather magnitudes at master
    std::vector<float> mag_full;
    if (rank==0) mag_full.resize(width*height);
    MPI_Gatherv(mag_local.data(), counts[rank], MPI_FLOAT,
                rank==0 ? mag_full.data() : nullptr,
                counts.data(), offsets.data(), MPI_FLOAT,
                0, MPI_COMM_WORLD);

    if (rank==0) {
        printf("[Sobel Scatter] ranks=%d  compute_time=%.5f s\n", size, t1-t0);
        float mx = *std::max_element(mag_full.begin(), mag_full.end());
        std::vector<unsigned char> out(width*height);
        for (int i=0; i<width*height; ++i)
            out[i] = (unsigned char)(255.0f * mag_full[i] / (mx + 1e-6f));
        stbi_write_png(argv[2], width, height, 1, out.data(), width);
    }
    MPI_Finalize();
    return 0;
}
