// log_arch1_farm.cpp
// Architecture 1 — OpenMP Farm: 5x5 LoG kernel, zero-crossing detection.
// Usage: ./log_arch1 <input_image> [num_threads] <output.png>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include <cmath>
#include <vector>
#include <algorithm>
#include <omp.h>
#include <cstdio>

static const int K_LOG[5][5] = {
    { 0,  0, -1,  0,  0},
    { 0, -1, -2, -1,  0},
    {-1, -2, 16, -2, -1},
    { 0, -1, -2, -1,  0},
    { 0,  0, -1,  0,  0}
};

int main(int argc, char** argv) {
    if (argc < 3) {
        printf("Usage: %s <input_image> [num_threads] <output.png>\n", argv[0]);
        return 1;
    }

    int width, height, channels;
    unsigned char* img = stbi_load(argv[1], &width, &height, &channels, 1);
    if (!img) { fprintf(stderr, "Failed to load image: %s\n", argv[1]); return 1; }

    int T = (argc > 3) ? atoi(argv[2]) : omp_get_max_threads();
    const char* out_path = (argc > 3) ? argv[3] : argv[2];

    std::vector<float> resp(width * height, 0.0f);

    double t0 = omp_get_wtime();

    // LoG convolution (embarrassingly parallel)
    #pragma omp parallel for schedule(dynamic) num_threads(T)
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            float r = 0.0f;
            for (int ky = -2; ky <= 2; ++ky) {
                int ny = std::max(0, std::min(height-1, y+ky));
                for (int kx = -2; kx <= 2; ++kx) {
                    int nx = std::max(0, std::min(width-1, x+kx));
                    r += img[ny*width + nx] * K_LOG[ky+2][kx+2];
                }
            }
            resp[y*width + x] = r;
        }
    }

    // Zero-crossing detection: edge if sign change in 4-neighbourhood
    std::vector<unsigned char> out(width*height, 0);
    #pragma omp parallel for schedule(dynamic) num_threads(T)
    for (int y = 1; y < height-1; ++y) {
        for (int x = 1; x < width-1; ++x) {
            float c = resp[y*width+x];
            if ((c * resp[y*width+x+1]   < 0) ||
                (c * resp[y*width+x-1]   < 0) ||
                (c * resp[(y+1)*width+x] < 0) ||
                (c * resp[(y-1)*width+x] < 0))
                out[y*width+x] = 255;
        }
    }

    double t1 = omp_get_wtime();
    printf("[LoG Farm] threads=%d  time=%.5f s\n", T, t1-t0);

    stbi_write_png(out_path, width, height, 1, out.data(), width);
    stbi_image_free(img);
    return 0;
}
