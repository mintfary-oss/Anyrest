#!/usr/bin/env bash
##############################################################################
# Anyrest — Полностью автоматический установщик v2
#
# Одна команда — полностью рабочий сервер (~2–3 минуты).
#
# ── Способы запуска ──────────────────────────────────────────────────────────
#
# Вариант 1 — jsDelivr CDN (рекомендуется, без rate limit):
#   curl -fsSL https://cdn.jsdelivr.net/gh/mintfary-oss/Anyrest@main/install.sh | bash
#
# Вариант 2 — GitHub Raw (если не возвращает 429):
#   curl -fsSL https://raw.githubusercontent.com/mintfary-oss/Anyrest/main/install.sh | bash
#
# Вариант 3 — wget:
#   wget -qO- https://raw.githubusercontent.com/mintfary-oss/Anyrest/main/install.sh | bash
#
# Вариант 4 — git clone (самый надёжный, без HTTP rate limit):
#   git clone --depth 1 https://github.com/mintfary-oss/Anyrest.git /opt/anyrest
#   cd /opt/anyrest && bash install.sh
#
# ── Что делает скрипт ────────────────────────────────────────────────────────
#   1. Определяет публичный IP и архитектуру (amd64 / arm64)
#   2. Устанавливает Docker (если не установлен)
#   3. Настраивает зеркала Docker Hub (РФ-стабильные: huecker.io, timeweb.cloud)
#   4. Загружает только нужные базовые образы: alpine (~8 MB), nginx (~40 MB)
#   5. Клонирует репозиторий в /opt/anyrest
#   6. Генерирует TLS-сертификаты с IP сервера (10 лет, IP-SAN)
#   7. Устанавливает CA в системное хранилище
#   8. Создаёт .env с безопасным случайным секретом
#   9. Собирает образы (только COPY — без компиляции!) и запускает стек
#  10. Выводит адрес — просто открываете в браузере
#
# Почему быстро: Go-бинарники и React-приложение уже собраны и лежат
# в репозитории (bin/, web/dist/). Docker только копирует их в образы.
#
# Опции:
#   --agent    Установить только агент (для управляемого ПК)
#   --ip IP    Указать IP вручную (если авто-определение не сработало)
#   --dir DIR  Папка установки (по умолчанию /opt/anyrest)
##############################################################################
set -euo pipefail

# ── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}  ✓${RESET}  $*"; }
info() { echo -e "${CYAN}  →${RESET}  $*"; }
warn() { echo -e "${YELLOW}  !${RESET}  $*"; }
die()  { echo -e "${RED}  ✗  ОШИБКА:${RESET} $*" >&2; exit 1; }
hr()   { echo -e "${BOLD}──────────────────────────────────────────────────${RESET}"; }

# ── Параметры ─────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/anyrest"
REPO_URL="https://github.com/mintfary-oss/Anyrest.git"
MANUAL_IP=""
AGENT_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)  AGENT_MODE=true;     shift ;;
    --ip)     MANUAL_IP="$2";      shift 2 ;;
    --dir)    INSTALL_DIR="$2";    shift 2 ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!' | sed 's/^# *//'
      exit 0 ;;
    *) die "Неизвестный параметр: $1" ;;
  esac
done

SUDO=""
[[ "$EUID" -ne 0 ]] && command -v sudo &>/dev/null && SUDO="sudo"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Определение публичного IP
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
      "https://ipinfo.io/ip"; do
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
# 2. Определение архитектуры
# (бинарники собраны для amd64 и arm64 — выбираем нужный)
# ─────────────────────────────────────────────────────────────────────────────
detect_arch() {
  local machine
  machine=$(uname -m)
  case "$machine" in
    x86_64|amd64)       ARCH="amd64" ;;
    aarch64|arm64)      ARCH="arm64" ;;
    *)
      warn "Неизвестная архитектура '$machine'. Используем amd64."
      ARCH="amd64"
      ;;
  esac
  ok "Архитектура: $ARCH"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Установка Docker
