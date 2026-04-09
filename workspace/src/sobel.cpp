#include "sobel.hpp"
#include <cmath>
#include <algorithm>

// Sobel kernels
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

uint8_t SobelDetector::magnitude(int gx, int gy) {
    double mag = std::sqrt(gx * gx + gy * gy);
    // Normalize to [0, 255]
    mag = std::min(255.0, mag / std::sqrt(2.0) * 255.0 / 1024.0);
    return static_cast<uint8_t>(mag);
}

int SobelDetector::direction(int gx, int gy) {
    // Quantize gradient direction to 4 bins: 0°, 45°, 90°, 135°
    double angle = std::atan2(gy, gx) * 180.0 / M_PI;
    if (angle < 0) angle += 180.0;

    if (angle < 22.5 || angle >= 157.5) return 0;  // 0°
    if (angle < 67.5) return 1;                     // 45°
    if (angle < 112.5) return 2;                    // 90°
    return 3;                                        // 135°
}

bool SobelDetector::compute_gradients(const float* input, int width, int height,
                                      float* magnitude, int* direction) {
    if (!input || !magnitude || !direction || width < 3 || height < 3) {
        return false;
    }

    // Process interior pixels (leave border as 0)
    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            int gx = 0, gy = 0;

            // Apply Sobel operators
            for (int ky = -1; ky <= 1; ky++) {
                for (int kx = -1; kx <= 1; kx++) {
                    int pixel_idx = (y + ky) * width + (x + kx);
                    float pixel = input[pixel_idx];
                    gx += static_cast<int>(SOBEL_X[ky + 1][kx + 1] * pixel);
                    gy += static_cast<int>(SOBEL_Y[ky + 1][kx + 1] * pixel);
                }
            }

            // Compute magnitude and direction
            int output_idx = y * width + x;
            magnitude[output_idx] = std::sqrt(gx * gx + gy * gy);
            direction[output_idx] = SobelDetector::direction(gx, gy);
        }
    }

    return true;
}


bool SobelDetector::process(const uint8_t* input, int width, int height, uint8_t* output) {
    if (!input || !output || width < 3 || height < 3) {
        return false;
    }

    // Process interior pixels (leave border as 0)
    for (int y = 1; y < height - 1; y++) {
        for (int x = 1; x < width - 1; x++) {
            int gx = 0, gy = 0;

            // Apply Sobel operators
            for (int ky = -1; ky <= 1; ky++) {
                for (int kx = -1; kx <= 1; kx++) {
                    int pixel_idx = (y + ky) * width + (x + kx);
                    uint8_t pixel = input[pixel_idx];
                    gx += SOBEL_X[ky + 1][kx + 1] * pixel;
                    gy += SOBEL_Y[ky + 1][kx + 1] * pixel;
                }
            }

            // Compute magnitude
            int output_idx = y * width + x;
            output[output_idx] = magnitude(gx, gy);
        }
    }

    return true;
}
