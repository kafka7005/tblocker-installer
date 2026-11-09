#!/usr/bin/env bash
# =============================================================================
#  tblocker installer for Remnawave nodes (+ Solobot webhook)
#
#  What it does (steps 1 and 3 of the manual install):
#    1. Mounts /var/log/remnanode into the remnanode container (edits
#       docker-compose.yml with a backup and validation), sets up logrotate
#    2. Removes the old apt package "tblocker" if present
#    3. Downloads tblocker from GitHub releases (verifies sha256)
#    4. Writes /opt/tblocker/config.yaml and the systemd service
#    5. Self-test: blocks the test IP 203.0.113.200 on an isolated copy
#       (webhook OFF), confirms the iptables rule appears, cleans up after itself
#    6. Starts the service and checks it is running
#
#  The Xray settings in the Remnawave panel (step 2) are done by hand — the
#  script prints the JSON to paste at the end.
#
#  Usage:
#    bash <(curl -fsSL https://raw.githubusercontent.com/kafka7005/tblocker-installer/main/install-tblocker.sh) \
#         --webhook bot.example.com
#
#  Options:
#    --webhook URL|DOMAIN  bot webhook. A bare domain becomes
#                          https://DOMAIN/tblocker/webhook
#    --no-webhook          do not send webhooks
#    --duration MIN        block duration in minutes (default 30)
#    --bypass LIST         comma-separated IPs/domains that are never blocked
#                          (e.g. cascade entry nodes)
#    --hostname NAME       server name in the webhook (default: hostname)
#    --firewall MODE       iptables (default) | nft
#    --version vX.Y.Z      tblocker version (default: latest release)
#    --log-file PATH       Xray access log (default /var/log/remnanode/access.log)
#    --node-dir DIR        remnanode folder (default /opt/remnanode)
#    --skip-node           do not touch docker-compose / the node container
#    --no-restart          do not restart the node container (only edit compose)
#    --skip-selftest       skip the self-test
#    --tarball PATH        install from a local release archive (no internet)
#    -y, --yes             ask no questions
#    --uninstall           remove tblocker completely
#    -h, --help            help
#
#  Re-running is safe: the previous config is backed up, and the webhook,
#  duration, hostname and bypass list are carried over unless new ones are given.
# =============================================================================

set -Eeuo pipefail

# ----------------------------- constants ------------------------------------
REPO="kutovoys/xray-torrent-blocker"
FALLBACK_VERSION="v1.1.0"
INSTALL_DIR="/opt/tblocker"
BIN_PATH="$INSTALL_DIR/tblocker"
CONFIG_PATH="$INSTALL_DIR/config.yaml"
SERVICE_PATH="/etc/systemd/system/tblocker.service"
LOGROTATE_PATH="/etc/logrotate.d/remnanode"
LOG_DIR_DEFAULT="/var/log/remnanode"
VOLUME_LINE="/var/log/remnanode:/var/log/remnanode"
TEST_IP="203.0.113.200"   # TEST-NET-3 (RFC 5737), not routed on the internet
CHAIN="TBLOCKER_BLOCKED"

# ----------------------------- defaults -------------------------------------
WEBHOOK=""
WEBHOOK_SET=0
NO_WEBHOOK=0
DURATION=""
BYPASS_ARG=""
HOSTNAME_ARG=""
FIREWALL="iptables"
VERSION=""
LOG_FILE="$LOG_DIR_DEFAULT/access.log"
NODE_DIR="/opt/remnanode"
SKIP_NODE=0
NO_RESTART=0
SKIP_SELFTEST=0
TARBALL=""
ASSUME_YES=0
UNINSTALL=0

TMP_DIR=""
SELFTEST_PID=""

