#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/AlirezaSayyari/V2rayTGE/main"

INSTALL_DIR="/opt/tge"
BIN_DIR="/usr/local/bin"

FAST_INSTALL="${FAST_INSTALL:-0}"                 # 1=stop apt background services temporarily (opt-in)
APT_LOCK_TIMEOUT_SEC="${APT_LOCK_TIMEOUT_SEC:-1800}"
APT_LOCK_POLL_SEC="${APT_LOCK_POLL_SEC:-10}"

# Docker install policy:
#  - auto (default): try ubuntu docker.io, if fails -> fallback to get.docker.com
#  - ubuntu: only ubuntu repo docker.io
#  - getdocker: only get.docker.com
DOCKER_INSTALL_MODE="${DOCKER_INSTALL_MODE:-auto}"

log(){ echo -e "\e[32m[deploy]\e[0m $*"; }
warn(){ echo -e "\e[33m[deploy][WARN]\e[0m $*"; }
err(){ echo -e "\e[31m[deploy][ERR]\e[0m $*"; }

need_root(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Run as root (sudo)."
    exit 1
  fi
}

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

# -----------------------------
# APT LOCK HANDLING (safe)
# -----------------------------
apt_locked(){
  lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && return 0 || true
  lsof /var/lib/dpkg/lock >/dev/null 2>&1 && return 0 || true
  lsof /var/cache/apt/archives/lock >/dev/null 2>&1 && return 0 || true
  return 1
}

show_lock_holders(){
  echo "---- lock holders (best-effort) ----"
  lsof /var/lib/dpkg/lock-frontend 2>/dev/null | sed -n '1,10p' || true
  lsof /var/lib/dpkg/lock          2>/dev/null | sed -n '1,10p' || true
  lsof /var/cache/apt/archives/lock 2>/dev/null | sed -n '1,10p' || true
  echo "-----------------------------------"
}

wait_for_apt_lock(){
  local start now elapsed
  start="$(date +%s)"

  if apt_locked; then
    warn "apt/dpkg lock detected. Waiting up to ${APT_LOCK_TIMEOUT_SEC}s (poll=${APT_LOCK_POLL_SEC}s)."
    warn "We will NOT kill processes and will NOT remove lock files."
    show_lock_holders
  fi

  while apt_locked; do
    now="$(date +%s)"
    elapsed=$((now - start))
    if (( elapsed >= APT_LOCK_TIMEOUT_SEC )); then
      err "Timed out waiting for apt/dpkg lock after ${elapsed}s."
      err "Try again later, or set FAST_INSTALL=1, or increase APT_LOCK_TIMEOUT_SEC."
      show_lock_holders
      exit 50
    fi
    warn "still locked... elapsed=${elapsed}s"
    sleep "${APT_LOCK_POLL_SEC}"
  done
}

# -----------------------------
# FAST MODE (opt-in)
# -----------------------------
stop_apt_background_services(){
  [[ "$FAST_INSTALL" == "1" ]] || return 0
  warn "FAST_INSTALL=1: stopping apt background services temporarily (best-effort)."
  systemctl stop unattended-upgrades.service 2>/dev/null || true
  systemctl stop apt-daily.service 2>/dev/null || true
  systemctl stop apt-daily-upgrade.service 2>/dev/null || true
  systemctl stop packagekit.service 2>/dev/null || true
  systemctl reset-failed unattended-upgrades.service apt-daily.service apt-daily-upgrade.service packagekit.service 2>/dev/null || true
}

start_apt_background_services(){
  [[ "$FAST_INSTALL" == "1" ]] || return 0
  warn "FAST_INSTALL=1: starting apt background services back (best-effort)."
  systemctl start apt-daily.service 2>/dev/null || true
  systemctl start apt-daily-upgrade.service 2>/dev/null || true
  systemctl start unattended-upgrades.service 2>/dev/null || true
  systemctl start packagekit.service 2>/dev/null || true
}

