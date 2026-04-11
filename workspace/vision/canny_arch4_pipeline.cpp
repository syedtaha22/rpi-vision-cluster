// canny_arch4_pipeline.cpp
// Architecture 4 — MPI Pipeline: each rank owns one Canny stage, images stream through.
//   Rank 0: Gaussian smoothing
//   Rank 1: Gradient + NMS
//   Rank 2: Threshold + hysteresis
//   Rank 3: Save output
// Streaming over N images achieves temporal parallelism across the pipeline.
// Usage: mpirun -n 4 ./canny_arch4 <image_list.txt> <output_dir/> <N_images>
#include <mpi.h>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include <cmath>
#include <vector>
#include <queue>
#include <cstdio>
#include <algorithm>

static const int Kx[3][3] = {{-1,0,1},{-2,0,2},{-1,0,1}};
static const int Ky[3][3] = {{-1,-2,-1},{0,0,0},{1,2,1}};
static const float G5[5][5] = {
    {2,4,5,4,2},{4,9,12,9,4},{5,12,15,12,5},{4,9,12,9,4},{2,4,5,4,2}
};
static const float G5S = 159.0f;
static const unsigned char STRONG=255, WEAK=50;

int main(int argc, char** argv) {
    MPI_Init(&argc, &argv);
    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    if (size < 4) {
        if (rank==0) fprintf(stderr, "Error: need exactly 4 ranks for this pipeline.\n");
        MPI_Finalize(); return 1;
    }
    if (argc < 4) {
        if (rank==0) printf("Usage: mpirun -n 4 %s <image_list.txt> <output_dir/> <N_images>\n", argv[0]);
        MPI_Finalize(); return 1;
    }

    int N_images = atoi(argv[3]);
    float Th = 100.0f, Tl = 50.0f;

    // Sentinel: dims[0]=-1 signals end-of-stream to the next rank
    auto send_sentinel = [&](int dest) {
        int sentinel[2] = {-1, -1};
        MPI_Send(sentinel, 2, MPI_INT, dest, 0, MPI_COMM_WORLD);
    };

    double t_start = MPI_Wtime();

    // =========================================================
    if (rank == 0) {
        // ---- Stage 0: Gaussian smoothing ----
        FILE* f = fopen(argv[1], "r");
        if (!f) { fprintf(stderr, "Rank 0: cannot open image list %s\n", argv[1]); MPI_Abort(MPI_COMM_WORLD,1); }
        char path[512];
        for (int img_id = 0; img_id < N_images; ++img_id) {
            if (fscanf(f, "%s", path) != 1) break;
            int w, h, ch;
            unsigned char* img = stbi_load(path, &w, &h, &ch, 1);
            if (!img) { fprintf(stderr, "Rank 0: failed to load %s\n", path); continue; }

            int dims[2] = {w, h};
            MPI_Send(dims, 2, MPI_INT, 1, 0, MPI_COMM_WORLD);

            std::vector<float> smooth(w*h);
            for (int y=0; y<h; ++y)
                for (int x=0; x<w; ++x) {
                    float s=0;
                    for (int ky=-2; ky<=2; ++ky)
                        for (int kx=-2; kx<=2; ++kx)
                            s += img[std::max(0,std::min(h-1,y+ky))*w
                                     + std::max(0,std::min(w-1,x+kx))]
                                 * G5[ky+2][kx+2];
                    smooth[y*w+x] = s / G5S;
                }
            MPI_Send(smooth.data(), w*h, MPI_FLOAT, 1, 0, MPI_COMM_WORLD);
            stbi_image_free(img);
        }
        fclose(f);
        send_sentinel(1);

    // =========================================================
    } else if (rank == 1) {
        // ---- Stage 1: Gradient + NMS ----
        while (true) {
            int dims[2];
            MPI_Recv(dims, 2, MPI_INT, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            if (dims[0] == -1) break;
            int w=dims[0], h=dims[1];

            std::vector<float> smooth(w*h);
            MPI_Recv(smooth.data(), w*h, MPI_FLOAT, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);

            std::vector<float> mag(w*h,0), ang(w*h,0), nms_out(w*h,0);
            for (int y=0; y<h; ++y)
                for (int x=0; x<w; ++x) {
                    float gx=0, gy=0;
                    for (int ky=-1; ky<=1; ++ky)
                        for (int kx=-1; kx<=1; ++kx) {
                            float p = smooth[std::max(0,std::min(h-1,y+ky))*w
                                             + std::max(0,std::min(w-1,x+kx))];
                            gx += p * Kx[ky+1][kx+1];
                            gy += p * Ky[ky+1][kx+1];
                        }
                    mag[y*w+x] = std::sqrt(gx*gx + gy*gy);
                    float a = std::atan2(gy,gx)*180.0f/(float)M_PI;
                    ang[y*w+x] = (a < 0) ? a+180.0f : a;
                }
            for (int y=1; y<h-1; ++y)
                for (int x=1; x<w-1; ++x) {
                    float a=ang[y*w+x]; float q=0, r=0;
                    if      (a<22.5f||a>=157.5f) { q=mag[y*w+x+1];        r=mag[y*w+x-1]; }
                    else if (a<67.5f)            { q=mag[(y+1)*w+x-1];    r=mag[(y-1)*w+x+1]; }
                    else if (a<112.5f)           { q=mag[(y+1)*w+x];      r=mag[(y-1)*w+x]; }
                    else                         { q=mag[(y-1)*w+x-1];    r=mag[(y+1)*w+x+1]; }
                    nms_out[y*w+x] = (mag[y*w+x]>=q && mag[y*w+x]>=r) ? mag[y*w+x] : 0.0f;
                }

            MPI_Send(dims,       2,   MPI_INT,   2, 0, MPI_COMM_WORLD);
            MPI_Send(nms_out.data(), w*h, MPI_FLOAT, 2, 0, MPI_COMM_WORLD);
        }
        send_sentinel(2);

    // =========================================================
    } else if (rank == 2) {
        // ---- Stage 2: Threshold + hysteresis ----
        while (true) {
            int dims[2];
            MPI_Recv(dims, 2, MPI_INT, 1, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            if (dims[0] == -1) break;
            int w=dims[0], h=dims[1];

            std::vector<float> nms_in(w*h);
            MPI_Recv(nms_in.data(), w*h, MPI_FLOAT, 1, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);

            std::vector<unsigned char> edge(w*h, 0);
            for (int i=0; i<w*h; ++i) {
                if      (nms_in[i] >= Th) edge[i] = STRONG;
                else if (nms_in[i] >= Tl) edge[i] = WEAK;
            }
            std::queue<int> bfs;
            for (int i=0; i<w*h; ++i) if (edge[i]==STRONG) bfs.push(i);
            while (!bfs.empty()) {
                int idx=bfs.front(); bfs.pop();
                int y=idx/w, x=idx%w;
                for (int dy=-1; dy<=1; ++dy) for (int dx=-1; dx<=1; ++dx) {
                    if (!dy && !dx) continue;
                    int ny=y+dy, nx=x+dx;
                    if (ny<0||ny>=h||nx<0||nx>=w) continue;
                    int ni=ny*w+nx;
                    if (edge[ni]==WEAK) { edge[ni]=STRONG; bfs.push(ni); }
                }
            }
            std::vector<unsigned char> out(w*h);
            for (int i=0; i<w*h; ++i) out[i] = (edge[i]==STRONG) ? 255 : 0;

            MPI_Send(dims,      2,   MPI_INT,          3, 0, MPI_COMM_WORLD);
            MPI_Send(out.data(), w*h, MPI_UNSIGNED_CHAR, 3, 0, MPI_COMM_WORLD);
        }
        send_sentinel(3);

    // =========================================================
    } else if (rank == 3) {
        // ---- Stage 3: Save output ----
        int img_id = 0;
        while (true) {
            int dims[2];
            MPI_Recv(dims, 2, MPI_INT, 2, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            if (dims[0] == -1) break;
            int w=dims[0], h=dims[1];

            std::vector<unsigned char> out(w*h);
            MPI_Recv(out.data(), w*h, MPI_UNSIGNED_CHAR, 2, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);

            char out_path[512];
            snprintf(out_path, 512, "%s/canny_out_%04d.png", argv[2], img_id++);
            stbi_write_png(out_path, w, h, 1, out.data(), w);
        }
    }

    double t_end = MPI_Wtime();
    if (rank==0)
        printf("[Canny Pipeline] N=%d  total_time=%.5f s  throughput=%.3f img/s\n",
               N_images, t_end-t_start, N_images/(t_end-t_start));

    MPI_Finalize();
    return 0;
}
