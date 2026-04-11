#include <iostream>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <algorithm>
#include <random>
#include <cstring>
#include "../include/utils.hpp"
#include "../include/image_io.hpp"
#include "../include/sobel.hpp"
#include "../include/canny.hpp"
#include "../include/timing.hpp"

namespace fs = std::filesystem;

struct TestResult {
    std::string image_file;
    int width, height;
    long pixel_count;
    double processing_time_ms;
    double throughput_mps;
};

// Generic detector function pointer type
typedef void (*DetectorFunc)(const uint8_t* input, int width, int height, uint8_t* output);

// Wrapper functions for Sobel and Canny
void sobel_wrapper(const uint8_t* input, int width, int height, uint8_t* output) {
    SobelDetector sobel;
    sobel.process(input, width, height, output);
}

void canny_wrapper(const uint8_t* input, int width, int height, uint8_t* output) {
    CannyDetector canny(50, 150, 1.4f);
    canny.process(input, width, height, output);
}

struct ImageInfo {
    std::string path;
    std::string filename;
    int width;
    int height;
    long pixel_count;
};

TestResult run_detector_test(const std::string& image_path, const ImageInfo& img_info,
    DetectorFunc detector, const std::string& output_dir, bool save_output) {
    TestResult result;
    result.image_file = img_info.filename;
    result.width = img_info.width;
    result.height = img_info.height;
    result.pixel_count = img_info.pixel_count;

    Image img = ImageIO::load_grayscale(image_path);
    if (!img.is_valid()) {
        result.processing_time_ms = 0;
        return result;
    }

    uint8_t* output = new uint8_t[result.pixel_count]();
    if (!output) {
        result.processing_time_ms = 0;
        return result;
    }

    Timer timer;
    timer.start();
    detector(img.data, img.width, img.height, output);
    timer.stop();

    result.processing_time_ms = timer.elapsed();
    result.throughput_mps = timer.throughput_megapixels(result.pixel_count);

    if (save_output) {
        std::string output_filename = img_info.filename.substr(0, img_info.filename.find_last_of('.')) + ".png";
        std::string output_path = output_dir + "/" + output_filename;
        ImageIO::save_png(output_path, img.width, img.height, 1, output);
    }

    delete[] output;
    return result;
}

