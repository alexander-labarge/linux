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
LDAP_IMAGE="osixia/openldap"
LDAP_ADMIN_IMAGE="osixia/phpldapadmin"
GERRIT_PORT_HTTP="8080"
GERRIT_PORT_SSH="29418"
GERRIT_HOSTNAME="$SUBDOMAIN"
LDAP_ADMIN_PASSWORD="secret"
LDAP_ADMIN_HOSTNAME="ldap"
LDAP_PHPLDAPADMIN_PORT="6443"
LDAP_PORT="389"
LDAP_SSL_PORT="636"

# Function to print messages
function print_message() {
  echo "--------------------------------"
  echo $1
  echo "--------------------------------"
}

# Update and install required packages
sudo apt update
sudo apt install -y docker.io docker-compose

# Add user to the Docker group
sudo groupadd docker
sudo usermod -aG docker $USER

# Apply group membership changes
newgrp docker <<EONG

# Create Docker Compose file
cat > docker-compose.yml <<EOF
version: '3'

services:
  gerrit:
    image: $GERRIT_IMAGE:$GERRIT_VERSION
    hostname: $GERRIT_HOSTNAME
    ports:
      - "$GERRIT_PORT_SSH:29418"
      - "$GERRIT_PORT_HTTP:8080"
    depends_on:
      - ldap
    volumes:
      - gerrit-etc:/var/gerrit/etc
      - gerrit-git:/var/gerrit/git
      - gerrit-db:/var/gerrit/db
      - gerrit-index:/var/gerrit/index
      - gerrit-cache:/var/gerrit/cache
    environment:
      - CANONICAL_WEB_URL=http://$SUBDOMAIN
    # command: init

  ldap:
    image: $LDAP_IMAGE
    ports:
      - "$LDAP_PORT:389"
      - "$LDAP_SSL_PORT:636"
    environment:
      - LDAP_ADMIN_PASSWORD=$LDAP_ADMIN_PASSWORD
    volumes:
      - ldap-var:/var/lib/ldap
      - ldap-etc:/etc/ldap/slapd.d

  ldap-admin:
    image: $LDAP_ADMIN_IMAGE
    ports:
      - "$LDAP_PHPLDAPADMIN_PORT:443"
    environment:
      - PHPLDAPADMIN_LDAP_HOSTS=$LDAP_ADMIN_HOSTNAME

volumes:
  gerrit-etc:
  gerrit-git:
  gerrit-db:
  gerrit-index:
  gerrit-cache:
  ldap-var:
  ldap-etc:
EOF

# Pull Docker images
print_message "Pulling Docker images"
docker-compose pull

# Start Docker Compose services
print_message "Starting Docker Compose services"
docker-compose up -d

# Wait for Gerrit to be ready
print_message "Waiting for Gerrit to be ready (this may take a few minutes)..."
until docker logs gerrit 2>&1 | grep -q "Gerrit Code Review .* ready"; do
  sleep 10
done

print_message "Gerrit is ready. Access it at http://$GERRIT_HOSTNAME:$GERRIT_PORT_HTTP"

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
  - hostname: $SUBDOMAIN
    service: http://localhost:$GERRIT_PORT_HTTP
  - hostname: $SUBDOMAIN
    service: ssh://localhost:$GERRIT_PORT_SSH
  - service: http_status:404
EOF

# Route DNS
cloudflared tunnel route dns nginx-tunnel $DOMAIN
cloudflared tunnel route dns nginx-tunnel $SUBDOMAIN

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

EONG

# Set up Gerrit configuration files
print_message "Setting up Gerrit configuration files"
sudo mkdir -p /external/gerrit/etc
sudo tee /external/gerrit/etc/gerrit.config > /dev/null <<EOF
[gerrit]
  basePath = git

[index]
  type = LUCENE

[auth]
  type = ldap
  gitBasicAuth = true

[ldap]
  server = ldap://ldap
  username=cn=admin,dc=example,dc=org
  accountBase = dc=example,dc=org
  accountPattern = (&(objectClass=person)(uid=\${username}))
  accountFullName = displayName
  accountEmailAddress = mail

[sendemail]
  smtpServer = localhost

[sshd]
  listenAddress = *:29418

[httpd]
  listenUrl = http://*:8080/

[cache]
  directory = cache

[container]
  user = root
EOF

sudo tee /external/gerrit/etc/secure.config > /dev/null <<EOF
[ldap]
  password = $LDAP_ADMIN_PASSWORD
EOF

# Initialize Gerrit DB and Git repositories
print_message "Initializing Gerrit DB and Git repositories"
docker-compose stop gerrit
docker-compose run gerrit init
docker-compose up -d

print_message "Setup complete. Access Gerrit at http://$GERRIT_HOSTNAME:$GERRIT_PORT_HTTP"
print_message "Access phpLDAPadmin at https://localhost:$LDAP_PHPLDAPADMIN_PORT"