# -----------------------------
# APT helpers
# -----------------------------
apt_update(){
  wait_for_apt_lock
  DEBIAN_FRONTEND=noninteractive apt-get update -y
}

apt_install(){
  wait_for_apt_lock
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# -----------------------------
# Docker install strategies
# -----------------------------
docker_ok(){
  have_cmd docker || return 1
  docker version >/dev/null 2>&1 || return 1
  return 0
}

install_docker_ubuntu(){
  warn "Trying Docker via Ubuntu packages (docker.io)..."
  apt_install docker.io || return 1
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker_ok
}

install_docker_getdocker(){
  warn "Trying Docker via get.docker.com (Docker CE)..."
  # We do not purge/remove anything. This is for fresh servers or where ubuntu install failed.
  curl -fsSL https://get.docker.com -o /tmp/install-docker.sh
  sh /tmp/install-docker.sh --dry-run >/dev/null 2>&1 || true
  sh /tmp/install-docker.sh
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker_ok
}

ensure_docker(){
  if docker_ok; then
    log "Docker is already installed and working. Skipping Docker installation."
    return 0
  fi

  case "$DOCKER_INSTALL_MODE" in
    ubuntu)
      install_docker_ubuntu || return 1
      ;;
    getdocker)
      install_docker_getdocker || return 1
      ;;
    auto)
      if install_docker_ubuntu; then
        return 0
      fi
      warn "Ubuntu docker.io install failed (often containerd conflicts). Falling back to get.docker.com..."
      install_docker_getdocker || return 1
      ;;
    *)
      err "Unknown DOCKER_INSTALL_MODE=$DOCKER_INSTALL_MODE (use: auto|ubuntu|getdocker)"
      return 1
      ;;
  esac
}

ensure_compose(){
  if docker_ok && docker compose version >/dev/null 2>&1; then
    log "docker compose is available."
    return 0
  fi

  warn "docker compose not detected. Trying to install docker-compose-plugin (best-effort)."
  apt_install docker-compose-plugin >/dev/null 2>&1 || true

  if docker_ok && docker compose version >/dev/null 2>&1; then
    log "docker compose plugin installed."
    return 0
  fi

  err "docker compose is not available. Cannot continue."
  return 1
}

iptables_backend_kind(){
  local bin="$1"
  have_cmd "$bin" || { echo "missing"; return 0; }
  local v
  v="$($bin --version 2>/dev/null || true)"
  if echo "$v" | grep -qi "legacy"; then
    echo "legacy"
  elif echo "$v" | grep -qi "nf_tables"; then
    echo "nft"
  else
    echo "unknown"
  fi
}

nft_ruleset_nonempty(){
  have_cmd nft || return 1
  local n
  n="$(nft list ruleset 2>/dev/null | sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' | wc -l || echo 0)"
  [[ "${n:-0}" -gt 0 ]]
}

print_legacy_backend_instructions(){
  cat <<'EOF'
Set legacy backend safely (no flush):
  sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
  sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
  sudo update-alternatives --set arptables /usr/sbin/arptables-legacy   # if installed
  sudo update-alternatives --set ebtables /usr/sbin/ebtables-legacy     # if installed

If nft rules are active in production, schedule a maintenance window first.
EOF
}

