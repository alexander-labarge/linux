#!/bin/bash

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root"
  exit 1
fi

# Create the user
USERNAME="skywalker"
PASSWORD="skywalker"  # You can change this to a more secure password or prompt for one

# Check if the user already exists
if id "$USERNAME" &>/dev/null; then
  echo "User $USERNAME already exists."
  exit 1
fi

# Create the user and set the password
useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

# Inform the user about the created account
echo "User $USERNAME has been created with the specified password."

# Expire the password to force a change on first login
passwd -e "$USERNAME"

# Add user to the sudo group
echo "Adding $USERNAME to the sudo group..."
usermod -aG sudo "$USERNAME"

# Additional steps (optional):
# Add the user to specific groups
# usermod -aG sudo "$USERNAME"

echo "User $USERNAME has been created successfully and will need to change the password upon first login."
