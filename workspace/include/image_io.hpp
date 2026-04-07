#ifndef IMAGE_IO_HPP
#define IMAGE_IO_HPP

#include <string>
#include <cstring>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

struct Image {
    unsigned char* data;
    int width;
    int height;
    int channels;

    Image() : data(nullptr), width(0), height(0), channels(0) {}

    ~Image() {
        if (data) {
            stbi_image_free(data);
        }
    }

    // Prevent copying
    Image(const Image&) = delete;
    Image& operator=(const Image&) = delete;

    // Allow moving
    Image(Image&& other) noexcept
        : data(other.data), width(other.width), height(other.height), channels(other.channels) {
        other.data = nullptr;
    }

    Image& operator=(Image&& other) noexcept {
        if (this != &other) {
            if (data) stbi_image_free(data);
            data = other.data;
            width = other.width;
            height = other.height;
            channels = other.channels;
            other.data = nullptr;
        }
        return *this;
    }

    long pixel_count() const {
        return (long)width * height;
    }

    bool is_valid() const {
        return data != nullptr && width > 0 && height > 0 && channels > 0;
    }
};

class ImageIO {
public:
    static Image load(const std::string& filepath, int desired_channels = 1) {
        Image img;
        img.data = stbi_load(filepath.c_str(), &img.width, &img.height, &img.channels, desired_channels);
        if (desired_channels != 0) {
            img.channels = desired_channels;
        }
        return img;
    }

    static Image load_rgb(const std::string& filepath) {
        return load(filepath, 3);
    }

    static Image load_grayscale(const std::string& filepath) {
        return load(filepath, 1);
    }

    static bool save_png(const std::string& filepath, int width, int height, int channels, const unsigned char* data) {
        return stbi_write_png(filepath.c_str(), width, height, channels, data, width * channels);
    }
};

#endif // IMAGE_IO_HPP
