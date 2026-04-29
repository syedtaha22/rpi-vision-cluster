#!/bin/bash
# Script to setup passwordless SSH access to all worker/master nodes before running cluster.sh

# Optional, if user wants to run this script on their own device to 
# setup passwordless SSH access to all worker/master nodes before running cluster.sh
# Allow user to specify -a, which means "all nodes", otherwise it defaults to workers 1-5.

INSTALL_MASTER=false
if [[ "$1" == "-a" ]]; then
    INSTALL_MASTER=true
fi

# Install sshpass if not already installed
if ! command -v sshpass &> /dev/null; then
    echo "sshpass not found, installing..."
    sudo apt update && sudo apt install -y sshpass
fi

# Ensure key exists
[ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

# Common options to skip "Are you sure?" prompts
OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=3"

# Build Device list
DEV_LIST=()
if $INSTALL_MASTER; then
    DEV_LIST+=("rpi-master.local")
fi

for i in {1..5}; do
    DEV_LIST+=("rpi-worker$i.local")
done

for NODE in "${DEV_LIST[@]}"; do
    echo "Processing $NODE"
    USER="${NODE%%.*}"  # Extract username from hostname (e.g., rpi-worker1 from rpi-worker1.local)

    echo "  Attempting to setup passwordless SSH for $USER@$NODE"

    # Add -o BatchMode=yes to the test command
    if ssh $OPTS -o BatchMode=yes "${USER}@${NODE}" "exit" 2>/dev/null; then
        echo "  SSH Key Already Setup on $NODE"
        continue
    fi

    # 1. Push the key using the password
    sshpass -p "$USER" ssh-copy-id $OPTS "${USER}@${NODE}"
    
    # 2. Verify key-based SSH access
    ssh $OPTS "${USER}@${NODE}" "echo '  SSH Key Verified on $NODE'"
done