#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include <iostream>
#include <vector>
#include <cmath>
#include <complex>
#include <algorithm>
#include <string>
#include <sys/time.h>

using namespace std;

typedef complex<double> Complex;

double get_time() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

// Naive Recursive FFT
void fft(vector<Complex>& x) {
    int n = x.size();
    if (n <= 1) return;

    vector<Complex> even(n / 2), odd(n / 2);
    for (int i = 0; i < n / 2; i++) {
        even[i] = x[i * 2];
        odd[i] = x[i * 2 + 1];
    }

    fft(even);
    fft(odd);

    for (int k = 0; k < n / 2; k++) {
        Complex t = polar(1.0, -2 * M_PI * k / n) * odd[k];
        x[k] = even[k] + t;
        x[k + n / 2] = even[k] - t;
    }
}

// Naive Recursive IFFT
void ifft(vector<Complex>& x) {
    int n = x.size();
    for (auto& val : x) val = conj(val);
    fft(x);
    for (auto& val : x) {
        val = conj(val);
        val /= n;
    }
}

int next_power_of_2(int n) {
    int p = 1;
    while (p < n) p *= 2;
    return p;
}

// Convert RGB to Grayscale
vector<unsigned char> to_gray(const unsigned char* img, int width, int height, int channels) {
    vector<unsigned char> gray(width * height);
    for (int i = 0; i < width * height; ++i) {
        if (channels >= 3) {
            gray[i] = (unsigned char)(0.299 * img[i * channels] + 0.587 * img[i * channels + 1] + 0.114 * img[i * channels + 2]);
        } else {
            gray[i] = img[i * channels];
        }
    }
    return gray;
}

// 2D Convolution with clamped boundary conditions
vector<double> convolve(const vector<unsigned char>& img, int width, int height, const vector<vector<double>>& kernel) {
    int k_size = kernel.size();
    int k_half = k_size / 2;
    vector<double> out(width * height, 0.0);

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            double sum = 0.0;
            for (int ky = -k_half; ky <= k_half; ++ky) {
                for (int kx = -k_half; kx <= k_half; ++kx) {
                    int ny = max(0, min(height - 1, y + ky));
                    int nx = max(0, min(width - 1, x + kx));
                    sum += img[ny * width + nx] * kernel[ky + k_half][kx + k_half];
                }
            }
            out[y * width + x] = sum;
        }
    }
    return out;
}

// Helper: Normalize double vector to 8-bit image
vector<unsigned char> normalize_to_8bit(const vector<double>& img, int width, int height) {
    vector<unsigned char> out(width * height);
    double min_val = img[0], max_val = img[0];
    for (double v : img) {
        if (v < min_val) min_val = v;
        if (v > max_val) max_val = v;
    }
    double range = max_val - min_val;
    if (range == 0) range = 1.0;

    for (int i = 0; i < width * height; ++i) {
        double val = (img[i] - min_val) / range * 255.0;
        out[i] = (unsigned char)max(0.0, min(255.0, val));
    }
    return out;
}

// Sobel Filter
vector<unsigned char> sobel(const vector<unsigned char>& img, int width, int height) {
    vector<vector<double>> Kx = {{-1, 0, 1}, {-2, 0, 2}, {-1, 0, 1}};
    vector<vector<double>> Ky = {{-1, -2, -1}, {0, 0, 0}, {1, 2, 1}};
    
    vector<double> gx = convolve(img, width, height, Kx);
    vector<double> gy = convolve(img, width, height, Ky);
    
    vector<double> mag(width * height);
    for(int i = 0; i < width * height; ++i) {
        mag[i] = sqrt(gx[i]*gx[i] + gy[i]*gy[i]);
    }
    return normalize_to_8bit(mag, width, height);
}

// Laplace of Gaussian
vector<unsigned char> log_filter(const vector<unsigned char>& img, int width, int height) {
    // 5x5 LoG kernel, approx sigma = 1.0
    vector<vector<double>> kernel = {
        {0, 0, -1, 0, 0},
        {0, -1, -2, -1, 0},
        {-1, -2, 16, -2, -1},
        {0, -1, -2, -1, 0},
        {0, 0, -1, 0, 0}
    };
    vector<double> result = convolve(img, width, height, kernel);
    return normalize_to_8bit(result, width, height);
}

// Simplified Canny
vector<unsigned char> canny(const vector<unsigned char>& img, int width, int height) {
    // 1. Gaussian Blur (3x3)
    vector<vector<double>> gauss = {
        {1.0/16, 2.0/16, 1.0/16},
        {2.0/16, 4.0/16, 2.0/16},
        {1.0/16, 2.0/16, 1.0/16}
    };
    vector<double> blurred_d = convolve(img, width, height, gauss);
    vector<unsigned char> blurred = normalize_to_8bit(blurred_d, width, height);
    
    // 2. Sobel Gradients
    vector<vector<double>> Kx = {{-1, 0, 1}, {-2, 0, 2}, {-1, 0, 1}};
    vector<vector<double>> Ky = {{-1, -2, -1}, {0, 0, 0}, {1, 2, 1}};
    vector<double> gx = convolve(blurred, width, height, Kx);
    vector<double> gy = convolve(blurred, width, height, Ky);
    
    vector<double> mag(width * height);
    vector<double> angle(width * height);
    for(int i = 0; i < width * height; ++i) {
        mag[i] = sqrt(gx[i]*gx[i] + gy[i]*gy[i]);
        angle[i] = atan2(gy[i], gx[i]) * 180.0 / M_PI;
        if(angle[i] < 0) angle[i] += 180.0;
    }
    
    // 3. Non-Maximum Suppression
    vector<double> nms(width * height, 0.0);
    for (int y = 1; y < height - 1; ++y) {
        for (int x = 1; x < width - 1; ++x) {
            int idx = y * width + x;
            double q = 255.0, r = 255.0;
            double ang = angle[idx];
            
            if ((ang >= 0 && ang < 22.5) || (ang >= 157.5 && ang <= 180)) {
                q = mag[y * width + (x + 1)];
                r = mag[y * width + (x - 1)];
            } else if (ang >= 22.5 && ang < 67.5) {
                q = mag[(y + 1) * width + (x - 1)];
                r = mag[(y - 1) * width + (x + 1)];
            } else if (ang >= 67.5 && ang < 112.5) {
                q = mag[(y + 1) * width + x];
                r = mag[(y - 1) * width + x];
            } else if (ang >= 112.5 && ang < 157.5) {
                q = mag[(y - 1) * width + (x - 1)];
                r = mag[(y + 1) * width + (x + 1)];
            }
            
            if (mag[idx] >= q && mag[idx] >= r) {
                nms[idx] = mag[idx];
            } else {
                nms[idx] = 0.0;
            }
        }
    }
    
    // 4. Double Threshold (Simple)
    double highThreshold = 100.0;
    double lowThreshold = 50.0;
    vector<unsigned char> out(width * height, 0);
    for (int i = 0; i < width * height; ++i) {
        if (nms[i] >= highThreshold) {
            out[i] = 255;
        } else if (nms[i] >= lowThreshold) {
            out[i] = 50; // Weak edge
        }
    }
    
    return out;
}

