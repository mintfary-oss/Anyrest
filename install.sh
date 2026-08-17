#!/usr/bin/env bash
##############################################################################
# Anyrest — Полностью автоматический установщик
#
# Одна команда — полностью рабочий сервер:
#
#   curl -fsSL https://raw.githubusercontent.com/mintfary-oss/Anyrest/main/install.sh | bash
#
# Что делает скрипт автоматически:
#   1. Определяет публичный IP сервера
#   2. Устанавливает Docker (если не установлен)
#   3. Настраивает зеркало Docker Hub (обход rate limit 429)
#   4. Загружает базовые образы с повторами (до 5 попыток)
#   5. Клонирует репозиторий в /opt/anyrest
#   6. Генерирует TLS-сертификаты с IP сервера
#   7. Устанавливает CA в системное хранилище
#   8. Создаёт .env с безопасным случайным секретом
#   9. Собирает и запускает Docker Compose
#  10. Выводит адрес — просто открываете в браузере
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
# 2. Установка Docker
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
# 3. Настройка зеркала Docker Hub (обход ошибки 429 Too Many Requests)
# ─────────────────────────────────────────────────────────────────────────────
configure_mirror() {
  local cfg="/etc/docker/daemon.json"

  # Пропускаем если зеркало уже настроено
  if $SUDO grep -q "registry-mirrors" "$cfg" 2>/dev/null; then
    ok "Зеркало Docker Hub уже настроено."
    return
  fi

  info "Настраиваю зеркало Docker Hub (mirror.gcr.io) для обхода rate limit..."
  $SUDO mkdir -p /etc/docker

  # Если daemon.json уже существует и содержит другие настройки — добавляем поле
  if [[ -f "$cfg" ]]; then
    # Backup
    $SUDO cp "$cfg" "${cfg}.bak"
    # Добавляем registry-mirrors через python (jq может отсутствовать)
    $SUDO python3 -c "
import json, sys
with open('$cfg') as f:
    d = json.load(f)
d.setdefault('registry-mirrors', [])
mirrors = ['https://mirror.gcr.io', 'https://dockerhub.azk8s.cn']
for m in mirrors:
    if m not in d['registry-mirrors']:
        d['registry-mirrors'].append(m)
with open('$cfg', 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null || \
    $SUDO tee "$cfg" > /dev/null <<'DAEMON'
{
  "registry-mirrors": ["https://mirror.gcr.io", "https://dockerhub.azk8s.cn"]
}
DAEMON
  else
    $SUDO tee "$cfg" > /dev/null <<'DAEMON'
{
  "registry-mirrors": ["https://mirror.gcr.io", "https://dockerhub.azk8s.cn"]
}
DAEMON
  fi

  # Перезапускаем Docker чтобы зеркало вступило в силу
  if command -v systemctl &>/dev/null; then
    info "Перезапускаю Docker daemon..."
    $SUDO systemctl restart docker
    sleep 4
  fi

  ok "Зеркало Docker Hub настроено."
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Предварительная загрузка базовых образов (с повторами)
# ─────────────────────────────────────────────────────────────────────────────
# Загружаем образы заранее, до сборки, чтобы docker compose build
# не получил 429 в середине компиляции.
pull_with_retry() {
  local image="$1"
  local max=5
  local delay=30

  for attempt in $(seq 1 $max); do
    info "Загружаю $image (попытка $attempt/$max)..."
    if docker pull "$image" 2>&1; then
      ok "Загружен: $image"
      return 0
    fi
    if [[ $attempt -lt $max ]]; then
      warn "Ошибка загрузки. Следующая попытка через ${delay}с..."
      sleep "$delay"
      delay=$((delay + 15))  # увеличиваем задержку с каждой попыткой
    fi
  done

  warn "Не удалось загрузить $image после $max попыток. Продолжаю (образ может быть в кэше)."
  return 0  # не прерываем установку — образ может быть закэширован
}

pull_base_images() {
  info "Загружаю базовые Docker-образы..."
  # Порядок важен: загружаем builder-образы первыми (они самые тяжёлые)
  pull_with_retry "golang:1.26-alpine"
  pull_with_retry "alpine:3.21"
  pull_with_retry "nginx:1.27-alpine"
  ok "Базовые образы загружены."
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Получение исходного кода
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
    ok "Код уже есть в $INSTALL_DIR (не git-репозиторий, не обновляю)."
    return
  fi

  info "Клонирую репозиторий в $INSTALL_DIR..."
  $SUDO mkdir -p "$INSTALL_DIR"
  $SUDO chown "$(id -u):$(id -g)" "$INSTALL_DIR" 2>/dev/null || true
  git clone --depth 1 --quiet "$REPO_URL" "$INSTALL_DIR"
  ok "Репозиторий загружен."
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. Генерация сертификатов
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
# 7. Установка CA в системное хранилище браузеров
# ─────────────────────────────────────────────────────────────────────────────
install_ca() {
  local ca="$INSTALL_DIR/certs/ca.crt"
  [[ -f "$ca" ]] || { warn "ca.crt не найден, пропускаю установку CA."; return; }

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
# 8. Создание .env
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
# 9. Запуск Docker Compose
# Образы уже загружены функцией pull_base_images, поэтому используем
# --pull=never чтобы docker compose не делал повторных pull-запросов.
# ─────────────────────────────────────────────────────────────────────────────
start_stack() {
  info "Собираю Docker-образы..."
  cd "$INSTALL_DIR"

  docker compose down --remove-orphans 2>/dev/null || true

  # --pull=never: базовые образы уже загружены, лишние запросы к registry не нужны
  docker compose build --pull=never 2>&1

  info "Запускаю контейнеры..."
  docker compose up -d 2>&1

  # Ждём пока web поднимется (до 60 сек)
  info "Ожидаю запуска сервисов..."
  local i=0
  while [[ $i -lt 60 ]]; do
    if wget -qO- --no-check-certificate "https://$SERVER_IP/health" &>/dev/null 2>&1; then
      break
    fi
    sleep 1
    i=$((i + 1))
  done

  ok "Все сервисы запущены."
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Установка агента (для управляемого ПК)
# ─────────────────────────────────────────────────────────────────────────────
start_agent() {
  info "Запускаю агент..."
  cd "$INSTALL_DIR"

  local signal_url
  signal_url=$(grep ANYREST_SIGNAL_URL "$INSTALL_DIR/.env" 2>/dev/null \
    | cut -d= -f2 || echo "wss://${SERVER_IP}/ws")

  ANYREST_SIGNAL_URL="$signal_url" \
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
  echo -e "  ${BOLD}Anyrest — автоматическая установка${RESET}"
  hr
  echo ""

  detect_ip
  install_docker
  configure_mirror

  if [[ "$AGENT_MODE" == "true" ]]; then
    pull_with_retry "golang:1.26-alpine"
    pull_with_retry "alpine:3.21"
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
