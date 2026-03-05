/*
 * MPI Latency Test
 * Measures inter-node communication overhead and latency
 */

#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>

#define WARMUP_ITERATIONS 10
#define TEST_ITERATIONS 100
#define MESSAGE_SIZES 5

int main(int argc, char** argv) {
    int rank, size;
    double start_time, end_time;
    double latency, bandwidth;
    
    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    
    if (rank == 0) {
        printf("=== MPI Communication Latency Test ===\n");
        printf("Cluster Size: %d nodes\n", size);
        printf("Test Iterations: %d\n\n", TEST_ITERATIONS);
    }
    
    // Test different message sizes
    int msg_sizes[MESSAGE_SIZES] = {1, 1024, 10240, 102400, 1048576}; // 1B, 1KB, 10KB, 100KB, 1MB
    
    for (int test = 0; test < MESSAGE_SIZES; test++) {
        int msg_size = msg_sizes[test];
        char* send_buffer = (char*)malloc(msg_size);
        char* recv_buffer = (char*)malloc(msg_size);
        
        // Initialize buffer
        for (int i = 0; i < msg_size; i++) {
            send_buffer[i] = (char)(i % 256);
        }
        
        // Warmup
        for (int i = 0; i < WARMUP_ITERATIONS; i++) {
            if (rank == 0) {
                MPI_Send(send_buffer, msg_size, MPI_CHAR, 1 % size, 0, MPI_COMM_WORLD);
                MPI_Recv(recv_buffer, msg_size, MPI_CHAR, 1 % size, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            } else if (rank == 1 % size) {
                MPI_Recv(recv_buffer, msg_size, MPI_CHAR, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                MPI_Send(send_buffer, msg_size, MPI_CHAR, 0, 0, MPI_COMM_WORLD);
            }
        }
        
        MPI_Barrier(MPI_COMM_WORLD);
        
        // Actual test
        start_time = MPI_Wtime();
        
        for (int i = 0; i < TEST_ITERATIONS; i++) {
            if (rank == 0) {
                MPI_Send(send_buffer, msg_size, MPI_CHAR, 1 % size, 0, MPI_COMM_WORLD);
                MPI_Recv(recv_buffer, msg_size, MPI_CHAR, 1 % size, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            } else if (rank == 1 % size) {
                MPI_Recv(recv_buffer, msg_size, MPI_CHAR, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                MPI_Send(send_buffer, msg_size, MPI_CHAR, 0, 0, MPI_COMM_WORLD);
            }
        }
        
        end_time = MPI_Wtime();
        
        if (rank == 0) {
            double total_time = end_time - start_time;
            latency = (total_time / (2.0 * TEST_ITERATIONS)) * 1e6; // microseconds
            bandwidth = (msg_size * 2.0 * TEST_ITERATIONS) / total_time / (1024.0 * 1024.0); // MB/s
            
            if (msg_size < 1024) {
                printf("Message Size: %d B   | Latency: %.2f μs | Bandwidth: %.2f MB/s\n", 
                       msg_size, latency, bandwidth);
            } else if (msg_size < 1048576) {
                printf("Message Size: %d KB  | Latency: %.2f μs | Bandwidth: %.2f MB/s\n", 
                       msg_size / 1024, latency, bandwidth);
            } else {
                printf("Message Size: %d MB  | Latency: %.2f μs | Bandwidth: %.2f MB/s\n", 
                       msg_size / 1048576, latency, bandwidth);
            }
        }
        
        free(send_buffer);
        free(recv_buffer);
    }
    
    // All-to-all latency test
    if (size > 1) {
        MPI_Barrier(MPI_COMM_WORLD);
        
        if (rank == 0) {
            printf("\n=== All-to-All Communication Test ===\n");
        }
        
        int small_msg = 1024; // 1KB message
        char* all_send_buffer = (char*)malloc(small_msg * size);
        char* all_recv_buffer = (char*)malloc(small_msg * size);
        
        for (int i = 0; i < small_msg * size; i++) {
            all_send_buffer[i] = (char)(rank + i % 256);
        }
        
        MPI_Barrier(MPI_COMM_WORLD);
        start_time = MPI_Wtime();
        
        for (int i = 0; i < TEST_ITERATIONS / 10; i++) {
            MPI_Alltoall(all_send_buffer, small_msg, MPI_CHAR,
                        all_recv_buffer, small_msg, MPI_CHAR,
                        MPI_COMM_WORLD);
        }
        
        end_time = MPI_Wtime();
        
        if (rank == 0) {
            double total_time = end_time - start_time;
            double avg_time = (total_time / (TEST_ITERATIONS / 10)) * 1e6; // microseconds
            printf("All-to-All (1KB × %d): %.2f μs per operation\n", size, avg_time);
        }
        
        free(all_send_buffer);
        free(all_recv_buffer);
    }
    
    // Broadcast latency test
    MPI_Barrier(MPI_COMM_WORLD);
    
    if (rank == 0) {
        printf("\n=== Broadcast Latency Test ===\n");
    }
    
    for (int test = 0; test < 3; test++) {
        int bcast_sizes[3] = {1024, 102400, 1048576}; // 1KB, 100KB, 1MB
        int bcast_size = bcast_sizes[test];
        char* bcast_buffer = (char*)malloc(bcast_size);
        
        if (rank == 0) {
            for (int i = 0; i < bcast_size; i++) {
                bcast_buffer[i] = (char)(i % 256);
            }
        }
        
        MPI_Barrier(MPI_COMM_WORLD);
        start_time = MPI_Wtime();
        
        for (int i = 0; i < TEST_ITERATIONS / 10; i++) {
            MPI_Bcast(bcast_buffer, bcast_size, MPI_CHAR, 0, MPI_COMM_WORLD);
        }
        
        end_time = MPI_Wtime();
        
        if (rank == 0) {
            double total_time = end_time - start_time;
            double avg_time = (total_time / (TEST_ITERATIONS / 10)) * 1e6; // microseconds
            
            if (bcast_size < 1048576) {
                printf("Broadcast %d KB: %.2f μs per operation\n", bcast_size / 1024, avg_time);
            } else {
                printf("Broadcast %d MB: %.2f μs per operation\n", bcast_size / 1048576, avg_time);
            }
        }
        
        free(bcast_buffer);
    }
    
    if (rank == 0) {
        printf("\n=== Test Complete ===\n");
    }
    
    MPI_Finalize();
    return 0;
}
