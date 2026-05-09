#!/bin/bash
# =============================================================================
# init_pi.sh - Raspberry Pi Initialization for MPI Cluster
#
# Purpose:
#   - Install required packages (build tools, MPI, NFS)
#   - Set up NFS shared folder on master
#   - Mount NFS folder on worker nodes
#
# Usage:
#   Run directly on each Pi in the cluster. The script automatically detects
#   whether it's rpi-master or rpi-worker* and runs appropriate setup.
#
#   ssh rpi-master.local "~/Desktop/rpi-vision-cluster/scripts/init_pi.sh"
#   ssh rpi-worker1.local "~/Desktop/rpi-vision-cluster/scripts/init_pi.sh"
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SHARED_FOLDER="/rpi-vision-cluster"
PACKAGES_BUILD=(build-essential git make gcc g++ cmake glances)
PACKAGES_MPI=(libopenmpi-dev openmpi-bin libomp-dev)
PACKAGES_NFS_SERVER=(nfs-kernel-server nfs-common)
PACKAGES_NFS_CLIENT=(nfs-common)

# =============================================================================
# Logging helpers
# =============================================================================

log_info()    { printf "\033[0;35m$*\033[0m\n"; }
log_ok()      { printf "\033[0;32m$*\033[0m\n"; }
log_warn()    { printf "\033[0;33m$*\033[0m\n"; }
log_error()   { printf "\033[0;31m$*\033[0m\n" >&2; }

# =============================================================================
# Utilities
# =============================================================================

# Check if running as root (required for system modifications)
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Install packages, skipping if already installed
install_packages() {
    local packages=("$@")
    log_info "Installing packages: ${packages[*]}"
    
    apt-get update >/dev/null 2>&1 || true
    for pkg in "${packages[@]}"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            log_ok "$pkg already installed"
        else
            log_info "Installing $pkg..."
            apt-get install -y "$pkg"
        fi
    done
}

# Configure a permanent static IPv4 address on eth0 via netplan
set_static_eth0_ip() {
        local static_ip="$1"
        local netplan_dir="/etc/netplan"
        local netplan_file=""
        local backup_file=""

        log_info "Configuring permanent eth0 address: ${static_ip}/24"

        if [ ! -d "$netplan_dir" ]; then
                mkdir -p "$netplan_dir"
        fi

        netplan_file="$(find "$netplan_dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -exec grep -l 'eth0' {} + 2>/dev/null | head -n1 || true)"
        if [ -z "$netplan_file" ]; then
                netplan_file="$netplan_dir/99-eth0-static.yaml"
        else
                backup_file="${netplan_file}.bak.$(date +%Y%m%d%H%M%S)"
                cp "$netplan_file" "$backup_file"
                log_ok "Backed up existing netplan config to $backup_file"
        fi

        cat > "$netplan_file" <<EOF
network:
    version: 2
    ethernets:
        eth0:
            renderer: NetworkManager
            match: {}
            dhcp4: false
            dhcp6: false
            addresses:
                - ${static_ip}/24
            networkmanager:
                uuid: "75a1216a-9d1a-30cd-8aca-ace5526ec021"
                name: "netplan-eth0"
                passthrough:
                    proxy._: ""
EOF

            chown root:root "$netplan_file"
            chmod 600 "$netplan_file"

        log_info "Applying netplan configuration"
        netplan apply
        log_ok "Permanent eth0 address configured: ${static_ip}/24"
}

# =============================================================================
# Master node setup: NFS server
# =============================================================================

setup_master() {
    log_info "Setting up rpi-master as NFS server"

    # Install packages
    install_packages "${PACKAGES_BUILD[@]}" "${PACKAGES_MPI[@]}" "${PACKAGES_NFS_SERVER[@]}"

    # Create shared folder
    if [ ! -d "$SHARED_FOLDER" ]; then
        log_info "Creating shared folder: $SHARED_FOLDER"
        mkdir -p "$SHARED_FOLDER"
        chmod 777 "$SHARED_FOLDER"
    else
        log_ok "Shared folder already exists: $SHARED_FOLDER"
    fi

    # Set up NFS exports
    log_info "Configuring NFS exports"
    
    # Check if already exported
    if grep -q "^${SHARED_FOLDER}" /etc/exports 2>/dev/null; then
        log_ok "NFS export already configured"
    else
        log_info "Adding NFS export to /etc/exports"
        echo "${SHARED_FOLDER} *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
    fi

    # Export NFS shares
    log_info "Exporting NFS shares"
    exportfs -a >/dev/null 2>&1 || true

    # Restart NFS server
    log_info "Starting NFS server"
    systemctl restart nfs-kernel-server >/dev/null 2>&1 || true
    systemctl enable nfs-kernel-server >/dev/null 2>&1 || true

    log_ok "Master setup complete"
    log_info "Shared folder: $SHARED_FOLDER"
    log_info "NFS server running on rpi-master"
}