# ----------------------------- output ---------------------------------------
if [ -t 1 ]; then
  C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[1;33m'; C_B=$'\033[0;34m'; C_0=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi
info() { printf '%s[INFO]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }

cleanup() {
  trap - ERR
  if [ -n "$SELFTEST_PID" ] && kill -0 "$SELFTEST_PID" 2>/dev/null; then
    kill "$SELFTEST_PID" 2>/dev/null || true
    wait "$SELFTEST_PID" 2>/dev/null || true
  fi
  if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
  return 0
}
trap cleanup EXIT
trap 'die "Error on line $LINENO (command: $BASH_COMMAND)"' ERR

usage() {
  cat <<'USAGE'
Usage: bash <(curl -fsSL https://raw.githubusercontent.com/kafka7005/tblocker-installer/main/install-tblocker.sh) [options]
  --webhook URL|DOMAIN   bot webhook (a bare domain -> https://DOMAIN/tblocker/webhook)
  --no-webhook           no webhooks
  --duration MIN         block duration, minutes (default 30)
  --bypass LIST          IPs/domains that are never blocked, comma-separated
  --hostname NAME        server name in the webhook
  --firewall MODE        iptables (default) | nft
  --version vX.Y.Z       tblocker version (default latest)
  --log-file PATH        Xray access log
  --node-dir DIR         remnanode folder (default /opt/remnanode)
  --skip-node            do not touch docker-compose
  --no-restart           do not restart the node container
  --skip-selftest        no self-test
  --tarball PATH         install from a local archive
  -y, --yes              ask no questions
  --uninstall            remove tblocker
USAGE
}

# Questions go through /dev/tty, so they work with bash <(curl ...) and curl | bash
HAS_TTY=0
if [ -r /dev/tty ] && [ -w /dev/tty ] && { : </dev/tty; } 2>/dev/null; then HAS_TTY=1; fi
ask() { # ask "question" default -> echoes answer
  local q="$1" def="${2:-}" ans=""
  if [ "$ASSUME_YES" -eq 1 ] || [ "$HAS_TTY" -eq 0 ]; then printf '%s' "$def"; return; fi
  printf '%s' "$q" >/dev/tty
  IFS= read -r ans </dev/tty || ans=""
  printf '%s' "${ans:-$def}"
}

# ----------------------------- arguments ------------------------------------
need_val() { [ $# -ge 2 ] && [ -n "$2" ] || die "Option $1 requires a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --webhook)       need_val "$@"; WEBHOOK="$2"; WEBHOOK_SET=1; shift 2 ;;
    --webhook=*)     WEBHOOK="${1#*=}"; WEBHOOK_SET=1; shift ;;
    --no-webhook)    NO_WEBHOOK=1; shift ;;
    --duration)      need_val "$@"; DURATION="$2"; shift 2 ;;
    --duration=*)    DURATION="${1#*=}"; shift ;;
    --bypass)        need_val "$@"; BYPASS_ARG="$2"; shift 2 ;;
    --bypass=*)      BYPASS_ARG="${1#*=}"; shift ;;
    --hostname)      need_val "$@"; HOSTNAME_ARG="$2"; shift 2 ;;
    --hostname=*)    HOSTNAME_ARG="${1#*=}"; shift ;;
    --firewall)      need_val "$@"; FIREWALL="$2"; shift 2 ;;
    --firewall=*)    FIREWALL="${1#*=}"; shift ;;
    --version)       need_val "$@"; VERSION="$2"; shift 2 ;;
    --version=*)     VERSION="${1#*=}"; shift ;;
    --log-file)      need_val "$@"; LOG_FILE="$2"; shift 2 ;;
    --log-file=*)    LOG_FILE="${1#*=}"; shift ;;
    --node-dir)      need_val "$@"; NODE_DIR="$2"; shift 2 ;;
    --node-dir=*)    NODE_DIR="${1#*=}"; shift ;;
    --skip-node)     SKIP_NODE=1; shift ;;
    --no-restart)    NO_RESTART=1; shift ;;
    --skip-selftest) SKIP_SELFTEST=1; shift ;;
    --tarball)       need_val "$@"; TARBALL="$2"; shift 2 ;;
    --tarball=*)     TARBALL="${1#*=}"; shift ;;
    -y|--yes)        ASSUME_YES=1; shift ;;
    --uninstall)     UNINSTALL=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

# ----------------------------- helpers --------------------------------------
# Like `grep -q`, but reads ALL input. With pipefail, `cmd | grep -q` fails when
# cmd gets SIGPIPE after grep exits early (e.g. lsmod with long output).
has() { grep "$@" >/dev/null; }

yaml_q() { # string -> "escaped string" for YAML
  local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"
}

# Read a scalar key from the existing config (strip quotes)
cfg_get() {
  [ -f "$CONFIG_PATH" ] || return 0
  awk -v k="$1" '
    $0 ~ "^"k":" {
      sub("^"k":[ \t]*", ""); sub(/[ \t]+#.*$/, "")
      if ($0 ~ /^".*"$/ || $0 ~ /^\x27.*\x27$/) $0 = substr($0, 2, length($0)-2)
      print; exit
    }' "$CONFIG_PATH"
}
# Read the BypassIPS list from the existing config
cfg_get_bypass() {
  [ -f "$CONFIG_PATH" ] || return 0
  awk '
    /^BypassIPS:/ { inb=1; next }
    inb && /^[ \t]*-/ { v=$0; sub(/^[ \t]*-[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v)
                       gsub(/^["\x27]|["\x27]$/, "", v); if (v != "") print v; next }
    inb && /^[ \t]*(#.*)?$/ { next }
    inb { exit }' "$CONFIG_PATH"
}

is_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a o <<<"$ip"
  for x in "${o[@]}"; do [ "$((10#$x))" -le 255 ] || return 1; done
}
is_ipv6() { [[ "$1" == *:* ]] && [[ "$1" =~ ^[0-9A-Fa-f:.]+$ ]]; }

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"
  else echo ""; fi
}

PKG=""
detect_pkg() {
  if command -v apt-get >/dev/null 2>&1; then PKG="apt"
  elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
  elif command -v yum >/dev/null 2>&1; then PKG="yum"
  else PKG=""; fi
}
APT_UPDATED=0
pkg_install() { # pkg_install <apt-name> <rpm-name>
  case "$PKG" in
    apt)
      if [ "$APT_UPDATED" -eq 0 ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null || warn "apt-get update finished with errors"
        APT_UPDATED=1
      fi
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$1" >/dev/null ;;
    dnf) dnf install -y -q "$2" >/dev/null ;;
    yum) yum install -y -q "$2" >/dev/null ;;
    *) return 1 ;;
  esac
}
ensure_cmd() { # ensure_cmd <command> <apt-pkg> <rpm-pkg>
  command -v "$1" >/dev/null 2>&1 && return 0
  info "Installing $2..."
  pkg_install "$2" "$3" || die "Could not install $2 — install it manually"
  command -v "$1" >/dev/null 2>&1 || die "Command $1 is still missing after installing $2"
}

