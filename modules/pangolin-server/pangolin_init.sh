#!/usr/bin/env bash

# Copyright © 2026 SUSE LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Cloud-init bootstrap script: installs Docker and configures Pangolin (+ Gerbil + Traefik)
# on first boot. Rendered by OpenTofu as a templatefile — variables are substituted at
# plan/apply time and must not be committed with real values.
 
set -e

pangolin_dir="/opt/pangolin"
pangolin_device="${pangolin_device}"

pangolin_docker_compose_path="$pangolin_dir/docker-compose.yml"
pangolin_docker_compose_systemd_unit_path="/etc/systemd/system/pangolin.service"

pangolin_config_dir="$pangolin_dir/config"
pangolin_config_path="$pangolin_config_dir/config.yml"

traefik_config_dir="$pangolin_config_dir/traefik"
traefik_static_config_path="$traefik_config_dir/traefik_config.yml"
traefik_dynamic_config_path="$traefik_config_dir/dynamic_config.yml"


# Wait for the EBS volume to be attached (it arrives a few seconds after the
# cloud-init script starts on Nitro instances).
echo "Waiting for $pangolin_device to become available..."
for i in $(seq 1 30); do
  [ -b "$pangolin_device" ] && break
  echo "  Device not ready yet (attempt $i/30), waiting 2s..."
  sleep 2
done
[ -b "$pangolin_device" ] || { echo "ERROR: $pangolin_device did not appear after 60s"; exit 1; }