enforce_legacy_firewall_backend(){
  local b4 b6
  b4="$(iptables_backend_kind iptables)"
  b6="$(iptables_backend_kind ip6tables)"
  if [[ "$b4" == "legacy" && "$b6" == "legacy" ]]; then
    log "Firewall backend already legacy (iptables/ip6tables)."
    return 0
  fi

  if ! have_cmd update-alternatives; then
    err "update-alternatives not found; cannot enforce legacy backend safely."
    print_legacy_backend_instructions
    return 60
  fi
  if [[ ! -x /usr/sbin/iptables-legacy || ! -x /usr/sbin/ip6tables-legacy ]]; then
    err "iptables-legacy/ip6tables-legacy binaries are missing."
    print_legacy_backend_instructions
    return 60
  fi

  if nft_ruleset_nonempty; then
    err "Detected active nft ruleset. Automatic backend switch is risky; refusing to force."
    print_legacy_backend_instructions
    return 61
  fi

  log "Switching firewall backend to legacy (iptables/ip6tables)..."
  update-alternatives --set iptables /usr/sbin/iptables-legacy
  update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
  if update-alternatives --query arptables >/dev/null 2>&1 && [[ -x /usr/sbin/arptables-legacy ]]; then
    update-alternatives --set arptables /usr/sbin/arptables-legacy || true
  fi
  if update-alternatives --query ebtables >/dev/null 2>&1 && [[ -x /usr/sbin/ebtables-legacy ]]; then
    update-alternatives --set ebtables /usr/sbin/ebtables-legacy || true
  fi

  b4="$(iptables_backend_kind iptables)"
  b6="$(iptables_backend_kind ip6tables)"
  if [[ "$b4" != "legacy" || "$b6" != "legacy" ]]; then
    err "Backend verification failed: iptables=$b4 ip6tables=$b6"
    print_legacy_backend_instructions
    return 62
  fi

  log "Firewall backend enforced: legacy."
}

# -----------------------------
# Install our files (always)
# -----------------------------
install_files(){
  log "Installing V2rayTGE files..."

  mkdir -p /opt/tge/bin
  mkdir -p /usr/local/sbin
  mkdir -p /opt/v2raytge
  mkdir -p /opt/tge/systemd
  mkdir -p /etc/systemd/system

  # Download full set
  curl -fsSL "$REPO_RAW/tge/bin/tge"        -o /opt/tge/bin/tge
  curl -fsSL "$REPO_RAW/tge/bin/tge-config" -o /opt/tge/bin/tge-config
  curl -fsSL "$REPO_RAW/tge/bin/tge-apply"  -o /opt/tge/bin/tge-apply
  curl -fsSL "$REPO_RAW/tge/bin/tge-lib.sh" -o /opt/tge/bin/tge-lib.sh
  curl -fsSL "$REPO_RAW/tge/bin/tge-ctl"        -o /opt/tge/bin/tge-ctl
  curl -fsSL "$REPO_RAW/tge/bin/tge-gre-ensure" -o /opt/tge/bin/tge-gre-ensure
  curl -fsSL "$REPO_RAW/tge/bin/tge-health"     -o /opt/tge/bin/tge-health
  curl -fsSL "$REPO_RAW/tge/bin/tge-logs"       -o /opt/tge/bin/tge-logs
  curl -fsSL "$REPO_RAW/tge/systemd/tge-gre.service"   -o /opt/tge/systemd/tge-gre.service
  curl -fsSL "$REPO_RAW/tge/systemd/tge-apply.service" -o /opt/tge/systemd/tge-apply.service
  curl -fsSL "$REPO_RAW/tge/systemd/tge-apply.path"    -o /opt/tge/systemd/tge-apply.path
  curl -fsSL "$REPO_RAW/tge/systemd/tge-apply.timer"   -o /opt/tge/systemd/tge-apply.timer

  # Normalize line endings defensively in case files were committed with CRLF.
  sed -i 's/\r$//' /opt/tge/bin/tge /opt/tge/bin/tge-config /opt/tge/bin/tge-apply /opt/tge/bin/tge-lib.sh /opt/tge/bin/tge-ctl /opt/tge/bin/tge-gre-ensure /opt/tge/bin/tge-health /opt/tge/bin/tge-logs /opt/tge/systemd/tge-gre.service /opt/tge/systemd/tge-apply.service /opt/tge/systemd/tge-apply.path /opt/tge/systemd/tge-apply.timer

  chmod +x /opt/tge/bin/tge /opt/tge/bin/tge-config /opt/tge/bin/tge-apply /opt/tge/bin/tge-ctl /opt/tge/bin/tge-gre-ensure /opt/tge/bin/tge-health /opt/tge/bin/tge-logs

  # Install to standard locations
  install -m 0755 /opt/tge/bin/tge        /usr/local/bin/tge
  install -m 0755 /opt/tge/bin/tge-config /usr/local/sbin/tge-config
  install -m 0755 /opt/tge/bin/tge-apply  /usr/local/sbin/tge-apply
  install -m 0755 /opt/tge/bin/tge-ctl        /usr/local/sbin/tge-ctl
  install -m 0755 /opt/tge/bin/tge-gre-ensure /usr/local/sbin/tge-gre-ensure
  install -m 0755 /opt/tge/bin/tge-health     /usr/local/sbin/tge-health
  install -m 0755 /opt/tge/bin/tge-logs       /usr/local/sbin/tge-logs
  install -m 0644 /opt/tge/bin/tge-lib.sh /opt/v2raytge/tge-lib.sh
  install -m 0644 /opt/tge/systemd/tge-gre.service   /etc/systemd/system/tge-gre.service
  install -m 0644 /opt/tge/systemd/tge-apply.service /etc/systemd/system/tge-apply.service
  install -m 0644 /opt/tge/systemd/tge-apply.path    /etc/systemd/system/tge-apply.path
  install -m 0644 /opt/tge/systemd/tge-apply.timer   /etc/systemd/system/tge-apply.timer
  systemctl daemon-reload

  log "Installed:"
  log "  /usr/local/bin/tge"
  log "  /usr/local/sbin/tge-config"
  log "  /usr/local/sbin/tge-apply"
  log "  /usr/local/sbin/tge-ctl"
  log "  /usr/local/sbin/tge-gre-ensure"
  log "  /usr/local/sbin/tge-health"
  log "  /usr/local/sbin/tge-logs"
  log "  /etc/systemd/system/tge-gre.service"
  log "  /etc/systemd/system/tge-apply.service"
  log "  /etc/systemd/system/tge-apply.path"
  log "  /etc/systemd/system/tge-apply.timer"
  log "  /opt/v2raytge/tge-lib.sh"
}

