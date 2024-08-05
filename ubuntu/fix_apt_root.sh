#!/bin/bash

set -e

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please run it with sudo or as root."
    exit 1
fi

echo "Beginning Ubuntu 22.04 Base Setup"
sleep 2
echo "Fixing Root APT Sandbox Error"
echo 'APT::Sandbox::User "root";' | sudo tee -a /etc/apt/apt.conf.d/10sandbox
echo "Root APT Issue Resolved"
echo "Updating System and Upgrading"
sleep 2
sudo apt-get update -y && sudo apt upgrade -y

# reboot
sudo reboot now