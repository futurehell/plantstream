#!/bin/bash
# Run this once on a fresh Debian 12 VM to get everything ready
set -e

echo ">>> Updating system..."
apt update && apt upgrade -y

echo ">>> Installing Docker..."
apt install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo ">>> Adding erik to docker group..."
usermod -aG docker erik

echo ">>> Installing Intel Arc / QSV drivers..."
apt install -y intel-media-va-driver-non-free libvpl2 vainfo

echo ">>> Verifying GPU access..."
vainfo || echo "WARNING: vainfo failed — check /dev/dri passthrough in Proxmox"

echo ""
echo "=== Done! ==="
echo "IMPORTANT: Log out and back in for docker group to take effect."
echo "Then cd into the plantstream folder, fill in .env, and run:"
echo "  docker compose up -d"