# =============================================================================
# Worker node setup: NFS client mount
# =============================================================================

setup_worker() {
    local worker_name="$1"
    log_info "Setting up $worker_name as NFS client"

    # Install packages
    install_packages "${PACKAGES_BUILD[@]}" "${PACKAGES_MPI[@]}" "${PACKAGES_NFS_CLIENT[@]}"

    # Create mount point
    if [ ! -d "$SHARED_FOLDER" ]; then
        log_info "Creating mount point: $SHARED_FOLDER"
        mkdir -p "$SHARED_FOLDER"
    else
        log_ok "Mount point already exists: $SHARED_FOLDER"
    fi

    # Mount NFS if not already mounted
    if mountpoint -q "$SHARED_FOLDER" 2>/dev/null; then
        log_ok "NFS already mounted at $SHARED_FOLDER"
    else
        log_info "Mounting NFS from rpi-master:$SHARED_FOLDER"
        
        # Wait for network to stabilize
        sleep 2
        
        if mount -t nfs -o soft,intr,retrans=3 "rpi-master.local:${SHARED_FOLDER}" "$SHARED_FOLDER" 2>/dev/null; then
            log_ok "NFS mounted successfully"
        else
            log_warn "Failed to mount NFS immediately, will try to add to fstab for next boot"
        fi
    fi

    # Add to /etc/fstab for persistence
    if grep -q "^rpi-master.local:${SHARED_FOLDER}" /etc/fstab 2>/dev/null; then
        log_ok "NFS mount already in /etc/fstab"
    else
        log_info "Adding NFS mount to /etc/fstab for persistence"
        echo "rpi-master.local:${SHARED_FOLDER} ${SHARED_FOLDER} nfs soft,intr,retrans=3 0 0" >> /etc/fstab
    fi

    log_ok "Worker setup complete"
    log_info "Mount point: $SHARED_FOLDER"
    log_info "NFS mounted from rpi-master"
}

# =============================================================================
# Optimization: Disable Wi-Fi Power Management
# =============================================================================

disable_wifi_power_management() {
    log_info "Optimizing Wi-Fi for MPI (disabling power management)..."
    
    # 1. Apply immediately if wlan0 exists
    if ip link show wlan0 >/dev/null 2>&1; then
        iwconfig wlan0 power off || log_warn "Could not set power off immediately"
        
        # 2. Make it persistent across reboots via an udev rule
        local rule_file="/etc/udev/rules.d/81-wifi-pm.rules"
        if [ ! -f "$rule_file" ]; then
            echo 'ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan0", RUN+="/sbin/iwconfig wlan0 power off"' > "$rule_file"
            log_ok "Created udev rule for persistent Wi-Fi power management"
        else
            log_ok "Persistent Wi-Fi rule already exists"
        fi
    else
        log_warn "wlan0 not found, skipping Wi-Fi optimization"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    log_info "Raspberry Pi MPI Cluster Initialization"
    
    check_root

    local hostname
    local static_ip
    hostname="$(hostname)"
    
    log_info "Hostname: $hostname"

    if [ "$hostname" = "rpi-master" ]; then
        static_ip="192.168.1.250"
        setup_master
    elif [[ "$hostname" =~ ^rpi-worker[0-9]+$ ]]; then
        static_ip="192.168.1.${hostname#rpi-worker}"
        setup_worker "$hostname"
    else
        log_error "Unknown hostname: $hostname"
        log_error "Expected 'rpi-master' or 'rpi-worker*' format"
        exit 1
    fi

    disable_wifi_power_management
    set_static_eth0_ip "$static_ip"

    echo ""
    log_ok "Initialization complete!"
}

main "$@"
