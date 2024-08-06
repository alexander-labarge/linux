#!/bin/bash

# Variables
GITLAB_HOME="/mnt/4tb/gitlab"
GITLAB_HOSTNAME="gitlab.unboundos.org"
SSH_PORT=2424
HTTP_PORT=8929

CLOUDFLARED_SERVICE_HTTP="/etc/systemd/system/cloudflared-gitlab-http.service"
CLOUDFLARED_SERVICE_SSH="/etc/systemd/system/cloudflared-gitlab-ssh.service"

# Function to stop and delete services if they exist
stop_and_delete_service() {
  local service_name=$1
  if systemctl is-active --quiet $service_name; then
    sudo systemctl stop $service_name > /dev/null 2>&1
    echo "Stopped service: $service_name"
  fi
  if systemctl is-enabled --quiet $service_name; then
    sudo systemctl disable $service_name > /dev/null 2>&1
    echo "Disabled service: $service_name"
  fi
  sudo rm -f /etc/systemd/system/$service_name > /dev/null 2>&1
  echo "Deleted service: $service_name"
}

# Stop and delete cloudflared services if they exist
stop_and_delete_service cloudflared-gitlab-http.service
stop_and_delete_service cloudflared-gitlab-ssh.service
stop_and_delete_service docker.socket
stop_and_delete_service docker
stop_and_delete_service cloudflared

# Reset environment
sudo apt-get remove -y cloudflared 
sudo apt purge -y cloudflared
sudo rm -rf /etc/cloudflared
sudo rm -rf ~/.cloudflared/
sudo docker system prune -a -f --volumes
sudo apt-get remove -y docker.io
sudo apt purge -y docker.io
sudo rm -rf /etc/apt/sources.list.d/*
sudo rm -rf $GITLAB_HOME
# Clean up Docker resources

# Update and reinstall Docker
sudo apt update
sudo apt upgrade -y
sudo apt-get install -y docker.io
sleep 3
sudo systemctl start docker

# Create directories for GitLab data and Cloudflare configuration
mkdir -p $GITLAB_HOME/config
mkdir -p $GITLAB_HOME/logs
mkdir -p $GITLAB_HOME/data
mkdir -p ~/.cloudflared

# Pull required Docker images
sudo docker pull gitlab/gitlab-ee:latest

# Download and install cloudflared
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt-get update && sudo apt-get install -y cloudflared

# Authenticate cloudflared
cloudflared tunnel login

# Delete existing tunnels if they exist
existing_tunnel_ids=$(cloudflared tunnel list | grep -E 'gitlab-http-tunnel|gitlab-ssh-tunnel' | awk '{print $1}')
for tunnel_id in $existing_tunnel_ids; do
  cloudflared tunnel delete $tunnel_id
done

# Create tunnels and store their IDs
GITLAB_HTTP_TUNNEL_ID=$(cloudflared tunnel create gitlab-http-tunnel | grep "Created tunnel" | awk '{print $NF}')
GITLAB_SSH_TUNNEL_ID=$(cloudflared tunnel create gitlab-ssh-tunnel | grep "Created tunnel" | awk '{print $NF}')

# Create YAML configuration files for tunnels
cat > ~/.cloudflared/gitlab-http-tunnel.yml <<EOF
tunnel: $GITLAB_HTTP_TUNNEL_ID
credentials-file: /home/$USER/.cloudflared/$GITLAB_HTTP_TUNNEL_ID.json
ingress:
  - hostname: $GITLAB_HOSTNAME
    service: http://localhost:$HTTP_PORT
  - service: http_status:404
EOF

cat > ~/.cloudflared/gitlab-ssh-tunnel.yml <<EOF
tunnel: $GITLAB_SSH_TUNNEL_ID
credentials-file: /home/$USER/.cloudflared/$GITLAB_SSH_TUNNEL_ID.json
ingress:
  - hostname: gitlab-ssh.unboundos.org
    service: ssh://localhost:$SSH_PORT
  - service: http_status:404
EOF

# Set permissions for the configuration files
chmod 644 ~/.cloudflared/*.yml
chmod 600 ~/.cloudflared/*.json

# Function to add DNS routes
add_dns_route() {
  local tunnel_name=$1
  local hostname=$2
  if ! cloudflared tunnel route dns $tunnel_name $hostname; then
    echo "Failed to add route: $hostname already exists. Skipping."
  fi
}

# Map DNS routes
add_dns_route gitlab-http-tunnel $GITLAB_HOSTNAME
add_dns_route gitlab-ssh-tunnel gitlab-ssh.unboundos.org

# Create systemd service files for Cloudflare tunnels
sudo bash -c "cat > $CLOUDFLARED_SERVICE_HTTP <<EOF
[Unit]
Description=Cloudflare Tunnel for GitLab HTTP
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --config /home/$USER/.cloudflared/gitlab-http-tunnel.yml run $GITLAB_HTTP_TUNNEL_ID
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF"

sudo bash -c "cat > $CLOUDFLARED_SERVICE_SSH <<EOF
[Unit]
Description=Cloudflare Tunnel for GitLab SSH
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --config /home/$USER/.cloudflared/gitlab-ssh-tunnel.yml run $GITLAB_SSH_TUNNEL_ID
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF"

# Reload systemd and enable the Cloudflare tunnel services
sudo systemctl daemon-reload
sudo systemctl enable cloudflared-gitlab-http.service
sudo systemctl enable cloudflared-gitlab-ssh.service

# Start the Cloudflare tunnel services
sudo systemctl start cloudflared-gitlab-http.service
sudo systemctl start cloudflared-gitlab-ssh.service

# Start GitLab with Docker
sudo docker run --detach \
  --hostname $GITLAB_HOSTNAME \
  --env GITLAB_OMNIBUS_CONFIG="external_url 'http://$GITLAB_HOSTNAME:$HTTP_PORT'; gitlab_rails['gitlab_default_theme'] = 2; gitlab_rails['gitlab_shell_ssh_port'] = $SSH_PORT; gitlab_rails['initial_root_password'] = 'Skywalker123!'; gitlab_rails['lfs_enabled'] = true;" \
  --publish $HTTP_PORT:$HTTP_PORT --publish $SSH_PORT:22 \
  --name gitlab-unboundos \
  --restart always \
  --volume $GITLAB_HOME/config:/etc/gitlab \
  --volume $GITLAB_HOME/logs:/var/log/gitlab \
  --volume $GITLAB_HOME/data:/var/opt/gitlab \
  --shm-size 512m \
  gitlab/gitlab-ee:latest

# Function to check if GitLab is up and running
check_gitlab_status() {
  while true; do
    status=$(sudo docker ps | grep "gitlab-unboundos" | grep "healthy")
    if [ -n "$status" ]; then
      echo "GitLab is up and running."
      break
    else
      echo "Waiting for GitLab to be healthy..."
      sleep 10
    fi
  done
}

# Check GitLab status
check_gitlab_status
echo "Gitlab with Cloudflare Setup Complete"