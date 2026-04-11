#pragma once
#include <complex>
#include <vector>
#include <cmath>

using Complex = std::complex<double>;

inline int next_power_of_2(int n) {
    int p = 1;
    while (p < n) p *= 2;
    return p;
}

inline void fft1d(std::vector<Complex>& x) {
    int n = x.size();
    int logn = __builtin_ctz(n); 

    // Bit-reversal permutation
    for (int i = 1, j = 0; i < n; i++) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(x[i], x[j]);
    }

    for (int stage = 1; stage <= logn; stage++) {
        int butterfly_size = 1 << stage;
        int butterfly_split = butterfly_size / 2;
        int num_of_butterflies = n / butterfly_size;

        for (int butterfly = 0; butterfly < num_of_butterflies; butterfly++) {
            int base = butterfly * butterfly_size;

            double angle_step = -2.0 * M_PI / butterfly_size;
            double wr = 1.0, wi = 0.0;
            double step_r = cos(angle_step);
            double step_i = sin(angle_step);

            for (int k = 0; k < butterfly_split; k++) {
                int index1 = base + k;
                int index2 = index1 + butterfly_split;

                double t_real = x[index2].real() * wr - x[index2].imag() * wi;
                double t_imag = x[index2].real() * wi + x[index2].imag() * wr;

                double u_real = x[index1].real();
                double u_imag = x[index1].imag();

                x[index1] = Complex(u_real + t_real, u_imag + t_imag);
                x[index2] = Complex(u_real - t_real, u_imag - t_imag);

                double new_wr = wr * step_r - wi * step_i;
                wi = wr * step_i + wi * step_r;
                wr = new_wr;
            }
        }
    }
}

inline void ifft1d(std::vector<Complex>& x) {
    int n = x.size();
    for (auto& val : x) val = std::conj(val);
    fft1d(x);
    for (auto& val : x) {
        val = std::conj(val);
        val /= n;
    }
}
