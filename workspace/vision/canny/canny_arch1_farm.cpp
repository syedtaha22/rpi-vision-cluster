// canny_arch1_farm.cpp
// Architecture 1 — OpenMP Farm: Stages 1-3 parallelised over rows; Stage 4 hysteresis serial.
// Usage: ./canny_arch1 <input_image> [num_threads] [T_high] [T_low] <output.png>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include <cmath>
#include <vector>
#include <queue>
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
        printf("Usage: %s <input_image> [num_threads] [T_high] [T_low] <output.png>\n", argv[0]);
        return 1;
    }

    int width, height, channels;
    unsigned char* img = stbi_load(argv[1], &width, &height, &channels, 1);
    if (!img) { fprintf(stderr, "Failed to load image: %s\n", argv[1]); return 1; }

    // Flexible arg parsing: last positional is always output path
    int T    = (argc > 3) ? atoi(argv[2]) : omp_get_max_threads();
    float Th = (argc > 4) ? atof(argv[3]) : 100.0f;
    float Tl = (argc > 5) ? atof(argv[4]) :  50.0f;
    const char* out_path = argv[argc-1];

    int N = width * height;
    std::vector<float> smooth(N), mag(N), angle(N), nms(N);
    std::vector<unsigned char> out(N, 0);

    double t0 = omp_get_wtime();

    // Stage 1: Gaussian smoothing (parallel)
    #pragma omp parallel for schedule(dynamic) num_threads(T)
    for (int y = 0; y < height; ++y)
        for (int x = 0; x < width; ++x) {
            float s = 0.0f;
            for (int ky=-2; ky<=2; ++ky)
                for (int kx=-2; kx<=2; ++kx)
                    s += img[std::max(0,std::min(height-1,y+ky))*width
                             + std::max(0,std::min(width-1,x+kx))]
                         * GAUSS5[ky+2][kx+2];
            smooth[y*width+x] = s / GAUSS5_SUM;
        }

    // Stage 2: Gradient magnitude + direction (parallel)
    #pragma omp parallel for schedule(dynamic) num_threads(T)
    for (int y = 0; y < height; ++y)
        for (int x = 0; x < width; ++x) {
            float gx=0, gy=0;
            for (int ky=-1; ky<=1; ++ky)
                for (int kx=-1; kx<=1; ++kx) {
                    float p = smooth[std::max(0,std::min(height-1,y+ky))*width
                                     + std::max(0,std::min(width-1,x+kx))];
                    gx += p * Kx[ky+1][kx+1];
                    gy += p * Ky[ky+1][kx+1];
                }
            mag[y*width+x]   = std::sqrt(gx*gx + gy*gy);
            angle[y*width+x] = std::atan2(gy, gx) * 180.0f / M_PI;
            if (angle[y*width+x] < 0) angle[y*width+x] += 180.0f;
        }

    // Stage 3: Non-maximum suppression (parallel — each pixel checks 2 fixed neighbours)
    #pragma omp parallel for schedule(dynamic) num_threads(T)
    for (int y = 1; y < height-1; ++y)
        for (int x = 1; x < width-1; ++x) {
            float a = angle[y*width+x];
            float q=0, r=0;
            if      (a < 22.5f  || a >= 157.5f) { q=mag[y*width+x+1];        r=mag[y*width+x-1]; }
            else if (a < 67.5f)                  { q=mag[(y+1)*width+x-1];    r=mag[(y-1)*width+x+1]; }
            else if (a < 112.5f)                 { q=mag[(y+1)*width+x];      r=mag[(y-1)*width+x]; }
            else                                 { q=mag[(y-1)*width+x-1];    r=mag[(y+1)*width+x+1]; }
            nms[y*width+x] = (mag[y*width+x] >= q && mag[y*width+x] >= r)
                              ? mag[y*width+x] : 0.0f;
        }

    // Stage 4: Double threshold + hysteresis (sequential — graph reachability)
    // Note: this is the serial bottleneck for Architecture 1. See PRAM analysis.
    static const unsigned char STRONG=255, WEAK=50;
    std::vector<unsigned char> edge(N, 0);
    for (int i=0; i<N; ++i) {
        if      (nms[i] >= Th) edge[i] = STRONG;
        else if (nms[i] >= Tl) edge[i] = WEAK;
    }
    std::queue<int> q;
    for (int i=0; i<N; ++i) if (edge[i]==STRONG) q.push(i);
    while (!q.empty()) {
        int idx = q.front(); q.pop();
        int y = idx/width, x = idx%width;
        for (int dy=-1; dy<=1; ++dy) for (int dx=-1; dx<=1; ++dx) {
            if (dy==0 && dx==0) continue;
            int ny=y+dy, nx=x+dx;
            if (ny<0||ny>=height||nx<0||nx>=width) continue;
            int ni = ny*width+nx;
            if (edge[ni]==WEAK) { edge[ni]=STRONG; q.push(ni); }
        }
    }
    for (int i=0; i<N; ++i) out[i] = (edge[i]==STRONG) ? 255 : 0;

    double t1 = omp_get_wtime();
    printf("[Canny Farm] threads=%d  time=%.5f s\n", T, t1-t0);

    stbi_write_png(out_path, width, height, 1, out.data(), width);
    stbi_image_free(img);
    return 0;
}
