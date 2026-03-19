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
    if (n <= 1) return;
    std::vector<Complex> even(n/2), odd(n/2);
    for (int i=0; i<n/2; ++i) {
        even[i] = x[i*2];
        odd[i] = x[i*2 + 1];
    }
    fft1d(even);
    fft1d(odd);
    for (int k=0; k<n/2; ++k) {
        Complex t = std::polar(1.0, -2 * M_PI * k / n) * odd[k];
        x[k] = even[k] + t;
        x[k+n/2] = even[k] - t;
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
