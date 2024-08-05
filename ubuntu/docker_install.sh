#!/bin/bash

set -e

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please run it with sudo or as root."
    exit 1
fi

# Update and install prerequisite packages
sudo apt-get update
sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Add Docker’s official GPG key
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Set up the Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update the package index
sudo apt-get update

# Install Docker Engine, Docker CLI, and Docker Compose
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Start Docker service
sudo systemctl start docker

# Enable Docker to start at boot
sudo systemctl enable docker

# Add the current user to the Docker group
sudo usermod -aG docker $USER

# Print Docker version to verify installation
docker --version

echo "Docker installation completed successfully."

# Reboot optionally
read -p "Do you want to reboot now? (y/n): " reboot_choice
if [ "$reboot_choice" == "y" ]; then
    sudo reboot
fi

echo "Please log out and log back in to apply Docker group changes for use. Recommend reboot when ready."