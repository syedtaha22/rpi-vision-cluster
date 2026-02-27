#include <mpi.h>
#include <stdio.h>
#include <cmath>

typedef struct {
    float** x_real;
    float** x_imag;
    int n;
    char flag;
} Client_data;

typedef struct {
    float* x_real;
    float* x_imag;
} Scatter_data;

typedef struct {
    float* twiddle_real;
    float* twiddle_imag;
    MPI_Win win_real;
    MPI_Win win_imag;
} Twiddle_data;

Client_data* get_client_data() {
    Client_data* data = new Client_data;

    data->flag = 'e';
    data->n = 8;
    data->x_real = (float**)malloc(sizeof(float*) * 8);
    data->x_imag = (float**)malloc(sizeof(float*) * 8);
    for (int i = 0; i < 8; i++) {
        data->x_real[i] = (float*)malloc(sizeof(float) * 8);
        data->x_imag[i] = (float*)malloc(sizeof(float) * 8);
    }

    for (int i = 0; i < 8; i++) {
        for (int j = 0; j < 8; j++) {
            data->x_real[i][j] = j;
            data->x_imag[i][j] = 0;
        }
    }

    return data;
}

void removeClient_data(Client_data* data) {
    for (int i = 0; i < data->n; i++) {
        free(data->x_real[i]);
        free(data->x_imag[i]);
    }
    free(data->x_real);
    free(data->x_imag);
    delete data;
}

float* flatten(float** matrix, int size) {
    float* flat = (float*)malloc(sizeof(float) * size * size);
    for (int i = 0; i < size; i++)
        for (int j = 0; j < size; j++)
            flat[i * size + j] = matrix[i][j];
    return flat;
}

float** expand(float* flat, int size) {
    float** matrix = (float**)malloc(sizeof(float*) * size);
    for (int i = 0; i < size; i++) {
        matrix[i] = (float*)malloc(sizeof(float) * size);
        for (int j = 0; j < size; j++)
            matrix[i][j] = flat[i * size + j];
    }
    return matrix;
}

Twiddle_data* generate_twiddle_factors(int n, bool inverse) {
    MPI_Comm shared_comm;
    MPI_Comm_split_type(MPI_COMM_WORLD, MPI_COMM_TYPE_SHARED, 0, 
                        MPI_INFO_NULL, &shared_comm);

    float* twiddle_real;
    float* twiddle_imag;
    MPI_Win win, win2;

    // only rank 0 of shared_comm allocates, others get size 0
    int shared_rank;
    MPI_Comm_rank(shared_comm, &shared_rank);
    MPI_Aint size = (shared_rank == 0) ? n/2 * sizeof(float) : 0;

    MPI_Win_allocate_shared(size, sizeof(float), MPI_INFO_NULL,
                            shared_comm, &twiddle_real, &win);
    MPI_Win_allocate_shared(size, sizeof(float), MPI_INFO_NULL,
                            shared_comm, &twiddle_imag, &win2);

    // other ranks get pointer to rank 0's memory
    if (shared_rank != 0) {
        MPI_Aint sz; int disp;
        MPI_Win_shared_query(win, 0, &sz, &disp, &twiddle_real);
        MPI_Win_shared_query(win2, 0, &sz, &disp, &twiddle_imag);
    }
    // now all ranks on same Pi point to same twiddle array

    if (shared_rank == 0) {
        for (int k = 0; k < n/2; k++) {
            float angle = -2.0 * M_PI * k / n;
            if (inverse) angle = -angle;
            twiddle_real[k] = cos(angle);
            twiddle_imag[k] = sin(angle);
        }
    }
    // wait for shared rank 0 to finish writing twiddle factors before any rank reads
    MPI_Barrier(shared_comm);

    Twiddle_data* data = new Twiddle_data;
    data->twiddle_real = twiddle_real;
    data->twiddle_imag = twiddle_imag;
    data->win_real = win;
    data->win_imag = win2;

    return data;
}

void free_twiddle_data(Twiddle_data* data) {
    MPI_Win_free(&data->win_real);
    MPI_Win_free(&data->win_imag);
    delete data;
}

unsigned int reverse_bits(unsigned int x, int log2n) {
    unsigned int n = 0;
    for (int i = 0; i < log2n; i++) {
        n = (n << 1) | (x & 1);
        x >>= 1;
    }
    return n;
}

void bit_reverse_array(float* x_real, float* x_imag, int n) {
    for (int i = 0; i < n; i++) {
        unsigned int rev = reverse_bits(i, (int)log2(n));
        if (rev > i) {
            float temp_real = x_real[i];
            float temp_imag = x_imag[i];
            x_real[i] = x_real[rev];
            x_imag[i] = x_imag[rev];
            x_real[rev] = temp_real;
            x_imag[rev] = temp_imag;
        }

    }
}

