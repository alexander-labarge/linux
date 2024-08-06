#!/bin/bash

# Check if the script is run as root
if [ "$(id -u)" -ne 0; then
  echo "This script must be run as root"
  exit 1
fi

# URL for Visual Studio Code Insider
URL="https://code.visualstudio.com/sha/download?build=insider&os=linux-deb-x64"

# Temporary file for the downloaded package
TEMP_DEB="$(mktemp /tmp/vscode-insider-XXXXXX.deb)"

# Download the package
echo "Downloading Visual Studio Code Insider..."
wget -O "$TEMP_DEB" "$URL"

# Install the package
echo "Installing Visual Studio Code Insider..."
sudo apt install -y "$TEMP_DEB"

# Clean up
rm -f "$TEMP_DEB"

echo "Visual Studio Code Insider installation completed successfully."