filesystem=$(file -s $pangolin_device)
pangolin_public_ip=$(curl -s --connect-timeout 5 http://169.254.169.254/latest/meta-data/public-ipv4 || true)
pangolin_custom_domain="${pangolin_custom_domain}"

if [ -n "$pangolin_custom_domain" ]; then
  # Custom domain provided via OpenTofu variable — derive base domain by stripping
  # the first DNS label: "pangolin.example.com" → "example.com"
  pangolin_domain="$pangolin_custom_domain"
  pangolin_base_domain="$${pangolin_custom_domain#*.}"
else
  # No custom domain: use sslip.io for zero-configuration DNS.
  pangolin_base_domain="$pangolin_public_ip.sslip.io"
  pangolin_domain="pangolin.$pangolin_base_domain"
fi

pangolin_server_secret=${pangolin_server_secret}
pangolin_setup_token=${pangolin_setup_token}
owner_email=${owner_email}

if [ "$filesystem" == "$pangolin_device: data" ]; then
    echo "Initializing device $pangolin_device for the first time"
    /usr/sbin/mkfs.ext4 $pangolin_device
fi

echo "Mounting $pangolin_device to $pangolin_dir"
mkdir -p $pangolin_dir
echo "$pangolin_device  $pangolin_dir  ext4     noatime  0 0" >> /etc/fstab # Adding entry to fstab to ensure mounting in case of instance reboot
mount -a

echo "Installing docker"
# Add Docker's official GPG key:
apt update
apt install -y ca-certificates curl unattended-upgrades
install -m 0755 -d /etc/apt/keyrings

echo "Enabling automatic security updates"
# Run unattended-upgrades daily and clean the package cache weekly.
cat << 'APTEOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APTEOF

# Security-only upgrades. Reboot automatically at 04:30 when required (kernel/libc updates).
# Note: $${distro_codename} below is an apt variable escaped for templatefile; it renders
# as $${distro_codename} in the cloud-init script (i.e. apt resolves it at upgrade time).
cat << 'APTEOF' > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=$${distro_codename},label=Debian-Security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
APTEOF

systemctl enable --now unattended-upgrades

echo "Hardening SSH: key-only authentication, no passwords"
cat << 'SSHEOF' > /etc/ssh/sshd_config.d/99-hardening.conf
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
SSHEOF
systemctl restart ssh

# Pin the Docker GPG key to a known-good checksum.
# If Docker rotates the key, update this value — see:
#   https://download.docker.com/linux/debian/gpg
# To regenerate: curl -fsSL https://download.docker.com/linux/debian/gpg | sha256sum
DOCKER_GPG_SHA256="1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570"

curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
echo "$${DOCKER_GPG_SHA256}  /etc/apt/keyrings/docker.asc" | sha256sum --check --status \
  || { echo "ERROR: Docker GPG key checksum mismatch — aborting"; exit 1; }
chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "Configuring pangolin using domain $pangolin_domain" # Reference: https://docs.pangolin.net/self-host/manual/docker-compose
mkdir -p $pangolin_config_dir
mkdir -p $traefik_config_dir


echo "Creating configuration: $pangolin_docker_compose_path"
cat << EOF > $pangolin_docker_compose_path
name: pangolin
services:
  pangolin:
    image: docker.io/fosrl/pangolin:1.17.1@sha256:c8002c5acf73a6e6e85f61be38036b4eb35afeb99c4d52501c737f0257d4c673 # https://github.com/fosrl/pangolin/releases
    container_name: pangolin
    restart: unless-stopped
    environment:
      - PANGOLIN_SETUP_TOKEN=$pangolin_setup_token
    volumes:
      - ./config:/app/config
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3001/api/v1/"]
      interval: "10s"
      timeout: "10s"
      retries: 15

  gerbil:
    image: docker.io/fosrl/gerbil:1.3.1@sha256:b16a722d5603fa74acd3e1deb86cea0b8330d015ab5325dc41e44108fe6f29c9 # https://github.com/fosrl/gerbil/releases
    container_name: gerbil
    restart: unless-stopped
    depends_on:
      pangolin:
        condition: service_healthy
    command:
      - --reachableAt=http://gerbil:3004
      - --generateAndSaveKeyTo=/var/config/key
      - --remoteConfig=http://pangolin:3001/api/v1/
    volumes:
      - ./config/:/var/config
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    ports:
      - 51820:51820/udp
      - 21820:21820/udp
      - 443:443
      - 443:443/udp # For http3 QUIC if desired
      - 80:80

  traefik:
    image: docker.io/traefik:v3.6.13@sha256:34d5089d0b414945342848518b383f11f5b3a645504ed87b77ffeb9d683d0e48
    container_name: traefik
    restart: unless-stopped

    network_mode: service:gerbil # Ports appear on the gerbil service

    depends_on:
      pangolin:
        condition: service_healthy
    command:
      - --configFile=/etc/traefik/traefik_config.yml
    volumes:
      - ./config/traefik:/etc/traefik:ro # Volume to store the Traefik configuration
      - ./config/letsencrypt:/letsencrypt # Volume to store the Let's Encrypt certificates
      - ./config/traefik/logs:/var/log/traefik # Volume to store Traefik logs

networks:
  default:
    driver: bridge
    name: pangolin
    enable_ipv6: false
EOF

echo "Creating configuration: $pangolin_config_path"
cat << EOF > $pangolin_config_path
# To see all available options, please visit the docs:
# https://docs.pangolin.net/

gerbil:
    start_port: 51820
    base_endpoint: "$pangolin_domain"
    # Optional network settings (defaults shown):
    # subnet_group: "100.89.137.0/20"
    # block_size: 24
    # site_block_size: 30

app:
    dashboard_url: "https://$pangolin_domain"
    log_level: "info"
    telemetry:
        anonymous_usage: true

domains:
    domain1:
        base_domain: "$pangolin_base_domain"

server:
    secret: "$pangolin_server_secret"
    cors:
        origins: ["https://$pangolin_domain"]
        methods: ["GET", "POST", "PUT", "DELETE", "PATCH"]
        allowed_headers: ["X-CSRF-Token", "Content-Type"]
        credentials: false

flags:
    require_email_verification: false
    disable_signup_without_invite: true
    disable_user_create_org: false
    allow_raw_resources: true
EOF

echo "Creating configuration: $traefik_static_config_path"
cat << EOF > $traefik_static_config_path
api:
  insecure: true
  dashboard: true

providers:
  http:
    endpoint: "http://pangolin:3001/api/v1/traefik-config"
    pollInterval: "5s"
  file:
    filename: "/etc/traefik/dynamic_config.yml"

experimental:
  plugins:
    badger:
      moduleName: "github.com/fosrl/badger"
      version: "v1.4.0"

log:
  level: "INFO"
  format: "common"
  maxSize: 100
  maxBackups: 3
  maxAge: 3
  compress: true

certificatesResolvers:
  letsencrypt:
    acme:
      httpChallenge:
        entryPoint: web
      email: "$owner_email"
      storage: "/letsencrypt/acme.json"
      caServer: "https://acme-v02.api.letsencrypt.org/directory"

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
    transport:
      respondingTimeouts:
        readTimeout: "30m"
    http3:
      advertisedPort: 443
    http:
      tls:
        certResolver: "letsencrypt"
      encodedCharacters:
        allowEncodedSlash: true
        allowEncodedQuestionMark: true

serversTransport:
  insecureSkipVerify: true

ping:
  entryPoint: "web"
EOF

echo "Creating configuration: $traefik_dynamic_config_path"
cat << EOF > $traefik_dynamic_config_path
http:
  middlewares:
    badger:
      plugin:
        badger:
          disableForwardAuth: true
    redirect-to-https:
      redirectScheme:
        scheme: https

  routers:
    # HTTP to HTTPS redirect router
    main-app-router-redirect:
      rule: "Host(\`$pangolin_domain\`)"
      service: next-service
      entryPoints:
        - web
      middlewares:
        - redirect-to-https
        - badger

    # Next.js router (handles everything except API and WebSocket paths)
    next-router:
      rule: "Host(\`$pangolin_domain\`) && !PathPrefix(\`/api/v1\`)"
      service: next-service
      entryPoints:
        - websecure
      middlewares:
        - badger
      tls:
        certResolver: letsencrypt

    # API router (handles /api/v1 paths)
    api-router:
      rule: "Host(\`$pangolin_domain\`) && PathPrefix(\`/api/v1\`)"
      service: api-service
      entryPoints:
        - websecure
      middlewares:
        - badger
      tls:
        certResolver: letsencrypt

    # WebSocket router
    ws-router:
      rule: "Host(\`$pangolin_domain\`)"
      service: api-service
      entryPoints:
        - websecure
      middlewares:
        - badger
      tls:
        certResolver: letsencrypt

  services:
    next-service:
      loadBalancer:
        servers:
          - url: "http://pangolin:3002"  # Next.js server

    api-service:
      loadBalancer:
        servers:
          - url: "http://pangolin:3000"  # API/WebSocket server

tcp:
  serversTransports:
    pp-transport-v1:
      proxyProtocol:
        version: 1
    pp-transport-v2:
      proxyProtocol:
        version: 2
EOF

echo "Starting and enabling docker"
systemctl enable docker
systemctl start docker

cat << EOF > $pangolin_docker_compose_systemd_unit_path
[Unit]
Description=Pangolin Service

[Service]
Type=oneshot
RemainAfterExit=true
WorkingDirectory=$pangolin_dir
ExecStart=docker compose up -d --remove-orphans
ExecStop=docker compose down

[Install]
WantedBy=multi-user.target
EOF

echo "Starting pangolin"
systemctl daemon-reload
systemctl enable pangolin
systemctl start pangolin