void butteryfly(float* x_real, float* x_imag, float* twiddle_real, float* twiddle_imag, int n) {
    
    int logn = (int)log2(n);

    for (int stage = 1; stage <= logn; stage++) {
        
        int butterfly_size = 1 << stage;
        int butterfly_split = butterfly_size/2;
        int num_of_butterflies = n/butterfly_size;

        for (int butterfly = 1; butterfly <= num_of_butterflies; butterfly++) {
            for (int k = 0; k < butterfly_split; k++) {
                int index1 = (butterfly - 1) * butterfly_size + k;
                int index2 = index1 + butterfly_split;

                int twiddle_index = k * (n / butterfly_size);

                float t_real =  x_real[index2] * twiddle_real[twiddle_index] - x_imag[index2] * twiddle_imag[twiddle_index];
                float t_imag =  x_real[index2] * twiddle_imag[twiddle_index] + x_imag[index2] * twiddle_real[twiddle_index];

                float u_real = x_real[index1];
                float u_imag = x_imag[index1];

                x_real[index1] = u_real + t_real;
                x_imag[index1] = u_imag + t_imag;
                x_real[index2] = u_real - t_real;
                x_imag[index2] = u_imag - t_imag;
            }

        }
    }
}

void fft_1d(float* x_real, float* x_imag, float* twiddle_real, float* twiddle_imag, int n) {
    bit_reverse_array(x_real, x_imag, n);
    butteryfly(x_real, x_imag, twiddle_real, twiddle_imag, n);
}

int main(int argc, char** argv) {

    MPI_Init(NULL, NULL);
    int world_size;
    MPI_Comm_size(MPI_COMM_WORLD, &world_size);
    int world_rank;
    MPI_Comm_rank(MPI_COMM_WORLD, &world_rank);

    int rows_per_process;
    int n;
    Scatter_data scatter_data;
    Client_data* client_data;
    if (world_rank == 0) {          // add socket listener code here later, set scatter_data based on client input
        client_data = get_client_data();
        // nxn matrix, size = n
        n = client_data->n;
        // n/world_size rows per process
        rows_per_process = n / world_size;
        // flatten the 2D array
        // 1 2 3 4
        // 5 6 7 8
        // 1 2 3 4
        // 5 6 7 8
        // becomes [1 2 3 4 5 6 7 8 1 2 3 4 5 6 7 8]
        scatter_data.x_real = flatten(client_data->x_real, n);
        scatter_data.x_imag = flatten(client_data->x_imag, n);
    }

    // tell all processors the size of the matrix and rows per process they will receive
    MPI_Bcast(&n, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(&rows_per_process, 1, MPI_INT, 0, MPI_COMM_WORLD);

    // allocate space for each process to receive its portion of the matrix
    float* real_local = (float*)malloc(sizeof(float) * rows_per_process * n);
    float* imag_local = (float*)malloc(sizeof(float) * rows_per_process * n);

    // scatter the data to all processes
    MPI_Scatter(scatter_data.x_real, rows_per_process * n, MPI_FLOAT, real_local, rows_per_process * n, MPI_FLOAT, 0, MPI_COMM_WORLD);
    MPI_Scatter(scatter_data.x_imag, rows_per_process * n, MPI_FLOAT, imag_local, rows_per_process * n, MPI_FLOAT, 0, MPI_COMM_WORLD);

    // generate twiddle factors
    // local 0 processor computes, rest share memory
    Twiddle_data* twiddle_data = generate_twiddle_factors(n, false);
    for (int i = 0; i < rows_per_process; i++) {
        fft_1d(&real_local[i * n], &imag_local[i * n], twiddle_data->twiddle_real, twiddle_data->twiddle_imag, n);
    }

    // gather results back to root process
    MPI_Gather(real_local, rows_per_process * n, MPI_FLOAT, scatter_data.x_real, rows_per_process * n, MPI_FLOAT, 0, MPI_COMM_WORLD);
    MPI_Gather(imag_local, rows_per_process * n, MPI_FLOAT, scatter_data.x_imag, rows_per_process * n, MPI_FLOAT, 0, MPI_COMM_WORLD);

    if (world_rank == 0) {
        // expand the flattened result back to 2D array
        float** x_real_result = expand(scatter_data.x_real, n);
        float** x_imag_result = expand(scatter_data.x_imag, n);

        printf("FFT Result (real part):\n");
        for (int i = 0; i < n; i++) {
            for (int j = 0; j < n; j++) {
                printf("%.2f ", x_real_result[i][j]);
            }
            printf("\n");
        }

        printf("\nFFT Result (imaginary part):\n");
        for (int i = 0; i < n; i++) {
            for (int j = 0; j < n; j++) {
                printf("%.2f ", x_imag_result[i][j]);
            }
            printf("\n");
        }

        // free expanded arrays
        for (int i = 0; i < n; i++) {
            free(x_real_result[i]);
            free(x_imag_result[i]);
        }
        {free(x_real_result);
        free(x_imag_result);
        removeClient_data(client_data);
        free(scatter_data.x_real);
        free(scatter_data.x_imag);}
    }

    {free(real_local);
    free(imag_local);
    free_twiddle_data(twiddle_data);
    MPI_Finalize();}
    return 0;
}