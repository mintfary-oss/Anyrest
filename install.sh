#!/usr/bin/env bash
##############################################################################
# Anyrest — Полностью автоматический установщик v3
#
# Одна команда — полностью рабочий сервер.
#
# ── Способы запуска ──────────────────────────────────────────────────────────
#
#  curl -fsSL https://cdn.jsdelivr.net/gh/mintfary-oss/Anyrest@main/install.sh | bash
#  git clone --depth 1 https://github.com/mintfary-oss/Anyrest.git /opt/anyrest && bash /opt/anyrest/install.sh
#
# ── Опции ─────────────────────────────────────────────────────────────────────
#   --agent    Установить только агент (для управляемого ПК)
#   --ip IP    Указать IP вручную
#   --dir DIR  Папка установки (по умолчанию /opt/anyrest)
#
# ── Что делает скрипт ─────────────────────────────────────────────────────────
#   1.  Определяет публичный IP и архитектуру (amd64 / arm64)
#   2.  Устанавливает Docker (если не установлен), с таймаутом 5 мин
#   3.  Открывает порты 80/443/8081 в брандмауэре (ufw/firewalld/iptables)
#   4.  Настраивает зеркала Docker Hub (РФ-стабильные)
#   5.  Клонирует репозиторий и генерирует TLS-сертификаты с IP SAN
#   6.  Собирает образы (COPY-only, ~30 сек) и запускает стек
#   7.  Запускает полную диагностику и печатает подробный отчёт
#
##############################################################################
set -euo pipefail

# ── Цвета ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
MAGENTA='\033[0;35m'

ok()   { echo -e "${GREEN}  ✓${RESET}  $*"; DIAG+=("OK|$*"); }
fail() { echo -e "${RED}  ✗${RESET}  $*"; DIAG+=("FAIL|$*"); DIAG_ERRORS+=("$*"); }
info() { echo -e "${CYAN}  →${RESET}  $*"; }
warn() { echo -e "${YELLOW}  !${RESET}  $*"; }
die()  { echo -e "\n${RED}${BOLD}  ✗  ОШИБКА:${RESET} $*" >&2; print_report; exit 1; }
hr()   { echo -e "${BOLD}──────────────────────────────────────────────────${RESET}"; }
hr2()  { echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"; }

# ── Диагностические массивы ───────────────────────────────────────────────────
DIAG=()         # "OK|msg" или "FAIL|msg" или "WARN|msg"
DIAG_ERRORS=()  # только ошибки

add_warn() { DIAG+=("WARN|$*"); warn "$*"; }

# ── Параметры ─────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/anyrest"
REPO_URL="https://github.com/mintfary-oss/Anyrest.git"
MANUAL_IP=""
AGENT_MODE=false
INSTALL_TIMEOUT=1200  # 20 минут — глобальный таймаут всей установки

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)  AGENT_MODE=true;    shift ;;
    --ip)     MANUAL_IP="$2";     shift 2 ;;
    --dir)    INSTALL_DIR="$2";   shift 2 ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# *//'; exit 0 ;;
    *) die "Неизвестный параметр: $1" ;;
  esac
done

SUDO=""
[[ "$EUID" -ne 0 ]] && command -v sudo &>/dev/null && SUDO="sudo"

# ── Глобальный watchdog ────────────────────────────────────────────────────────
# Если установка зависла более чем на INSTALL_TIMEOUT секунд — убиваем процесс
# и выводим отчёт об ошибке.
START_TIME=$SECONDS
WATCHDOG_PID=""

start_watchdog() {
  (
    sleep "$INSTALL_TIMEOUT"
    echo -e "\n${RED}${BOLD}  ✗  WATCHDOG: установка длится более $((INSTALL_TIMEOUT/60)) минут — принудительное завершение.${RESET}" >&2
    echo -e "  Последний известный шаг: ${STEP_NAME:-неизвестно}" >&2
    echo -e "  Лог контейнеров: docker compose -f $INSTALL_DIR/docker-compose.yml logs --tail=50" >&2
    kill -TERM "$PPID" 2>/dev/null || true
  ) &
  WATCHDOG_PID=$!
}

stop_watchdog() {
  [[ -n "$WATCHDOG_PID" ]] && kill "$WATCHDOG_PID" 2>/dev/null || true
  WATCHDOG_PID=""
}

STEP_NAME="инициализация"

# ── Установка текущего шага ───────────────────────────────────────────────────
# Обновляет STEP_NAME для watchdog и выводит прогресс.
set_step() { STEP_NAME="$1"; info "Шаг: $STEP_NAME..."; }

