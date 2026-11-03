#!/usr/bin/env bash
# Prepare an Ubuntu host for HRMS (idempotent: safe to run on every deploy).
# Installs Docker Engine + Compose plugin, adds swap, enables the firewall (22/80/443),
# caps container log size, enables unattended security upgrades, creates /opt/hrms.
# Usage (as a sudo-capable user): sudo bash bootstrap-ec2.sh [deploy-user]
set -euo pipefail
DEPLOY_USER=${1:-${SUDO_USER:-ubuntu}}
SWAP_GB=${SWAP_GB:-2}
log() { echo "[bootstrap] $*"; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || { echo "only Ubuntu is supported (found ${ID:-unknown})" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  log "installing Docker Engine and Compose plugin"
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  log "docker present: $(docker --version)"
fi

if [ ! -f /etc/docker/daemon.json ]; then
  log "default container log rotation"
  printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "10m", "max-file": "5" }\n}\n' > /etc/docker/daemon.json
  systemctl restart docker
fi
systemctl enable --now docker >/dev/null

if id "$DEPLOY_USER" >/dev/null 2>&1 && ! id -nG "$DEPLOY_USER" | grep -qw docker; then
  log "adding $DEPLOY_USER to the docker group"; usermod -aG docker "$DEPLOY_USER"
fi

if [ "$(swapon --show --noheadings | wc -l)" -eq 0 ]; then
  log "creating ${SWAP_GB}G swap"
  fallocate -l "${SWAP_GB}G" /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

if command -v ufw >/dev/null; then
  ufw allow OpenSSH >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  if ! ufw status | grep -q 'Status: active'; then log "enabling ufw (22, 80, 443)"; ufw --force enable >/dev/null; fi
fi

if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then apt-get install -y -qq unattended-upgrades; fi
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

install -d -m 0750 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/hrms
log "ok"
