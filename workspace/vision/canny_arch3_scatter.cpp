// canny_arch3_scatter.cpp
// Architecture 3 — MPI Scatter-Gather: Stages 1-3 distributed across ranks with halo exchange.
// Stage 4 uses iterative boundary-exchange hysteresis — no global gather until convergence.
// Usage: mpirun -n <P> ./canny_arch3 <input_image> <output.png> [T_high] [T_low]
#include <mpi.h>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include "halo_utils.h"
#include <cmath>
#include <vector>
#include <queue>
#include <algorithm>
#include <cstdio>

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

    if (argc < 3) {
        if (rank==0) printf("Usage: mpirun -n <P> %s <input_image> <output.png> [T_high] [T_low]\n", argv[0]);
        MPI_Finalize(); return 1;
    }

    float Th = (argc > 3) ? atof(argv[3]) : 100.0f;
    float Tl = (argc > 4) ? atof(argv[4]) :  50.0f;

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

    double t0 = MPI_Wtime();

    // Stage 1: Gaussian smoothing (2-row halo for 5x5 kernel)
    std::vector<unsigned char> th, bh;
    exchange_halos(local_data, th, bh, lr, width, 2, rank, size, MPI_COMM_WORLD);
    std::vector<float> smooth(counts[rank], 0.0f);
    for (int y=0; y<lr; ++y)
        for (int x=0; x<width; ++x) {
            float s=0;
            for (int ky=-2; ky<=2; ++ky)
                for (int kx=-2; kx<=2; ++kx)
                    s += get_pixel(th, local_data, bh,
                                   y+ky, std::max(0,std::min(width-1,x+kx)),
                                   lr, width, 2) * G5[ky+2][kx+2];
            smooth[y*width+x] = s / G5S;
        }

    // Stage 2: Gradient + NMS (1-row halo on smoothed data)
    std::vector<unsigned char> smooth_uc(counts[rank]);
    for (int i=0; i<counts[rank]; ++i)
        smooth_uc[i] = (unsigned char)std::min(255.0f, smooth[i]);
    exchange_halos(smooth_uc, th, bh, lr, width, 1, rank, size, MPI_COMM_WORLD);

    std::vector<float> mag(counts[rank], 0.0f), ang(counts[rank], 0.0f);
    for (int y=0; y<lr; ++y)
        for (int x=0; x<width; ++x) {
            float gx=0, gy=0;
            for (int ky=-1; ky<=1; ++ky)
                for (int kx=-1; kx<=1; ++kx) {
                    float p = get_pixel(th, smooth_uc, bh,
                                        y+ky, std::max(0,std::min(width-1,x+kx)),
                                        lr, width, 1);
                    gx += p * Kx[ky+1][kx+1];
                    gy += p * Ky[ky+1][kx+1];
                }
            mag[y*width+x] = std::sqrt(gx*gx + gy*gy);
            float a = std::atan2(gy,gx)*180.0f/(float)M_PI;
            ang[y*width+x] = (a < 0) ? a+180.0f : a;
        }

    std::vector<float> nms_local(counts[rank], 0.0f);
    for (int y=1; y<lr-1; ++y)
        for (int x=1; x<width-1; ++x) {
            float a=ang[y*width+x]; float q=0, r=0;
            if      (a<22.5f||a>=157.5f) { q=mag[y*width+x+1];        r=mag[y*width+x-1]; }
            else if (a<67.5f)            { q=mag[(y+1)*width+x-1];    r=mag[(y-1)*width+x+1]; }
            else if (a<112.5f)           { q=mag[(y+1)*width+x];      r=mag[(y-1)*width+x]; }
            else                         { q=mag[(y-1)*width+x-1];    r=mag[(y+1)*width+x+1]; }
            nms_local[y*width+x] = (mag[y*width+x]>=q && mag[y*width+x]>=r)
                                   ? mag[y*width+x] : 0.0f;
        }

    // Stage 3: Double threshold
    std::vector<unsigned char> edge_local(counts[rank], 0);
    for (int i=0; i<counts[rank]; ++i) {
        if      (nms_local[i] >= Th) edge_local[i] = STRONG;
        else if (nms_local[i] >= Tl) edge_local[i] = WEAK;
    }

    // Stage 4: Distributed iterative hysteresis
    // Each round: run local BFS, exchange boundary rows with neighbours,
    // promote any weak pixels adjacent to incoming strong pixels, repeat until convergence.
    bool changed_global = true;
    while (changed_global) {
        bool changed_local = false;
        std::queue<int> bfs;
        for (int i=0; i<counts[rank]; ++i)
            if (edge_local[i]==STRONG) bfs.push(i);
        while (!bfs.empty()) {
            int idx=bfs.front(); bfs.pop();
            int y=idx/width, x=idx%width;
            for (int dy=-1; dy<=1; ++dy) for (int dx=-1; dx<=1; ++dx) {
                if (!dy && !dx) continue;
                int ny=y+dy, nx=x+dx;
                if (ny<0||ny>=lr||nx<0||nx>=width) continue;
                int ni=ny*width+nx;
                if (edge_local[ni]==WEAK) {
                    edge_local[ni]=STRONG;
                    bfs.push(ni);
                    changed_local=true;
                }
            }
        }
        // Exchange boundary rows with neighbours
        std::vector<unsigned char> top_edge(width,0), bot_edge(width,0);
        std::vector<unsigned char> recv_top(width,0), recv_bot(width,0);
        for (int x=0; x<width; ++x) top_edge[x] = edge_local[x];
        for (int x=0; x<width; ++x) bot_edge[x] = edge_local[(lr-1)*width+x];
        if (rank > 0)
            MPI_Sendrecv(top_edge.data(), width, MPI_UNSIGNED_CHAR, rank-1, 10,
                         recv_top.data(), width, MPI_UNSIGNED_CHAR, rank-1, 11,
                         MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        if (rank < size-1)
            MPI_Sendrecv(bot_edge.data(), width, MPI_UNSIGNED_CHAR, rank+1, 11,
                         recv_bot.data(), width, MPI_UNSIGNED_CHAR, rank+1, 10,
                         MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        for (int x=0; x<width; ++x) {
            if (recv_top[x]==STRONG && edge_local[x]==WEAK)
                { edge_local[x]=STRONG; changed_local=true; }
            if (recv_bot[x]==STRONG && edge_local[(lr-1)*width+x]==WEAK)
                { edge_local[(lr-1)*width+x]=STRONG; changed_local=true; }
        }
        int cl=(int)changed_local, cg=0;
        MPI_Allreduce(&cl, &cg, 1, MPI_INT, MPI_MAX, MPI_COMM_WORLD);
        changed_global = (cg > 0);
    }

    double t1 = MPI_Wtime();

    // Gather final edges
    std::vector<unsigned char> out;
    if (rank==0) out.resize(width*height);
    std::vector<unsigned char> edge_final(counts[rank]);
    for (int i=0; i<counts[rank]; ++i)
        edge_final[i] = (edge_local[i]==STRONG) ? 255 : 0;
    MPI_Gatherv(edge_final.data(), counts[rank], MPI_UNSIGNED_CHAR,
                rank==0 ? out.data() : nullptr,
                counts.data(), offsets.data(), MPI_UNSIGNED_CHAR,
                0, MPI_COMM_WORLD);

    if (rank==0) {
        printf("[Canny Scatter] ranks=%d  total_time=%.5f s\n", size, t1-t0);
        stbi_write_png(argv[2], width, height, 1, out.data(), width);
    }
    MPI_Finalize();
    return 0;
}
