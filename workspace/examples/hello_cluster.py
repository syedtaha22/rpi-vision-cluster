from mpi4py import MPI
import socket
import sys

comm = MPI.COMM_WORLD
rank = comm.Get_rank()
size = comm.Get_size()
name = socket.gethostname()


print(f"Hello from rank {rank} of {size} on host {name}")

# This is the line where it hangs. 
# We move the data into a variable on ALL ranks.
all_names = comm.allgather(name)

if rank == 0:
    print(f"Success! Cluster nodes found: {all_names}")

# Finalize explicitly
MPI.Finalize()