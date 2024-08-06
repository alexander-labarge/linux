#!/bin/bash

# Variables
CONFIG_DIR="/etc/cloudflared"
CONFIG_FILE="$CONFIG_DIR/config.yml"
SERVICE_FILE="/etc/systemd/system/cloudflared.service"
TUNNEL_ID="6e471308-2a72-413b-8f2c-1ba9215098d9"
CREDENTIALS_FILE="$CONFIG_DIR/$TUNNEL_ID.json"
USER="skywalker"
DOMAIN="unboundos.org"

# Update and install required packages
sudo apt update
sudo apt install -y docker.io

# Run NGINX in Docker
sudo docker run --name tunnel-nginx -p 5000:80 --detach nginx:latest

# Download and install cloudflared
curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared.deb

# Authenticate and create tunnel
cloudflared tunnel login
cloudflared tunnel create nginx-tunnel

# Create and configure the tunnel YAML file
cat > /home/$USER/.cloudflared/nginx-tunnel.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: /home/$USER/.cloudflared/$TUNNEL_ID.json
ingress:
  - hostname: $DOMAIN
    service: http://localhost:5000
  - service: http_status:404
EOF

# Route DNS
cloudflared tunnel route dns nginx-tunnel $DOMAIN

# Set permissions for the configuration files
chmod 644 /home/$USER/.cloudflared/nginx-tunnel.yml
chmod 600 /home/$USER/.cloudflared/$TUNNEL_ID.json

# Move configuration to /etc/cloudflared
sudo mkdir -p $CONFIG_DIR
sudo cp /home/$USER/.cloudflared/nginx-tunnel.yml $CONFIG_FILE
sudo cp /home/$USER/.cloudflared/$TUNNEL_ID.json $CREDENTIALS_FILE

# Create systemd service file
sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --config $CONFIG_FILE run $TUNNEL_ID
Restart=on-failure
RestartSec=5s
User=$USER

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable cloudflared.service
sudo systemctl start cloudflared.service

# Check the status of the service
sudo systemctl status cloudflared.service

                           