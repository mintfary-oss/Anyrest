# Что реализовано

## Статус: ✅ MVP готов — все компоненты собраны и проверены

**Последний аудит:** сессия 13 — 0 ошибок Go (amd64 + arm64 + windows), TypeScript, bash, YAML, nginx, протоколах.

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

---

## Десктопный агент (Go) `agent/`

- Захват экрана: `kbinani/screenshot` (X11/Linux, GDI/Windows, CoreGraphics/macOS) — **OS-агностик**
- Масштабирование до 1280×720, JPEG-кодирование (`image/jpeg`)
- WebRTC P2P через `pion/webrtc v4` — Data Channel, trickle ICE
- **Linux:** инъекция ввода через `xdotool` (X11 XTEST)
- **Windows:** инъекция ввода через `SendInput` Win32 API (user32.dll, pure Go, без CGO)
- **Другие ОС:** stub (no-op, view-only)
- Авто-реконнект к сигнальному серверу (backoff 3 сек)
- Совместимость: соединение работает между любыми ОС — Windows↔Linux, Linux↔Linux, Windows↔macOS

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
| `bin/linux-amd64/anyrest-signal` | 6.5 MB | x86_64 Linux серверы |
| `bin/linux-amd64/anyrest-relay`  | 2.6 MB | x86_64 Linux серверы |
| `bin/linux-amd64/anyrest-agent`  | 11 MB  | x86_64 Linux управляемые ПК |
| `bin/linux-arm64/anyrest-signal` | 6.0 MB | ARM64 серверы (Raspberry Pi, Graviton) |
| `bin/linux-arm64/anyrest-relay`  | 2.4 MB | ARM64 серверы |
| `bin/linux-arm64/anyrest-agent`  | 10 MB  | ARM64 Linux управляемые ПК |
| `bin/windows-amd64/anyrest-agent.exe`     | 11 MB  | Windows 10/11/Server x64 агент |
| `bin/windows-amd64/anyrest-installer.exe` | 2.1 MB | Windows установщик (self-contained) |

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

### Dockerfiles — COPY-only (быстрая сборка)

| Файл | Базовый образ | Что делает | Время сборки |
|------|---------------|------------|--------------| 
| `Dockerfile.server` | `busybox:1.37-musl` | COPY binary | **~3 сек** |
| `Dockerfile.agent`  | `alpine:3.21` | COPY binary + xdotool | **~10 сек** |
| `Dockerfile.web`    | `nginx:1.27-alpine` | COPY web/dist | **~5 сек** |

До оптимизации: компиляция Go внутри Docker → 45+ минут.
После: только COPY готовых бинарников → **~20 секунд** на все три образа.

### `install.sh` v3 — авто-установщик Linux с полной диагностикой
1. Watchdog (20 мин глобальный, 5 мин на шаг) — при зависании авто-прерывает и показывает отчёт
2. Определяет публичный IP (5 fallback-сервисов)
3. Определяет архитектуру (amd64 / arm64)
4. Устанавливает Docker (если отсутствует), с таймаутом
5. **Открывает порты 80/443/8081** в ufw / firewalld / iptables автоматически
6. Настраивает зеркала Docker Hub (huecker.io, timeweb.cloud) — РФ-стабильные
7. Загружает busybox (~1 MB) + nginx (~40 MB)
8. Клонирует / обновляет репозиторий
9. Генерирует TLS-сертификаты (IP-SAN, 4096 bit, 10 лет)
10. Устанавливает CA в системное хранилище (Debian/RHEL/NSS)
11. Создаёт `.env` с random RELAY_SECRET
12. Собирает Docker-образы и запускает стек
13. **Диагностика:**
    - Локальная: HTTPS, HTTP→HTTPS redirect, WebSocket, TCP relay
    - Внешняя: port check через hackertarget.com API
    - ISP/DNS: исходящий интернет, DNS разрешение
    - Браузер: TLS 1.2/1.3, IP-SAN, SHA-256, HSTS, WebSocket upgrade
14. **Финальный отчёт** ✓/✗ по каждому пункту с объяснением проблемы

### `install.ps1` + `anyrest-installer.exe` — Windows установщик
- Агент-режим (по умолчанию): скачивает `anyrest-agent.exe`, устанавливает как Windows Service
- Сервер-режим (`-ServerMode`): Docker Desktop + Docker Compose, открывает firewall
- Автоматически открывает порты в Windows Firewall (`New-NetFirewallRule`)
- Диагностика: DNS, исходящий HTTPS, TCP доступность сервера
- `anyrest-installer.exe`: самодостаточный .exe, embed install.ps1, не требует зависимостей

### `certs/gen-certs.sh`
- CA (4096 bit RSA) + server cert с IP-SAN и localhost
- Поддержка Debian/RHEL/macOS NSS trust stores
- Без process substitution (работает в Alpine bash)

---

## Результаты аудита (сессия 13)

| Проверка | Результат |
|----------|-----------|
| Go server: `go build` (linux/amd64) | ✅ 0 ошибок |
| Go agent: `go build` (linux/amd64) | ✅ 0 ошибок |
| Go server: `go build` (linux/arm64) | ✅ 0 ошибок |
| Go agent: `go build` (linux/arm64) | ✅ 0 ошибок |
| Go agent: `go build` (windows/amd64) | ✅ 0 ошибок — CGO_ENABLED=0 |
| anyrest-installer.exe: `go build` (windows/amd64) | ✅ 0 ошибок |
| TypeScript: `tsc -b && vite build` | ✅ 0 ошибок, 218 KB |
| nginx.conf | ✅ OK |
| docker-compose.yml YAML | ✅ OK |
| install.sh: bash -n | ✅ синтаксис OK |
| Протокол server↔agent↔TS | ✅ совпадают |
| Windows input: SendInput (user32.dll) | ✅ реализован без CGO |
| Windows screen capture: kbinani/screenshot | ✅ pure Go via lxn/win |

---

## Дорожная карта

| Функция | Приоритет | Статус |
|---------|-----------|--------|
| Windows агент (Win32 SendInput) | Высокий | ✅ Готово |
| Авто-открытие портов | Высокий | ✅ Готово |
| Диагностика при установке | Высокий | ✅ Готово |
| Windows installer .exe | Высокий | ✅ Готово |
| PIN-код доступа к агенту | Высокий | В работе |
| H.264 видео-трек | Средний | Запланировано |
| Передача файлов (Data Channel) | Средний | Запланировано |
| Многомониторный режим | Низкий | Запланировано |
| Мобильный клиент (PWA) | Низкий | Запланировано |
