# Что реализовано

## Статус: ✅ MVP готов — все компоненты собраны и проверены

**Последний аудит:** сессия 9 — 0 ошибок в Go (amd64+arm64), TypeScript, bash, YAML, nginx, протоколах.

---

## Серверная часть (Go)

### Сервер сигнализации `server/cmd/signal/`
- WebSocket-сервер, регистрация пиров с 9-значным ID (аналог AnyDesk)
- Брокеринг WebRTC offer/answer/ICE (trickle ICE)
- Heartbeat ping/pong (30 сек), `/health` JSON endpoint
- Relay fallback через HMAC-токен при недоступности P2P

### Сервер ретрансляции `server/cmd/relay/`
- TCP relay для случаев когда P2P недоступен (NAT/firewall)
- HMAC-SHA256 аутентификация, временны́е токены (30 сек окно)
- Прозрачный `io.CopyBuffer` (32 KB буфер)

### Реестр пиров `server/internal/peer/`
- Потокобезопасный in-memory реестр (`sync.RWMutex`)
- 9-значные уникальные ID без коллизий

---

## Десктопный агент (Go) `agent/`

- Захват экрана: `kbinani/screenshot` (X11 на Linux, DXGI на Windows, CoreGraphics на macOS)
- Масштабирование до 1280×720, JPEG-кодирование (`image/jpeg`)
- WebRTC P2P через `pion/webrtc v4` — Data Channel, trickle ICE
- Инъекция ввода: `xdotool` (X11 XTEST): мышь, клавиатура, скролл
- Авто-реконнект к сигнальному серверу (backoff 3 сек)

---

## Веб-клиент (React + TypeScript) `web/`

### `lib/signaling.ts`
- WebSocket с авто-реконнектом (до 30 сек exponential backoff)
- Типизированные события, внутренний ping/pong

### `lib/webrtc.ts`
- RTCPeerConnection lifecycle (offer → answer → ICE)
- Декодирование JPEG-фреймов из Data Channel
- Бинарный заголовок: magic(4) + width(2) + height(2) + seq(4) = 12 байт

### Компоненты
- `ConnectForm` — ввод 9-значного ID в формате XXX XXX XXX
- `RemoteScreen` — canvas-рендеринг, нормализованные (0–1) координаты мыши
- `StatusBar` — dot-индикатор сервера, бейдж состояния WebRTC
- `HelpPage` — overlay с 7 разделами: старт, агент, подключение, клавиши, сертификаты, безопасность, FAQ

### Собранные файлы `web/dist/` ✅ (в репозитории — npm не нужен на сервере)
```
web/dist/index.html              0.7 KB
web/dist/assets/index-*.css      8.5 KB (gzip: 2.1 KB)
web/dist/assets/index-*.js     218.0 KB (gzip: 67.9 KB)
web/dist/favicon.svg
web/dist/icons.svg
```

---

## Pre-built бинарники `bin/` ✅ (в репозитории — Go не нужен на сервере)

| Файл | Размер | Целевая платформа |
|------|--------|-------------------|
| `bin/linux-amd64/anyrest-signal` | 6.5 MB | x86_64 серверы |
| `bin/linux-amd64/anyrest-relay`  | 2.6 MB | x86_64 серверы |
| `bin/linux-amd64/anyrest-agent`  | 11 MB  | x86_64 управляемые ПК |
| `bin/linux-arm64/anyrest-signal` | 6.0 MB | ARM64 серверы (Raspberry Pi, Graviton) |
| `bin/linux-arm64/anyrest-relay`  | 2.4 MB | ARM64 серверы |
| `bin/linux-arm64/anyrest-agent`  | 10 MB  | ARM64 управляемые ПК |

Все бинарники: `CGO_ENABLED=0`, статически слинкованы, не зависят от glibc.

---

## Инфраструктура

