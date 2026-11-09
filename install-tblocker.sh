#!/usr/bin/env bash
# =============================================================================
#  Установщик tblocker для нод Remnawave (+ вебхук Solobot)
#
#  Что делает (шаги 1 и 3 ручной инструкции):
#    1. Пробрасывает /var/log/remnanode в контейнер remnanode (правит
#       docker-compose.yml с бэкапом и проверкой), настраивает logrotate
#    2. Удаляет старый apt-пакет tblocker, если он стоит
#    3. Скачивает tblocker из релизов GitHub (проверяет sha256)
#    4. Пишет /opt/tblocker/config.yaml и systemd-сервис
#    5. Самотест: на изолированной копии (вебхук ВЫКЛ) блокирует тестовый
#       IP 203.0.113.200, проверяет, что правило появилось, и убирает его
#    6. Запускает сервис и проверяет, что он работает
#
#  Настройку Xray в панели Remnawave (шаг 2) нужно сделать руками —
#  скрипт в конце выведет готовый JSON.
#
#  Запуск:
#    bash <(curl -fsSL https://raw.githubusercontent.com/kafka7005/tblocker-installer/main/install-tblocker.sh) \
#         --webhook bot.example.com
#
#  Параметры:
#    --webhook URL|ДОМЕН   вебхук бота. Голый домен превращается в
#                          https://ДОМЕН/tblocker/webhook
#    --no-webhook          не отправлять вебхуки
#    --duration МИН        срок блокировки в минутах (по умолчанию 30)
#    --bypass СПИСОК       IP/домены через запятую, которые никогда не блокируются
#    --hostname ИМЯ        имя сервера в вебхуке (по умолчанию hostname)
#    --firewall РЕЖИМ      iptables (по умолчанию) | nft
#    --version vX.Y.Z      версия tblocker (по умолчанию последний релиз)
#    --log-file ПУТЬ       access-лог Xray (по умолчанию /var/log/remnanode/access.log)
#    --node-dir ПАПКА      папка remnanode (по умолчанию /opt/remnanode)
#    --skip-node           не трогать docker-compose и контейнер ноды
#    --no-restart          не перезапускать контейнер ноды (только править compose)
#    --skip-selftest       пропустить самотест
#    --tarball ПУТЬ        установить из локального архива релиза (без интернета)
#    -y, --yes             ничего не спрашивать
#    --uninstall           полностью удалить tblocker
#    -h, --help            справка
#
#  Повторный запуск безопасен: старый конфиг сохраняется в бэкап, вебхук,
#  срок, hostname и bypass-список переносятся, если не заданы новые.
# =============================================================================

set -Eeuo pipefail

# ----------------------------- константы ------------------------------------
REPO="kutovoys/xray-torrent-blocker"
FALLBACK_VERSION="v1.1.0"
INSTALL_DIR="/opt/tblocker"
BIN_PATH="$INSTALL_DIR/tblocker"
CONFIG_PATH="$INSTALL_DIR/config.yaml"
SERVICE_PATH="/etc/systemd/system/tblocker.service"
LOGROTATE_PATH="/etc/logrotate.d/remnanode"
LOG_DIR_DEFAULT="/var/log/remnanode"
VOLUME_LINE="/var/log/remnanode:/var/log/remnanode"
TEST_IP="203.0.113.200"   # TEST-NET-3 (RFC 5737), в интернете не маршрутизируется
CHAIN="TBLOCKER_BLOCKED"
SCRIPT_URL="https://raw.githubusercontent.com/kafka7005/tblocker-installer/main/install-tblocker.sh"

# ----------------------------- значения по умолчанию ------------------------
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

# ----------------------------- вывод ----------------------------------------
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
trap 'die "Ошибка в строке $LINENO (команда: $BASH_COMMAND)"' ERR

