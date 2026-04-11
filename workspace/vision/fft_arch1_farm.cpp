#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include "fft_utils.h"
#include <iostream>
#include <vector>
#include <sys/time.h>
#include <omp.h>

using namespace std;

double get_time() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        cout << "Usage: " << argv[0] << " <image_path> [num_threads]\n";
        return 1;
    }
    int num_threads = 4;
    if (argc >= 3) num_threads = atoi(argv[2]);
    omp_set_num_threads(num_threads);

    string img_path = argv[1];
    int width, height, channels;
    unsigned char* img_data = stbi_load(img_path.c_str(), &width, &height, &channels, 0);
    if (!img_data) { cerr << "Failed to load image\n"; return 1; }

    int new_w = next_power_of_2(width);
    int new_h = next_power_of_2(height);
    vector<Complex> data(new_w * new_h, Complex(0,0));

    for (int y = 0; y < height; ++y)
        for (int x = 0; x < width; ++x) {
            double sign = ((x + y) % 2 == 0) ? 1.0 : -1.0;
            unsigned char pixel = img_data[(y * width + x) * channels];
            data[y * new_w + x] = Complex(pixel * sign, 0);
        }
    stbi_image_free(img_data);

    double t_start = get_time();
    
    // 1. Forward Row Pass — only over actual data rows (height), not zero-padded rows
    #pragma omp parallel for schedule(dynamic)
    for (int y = 0; y < new_h; ++y) {   // keep new_h so FFT sees full padded size
        vector<Complex> row(new_w);
        for (int x = 0; x < new_w; ++x) row[x] = data[y * new_w + x];
        fft1d(row);
        for (int x = 0; x < new_w; ++x) data[y * new_w + x] = row[x];
    }

    // 2. Forward Col Pass
    #pragma omp parallel for schedule(dynamic)
    for (int x = 0; x < new_w; ++x) {
        vector<Complex> col(new_h);
        for (int y = 0; y < new_h; ++y) col[y] = data[y * new_w + x];
        fft1d(col);
        for (int y = 0; y < new_h; ++y) data[y * new_w + x] = col[y];
    }

    vector<float> magnitude(new_w * new_h);
    float max_mag = 0.0f;

    for (int y = 0; y < new_h; ++y) {
        for (int x = 0; x < new_w; ++x) {
            Complex c = data[y * new_w + x];
            float mag = sqrt(c.real() * c.real() + c.imag() * c.imag());
            magnitude[y * new_w + x] = log(1.0f + mag);
            if (magnitude[y * new_w + x] > max_mag)
                max_mag = magnitude[y * new_w + x];
        }
    }

    // 2. Normalize to 0-255 and save
    vector<unsigned char> fft_vis(new_w * new_h);
    for (int y = 0; y < new_h; ++y)
        for (int x = 0; x < new_w; ++x)
            fft_vis[y * new_w + x] = (unsigned char)(255.0f * magnitude[y * new_w + x] / max_mag);

    stbi_write_png("fft_magnitude.png", new_w, new_h, 1, fft_vis.data(), new_w);

    // 3. GHPF
    int cx = new_w / 2, cy = new_h / 2;
    double d0 = 10.0;
    #pragma omp parallel for collapse(2)
    for (int y = 0; y < new_h; ++y)
        for (int x = 0; x < new_w; ++x) {
            double d2 = (double)(x-cx)*(x-cx) + (double)(y-cy)*(y-cy);
            double h = 1.0 - exp(-d2 / (2.0 * d0 * d0));
            data[y * new_w + x] *= h;
        }

    // 4. Inverse Col Pass
    #pragma omp parallel for schedule(dynamic)
    for (int x = 0; x < new_w; ++x) {
        vector<Complex> col(new_h);
        for (int y = 0; y < new_h; ++y) col[y] = data[y * new_w + x];
        ifft1d(col);
        for (int y = 0; y < new_h; ++y) data[y * new_w + x] = col[y];
    }

    // 5. Inverse Row Pass
    #pragma omp parallel for schedule(dynamic)
    for (int y = 0; y < new_h; ++y) {
        vector<Complex> row(new_w);
        for (int x = 0; x < new_w; ++x) row[x] = data[y * new_w + x];
        ifft1d(row);
        for (int x = 0; x < new_w; ++x) data[y * new_w + x] = row[x];
    }

    // Find max edge magnitude
    float max_edge = 0.0f;
    for (int y = 0; y < new_h; ++y)
        for (int x = 0; x < new_w; ++x) {
            Complex c = data[y * new_w + x];
            float mag = sqrt(c.real() * c.real() + c.imag() * c.imag());
            if (mag > max_edge) max_edge = mag;
        }

    // Normalize and save
    vector<unsigned char> edge_output(new_w * new_h);
    for (int y = 0; y < new_h; ++y)
        for (int x = 0; x < new_w; ++x) {
            Complex c = data[y * new_w + x];
            float mag = sqrt(c.real() * c.real() + c.imag() * c.imag());
            edge_output[y * new_w + x] = (unsigned char)(255.0f * mag / max_edge);
        }

    stbi_write_png("fft_arch1_out.png", new_w, new_h, 1, edge_output.data(), new_w);
    printf("Saved edge output to fft_arch1_out.png\n");

    double t_end = get_time();
    cout << "FFT Arch1 (Farm) Time: " << (t_end - t_start) << " s using " << num_threads << " threads.\n";

    // Save Result
    // vector<unsigned char> out(width * height);
    // for (int y = 0; y < height; ++y)
    //     for (int x = 0; x < width; ++x) {
    //         double sign = ((x + y) % 2 == 0) ? 1.0 : -1.0;
    //         double val = data[y * new_w + x].real() * sign;
    //         out[y * width + x] = (unsigned char)max(0.0, min(255.0, val + 128.0));
    //     }

    ///stbi_write_png("fft_arch1_out.png", width, height, 1, out.data(), width);
    return 0;
}
