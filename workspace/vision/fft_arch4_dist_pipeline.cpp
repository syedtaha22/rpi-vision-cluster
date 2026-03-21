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

int main(int argc, char** argv) {
    MPI_Init(&argc, &argv);
    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    if (size < 2) {
        if (rank == 0) cout << "Pipeline architecture requires at least 2 nodes.\n";
        MPI_Finalize();
        return 0;
    }

    int dims[4] = {0, 0, 0, 0}; // new_w, new_h, orig_w, orig_h
    double t_start = 0;
    vector<Complex> data;

    if (rank == 0) {
        if (argc < 2) {
            cout << "Usage: " << argv[0] << " <image_path>\n";
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
        int channels;
        unsigned char* img_data = stbi_load(argv[1], &dims[2], &dims[3], &channels, 0);
        if (!img_data) {
            cerr << "Failed to load image\n";
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
        dims[0] = next_power_of_2(dims[2]);
        dims[1] = next_power_of_2(dims[3]);
        data.resize(dims[0] * dims[1], Complex(0,0));
        for (int y = 0; y < dims[3]; ++y) {
            for (int x = 0; x < dims[2]; ++x) {
                double sign = ((x + y) % 2 == 0) ? 1.0 : -1.0;
                data[y * dims[0] + x] = Complex(img_data[(y * dims[2] + x) * channels] * sign, 0);
            }
        }
        stbi_image_free(img_data);
        t_start = MPI_Wtime();
        
        // Stage 1: Row Pass Forward
        for (int y = 0; y < dims[1]; ++y) {
            vector<Complex> row(dims[0]);
            for(int x = 0; x < dims[0]; ++x) row[x] = data[y * dims[0] + x];
            fft1d(row);
            for(int x = 0; x < dims[0]; ++x) data[y * dims[0] + x] = row[x];
        }
        MPI_Send(dims, 4, MPI_INT, 1, 0, MPI_COMM_WORLD);
        MPI_Send(data.data(), dims[0] * dims[1] * 2, MPI_DOUBLE, 1, 0, MPI_COMM_WORLD);

    } else if (rank == 1) {
        MPI_Recv(dims, 4, MPI_INT, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        int nw = dims[0], nh = dims[1];
        data.resize(nw * nh);
        MPI_Recv(data.data(), nw * nh * 2, MPI_DOUBLE, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);

        // Stage 2: Col Pass Forward + GHPF + Col Pass Inverse
        int cx = nw / 2, cy = nh / 2;
        double d0 = 10.0;
        for (int x = 0; x < nw; ++x) {
            vector<Complex> col(nh);
            for(int y = 0; y < nh; ++y) col[y] = data[y * nw + x];
            fft1d(col);
            for(int y = 0; y < nh; ++y) {
                double d2 = (double)(x - cx) * (x - cx) + (double)(y - cy) * (y - cy);
                double h = 1.0 - exp(-d2 / (2.0 * d0 * d0));
                col[y] *= h;
            }
            ifft1d(col);
            for(int y = 0; y < nh; ++y) data[y * nw + x] = col[y];
        }
        MPI_Send(data.data(), nw * nh * 2, MPI_DOUBLE, 0, 1, MPI_COMM_WORLD);
    }
    
    if (rank == 0) {
        MPI_Recv(data.data(), dims[0] * dims[1] * 2, MPI_DOUBLE, 1, 1, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        // Stage 3: Row Pass Inverse
        for (int y = 0; y < dims[1]; ++y) {
            vector<Complex> row(dims[0]);
            for(int x = 0; x < dims[0]; ++x) row[x] = data[y * dims[0] + x];
            ifft1d(row);
            for(int x = 0; x < dims[0]; ++x) data[y * dims[0] + x] = row[x];
        }
        double t_end = MPI_Wtime();
        cout << "FFT Arch4 (Dist Pipeline) Total Time: " << (t_end - t_start) << " s.\n";
        
        vector<unsigned char> out(dims[2] * dims[3]);
        for (int y = 0; y < dims[3]; ++y) {
            for (int x = 0; x < dims[2]; ++x) {
                double sign = ((x + y) % 2 == 0) ? 1.0 : -1.0;
                double val = data[y * dims[0] + x].real() * sign;
                out[y * dims[2] + x] = (unsigned char)max(0.0, min(255.0, val + 128.0));
            }
        }
        stbi_write_png("fft_arch4_out.png", dims[2], dims[3], 1, out.data(), dims[2]);
    }

    MPI_Finalize();
    return 0;
}