usage() {
  cat <<USAGE
Запуск: bash <(curl -fsSL $SCRIPT_URL) [параметры]
  --webhook URL|ДОМЕН    вебхук бота (голый домен -> https://ДОМЕН/tblocker/webhook)
  --no-webhook           без вебхуков
  --duration МИН         срок блокировки в минутах (по умолчанию 30)
  --bypass СПИСОК        IP/домены через запятую, которые никогда не блокируются
  --hostname ИМЯ         имя сервера в вебхуке
  --firewall РЕЖИМ       iptables (по умолчанию) | nft
  --version vX.Y.Z       версия tblocker (по умолчанию последняя)
  --log-file ПУТЬ        access-лог Xray
  --node-dir ПАПКА       папка remnanode (по умолчанию /opt/remnanode)
  --skip-node            не трогать docker-compose
  --no-restart           не перезапускать контейнер ноды
  --skip-selftest        без самотеста
  --tarball ПУТЬ         установка из локального архива
  -y, --yes              ничего не спрашивать
  --uninstall            удалить tblocker
USAGE
}

# Вопросы идут через /dev/tty, поэтому работают и с bash <(curl ...), и с curl | bash
HAS_TTY=0
if [ -r /dev/tty ] && [ -w /dev/tty ] && { : </dev/tty; } 2>/dev/null; then HAS_TTY=1; fi
ask() { # ask "вопрос" значение_по_умолчанию -> печатает ответ
  local q="$1" def="${2:-}" ans=""
  if [ "$ASSUME_YES" -eq 1 ] || [ "$HAS_TTY" -eq 0 ]; then printf '%s' "$def"; return; fi
  printf '%s' "$q" >/dev/tty
  IFS= read -r ans </dev/tty || ans=""
  printf '%s' "${ans:-$def}"
}

# ----------------------------- аргументы ------------------------------------
need_val() { [ $# -ge 2 ] && [ -n "$2" ] || die "Параметру $1 нужно значение"; }
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
    *) die "Неизвестный параметр: $1 (см. --help)" ;;
  esac
done

# ----------------------------- помощники ------------------------------------
# Как `grep -q`, но читает ВЕСЬ вход. С pipefail конструкция `cmd | grep -q`
# падает, когда cmd получает SIGPIPE после раннего выхода grep (например, lsmod
# с длинным выводом).
has() { grep "$@" >/dev/null; }

yaml_q() { # строка -> "экранированная строка" для YAML
  local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"
}

# Прочитать скалярный ключ из существующего конфига (без кавычек)
cfg_get() {
  [ -f "$CONFIG_PATH" ] || return 0
  awk -v k="$1" '
    $0 ~ "^"k":" {
      sub("^"k":[ \t]*", ""); sub(/[ \t]+#.*$/, "")
      if ($0 ~ /^".*"$/ || $0 ~ /^\x27.*\x27$/) $0 = substr($0, 2, length($0)-2)
      print; exit
    }' "$CONFIG_PATH"
}
# Прочитать список BypassIPS из существующего конфига
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
pkg_install() { # pkg_install <пакет-apt> <пакет-rpm>
  case "$PKG" in
    apt)
      if [ "$APT_UPDATED" -eq 0 ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null || warn "apt-get update завершился с ошибками"
        APT_UPDATED=1
      fi
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$1" >/dev/null ;;
    dnf) dnf install -y -q "$2" >/dev/null ;;
    yum) yum install -y -q "$2" >/dev/null ;;
    *) return 1 ;;
  esac
}
ensure_cmd() { # ensure_cmd <команда> <пакет-apt> <пакет-rpm>
  command -v "$1" >/dev/null 2>&1 && return 0
  info "Устанавливаю $2..."
  pkg_install "$2" "$3" || die "Не удалось установить $2 — поставь его вручную"
  command -v "$1" >/dev/null 2>&1 || die "Команды $1 нет даже после установки $2"
}

# Убрать один тестовый/устаревший IP из файрвола (остальные правила не трогает)
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
#  УДАЛЕНИЕ
# ============================================================================
do_uninstall() {
  step "Удаление tblocker"
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
  ok "tblocker удалён: сервис, правила файрвола и $INSTALL_DIR"
  info "Volume в docker-compose, logrotate и логи в $LOG_DIR_DEFAULT оставлены (они нужны ноде)."
}

# ============================================================================
#  ПРЕДВАРИТЕЛЬНЫЕ ПРОВЕРКИ
# ============================================================================
[ "$(id -u)" -eq 0 ] || die "Запускай от root (sudo)."
[ "$(uname -s)" = "Linux" ] || die "Только для Linux."

if [ "$UNINSTALL" -eq 1 ]; then do_uninstall; exit 0; fi

