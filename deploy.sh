#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/AlirezaSayyari/V2rayTGE/main}"
GH_REPO="${GH_REPO:-AlirezaSayyari/V2rayTGE}"

INSTALL_DIR="/opt/tge"
BIN_DIR="/usr/local/bin"

# Docker install: only via get.docker.com when docker is missing (Ubuntu).

FAST_INSTALL="${FAST_INSTALL:-0}"                 # 1=stop apt background services temporarily (opt-in)
APT_LOCK_TIMEOUT_SEC="${APT_LOCK_TIMEOUT_SEC:-600}"
APT_LOCK_POLL_SEC="${APT_LOCK_POLL_SEC:-5}"
TGE_FIREWALL_BACKEND="${TGE_FIREWALL_BACKEND:-legacy}"
TGE_CLI_VERSION="${TGE_CLI_VERSION:-v1.0.0}"
TGE_CLI_BRANCH="${TGE_CLI_BRANCH:-main}"
TGE_CLI_CHANNEL="${TGE_CLI_CHANNEL:-latest}"
FIREWALL_SWITCHED=0


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

read_prompt(){
  local __var_name="$1"; shift
  local __prompt="$*"
  local __ans=""

  if [[ -r /dev/tty ]]; then
    read -r -p "$__prompt" __ans < /dev/tty || true
  elif [[ -t 0 ]]; then
    read -r -p "$__prompt" __ans || true
  else
    return 1
  fi

  printf -v "$__var_name" '%s' "$__ans"
  return 0
}


discover_cli_metadata(){
  local rel_json tag branch_guess
  branch_guess="$(echo "$REPO_RAW" | awk -F'/' '{print $NF}')"
  [[ -n "$branch_guess" ]] || branch_guess="main"

  # Respect explicit user-provided values
  if [[ "${TGE_CLI_BRANCH:-}" == "main" && "$branch_guess" != "main" ]]; then
    TGE_CLI_BRANCH="$branch_guess"
  fi

  # Auto-detect only when still default-like
  if [[ "${TGE_CLI_VERSION:-}" == "v1.0.0" || "${TGE_CLI_CHANNEL:-}" == "latest" ]]; then
    rel_json="$(curl -fsSL "https://api.github.com/repos/${GH_REPO}/releases/latest" 2>/dev/null || true)"
    if [[ -n "$rel_json" ]]; then
      tag="$(echo "$rel_json" | jq -r '.tag_name // empty' 2>/dev/null || true)"
      if [[ -n "$tag" ]]; then
        [[ "${TGE_CLI_VERSION:-}" == "v1.0.0" ]] && TGE_CLI_VERSION="$tag"
        [[ "${TGE_CLI_CHANNEL:-}" == "latest" ]] && TGE_CLI_CHANNEL="stable"
      fi
    fi
  fi

  # Fallback channel/version when release metadata is unavailable
  if [[ "${TGE_CLI_VERSION:-}" == "v1.0.0" ]]; then
    TGE_CLI_VERSION="dev-${TGE_CLI_BRANCH}"
  fi
}

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
  if ! [[ "$APT_LOCK_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || (( APT_LOCK_TIMEOUT_SEC < 1 )); then
    APT_LOCK_TIMEOUT_SEC=600
  fi
  if (( APT_LOCK_TIMEOUT_SEC > 600 )); then
    warn "APT_LOCK_TIMEOUT_SEC capped to 600s."
    APT_LOCK_TIMEOUT_SEC=600
  fi
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
      err "Try again later, or set FAST_INSTALL=1 to stop apt background services and retry."
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

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi
  if [[ "${ID:-}" != "ubuntu" ]]; then
    err "Docker auto-install is supported only on Ubuntu. Install Docker manually and re-run deploy."
    return 1
  fi

  install_docker_getdocker || return 1
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

Optional (if alternatives exist):
  sudo update-alternatives --set iptables-save /usr/sbin/iptables-legacy-save
  sudo update-alternatives --set iptables-restore /usr/sbin/iptables-legacy-restore
  sudo update-alternatives --set ip6tables-save /usr/sbin/ip6tables-legacy-save
  sudo update-alternatives --set ip6tables-restore /usr/sbin/ip6tables-legacy-restore

If nft rules are active in production, schedule a maintenance window first.
EOF
}

firewall_backend_mode(){
  local mode="${TGE_FIREWALL_BACKEND:-legacy}"
  mode="$(echo "$mode" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$mode" ]] && mode="legacy"
  echo "$mode"
}

