#include <mpi.h>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include "fft_utils.h"
#include <iostream>
#include <vector>
#include <sys/time.h>

using namespace std;

void transpose(const vector<Complex>& in, vector<Complex>& out, int w, int h) {
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            out[x * h + y] = in[y * w + x];
        }
    }
}

int main(int argc, char** argv) {
    MPI_Init(&argc, &argv);
    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    int new_w = 0, new_h = 0, orig_w = 0, orig_h = 0;
    vector<Complex> data;
    double t_start;

    if (rank == 0) {
        if (argc < 2) {
            cout << "Usage: " << argv[0] << " <image_path>\n";
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
        int channels;
        unsigned char* img_data = stbi_load(argv[1], &orig_w, &orig_h, &channels, 0);
        if (!img_data) {
            cerr << "Failed to load image\n";
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
        new_w = next_power_of_2(orig_w);
        new_h = next_power_of_2(orig_h);
        data.resize(new_w * new_h, Complex(0,0));
        for (int y = 0; y < orig_h; ++y) {
            for (int x = 0; x < orig_w; ++x) {
                double sign = ((x + y) % 2 == 0) ? 1.0 : -1.0;
                data[y * new_w + x] = Complex(img_data[(y * orig_w + x) * channels] * sign, 0);
            }
        }
        stbi_image_free(img_data);
        t_start = MPI_Wtime();
    }

    MPI_Bcast(&new_w, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(&new_h, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(&orig_w, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(&orig_h, 1, MPI_INT, 0, MPI_COMM_WORLD);

    int rows_per_proc = new_h / size;
    vector<Complex> local_data(rows_per_proc * new_w);

    // Forward Pass
    MPI_Scatter(data.data(), rows_per_proc * new_w * 2, MPI_DOUBLE, local_data.data(), rows_per_proc * new_w * 2, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    for (int y = 0; y < rows_per_proc; ++y) {
        vector<Complex> row(new_w);
        for(int x = 0; x < new_w; ++x) row[x] = local_data[y * new_w + x];
        fft1d(row);
        for(int x = 0; x < new_w; ++x) local_data[y * new_w + x] = row[x];
    }
    MPI_Gather(local_data.data(), rows_per_proc * new_w * 2, MPI_DOUBLE, data.data(), rows_per_proc * new_w * 2, MPI_DOUBLE, 0, MPI_COMM_WORLD);

    if (rank == 0) {
        vector<Complex> temp(new_w * new_h);
        transpose(data, temp, new_w, new_h);
        data = temp;
    }

    int cols_per_proc = new_w / size;
    vector<Complex> local_cols(cols_per_proc * new_h);
    MPI_Scatter(data.data(), cols_per_proc * new_h * 2, MPI_DOUBLE, local_cols.data(), cols_per_proc * new_h * 2, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    
    int cx = new_w / 2, cy = new_h / 2, r = 10;
    for (int x = 0; x < cols_per_proc; ++x) {
        int global_x = rank * cols_per_proc + x;
        vector<Complex> col(new_h);
        for(int y = 0; y < new_h; ++y) col[y] = local_cols[x * new_h + y];
        fft1d(col);
        
        // Filter + IFFT
        for(int y = 0; y < new_h; ++y) {
            if ((global_x-cx)*(global_x-cx) + (y-cy)*(y-cy) < r*r) col[y] = 0;
        }
        ifft1d(col);
        for(int y = 0; y < new_h; ++y) local_cols[x * new_h + y] = col[y];
    }
    MPI_Gather(local_cols.data(), cols_per_proc * new_h * 2, MPI_DOUBLE, data.data(), cols_per_proc * new_h * 2, MPI_DOUBLE, 0, MPI_COMM_WORLD);

    // Inverse Row Pass
    if (rank == 0) {
        vector<Complex> temp(new_w * new_h);
        transpose(data, temp, new_h, new_w);
        data = temp;
    }
    MPI_Scatter(data.data(), rows_per_proc * new_w * 2, MPI_DOUBLE, local_data.data(), rows_per_proc * new_w * 2, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    for (int y = 0; y < rows_per_proc; ++y) {
        vector<Complex> row(new_w);
        for(int x = 0; x < new_w; ++x) row[x] = local_data[y * new_w + x];
        ifft1d(row);
        for(int x = 0; x < new_w; ++x) local_data[y * new_w + x] = row[x];
    }
    MPI_Gather(local_data.data(), rows_per_proc * new_w * 2, MPI_DOUBLE, data.data(), rows_per_proc * new_w * 2, MPI_DOUBLE, 0, MPI_COMM_WORLD);

    if (rank == 0) {
        double t_end = MPI_Wtime();
        cout << "FFT Arch3 (Dist Dynamic/Scatter-Gather) Time: " << (t_end - t_start) << " s.\n";
        vector<unsigned char> out(orig_w * orig_h);
        for (int y = 0; y < orig_h; ++y) {
            for (int x = 0; x < orig_w; ++x) {
                double sign = ((x + y) % 2 == 0) ? 1.0 : -1.0;
                double val = data[y * new_w + x].real() * sign;
                out[y * orig_w + x] = (unsigned char)max(0.0, min(255.0, val + 128.0));
            }
        }
        stbi_write_png("fft_arch3_out.png", orig_w, orig_h, 1, out.data(), orig_w);
    }

    MPI_Finalize();
    return 0;
}
