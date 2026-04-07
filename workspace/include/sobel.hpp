#ifndef SOBEL_HPP
#define SOBEL_HPP

#include <cstdint>

class SobelDetector {
public:
    SobelDetector() = default;
    ~SobelDetector() = default;

    /**
     * Process a grayscale image with Sobel edge detection
     * @param input Grayscale input image (width x height pixels)
     * @param width Image width in pixels
     * @param height Image height in pixels
     * @param output Pre-allocated output buffer (must be width x height bytes)
     * @return true if successful, false otherwise
     */
    bool process(const uint8_t* input, int width, int height, uint8_t* output);

    /**
     * Get magnitude of gradient at pixel
     * @param gx X-direction gradient
     * @param gy Y-direction gradient
     * @return Gradient magnitude (normalized to [0, 255])
     */
    static uint8_t magnitude(int gx, int gy);

    /**
     * Get direction of gradient at pixel (in degrees: 0, 45, 90, 135)
     * @param gx X-direction gradient
     * @param gy Y-direction gradient
     * @return Direction (0-3: represents 0°, 45°, 90°, 135°)
     */
    static int direction(int gx, int gy);
};

#endif // SOBEL_HPP
