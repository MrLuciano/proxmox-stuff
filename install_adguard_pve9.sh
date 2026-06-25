#!/usr/bin/env bash
# =========================================================================================
# Automated AdGuard Home (LXC) Installation for Proxmox VE 9+ (Optimized)
# =========================================================================================
# This script creates a lightweight LXC container using the Debian template,
# configures the network, checks for local templates to save bandwidth, 
# and runs the official AdGuard Home installation.
# =========================================================================================

set -e # Exit immediately if a command exits with a non-zero status

echo -e "\n🟢 Starting the Proxmox 9 AdGuard Home LXC Builder..."

# 1. Automatic ID Collection and User Variables
CT_ID=$(pvesh get /cluster/nextid)
echo "👉 Next available ID found: $CT_ID"

read -p "Network bridge interface (e.g., vmbr0, vmbr1) [Default: vmbr1]: " INPUT_BRIDGE < /dev/tty
CT_BRIDGE=${INPUT_BRIDGE:-vmbr1}

read -p "Static IP with CIDR (e.g., 10.0.0.53/24) or dhcp [Default: dhcp]: " INPUT_IP < /dev/tty
CT_IP=${INPUT_IP:-dhcp}

if [ "$CT_IP" != "dhcp" ]; then
    read -p "Gateway (e.g., 10.0.0.1): " CT_GW < /dev/tty
fi

CT_NAME="AdGuard-Home"
CT_RAM=512
CT_CORES=1
CT_DISK=4

# 2. Smart Template Management (Avoids repeated downloads)
echo -e "\n⏳ Checking for existing Debian templates in Proxmox..."

# Scans local storage for a pre-existing Debian template (.tar.zst or .tar.gz)
LOCAL_TEMPLATE=$(pveam list local 2>/dev/null | grep -E 'debian-12|debian-13' | awk '{print $1}' | tail -n 1) || true

if [ -n "$LOCAL_TEMPLATE" ]; then
    echo "✅ Local template found: $LOCAL_TEMPLATE (Skipping download)"
    TEMPLATE_PATH="$LOCAL_TEMPLATE"
else
    echo "🔍 No local Debian 12/13 template found. Fetching from official repositories..."
    pveam update >/dev/null
    ONLINE_TEMPLATE=$(pveam available -section system | grep -E 'debian-12-standard|debian-13-standard' | awk '{print $2}' | tail -n 1)
    
    if [ -z "$ONLINE_TEMPLATE" ]; then
        echo "❌ Error: No Debian template found online or locally."
        exit 1
    fi
    
    echo "📥 Downloading $ONLINE_TEMPLATE to local storage..."
    pveam download local "$ONLINE_TEMPLATE" >/dev/null
    TEMPLATE_PATH="local:vztmpl/$(basename $ONLINE_TEMPLATE)"
fi

# 3. Build the LXC Container
echo -e "\n🛠️ Building LXC Container $CT_ID..."
if [ "$CT_IP" == "dhcp" ]; then
    pct create $CT_ID "$TEMPLATE_PATH" \
        --ostype debian --arch amd64 \
        --hostname $CT_NAME \
        --cores $CT_CORES --memory $CT_RAM --swap 0 \
        --rootfs local-lvm:${CT_DISK} \
        --net0 name=eth0,bridge=${CT_BRIDGE},ip=dhcp \
        --unprivileged 1 \
        --features nesting=1
else
    pct create $CT_ID "$TEMPLATE_PATH" \
        --ostype debian --arch amd64 \
        --hostname $CT_NAME \
        --cores $CT_CORES --memory $CT_RAM --swap 0 \
        --rootfs local-lvm:${CT_DISK} \
        --net0 name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW} \
        --unprivileged 1 \
        --features nesting=1
fi

# 4. OS Initialization and Configuration
echo "🚀 Starting the LXC..."
pct start $CT_ID
echo "⏳ Waiting for the network to come up inside the container (10 seconds)..."
sleep 10

echo "📦 Updating packages in the container and installing curl/sudo..."
pct exec $CT_ID -- apt-get update -y >/dev/null
pct exec $CT_ID -- apt-get install -y curl sudo >/dev/null

# 5. Official AdGuard Home Installation via Binary
echo "🛡️ Installing AdGuard Home..."
pct exec $CT_ID -- bash -c "curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v"

# 6. Conclusion and Credentials Display
echo -e "\n======================================================================"
echo "✅ Installation Completed Successfully on Proxmox 9!"
echo "======================================================================"
if [ "$CT_IP" == "dhcp" ]; then
    echo "Since you chose DHCP, please check your router for the assigned IP."
    echo "Access the initial setup in your browser at: http://<LXC_IP>:3000"
else
    CLEAN_IP=$(echo $CT_IP | cut -d'/' -f1)
    echo "Access the initial setup dashboard at:"
    echo "👉 http://${CLEAN_IP}:3000"
fi
echo "======================================================================"

