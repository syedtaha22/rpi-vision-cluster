#include "canny.hpp"
#include "sobel.hpp"
#include <cmath>
#include <cstring>
#include <algorithm>
#include <queue>

CannyDetector::CannyDetector(uint8_t low_threshold, uint8_t high_threshold, float sigma)
    : low_threshold(low_threshold), high_threshold(high_threshold), sigma(sigma) {}

void CannyDetector::set_thresholds(uint8_t low, uint8_t high) {
    low_threshold = low;
    high_threshold = high;
}

void CannyDetector::set_sigma(float s) {
    sigma = s;
}

float* CannyDetector::gaussian_blur(const uint8_t* input, int width, int height) {
    float* blurred = new float[width * height];
    if (!blurred) return nullptr;

    // Create Gaussian kernel
    int kernel_size = static_cast<int>(2 * std::ceil(3 * sigma) + 1);
    if (kernel_size < 3) kernel_size = 3;
    if (kernel_size % 2 == 0) kernel_size++;

    int radius = kernel_size / 2;
    float* kernel = new float[kernel_size];
    float sum = 0.0f;

    for (int i = 0; i < kernel_size; i++) {
        int x = i - radius;
        kernel[i] = std::exp(-(x * x) / (2 * sigma * sigma));
        sum += kernel[i];
    }

    // Normalize kernel
    for (int i = 0; i < kernel_size; i++) {
        kernel[i] /= sum;
    }

    // Separable Gaussian: apply horizontally first
    float* temp = new float[width * height];
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            float val = 0.0f;
            for (int k = -radius; k <= radius; k++) {
                int nx = std::max(0, std::min(width - 1, x + k));
                val += kernel[k + radius] * input[y * width + nx];
            }
            temp[y * width + x] = val;
        }
    }

    // Apply vertically
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            float val = 0.0f;
            for (int k = -radius; k <= radius; k++) {
                int ny = std::max(0, std::min(height - 1, y + k));
                val += kernel[k + radius] * temp[ny * width + x];
            }
            blurred[y * width + x] = val;
        }
    }

    delete[] kernel;
    delete[] temp;
    return blurred;
}

bool CannyDetector::non_maximum_suppression(const float* magnitude, const int* direction,
                                             int width, int height, uint8_t* output) {
    std::memset(output, 0, width * height);

    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            int idx = y * width + x;
            float mag = magnitude[idx];
            int dir = direction[idx];

            float mag1 = 0, mag2 = 0;

            // Check neighbors perpendicular to gradient direction
            if (dir == 0) {  // 0° - horizontal
                mag1 = magnitude[y * width + (x - 1)];
                mag2 = magnitude[y * width + (x + 1)];
            } else if (dir == 1) {  // 45°
                mag1 = magnitude[(y - 1) * width + (x + 1)];
                mag2 = magnitude[(y + 1) * width + (x - 1)];
            } else if (dir == 2) {  // 90° - vertical
                mag1 = magnitude[(y - 1) * width + x];
                mag2 = magnitude[(y + 1) * width + x];
            } else {  // 135°
                mag1 = magnitude[(y - 1) * width + (x - 1)];
                mag2 = magnitude[(y + 1) * width + (x + 1)];
            }

            // Keep local maximum
            if (mag >= mag1 && mag >= mag2) {
                output[idx] = static_cast<uint8_t>(std::min(255.0f, mag));
            }
        }
    }

    return true;
}

bool CannyDetector::hysteresis_threshold(uint8_t* edges, int width, int height) {
    // Mark strong and weak edges
    std::vector<bool> strong(width * height, false);
    std::queue<int> queue;

    // Find strong edges and weak edges
    for (int i = 0; i < width * height; i++) {
        if (edges[i] >= high_threshold) {
            strong[i] = true;
            queue.push(i);
        } else if (edges[i] < low_threshold) {
            edges[i] = 0;
        }
    }

    // Track weak edges connected to strong edges (BFS)
    while (!queue.empty()) {
        int idx = queue.front();
        queue.pop();

        int x = idx % width;
        int y = idx / width;

        // Check 8 neighbors
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                if (dx == 0 && dy == 0) continue;

                int nx = x + dx;
                int ny = y + dy;

                if (nx >= 0 && nx < width && ny >= 0 && ny < height) {
                    int neighbor_idx = ny * width + nx;
                    if (!strong[neighbor_idx] && edges[neighbor_idx] >= low_threshold) {
                        strong[neighbor_idx] = true;
                        edges[neighbor_idx] = 255;
                        queue.push(neighbor_idx);
                    }
                }
            }
        }
    }

    // Set weak edges not connected to strong edges to 0
    for (int i = 0; i < width * height; i++) {
        if (!strong[i]) {
            edges[i] = 0;
        } else if (edges[i] < 255) {
            edges[i] = 255;
        }
    }

    return true;
}

bool CannyDetector::process(const uint8_t* input, int width, int height, uint8_t* output) {
    if (!input || !output || width < 3 || height < 3) {
        return false;
    }

    // Stage 1: Gaussian blur
    float* blurred = gaussian_blur(input, width, height);
    if (!blurred) return false;

    // Stage 2: Compute Sobel gradients
    float* magnitude = new float[width * height];
    int* direction = new int[width * height];

    if (!magnitude || !direction) {
        delete[] blurred;
        delete[] magnitude;
        delete[] direction;
        return false;
    }

    static const int SOBEL_X[3][3] = {
        {-1, 0, 1},
        {-2, 0, 2},
        {-1, 0, 1}
    };

    static const int SOBEL_Y[3][3] = {
        {-1, -2, -1},
        {0, 0, 0},
        {1, 2, 1}
    };

    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            int gx = 0, gy = 0;

            // Apply Sobel operators on blurred image
            for (int ky = -1; ky <= 1; ky++) {
                for (int kx = -1; kx <= 1; kx++) {
                    int pixel_idx = (y + ky) * width + (x + kx);
                    float pixel = blurred[pixel_idx];
                    gx += static_cast<int>(SOBEL_X[ky + 1][kx + 1] * pixel);
                    gy += static_cast<int>(SOBEL_Y[ky + 1][kx + 1] * pixel);
                }
            }

            int idx = y * width + x;
            magnitude[idx] = std::sqrt(gx * gx + gy * gy);
            direction[idx] = SobelDetector::direction(gx, gy);
        }
    }

    // Stage 3: Non-maximum suppression
    non_maximum_suppression(magnitude, direction, width, height, output);

    // Stage 4: Hysteresis thresholding
    hysteresis_threshold(output, width, height);

    // Cleanup
    delete[] blurred;
    delete[] magnitude;
    delete[] direction;

    return true;
}
