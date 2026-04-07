#include <iostream>
#include <string>
#include <filesystem>
#include "../include/image_io.hpp"
#include "../include/sobel.hpp"
#include "../include/canny.hpp"
#include "../include/timing.hpp"

namespace fs = std::filesystem;

bool validate_output(const uint8_t* output, int width, int height) {
    if (!output || width <= 0 || height <= 0) {
        return false;
    }

    bool has_edges = false;
    for (int i = 0; i < width * height; i++) {
        if (output[i] > 0) {
            has_edges = true;
            break;
        }
    }

    return has_edges;
}

int main(int argc, char* argv[]) {
    // Find first PNG image in workspace/images/
    std::string image_dir = "images";
    std::string test_image;

    if (fs::exists(image_dir) && fs::is_directory(image_dir)) {
        for (const auto& entry : fs::directory_iterator(image_dir)) {
            if (entry.path().extension() == ".png") {
                test_image = entry.path().string();
                break;
            }
        }
    }

    if (test_image.empty()) {
        std::cerr << "ERROR: No PNG images found in " << image_dir << std::endl;
        return 1;
    }

    std::cout << "=== Basic Edge Detection Test ===" << std::endl;
    std::cout << "Test image: " << test_image << std::endl;

    // Load image in grayscale
    Image img = ImageIO::load_grayscale(test_image);
    if (!img.is_valid()) {
        std::cerr << "ERROR: Failed to load image " << test_image << std::endl;
        return 1;
    }

    std::cout << "Image dimensions: " << img.width << "x" << img.height 
              << " (" << img.pixel_count() << " pixels)" << std::endl;

    // Allocate output buffers
    uint8_t* sobel_output = new uint8_t[img.width * img.height]();
    uint8_t* canny_output = new uint8_t[img.width * img.height]();

    if (!sobel_output || !canny_output) {
        std::cerr << "ERROR: Failed to allocate output buffers" << std::endl;
        delete[] sobel_output;
        delete[] canny_output;
        return 1;
    }

    // Test Sobel
    std::cout << "\n--- Sobel Edge Detection ---" << std::endl;
    SobelDetector sobel;
    Timer sobel_timer;

    sobel_timer.start();
    bool sobel_ok = sobel.process(img.data, img.width, img.height, sobel_output);
    sobel_timer.stop();

    if (!sobel_ok) {
        std::cerr << "ERROR: Sobel processing failed" << std::endl;
        delete[] sobel_output;
        delete[] canny_output;
        return 1;
    }

    if (!validate_output(sobel_output, img.width, img.height)) {
        std::cerr << "ERROR: Sobel output validation failed (no edges detected)" << std::endl;
        delete[] sobel_output;
        delete[] canny_output;
        return 1;
    }

    std::cout << "✓ Sobel processing successful" << std::endl;
    std::cout << "  Processing time: " << sobel_timer.elapsed() << " ms" << std::endl;
    std::cout << "  Throughput: " << sobel_timer.throughput_megapixels(img.pixel_count()) 
              << " MP/s" << std::endl;

    // Save Sobel output
    std::string sobel_output_path = "results/sobel_output.png";
    if (ImageIO::save_png(sobel_output_path, img.width, img.height, 1, sobel_output)) {
        std::cout << "  Output saved to: " << sobel_output_path << std::endl;
    }

    // Test Canny
    std::cout << "\n--- Canny Edge Detection ---" << std::endl;
    CannyDetector canny(50, 150, 1.4f);
    Timer canny_timer;

    canny_timer.start();
    bool canny_ok = canny.process(img.data, img.width, img.height, canny_output);
    canny_timer.stop();

    if (!canny_ok) {
        std::cerr << "ERROR: Canny processing failed" << std::endl;
        delete[] sobel_output;
        delete[] canny_output;
        return 1;
    }

    if (!validate_output(canny_output, img.width, img.height)) {
        std::cerr << "ERROR: Canny output validation failed (no edges detected)" << std::endl;
        delete[] sobel_output;
        delete[] canny_output;
        return 1;
    }

    std::cout << "✓ Canny processing successful" << std::endl;
    std::cout << "  Processing time: " << canny_timer.elapsed() << " ms" << std::endl;
    std::cout << "  Throughput: " << canny_timer.throughput_megapixels(img.pixel_count()) 
              << " MP/s" << std::endl;

    // Save Canny output
    std::string canny_output_path = "results/canny_output.png";
    if (ImageIO::save_png(canny_output_path, img.width, img.height, 1, canny_output)) {
        std::cout << "  Output saved to: " << canny_output_path << std::endl;
    }

    std::cout << "\n=== All Tests Passed ===" << std::endl;

    delete[] sobel_output;
    delete[] canny_output;

    return 0;
}
