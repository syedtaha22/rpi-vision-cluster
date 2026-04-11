// log_arch3_scatter.cpp
// Architecture 3 — MPI Scatter-Gather: 5x5 LoG kernel requires 2-row halo exchange.
// Usage: mpirun -n <P> ./log_arch3 <input_image> <output.png>
#include <mpi.h>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include "halo_utils.h"
#include <vector>
#include <algorithm>
#include <cstdio>

static const int K_LOG[5][5] = {
    { 0, 0,-1, 0, 0},
    { 0,-1,-2,-1, 0},
    {-1,-2,16,-2,-1},
    { 0,-1,-2,-1, 0},
    { 0, 0,-1, 0, 0}
};

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
    if (rank==0) {
        int ch;
        unsigned char* img = stbi_load(argv[1], &dims[0], &dims[1], &ch, 1);
        if (!img) { fprintf(stderr, "Failed to load image\n"); MPI_Abort(MPI_COMM_WORLD,1); }
        img_flat.assign(img, img+dims[0]*dims[1]);
        stbi_image_free(img);
    }
    MPI_Bcast(dims, 2, MPI_INT, 0, MPI_COMM_WORLD);
    int width=dims[0], height=dims[1];

    int base=height/size, rem=height%size;
    std::vector<int> counts(size), offsets(size);
    for (int i=0; i<size; ++i) {
        counts[i]  = (base + (i<rem ? 1 : 0)) * width;
        offsets[i] = (i==0) ? 0 : offsets[i-1]+counts[i-1];
    }
    int lr = counts[rank] / width;

    std::vector<unsigned char> local_data(counts[rank]);
    MPI_Scatterv(rank==0 ? img_flat.data() : nullptr,
                 counts.data(), offsets.data(), MPI_UNSIGNED_CHAR,
                 local_data.data(), counts[rank], MPI_UNSIGNED_CHAR,
                 0, MPI_COMM_WORLD);

    // 2-row halo for 5×5 LoG kernel
    std::vector<unsigned char> top_halo, bot_halo;
    exchange_halos(local_data, top_halo, bot_halo, lr, width, 2, rank, size, MPI_COMM_WORLD);

    double t0 = MPI_Wtime();

    std::vector<float> resp(counts[rank], 0.0f);
    for (int y=0; y<lr; ++y)
        for (int x=0; x<width; ++x) {
            float r=0;
            for (int ky=-2; ky<=2; ++ky)
                for (int kx=-2; kx<=2; ++kx) {
                    int nx = std::max(0, std::min(width-1, x+kx));
                    r += get_pixel(top_halo, local_data, bot_halo,
                                   y+ky, nx, lr, width, 2) * K_LOG[ky+2][kx+2];
                }
            resp[y*width+x] = r;
        }

    // Local zero-crossing detection
    std::vector<unsigned char> edge_local(counts[rank], 0);
    for (int y=1; y<lr-1; ++y)
        for (int x=1; x<width-1; ++x) {
            float c=resp[y*width+x];
            if ((c*resp[y*width+x+1]   < 0) ||
                (c*resp[y*width+x-1]   < 0) ||
                (c*resp[(y+1)*width+x] < 0) ||
                (c*resp[(y-1)*width+x] < 0))
                edge_local[y*width+x] = 255;
        }

    double t1 = MPI_Wtime();

    std::vector<unsigned char> out;
    if (rank==0) out.resize(width*height);
    MPI_Gatherv(edge_local.data(), counts[rank], MPI_UNSIGNED_CHAR,
                rank==0 ? out.data() : nullptr,
                counts.data(), offsets.data(), MPI_UNSIGNED_CHAR,
                0, MPI_COMM_WORLD);

    if (rank==0) {
        printf("[LoG Scatter] ranks=%d  compute_time=%.5f s\n", size, t1-t0);
        stbi_write_png(argv[2], width, height, 1, out.data(), width);
    }
    MPI_Finalize();
    return 0;
}
