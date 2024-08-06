#!/bin/bash

# Variables
CONFIG_DIR="/etc/cloudflared"
CONFIG_FILE="$CONFIG_DIR/config.yml"
SERVICE_FILE="/etc/systemd/system/cloudflared.service"
TUNNEL_ID="6e471308-2a72-413b-8f2c-1ba9215098d9"
CREDENTIALS_FILE="$CONFIG_DIR/$TUNNEL_ID.json"
USER="skywalker"
DOMAIN="unboundos.org"
SUBDOMAIN="source.unboundos.org"
GERRIT_IMAGE="gerritcodereview/gerrit"
GERRIT_VERSION="latest"
MYSQL_ROOT_PASSWORD="rootpassword"
MYSQL_GERRIT_DB="gerrit"
MYSQL_GERRIT_USER="gerrit"
MYSQL_GERRIT_PASSWORD="gerritpassword"
GERRIT_PORT_HTTP="8080"
GERRIT_PORT_SSH="29418"

# Function to print messages
function print_message() {
  echo "--------------------------------"
  echo $1
  echo "--------------------------------"
}

# Create Docker Compose file
print_message "Creating Docker Compose file"
cat > docker-compose.yml <<EOF
version: '3'

services:
  mysql:
    image: mysql:5.7
    environment:
      MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD
      MYSQL_DATABASE: $MYSQL_GERRIT_DB
      MYSQL_USER: $MYSQL_GERRIT_USER
      MYSQL_PASSWORD: $MYSQL_GERRIT_PASSWORD
    volumes:
      - mysql-data:/var/lib/mysql
    ports:
      - "3306:3306"

  gerrit:
    image: $GERRIT_IMAGE:$GERRIT_VERSION
    depends_on:
      - mysql
    ports:
      - "$GERRIT_PORT_HTTP:8080"
      - "$GERRIT_PORT_SSH:29418"
    environment:
      - DATABASE_TYPE=mysql
      - AUTH_TYPE=LDAP
      - DATABASE_HOST=mysql
      - DATABASE_PORT=3306
      - DATABASE_DATABASE=$MYSQL_GERRIT_DB
      - DATABASE_USERNAME=$MYSQL_GERRIT_USER
      - DATABASE_PASSWORD=$MYSQL_GERRIT_PASSWORD
    volumes:
      - gerrit-data:/var/gerrit/review_site

volumes:
  mysql-data:
  gerrit-data:
EOF

# Pull Docker images
print_message "Pulling Docker images"
docker-compose pull

# Start Docker Compose services
print_message "Starting Docker Compose services"
docker-compose up -d

# Wait for Gerrit to be ready
print_message "Waiting for Gerrit to be ready (this may take a few minutes)..."
until docker logs $(docker-compose ps -q gerrit) 2>&1 | grep -q "Gerrit Code Review .* ready"; do
  sleep 10
done

print_message "Gerrit is ready. Access it at http://localhost:$GERRIT_PORT_HTTP"

# Download and install cloudflared
print_message "Downloading and installing cloudflared"
curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared.deb

# Authenticate and create tunnel
print_message "Authenticating with Cloudflare and creating tunnel"
cloudflared tunnel login
cloudflared tunnel create nginx-tunnel

# Create and configure the tunnel YAML file
print_message "Creating and configuring the tunnel YAML file"
cat > /home/$USER/.cloudflared/nginx-tunnel.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: /home/$USER/.cloudflared/$TUNNEL_ID.json
ingress:
  - hostname: $DOMAIN
    service: http://localhost:5000
  - hostname: $SUBDOMAIN
    service: http://localhost:$GERRIT_PORT_HTTP
  - hostname: $SUBDOMAIN
    service: ssh://localhost:$GERRIT_PORT_SSH
  - service: http_status:404
EOF

# Route DNS
print_message "Routing DNS"
cloudflared tunnel route dns nginx-tunnel $DOMAIN
cloudflared tunnel route dns nginx-tunnel $SUBDOMAIN

# Set permissions for the configuration files
print_message "Setting permissions for the configuration files"
chmod 644 /home/$USER/.cloudflared/nginx-tunnel.yml
chmod 600 /home/$USER/.cloudflared/$TUNNEL_ID.json

# Move configuration to /etc/cloudflared
print_message "Moving configuration to /etc/cloudflared"
sudo mkdir -p $CONFIG_DIR
sudo cp /home/$USER/.cloudflared/nginx-tunnel.yml $CONFIG_FILE
sudo cp /home/$USER/.cloudflared/$TUNNEL_ID.json $CREDENTIALS_FILE

# Create systemd service file
print_message "Creating systemd service file"
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
print_message "Reloading systemd, enabling and starting the service"
sudo systemctl daemon-reload
sudo systemctl enable cloudflared.service
sudo systemctl start cloudflared.service

# Check the status of the service
print_message "Checking the status of the service"
sudo systemctl status cloudflared.service
