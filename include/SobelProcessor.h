/**
 * @file SobelProcessor.h
 * @brief Image processing interface for Sobel edge detection.
 * @date 1st May, 2026
 * @author Syed Taha
 */

#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

 /**
  * @class SobelProcessor
  * @brief Image processor that converts RGBA frames to Sobel edge output.
  *
  * Processes fixed-size RGBA image frames through a grayscale conversion
  * followed by Sobel edge detection to produce edge-highlighted RGBA output.
  */
class SobelProcessor {
public:
    /**
     * @brief Creates a processor for fixed-size frames.
     * @param width image width in pixels
     * @param height image height in pixels
     */
    SobelProcessor(int width, int height);

    /**
     * @brief Processes a single RGBA frame and returns a processed RGBA edge image.
     * @param rgba input RGBA pixel data (width*height*4 bytes)
     * @return processed RGBA edge data, or empty vector on error
     */
    std::vector<uint8_t> process(const std::vector<uint8_t>& rgba) const;

    /**
     * @brief Returns the configured frame size in bytes.
     * @return frame size = width * height * 4
     */
    size_t frame_size() const;

private:
    int width_;         ///< Frame width in pixels
    int height_;        ///< Frame height in pixels
    size_t frame_size_; ///< Total frame size in bytes (width * height * 4)
};
