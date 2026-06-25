#!/usr/bin/env bash
# =========================================================================================
# Automated AdGuard Home (LXC) Installation for Proxmox VE 9+
# =========================================================================================
# This script creates an ultra-lightweight LXC container using the Debian template,
# configures the network, and runs the official AdGuard Home installation.
# =========================================================================================

set -e # Exit immediately if a command exits with a non-zero status

echo -e "\n🟢 Starting the Proxmox 9 AdGuard Home LXC Builder..."

# 1. Basic Variable Collection
read -p "Enter the numeric ID for the new LXC (e.g., 105): " CT_ID
read -p "Enter the network bridge interface (e.g., vmbr1 for Lab, or vmbr0 for LAN): " CT_BRIDGE
read -p "Enter the static IP with CIDR (e.g., 10.0.0.53/24) or 'dhcp': " CT_IP
if [ "$CT_IP" != "dhcp" ]; then
    read -p "Enter the Gateway (e.g., 10.0.0.1): " CT_GW
fi

CT_NAME="AdGuard-Home"
CT_RAM=512
CT_CORES=1
CT_DISK=4

# 2. Update and Download the Debian Template
echo -e "\n⏳ Updating Proxmox template list..."
pveam update >/dev/null

echo "⏳ Fetching the default Debian template..."
TEMPLATE=$(pveam available -section system | grep 'debian-12-standard\|debian-13-standard' | awk '{print $2}' | tail -n 1)

if [ -z "$TEMPLATE" ]; then
    echo "❌ Error: Debian template not found in Proxmox."
    exit 1
fi

echo "📥 Downloading $TEMPLATE (This may take a few minutes)..."
pveam download local $TEMPLATE >/dev/null

# 3. Build the LXC Container
echo -e "\n🛠️ Building LXC Container $CT_ID..."
if [ "$CT_IP" == "dhcp" ]; then
    pct create $CT_ID local:vztmpl/$(basename $TEMPLATE) \
        --ostype debian --arch amd64 \
        --hostname $CT_NAME \
        --cores $CT_CORES --memory $CT_RAM --swap 0 \
        --rootfs local-lvm:${CT_DISK} \
        --net0 name=eth0,bridge=${CT_BRIDGE},ip=dhcp \
        --unprivileged 1 \
        --features nesting=1
else
    pct create $CT_ID local:vztmpl/$(basename $TEMPLATE) \
        --ostype debian --arch amd64 \
        --hostname $CT_NAME \
        --cores $CT_CORES --memory $CT_RAM --swap 0 \
        --rootfs local-lvm:${CT_DISK} \
        --net0 name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW} \
        --unprivileged 1 \
        --features nesting=1
fi

# 4. Initialization and Configuration
echo "🚀 Starting the LXC..."
pct start $CT_ID
echo "⏳ Waiting for the network to come up (10 seconds)..."
sleep 10

echo "📦 Updating packages in the container and installing curl/sudo..."
pct exec $CT_ID -- apt-get update -y >/dev/null
pct exec $CT_ID -- apt-get install -y curl sudo >/dev/null

# 5. Official AdGuard Home Installation
echo "🛡️ Installing AdGuard Home..."
pct exec $CT_ID -- bash -c "curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v"

# 6. Conclusion
echo -e "\n======================================================================"
echo "✅ Installation Completed Successfully on Proxmox 9!"
echo "======================================================================"
if [ "$CT_IP" == "dhcp" ]; then
    echo "Since you chose DHCP, please check your router for the assigned IP."
    echo "Access the initial setup in your browser at: http://<LXC_IP>:3000"
else
    # Extract just the IP without the CIDR notation to display the final URL
    CLEAN_IP=$(echo $CT_IP | cut -d'/' -f1)
    echo "Access the initial setup dashboard at:"
    echo "👉 http://${CLEAN_IP}:3000"
fi
echo "======================================================================"