# Remove one test/stale IP from the firewall (never touches the rest)
fw_unblock() {
  local ip="$1"
  if [ "$FIREWALL" = "iptables" ]; then
    while iptables -w -t raw -C "$CHAIN" -s "$ip" -j DROP 2>/dev/null; do
      iptables -w -t raw -D "$CHAIN" -s "$ip" -j DROP 2>/dev/null || break
    done
  else
    nft delete element inet tblocker TBLOCKER_BLOCKED_IPS "{ $ip }" 2>/dev/null || true
  fi
}
fw_has_ip() {
  local ip="$1"
  if [ "$FIREWALL" = "iptables" ]; then
    iptables -w -t raw -C "$CHAIN" -s "$ip" -j DROP 2>/dev/null
  else
    nft list set inet tblocker TBLOCKER_BLOCKED_IPS 2>/dev/null | has -w -- "$ip"
  fi
}

# ============================================================================
#  UNINSTALL
# ============================================================================
do_uninstall() {
  step "Removing tblocker"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop tblocker 2>/dev/null || true
    systemctl disable tblocker 2>/dev/null || true
  fi
  if command -v dpkg >/dev/null 2>&1 && dpkg -s tblocker >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq tblocker >/dev/null || true
  fi
  rm -f "$SERVICE_PATH"
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
  if command -v iptables >/dev/null 2>&1; then
    while iptables -w -t raw -D PREROUTING -j "$CHAIN" 2>/dev/null; do :; done
    iptables -w -t raw -F "$CHAIN" 2>/dev/null || true
    iptables -w -t raw -X "$CHAIN" 2>/dev/null || true
  fi
  if command -v nft >/dev/null 2>&1; then
    nft delete table inet tblocker 2>/dev/null || true
  fi
  rm -rf "$INSTALL_DIR"
  ok "tblocker removed: service, firewall rules and $INSTALL_DIR"
  info "The docker-compose volume, logrotate and logs in $LOG_DIR_DEFAULT were left untouched (the node needs them)."
}

# ============================================================================
#  PRE-FLIGHT CHECKS
# ============================================================================
[ "$(id -u)" -eq 0 ] || die "Run as root (sudo)."
[ "$(uname -s)" = "Linux" ] || die "Linux only."

if [ "$UNINSTALL" -eq 1 ]; then do_uninstall; exit 0; fi

step "Checking the system"
command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] \
  || die "systemd is required (no /run/systemd/system found)."

case "$(uname -m)" in
  x86_64|amd64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac
