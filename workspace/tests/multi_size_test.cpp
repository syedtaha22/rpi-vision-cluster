#include <iostream>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <algorithm>
#include "../include/image_io.hpp"
#include "../include/sobel.hpp"
#include "../include/canny.hpp"
#include "../include/timing.hpp"

namespace fs = std::filesystem;

struct ImageInfo {
    std::string path;
    std::string filename;
    int width;
    int height;
    long pixel_count;
};

struct TestResult {
    std::string algorithm;
    std::string image_file;
    int width, height;
    long pixel_count;
    double processing_time_ms;
    double throughput_mps;
    bool passed;
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

TestResult run_sobel_test(const std::string& image_path, const ImageInfo& info) {
    TestResult result;
    result.algorithm = "Sobel";
    result.image_file = info.filename;
    result.width = info.width;
    result.height = info.height;
    result.pixel_count = info.pixel_count;

    Image img = ImageIO::load_grayscale(image_path);
    if (!img.is_valid()) {
        result.passed = false;
        return result;
    }

    uint8_t* output = new uint8_t[result.pixel_count]();
    if (!output) {
        result.passed = false;
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

    delete[] output;
    return result;
}

TestResult run_canny_test(const std::string& image_path, const ImageInfo& info) {
    TestResult result;
    result.algorithm = "Canny";
    result.image_file = info.filename;
    result.width = info.width;
    result.height = info.height;
    result.pixel_count = info.pixel_count;

    Image img = ImageIO::load_grayscale(image_path);
    if (!img.is_valid()) {
        result.passed = false;
        return result;
    }

    uint8_t* output = new uint8_t[result.pixel_count]();
    if (!output) {
        result.passed = false;
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

    delete[] output;
    return result;
}

int main() {
    std::string images_dir = "images";
    std::vector<ImageInfo> images;

    // Scan and load image info
    std::cout << "=== Multi-Size Baseline Test ===" << std::endl;
    std::cout << "Scanning images..." << std::endl;

    if (fs::exists(images_dir) && fs::is_directory(images_dir)) {
        for (const auto& entry : fs::directory_iterator(images_dir)) {
            if (entry.path().extension() == ".png" || entry.path().extension() == ".jpg") {
                Image img = ImageIO::load_grayscale(entry.path().string());
                if (img.is_valid()) {
                    ImageInfo info;
                    info.path = entry.path().string();
                    info.filename = entry.path().filename().string();
                    info.width = img.width;
                    info.height = img.height;
                    info.pixel_count = img.pixel_count();
                    images.push_back(info);
                }
            }
        }
    }

    if (images.empty()) {
        std::cerr << "ERROR: No images found" << std::endl;
        return 1;
    }

    // Sort by pixel count
    std::sort(images.begin(), images.end(), 
              [](const ImageInfo& a, const ImageInfo& b) {
                  return a.pixel_count < b.pixel_count;
              });

    std::cout << "Found " << images.size() << " images" << std::endl;
    std::cout << "Size range: " << images.front().width << "x" << images.front().height
              << " (" << images.front().pixel_count << " px) to "
              << images.back().width << "x" << images.back().height
              << " (" << images.back().pixel_count << " px)" << std::endl;

    // Run tests
    std::vector<TestResult> results;
    int total_tests = images.size() * 2;
    int completed = 0;

    std::cout << "\nRunning tests..." << std::endl;
    for (const auto& img : images) {
        std::cout << "  Testing " << img.filename << " (" << img.width << "x" << img.height << ")... ";
        results.push_back(run_sobel_test(img.path, img));
        std::cout << ".";
        results.push_back(run_canny_test(img.path, img));
        std::cout << " done\n";
    }

    // Print summary
    std::cout << std::endl << "=== Results ===" << std::endl;
    std::cout << std::setw(15) << "Algorithm" 
              << std::setw(20) << "Image Size"
              << std::setw(20) << "Time (ms)"
              << std::setw(18) << "Throughput (MP/s)"
              << std::setw(10) << "Status" << std::endl;
    std::cout << std::string(83, '-') << std::endl;

    int passed = 0;
    for (const auto& r : results) {
        std::cout << std::setw(15) << r.algorithm
                  << std::setw(20) << (std::to_string(r.width) + "x" + std::to_string(r.height))
                  << std::fixed << std::setprecision(4)
                  << std::setw(20) << r.processing_time_ms
                  << std::setw(18) << r.throughput_mps
                  << std::setw(10) << (r.passed ? "PASS" : "FAIL") << std::endl;
        if (r.passed) passed++;
    }

    std::cout << std::string(83, '-') << std::endl;
    std::cout << "Results: " << passed << "/" << results.size() << " tests passed" << std::endl;

    // Save detailed results to CSV
    std::ofstream csv("results/multi_size_baseline.csv");
    csv << "Algorithm,Image_File,Width,Height,Pixel_Count,Time_ms,Throughput_MPS,Status\n";
    for (const auto& r : results) {
        csv << r.algorithm << "," << r.image_file << "," << r.width << "," << r.height 
            << "," << r.pixel_count << "," << std::fixed << std::setprecision(6) 
            << r.processing_time_ms << "," << r.throughput_mps << "," 
            << (r.passed ? "PASS" : "FAIL") << "\n";
    }
    csv.close();

    std::cout << "\nResults saved to: results/multi_size_baseline.csv" << std::endl;

    return passed == results.size() ? 0 : 1;
}
