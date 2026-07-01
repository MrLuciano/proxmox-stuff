#!/usr/bin/env bash
# =========================================================================================
# Automated ai-memory (Arch Linux LXC) Installation for Proxmox VE 9+
# =========================================================================================
# This script creates an Arch Linux LXC container, installs ai-memory
# via native AUR package, and configures it as a system service with
# Gemini LLM, web UI, and bearer-token auth for LAN access.
# =========================================================================================
# ai-memory: Long-term memory for AI coding agents
# https://github.com/akitaonrails/ai-memory
# =========================================================================================

set -e

echo -e "\n Starting the Proxmox 9 ai-memory LXC Builder..."

# 1. Automatic ID Collection and User Variables
CT_ID=$(pvesh get /cluster/nextid)
echo " Next available ID found: $CT_ID"

read -p "Network bridge interface (e.g., vmbr0, vmbr1) [Default: vmbr1]: " INPUT_BRIDGE < /dev/tty
CT_BRIDGE=${INPUT_BRIDGE:-vmbr1}

read -p "Static IP with CIDR (e.g., 10.0.0.90/24) or dhcp [Default: dhcp]: " INPUT_IP < /dev/tty
CT_IP=${INPUT_IP:-dhcp}

if [ "$CT_IP" != "dhcp" ]; then
    read -p "Gateway (e.g., 10.0.0.1): " CT_GW < /dev/tty
    CLEAN_IP=$(echo "$CT_IP" | cut -d'/' -f1)
else
    CLEAN_IP="(DHCP - check your router)"
fi

CT_NAME="ai-memory-lab"
CT_RAM=1024
CT_CORES=1
CT_DISK=8

read -p "Gemini API Key (leave blank to configure later): " GEMINI_API_KEY < /dev/tty

# 2. Smart Template Management
echo -e "\n Checking for existing Arch Linux templates in Proxmox..."

LOCAL_TEMPLATE=$(pveam list local 2>/dev/null | grep -i 'archlinux' | awk '{print $1}' | tail -n 1) || true

if [ -n "$LOCAL_TEMPLATE" ]; then
    echo " Local template found: $LOCAL_TEMPLATE (Skipping download)"
    TEMPLATE_PATH="$LOCAL_TEMPLATE"
else
    echo " No local Arch Linux template found. Fetching from official repositories..."
    pveam update >/dev/null
    ONLINE_TEMPLATE=$(pveam available -section system | grep -i 'archlinux' | awk '{print $2}' | tail -n 1)

    if [ -z "$ONLINE_TEMPLATE" ]; then
        echo " Error: No Arch Linux template found online or locally."
        exit 1
    fi

    echo " Downloading $ONLINE_TEMPLATE to local storage..."
    pveam download local "$ONLINE_TEMPLATE" >/dev/null
    TEMPLATE_PATH="local:vztmpl/$(basename "$ONLINE_TEMPLATE")"
fi

# 3. Build the LXC Container
echo -e "\n Building LXC Container $CT_ID..."
if [ "$CT_IP" == "dhcp" ]; then
    pct create "$CT_ID" "$TEMPLATE_PATH" \
        --ostype archlinux --arch amd64 \
        --hostname "$CT_NAME" \
        --cores "$CT_CORES" --memory "$CT_RAM" --swap 0 \
        --rootfs "local-lvm:${CT_DISK}" \
        --net0 name=eth0,bridge="${CT_BRIDGE}",ip=dhcp \
        --unprivileged 1 \
        --features nesting=1
else
    pct create "$CT_ID" "$TEMPLATE_PATH" \
        --ostype archlinux --arch amd64 \
        --hostname "$CT_NAME" \
        --cores "$CT_CORES" --memory "$CT_RAM" --swap 0 \
        --rootfs "local-lvm:${CT_DISK}" \
        --net0 name=eth0,bridge="${CT_BRIDGE}",ip="${CT_IP}",gw="${CT_GW}" \
        --unprivileged 1 \
        --features nesting=1
fi

# 4. OS Initialization
echo " Starting the LXC..."
pct start "$CT_ID"
echo " Waiting for the OS to boot (20 seconds)..."
sleep 20

