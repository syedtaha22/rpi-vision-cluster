// log_arch2_pipeline.cpp
// Architecture 2 — OpenMP Pipeline: three stages (LoG convolution | zero-crossing prep | detection)
// operating on chunk_rows-row bands concurrently via atomic completion flags.
// Usage: ./log_arch2 <input_image> [chunk_rows] <output.png>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include <cmath>
#include <vector>
#include <atomic>
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
        printf("Usage: %s <input_image> [chunk_rows] <output.png>\n", argv[0]);
        return 1;
    }

    int width, height, channels;
    unsigned char* img = stbi_load(argv[1], &width, &height, &channels, 1);
    if (!img) { fprintf(stderr, "Failed to load image: %s\n", argv[1]); return 1; }

    int chunk_rows = (argc > 3) ? atoi(argv[2]) : 32;
    const char* out_path = (argc > 3) ? argv[3] : argv[2];
    int num_chunks = (height + chunk_rows - 1) / chunk_rows;
    int N = width * height;

    // Stage buffers
    std::vector<float> resp(N, 0.0f);       // LoG response
    std::vector<unsigned char> out(N, 0);   // zero-crossing output

    // Per-chunk completion flags
    std::vector<std::atomic<int>> done_conv(num_chunks);
    for (auto& f : done_conv) f.store(0);

    double t0 = omp_get_wtime();

    #pragma omp parallel sections num_threads(2)
    {
        // Stage 0: LoG convolution (5x5 kernel, embarrassingly parallel per chunk)
        #pragma omp section
        for (int c = 0; c < num_chunks; ++c) {
            int y0 = c * chunk_rows;
            int y1 = std::min(height, y0 + chunk_rows);
            for (int y = y0; y < y1; ++y)
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
            done_conv[c].store(1);
        }

        // Stage 1: Zero-crossing detection (waits for convolution per chunk)
        // Uses 4-neighbour sign-change: edge if resp changes sign with any neighbour
        // Note: chunk boundary pixels need the adjacent chunk's response, so we wait
        // for both current and adjacent chunks before processing boundaries.
        #pragma omp section
        for (int c = 0; c < num_chunks; ++c) {
            // Wait for this chunk and adjacent (needed for border rows)
            while (done_conv[c].load() == 0) { /* spin-wait */ }
            if (c + 1 < num_chunks) {
                // Wait for next chunk too so boundary row has valid neighbours
                while (done_conv[c + 1].load() == 0) { /* spin-wait */ }
            }

            int y0 = std::max(1, c * chunk_rows);
            int y1 = std::min(height - 1, (c + 1) * chunk_rows);
            for (int y = y0; y < y1; ++y)
                for (int x = 1; x < width - 1; ++x) {
                    float cv = resp[y*width + x];
                    if ((cv * resp[y*width + x + 1] < 0) ||
                        (cv * resp[y*width + x - 1] < 0) ||
                        (cv * resp[(y+1)*width + x]  < 0) ||
                        (cv * resp[(y-1)*width + x]  < 0))
                        out[y*width + x] = 255;
                }
        }
    }

    double t1 = omp_get_wtime();
    printf("[LoG Pipeline] chunk_rows=%d  time=%.5f s\n", chunk_rows, t1-t0);

    stbi_write_png(out_path, width, height, 1, out.data(), width);
    stbi_image_free(img);
    return 0;
}
