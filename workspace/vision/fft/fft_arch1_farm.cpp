#include <mpi.h>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include "fft_utils.h"
#include <iostream>
#include <vector>

using namespace std;

int main(int argc, char** argv) {
    MPI_Init(&argc, &argv);
    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    const char* out_path = (argc > 2) ? argv[argc-1] : "fft_arch1_out.png";

    int new_w = 0, new_h = 0, orig_w = 0, orig_h = 0;
    vector<Complex> data;
    double t_start;

    if (rank == 0) {
        if (argc < 2) { MPI_Abort(MPI_COMM_WORLD, 1); }
        int channels;
        unsigned char* img_data = stbi_load(argv[1], &orig_w, &orig_h, &channels, 0);
        if (!img_data) { cerr << "Failed to load image\n"; MPI_Abort(MPI_COMM_WORLD, 1); }
        new_w = next_power_of_2(orig_w);
        new_h = next_power_of_2(orig_h);
        data.resize(new_w * new_h, Complex(0, 0));
        for (int y = 0; y < orig_h; ++y)
            for (int x = 0; x < orig_w; ++x) {
                double sign = ((x + y) % 2 == 0) ? 1.0 : -1.0;
                data[y * new_w + x] = Complex(img_data[(y * orig_w + x) * channels] * sign, 0);
            }
        stbi_image_free(img_data);
        t_start = MPI_Wtime();
    }

    MPI_Bcast(&new_w, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(&new_h, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(&orig_w, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(&orig_h, 1, MPI_INT, 0, MPI_COMM_WORLD);

    int rows_per_proc = new_h / size;
    int cols_per_proc = new_w / size;

    // ---- Step 1: Forward Row FFT ----
    vector<Complex> local_rows(rows_per_proc * new_w);
    MPI_Scatter(data.data(), rows_per_proc * new_w * 2, MPI_DOUBLE,
                local_rows.data(), rows_per_proc * new_w * 2, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    for (int y = 0; y < rows_per_proc; ++y) {
        vector<Complex> row(new_w);
        for (int x = 0; x < new_w; ++x) row[x] = local_rows[y * new_w + x];
        fft1d(row);
        for (int x = 0; x < new_w; ++x) local_rows[y * new_w + x] = row[x];
    }
    MPI_Gather(local_rows.data(), rows_per_proc * new_w * 2, MPI_DOUBLE,
               data.data(), rows_per_proc * new_w * 2, MPI_DOUBLE, 0, MPI_COMM_WORLD);

    // ---- Step 2: Forward Col FFT ----
    // Transpose on rank 0 so cols become rows for scatter
    if (rank == 0) {
        vector<Complex> temp(new_w * new_h);
        for (int y = 0; y < new_h; ++y)
            for (int x = 0; x < new_w; ++x)
                temp[x * new_h + y] = data[y * new_w + x];
        data = temp;
    }
    vector<Complex> local_cols(cols_per_proc * new_h);
    MPI_Scatter(data.data(), cols_per_proc * new_h * 2, MPI_DOUBLE,
                local_cols.data(), cols_per_proc * new_h * 2, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    for (int x = 0; x < cols_per_proc; ++x) {
        vector<Complex> col(new_h);
        for (int y = 0; y < new_h; ++y) col[y] = local_cols[x * new_h + y];
        fft1d(col);
        for (int y = 0; y < new_h; ++y) local_cols[x * new_h + y] = col[y];
    }
    MPI_Gather(local_cols.data(), cols_per_proc * new_h * 2, MPI_DOUBLE,
               data.data(), cols_per_proc * new_h * 2, MPI_DOUBLE, 0, MPI_COMM_WORLD);

    // ---- Step 3: Apply GHPF (rank 0, data is still transposed: shape new_w x new_h) ----
    if (rank == 0) {
        // Transpose back to row-major (new_h x new_w) before applying filter
        vector<Complex> temp(new_w * new_h);
        for (int x = 0; x < new_w; ++x)
            for (int y = 0; y < new_h; ++y)
                temp[y * new_w + x] = data[x * new_h + y];
        data = temp;

        int cx = new_w / 2, cy = new_h / 2;
        double d0 = 10.0;
        for (int y = 0; y < new_h; ++y)
            for (int x = 0; x < new_w; ++x) {
                double d2 = (double)(x - cx) * (x - cx) + (double)(y - cy) * (y - cy);
                double h = 1.0 - exp(-d2 / (2.0 * d0 * d0));
                data[y * new_w + x] *= h;
            }

        // Transpose again for col scatter
        vector<Complex> temp2(new_w * new_h);
        for (int y = 0; y < new_h; ++y)
            for (int x = 0; x < new_w; ++x)
                temp2[x * new_h + y] = data[y * new_w + x];
        data = temp2;
    }

    // ---- Step 4: Inverse Col IFFT ----
    MPI_Scatter(data.data(), cols_per_proc * new_h * 2, MPI_DOUBLE,
                local_cols.data(), cols_per_proc * new_h * 2, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    for (int x = 0; x < cols_per_proc; ++x) {
        vector<Complex> col(new_h);
        for (int y = 0; y < new_h; ++y) col[y] = local_cols[x * new_h + y];
        ifft1d(col);
        for (int y = 0; y < new_h; ++y) local_cols[x * new_h + y] = col[y];
    }
    MPI_Gather(local_cols.data(), cols_per_proc * new_h * 2, MPI_DOUBLE,
               data.data(), cols_per_proc * new_h * 2, MPI_DOUBLE, 0, MPI_COMM_WORLD);

    // ---- Step 5: Inverse Row IFFT ----
    if (rank == 0) {
        // Transpose back to row-major
        vector<Complex> temp(new_w * new_h);
        for (int x = 0; x < new_w; ++x)
            for (int y = 0; y < new_h; ++y)
                temp[y * new_w + x] = data[x * new_h + y];
        data = temp;
    }
    MPI_Scatter(data.data(), rows_per_proc * new_w * 2, MPI_DOUBLE,
                local_rows.data(), rows_per_proc * new_w * 2, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    for (int y = 0; y < rows_per_proc; ++y) {
        vector<Complex> row(new_w);
        for (int x = 0; x < new_w; ++x) row[x] = local_rows[y * new_w + x];
        ifft1d(row);
        for (int x = 0; x < new_w; ++x) local_rows[y * new_w + x] = row[x];
    }
    MPI_Gather(local_rows.data(), rows_per_proc * new_w * 2, MPI_DOUBLE,
               data.data(), rows_per_proc * new_w * 2, MPI_DOUBLE, 0, MPI_COMM_WORLD);

    // ---- Output ----
    if (rank == 0) {
        double t_end = MPI_Wtime();
        cout << "FFT Arch3 (Dist Dynamic/Scatter-Gather) Time: " << (t_end - t_start) << " s.\n";

        float max_edge = 0.0f;
        for (int i = 0; i < new_w * new_h; ++i) {
            float mag = sqrt(data[i].real() * data[i].real() + data[i].imag() * data[i].imag());
            if (mag > max_edge) max_edge = mag;
        }
        vector<unsigned char> out(new_w * new_h);
        for (int i = 0; i < new_w * new_h; ++i) {
            float mag = sqrt(data[i].real() * data[i].real() + data[i].imag() * data[i].imag());
            out[i] = (unsigned char)(255.0f * mag / max_edge);
        }
        stbi_write_png(out_path, new_w, new_h, 1, out.data(), new_w);
    }

    MPI_Finalize();
    return 0;
}