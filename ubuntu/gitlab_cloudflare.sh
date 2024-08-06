#!/bin/bash

# Variables
GITLAB_VERSION="latest"
GITLAB_HOME="$HOME/gitlab"
GITLAB_HOSTNAME="gitlab.unboundos.org"
SSH_PORT=2424
HTTP_PORT=8080
HTTPS_PORT=8443

# Reset environment
sudo systemctl stop docker
sudo systemctl stop cloudflared
sudo apt-get remove -y cloudflared 
sudo rm -rf /etc/cloudflared
sudo rm -rf ~/.cloudflared/
sudo rm -rf /opt/containerd/
sudo apt-get remove -y docker.io
sudo apt purge -y docker.io

# Clean up Docker resources
sudo docker system prune -a -f --volumes

# Update and reinstall Docker
sudo apt update
sudo apt upgrade -y
sudo apt-get install -y docker.io
sleep 3
sudo systemctl start docker

# Create directories for GitLab data and Cloudflare configuration
mkdir -p $GITLAB_HOME/data/config
mkdir -p $GITLAB_HOME/data/logs
mkdir -p $GITLAB_HOME/data/data
mkdir -p ~/.cloudflared

# Pull required Docker images
sudo docker pull gitlab/gitlab-ee:$GITLAB_VERSION

# Download and install cloudflared
curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared.deb

# Authenticate cloudflared
cloudflared tunnel login

# Create tunnels and store their IDs
GITLAB_HTTP_TUNNEL_ID=$(cloudflared tunnel create gitlab-http-tunnel | grep "Created tunnel" | awk '{print $NF}')
GITLAB_SSH_TUNNEL_ID=$(cloudflared tunnel create gitlab-ssh-tunnel | grep "Created tunnel" | awk '{print $NF}')

# Create YAML configuration files for tunnels
cat > ~/.cloudflared/gitlab-http-tunnel.yml <<EOF
tunnel: $GITLAB_HTTP_TUNNEL_ID
credentials-file: /home/skywalker/.cloudflared/$GITLAB_HTTP_TUNNEL_ID.json
ingress:
  - hostname: $GITLAB_HOSTNAME
    service: http://localhost:$HTTP_PORT
  - service: http_status:404
EOF

cat > ~/.cloudflared/gitlab-ssh-tunnel.yml <<EOF
tunnel: $GITLAB_SSH_TUNNEL_ID
credentials-file: /home/skywalker/.cloudflared/$GITLAB_SSH_TUNNEL_ID.json
ingress:
  - hostname: gitlab-ssh.unboundos.org
    service: ssh://localhost:$SSH_PORT
  - service: http_status:404
EOF

# Set permissions for the configuration files
chmod 644 ~/.cloudflared/*.yml
chmod 600 ~/.cloudflared/*.json

# Map DNS routes
cloudflared tunnel route dns gitlab-http-tunnel $GITLAB_HOSTNAME
cloudflared tunnel route dns gitlab-ssh-tunnel gitlab-ssh.unboundos.org

# Start Cloudflare tunnels
cloudflared tunnel --config ~/.cloudflared/gitlab-http-tunnel.yml run $GITLAB_HTTP_TUNNEL_ID &
cloudflared tunnel --config ~/.cloudflared/gitlab-ssh-tunnel.yml run $GITLAB_SSH_TUNNEL_ID &

# Change the server's SSH port
sudo sed -i "s/#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sudo systemctl restart ssh

# Create docker-compose.yml file
cat > $GITLAB_HOME/docker-compose.yml <<EOF
version: '3.6'
services:
  web:
    image: gitlab/gitlab-ee:$GITLAB_VERSION
    restart: always
    hostname: '$GITLAB_HOSTNAME'
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://$GITLAB_HOSTNAME:$HTTP_PORT'
        gitlab_rails['gitlab_shell_ssh_port'] = $SSH_PORT
        nginx['listen_port'] = $HTTP_PORT
        nginx['listen_https'] = false
        nginx['redirect_http_to_https'] = false
        nginx['ssl_port'] = $HTTPS_PORT
        unicorn['worker_processes'] = 8
        sidekiq['concurrency'] = 25
        git['max_commit_or_tag_message_size'] = 10485760  # 10MB
        git['max_file_size'] = 32212254720  # 30GB
        gitlab_shell['receive_pack_timeout'] = 1800  # 30 minutes
        gitlab_shell['upload_pack_timeout'] = 1800  # 30 minutes
    ports:
      - "$HTTP_PORT:$HTTP_PORT"
      - "$HTTPS_PORT:443"
      - "$SSH_PORT:22"
    volumes:
      - '$GITLAB_HOME/config:/etc/gitlab'
      - '$GITLAB_HOME/logs:/var/log/gitlab'
      - '$GITLAB_HOME/data:/var/opt/gitlab'
    shm_size: '256m'
EOF

# Start services with Docker Compose
cd $GITLAB_HOME
sudo docker-compose up -d

# Wait for GitLab to be fully up and running
echo "Waiting for GitLab to be fully up and running..."
until sudo docker exec $(sudo docker ps -q -f name=gitlab_web) grep "Ready" /var/log/gitlab/unicorn/current > /dev/null 2>&1; do
  sleep 10
  echo -n "."
done
echo "GitLab is up and running."

# Verify configuration
sudo docker exec -it $(sudo docker ps -q -f name=gitlab_web) bash -c "
  grep max_commit_or_tag_message_size /etc/gitlab/gitlab.rb
  grep max_file_size /etc/gitlab/gitlab.rb
  grep receive_pack_timeout /etc/gitlab/gitlab.rb
  grep upload_pack_timeout /etc/gitlab/gitlab.rb
"