step "Проверка системы"
command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] \
  || die "Нужен systemd (нет /run/systemd/system)."

case "$(uname -m)" in
  x86_64|amd64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "Архитектура не поддерживается: $(uname -m)" ;;
esac
case "$FIREWALL" in iptables|nft) ;; *) die "--firewall должен быть iptables или nft" ;; esac
[[ "$LOG_FILE" = /* ]] || die "--log-file должен быть абсолютным путём"

detect_pkg
[ -n "$PKG" ] || warn "Пакетный менеджер не найден (apt/dnf/yum) — зависимости должны уже стоять."
ok "Архитектура: $ARCH, пакеты: ${PKG:-нет}, файрвол: $FIREWALL"

# ---------------- параметры (переносятся из старого конфига) ---------------
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
    info "Вебхук взят из существующего конфига: $WEBHOOK"
  else
    WEBHOOK="$(ask "Домен бота для вебхука (например bot.example.com, Enter = без вебхука): " "")"
  fi
fi
WEBHOOK="$(printf '%s' "$WEBHOOK" | tr -d '[:space:]')"
if [ -n "$WEBHOOK" ]; then
  if [[ "$WEBHOOK" != http://* && "$WEBHOOK" != https://* ]]; then
    WEBHOOK="https://${WEBHOOK%/}/tblocker/webhook"
  fi
  [[ "$WEBHOOK" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[^\"\'\ ]*)?$ ]] \
    || die "Некорректный адрес вебхука: $WEBHOOK"
fi

if [ -z "$DURATION" ]; then
  if [[ "$OLD_DURATION" =~ ^[0-9]+$ ]] && [ "$OLD_DURATION" -gt 0 ]; then DURATION="$OLD_DURATION"; else DURATION=30; fi
fi
[[ "$DURATION" =~ ^[0-9]+$ ]] && [ "$DURATION" -ge 1 ] || die "--duration должен быть целым числом >= 1"

if [ -n "$HOSTNAME_ARG" ]; then NODE_NAME="$HOSTNAME_ARG"
elif [ -n "$OLD_HOSTNAME" ]; then NODE_NAME="$OLD_HOSTNAME"
else NODE_NAME="$(hostname)"; fi
[[ "$NODE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Некорректный hostname: $NODE_NAME"

# Bypass-список: 127.0.0.1, ::1 + старый список + --bypass (домены -> IPv4)
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
      [ "${#res[@]}" -gt 0 ] || die "Не удалось разрезолвить $it (--bypass)"
      for r in "${res[@]}"; do add_bypass "$r"; info "bypass: $it -> $r"; done
    else
      die "Некорректная запись в --bypass: $it"
    fi
  done
fi

# ============================================================================
#  ЗАВИСИМОСТИ
# ============================================================================
step "Зависимости"
ensure_cmd curl curl curl
ensure_cmd tar tar tar
ensure_cmd sha256sum coreutils coreutils
ensure_cmd modprobe kmod kmod
ensure_cmd lsmod kmod kmod
ensure_cmd logrotate logrotate logrotate
if [ "$FIREWALL" = "iptables" ]; then ensure_cmd iptables iptables iptables
else ensure_cmd nft nftables nftables; fi
ok "Зависимости на месте"

# ============================================================================
#  НОДА: volume в docker-compose + папка логов + logrotate
# ============================================================================
patch_compose() { # patch_compose <файл> -> 0 изменён, 2 уже есть, 1 ошибка
  local f="$1" svc tmp
  if grep -Eq "^[^#]*/var/log/remnanode[\"']?[[:space:]]*:[[:space:]]*/var/log/remnanode" "$f"; then
    return 2
  fi
  # сервис: remnanode, иначе первый в services:
  if grep -Eq '^[[:space:]]+remnanode:[[:space:]]*(#.*)?$' "$f"; then svc="remnanode"
  else
    svc="$(awk '/^services:[ \t]*(#.*)?$/{s=1;next} s && /^[ \t]+[A-Za-z0-9_.-]+:[ \t]*(#.*)?$/{sub(/^[ \t]+/,"");sub(/:.*/,"");print;exit} s && /^[^ \t#]/{exit}' "$f")"
  fi
  [ -n "$svc" ] || { warn "В $f не найден ни один сервис"; return 1; }

  tmp="$(mktemp)"
  if ! awk -v svc="$svc" -v vol="$VOLUME_LINE" '
    function ind(s) { match(s, /^[ ]*/); return RLENGTH }
    function blank(s) { return s ~ /^[ \t]*(#.*)?$/ }
    { L[NR] = $0 }
    END {
      # 1) найти блок сервиса
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
      # 2) найти volumes: на уровне дочерних ключей
      v = 0; ii = -1; last = 0
      for (i = s + 1; i <= e; i++) {
        if (!v && ind(L[i]) == ci && L[i] ~ /^[ ]*volumes:/) {
          if (L[i] !~ /^[ ]*volumes:[ \t]*(#.*)?$/) exit 4   # inline-форма — не трогаем
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
    rm -f "$tmp"; warn "Не удалось автоматически отредактировать $f (нестандартный формат)"; return 1
  fi
  cat "$tmp" >"$f"; rm -f "$tmp"
  return 0
}

if [ "$SKIP_NODE" -eq 0 ]; then
  step "Настройка ноды remnanode"
  mkdir -p "$(dirname "$LOG_FILE")"
  [ -d "$LOG_DIR_DEFAULT" ] || mkdir -p "$LOG_DIR_DEFAULT"
  ok "Папка логов: $(dirname "$LOG_FILE")"

  COMPOSE_FILE=""
  for c in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [ -f "$NODE_DIR/$c" ] && { COMPOSE_FILE="$NODE_DIR/$c"; break; }
  done

  if [ -z "$COMPOSE_FILE" ]; then
    warn "В $NODE_DIR не найден docker-compose. Если нода в другой папке — укажи --node-dir; если Xray не в docker — запусти с --skip-node."
  else
    DC="$(compose_cmd)"
    [ -n "$DC" ] || die "docker compose не найден, хотя есть $COMPOSE_FILE"
    BACKUP="$COMPOSE_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$COMPOSE_FILE" "$BACKUP"
    rc=0; patch_compose "$COMPOSE_FILE" || rc=$?
    case "$rc" in
      0)
        if (cd "$NODE_DIR" && $DC -f "$COMPOSE_FILE" config -q) 2>/dev/null \
           && (cd "$NODE_DIR" && $DC -f "$COMPOSE_FILE" config 2>/dev/null) | has "/var/log/remnanode"; then
          ok "Volume добавлен в $COMPOSE_FILE (бэкап: $BACKUP)"
          COMPOSE_CHANGED=1
        else
          cp -a "$BACKUP" "$COMPOSE_FILE"
          die "После правки docker compose не принял файл — восстановлен из бэкапа. Добавь volume вручную: - '$VOLUME_LINE'"
        fi ;;
      2) ok "Volume /var/log/remnanode уже есть в $COMPOSE_FILE"; rm -f "$BACKUP"; COMPOSE_CHANGED=0 ;;
      *) cp -a "$BACKUP" "$COMPOSE_FILE"; die "Добавь volume в $COMPOSE_FILE вручную: - '$VOLUME_LINE', потом перезапусти скрипт" ;;
    esac

    CONTAINER="$(cd "$NODE_DIR" && $DC -f "$COMPOSE_FILE" ps -q 2>/dev/null | head -n1 || true)"
    mounted=0
    if [ -n "$CONTAINER" ] && docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$CONTAINER" 2>/dev/null | has -w "/var/log/remnanode"; then
      mounted=1
    fi
    if [ "$mounted" -eq 1 ] && [ "${COMPOSE_CHANGED:-0}" -eq 0 ]; then
      ok "Контейнер уже видит /var/log/remnanode — перезапуск не нужен"
    elif [ "$NO_RESTART" -eq 1 ]; then
      warn "--no-restart: пересоздай контейнер сам: cd $NODE_DIR && $DC up -d"
    else
      info "Пересоздаю контейнер ноды (подключения оборвутся на несколько секунд)..."
      (cd "$NODE_DIR" && $DC -f "$COMPOSE_FILE" up -d --force-recreate) >/dev/null 2>&1 \
        || die "docker compose up завершился с ошибкой. Смотри: cd $NODE_DIR && $DC logs"
      sleep 3
      CONTAINER="$(cd "$NODE_DIR" && $DC -f "$COMPOSE_FILE" ps -q 2>/dev/null | head -n1 || true)"
      if [ -n "$CONTAINER" ] && docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$CONTAINER" | has -w "/var/log/remnanode"; then
        ok "Нода перезапущена, папка подключена"
      else
        die "Контейнер поднялся, но /var/log/remnanode в нём не подключена. Проверь $COMPOSE_FILE"
      fi
    fi
  fi

  # logrotate — ровно как в инструкции
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
  else warn "logrotate -d нашёл проблему в $LOGROTATE_PATH"; fi
else
  info "--skip-node: ноду не трогаю"
  mkdir -p "$(dirname "$LOG_FILE")"
fi

# ============================================================================
#  УДАЛЕНИЕ СТАРОГО ПАКЕТА
# ============================================================================
step "Проверка старой установки"
if systemctl is-active --quiet tblocker 2>/dev/null; then
  info "Останавливаю работающий tblocker..."
  systemctl stop tblocker
fi
CONFIG_BACKUP=""
if [ -f "$CONFIG_PATH" ]; then
  CONFIG_BACKUP="$CONFIG_PATH.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$CONFIG_PATH" "$CONFIG_BACKUP"
  info "Старый конфиг сохранён: $CONFIG_BACKUP"
fi
if command -v dpkg >/dev/null 2>&1 && dpkg -s tblocker >/dev/null 2>&1; then
  info "Удаляю старый apt-пакет tblocker..."
  DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq tblocker >/dev/null || warn "apt-get remove tblocker завершился с ошибкой"
  rm -f /etc/apt/sources.list.d/openrepo-xray-tools.list
  ok "Старый пакет удалён"
elif command -v rpm >/dev/null 2>&1 && rpm -q tblocker >/dev/null 2>&1; then
  info "Удаляю старый rpm-пакет tblocker..."
  { command -v dnf >/dev/null && dnf remove -y -q tblocker; } || yum remove -y -q tblocker || warn "Не удалось удалить rpm-пакет"
else
  ok "Старого пакета нет"
fi

# ============================================================================
#  СКАЧИВАНИЕ
# ============================================================================
step "Скачивание tblocker"
TMP_DIR="$(mktemp -d)"

resolve_latest() {
  local tag=""
  tag="$(curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' \
          "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')" || true
  if [ -z "$tag" ]; then # API недоступен (лимит запросов) — берём из редиректа
    tag="$(curl -fsSIL --max-time 15 -o /dev/null -w '%{url_effective}' \
            "https://github.com/$REPO/releases/latest" 2>/dev/null | sed -E 's#.*/tag/##')" || true
  fi
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+.*$ ]] && printf '%s' "$tag" || printf '%s' ""
}

if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || die "Нет такого файла: $TARBALL"
  cp "$TARBALL" "$TMP_DIR/tb.tar.gz"
  info "Использую локальный архив: $TARBALL"
else
  if [ -z "$VERSION" ]; then
    VERSION="$(resolve_latest)"
    if [ -z "$VERSION" ]; then
      VERSION="$FALLBACK_VERSION"; warn "Не удалось узнать последнюю версию, ставлю $VERSION"
    fi
  fi
  [[ "$VERSION" == v* ]] || VERSION="v$VERSION"
  ASSET="xray-torrent-blocker-${VERSION}-linux-${ARCH}.tar.gz"
  BASE="https://github.com/$REPO/releases/download/$VERSION"
  info "Версия $VERSION → $ASSET"
  curl -fL --retry 3 --retry-delay 2 --max-time 120 -sS "$BASE/$ASSET" -o "$TMP_DIR/tb.tar.gz" \
    || die "Не удалось скачать $BASE/$ASSET"
  if curl -fsSL --retry 2 --max-time 30 "$BASE/checksums.txt" -o "$TMP_DIR/checksums.txt" 2>/dev/null; then
    expected="$(awk -v a="$ASSET" '$2==a || $2=="*"a {print $1}' "$TMP_DIR/checksums.txt")"
    actual="$(sha256sum "$TMP_DIR/tb.tar.gz" | awk '{print $1}')"
    [ -n "$expected" ] || die "В checksums.txt нет записи для $ASSET"
    [ "$expected" = "$actual" ] || die "SHA256 не совпадает! Ожидалось $expected, получено $actual"
    ok "SHA256 совпадает"
  else
    warn "checksums.txt недоступен — контрольная сумма не проверена"
  fi
fi

mkdir -p "$TMP_DIR/x"
tar -xzf "$TMP_DIR/tb.tar.gz" -C "$TMP_DIR/x" || die "Архив повреждён"
NEW_BIN="$(find "$TMP_DIR/x" -type f -name tblocker | head -n1)"
[ -n "$NEW_BIN" ] || die "В архиве нет бинарника tblocker"
chmod +x "$NEW_BIN"
"$NEW_BIN" -v >/dev/null 2>&1 || die "Бинарник не запускается на этой системе"
mkdir -p "$INSTALL_DIR"
install -m 0755 "$NEW_BIN" "$BIN_PATH.new"
mv -f "$BIN_PATH.new" "$BIN_PATH"
ok "Установлено: $("$BIN_PATH" -v 2>&1 | tail -n1)"

# ============================================================================
#  ЯДРО И ФАЙРВОЛ
# ============================================================================
step "Проверка ядра и файрвола"
# tblocker проверяет модуль именно так: в выводе `lsmod` должен быть
# nf_conntrack, иначе он падает при старте. Поэтому проверяем так же.
if ! lsmod 2>/dev/null | has 'nf_conntrack'; then
  modprobe nf_conntrack 2>/dev/null || true
fi
if lsmod 2>/dev/null | has 'nf_conntrack'; then
  ok "nf_conntrack загружен"
else
  die "nf_conntrack нет в lsmod (контейнер OpenVZ/LXC или ядро без модулей) — tblocker на этом сервере не запустится."
fi
mkdir -p /etc/modules-load.d && echo nf_conntrack >/etc/modules-load.d/conntrack.conf

if [ "$FIREWALL" = "iptables" ]; then
  iptables -w -t raw -L PREROUTING -n >/dev/null 2>&1 \
    || die "iptables не может работать с таблицей raw. Попробуй --firewall nft"
  ok "iptables (таблица raw) доступен"
  # при переходе с nft убираем старую таблицу, иначе её блокировки никогда не снимутся
  if command -v nft >/dev/null 2>&1 && nft list table inet tblocker >/dev/null 2>&1; then
    nft delete table inet tblocker && info "Удалена оставшаяся nft-таблица tblocker"
  fi
else
  nft list tables >/dev/null 2>&1 || die "nft не работает"
  ok "nftables доступен"
  # при переходе с iptables убираем старую цепочку
  if command -v iptables >/dev/null 2>&1 && iptables -w -t raw -S "$CHAIN" >/dev/null 2>&1; then
    while iptables -w -t raw -D PREROUTING -j "$CHAIN" 2>/dev/null; do :; done
    iptables -w -t raw -F "$CHAIN" 2>/dev/null || true
    iptables -w -t raw -X "$CHAIN" 2>/dev/null || true
    info "Удалена оставшаяся цепочка iptables $CHAIN"
  fi
fi

# ============================================================================
#  КОНФИГ
# ============================================================================
write_config() { # write_config <путь> <лог> <хранилище> <send:true|false> <вебхук> <срок> <bypass...>
  local path="$1" lf="$2" sd="$3" send="$4" wh="$5" dur="$6"; shift 6
  {
    echo "# Создано install-tblocker.sh $(date '+%F %T')"
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

step "Конфигурация"
SEND="false"; [ -n "$WEBHOOK" ] && SEND="true"
write_config "$CONFIG_PATH" "$LOG_FILE" "$INSTALL_DIR" "$SEND" "$WEBHOOK" "$DURATION" "${BYPASS[@]}"
ok "Конфиг: $CONFIG_PATH"

# ============================================================================
#  САМОТЕСТ (изолированная копия, вебхук выключен)
# ============================================================================
if [ "$SKIP_SELFTEST" -eq 0 ]; then
  step "Самотест (тестовый IP $TEST_IP, вебхук выключен)"
  ST="$TMP_DIR/selftest"; mkdir -p "$ST"
  : >"$ST/access.log"
  write_config "$ST/config.yaml" "$ST/access.log" "$ST" "false" "" 1 "127.0.0.1"
  fw_unblock "$TEST_IP"
  "$BIN_PATH" -c "$ST/config.yaml" >"$ST/out.log" 2>&1 &
  SELFTEST_PID=$!
  # ждём, пока tblocker откроет лог
  for _ in $(seq 1 20); do
    grep -q "Initialized byte search patterns" "$ST/out.log" 2>/dev/null && break
    kill -0 "$SELFTEST_PID" 2>/dev/null || break
    sleep 0.5
  done
  sleep 1
  if ! kill -0 "$SELFTEST_PID" 2>/dev/null; then
    cat "$ST/out.log" >&2
    die "tblocker упал при запуске (вывод выше)"
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
    ok "Самотест пройден: строка лога → разбор → блокировка в $FIREWALL (правило убрано)"
  else
    sed 's/^/    /' "$ST/out.log" >&2
    die "Самотест провален: tblocker не заблокировал тестовый IP (вывод tblocker выше)"
  fi
fi

# ============================================================================
#  SYSTEMD
# ============================================================================
step "Запуск сервиса"
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

# следим 10 секунд: любое падение (включая авторестарт) считается ошибкой
active=1
for _ in $(seq 1 10); do
  sleep 1
  systemctl is-active --quiet tblocker || { active=0; break; }
done
if [ "$active" -ne 1 ]; then
  journalctl -u tblocker -n 30 --no-pager >&2 || true
  die "Сервис tblocker не запустился (лог выше)"
fi
ok "tblocker запущен и работает стабильно"

if [ "$FIREWALL" = "iptables" ]; then
  if iptables -w -t raw -S PREROUTING 2>/dev/null | has -- "-j $CHAIN"; then ok "Цепочка $CHAIN подключена в raw/PREROUTING"
  else warn "Перехода в $CHAIN в raw/PREROUTING пока нет — смотри: journalctl -u tblocker"; fi
else
  if nft list table inet tblocker >/dev/null 2>&1; then ok "nft-таблица inet tblocker создана"
  else warn "nft-таблицы tblocker пока нет — смотри: journalctl -u tblocker"; fi
fi

# ============================================================================
#  ПРОВЕРКА ЛОГА XRAY
# ============================================================================
step "Проверка лога Xray"
if [ -s "$LOG_FILE" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$LOG_FILE") ))
  if [ "$age" -lt 600 ]; then
    ok "Xray пишет в $LOG_FILE (последняя запись ${age} с назад)"
    if tail -n 200 "$LOG_FILE" | has " accepted " && ! tail -n 200 "$LOG_FILE" | has "email: "; then
      warn "В логе нет полей 'email:' — tblocker не сможет определить пользователей."
    fi
  else
    warn "$LOG_FILE не обновлялся ${age} с — есть ли трафик и прописан ли лог в профиле?"
  fi
else
  warn "$LOG_FILE пустой или отсутствует — Xray пока не пишет access-лог."
fi

# ============================================================================
#  ИТОГ
# ============================================================================
printf '\n%s=====================================================================%s\n' "$C_G" "$C_0"
ok "Установка завершена"
printf '%s=====================================================================%s\n' "$C_G" "$C_0"
cat <<EOF
  Сервер (hostname)  : $NODE_NAME     <- впиши в SERVER_COUNTRIES в Solobot
  Лог                : $LOG_FILE
  Файрвол            : $FIREWALL
  Срок блокировки    : $DURATION мин
  Вебхук             : ${WEBHOOK:-выключен}
  Bypass             : ${BYPASS[*]}
  Конфиг             : $CONFIG_PATH${CONFIG_BACKUP:+  (старый: $CONFIG_BACKUP)}

  Логи:     journalctl -u tblocker -f
  Статус:   systemctl status tblocker
  Удаление: bash <(curl -fsSL $SCRIPT_URL) --uninstall
EOF

cat <<'EOF'

  ─── Проверь в панели Remnawave (Профили → конфиг Xray) ───
  "log": {
      "error": "/var/log/remnanode/error.log",
      "access": "/var/log/remnanode/access.log",
      "loglevel": "warning"
  }

  в "outbounds":
  { "tag": "TORRENT", "protocol": "blackhole" }

  в "routing" → "rules":
  { "type": "field", "protocol": ["bittorrent"], "outboundTag": "TORRENT" }

  Чтобы Xray распознавал bittorrent, у инбаундов должно быть "sniffing": { "enabled": true }.
EOF
echo
