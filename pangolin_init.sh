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

# This script dumps some etcd info.
# Mainly this is used to detect and debug conflicts managing resources.
 
set -e

pangolin_dir="/opt/pangolin"
pangolin_device="/dev/nvme1n1"

pangolin_docker_compose_path="$pangolin_dir/docker-compose.yml"
pangolin_docker_compose_systemd_unit_path="/etc/systemd/system/pangolin.service"

pangolin_config_dir="$pangolin_dir/config"
pangolin_config_path="$pangolin_config_dir/config.yml"

traefik_config_dir="$pangolin_dir/traefik"
traefik_static_config_path="$traefik_config_dir/traefik_config.yml"
traefik_dynamic_config_path="$traefik_config_dir/dynamic_config.yml"

filesystem=$(file -s $pangolin_device)
pangolin_domain=$(ec2metadata --public-hostname)

#pangolin_server_secret=${pangolin_server_secret}
#owner_email=${owner_email}

pangolin_server_secret="just4now"
owner_email="andrea.mazzotti@suse.com"

if [ "$filesystem" == "$pangolin_device: data" ]; then
    echo "Initializing device $pangolin_device for the first time"
    /usr/sbin/mkfs.xfs $pangolin_device
fi

echo "Mounting $pangolin_device to $pangolin_dir"
mkdir -p $pangolin_dir
echo "$pangolin_device  $pangolin_dir  xfs     noatime  0 0" >> /etc/fstab # Adding entry to fstab to ensure mounting in case of instance reboot
mount -a

echo "Installing docker"
zypper refresh
zypper --non-interactive install docker-compose

echo "Configuring pangolin using domain $pangolin_domain" # Reference: https://docs.pangolin.net/self-host/manual/docker-compose
mkdir -p $pangolin_config_dir
mkdir -p $traefik_config_dir

if [ ! -f $pangolin_docker_compose_path ]; then
    echo "Creating initial configuration: $pangolin_docker_compose_path"
    cat << EOF > $pangolin_docker_compose_path
name: pangolin
services:
  pangolin:
    image: docker.io/fosrl/pangolin:latest # https://github.com/fosrl/pangolin/releases
    container_name: pangolin
    restart: unless-stopped
    volumes:
      - ./config:/app/config
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3001/api/v1/"]
      interval: "10s"
      timeout: "10s"
      retries: 15

  gerbil:
    image: docker.io/fosrl/gerbil:latest # https://github.com/fosrl/gerbil/releases
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
      - 80:80

  traefik:
    image: docker.io/traefik:v3.6
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
    #enable_ipv6: true # activate if your system supports IPv6
EOF
fi

if [ ! -f $pangolin_config_path ]; then
    echo "Creating initial configuration: $pangolin_config_path"
    cat << EOF > $pangolin_config_path
# To see all available options, please visit the docs:
# https://docs.pangolin.net/

gerbil:
    start_port: 51820
    base_endpoint: $pangolin_domain" # REPLACE WITH YOUR DOMAIN
    # Optional network settings (defaults shown):
    # subnet_group: "100.89.137.0/20"
    # block_size: 24
    # site_block_size: 30

app:
    dashboard_url: "https:/$pangolin_domain" # REPLACE WITH YOUR DOMAIN
    log_level: "info"
    telemetry:
        anonymous_usage: true

domains:
    domain1:
        base_domain: "$pangolin_domain" # REPLACE WITH YOUR DOMAIN
        cert_resolver: "letsencrypt"

server:
    secret: "$pangolin_server_secret"
    cors:
        origins: ["https:/$pangolin_domain"] # REPLACE WITH YOUR DOMAIN
        methods: ["GET", "POST", "PUT", "DELETE", "PATCH"]
        allowed_headers: ["X-CSRF-Token", "Content-Type"]
        credentials: false

# Optional organization network settings (defaults shown):
# orgs:
#     block_size: 24
#     subnet_group: "100.90.128.0/20"
#     utility_subnet_group: "100.96.128.0/20"

flags:
    require_email_verification: false
    disable_signup_without_invite: true
    disable_user_create_org: false
    allow_raw_resources: true
EOF
fi

if [ ! -f $traefik_static_config_path ]; then
    echo "Creating initial configuration: $traefik_static_config_path"
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
      version: "v1.3.1"

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
fi

if [ ! -f $traefik_dynamic_config_path ]; then
    echo "Creating initial configuration: $traefik_dynamic_config_path"
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
      rule: "Host($pangolin_domain\`)"
      service: next-service
      entryPoints:
        - web
      middlewares:
        - redirect-to-https
        - badger

    # Next.js router (handles everything except API and WebSocket paths)
    next-router:
      rule: "Host($pangolin_domain\`) && !PathPrefix(\`/api/v1\`)"
      service: next-service
      entryPoints:
        - websecure
      middlewares:
        - badger
      tls:
        certResolver: letsencrypt

    # API router (handles /api/v1 paths)
    api-router:
      rule: "Host($pangolin_domain\`) && PathPrefix(\`/api/v1\`)"
      service: api-service
      entryPoints:
        - websecure
      middlewares:
        - badger
      tls:
        certResolver: letsencrypt

    # WebSocket router
    ws-router:
      rule: "Host($pangolin_domain\`)"
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
fi

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
ExecStart=/usr/local/bin/docker-compose up -d --remove-orphans
ExecStop=/usr/local/bin/docker-compose down

[Install]
WantedBy=multi-user.target
EOF

echo "Starting pangolin"
systemctl daemon-reload
systemctl enable pangolin
# systemctl start pangolin #TODO: selinux 