# ─────────────────────────────────────────────────────────────────────────────
install_docker() {
  if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    ok "Docker уже установлен: $(docker --version | awk '{print $3}' | tr -d ',')"
    return
  fi
  info "Устанавливаю Docker..."
  curl -fsSL https://get.docker.com | $SUDO bash -s -- --quiet 2>&1 \
    | grep -E 'Installing|installed|already' || true
  if command -v systemctl &>/dev/null; then
    $SUDO systemctl enable --now docker 2>/dev/null || true
  fi
  ok "Docker установлен."
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Настройка зеркал Docker Hub
#
# Зеркала подобраны для стабильной работы в России:
#   huecker.io              — публичное зеркало, работает в РФ
#   dockerhub.timeweb.cloud — зеркало российского хостера Timeweb
#
# DNS: Yandex (77.88.8.8) + Cloudflare (1.1.1.1) + Google (8.8.8.8)
# ─────────────────────────────────────────────────────────────────────────────
configure_mirror() {
  local cfg="/etc/docker/daemon.json"
  if $SUDO grep -q "registry-mirrors" "$cfg" 2>/dev/null; then
    ok "Зеркала Docker Hub уже настроены."
    return
  fi

  info "Настраиваю зеркала Docker Hub (РФ-стабильные)..."
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
    info "Перезапускаю Docker daemon..."
    $SUDO systemctl restart docker
    sleep 5
  fi
  ok "Зеркала Docker Hub настроены (huecker.io, timeweb.cloud)."
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Предварительная загрузка базовых образов (с повторами)
#
# Нужны только alpine и nginx — всего ~48 MB.
# golang больше НЕ нужен: бинарники уже собраны и лежат в bin/.
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
    if [[ $attempt -lt $max ]]; then
      warn "Ошибка загрузки. Следующая попытка через ${delay}с..."
      sleep "$delay"
      delay=$((delay + 10))
    fi
  done
  warn "Не удалось загрузить $image после $max попыток (продолжаю — образ может быть в кэше)."
  return 0
}

pull_base_images() {
  info "Загружаю базовые Docker-образы (~48 MB)..."
  pull_with_retry "alpine:3.21"
  pull_with_retry "nginx:1.27-alpine"
  ok "Базовые образы загружены."
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. Получение исходного кода
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
# 7. Генерация сертификатов
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
  ok "Сертификаты созданы."
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. Установка CA в системное хранилище
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
  ok "CA установлен в систему."
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. Создание .env
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
# 10. Сборка и запуск Docker Compose
#
# БЫСТРО: Docker только копирует готовые бинарники из bin/linux-${ARCH}/ в образы.
# Компиляция Go и npm НЕ выполняется — весь код уже собран локально.
# Ожидаемое время: ~30 секунд (вместо прежних 45+ минут).
# ─────────────────────────────────────────────────────────────────────────────
start_stack() {
  cd "$INSTALL_DIR"
  docker compose down --remove-orphans 2>/dev/null || true

  # Сборка с повтором (на случай временных ошибок сети)
  local build_ok=false
  for attempt in 1 2 3; do
    info "Собираю Docker-образы (попытка $attempt/3, только COPY — должно быть быстро)..."
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

  # Ожидаем готовности (до 60 сек)
  info "Ожидаю запуска сервисов..."
  local i=0
  while [[ $i -lt 60 ]]; do
    if wget -qO- --no-check-certificate "https://$SERVER_IP/health" \
        &>/dev/null 2>&1; then
      break
    fi
    sleep 1
    i=$((i + 1))
  done
  ok "Все сервисы запущены."
}

# ─────────────────────────────────────────────────────────────────────────────
# 11. Установка агента (управляемый ПК)
# ─────────────────────────────────────────────────────────────────────────────
start_agent() {
  info "Запускаю агент..."
  cd "$INSTALL_DIR"
  local signal_url
  signal_url=$(grep ANYREST_SIGNAL_URL "$INSTALL_DIR/.env" 2>/dev/null \
    | cut -d= -f2 || echo "wss://${SERVER_IP}/ws")

  # Загружаем только alpine (~8 MB) — golang больше не нужен
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
# Итоговый вывод
# ─────────────────────────────────────────────────────────────────────────────
print_done() {
  hr
  echo ""
  echo -e "  ${GREEN}${BOLD}Anyrest успешно установлен!${RESET}"
  echo ""
  echo -e "  ${BOLD}Откройте в браузере:${RESET}"
  echo -e "  ${CYAN}${BOLD}https://${SERVER_IP}${RESET}"
  echo ""
  echo -e "  ${BOLD}Если браузер показывает предупреждение о сертификате:${RESET}"
  echo -e "  1. Скачайте CA:  ${CYAN}https://${SERVER_IP}/certs/ca.crt${RESET}"
  echo -e "  2. Установите в браузер (инструкция: кнопка ${BOLD}?${RESET} в интерфейсе)"
  echo ""
  echo -e "  ${BOLD}Установить агент на управляемый ПК:${RESET}"
  echo -e "  ${CYAN}curl -fsSL https://raw.githubusercontent.com/mintfary-oss/Anyrest/main/install.sh | bash -s -- --agent --ip ${SERVER_IP}${RESET}"
  echo ""
  hr
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
  hr
  echo -e "  ${BOLD}Anyrest — автоматическая установка v2${RESET}"
  hr
  echo ""

  detect_ip
  detect_arch
  install_docker
  configure_mirror

  if [[ "$AGENT_MODE" == "true" ]]; then
    fetch_repo
    create_env
    start_agent
    echo ""
    ok "Агент запущен. ID появится в логах: docker logs anyrest-agent-1"
    return
  fi

  pull_base_images
  fetch_repo
  generate_certs
  install_ca
  create_env
  start_stack
  print_done
}

main
