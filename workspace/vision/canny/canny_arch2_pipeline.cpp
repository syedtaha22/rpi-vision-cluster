// canny_arch2_pipeline.cpp
// Architecture 2 — OpenMP Pipeline: 4 stages (Gaussian | Gradient | NMS | Hysteresis)
// operating on chunk_rows-row bands concurrently via atomic completion flags.
// Note: Stage 3 (hysteresis) must wait for all NMS chunks — it is the serial bottleneck.
// Usage: ./canny_arch2 <input_image> [chunk_rows] [T_high] [T_low] <output.png>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include <cmath>
#include <vector>
#include <queue>
#include <atomic>
#include <memory>
#include <algorithm>
#include <omp.h>
#include <cstdio>

static const int Kx[3][3] = {{-1,0,1},{-2,0,2},{-1,0,1}};
static const int Ky[3][3] = {{-1,-2,-1},{0,0,0},{1,2,1}};
static const float GAUSS5[5][5] = {
    {2,4,5,4,2},{4,9,12,9,4},{5,12,15,12,5},{4,9,12,9,4},{2,4,5,4,2}
};
static const float GAUSS5_SUM = 159.0f;

int main(int argc, char** argv) {
    if (argc < 3) {
        printf("Usage: %s <input_image> [chunk_rows] [T_high] [T_low] <output.png>\n", argv[0]);
        return 1;
    }

    int width, height, channels;
    unsigned char* img = stbi_load(argv[1], &width, &height, &channels, 1);
    if (!img) { fprintf(stderr, "Failed to load image: %s\n", argv[1]); return 1; }

    int chunk_rows = (argc > 3) ? atoi(argv[2]) : 32;
    float Th       = (argc > 4) ? atof(argv[3]) : 100.0f;
    float Tl       = (argc > 5) ? atof(argv[4]) :  50.0f;
    const char* out_path = argv[argc-1];

    int N = width * height;
    int num_chunks = (height + chunk_rows - 1) / chunk_rows;

    std::vector<float>         smooth(N, 0.0f);
    std::vector<float>         mag(N, 0.0f), angle_map(N, 0.0f);
    std::vector<float>         nms_map(N, 0.0f);
    std::vector<unsigned char> edge(N, 0), out(N, 0);

    // Completion flags: done[stage * num_chunks + chunk] = 1 when done.
    // unique_ptr<atomic[]> avoids GCC 10 copy-construction error on ARM64
    // (vector<atomic<int>>(N) triggers copy-ctor path in that toolchain).
    int total_flags = 4 * num_chunks;
    auto done = std::make_unique<std::atomic<int>[]>(total_flags);
    for (int i = 0; i < total_flags; ++i) done[i].store(0);
    auto done_flag = [&](int stage, int chunk) -> std::atomic<int>& {
        return done[stage * num_chunks + chunk];
    };

    double t0 = omp_get_wtime();

    #pragma omp parallel sections num_threads(4)
    {
        // ---- Stage 0: Gaussian smoothing ----
        #pragma omp section
        {
            for (int c = 0; c < num_chunks; ++c) {
                int y0 = c * chunk_rows;
                int y1 = std::min(height, y0 + chunk_rows);
                for (int y = y0; y < y1; ++y)
                    for (int x = 0; x < width; ++x) {
                        float s = 0.0f;
                        for (int ky=-2; ky<=2; ++ky)
                            for (int kx=-2; kx<=2; ++kx)
                                s += img[std::max(0,std::min(height-1,y+ky))*width
                                         + std::max(0,std::min(width-1,x+kx))]
                                     * GAUSS5[ky+2][kx+2];
                        smooth[y*width+x] = s / GAUSS5_SUM;
                    }
                done_flag(0,c).store(1);
            }
        }

        // ---- Stage 1: Gradient + direction ----
        #pragma omp section
        {
            for (int c = 0; c < num_chunks; ++c) {
                while (done_flag(0,c).load() == 0) { /* spin-wait for Gaussian */ }
                int y0 = c * chunk_rows;
                int y1 = std::min(height, y0 + chunk_rows);
                for (int y = y0; y < y1; ++y)
                    for (int x = 0; x < width; ++x) {
                        float gx=0, gy=0;
                        for (int ky=-1; ky<=1; ++ky)
                            for (int kx=-1; kx<=1; ++kx) {
                                float p = smooth[std::max(0,std::min(height-1,y+ky))*width
                                                 + std::max(0,std::min(width-1,x+kx))];
                                gx += p * Kx[ky+1][kx+1];
                                gy += p * Ky[ky+1][kx+1];
                            }
                        mag[y*width+x]       = std::sqrt(gx*gx + gy*gy);
                        float a = std::atan2(gy,gx)*180.0f/(float)M_PI;
                        angle_map[y*width+x] = (a < 0) ? a+180.0f : a;
                    }
                done_flag(1,c).store(1);
            }
        }

        // ---- Stage 2: Non-maximum suppression ----
        #pragma omp section
        {
            for (int c = 0; c < num_chunks; ++c) {
                while (done_flag(1,c).load() == 0) { /* spin-wait for gradient */ }
                int y0 = std::max(1, c * chunk_rows);
                int y1 = std::min(height-1, (c+1) * chunk_rows);
                for (int y = y0; y < y1; ++y)
                    for (int x = 1; x < width-1; ++x) {
                        float a = angle_map[y*width+x];
                        float q=0, r=0;
                        if      (a < 22.5f  || a >= 157.5f) { q=mag[y*width+x+1];     r=mag[y*width+x-1]; }
                        else if (a < 67.5f)                  { q=mag[(y+1)*width+x-1]; r=mag[(y-1)*width+x+1]; }
                        else if (a < 112.5f)                 { q=mag[(y+1)*width+x];   r=mag[(y-1)*width+x]; }
                        else                                 { q=mag[(y-1)*width+x-1]; r=mag[(y+1)*width+x+1]; }
                        nms_map[y*width+x] = (mag[y*width+x]>=q && mag[y*width+x]>=r)
                                             ? mag[y*width+x] : 0.0f;
                    }
                done_flag(2,c).store(1);
            }
        }

        // ---- Stage 3: Double threshold + hysteresis (serial — must see full NMS map) ----
        #pragma omp section
        {
            // Wait for all NMS chunks before global hysteresis BFS
            for (int c = 0; c < num_chunks; ++c)
                while (done_flag(2,c).load() == 0) { /* spin-wait */ }

            static const unsigned char STRONG=255, WEAK=50;
            for (int i=0; i<N; ++i) {
                if      (nms_map[i] >= Th) edge[i] = STRONG;
                else if (nms_map[i] >= Tl) edge[i] = WEAK;
            }
            std::queue<int> bfs;
            for (int i=0; i<N; ++i) if (edge[i]==STRONG) bfs.push(i);
            while (!bfs.empty()) {
                int idx=bfs.front(); bfs.pop();
                int y=idx/width, x=idx%width;
                for (int dy=-1; dy<=1; ++dy) for (int dx=-1; dx<=1; ++dx) {
                    if (!dy && !dx) continue;
                    int ny=y+dy, nx=x+dx;
                    if (ny<0||ny>=height||nx<0||nx>=width) continue;
                    int ni=ny*width+nx;
                    if (edge[ni]==WEAK) { edge[ni]=STRONG; bfs.push(ni); }
                }
            }
            for (int i=0; i<N; ++i) out[i]=(edge[i]==STRONG)?255:0;
        }
    }

    double t1 = omp_get_wtime();
    printf("[Canny Pipeline] chunk_rows=%d  time=%.5f s\n", chunk_rows, t1-t0);

    stbi_write_png(out_path, width, height, 1, out.data(), width);
    stbi_image_free(img);
    return 0;
}