int main(int argc, char* argv[]) {
    ArgParser parser;
    parser.add("-d", "--detector", true, "Detector to test: sobel or canny");
    parser.add("-n", "--number", true, "Number of images to test (default: 1)");
    parser.add("-r", "--random", false, "Randomly select images");
    parser.add("-o", "--output", true, "Save output images: true or false (default: true)");
    parser.add("-s", "--seed", true, "Random seed (default: 42)");
    parser.add("-i", "--images-path", true, "Path to images directory (default: images)");
    parser.parse(argc, argv);

    if (!parser.is_valid()) {
        return 1;
    }

    // Get detector
    std::string detector_name = parser.get<std::string>("--detector", "");
    if (detector_name.empty()) {
        std::cerr << "ERROR: --detector is required (sobel or canny)\n";
        parser.print_help(argv[0]);
        return 1;
    }

    DetectorFunc detector = nullptr;
    if (detector_name == "sobel") {
        detector = sobel_wrapper;
    }
    else if (detector_name == "canny") {
        detector = canny_wrapper;
    }
    else {
        std::cerr << "ERROR: unknown detector: " << detector_name << "\n";
        return 1;
    }

    // Get test parameters
    int num_images = parser.get<int>("--number", 1);
    bool random_select = parser.has("--random");
    bool save_output = parser.get<bool>("--output", true);
    unsigned int seed = parser.get<int>("--seed", 42);
    std::string images_path = parser.get<std::string>("--images-path", "images");

    // Create result directories
    std::string base_dir = "results/" + detector_name;
    std::string images_dir = base_dir + "/images";
    fs::create_directories(images_dir);

    // Scan available image paths (without loading)
    std::cout << "=== " << detector_name << " Detector Test ===" << std::endl;
    std::cout << "Scanning images..." << std::endl;

    std::vector<std::string> image_paths;
    if (fs::exists(images_path) && fs::is_directory(images_path)) {
        for (const auto& entry : fs::directory_iterator(images_path)) {
            if (entry.path().extension() == ".png" || entry.path().extension() == ".jpg") {
                image_paths.push_back(entry.path().string());
            }
        }
    }

    if (image_paths.empty()) {
        std::cerr << "ERROR: No images found in " << images_path << "\n";
        return 1;
    }

    std::cout << "Found " << image_paths.size() << " images" << std::endl;

    // Select and shuffle image paths
    std::mt19937 rng(seed);
    if (random_select) {
        std::shuffle(image_paths.begin(), image_paths.end(), rng);
    }

    num_images = std::min(num_images, (int)image_paths.size());
    std::vector<std::string> selected_paths(image_paths.begin(), image_paths.begin() + num_images);

    // Load metadata only for selected images
    std::vector<ImageInfo> test_images;
    for (const auto& path : selected_paths) {
        Image img = ImageIO::load_grayscale(path);
        if (img.is_valid()) {
            ImageInfo info;
            info.path = path;
            info.filename = fs::path(path).filename().string();
            info.width = img.width;
            info.height = img.height;
            info.pixel_count = img.pixel_count();
            test_images.push_back(info);
        }
    }

    std::cout << "Testing " << test_images.size() << " images (random: "
        << (random_select ? "yes, seed " + std::to_string(seed) : "no") << ")" << std::endl;
    if (!save_output) {
        std::cout << "Output images will NOT be saved" << std::endl;
    }

    // Run tests
    std::vector<TestResult> results;
    std::cout << "\nProcessing..." << std::endl;
    for (int i = 0; i < (int)test_images.size(); ++i) {
        if ((i + 1) % 10 == 0 || i + 1 == test_images.size()) {
            std::cout << "  " << (i + 1) << "/" << test_images.size() << " complete\n";
        }
        results.push_back(run_detector_test(test_images[i].path, test_images[i],
            detector, images_dir, save_output));
    }

    // Print summary
    std::cout << std::endl << "=== Results ===" << std::endl;
    std::cout << std::setw(20) << "Image"
        << std::setw(15) << "Size"
        << std::setw(15) << "Time (ms)"
        << std::setw(18) << "Throughput (MP/s)" << std::endl;
    std::cout << std::string(68, '-') << std::endl;

    for (const auto& r : results) {
        if (r.processing_time_ms > 0) {
            std::cout << std::setw(20) << r.image_file.substr(0, 19)
                << std::setw(15) << (std::to_string(r.width) + "x" + std::to_string(r.height))
                << std::fixed << std::setprecision(4)
                << std::setw(15) << r.processing_time_ms
                << std::setw(18) << r.throughput_mps << std::endl;
        }
    }

    // Calculate and print statistics
    double total_time = 0;
    int valid_count = 0;
    for (const auto& r : results) {
        if (r.processing_time_ms > 0) {
            total_time += r.processing_time_ms;
            valid_count++;
        }
    }

    if (valid_count > 0) {
        double avg_time = total_time / valid_count;
        std::cout << std::string(68, '-') << std::endl;
        std::cout << "Average time: " << std::fixed << std::setprecision(4) << avg_time << " ms\n";
        std::cout << "Total time: " << total_time << " ms\n";
        std::cout << "Tests run: " << valid_count << "\n";
    }

    // Save results to CSV
    std::string csv_path = base_dir + "/results.csv";
    std::ofstream csv(csv_path);
    csv << "Image_File,Width,Height,Pixel_Count,Time_ms,Throughput_MPS\n";
    for (const auto& r : results) {
        if (r.processing_time_ms > 0) {
            csv << r.image_file << "," << r.width << "," << r.height
                << "," << r.pixel_count << "," << std::fixed << std::setprecision(6)
                << r.processing_time_ms << "," << r.throughput_mps << "\n";
        }
    }
    csv.close();

    std::cout << "\nResults saved to:" << std::endl;
    std::cout << "  - CSV: " << csv_path << std::endl;
    if (save_output) {
        std::cout << "  - Images: " << images_dir << "/*.png" << std::endl;
    }

    return 0;
}