set_alternative_optional(){
  local name="$1" target="$2"
  if ! update-alternatives --query "$name" >/dev/null 2>&1; then
    warn "[firewall] optional alternative missing: $name"
    return 0
  fi
  if [[ ! -x "$target" ]]; then
    warn "[firewall] optional target missing for $name: $target"
    return 0
  fi
  update-alternatives --set "$name" "$target" || true
}

restart_docker_if_running(){
  have_cmd systemctl || return 0
  systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service' || return 0
  if systemctl is-active --quiet docker; then
    log "[firewall] restarting docker service after backend switch..."
    systemctl restart docker || warn "[firewall] docker restart failed; restart manually."
  fi
}

enforce_legacy_firewall_backend(){
  local b4 b6
  b4="$(iptables_backend_kind iptables)"
  b6="$(iptables_backend_kind ip6tables)"
  if [[ "$b4" == "legacy" && ( "$b6" == "legacy" || "$b6" == "missing" ) ]]; then
    log "[firewall] backend already legacy (iptables=$b4 ip6tables=$b6)."
    return 0
  fi

  if ! have_cmd update-alternatives; then
    err "[firewall] update-alternatives not found; cannot enforce legacy backend safely."
    print_legacy_backend_instructions
    return 60
  fi
  if [[ ! -x /usr/sbin/iptables-legacy ]]; then
    err "[firewall] /usr/sbin/iptables-legacy not found."
    print_legacy_backend_instructions
    return 60
  fi
  if have_cmd ip6tables && [[ ! -x /usr/sbin/ip6tables-legacy ]]; then
    err "[firewall] /usr/sbin/ip6tables-legacy not found."
    print_legacy_backend_instructions
    return 60
  fi

  if nft_ruleset_nonempty; then
    warn "[firewall] active nft ruleset detected."
    warn "[firewall] Switching to legacy is still possible, but reboot is required after apply."
  fi

  echo "[firewall] Commands to apply:"
  echo "  update-alternatives --set iptables /usr/sbin/iptables-legacy"
  if have_cmd ip6tables; then
    echo "  update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy"
  fi
  echo "  optional: iptables-save/restore and ip6tables-save/restore -> legacy targets"

  if [[ "${TGE_ASSUME_YES:-0}" != "1" ]]; then
    if [[ -r /dev/tty || -t 0 ]]; then
      local confirm
      read_prompt confirm "[firewall] Switch backend to legacy now (recommended)? [Y/n]: " || true
      confirm="${confirm:-Y}"
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        warn "[firewall] switch canceled by user."
        print_legacy_backend_instructions
        return 64
      fi
    else
      err "[firewall] non-interactive mode cannot confirm backend switch."
      err "[firewall] set TGE_ASSUME_YES=1 to allow non-interactive switch."
      print_legacy_backend_instructions
      return 64
    fi
  fi

  log "[firewall] switching backend to legacy..."
  update-alternatives --set iptables /usr/sbin/iptables-legacy
  if have_cmd ip6tables; then
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
  fi
  set_alternative_optional iptables-save /usr/sbin/iptables-legacy-save
  set_alternative_optional iptables-restore /usr/sbin/iptables-legacy-restore
  set_alternative_optional ip6tables-save /usr/sbin/ip6tables-legacy-save
  set_alternative_optional ip6tables-restore /usr/sbin/ip6tables-legacy-restore

  b4="$(iptables_backend_kind iptables)"
  b6="$(iptables_backend_kind ip6tables)"
  if [[ "$b4" != "legacy" || ( "$b6" != "legacy" && "$b6" != "missing" ) ]]; then
    err "[firewall] backend verification failed: iptables=$b4 ip6tables=$b6"
    return 62
  fi

  log "[firewall] backend enforced: legacy."
  FIREWALL_SWITCHED=1
}

