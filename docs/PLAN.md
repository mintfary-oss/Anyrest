# План создания Anyrest

## Концепция

Anyrest — самостоятельно размещаемый аналог AnyDesk/TeamViewer. Работает **без облачных сервисов**, разворачивается одной командой через Docker.

---

## Архитектура

```
Browser ──HTTPS──► NGINX :443 ──► React Web Client (pre-built dist)
Browser ──WSS────► NGINX :443 ──► Signaling Server :8080 (internal)
Agent   ──WS─────►              Signaling Server :8080 (internal)
Agent   ──TCP────►              Relay Server     :8081

WebRTC P2P:  Agent ◄──DTLS 1.3 + AES-256-GCM──► Browser
Relay fall:  Agent ──TCP──► Relay ──TCP──► Browser (если P2P недоступен)
```

---

## Стек технологий

| Компонент | Технология |
|-----------|-----------|
| Серверы | Go 1.26 + gorilla/websocket |
| WebRTC агент | pion/webrtc v4 |
| Захват экрана | kbinani/screenshot (X11/DXGI/CoreGraphics) |
| Ввод (Linux) | xdotool (X11 XTEST) |
| Веб-клиент | React 19 + TypeScript 6 + Vite 8 |
| Сертификаты | OpenSSL (IP-SAN, 4096 bit) |
| Контейнеры | Docker Compose + NGINX 1.27 |
| Node.js | **Только для локальной сборки** — на сервере не нужен |

---

## Протокол сигнализации

```
Viewer (Browser)         Signaling Server        Agent (Host)
     │── register ──────────────►│                    │
     │◄─ register_ack (ID) ──────│                    │
     │                           │◄─── register ──────│
     │                           │──── register_ack ─►│
     │── connect(target_id) ─────►│                   │
     │                           │──── connect_ack ──►│
     │                           │◄─── offer (SDP) ───│
     │◄─ offer ──────────────────│                    │
     │── answer ─────────────────►│                   │
     │                           │──── answer ───────►│
     │◄══ ICE ═══════════════════►◄══ ICE ════════════│
     │◄══════════ WebRTC P2P (DTLS + AES-256) ════════│
```

## Формат JPEG-фрейма (Data Channel)

```
Offset  Size  Field
0       4     Magic 0xA2E501F2 (little-endian)
4       2     Width (px)
6       2     Height (px)
8       4     Sequence number
12      N     JPEG payload
```

---

## Безопасность

| Слой | Механизм |
|------|---------|
| Транспорт | TLS 1.3 (HTTPS/WSS) |
| P2P медиа | DTLS 1.3 + AES-256-GCM |
| Relay auth | HMAC-SHA256, временно́е окно 30 сек |
| Сертификат | Self-signed CA + IP-SAN |
| Идентификаторы | 9-значные случайные числа |

---

## Развёртывание

### Сервер (~2–3 минуты)

**Если raw.githubusercontent.com возвращает 429 — используйте jsDelivr:**

```bash
# Вариант 1 — jsDelivr CDN (рекомендуется, без rate limit):
curl -fsSL https://cdn.jsdelivr.net/gh/mintfary-oss/Anyrest@main/install.sh | bash

# Вариант 2 — GitHub Raw:
curl -fsSL https://raw.githubusercontent.com/mintfary-oss/Anyrest/main/install.sh | bash

# Вариант 3 — wget:
wget -qO- https://raw.githubusercontent.com/mintfary-oss/Anyrest/main/install.sh | bash

# Вариант 4 — git clone (самый надёжный):
git clone --depth 1 https://github.com/mintfary-oss/Anyrest.git /opt/anyrest
cd /opt/anyrest && bash install.sh
```

### Удаление и переустановка
```bash
cd /opt/anyrest && docker compose down --volumes --remove-orphans 2>/dev/null || true
docker rmi anyrest-signal:latest anyrest-relay:latest anyrest-web:latest 2>/dev/null || true
docker builder prune -af && rm -rf /opt/anyrest
curl -fsSL https://raw.githubusercontent.com/mintfary-oss/Anyrest/main/install.sh | bash
```

### Агент на управляемом ПК
```bash
curl -fsSL https://raw.githubusercontent.com/mintfary-oss/Anyrest/main/install.sh | bash -s -- --agent --ip SERVER_IP
```

### Обновление без переустановки
```bash
cd /opt/anyrest
git fetch origin main && git reset --hard origin/main
docker compose down && docker compose up -d --build
```

### Пересборка web-интерфейса (после изменения исходников)
```bash
# На локальной машине с Node.js:
cd web && npm install && npm run build
git add dist/ && git commit -m "build: update web dist"
git push
# На сервере — просто обновить репозиторий:
cd /opt/anyrest && git pull && docker compose up -d --build
```

### Пересборка Go-бинарников (после изменения Go-кода)
```bash
# Сервер (amd64 + arm64):
cd server
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o ../bin/linux-amd64/anyrest-signal ./cmd/signal/
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o ../bin/linux-amd64/anyrest-relay  ./cmd/relay/
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o ../bin/linux-arm64/anyrest-signal ./cmd/signal/
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o ../bin/linux-arm64/anyrest-relay  ./cmd/relay/
# Агент:
cd ../agent
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o ../bin/linux-amd64/anyrest-agent ./cmd/
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o ../bin/linux-arm64/anyrest-agent ./cmd/
git add ../bin/ && git commit -m "build: update Go binaries" && git push
```

---

## Структура файлов

```
anyrest/
├── server/                         # Go: серверные компоненты
│   ├── cmd/signal/main.go
│   ├── cmd/relay/main.go
│   └── internal/
│       ├── protocol/messages.go
│       ├── peer/registry.go
│       └── relay/relay.go
├── agent/                          # Go: десктопный агент
│   ├── cmd/main.go
│   └── internal/
│       ├── agent/agent.go
│       ├── capture/capture.go
│       └── input/
│           ├── input.go
│           ├── input_linux.go
│           ├── input_stub.go
│           ├── factory_linux.go
│           └── factory_other.go
├── web/                            # React + TypeScript
│   ├── src/
│   │   ├── lib/{protocol,signaling,webrtc}.ts
│   │   └── components/{ConnectForm,RemoteScreen,StatusBar,HelpPage}.tsx
│   └── dist/                       # ← pre-built, committed to repo
│       ├── index.html
│       └── assets/{*.js,*.css}
├── certs/gen-certs.sh
├── nginx/nginx.conf
├── bin/                            # ← Pre-built Go binaries (committed to repo)
│   ├── linux-amd64/anyrest-signal  # 6.5 MB — x86_64
│   ├── linux-amd64/anyrest-relay   # 2.6 MB — x86_64
│   ├── linux-amd64/anyrest-agent   # 11 MB  — x86_64
│   ├── linux-arm64/anyrest-signal  # 6.0 MB — ARM64
│   ├── linux-arm64/anyrest-relay   # 2.4 MB — ARM64
│   └── linux-arm64/anyrest-agent   # 10 MB  — ARM64
├── Dockerfile.server               # COPY-only → Alpine (no Go compiler!)
├── Dockerfile.web                  # NGINX-only (no npm!)
├── Dockerfile.agent                # COPY-only → Alpine + xdotool (no Go compiler!)
├── docker-compose.yml
├── docker-compose.agent.yml
├── agent-entrypoint.sh
├── install.sh                      # Авто-установщик с mirror + retry
└── docs/
    ├── PLAN.md
    ├── CONVERSATION.md
    ├── DONE.md
    └── FIXES.md
```
