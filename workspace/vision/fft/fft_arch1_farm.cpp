// fft_arch1_farm.cpp
// Architecture 1 — OpenMP Farm: rows and columns distributed across threads.
// Usage: ./fft_arch1 <input_image> [num_threads] <output.png>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include "fft_utils.h"
#include <cmath>
#include <vector>
#include <omp.h>
#include <cstdio>
#include <iostream>

using namespace std;

int main(int argc, char** argv) {
    if (argc < 3) {
        printf("Usage: %s <input_image> [num_threads] <output.png>\n", argv[0]);
        return 1;
    }

    int width, height, channels;
    unsigned char* img_data = stbi_load(argv[1], &width, &height, &channels, 0);
    if (!img_data) { fprintf(stderr, "Failed to load image: %s\n", argv[1]); return 1; }

    int T = (argc > 3) ? atoi(argv[2]) : omp_get_max_threads();
    const char* out_path = (argc > 3) ? argv[3] : argv[2];

    int new_w = next_power_of_2(width);
    int new_h = next_power_of_2(height);

    vector<Complex> data(new_w * new_h, Complex(0, 0));
    for (int y = 0; y < height; ++y)
        for (int x = 0; x < width; ++x) {
            double sign = ((x + y) % 2 == 0) ? 1.0 : -1.0;
            data[y * new_w + x] = Complex(img_data[(y * width + x) * channels] * sign, 0);
        }
    stbi_image_free(img_data);

    double t0 = omp_get_wtime();

    // Forward row FFT
    #pragma omp parallel for num_threads(T) schedule(dynamic)
    for (int y = 0; y < new_h; ++y) {
        vector<Complex> row(new_w);
        for (int x = 0; x < new_w; ++x) row[x] = data[y * new_w + x];
        fft1d(row);
        for (int x = 0; x < new_w; ++x) data[y * new_w + x] = row[x];
    }

    // Forward col FFT
    #pragma omp parallel for num_threads(T) schedule(dynamic)
    for (int x = 0; x < new_w; ++x) {
        vector<Complex> col(new_h);
        for (int y = 0; y < new_h; ++y) col[y] = data[y * new_w + x];
        fft1d(col);
        for (int y = 0; y < new_h; ++y) data[y * new_w + x] = col[y];
    }

    // Apply GHPF
    int cx = new_w / 2, cy = new_h / 2;
    double d0 = 10.0;
    #pragma omp parallel for num_threads(T) schedule(static) collapse(2)
    for (int y = 0; y < new_h; ++y)
        for (int x = 0; x < new_w; ++x) {
            double d2 = (double)(x - cx) * (x - cx) + (double)(y - cy) * (y - cy);
            double h = 1.0 - exp(-d2 / (2.0 * d0 * d0));
            data[y * new_w + x] *= h;
        }

    // Inverse col IFFT
    #pragma omp parallel for num_threads(T) schedule(dynamic)
    for (int x = 0; x < new_w; ++x) {
        vector<Complex> col(new_h);
        for (int y = 0; y < new_h; ++y) col[y] = data[y * new_w + x];
        ifft1d(col);
        for (int y = 0; y < new_h; ++y) data[y * new_w + x] = col[y];
    }

    // Inverse row IFFT
    #pragma omp parallel for num_threads(T) schedule(dynamic)
    for (int y = 0; y < new_h; ++y) {
        vector<Complex> row(new_w);
        for (int x = 0; x < new_w; ++x) row[x] = data[y * new_w + x];
        ifft1d(row);
        for (int x = 0; x < new_w; ++x) data[y * new_w + x] = row[x];
    }

    double t1 = omp_get_wtime();
    printf("FFT Arch1 (Farm) Time: %.9f s using %d threads\n", t1 - t0, T);

    float max_edge = 0.0f;
    for (int i = 0; i < new_w * new_h; ++i) {
        float mag = sqrt(data[i].real() * data[i].real() + data[i].imag() * data[i].imag());
        if (mag > max_edge) max_edge = mag;
    }

    vector<unsigned char> out(new_w * new_h);
    for (int i = 0; i < new_w * new_h; ++i) {
        float mag = sqrt(data[i].real() * data[i].real() + data[i].imag() * data[i].imag());
        out[i] = (unsigned char)(255.0f * mag / (max_edge + 1e-6f));
    }
    stbi_write_png(out_path, new_w, new_h, 1, out.data(), new_w);
    return 0;
}