firewall_backend_preflight(){
  local mode
  mode="$(firewall_backend_mode)"
  case "$mode" in
    legacy|nft) ;;
    *)
      err "[firewall] invalid TGE_FIREWALL_BACKEND=$mode (use legacy|nft)"
      return 2
      ;;
  esac

  if [[ "$mode" == "nft" ]]; then
    warn "[firewall] TGE_FIREWALL_BACKEND=nft selected (advanced/experimental)."
    warn "[firewall] no alternatives switch will be performed."
    log "[firewall] current backend: iptables=$(iptables_backend_kind iptables) ip6tables=$(iptables_backend_kind ip6tables)"
    return 0
  fi

  enforce_legacy_firewall_backend || return $?
  restart_docker_if_running || true
}


prompt_reboot_after_backend_switch(){
  [[ "${FIREWALL_SWITCHED:-0}" == "1" ]] || return 0

  echo
  warn "[firewall] backend was changed to legacy. Reboot is required before continuing install."
  warn "After reboot, run this command again:"
  warn "curl -fsSL $REPO_RAW/deploy.sh | sudo bash"
  local ans="n"
  if [[ -r /dev/tty || -t 0 ]]; then
    read_prompt ans "Reboot now? [y/N]: " || true
  else
    warn "No interactive TTY detected. Reboot was not triggered automatically."
  fi

  if [[ "$ans" =~ ^[Yy]$ ]]; then
    log "Rebooting now..."
    reboot
  else
    warn "Please reboot the server now."
    warn "After server is up, run: curl -fsSL $REPO_RAW/deploy.sh | sudo bash"

  fi
  exit 0
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
cat > /opt/v2raytge/meta.env <<EOF
TGE_CLI_VERSION="$TGE_CLI_VERSION"
TGE_CLI_BRANCH="$TGE_CLI_BRANCH"
TGE_CLI_CHANNEL="$TGE_CLI_CHANNEL"
EOF
  chmod 0644 /opt/v2raytge/meta.env
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
- If Docker exists & works, deploy does NOT reinstall Docker.
- If Docker is missing on Ubuntu, deploy installs via get.docker.com.

Firewall backend mode:
- Default recommended: TGE_FIREWALL_BACKEND=legacy
- Advanced/experimental: TGE_FIREWALL_BACKEND=nft

Examples:
  curl -fsSL $REPO_RAW/deploy.sh | sudo bash
  curl -fsSL $REPO_RAW/deploy.sh | sudo FAST_INSTALL=1 bash
  curl -fsSL $REPO_RAW/deploy.sh | sudo TGE_FIREWALL_BACKEND=nft bash

EOF
}

main(){
  need_root

  stop_apt_background_services

  apt_update
  log "Installing base dependencies..."
  apt_install ca-certificates curl jq iproute2 iptables lsof wireguard-tools >/dev/null

  # Required order: Docker -> backend preflight -> Compose -> deploy/start v2rayA -> finalize TGE install.
  ensure_docker
  firewall_backend_preflight
  prompt_reboot_after_backend_switch
  ensure_compose
  mkdir -p /opt/v2raytge/docker
  curl -fsSL "$REPO_RAW/tge/docker/docker-compose.yml" -o /opt/v2raytge/docker/docker-compose.yml
  sed -i 's/\r$//' /opt/v2raytge/docker/docker-compose.yml
  cd /opt/v2raytge/docker
  docker compose up -d
  discover_cli_metadata
  install_files

  start_apt_background_services
  post_notes
}

main "$@"
