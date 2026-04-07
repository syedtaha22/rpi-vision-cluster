#include <iostream>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include "../include/image_io.hpp"
#include "../include/sobel.hpp"
#include "../include/canny.hpp"
#include "../include/timing.hpp"

namespace fs = std::filesystem;

struct TestResult {
    std::string algorithm;
    std::string image_file;
    int width, height;
    long pixel_count;
    double processing_time_ms;
    double throughput_mps;
    bool passed;
    std::string error_msg;
};

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

TestResult run_sobel_test(const std::string& image_path) {
    TestResult result;
    result.algorithm = "Sobel";
    result.image_file = fs::path(image_path).filename().string();

    Image img = ImageIO::load_grayscale(image_path);
    if (!img.is_valid()) {
        result.passed = false;
        result.error_msg = "Failed to load image";
        return result;
    }

    result.width = img.width;
    result.height = img.height;
    result.pixel_count = img.pixel_count();

    uint8_t* output = new uint8_t[result.pixel_count]();
    if (!output) {
        result.passed = false;
        result.error_msg = "Failed to allocate output buffer";
        return result;
    }

    SobelDetector sobel;
    Timer timer;

    timer.start();
    bool ok = sobel.process(img.data, img.width, img.height, output);
    timer.stop();

    result.processing_time_ms = timer.elapsed();
    result.throughput_mps = timer.throughput_megapixels(result.pixel_count);
    result.passed = ok && validate_output(output, img.width, img.height);
    if (!result.passed) {
        result.error_msg = "Validation failed";
    }

    delete[] output;
    return result;
}

TestResult run_canny_test(const std::string& image_path) {
    TestResult result;
    result.algorithm = "Canny";
    result.image_file = fs::path(image_path).filename().string();

    Image img = ImageIO::load_grayscale(image_path);
    if (!img.is_valid()) {
        result.passed = false;
        result.error_msg = "Failed to load image";
        return result;
    }

    result.width = img.width;
    result.height = img.height;
    result.pixel_count = img.pixel_count();

    uint8_t* output = new uint8_t[result.pixel_count]();
    if (!output) {
        result.passed = false;
        result.error_msg = "Failed to allocate output buffer";
        return result;
    }

    CannyDetector canny(50, 150, 1.4f);
    Timer timer;

    timer.start();
    bool ok = canny.process(img.data, img.width, img.height, output);
    timer.stop();

    result.processing_time_ms = timer.elapsed();
    result.throughput_mps = timer.throughput_megapixels(result.pixel_count);
    result.passed = ok && validate_output(output, img.width, img.height);
    if (!result.passed) {
        result.error_msg = "Validation failed";
    }

    delete[] output;
    return result;
}

int main() {
    std::string images_dir = "images";
    std::vector<std::string> test_files;

    // Find first PNG image
    if (fs::exists(images_dir) && fs::is_directory(images_dir)) {
        for (const auto& entry : fs::directory_iterator(images_dir)) {
            if (entry.path().extension() == ".png") {
                test_files.push_back(entry.path().string());
                break;  // Only test first image
            }
        }
    }

    if (test_files.empty()) {
        std::cerr << "ERROR: No PNG images found in " << images_dir << std::endl;
        return 1;
    }

    std::cout << "=== Single Image Baseline Test ===" << std::endl;
    std::cout << "Image: " << test_files[0] << std::endl;

    std::vector<TestResult> results;
    results.push_back(run_sobel_test(test_files[0]));
    results.push_back(run_canny_test(test_files[0]));

    // Print results
    std::cout << std::endl << std::setw(10) << "Algorithm" 
              << std::setw(15) << "Image Size (px)"
              << std::setw(20) << "Processing Time (ms)"
              << std::setw(18) << "Throughput (MP/s)"
              << std::setw(8) << "Status" << std::endl;
    std::cout << std::string(70, '-') << std::endl;

    int passed = 0;
    for (const auto& r : results) {
        std::cout << std::setw(10) << r.algorithm
                  << std::setw(15) << (std::to_string(r.width) + "x" + std::to_string(r.height))
                  << std::fixed << std::setprecision(4)
                  << std::setw(20) << r.processing_time_ms
                  << std::setw(18) << r.throughput_mps
                  << std::setw(8) << (r.passed ? "PASS" : "FAIL") << std::endl;
        if (r.passed) passed++;
    }

    std::cout << std::string(70, '-') << std::endl;
    std::cout << "Results: " << passed << "/" << results.size() << " tests passed" << std::endl;

    // Save results to CSV
    std::ofstream csv("results/single_image_baseline.csv");
    csv << "Algorithm,Image_File,Width,Height,Pixel_Count,Time_ms,Throughput_MPS,Status\n";
    for (const auto& r : results) {
        csv << r.algorithm << "," << r.image_file << "," << r.width << "," << r.height 
            << "," << r.pixel_count << "," << std::fixed << std::setprecision(6) 
            << r.processing_time_ms << "," << r.throughput_mps << "," 
            << (r.passed ? "PASS" : "FAIL") << "\n";
    }
    csv.close();

    std::cout << "\nResults saved to: results/single_image_baseline.csv" << std::endl;

    return passed == results.size() ? 0 : 1;
}
