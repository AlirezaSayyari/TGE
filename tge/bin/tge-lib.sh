#!/usr/bin/env bash

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "ERROR: sudo required"; exit 1; }; }

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

guess_primary_nic(){
  ip route show default 0.0.0.0/0 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1
}

validate_iface_exists(){
  ip link show "$1" >/dev/null 2>&1 || { echo "ERROR: interface not found: $1"; exit 1; }
}

iface_ipv4(){
  ip -4 -o addr show dev "$1" | awk '{print $4}' | cut -d/ -f1 | head -n1
}

validate_ipv4(){
  python3 - "$1" <<'PY'
import ipaddress,sys
try:
  ipaddress.IPv4Address(sys.argv[1])
except Exception:
  print("ERROR: invalid IPv4:", sys.argv[1])
  sys.exit(1)
PY
}

validate_cidr(){
  python3 - "$1" <<'PY'
import ipaddress,sys
try:
  ipaddress.ip_network(sys.argv[1], strict=False)
except Exception:
  print("ERROR: invalid CIDR:", sys.argv[1])
  sys.exit(1)
PY
}

validate_no_overlap(){
  python3 - "$@" <<'PY'
import ipaddress,sys
nets=[]
for s in sys.argv[1:]:
  n=ipaddress.ip_network(s, strict=False)
  for x in nets:
    if n.overlaps(x):
      print(f"ERROR: overlap detected: {n} overlaps {x}")
      sys.exit(1)
  nets.append(n)
print("OK")
PY
}

cidr_network(){
  python3 - "$1" <<'PY'
import ipaddress,sys
try:
  print(ipaddress.ip_network(sys.argv[1], strict=False))
except Exception:
  print("ERROR: invalid CIDR:", sys.argv[1])
  sys.exit(1)
PY
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

firewall_backend_mode(){
  local mode="${TGE_FIREWALL_BACKEND:-legacy}"
  mode="$(echo "$mode" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$mode" ]] && mode="legacy"
  echo "$mode"
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

If nft rules are currently active in production, schedule a maintenance window first.
EOF
}

restart_docker_if_running(){
  have_cmd systemctl || return 0
  systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service' || return 0
  if systemctl is-active --quiet docker; then
    echo "[firewall] restarting docker service after backend switch..."
    systemctl restart docker || {
      echo "[firewall][WARN] docker restart failed; please restart docker manually." >&2
      return 1
    }
  fi
  return 0
}

set_alternative_required(){
  local name="$1" target="$2"
  if ! update-alternatives --query "$name" >/dev/null 2>&1; then
    echo "[firewall][ERROR] update-alternatives entry not found for $name" >&2
    return 1
  fi
  update-alternatives --set "$name" "$target"
}

set_alternative_optional(){
  local name="$1" target="$2"
  if ! update-alternatives --query "$name" >/dev/null 2>&1; then
    echo "[firewall][WARN] update-alternatives entry missing for $name; skipping."
    return 0
  fi
  if [[ ! -x "$target" ]]; then
    echo "[firewall][WARN] target not found for $name: $target; skipping."
    return 0
  fi
  update-alternatives --set "$name" "$target" || {
    echo "[firewall][WARN] could not set optional alternative $name -> $target"
    return 0
  }
}

firewall_backend_preflight(){
  local mode b4 b6
  mode="$(firewall_backend_mode)"

  case "$mode" in
    legacy|nft) ;;
    *)
      echo "[firewall][ERROR] invalid TGE_FIREWALL_BACKEND=$mode (use: legacy|nft)" >&2
      return 2
      ;;
  esac

  b4="$(iptables_backend_kind iptables)"
  b6="$(iptables_backend_kind ip6tables)"

  if [[ "$mode" == "nft" ]]; then
    echo "[firewall][WARN] TGE_FIREWALL_BACKEND=nft (advanced/experimental)."
    echo "[firewall][WARN] Backend auto-switch is disabled; manual adjustments may be required."
    echo "[firewall] current backend: iptables=$b4 ip6tables=$b6"
    return 0
  fi

  if [[ "$b4" == "legacy" && ( "$b6" == "legacy" || "$b6" == "missing" ) ]]; then
    echo "[firewall] OK: backend already legacy (iptables=$b4 ip6tables=$b6)."
    return 0
  fi

  if ! have_cmd update-alternatives; then
    echo "[firewall][ERROR] update-alternatives not found; cannot enforce legacy backend." >&2
    print_legacy_backend_instructions >&2
    return 60
  fi
  if [[ ! -x /usr/sbin/iptables-legacy ]]; then
    echo "[firewall][ERROR] /usr/sbin/iptables-legacy not found." >&2
    print_legacy_backend_instructions >&2
    return 60
  fi
  if have_cmd ip6tables && [[ ! -x /usr/sbin/ip6tables-legacy ]]; then
    echo "[firewall][ERROR] /usr/sbin/ip6tables-legacy not found." >&2
    print_legacy_backend_instructions >&2
    return 60
  fi

  if nft_ruleset_nonempty; then
    echo "[firewall][ERROR] active nft ruleset detected; refusing risky auto-switch." >&2
    print_legacy_backend_instructions >&2
    return 61
  fi

  echo "[firewall] switching backend to legacy..."
  set_alternative_required iptables /usr/sbin/iptables-legacy || return 62
  if have_cmd ip6tables; then
    set_alternative_required ip6tables /usr/sbin/ip6tables-legacy || return 62
  fi

  set_alternative_optional iptables-save /usr/sbin/iptables-legacy-save
  set_alternative_optional iptables-restore /usr/sbin/iptables-legacy-restore
  set_alternative_optional ip6tables-save /usr/sbin/ip6tables-legacy-save
  set_alternative_optional ip6tables-restore /usr/sbin/ip6tables-legacy-restore

  b4="$(iptables_backend_kind iptables)"
  b6="$(iptables_backend_kind ip6tables)"
  if [[ "$b4" != "legacy" || ( "$b6" != "legacy" && "$b6" != "missing" ) ]]; then
    echo "[firewall][ERROR] backend verification failed after switch: iptables=$b4 ip6tables=$b6" >&2
    return 63
  fi

  restart_docker_if_running || true
  echo "[firewall] OK: backend enforced to legacy."
  return 0
}

