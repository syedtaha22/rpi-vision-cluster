
# Performance Metrics Analysis

This document outlines the theoretical and empirical metrics for the implemented Computer Vision baselines and FFT architectures, addressing Isoefficiency, Amdahl's Law, and Brent's Law across varying datasets (such as CIFAR, COCO, and TinyNet).

## 1. Isoefficiency ($E(f(p), p)$)
Isoefficiency measures a system's ability to maintain a constant efficiency as both the problem size ($W$, which is $O(N^2 \log N)$ for a 2D FFT on an $N \times N$ image) and the number of processors ($p$) scale.

- **Architecture 1 & 2 (Single Node OpenMP):**
  Communication overhead is minimal due to shared memory. Efficiency drops primarily because of memory bandwidth contention. The isoefficiency function $f(p)$ is small, meaning the system scales efficiently with a linear increase in problem size relative to threads.
  
- **Architecture 3 & 4 (Distributed MPI):**
  Scatter/Gather operations and node-to-node transfers require significant data movement. To maintain constant efficiency, the computation time $O(W \log W)$ must offset the network communication overhead. Network latency on a Raspberry Pi cluster becomes the bottleneck, meaning the problem size $W$ must grow exponentially relative to $p$ to maintain high efficiency (a steep isoefficiency curve).

## 2. Amdahl's Law
Amdahl's Law bounds the maximum speedup $S(p)$ based on the serial fraction of the code ($1-f$):
$$S(p) = \frac{1}{(1-f) + \frac{f}{p}}$$

In our codebase:
- **Serial Fraction ($1-f$):** Image I/O (`stbi_load`, `stbi_write_png`), zero-padding to powers of 2, allocating complex vectors, and transposing the matrix in the Master node (Arch 3).
- **Parallel Fraction ($f$):** The independent 1D FFT calculations on rows and columns.

**Dataset Impact:**
- **CIFAR (32x32):** Extremely small problem size. The serial I/O and communication overhead will dwarf the parallel FFT computation ($f$ is low). Speedup will be near 1 or even negative (slower).
- **COCO / TinyNet (e.g., 1024x1024+):** The $O(N^2 \log N)$ FFT computation becomes substantial. The parallel fraction $f$ approaches 0.95+, allowing for significant empirical speedups approaching the theoretical limit.

## 3. Brent's Law
Brent's Law states that parallel execution time $T_p$ is bounded by the total work $T_1$ and the critical path length $T_\infty$ (execution time with infinite processors):
$$T_p \le \frac{T_1}{p} + T_\infty$$

Identifying the critical path in each architecture:
- **Arch 1 (Farm - OpenMP):** 
  $T_\infty = O(N \log N)$. With infinite processors, all rows are computed in the time it takes to compute one row, followed by all columns in the time it takes to compute one column. It is highly parallelizable.
- **Arch 2 (Single Node Pipeline):** 
  Because a 2D FFT requires all rows to be processed before the column pass can begin (for a single image), the critical path is bounded by the barrier between pipeline stages. Speedup on a *single* image is constrained, but throughput on a *stream* of images approaches $T_\infty = \max(T_{rows}, T_{cols})$.
- **Arch 3 (Distributed Dynamic Scatter/Gather):** 
  $T_\infty = T_{scatter} + O(N \log N) + T_{gather} + T_{transpose} + T_{scatter} + O(N \log N) + T_{gather}$. The sequential matrix transposition on the master node heavily limits the theoretical speedup.
- **Arch 4 (Distributed Pipeline):** 
  $T_\infty = O(N^2 \log N)_{row} + T_{comm} + O(N^2 \log N)_{col}$. The critical path is simply the time for node 0 to process its part and send it to node 1. For a single image, it yields a theoretical speedup of at most 2x, minus communication overhead.