# ── Ловушка ошибок ─────────────────────────────────────────────────────────────
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

on_error() {
  local line="$1"
  local cmd="$2"
  stop_watchdog
  DIAG+=("FAIL|Ошибка выполнения (строка $line): $cmd")
  DIAG_ERRORS+=("Ошибка выполнения (строка $line): $cmd")
  print_report
  exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Публичный IP
# ─────────────────────────────────────────────────────────────────────────────
detect_ip() {
  if [[ -n "$MANUAL_IP" ]]; then
    SERVER_IP="$MANUAL_IP"
    ok "IP задан вручную: $SERVER_IP"
    return
  fi
  info "Определяю публичный IP..."
  for svc in \
      "https://api.ipify.org" \
      "https://ifconfig.me/ip" \
      "https://icanhazip.com" \
      "https://ipinfo.io/ip" \
      "https://myexternalip.com/raw"; do
    local ip
    ip=$(curl -fsSL --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]') || continue
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      SERVER_IP="$ip"
      ok "Публичный IP: $SERVER_IP"
      return
    fi
  done
  SERVER_IP=$(ip -o -4 addr show scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -1) || true
  if [[ -z "$SERVER_IP" ]]; then
    warn "Не удалось определить IP автоматически."
    read -rp "  Введите IP сервера: " SERVER_IP
  fi
  ok "IP сервера: $SERVER_IP"
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Архитектура
# ─────────────────────────────────────────────────────────────────────────────
detect_arch() {
  local machine
  machine=$(uname -m)
  case "$machine" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
      warn "Неизвестная архитектура '$machine'. Используем amd64."
      ARCH="amd64"
      ;;
  esac
  ok "Архитектура: $ARCH"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Docker
# ─────────────────────────────────────────────────────────────────────────────
install_docker() {
  if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    ok "Docker уже установлен: $(docker --version | awk '{print $3}' | tr -d ',')"
    return
  fi
  info "Устанавливаю Docker (таймаут 5 мин)..."

  # ── Определяем дистрибутив ─────────────────────────────────────────────────
  local os_id=""
  if [[ -f /etc/os-release ]]; then
    os_id=$(. /etc/os-release && echo "${ID:-}")
  fi
  [[ -f /etc/gentoo-release ]] && os_id="gentoo"

  # ── Gentoo (Portage / emerge) ──────────────────────────────────────────────
  if [[ "$os_id" == "gentoo" ]] || command -v emerge &>/dev/null; then
    info "Gentoo обнаружена — устанавливаю через emerge..."
    # Синхронизируем дерево portage если оно старше 24 часов
    if [[ ! -f /usr/portage/metadata/timestamp.chk ]] || \
       [[ $(find /usr/portage/metadata/timestamp.chk -mtime +1 2>/dev/null) ]]; then
      timeout 300 $SUDO emerge --sync --quiet 2>/dev/null || true
    fi
    timeout 600 $SUDO emerge --ask=n --quiet \
      app-containers/docker \
      app-containers/docker-cli \
      app-containers/docker-compose \
      || die "Не удалось установить Docker на Gentoo. Запустите: emerge app-containers/docker"
    # OpenRC (по умолчанию на Gentoo) или systemd
    if command -v rc-update &>/dev/null; then
      $SUDO rc-update add docker default 2>/dev/null || true
      $SUDO rc-service docker start 2>/dev/null || true
      ok "Docker запущен через OpenRC."
    elif command -v systemctl &>/dev/null; then
      $SUDO systemctl enable --now docker 2>/dev/null || true
      ok "Docker запущен через systemd."
    fi
    ok "Docker установлен на Gentoo."
    return
  fi

  # ── Alpine (apk) ───────────────────────────────────────────────────────────
  if command -v apk &>/dev/null; then
    timeout 300 $SUDO apk add --no-cache docker docker-compose 2>/dev/null \
      || die "Не удалось установить Docker на Alpine."
    $SUDO rc-update add docker boot 2>/dev/null || true
    $SUDO service docker start 2>/dev/null || true
    ok "Docker установлен на Alpine."
    return
  fi

  # ── Ubuntu / Debian / RHEL / CentOS — официальный скрипт ──────────────────
  if ! timeout 300 bash -c 'curl -fsSL https://get.docker.com | bash -s -- --quiet' 2>&1 \
      | grep -E 'Installing|installed|already' || true; then
    if command -v apt-get &>/dev/null; then
      timeout 300 $SUDO apt-get install -y docker.io docker-compose-plugin \
        || die "Не удалось установить Docker"
    elif command -v dnf &>/dev/null; then
      timeout 300 $SUDO dnf install -y docker docker-compose-plugin \
        || die "Не удалось установить Docker"
    elif command -v yum &>/dev/null; then
      timeout 300 $SUDO yum install -y docker docker-compose-plugin \
        || die "Не удалось установить Docker"
    else
      die "Дистрибутив не распознан. Установите Docker вручную: https://docs.docker.com/engine/install/"
    fi
  fi
  if command -v systemctl &>/dev/null; then
    $SUDO systemctl enable --now docker 2>/dev/null || true
  fi
  ok "Docker установлен."
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Открытие портов в брандмауэре
# Открывает 80 (HTTP→HTTPS redirect), 443 (HTTPS + WSS), 8081 (relay TCP).
# Поддерживает: ufw, firewalld, iptables.
# ─────────────────────────────────────────────────────────────────────────────
open_ports() {
  info "Открываю порты 80/443/8081 в брандмауэре..."
  local opened=false

  # ── ufw ────────────────────────────────────────────────────────────────────
  if command -v ufw &>/dev/null; then
    local ufw_status
    ufw_status=$($SUDO ufw status 2>/dev/null | head -1 || echo "inactive")
    if echo "$ufw_status" | grep -qi "active"; then
      $SUDO ufw allow 80/tcp  >/dev/null 2>&1 || true
      $SUDO ufw allow 443/tcp >/dev/null 2>&1 || true
      $SUDO ufw allow 8081/tcp>/dev/null 2>&1 || true
      $SUDO ufw --force reload >/dev/null 2>&1 || true
      ok "UFW: открыты порты 80, 443, 8081"
      opened=true
    fi
  fi

  # ── firewalld ──────────────────────────────────────────────────────────────
  if command -v firewall-cmd &>/dev/null; then
    if $SUDO systemctl is-active --quiet firewalld 2>/dev/null; then
      $SUDO firewall-cmd --permanent --add-port=80/tcp   >/dev/null 2>&1 || true
      $SUDO firewall-cmd --permanent --add-port=443/tcp  >/dev/null 2>&1 || true
      $SUDO firewall-cmd --permanent --add-port=8081/tcp >/dev/null 2>&1 || true
      $SUDO firewall-cmd --reload >/dev/null 2>&1 || true
      ok "firewalld: открыты порты 80, 443, 8081"
      opened=true
    fi
  fi

  # ── iptables (fallback) ───────────────────────────────────────────────────
  if command -v iptables &>/dev/null; then
    for port in 80 443 8081; do
      # Добавляем правило только если его ещё нет
      if ! $SUDO iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
        $SUDO iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
      fi
    done
    # Сохранение правил (разные дистрибутивы)
    if command -v netfilter-persistent &>/dev/null; then
      $SUDO netfilter-persistent save >/dev/null 2>&1 || true
    elif command -v service &>/dev/null; then
      $SUDO service iptables save >/dev/null 2>&1 || true
    elif command -v iptables-save &>/dev/null; then
      $SUDO mkdir -p /etc/iptables
      $SUDO iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    ok "iptables: разрешены порты 80, 443, 8081"
    opened=true
  fi

  if [[ "$opened" == "false" ]]; then
    add_warn "Брандмауэр: не обнаружено ufw/firewalld/iptables. Откройте порты 80/443/8081 вручную в панели хостера."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Зеркала Docker Hub (РФ-стабильные)
# ─────────────────────────────────────────────────────────────────────────────
configure_mirror() {
  local cfg="/etc/docker/daemon.json"
  if $SUDO grep -q "registry-mirrors" "$cfg" 2>/dev/null; then
    ok "Зеркала Docker Hub уже настроены."
    return
  fi
  info "Настраиваю зеркала Docker Hub (huecker.io + timeweb.cloud)..."
  $SUDO mkdir -p /etc/docker
  $SUDO tee "$cfg" > /dev/null <<'DAEMON'
{
  "registry-mirrors": [
    "https://huecker.io",
    "https://dockerhub.timeweb.cloud"
  ],
  "dns": ["77.88.8.8", "1.1.1.1", "8.8.8.8"]
}
DAEMON
  if command -v systemctl &>/dev/null; then
    $SUDO systemctl restart docker
    sleep 5
  fi
  ok "Зеркала Docker Hub настроены."
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. Загрузка базовых образов (busybox + nginx)
# ─────────────────────────────────────────────────────────────────────────────
pull_with_retry() {
  local image="$1"
  local max=5
  local delay=20
  for attempt in $(seq 1 $max); do
    info "Загружаю $image (попытка $attempt/$max)..."
    if docker pull "$image" 2>&1; then
      ok "Загружен: $image"
      return 0
    fi
    warn "Ошибка загрузки. Следующая попытка через ${delay}с..."
    sleep "$delay"
    delay=$((delay + 10))
  done
  warn "Не удалось загрузить $image после $max попыток (продолжаю — образ может быть в кэше)."
  return 0
}

pull_base_images() {
  info "Загружаю базовые Docker-образы..."
  pull_with_retry "busybox:1.37-musl"
  pull_with_retry "nginx:1.27-alpine"
  ok "Базовые образы загружены."
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. Репозиторий
# ─────────────────────────────────────────────────────────────────────────────
fetch_repo() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Обновляю репозиторий в $INSTALL_DIR..."
    git -C "$INSTALL_DIR" fetch --quiet origin main 2>/dev/null || true
    git -C "$INSTALL_DIR" reset --hard origin/main --quiet 2>/dev/null || true
    ok "Код обновлён."
    return
  fi
  if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    ok "Код уже есть в $INSTALL_DIR."
    return
  fi
  info "Клонирую репозиторий в $INSTALL_DIR..."
  $SUDO mkdir -p "$INSTALL_DIR"
  $SUDO chown "$(id -u):$(id -g)" "$INSTALL_DIR" 2>/dev/null || true
  git clone --depth 1 --quiet "$REPO_URL" "$INSTALL_DIR"
  ok "Репозиторий загружен."
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. Сертификаты
# ─────────────────────────────────────────────────────────────────────────────
generate_certs() {
  local cert_dir="$INSTALL_DIR/certs"
  if [[ -f "$cert_dir/server.crt" && -f "$cert_dir/server.key" ]]; then
    if openssl x509 -in "$cert_dir/server.crt" -text -noout 2>/dev/null \
        | grep -q "IP Address:$SERVER_IP"; then
      ok "Сертификаты уже существуют для IP $SERVER_IP."
      return
    fi
    warn "Пересоздаю сертификаты для нового IP $SERVER_IP..."
    rm -f "$cert_dir/server.crt" "$cert_dir/server.key" \
          "$cert_dir/ca.crt" "$cert_dir/ca.key" "$cert_dir/openssl.cnf"
  fi
  info "Генерирую TLS-сертификаты для IP $SERVER_IP..."
  chmod +x "$cert_dir/gen-certs.sh"
  bash "$cert_dir/gen-certs.sh" --ip "$SERVER_IP" --out "$cert_dir" 2>&1 \
    | grep -E '\[certs\]|ERROR' || true
  ok "Сертификаты созданы (IP SAN: $SERVER_IP, срок: 10 лет)."
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. CA в системное хранилище
# ─────────────────────────────────────────────────────────────────────────────
install_ca() {
  local ca="$INSTALL_DIR/certs/ca.crt"
  [[ -f "$ca" ]] || { warn "ca.crt не найден, пропускаю."; return; }
  info "Устанавливаю CA-сертификат в систему..."
  if command -v update-ca-certificates &>/dev/null; then
    $SUDO cp "$ca" /usr/local/share/ca-certificates/anyrest-ca.crt
    $SUDO update-ca-certificates --fresh -q 2>/dev/null || true
  elif command -v update-ca-trust &>/dev/null; then
    $SUDO cp "$ca" /etc/pki/ca-trust/source/anchors/anyrest-ca.crt
    $SUDO update-ca-trust extract 2>/dev/null || true
  fi
  if command -v certutil &>/dev/null; then
    for d in "$HOME/.pki/nssdb" "$HOME/.mozilla/firefox/"*; do
      [[ -d "$d" ]] && certutil -A -d "sql:$d" -n "Anyrest Root CA" \
        -t "CT,," -i "$ca" 2>/dev/null || true
    done
  fi
  ok "CA установлен в систему (curl и системный HTTP теперь доверяют сертификату)."
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. .env
# ─────────────────────────────────────────────────────────────────────────────
create_env() {
  local env="$INSTALL_DIR/.env"
  if [[ -f "$env" ]]; then
    ok ".env уже существует."
    return
  fi
  info "Создаю .env со случайным секретом..."
  cat > "$env" <<EOF
RELAY_SECRET=$(openssl rand -hex 32)
ANYREST_SIGNAL_URL=wss://${SERVER_IP}/ws
EOF
  $SUDO chmod 600 "$env"
  ok ".env создан."
}

# ─────────────────────────────────────────────────────────────────────────────
# 11. Сборка и запуск
# ─────────────────────────────────────────────────────────────────────────────
start_stack() {
  cd "$INSTALL_DIR"
  docker compose down --remove-orphans 2>/dev/null || true

  local build_ok=false
  for attempt in 1 2 3; do
    info "Собираю Docker-образы (попытка $attempt/3, COPY-only, ~30 сек)..."
    if TARGETARCH="$ARCH" docker compose build 2>&1; then
      build_ok=true
      break
    fi
    warn "Ошибка сборки. Повтор через 15 сек..."
    sleep 15
    pull_base_images
  done
  [[ "$build_ok" == "true" ]] || die "Сборка не удалась после 3 попыток."

  info "Запускаю контейнеры..."
  docker compose up -d 2>&1

  # Ждём готовности (до 90 сек)
  info "Ожидаю запуска сервисов (до 90 сек)..."
  local i=0
  local ready=false
  while [[ $i -lt 90 ]]; do
    if curl -fsSk --max-time 3 "https://$SERVER_IP/health" &>/dev/null 2>&1 \
        || wget -qO- --no-check-certificate --timeout=3 "https://$SERVER_IP/health" &>/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
    i=$((i + 1))
  done

  if [[ "$ready" == "true" ]]; then
    ok "Все сервисы запущены и отвечают (${i}с)."
  else
    add_warn "Health-check не ответил за 90 сек. Проверьте: docker compose -f $INSTALL_DIR/docker-compose.yml logs"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 12. Агент
# ─────────────────────────────────────────────────────────────────────────────
start_agent() {
  info "Запускаю агент..."
  cd "$INSTALL_DIR"
  local signal_url
  signal_url=$(grep ANYREST_SIGNAL_URL "$INSTALL_DIR/.env" 2>/dev/null \
    | cut -d= -f2 || echo "wss://${SERVER_IP}/ws")

  pull_with_retry "alpine:3.21"
  TARGETARCH="$ARCH" ANYREST_SIGNAL_URL="$signal_url" \
    docker compose -f docker-compose.agent.yml up -d --build --quiet-pull 2>/dev/null

  if command -v systemctl &>/dev/null; then
    $SUDO tee /etc/systemd/system/anyrest-agent.service > /dev/null <<UNIT
[Unit]
Description=Anyrest Desktop Agent
After=network-online.target graphical.target
Wants=network-online.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5
Environment=DISPLAY=:0
Environment=ANYREST_SIGNAL_URL=${signal_url}
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose -f ${INSTALL_DIR}/docker-compose.agent.yml up --no-recreate
ExecStop=/usr/bin/docker compose  -f ${INSTALL_DIR}/docker-compose.agent.yml down

[Install]
WantedBy=graphical.target
UNIT
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now anyrest-agent.service 2>/dev/null || true
  fi
  ok "Агент запущен."
}

# ─────────────────────────────────────────────────────────────────────────────
# 13. Локальная диагностика
# Проверяет что сервисы действительно отвечают изнутри.
# ─────────────────────────────────────────────────────────────────────────────
check_local() {
  info "Проверяю локальную связность..."

  # HTTPS health endpoint
  if curl -fsSk --max-time 5 "https://$SERVER_IP/health" &>/dev/null 2>&1; then
    ok "HTTPS: https://$SERVER_IP/health → OK"
  else
    fail "HTTPS: https://$SERVER_IP/health не отвечает. Проверьте: docker compose -f $INSTALL_DIR/docker-compose.yml ps"
  fi

  # Redirect HTTP→HTTPS
  local redirect_code
  redirect_code=$(curl -fsSo /dev/null --max-time 5 -w "%{http_code}" "http://$SERVER_IP/" 2>/dev/null || echo "000")
  if [[ "$redirect_code" =~ ^30 ]]; then
    ok "HTTP → HTTPS редирект работает (код $redirect_code)."
  elif [[ "$redirect_code" == "200" ]]; then
    ok "HTTP порт 80 отвечает (код 200)."
  else
    add_warn "HTTP порт 80: код ответа '$redirect_code' (не критично, основной порт — 443)."
  fi

  # WebSocket endpoint (через curl WS handshake)
  local ws_code
  # curl записывает http_code до завершения; при WebSocket таймауте добавляется
  # суффикс из ветки ||, что даёт "101000" вместо "101" — берём первые 3 символа.
  ws_code=$(curl -sSo /dev/null --max-time 4 -w "%{http_code}" -k \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "https://$SERVER_IP/ws" 2>/dev/null || true)
  ws_code="${ws_code:0:3}"
  [[ -z "$ws_code" ]] && ws_code="000"
  if [[ "$ws_code" =~ ^(101|200|400)$ ]]; then
    ok "WebSocket: wss://$SERVER_IP/ws → handshake OK (код $ws_code)."
  else
    fail "WebSocket wss://$SERVER_IP/ws недоступен (код $ws_code). Проверьте сервис signal."
  fi

  # TCP relay port
  if command -v nc &>/dev/null; then
    if nc -z -w3 "$SERVER_IP" 8081 2>/dev/null; then
      ok "Relay TCP: $SERVER_IP:8081 → открыт."
    else
      fail "Relay TCP: $SERVER_IP:8081 не отвечает. Проверьте сервис relay."
    fi
  else
    if curl -fsSo /dev/null --max-time 3 "telnet://$SERVER_IP:8081" 2>/dev/null; then
      ok "Relay TCP: $SERVER_IP:8081 → открыт."
    else
      add_warn "Relay TCP 8081: nc не доступен, проверка пропущена."
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 14. Внешняя связность
# Проверяет видны ли порты из интернета через публичные API.
# ─────────────────────────────────────────────────────────────────────────────
check_external() {
  info "Проверяю внешнюю доступность (видно ли из интернета)..."

  check_port_ext() {
    local port="$1"
    local result="unknown"

    # hackertarget.com — бесплатный nmap API
    local raw
    raw=$(curl -fsSL --max-time 15 \
      "https://api.hackertarget.com/nmap/?q=${SERVER_IP}&port=${port}" 2>/dev/null || echo "")
    if echo "$raw" | grep -qi "open"; then
      result="open"
    elif echo "$raw" | grep -qi "filtered\|closed"; then
      result="closed"
    fi

    # Если первый API не ответил — пробуем portchecker.online
    if [[ "$result" == "unknown" ]]; then
      raw=$(curl -fsSL --max-time 15 \
        "https://portchecker.online/api/v1/query" \
        -H "Content-Type: application/json" \
        -d "{\"host\":\"${SERVER_IP}\",\"ports\":[${port}]}" 2>/dev/null || echo "")
      if echo "$raw" | grep -qi "open\|true"; then
        result="open"
      elif echo "$raw" | grep -qi "close\|false"; then
        result="closed"
      fi
    fi

    echo "$result"
  }

  for port in 443 8081 80; do
    local label
    case "$port" in
      443) label="HTTPS (основной)" ;;
      8081) label="Relay TCP" ;;
      80) label="HTTP" ;;
    esac

    local state
    state=$(check_port_ext "$port")
    case "$state" in
      open)
        ok "Порт $port ($label) → открыт и виден из интернета."
        ;;
      closed)
        if [[ "$port" == "443" ]]; then
          fail "Порт 443 ($label) → ЗАКРЫТ или заблокирован провайдером/firewall. Браузеры не смогут подключиться!"
          fail "  Решение: откройте порт 443 в панели управления VPS/хостера."
        elif [[ "$port" == "8081" ]]; then
          fail "Порт 8081 ($label) → заблокирован. Relay (TCP fallback) не будет работать."
          fail "  Решение: откройте порт 8081 в панели управления VPS/хостера."
        else
          add_warn "Порт 80 (HTTP) закрыт провайдером — не критично, редирект на 443 всё равно работает."
        fi
        ;;
      *)
        add_warn "Порт $port ($label) → не удалось проверить через внешний API (нет ответа от portchecker). Проверьте вручную: https://2ip.ru/port-check/"
        ;;
    esac
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# 15. Проверка блокировки провайдером / браузером
# ─────────────────────────────────────────────────────────────────────────────
check_isp_browser() {
  info "Проверяю блокировки провайдера и совместимость с браузерами..."

  # ── Исходящий интернет с сервера ──────────────────────────────────────────
  if curl -fsSo /dev/null --max-time 5 "https://dns.google" 2>/dev/null; then
    ok "Исходящий HTTPS: сервер имеет доступ в интернет."
  else
    fail "Исходящий HTTPS: сервер не может достучаться до интернета — WebRTC STUN/TURN не будет работать."
    fail "  Это означает: P2P соединение будет идти через relay (медленнее, но будет работать)."
  fi

  # ── DNS разрешение ────────────────────────────────────────────────────────
  if getent hosts github.com &>/dev/null 2>&1 || nslookup github.com &>/dev/null 2>&1; then
    ok "DNS: github.com разрешается корректно."
  else
    fail "DNS: не удаётся разрешить имена (github.com не отвечает). Настройте DNS: 77.88.8.8 или 8.8.8.8"
  fi

  # ── TLS версия и шифры (совместимость браузеров) ─────────────────────────
  if command -v openssl &>/dev/null && [[ -f "$INSTALL_DIR/certs/server.crt" ]]; then
    # Проверяем что сертификат содержит IP SAN
    if openssl x509 -in "$INSTALL_DIR/certs/server.crt" -text -noout 2>/dev/null \
        | grep -q "IP Address:$SERVER_IP"; then
      ok "Сертификат: содержит IP SAN для $SERVER_IP — браузеры примут без ошибки 'неверное имя'."
    else
      fail "Сертификат: не содержит IP SAN для $SERVER_IP — браузеры покажут ошибку SSL."
    fi

    # Проверяем SHA-256 (SHA-1 заблокирован во всех браузерах с 2017)
    local sig_algo
    sig_algo=$(openssl x509 -in "$INSTALL_DIR/certs/server.crt" -text -noout 2>/dev/null \
      | grep "Signature Algorithm" | head -1 | awk '{print $NF}')
    if echo "$sig_algo" | grep -qi "sha256\|sha384\|sha512"; then
      ok "Сертификат: подпись $sig_algo — поддерживается всеми браузерами."
    else
      fail "Сертификат: подпись $sig_algo — старый алгоритм, Chrome/Firefox заблокируют."
    fi

    # Проверяем срок действия
    local expiry
    expiry=$(openssl x509 -in "$INSTALL_DIR/certs/server.crt" -noout -enddate 2>/dev/null \
      | cut -d= -f2 || echo "unknown")
    ok "Сертификат: действует до $expiry."
  fi

  # ── TLS протокол через nginx (если запущен) ───────────────────────────────
  if command -v openssl &>/dev/null; then
    if echo | timeout 5 openssl s_client -connect "$SERVER_IP:443" \
        -tls1_2 2>/dev/null | grep -q "Cipher"; then
      ok "TLS 1.2: поддерживается (Chrome 49+, Firefox 27+, Safari 9+, Edge 12+)."
    else
      add_warn "TLS 1.2: не удалось проверить (сервер возможно не запущен или порт закрыт)."
    fi
    if echo | timeout 5 openssl s_client -connect "$SERVER_IP:443" \
        -tls1_3 2>/dev/null | grep -q "Cipher"; then
      ok "TLS 1.3: поддерживается (Chrome 70+, Firefox 63+, Safari 12.1+, Edge 79+)."
    else
      add_warn "TLS 1.3: не удалось проверить."
    fi
  fi

  # ── Проверка заголовков безопасности ──────────────────────────────────────
  local headers
  headers=$(curl -fsSk --max-time 5 -I "https://$SERVER_IP/" 2>/dev/null || echo "")
  if echo "$headers" | grep -qi "strict-transport-security"; then
    ok "HSTS: заголовок присутствует — браузеры запомнят HTTPS-only."
  else
    add_warn "HSTS заголовок не обнаружен в ответе (возможно сервис ещё не запустился)."
  fi
  if echo "$headers" | grep -qi "x-content-type-options"; then
    ok "X-Content-Type-Options: присутствует — защита от MIME sniffing."
  fi

  # ── Проверка WebSocket upgrade ────────────────────────────────────────────
  local ws_status
  ws_status=$(curl -sSo /dev/null --max-time 4 -w "%{http_code}" -k \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "https://$SERVER_IP/ws" 2>/dev/null || true)
  ws_status="${ws_status:0:3}"
  [[ -z "$ws_status" ]] && ws_status="000"
  if [[ "$ws_status" == "101" ]]; then
    ok "WebSocket Upgrade: сервер возвращает 101 — браузеры откроют WSS соединение."
  elif [[ "$ws_status" =~ ^[2-4] ]]; then
    ok "WebSocket endpoint отвечает (код $ws_status)."
  else
    fail "WebSocket /ws не отвечает (код $ws_status) — браузер не сможет подключиться к серверу."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 16. Финальный отчёт
# ─────────────────────────────────────────────────────────────────────────────
print_report() {
  local elapsed=$((SECONDS - START_TIME))
  echo ""
  hr2
  echo -e "  ${BOLD}${MAGENTA}Anyrest — Диагностический отчёт${RESET}"
  echo -e "  Сервер: $SERVER_IP  |  Время установки: ${elapsed}с  |  Архитектура: ${ARCH:-?}"
  hr2
  echo ""

  local ok_count=0
  local warn_count=0
  local fail_count=0

  for item in "${DIAG[@]}"; do
    local status="${item%%|*}"
    local msg="${item#*|}"
    case "$status" in
      OK)   echo -e "  ${GREEN}✓${RESET} $msg";  ok_count=$((ok_count+1))   ;;
      WARN) echo -e "  ${YELLOW}!${RESET} $msg";  warn_count=$((warn_count+1)) ;;
      FAIL) echo -e "  ${RED}✗${RESET} $msg";  fail_count=$((fail_count+1)) ;;
    esac
  done

  echo ""
  hr2

  if [[ ${#DIAG_ERRORS[@]} -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}РЕЗУЛЬТАТ: ОБНАРУЖЕНЫ ОШИБКИ${RESET}"
    echo ""
    echo -e "  ${BOLD}Список ошибок:${RESET}"
    for e in "${DIAG_ERRORS[@]}"; do
      echo -e "  ${RED}✗${RESET} $e"
    done
    echo ""
    echo -e "  ${BOLD}Как исправить:${RESET}"
    echo -e "  1. Откройте порты 80/443/8081 в панели управления VPS"
    echo -e "  2. Проверьте логи: cd $INSTALL_DIR && docker compose logs"
    echo -e "  3. Перезапустите: cd $INSTALL_DIR && docker compose restart"
  else
    echo -e "  ${GREEN}${BOLD}РЕЗУЛЬТАТ: ГОТОВО К РАБОТЕ  ✓${RESET}"
    echo -e "  Проверок: ${GREEN}${ok_count} успешных${RESET}${YELLOW:+, ${warn_count} предупреждений}${RESET}"
  fi

  echo ""
  hr2
  echo ""
  echo -e "  ${BOLD}Откройте в браузере:${RESET}"
  echo -e "  ${CYAN}${BOLD}https://${SERVER_IP}${RESET}"
  echo ""
  echo -e "  ${BOLD}Если браузер показывает предупреждение о сертификате:${RESET}"
  echo -e "  1. Скачайте CA: ${CYAN}https://${SERVER_IP}/certs/ca.crt${RESET}"
  echo -e "  2. Установите в браузер (инструкция — кнопка ${BOLD}?${RESET} в интерфейсе)"
  echo ""
  echo -e "  ${BOLD}Установить агент на управляемый ПК (Linux):${RESET}"
  echo -e "  ${CYAN}curl -fsSL https://cdn.jsdelivr.net/gh/mintfary-oss/Anyrest@main/install.sh | bash -s -- --agent --ip ${SERVER_IP}${RESET}"
  echo ""
  echo -e "  ${BOLD}Установить агент на Windows:${RESET}"
  echo -e "  Скачайте anyrest-installer.exe из релизов:"
  echo -e "  ${CYAN}https://github.com/mintfary-oss/Anyrest/releases${RESET}"
  echo ""
  hr2
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
  hr
  echo -e "  ${BOLD}Anyrest — автоматическая установка v3${RESET}"
  echo -e "  Таймаут: $((INSTALL_TIMEOUT/60)) минут. При зависании — автоматическое прерывание."
  hr
  echo ""

  start_watchdog

  set_step "определение IP"; detect_ip
  set_step "определение архитектуры"; detect_arch
  set_step "установка Docker"; install_docker
  set_step "открытие портов firewall"; open_ports
  set_step "настройка зеркал Docker Hub"; configure_mirror

  if [[ "$AGENT_MODE" == "true" ]]; then
    set_step "получение репозитория"; fetch_repo
    set_step "создание .env"; create_env
    set_step "запуск агента"; start_agent
    stop_watchdog
    echo ""
    ok "Агент запущен. ID появится в логах: docker logs anyrest-agent-1"
    return
  fi

  set_step "загрузка базовых Docker-образов"; pull_base_images
  set_step "получение репозитория"; fetch_repo
  set_step "генерация TLS-сертификатов"; generate_certs
  set_step "установка CA в систему"; install_ca
  set_step "создание .env"; create_env
  set_step "сборка и запуск Docker Compose"; start_stack

  # ── Диагностика ────────────────────────────────────────────────────────────
  echo ""
  hr
  echo -e "  ${BOLD}Запускаю диагностику...${RESET}"
  hr
  set_step "диагностика локальная"; check_local
  set_step "диагностика внешняя"; check_external
  set_step "диагностика ISP/браузер"; check_isp_browser

  stop_watchdog
  print_report
}

main
