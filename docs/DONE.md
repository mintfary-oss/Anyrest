# Что реализовано

## Статус: ✅ MVP готов — все компоненты проверены

**Последний аудит:** сессия 8 — 0 ошибок в Go, TypeScript, bash, nginx, протоколах.

---

## Серверная часть (Go)

### Сервер сигнализации `server/cmd/signal/`
- WebSocket-сервер, регистрация пиров с 9-значным ID
- Брокеринг WebRTC offer/answer/ICE
- Heartbeat ping/pong, `/health` endpoint
- Relay fallback через HMAC-токен

### Сервер ретрансляции `server/cmd/relay/`
- TCP relay для случаев когда P2P недоступен
- HMAC-SHA256 аутентификация, временны́е токены (30 сек)
- Прозрачный io.CopyBuffer

### Реестр пиров `server/internal/peer/`
- Потокобезопасный in-memory реестр
- 9-значные уникальные ID без коллизий

---

## Десктопный агент (Go) `agent/`

- Захват экрана: `kbinani/screenshot` (X11 / DXGI / CoreGraphics)
- Масштабирование до 1280×720, JPEG-кодирование
- WebRTC P2P через `pion/webrtc v4`
- Инъекция ввода: `xdotool` (X11 XTEST)
- Авто-реконнект к сигнальному серверу

---

## Веб-клиент (React + TypeScript) `web/`

### `lib/signaling.ts`
- WebSocket с авто-реконнектом (до 30 сек)
- Типизированные события

### `lib/webrtc.ts`
- RTCPeerConnection lifecycle
- Декодирование JPEG-фреймов из Data Channel
- Заголовок: magic(4) + w(2) + h(2) + seq(4) = 12 байт

### Компоненты
- `ConnectForm` — ввод 9-значного ID (XXX XXX XXX)
- `RemoteScreen` — canvas-рендеринг, нормализованные координаты мыши
- `StatusBar` — dot-индикатор сервера, бейдж состояния
- `HelpPage` — overlay с 7 разделами руководства

### Собранные файлы `web/dist/` ✅ (в репозитории)
```
web/dist/index.html              0.7 KB
web/dist/assets/index-*.css      8.3 KB (gzip: 2.1 KB)
web/dist/assets/index-*.js     218.0 KB (gzip: 67.9 KB)
web/dist/favicon.svg             9.3 KB
web/dist/icons.svg               4.9 KB
```

---

## Инфраструктура

### `nginx/nginx.conf`
- HTTP → HTTPS редирект
- TLS 1.2/1.3, современные шифры (одна строка)
- HSTS, X-Content-Type-Options, X-Frame-Options
- WebSocket proxy `/ws` (timeout 3600s)
- Раздача `/certs/ca.crt` для установки в браузер
- SPA fallback `try_files $uri /index.html`

### `docker-compose.yml`
- `signal` — WebSocket, healthcheck wget
- `relay` — TCP :8081, healthcheck nc
- `web` — NGINX :80/:443, volume `./certs`

### Dockerfiles
- `Dockerfile.server` — Go builder → Alpine (wget)
- `Dockerfile.web` — **NGINX-only** (без Node.js/npm, ~5 сек сборки)
- `Dockerfile.agent` — Go builder → Alpine (xdotool)

### `install.sh` — авто-установщик
1. Определяет публичный IP (4 fallback-сервиса)
2. Устанавливает Docker
3. **Настраивает зеркало Docker Hub** (`mirror.gcr.io`) → обход rate limit 429
4. **Предзагружает базовые образы** с 5 попытками и backoff
5. Клонирует / обновляет репозиторий
6. Генерирует TLS-сертификаты (IP-SAN, 4096 bit)
7. Устанавливает CA в системное хранилище
8. Создаёт `.env` с random RELAY_SECRET
9. `docker compose build --pull=never` + `up -d`
10. Ожидает readiness (wget health-poll)

### `certs/gen-certs.sh`
- CA + server cert с IP-SAN
- Поддержка Debian/RHEL/macOS NSS
- Без process substitution (работает в Alpine)

---

## Результаты аудита (сессия 8)

| Проверка | Результат |
|----------|-----------|
| Go server: `go vet + build` | ✅ 0 ошибок |
| Go agent: `go vet + build` | ✅ 0 ошибок |
| TypeScript: `tsc -b + vite build` | ✅ 0 ошибок |
| nginx.conf (10 проверок) | ✅ OK |
| docker-compose.yml YAML | ✅ OK |
| install.sh / gen-certs.sh / entrypoint.sh | ✅ синтаксис OK |
| Протокол server↔agent↔TS (12 типов) | ✅ совпадают |
| Frame magic Go↔TS | ✅ `0xa2e501f2` |
| Input events (6 типов) | ✅ синхронизированы |
| HMAC token format | ✅ идентичен |
| RELAY_SECRET во всех файлах | ✅ согласован |

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