post_notes(){
  cat <<EOF

✅ V2rayTGE deployed.

Run:
  sudo tge

Docker install behavior:
- If Docker exists & works → deploy will NOT touch Docker.
- If Docker is missing:
    DOCKER_INSTALL_MODE=auto    → try Ubuntu docker.io then fallback to get.docker.com
    DOCKER_INSTALL_MODE=ubuntu  → only Ubuntu docker.io
    DOCKER_INSTALL_MODE=getdocker → only get.docker.com

Examples:
  curl -fsSL $REPO_RAW/deploy.sh | sudo bash
  curl -fsSL $REPO_RAW/deploy.sh | sudo FAST_INSTALL=1 bash
  curl -fsSL $REPO_RAW/deploy.sh | sudo DOCKER_INSTALL_MODE=getdocker bash

EOF
}

main(){
  need_root

  stop_apt_background_services

  apt_update
  log "Installing base dependencies..."
  apt_install ca-certificates curl jq iproute2 iptables lsof >/dev/null
  enforce_legacy_firewall_backend

  # Required order: Docker -> Compose -> deploy/start v2rayA -> finalize TGE install.
  ensure_docker
  ensure_compose
  mkdir -p /opt/v2raytge/docker
  curl -fsSL "$REPO_RAW/tge/docker/docker-compose.yml" -o /opt/v2raytge/docker/docker-compose.yml
  sed -i 's/\r$//' /opt/v2raytge/docker/docker-compose.yml
  cd /opt/v2raytge/docker
  docker compose up -d
  install_files

  start_apt_background_services
  post_notes
}

main "$@"