// FFT High Pass Filter for Edge Detection
vector<unsigned char> fft_edge_detection(const vector<unsigned char>& img, int width, int height) {
    int nw = next_power_of_2(width);
    int nh = next_power_of_2(height);
    vector<Complex> data(nw * nh, Complex(0, 0));

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            // Pre-multiply by (-1)^(x+y) to shift FFT center to middle
            double sign = ((x + y) % 2 == 0) ? 1.0 : -1.0;
            data[y * nw + x] = Complex(img[y * width + x] * sign, 0);
        }
    }

    // 2D FFT
    for (int y = 0; y < nh; y++) {
        vector<Complex> row(nw);
        for (int x = 0; x < nw; x++) row[x] = data[y * nw + x];
        fft(row);
        for (int x = 0; x < nw; x++) data[y * nw + x] = row[x];
    }
    for (int x = 0; x < nw; x++) {
        vector<Complex> col(nh);
        for (int y = 0; y < nh; y++) col[y] = data[y * nw + x];
        fft(col);
        for (int y = 0; y < nh; y++) data[y * nw + x] = col[y];
    }

    // High Pass Filter: Zero out low frequencies in the center
    int cx = nw / 2, cy = nh / 2;
    int r = 10; // cutoff radius
    for (int y = 0; y < nh; y++) {
        for (int x = 0; x < nw; x++) {
            if (pow(x - cx, 2) + pow(y - cy, 2) < pow(r, 2)) {
                data[y * nw + x] = 0;
            }
        }
    }

    // 2D IFFT
    for (int x = 0; x < nw; x++) {
        vector<Complex> col(nh);
        for (int y = 0; y < nh; y++) col[y] = data[y * nw + x];
        ifft(col);
        for (int y = 0; y < nh; y++) data[y * nw + x] = col[y];
    }
    for (int y = 0; y < nh; y++) {
        vector<Complex> row(nw);
        for (int x = 0; x < nw; x++) row[x] = data[y * nw + x];
        ifft(row);
        for (int x = 0; x < nw; x++) data[y * nw + x] = row[x];
    }

    vector<double> mag(width * height);
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            double sign = ((x + y) % 2 == 0) ? 1.0 : -1.0;
            mag[y * width + x] = data[y * nw + x].real() * sign;
        }
    }

    return normalize_to_8bit(mag, width, height);
}

int main(int argc, char** argv) {
    if (argc < 2) {
        cout << "Usage: " << argv[0] << " <image_path>\n";
        return 1;
    }
    
    string img_path = argv[1];
    int width, height, channels;
    unsigned char* img_data = stbi_load(img_path.c_str(), &width, &height, &channels, 0);
    if (!img_data) {
        cerr << "Failed to load image: " << img_path << "\n";
        return 1;
    }
    
    cout << "Loaded image: " << width << "x" << height << " (" << channels << " channels)\n";
    vector<unsigned char> gray = to_gray(img_data, width, height, channels);
    stbi_write_png("original_gray.png", width, height, 1, gray.data(), width);
    stbi_image_free(img_data);
    
    // Sobel
    double t_start = get_time();
    vector<unsigned char> out_sobel = sobel(gray, width, height);
    double t_sobel = get_time() - t_start;
    stbi_write_png("sobel_out.png", width, height, 1, out_sobel.data(), width);
    cout << "Sobel time: " << t_sobel << " s\n";
    
    // LoG
    t_start = get_time();
    vector<unsigned char> out_log = log_filter(gray, width, height);
    double t_log = get_time() - t_start;
    stbi_write_png("log_out.png", width, height, 1, out_log.data(), width);
    cout << "LoG time: " << t_log << " s\n";
    
    // Canny
    t_start = get_time();
    vector<unsigned char> out_canny = canny(gray, width, height);
    double t_canny = get_time() - t_start;
    stbi_write_png("canny_out.png", width, height, 1, out_canny.data(), width);
    cout << "Canny time: " << t_canny << " s\n";

    // FFT Edge Detection
    t_start = get_time();
    vector<unsigned char> out_fft = fft_edge_detection(gray, width, height);
    double t_fft = get_time() - t_start;
    stbi_write_png("fft_edge_out.png", width, height, 1, out_fft.data(), width);
    cout << "FFT Edge time: " << t_fft << " s\n";
    
    return 0;
}