echo " Updating Arch Linux and installing build tools..."
pct exec "$CT_ID" -- pacman -Sy --noconfirm archlinux-keyring >/dev/null 2>&1 || true
pct exec "$CT_ID" -- pacman -Syu --noconfirm >/dev/null 2>&1 || true
pct exec "$CT_ID" -- pacman -S --noconfirm base-devel git >/dev/null

echo " Creating build user for AUR package installation..."
pct exec "$CT_ID" -- useradd -m builduser
pct exec "$CT_ID" -- bash -c "echo 'builduser ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers"

echo " Installing yay-bin (prebuilt AUR helper)..."
pct exec "$CT_ID" -- su - builduser -c "git clone --depth=1 https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm"

echo " Installing ai-memory-bin from AUR..."
pct exec "$CT_ID" -- yay -S --noconfirm ai-memory-bin

# 5. Configure ai-memory System Service
echo " Setting up ai-memory system service..."
pct exec "$CT_ID" -- systemd-sysusers /usr/lib/sysusers.d/ai-memory.conf 2>/dev/null || true
pct exec "$CT_ID" -- systemd-tmpfiles --create /usr/lib/tmpfiles.d/ai-memory.conf 2>/dev/null || true

echo " Writing ai-memory config..."
pct exec "$CT_ID" -- mkdir -p /etc/ai-memory

# Build allowed_hosts based on whether we know the IP
if [ "$CT_IP" != "dhcp" ]; then
    ALLOWED_HOSTS="[\"$CLEAN_IP\", \"localhost\", \"127.0.0.1\"]"
else
    ALLOWED_HOSTS="[\"localhost\", \"127.0.0.1\"]"
fi

TEMP_CONFIG=$(mktemp)
cat > "$TEMP_CONFIG" << EOF
bind = "0.0.0.0:49374"
allowed_hosts = $ALLOWED_HOSTS
EOF
pct push "$CT_ID" "$TEMP_CONFIG" /etc/ai-memory/config.toml
rm -f "$TEMP_CONFIG"

echo " Initializing ai-memory data directory..."
pct exec "$CT_ID" -- sudo -u ai-memory ai-memory \
    --data-dir /var/lib/ai-memory \
    --config /etc/ai-memory/config.toml \
    init

echo " Generating auth token and writing secrets..."
AUTH_TOKEN=$(pct exec "$CT_ID" -- ai-memory generate-auth-token | tr -d '\n\r')

TEMP_ENV=$(mktemp)
cat > "$TEMP_ENV" << EOF
AI_MEMORY_AUTH_TOKEN=${AUTH_TOKEN}
AI_MEMORY_LLM_PROVIDER=gemini
AI_MEMORY_ENABLE_WEB=true
EOF

if [ -n "$GEMINI_API_KEY" ]; then
    echo "GEMINI_API_KEY=${GEMINI_API_KEY}" >> "$TEMP_ENV"
fi

pct push "$CT_ID" "$TEMP_ENV" /etc/ai-memory/env
rm -f "$TEMP_ENV"

pct exec "$CT_ID" -- chmod 600 /etc/ai-memory/env

echo " Enabling and starting ai-memory service..."
pct exec "$CT_ID" -- systemctl enable --now ai-memory.service

# 6. Conclusion and Credentials Display
echo -e "\n======================================================================"
echo " ai-memory Lab Server Installation Completed Successfully!"
echo "======================================================================"
echo " LXC ID:      $CT_ID"
echo " Hostname:    $CT_NAME"
echo " Web UI:      http://${CLEAN_IP}:49374/web"
echo " MCP:         http://${CLEAN_IP}:49374/mcp"
echo " Auth Token:  $AUTH_TOKEN"
if [ -n "$GEMINI_API_KEY" ]; then
    echo " Gemini LLM:  configured"
else
    echo " Gemini LLM:  NOT configured (edit /etc/ai-memory/env and restart ai-memory.service)"
fi
echo ""
echo " Client setup (on your laptop/workstation):"
echo "   export AI_MEMORY_SERVER_URL=http://${CLEAN_IP}:49374"
echo "   export AI_MEMORY_AUTH_TOKEN=${AUTH_TOKEN}"
echo "   ai-memory install-mcp   --client <agent> --apply"
echo "   ai-memory install-hooks --agent  <agent> --apply"
echo ""
echo " For Claude Code, Codex, OpenCode, Cursor, Gemini CLI, etc."
echo " See: https://github.com/akitaonrails/ai-memory"
echo "======================================================================"