case "$FIREWALL" in iptables|nft) ;; *) die "--firewall must be iptables or nft" ;; esac
[[ "$LOG_FILE" = /* ]] || die "--log-file must be an absolute path"

detect_pkg
[ -n "$PKG" ] || warn "No package manager found (apt/dnf/yum) — dependencies must already be installed."
ok "Architecture: $ARCH, packages: ${PKG:-none}, firewall: $FIREWALL"

# ---------------- parameters (carried over from the old config) ------------
OLD_WEBHOOK="$(cfg_get WebhookURL || true)"
OLD_SEND="$(cfg_get SendWebhook || true)"
OLD_DURATION="$(cfg_get BlockDuration || true)"
OLD_HOSTNAME="$(cfg_get Hostname || true)"
mapfile -t OLD_BYPASS < <(cfg_get_bypass || true)

if [ "$NO_WEBHOOK" -eq 1 ]; then
  WEBHOOK=""
elif [ "$WEBHOOK_SET" -eq 0 ]; then
  if [ "$OLD_SEND" = "true" ] && [ -n "$OLD_WEBHOOK" ] && [[ "$OLD_WEBHOOK" != *"your-webhook-url"* ]]; then
    WEBHOOK="$OLD_WEBHOOK"
    info "Webhook taken from the existing config: $WEBHOOK"
  else
    WEBHOOK="$(ask "Bot domain for the webhook (e.g. bot.example.com, Enter = no webhook): " "")"
  fi
fi
WEBHOOK="$(printf '%s' "$WEBHOOK" | tr -d '[:space:]')"
if [ -n "$WEBHOOK" ]; then
  if [[ "$WEBHOOK" != http://* && "$WEBHOOK" != https://* ]]; then
    WEBHOOK="https://${WEBHOOK%/}/tblocker/webhook"
  fi
  [[ "$WEBHOOK" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[^\"\'\ ]*)?$ ]] \
    || die "Invalid webhook address: $WEBHOOK"
fi

if [ -z "$DURATION" ]; then
  if [[ "$OLD_DURATION" =~ ^[0-9]+$ ]] && [ "$OLD_DURATION" -gt 0 ]; then DURATION="$OLD_DURATION"; else DURATION=30; fi
fi
[[ "$DURATION" =~ ^[0-9]+$ ]] && [ "$DURATION" -ge 1 ] || die "--duration must be an integer >= 1"

if [ -n "$HOSTNAME_ARG" ]; then NODE_NAME="$HOSTNAME_ARG"
elif [ -n "$OLD_HOSTNAME" ]; then NODE_NAME="$OLD_HOSTNAME"
else NODE_NAME="$(hostname)"; fi
[[ "$NODE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid hostname: $NODE_NAME"

# Bypass list: 127.0.0.1, ::1 + old list + --bypass (domains -> IPv4)
BYPASS=("127.0.0.1" "::1")
add_bypass() { local v="$1" e; for e in "${BYPASS[@]}"; do [ "$e" = "$v" ] && return 0; done; BYPASS+=("$v"); }
for v in "${OLD_BYPASS[@]}"; do [ -n "$v" ] && add_bypass "$v"; done
if [ -n "$BYPASS_ARG" ]; then
  IFS=',' read -r -a items <<<"$BYPASS_ARG"
  for it in "${items[@]}"; do
    it="$(printf '%s' "$it" | tr -d '[:space:]')"; [ -z "$it" ] && continue
    if is_ipv4 "$it" || is_ipv6 "$it"; then
      add_bypass "$it"
    elif [[ "$it" =~ ^[A-Za-z0-9.-]+$ ]]; then
      mapfile -t res < <(getent ahostsv4 "$it" 2>/dev/null | awk '{print $1}' | sort -u)
      [ "${#res[@]}" -gt 0 ] || die "Could not resolve $it (--bypass)"
      for r in "${res[@]}"; do add_bypass "$r"; info "bypass: $it -> $r"; done
    else
      die "Invalid --bypass entry: $it"
    fi
  done
fi

# ============================================================================
#  DEPENDENCIES
# ============================================================================
step "Dependencies"
ensure_cmd curl curl curl
ensure_cmd tar tar tar
ensure_cmd sha256sum coreutils coreutils
ensure_cmd modprobe kmod kmod
ensure_cmd lsmod kmod kmod
ensure_cmd logrotate logrotate logrotate
if [ "$FIREWALL" = "iptables" ]; then ensure_cmd iptables iptables iptables
else ensure_cmd nft nftables nftables; fi
ok "Dependencies in place"

# ============================================================================
#  NODE: docker-compose volume + log folder + logrotate
# ============================================================================
patch_compose() { # patch_compose <file> -> 0 changed, 2 already there, 1 error
  local f="$1" svc tmp
  if grep -Eq "^[^#]*/var/log/remnanode[\"']?[[:space:]]*:[[:space:]]*/var/log/remnanode" "$f"; then
    return 2
  fi
  # service: remnanode, otherwise the first one under services:
  if grep -Eq '^[[:space:]]+remnanode:[[:space:]]*(#.*)?$' "$f"; then svc="remnanode"
  else
    svc="$(awk '/^services:[ \t]*(#.*)?$/{s=1;next} s && /^[ \t]+[A-Za-z0-9_.-]+:[ \t]*(#.*)?$/{sub(/^[ \t]+/,"");sub(/:.*/,"");print;exit} s && /^[^ \t#]/{exit}' "$f")"
  fi
  [ -n "$svc" ] || { warn "No service found in $f"; return 1; }

  tmp="$(mktemp)"
  if ! awk -v svc="$svc" -v vol="$VOLUME_LINE" '
    function ind(s) { match(s, /^[ ]*/); return RLENGTH }
    function blank(s) { return s ~ /^[ \t]*(#.*)?$/ }
    { L[NR] = $0 }
    END {
      # 1) locate the service block
      for (i = 1; i <= NR; i++) if (L[i] ~ "^[ ]+" svc ":[ \t]*(#.*)?$") { s = i; break }
      if (!s) exit 3
      si = ind(L[s]); ci = -1; e = s
      for (i = s + 1; i <= NR; i++) {
        if (blank(L[i])) continue
        if (ind(L[i]) <= si) break
        if (ci < 0) ci = ind(L[i])
        e = i
      }
      if (ci < 0) exit 3
      # 2) look for volumes: at child level
      v = 0; ii = -1; last = 0
      for (i = s + 1; i <= e; i++) {
        if (!v && ind(L[i]) == ci && L[i] ~ /^[ ]*volumes:/) {
          if (L[i] !~ /^[ ]*volumes:[ \t]*(#.*)?$/) exit 4   # inline form — do not touch
          v = i; last = i; continue
        }
        if (v && !blank(L[i])) {
          if (ind(L[i]) > ci || (ind(L[i]) == ci && L[i] ~ /^[ ]*- /)) {
            if (ii < 0 && L[i] ~ /^[ ]*- /) ii = ind(L[i])
            last = i
          } else break
        }
      }
      pad = sprintf("%" ci "s", "")
      if (v) {
        if (ii < 0) ii = ci + 4
        ipad = sprintf("%" ii "s", "")
        for (i = 1; i <= NR; i++) { print L[i]; if (i == last) print ipad "- \x27" vol "\x27" }
      } else {
        ipad = sprintf("%" (ci + 4) "s", "")
        for (i = 1; i <= NR; i++) { print L[i]; if (i == e) { print pad "volumes:"; print ipad "- \x27" vol "\x27" } }
      }
    }' "$f" >"$tmp"; then
    rm -f "$tmp"; warn "Could not edit $f automatically (non-standard format)"; return 1
  fi
  cat "$tmp" >"$f"; rm -f "$tmp"
  return 0
}

if [ "$SKIP_NODE" -eq 0 ]; then
  step "Configuring the remnanode node"
  mkdir -p "$(dirname "$LOG_FILE")"
  [ -d "$LOG_DIR_DEFAULT" ] || mkdir -p "$LOG_DIR_DEFAULT"
  ok "Log folder: $(dirname "$LOG_FILE")"

  COMPOSE_FILE=""
  for c in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [ -f "$NODE_DIR/$c" ] && { COMPOSE_FILE="$NODE_DIR/$c"; break; }
  done

  if [ -z "$COMPOSE_FILE" ]; then
    warn "No docker-compose found in $NODE_DIR. If the node lives elsewhere, use --node-dir; if Xray is not in docker, use --skip-node."
  else
    DC="$(compose_cmd)"
    [ -n "$DC" ] || die "docker compose not found, but $COMPOSE_FILE exists"
    BACKUP="$COMPOSE_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$COMPOSE_FILE" "$BACKUP"
    rc=0; patch_compose "$COMPOSE_FILE" || rc=$?
    case "$rc" in
      0)
        if (cd "$NODE_DIR" && $DC -f "$COMPOSE_FILE" config -q) 2>/dev/null \
           && (cd "$NODE_DIR" && $DC -f "$COMPOSE_FILE" config 2>/dev/null) | has "/var/log/remnanode"; then
          ok "Volume added to $COMPOSE_FILE (backup: $BACKUP)"
          COMPOSE_CHANGED=1
        else
          cp -a "$BACKUP" "$COMPOSE_FILE"
          die "After the edit, docker compose did not validate the file — restored from backup. Add the volume by hand: - '$VOLUME_LINE'"
        fi ;;
      2) ok "Volume /var/log/remnanode is already in $COMPOSE_FILE"; rm -f "$BACKUP"; COMPOSE_CHANGED=0 ;;
      *) cp -a "$BACKUP" "$COMPOSE_FILE"; die "Add the volume to $COMPOSE_FILE by hand: - '$VOLUME_LINE', then rerun the script" ;;
    esac

    CONTAINER="$(cd "$NODE_DIR" && $DC -f "$COMPOSE_FILE" ps -q 2>/dev/null | head -n1 || true)"
    mounted=0
    if [ -n "$CONTAINER" ] && docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$CONTAINER" 2>/dev/null | has -w "/var/log/remnanode"; then
      mounted=1
    fi
    if [ "$mounted" -eq 1 ] && [ "${COMPOSE_CHANGED:-0}" -eq 0 ]; then
      ok "The container already sees /var/log/remnanode — no restart needed"
    elif [ "$NO_RESTART" -eq 1 ]; then
      warn "--no-restart: recreate the container yourself: cd $NODE_DIR && $DC up -d"
    else
      info "Recreating the node container (connections will drop for a few seconds)..."
      (cd "$NODE_DIR" && $DC -f "$COMPOSE_FILE" up -d --force-recreate) >/dev/null 2>&1 \
        || die "docker compose up failed. Check: cd $NODE_DIR && $DC logs"
      sleep 3
      CONTAINER="$(cd "$NODE_DIR" && $DC -f "$COMPOSE_FILE" ps -q 2>/dev/null | head -n1 || true)"
      if [ -n "$CONTAINER" ] && docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$CONTAINER" | has -w "/var/log/remnanode"; then
        ok "Node restarted, folder mounted"
      else
        die "The container is up but /var/log/remnanode is not mounted. Check $COMPOSE_FILE"
      fi
    fi
  fi

  # logrotate exactly as in the instructions
  cat >"$LOGROTATE_PATH" <<'EOF'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF
  chmod 644 "$LOGROTATE_PATH"
  if logrotate -d "$LOGROTATE_PATH" >/dev/null 2>&1; then ok "logrotate: $LOGROTATE_PATH"
  else warn "logrotate -d reported a problem in $LOGROTATE_PATH"; fi
else
  info "--skip-node: not touching the node"
  mkdir -p "$(dirname "$LOG_FILE")"
fi

# ============================================================================
#  REMOVE THE OLD PACKAGE
# ============================================================================
step "Checking for an old install"
if systemctl is-active --quiet tblocker 2>/dev/null; then
  info "Stopping the running tblocker..."
  systemctl stop tblocker
fi
CONFIG_BACKUP=""
if [ -f "$CONFIG_PATH" ]; then
  CONFIG_BACKUP="$CONFIG_PATH.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$CONFIG_PATH" "$CONFIG_BACKUP"
  info "Old config saved: $CONFIG_BACKUP"
fi
if command -v dpkg >/dev/null 2>&1 && dpkg -s tblocker >/dev/null 2>&1; then
  info "Removing the old apt package tblocker..."
  DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq tblocker >/dev/null || warn "apt-get remove tblocker failed"
  rm -f /etc/apt/sources.list.d/openrepo-xray-tools.list
  ok "Old package removed"
elif command -v rpm >/dev/null 2>&1 && rpm -q tblocker >/dev/null 2>&1; then
  info "Removing the old rpm package tblocker..."
  { command -v dnf >/dev/null && dnf remove -y -q tblocker; } || yum remove -y -q tblocker || warn "Failed to remove the rpm package"
else
  ok "No old package found"
fi

# ============================================================================
#  DOWNLOAD
# ============================================================================
step "Downloading tblocker"
TMP_DIR="$(mktemp -d)"

resolve_latest() {
  local tag=""
  tag="$(curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' \
          "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')" || true
  if [ -z "$tag" ]; then # no API (rate limit) — use the redirect
    tag="$(curl -fsSIL --max-time 15 -o /dev/null -w '%{url_effective}' \
            "https://github.com/$REPO/releases/latest" 2>/dev/null | sed -E 's#.*/tag/##')" || true
  fi
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+.*$ ]] && printf '%s' "$tag" || printf '%s' ""
}

if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || die "No such file: $TARBALL"
  cp "$TARBALL" "$TMP_DIR/tb.tar.gz"
  info "Using the local archive: $TARBALL"
else
  if [ -z "$VERSION" ]; then
    VERSION="$(resolve_latest)"
    if [ -z "$VERSION" ]; then
      VERSION="$FALLBACK_VERSION"; warn "Could not determine the latest version, using $VERSION"
    fi
  fi
  [[ "$VERSION" == v* ]] || VERSION="v$VERSION"
  ASSET="xray-torrent-blocker-${VERSION}-linux-${ARCH}.tar.gz"
  BASE="https://github.com/$REPO/releases/download/$VERSION"
  info "Version $VERSION → $ASSET"
  curl -fL --retry 3 --retry-delay 2 --max-time 120 -sS "$BASE/$ASSET" -o "$TMP_DIR/tb.tar.gz" \
    || die "Failed to download $BASE/$ASSET"
  if curl -fsSL --retry 2 --max-time 30 "$BASE/checksums.txt" -o "$TMP_DIR/checksums.txt" 2>/dev/null; then
    expected="$(awk -v a="$ASSET" '$2==a || $2=="*"a {print $1}' "$TMP_DIR/checksums.txt")"
    actual="$(sha256sum "$TMP_DIR/tb.tar.gz" | awk '{print $1}')"
    [ -n "$expected" ] || die "No entry for $ASSET in checksums.txt"
    [ "$expected" = "$actual" ] || die "SHA256 mismatch! expected $expected, got $actual"
    ok "SHA256 verified"
  else
    warn "checksums.txt unavailable — checksum not verified"
  fi
fi

mkdir -p "$TMP_DIR/x"
tar -xzf "$TMP_DIR/tb.tar.gz" -C "$TMP_DIR/x" || die "Archive is corrupted"
NEW_BIN="$(find "$TMP_DIR/x" -type f -name tblocker | head -n1)"
[ -n "$NEW_BIN" ] || die "No tblocker binary in the archive"
chmod +x "$NEW_BIN"
"$NEW_BIN" -v >/dev/null 2>&1 || die "The binary does not run on this system"
mkdir -p "$INSTALL_DIR"
install -m 0755 "$NEW_BIN" "$BIN_PATH.new"
mv -f "$BIN_PATH.new" "$BIN_PATH"
ok "Installed: $("$BIN_PATH" -v 2>&1 | tail -n1)"

# ============================================================================
#  KERNEL AND FIREWALL
# ============================================================================
step "Checking the kernel and firewall"
# tblocker checks the module exactly like this: the output of `lsmod` must contain
# nf_conntrack, otherwise it exits on start. So we check the same way.
if ! lsmod 2>/dev/null | has 'nf_conntrack'; then
  modprobe nf_conntrack 2>/dev/null || true
fi
if lsmod 2>/dev/null | has 'nf_conntrack'; then
  ok "nf_conntrack loaded"
else
  die "nf_conntrack is missing from lsmod (OpenVZ/LXC container or a kernel without modules) — tblocker will not start on this server."
fi
mkdir -p /etc/modules-load.d && echo nf_conntrack >/etc/modules-load.d/conntrack.conf

if [ "$FIREWALL" = "iptables" ]; then
  iptables -w -t raw -L PREROUTING -n >/dev/null 2>&1 \
    || die "iptables cannot access the raw table. Try --firewall nft"
  ok "iptables (raw table) available"
  # when switching from nft, remove the old table, otherwise its blocks would never be lifted
  if command -v nft >/dev/null 2>&1 && nft list table inet tblocker >/dev/null 2>&1; then
    nft delete table inet tblocker && info "Removed the leftover nft table tblocker"
  fi
else
  nft list tables >/dev/null 2>&1 || die "nft is not working"
  ok "nftables available"
  # when switching from iptables, remove the old chain
  if command -v iptables >/dev/null 2>&1 && iptables -w -t raw -S "$CHAIN" >/dev/null 2>&1; then
    while iptables -w -t raw -D PREROUTING -j "$CHAIN" 2>/dev/null; do :; done
    iptables -w -t raw -F "$CHAIN" 2>/dev/null || true
    iptables -w -t raw -X "$CHAIN" 2>/dev/null || true
    info "Removed the leftover iptables chain $CHAIN"
  fi
fi

# ============================================================================
#  CONFIG
# ============================================================================
write_config() { # write_config <path> <logfile> <storage> <send:true|false> <webhook> <duration> <bypass...>
  local path="$1" lf="$2" sd="$3" send="$4" wh="$5" dur="$6"; shift 6
  {
    echo "# Generated by install-tblocker.sh $(date '+%F %T')"
    echo "LogFile: $(yaml_q "$lf")"
    echo "BlockDuration: $dur"
    echo 'TorrentTag: "TORRENT"'
    echo "BlockMode: $(yaml_q "$FIREWALL")"
    echo "Hostname: $(yaml_q "$NODE_NAME")"
    echo "BypassIPS:"
    for b in "$@"; do echo "  - $(yaml_q "$b")"; done
    echo "StorageDir: $(yaml_q "$sd")"
    echo 'UsernameRegex: "^(.+)$"'
    echo "SendWebhook: $send"
    if [ -n "$wh" ]; then echo "WebhookURL: $(yaml_q "$wh")"; fi
    echo "WebhookTemplate: '{\"username\":\"%s\",\"ip\":\"%s\",\"server\":\"%s\",\"action\":\"%s\",\"duration\":%d,\"timestamp\":\"%s\"}'"
  } >"$path"
  chmod 600 "$path"
}

step "Configuration"
SEND="false"; [ -n "$WEBHOOK" ] && SEND="true"
write_config "$CONFIG_PATH" "$LOG_FILE" "$INSTALL_DIR" "$SEND" "$WEBHOOK" "$DURATION" "${BYPASS[@]}"
ok "Config: $CONFIG_PATH"

# ============================================================================
#  SELF-TEST (isolated copy, webhook off)
# ============================================================================
if [ "$SKIP_SELFTEST" -eq 0 ]; then
  step "Self-test (test IP $TEST_IP, webhook off)"
  ST="$TMP_DIR/selftest"; mkdir -p "$ST"
  : >"$ST/access.log"
  write_config "$ST/config.yaml" "$ST/access.log" "$ST" "false" "" 1 "127.0.0.1"
  fw_unblock "$TEST_IP"
  "$BIN_PATH" -c "$ST/config.yaml" >"$ST/out.log" 2>&1 &
  SELFTEST_PID=$!
  # wait for the log to be opened
  for _ in $(seq 1 20); do
    grep -q "Initialized byte search patterns" "$ST/out.log" 2>/dev/null && break
    kill -0 "$SELFTEST_PID" 2>/dev/null || break
    sleep 0.5
  done
  sleep 1
  if ! kill -0 "$SELFTEST_PID" 2>/dev/null; then
    cat "$ST/out.log" >&2
    die "tblocker crashed on start (see output above)"
  fi
  printf '%s from tcp:%s:51413 accepted tcp:198.51.100.7:6881 [VLESS_REALITY >> TORRENT] email: tblocker_selftest\n' \
    "$(date '+%Y/%m/%d %H:%M:%S.000000')" "$TEST_IP" >>"$ST/access.log"
  passed=0
  for _ in $(seq 1 20); do
    if fw_has_ip "$TEST_IP"; then passed=1; break; fi
    sleep 0.5
  done
  kill "$SELFTEST_PID" 2>/dev/null || true
  wait "$SELFTEST_PID" 2>/dev/null || true
  SELFTEST_PID=""
  fw_unblock "$TEST_IP"
  if [ "$passed" -eq 1 ]; then
    ok "Self-test passed: log line → parsing → block in $FIREWALL (rule removed)"
  else
    sed 's/^/    /' "$ST/out.log" >&2
    die "Self-test failed: tblocker did not block the test IP (tblocker output above)"
  fi
fi

# ============================================================================
#  SYSTEMD
# ============================================================================
step "Starting the service"
cat >"$SERVICE_PATH" <<EOF
[Unit]
Description=XRay Torrent Blocker Service
Documentation=https://github.com/$REPO
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$BIN_PATH -c $CONFIG_PATH
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable tblocker >/dev/null 2>&1
systemctl restart tblocker

# watch for 10 s: any drop (including an auto-restart) counts as a failure
active=1
for _ in $(seq 1 10); do
  sleep 1
  systemctl is-active --quiet tblocker || { active=0; break; }
done
if [ "$active" -ne 1 ]; then
  journalctl -u tblocker -n 30 --no-pager >&2 || true
  die "The tblocker service did not start (log above)"
fi
ok "tblocker is running and stays up"

if [ "$FIREWALL" = "iptables" ]; then
  if iptables -w -t raw -S PREROUTING 2>/dev/null | has -- "-j $CHAIN"; then ok "Chain $CHAIN hooked into raw/PREROUTING"
  else warn "No jump to $CHAIN in raw/PREROUTING yet — check: journalctl -u tblocker"; fi
else
  if nft list table inet tblocker >/dev/null 2>&1; then ok "nft table inet tblocker created"
  else warn "No nft table tblocker yet — check: journalctl -u tblocker"; fi
fi

# ============================================================================
#  XRAY LOG CHECK
# ============================================================================
step "Checking the Xray log"
if [ -s "$LOG_FILE" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$LOG_FILE") ))
  if [ "$age" -lt 600 ]; then
    ok "Xray is writing $LOG_FILE (last write ${age}s ago)"
    if tail -n 200 "$LOG_FILE" | has " accepted " && ! tail -n 200 "$LOG_FILE" | has "email: "; then
      warn "The log has no 'email:' fields — tblocker cannot identify users."
    fi
  else
    warn "$LOG_FILE has not been updated for ${age}s — is there traffic and is the log configured in the profile?"
  fi
else
  warn "$LOG_FILE is empty or missing — Xray is not writing access logs yet."
fi

# ============================================================================
#  SUMMARY
# ============================================================================
printf '\n%s=====================================================================%s\n' "$C_G" "$C_0"
ok "Installation finished"
printf '%s=====================================================================%s\n' "$C_G" "$C_0"
cat <<EOF
  Server (hostname)  : $NODE_NAME     <- add to SERVER_COUNTRIES in Solobot
  Log                : $LOG_FILE
  Firewall           : $FIREWALL
  Block for          : $DURATION min
  Webhook            : ${WEBHOOK:-off}
  Bypass             : ${BYPASS[*]}
  Config             : $CONFIG_PATH${CONFIG_BACKUP:+  (old one: $CONFIG_BACKUP)}

  Logs:    journalctl -u tblocker -f
  Status:  systemctl status tblocker
  Removal: bash <(curl -fsSL https://raw.githubusercontent.com/kafka7005/tblocker-installer/main/install-tblocker.sh) --uninstall
EOF

cat <<'EOF'

  ─── Check in the Remnawave panel (Profiles → Xray config) ───
  "log": {
      "error": "/var/log/remnanode/error.log",
      "access": "/var/log/remnanode/access.log",
      "loglevel": "warning"
  }

  in "outbounds":
  { "tag": "TORRENT", "protocol": "blackhole" }

  in "routing" → "rules":
  { "type": "field", "protocol": ["bittorrent"], "outboundTag": "TORRENT" }

  For bittorrent detection, the inbounds need "sniffing": { "enabled": true }.
EOF
echo