validate_int_range(){
  local v="$1" min="$2" max="$3"
  [[ "$v" =~ ^[0-9]+$ ]] || { echo "ERROR: not integer: $v"; exit 1; }
  (( v >= min && v <= max )) || { echo "ERROR: out of range [$min..$max]: $v"; exit 1; }
}

join_by_comma(){
  local IFS=,
  echo "$*"
}

ensure_rt_table(){
  local id="$1" name="$2"
  grep -qE "^[[:space:]]*${id}[[:space:]]+${name}[[:space:]]*$" /etc/iproute2/rt_tables || echo "${id} ${name}" >> /etc/iproute2/rt_tables
}

# robust pref check using ip -o output
ensure_rule_pref(){
  local pref="$1"; shift
  local want_regex="$1"; shift
  local add_cmd=("$@")
  local line
  line="$(ip -o rule show 2>/dev/null | awk -v p="${pref}:" '$1==p{print; exit}')"
  if [[ -z "$line" ]]; then
    "${add_cmd[@]}"
    return 0
  fi
  echo "$line" | grep -qE "$want_regex" && return 0
  echo "[WARN] pref $pref exists but differs; not modifying. line=[$line]"
  return 0
}

iptables_ensure(){
  local table="$1" chain="$2"
  shift 2
  local spec="$*"
  iptables -t "$table" -C "$chain" $spec 2>/dev/null || iptables -t "$table" -A "$chain" $spec
}

# Backward-compatible wrapper name
iptables_legacy_ensure(){ iptables_ensure "$@"; }

# Insert MSS fix as first rule only if missing
iptables_ensure_mangle_insert_first(){
  local in_if="$1" out_if="$2" mss="$3"
  if ! iptables -t mangle -C FORWARD -i "$in_if" -o "$out_if" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss" 2>/dev/null; then
    iptables -t mangle -I FORWARD 1 -i "$in_if" -o "$out_if" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss"
  fi
}

# Backward-compatible wrapper name
iptables_legacy_ensure_mangle_insert_first(){ iptables_ensure_mangle_insert_first "$@"; }

# Safe delete helpers (NO flush)
safe_ip_rule_del(){
  local pref="$1" match="$2"
  local line
  line="$(ip -o rule show 2>/dev/null | awk -v p="${pref}:" '$1==p{print; exit}')"
  [[ -z "$line" ]] && return 0
  echo "$line" | grep -q "$match" || return 0
  ip rule del pref "$pref" || true
}

safe_ip_route_del_table(){
  local table="$1"; shift
  local spec="$*"
  ip route del table "$table" $spec 2>/dev/null || true
}

safe_iptables_del_nat(){
  local cidr="$1" outif="$2"
  iptables -t nat -D POSTROUTING -s "$cidr" -o "$outif" -j MASQUERADE 2>/dev/null || true
}

safe_iptables_del_forward(){
  local gre="$1" tun="$2"
  iptables -D FORWARD -i "$gre" -o "$tun" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$tun" -o "$gre" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
}

safe_iptables_del_mss(){
  local gre="$1" tun="$2" mss="$3"
  iptables -t mangle -D FORWARD -i "$gre" -o "$tun" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss" 2>/dev/null || true
}

# Backward-compatible alias used by older scripts.
assert_legacy_firewall_backend(){
  firewall_backend_preflight
}
