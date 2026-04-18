// sobel_arch1_farm.cpp
// Architecture 1 — OpenMP Farm: rows distributed across threads, embarrassingly parallel.
// Usage: ./sobel_arch1 <input_image> [num_threads] <output.png>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include <cmath>
#include <vector>
#include <algorithm>
#include <omp.h>
#include <cstdio>

static const int Kx[3][3] = {{-1,0,1},{-2,0,2},{-1,0,1}};
static const int Ky[3][3] = {{-1,-2,-1},{0,0,0},{1,2,1}};

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

    std::vector<float> mag(width * height, 0.0f);

    double t0 = omp_get_wtime();

    #pragma omp parallel for schedule(dynamic) num_threads(T)
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            float gx = 0.0f, gy = 0.0f;
            for (int ky = -1; ky <= 1; ++ky) {
                int ny = std::max(0, std::min(height-1, y+ky));
                for (int kx = -1; kx <= 1; ++kx) {
                    int nx = std::max(0, std::min(width-1, x+kx));
                    unsigned char p = img[ny*width + nx];
                    gx += p * Kx[ky+1][kx+1];
                    gy += p * Ky[ky+1][kx+1];
                }
            }
            mag[y*width + x] = std::sqrt(gx*gx + gy*gy);
        }
    }

    double t1 = omp_get_wtime();
    printf("[Sobel Farm] threads=%d  time=%.5f s\n", T, t1-t0);

    float mx = *std::max_element(mag.begin(), mag.end());
    std::vector<unsigned char> out(width*height);
    for (int i = 0; i < width*height; ++i)
        out[i] = (unsigned char)(255.0f * mag[i] / (mx + 1e-6f));

    stbi_write_png(out_path, width, height, 1, out.data(), width);
    stbi_image_free(img);
    return 0;
}