### `nginx/nginx.conf`
- HTTP → HTTPS редирект
- TLS 1.2/1.3, современные шифры (одна строка — bug fix!)
- HSTS, X-Content-Type-Options, X-Frame-Options
- WebSocket proxy `/ws` (timeout 3600s)
- Раздача `/certs/ca.crt` для установки в браузер (content-type: x-x509-ca-cert)
- SPA fallback `try_files $uri /index.html`

### `docker-compose.yml`
- `signal` — WebSocket :8080 (internal), healthcheck wget /health
- `relay` — TCP :8081 (exposed), healthcheck nc -z
- `web` — NGINX :80/:443, volume `./certs`, depends_on signal (healthy)
- Все сервисы: `TARGETARCH: "${TARGETARCH:-amd64}"` для выбора правильного бинарника

### Dockerfiles

| Файл | Базовый образ | Что делает | Время сборки |
|------|---------------|------------|--------------|
| `Dockerfile.server` | `alpine:3.21` | COPY binary + wget | **~5 сек** |
| `Dockerfile.agent`  | `alpine:3.21` | COPY binary + xdotool | **~10 сек** |
| `Dockerfile.web`    | `nginx:1.27-alpine` | COPY web/dist | **~5 сек** |

До оптимизации: Dockerfile.server и Dockerfile.agent компилировали Go внутри Docker → 45+ минут.  
После оптимизации: только COPY готовых бинарников → **~20 секунд** на все три образа.

### `install.sh` v2 — авто-установщик (~2–3 мин)
1. Определяет публичный IP (4 fallback-сервиса)
2. **Определяет архитектуру** (amd64 / arm64) для выбора бинарников
3. Устанавливает Docker (если отсутствует)
4. Настраивает зеркала Docker Hub (huecker.io, timeweb.cloud) — РФ-стабильные
5. Загружает только alpine (~8 MB) + nginx (~40 MB) — **golang больше не нужен**
6. Клонирует / обновляет репозиторий
7. Генерирует TLS-сертификаты (IP-SAN, 4096 bit, 10 лет)
8. Устанавливает CA в системное хранилище (Debian/RHEL/macOS/NSS)
9. Создаёт `.env` с random RELAY_SECRET
10. `TARGETARCH=$ARCH docker compose build` → `up -d`
11. Ожидает readiness (wget health-poll 60 сек)

### `certs/gen-certs.sh`
- CA (4096 bit RSA) + server cert с IP-SAN и localhost
- Поддержка Debian/RHEL/macOS NSS trust stores
- Без process substitution (работает в Alpine bash)

---

## Результаты аудита (сессия 9)

| Проверка | Результат |
|----------|-----------|
| Go server: `go build ./...` (amd64) | ✅ 0 ошибок |
| Go agent: `go build ./...` (amd64) | ✅ 0 ошибок |
| Go server: `go build ./...` (arm64) | ✅ 0 ошибок |
| Go agent: `go build ./...` (arm64) | ✅ 0 ошибок |
| TypeScript: `tsc -b && vite build` | ✅ 0 ошибок, 218 KB |
| nginx.conf | ✅ OK |
| docker-compose.yml / agent.yml YAML | ✅ OK |
| install.sh / gen-certs.sh / entrypoint.sh | ✅ синтаксис OK |
| Протокол server↔agent↔TS (12 типов) | ✅ совпадают |
| Frame magic Go↔TS | ✅ `0xa2e501f2` |
| Input events (6 типов) | ✅ синхронизированы |
| HMAC token format | ✅ идентичен |
| RELAY_SECRET во всех файлах | ✅ согласован |
| bin/ бинарники (amd64 + arm64) | ✅ скомпилированы |

---

## Дорожная карта

| Функция | Приоритет |
|---------|-----------|
| Агент для Windows (Win32 API) | Высокий |
| PIN-код доступа к агенту | Высокий |
| H.264 видео-трек (лучше JPEG) | Средний |
| Передача файлов (Data Channel) | Средний |
| Многомониторный режим | Низкий |
| Мобильный клиент (PWA) | Низкий |
