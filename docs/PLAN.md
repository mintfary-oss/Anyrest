# План создания Anyrest

## Концепция

Anyrest — самостоятельно размещаемый аналог AnyDesk/TeamViewer. Работает **без облачных сервисов**, разворачивается одной командой через Docker.

---

## Архитектура системы

```
                     ┌─────────────────────────────────────────────┐
                     │              ANYREST STACK                   │
                     │                                              │
Browser ──HTTPS──►   │  NGINX (:443) ──► React Web Client           │
Browser ──WSS────►   │  NGINX (:443) ──► Signaling Server           │
                     │                                              │
Agent ──WebSocket──► │  Signaling Server (:8080, internal)          │
                     │                                              │
Agent ──TCP──────►   │  Relay Server (:8081)                        │
                     │                                              │
                     └─────────────────────────────────────────────┘

Потоки данных:
  WebRTC P2P: Agent ◄──DTLS/SRTP──► Browser (прямое соединение)
  Relay fall: Agent ──TCP──► Relay ──TCP──► Browser (если P2P недоступен)
```

---

## Стек технологий

| Компонент | Технология | Обоснование |
|---|---|---|
| Сервер сигнализации | **Go 1.26** + gorilla/websocket | Лёгкий, быстрый, компилируется в статический бинарник |
| Сервер ретрансляции | **Go 1.26** + net/tcp | Минимальные зависимости |
| WebRTC (сервер) | **pion/webrtc v4** | Нативный Go, без CGO |
| Веб-клиент | **React 18 + TypeScript 5 + Vite** | Современный стек, быстрая сборка |
| WebRTC (браузер) | **Web API RTCPeerConnection** | Нативная поддержка всех браузеров |
| Захват экрана | **kbinani/screenshot** | Поддержка X11, Wayland, DXGI, CoreGraphics |
| Ввод (Linux) | **xdotool** | Надёжная инъекция ввода через X11 XTEST |
| Сертификаты | **OpenSSL** + bash-скрипт | IP-SAN без доменного имени |
| Контейнеры | **Docker Compose** | Авто-запуск, изоляция, портируемость |
| Реверс-прокси | **NGINX 1.27** | TLS-терминация, проксирование WebSocket |

---

## Протокол соединения

### Этапы установки сессии

```
Viewer (Browser)          Signaling Server          Agent (Host)
      │                         │                        │
      │── register ────────────►│                        │
      │◄─ register_ack (ID) ────│                        │
      │                         │◄──── register ─────────│
      │                         │───── register_ack ────►│
      │                         │                        │
      │── connect(target_id) ──►│                        │
      │                         │──── connect_ack ──────►│
      │                         │◄─── offer (SDP) ───────│
      │◄─ offer (SDP) ──────────│                        │
      │── answer (SDP) ─────────►│                       │
      │                         │──── answer (SDP) ─────►│
      │◄══ ICE candidates ═════►│◄══ ICE candidates ═════│
      │                                                   │
      │◄══════════════ WebRTC P2P (DTLS+SRTP) ═══════════►│
      │                  (JPEG frames + input)             │
```

### Формат JPEG-фрейма (Data Channel)

```
Offset  Size   Field
0       4      Magic: 0xA2E501F2 (little-endian)
4       2      Frame width (pixels)
6       2      Frame height (pixels)
8       4      Sequence number
12      N      JPEG payload
```

---

## Безопасность

| Слой | Механизм |
|---|---|
| Транспорт | TLS 1.3 (HTTPS/WSS) |
| WebRTC медиа | DTLS 1.3 + AES-256-GCM (обязательно для всех браузеров) |
| Relay аутентификация | HMAC-SHA256 с временны́м окном 30 сек |
| Сертификат | Self-signed CA + IP-SAN (устанавливается в системное хранилище) |
| Идентификаторы | 9-значные случайные числа (аналог AnyDesk) |

---

## Развёртывание

### Сервер (одна команда)
```bash
curl -fsSL https://raw.githubusercontent.com/mintfary-oss/Anyrest/main/install.sh | bash
```

### Агент на управляемом ПК
```bash
./install.sh --agent-only --signal-url wss://SERVER_IP/ws
```

### Ручное развёртывание
```bash
cd certs && ./gen-certs.sh          # Генерация сертификатов
docker compose up -d                # Запуск стека
```

---

## Структура файлов

```
anyrest/
├── server/                          # Go: серверные компоненты
│   ├── cmd/signal/main.go           # Сервер сигнализации
│   ├── cmd/relay/main.go            # Сервер ретрансляции
│   └── internal/
│       ├── protocol/messages.go     # Типы сообщений
│       ├── peer/registry.go         # Реестр подключённых пиров
│       └── relay/relay.go           # TCP relay логика
├── agent/                           # Go: десктопный агент
│   ├── cmd/main.go                  # Точка входа
│   └── internal/
│       ├── agent/agent.go           # WebRTC + сигнализация
│       ├── capture/capture.go       # Захват экрана → JPEG
│       └── input/                   # Инъекция ввода
│           ├── input.go             # Интерфейс
│           ├── input_linux.go       # Linux (xdotool)
│           └── input_stub.go        # Заглушка (другие ОС)
├── web/                             # React + TypeScript
│   └── src/
│       ├── lib/
│       │   ├── protocol.ts          # Типы протокола
│       │   ├── signaling.ts         # WebSocket клиент
│       │   └── webrtc.ts            # WebRTC viewer
│       └── components/
│           ├── ConnectForm.tsx      # Форма подключения
│           ├── RemoteScreen.tsx     # Canvas рендеринг экрана
│           └── StatusBar.tsx        # Статус соединения
├── certs/
│   └── gen-certs.sh                 # Генератор CA + IP-SAN
├── nginx/nginx.conf                 # NGINX конфиг
├── Dockerfile.server                # Сборка signaling/relay
├── Dockerfile.web                   # Сборка React + NGINX
├── Dockerfile.agent                 # Сборка агента
├── docker-compose.yml               # Серверный стек
├── docker-compose.agent.yml         # Агент
└── install.sh                       # Авто-установщик
```
