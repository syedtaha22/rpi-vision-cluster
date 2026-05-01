/**
 * @file SobelProcessor.cpp
 * @brief Implementation of Sobel edge detection image processor.
 * @date 1st May, 2026
 * @author Syed Taha
 */

#include "SobelProcessor.h"

#include <cmath>

SobelProcessor::SobelProcessor(int width, int height)
    : width_(width), height_(height), frame_size_(static_cast<size_t>(width)* static_cast<size_t>(height) * 4) {
}

size_t SobelProcessor::frame_size() const {
    return frame_size_;
}

std::vector<uint8_t> SobelProcessor::process(const std::vector<uint8_t>& rgba) const {
    if (rgba.size() != frame_size_) {
        return {};
    }

    std::vector<uint8_t> gray(static_cast<size_t>(width_) * static_cast<size_t>(height_));
    for (int i = 0; i < width_ * height_; ++i) {
        const uint8_t r = rgba[static_cast<size_t>(i) * 4 + 0];
        const uint8_t g = rgba[static_cast<size_t>(i) * 4 + 1];
        const uint8_t b = rgba[static_cast<size_t>(i) * 4 + 2];
        gray[static_cast<size_t>(i)] = static_cast<uint8_t>((77 * r + 150 * g + 29 * b) >> 8);
    }

    std::vector<uint8_t> output(frame_size_, 0);
    for (int y = 1; y < height_ - 1; ++y) {
        for (int x = 1; x < width_ - 1; ++x) {
            const int p00 = gray[static_cast<size_t>((y - 1) * width_ + (x - 1))];
            const int p01 = gray[static_cast<size_t>((y - 1) * width_ + x)];
            const int p02 = gray[static_cast<size_t>((y - 1) * width_ + (x + 1))];
            const int p10 = gray[static_cast<size_t>(y * width_ + (x - 1))];
            const int p12 = gray[static_cast<size_t>(y * width_ + (x + 1))];
            const int p20 = gray[static_cast<size_t>((y + 1) * width_ + (x - 1))];
            const int p21 = gray[static_cast<size_t>((y + 1) * width_ + x)];
            const int p22 = gray[static_cast<size_t>((y + 1) * width_ + (x + 1))];

            const int gx = -p00 + p02 - (2 * p10) + (2 * p12) - p20 + p22;
            const int gy = p00 + (2 * p01) + p02 - p20 - (2 * p21) - p22;
            int mag = static_cast<int>(std::sqrt(static_cast<double>(gx * gx + gy * gy)));
            if (mag > 255) {
                mag = 255;
            }

            const size_t out = static_cast<size_t>(y * width_ + x) * 4;
            const uint8_t v = static_cast<uint8_t>(mag);
            output[out + 0] = v;
            output[out + 1] = v;
            output[out + 2] = v;
            output[out + 3] = 255;
        }
    }

    for (int x = 0; x < width_; ++x) {
        output[static_cast<size_t>(x) * 4 + 3] = 255;
        output[static_cast<size_t>((height_ - 1) * width_ + x) * 4 + 3] = 255;
    }
    for (int y = 0; y < height_; ++y) {
        output[static_cast<size_t>(y * width_) * 4 + 3] = 255;
        output[static_cast<size_t>(y * width_ + (width_ - 1)) * 4 + 3] = 255;
    }

    return output;
}
