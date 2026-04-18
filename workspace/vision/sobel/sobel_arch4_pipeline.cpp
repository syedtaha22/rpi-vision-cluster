// sobel_arch4_pipeline.cpp
// Architecture 4 — MPI Distributed Pipeline: stage-parallel Sobel across ranks.
// Rank 0: Kx + Ky convolution (gradient computation)
// Rank 1: Magnitude normalisation + save output
// In streaming mode, rank 0 processes image i+1 while rank 1 processes image i.
// Usage: mpirun -n 2 ./sobel_arch4 <image_list_file> <output_dir> <N_images>
//        mpirun -n 2 ./sobel_arch4 <single_image> <output.png>   (single-image mode)
#include <mpi.h>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include <cmath>
#include <vector>
#include <algorithm>
#include <cstdio>
#include <cstring>

static const int Kx[3][3] = {{-1,0,1},{-2,0,2},{-1,0,1}};
static const int Ky[3][3] = {{-1,-2,-1},{0,0,0},{1,2,1}};

int main(int argc, char** argv) {
    MPI_Init(&argc, &argv);
    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    if (size < 2) {
        if (rank == 0) fprintf(stderr, "[Sobel Pipeline] Need at least 2 ranks.\n");
        MPI_Finalize();
        return 1;
    }

    bool single_mode = (argc == 3);
    int N_images = 1;

    if (!single_mode && argc < 4) {
        if (rank == 0) fprintf(stderr, "Usage: %s <image_list> <output_dir> <N_images>\n"
                                       "   or: %s <input_image> <output.png>\n", argv[0], argv[0]);
        MPI_Finalize();
        return 1;
    }
    if (!single_mode) N_images = atoi(argv[3]);

    double t_start = MPI_Wtime();

    auto send_sentinel = [&](int dest) {
        int s[2] = {-1, -1};
        MPI_Send(s, 2, MPI_INT, dest, 0, MPI_COMM_WORLD);
    };

    if (rank == 0) {
        // ---- Stage 0: Gradient computation (Kx + Ky → magnitude) ----
        FILE* flist = single_mode ? nullptr : fopen(argv[1], "r");

        for (int img_id = 0; img_id < N_images; ++img_id) {
            char path[512];
            if (single_mode) {
                strncpy(path, argv[1], sizeof(path));
            } else {
                if (fscanf(flist, "%511s", path) != 1) break;
            }

            int w, h, ch;
            unsigned char* img = stbi_load(path, &w, &h, &ch, 1);
            if (!img) { fprintf(stderr, "Rank0: failed to load %s\n", path); continue; }

            int dims[2] = {w, h};
            MPI_Send(dims, 2, MPI_INT, 1, 0, MPI_COMM_WORLD);

            std::vector<float> mag(w * h, 0.0f);
            for (int y = 0; y < h; ++y)
                for (int x = 0; x < w; ++x) {
                    float gx = 0.0f, gy = 0.0f;
                    for (int ky = -1; ky <= 1; ++ky) {
                        int ny = std::max(0, std::min(h-1, y+ky));
                        for (int kx = -1; kx <= 1; ++kx) {
                            int nx = std::max(0, std::min(w-1, x+kx));
                            unsigned char p = img[ny*w + nx];
                            gx += p * Kx[ky+1][kx+1];
                            gy += p * Ky[ky+1][kx+1];
                        }
                    }
                    mag[y*w + x] = std::sqrt(gx*gx + gy*gy);
                }

            MPI_Send(mag.data(), w * h, MPI_FLOAT, 1, 0, MPI_COMM_WORLD);
            stbi_image_free(img);
        }
        if (flist) fclose(flist);
        send_sentinel(1);

    } else if (rank == 1) {
        // ---- Stage 1: Normalise and save ----
        int img_id = 0;
        while (true) {
            int dims[2];
            MPI_Recv(dims, 2, MPI_INT, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            if (dims[0] == -1) break;

            int w = dims[0], h = dims[1];
            std::vector<float> mag(w * h);
            MPI_Recv(mag.data(), w * h, MPI_FLOAT, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);

            float mx = *std::max_element(mag.begin(), mag.end());
            std::vector<unsigned char> out(w * h);
            for (int i = 0; i < w * h; ++i)
                out[i] = (unsigned char)(255.0f * mag[i] / (mx + 1e-6f));

            char out_path[512];
            if (single_mode) {
                strncpy(out_path, argv[2], sizeof(out_path));
            } else {
                snprintf(out_path, sizeof(out_path), "%s/sobel_out_%04d.png", argv[2], img_id++);
            }
            stbi_write_png(out_path, w, h, 1, out.data(), w);
        }
    }

    double t_end = MPI_Wtime();
    if (rank == 0) {
        printf("[Sobel MPI Pipeline] N=%d  total_time=%.5f s  throughput=%.3f img/s\n",
               N_images, t_end - t_start, N_images / (t_end - t_start));
    }

    MPI_Finalize();
    return 0;
}
