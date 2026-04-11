#ifndef TIMING_HPP
#define TIMING_HPP

#include <chrono>
#include <cstring>

#ifdef OMPI_MPI_H
#include <mpi.h>
#endif

class Timer {
private:
    std::chrono::high_resolution_clock::time_point start_time;
    double elapsed_ms;

public:
    Timer() : elapsed_ms(0.0) {}

    void start() {
#ifdef OMPI_MPI_H
        MPI_Barrier(MPI_COMM_WORLD);
#endif
        start_time = std::chrono::high_resolution_clock::now();
    }

    void stop() {
        auto end_time = std::chrono::high_resolution_clock::now();
        elapsed_ms = std::chrono::duration<double, std::milli>(end_time - start_time).count();
    }

    double elapsed() const {
        return elapsed_ms;
    }

    double throughput_megapixels(long total_pixels) const {
        if (elapsed_ms <= 0) return 0.0;
        return (total_pixels / 1e6) / (elapsed_ms / 1e3);
    }
};

#endif // TIMING_HPP
