#ifndef CANNY_HPP
#define CANNY_HPP

#include <cstdint>

class CannyDetector {
public:
    /**
     * @param low_threshold Lower threshold for hysteresis (0-255)
     * @param high_threshold Upper threshold for hysteresis (0-255)
     * @param sigma Gaussian blur standard deviation (typically 1.0-2.0)
     */
    CannyDetector(uint8_t low_threshold = 50, uint8_t high_threshold = 150, float sigma = 1.4f);
    ~CannyDetector() = default;

    /**
     * Process a grayscale image with Canny edge detection
     * Pipeline: Gaussian blur -> Sobel gradients -> Non-maximum suppression -> Hysteresis thresholding
     * 
     * @param input Grayscale input image (width x height pixels)
     * @param width Image width in pixels
     * @param height Image height in pixels
     * @param output Pre-allocated output buffer (must be width x height bytes)
     * @return true if successful, false otherwise
     */
    bool process(const uint8_t* input, int width, int height, uint8_t* output);

    void set_thresholds(uint8_t low, uint8_t high);
    void set_sigma(float sigma);

private:
    uint8_t low_threshold;
    uint8_t high_threshold;
    float sigma;

    // Helper methods for pipeline stages
    float* gaussian_blur(const uint8_t* input, int width, int height);
    bool non_maximum_suppression(const float* magnitude, const int* direction, 
                                  int width, int height, uint8_t* output);
    bool hysteresis_threshold(uint8_t* edges, int width, int height);
};

#endif // CANNY_HPP
