// sobel_arch2_pipeline.cpp
// Architecture 2 — OpenMP Pipeline: three stages (Kx | Ky | Magnitude) operating
// on chunk_rows-row bands concurrently via atomic completion flags.
// Usage: ./sobel_arch2 <input_image> [chunk_rows] <output.png>
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

static const int Kx[3][3] = {{-1,0,1},{-2,0,2},{-1,0,1}};
static const int Ky[3][3] = {{-1,-2,-1},{0,0,0},{1,2,1}};

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

    std::vector<float> gx_buf(N, 0.0f), gy_buf(N, 0.0f), mag_buf(N, 0.0f);
    std::vector<unsigned char> out(N);

    // Per-chunk completion flags for each pipeline stage
    std::vector<std::atomic<int>> done_kx(num_chunks), done_ky(num_chunks);
    for (auto& f : done_kx) f.store(0);
    for (auto& f : done_ky) f.store(0);

    double t0 = omp_get_wtime();

    #pragma omp parallel sections num_threads(3)
    {
        // Stage 0: Kx convolution
        #pragma omp section
        for (int c = 0; c < num_chunks; ++c) {
            int y0=c*chunk_rows, y1=std::min(height, y0+chunk_rows);
            for (int y=y0; y<y1; ++y)
                for (int x=0; x<width; ++x) {
                    float v=0;
                    for (int ky=-1; ky<=1; ++ky)
                        for (int kx=-1; kx<=1; ++kx)
                            v += img[std::max(0,std::min(height-1,y+ky))*width
                                     + std::max(0,std::min(width-1,x+kx))] * Kx[ky+1][kx+1];
                    gx_buf[y*width+x] = v;
                }
            done_kx[c].store(1);
        }

        // Stage 1: Ky convolution (runs concurrently with Kx, each chunk independent)
        #pragma omp section
        for (int c = 0; c < num_chunks; ++c) {
            int y0=c*chunk_rows, y1=std::min(height, y0+chunk_rows);
            for (int y=y0; y<y1; ++y)
                for (int x=0; x<width; ++x) {
                    float v=0;
                    for (int ky=-1; ky<=1; ++ky)
                        for (int kx=-1; kx<=1; ++kx)
                            v += img[std::max(0,std::min(height-1,y+ky))*width
                                     + std::max(0,std::min(width-1,x+kx))] * Ky[ky+1][kx+1];
                    gy_buf[y*width+x] = v;
                }
            done_ky[c].store(1);
        }

        // Stage 2: Magnitude (waits for both Kx and Ky per chunk)
        #pragma omp section
        {
            float mx = 0.0f;
            for (int c = 0; c < num_chunks; ++c) {
                while (!done_kx[c].load() || !done_ky[c].load()) { /* spin-wait */ }
                int y0=c*chunk_rows, y1=std::min(height, y0+chunk_rows);
                for (int y=y0; y<y1; ++y)
                    for (int x=0; x<width; ++x) {
                        float m = std::sqrt(gx_buf[y*width+x]*gx_buf[y*width+x]
                                          + gy_buf[y*width+x]*gy_buf[y*width+x]);
                        mag_buf[y*width+x] = m;
                        if (m > mx) mx = m;
                    }
            }
            for (int i=0; i<N; ++i)
                out[i] = (unsigned char)(255.0f * mag_buf[i] / (mx + 1e-6f));
        }
    }

    double t1 = omp_get_wtime();
    printf("[Sobel Pipeline] chunk_rows=%d  time=%.5f s\n", chunk_rows, t1-t0);

    stbi_write_png(out_path, width, height, 1, out.data(), width);
    stbi_image_free(img);
    return 0;
}
