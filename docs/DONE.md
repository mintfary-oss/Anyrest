# Что реализовано

## Статус: ✅ MVP готов к деплою

---

## 1. Сервер сигнализации (`server/cmd/signal/`)

**Файл:** `server/cmd/signal/main.go`

- WebSocket-сервер на Go с поддержкой TLS
- Регистрация пиров с уникальным 9-значным ID (аналог AnyDesk)
- Брокеринг WebRTC offer/answer/ICE между агентом и вьювером
- Heartbeat (ping/pong) для поддержания соединений
- Автоматический fallback на relay-сервер при недоступности P2P
- Endpoint `/health` для мониторинга
- Конфигурация через флаги командной строки

---

## 2. Сервер ретрансляции (`server/cmd/relay/`)

**Файл:** `server/internal/relay/relay.go`

- TCP relay для случаев, когда P2P hole-punching не работает
- HMAC-SHA256 аутентификация с временны́м окном (30 сек)
- Сопряжение двух TCP-соединений по session_id + token
- Прозрачное байтовое копирование (`io.CopyBuffer`)
- Защита от replay-атак через временны́е корзины

---

## 3. Реестр пиров (`server/internal/peer/`)

- Потокобезопасный in-memory реестр всех активных соединений
- Генерация уникальных 9-значных IDs без коллизий
- SafeWrite — запись в WebSocket без гонок

---

## 4. Генератор сертификатов (`certs/gen-certs.sh`)

- Автоматическое создание корневого CA (4096 bit RSA, SHA-256)
- Серверный сертификат с IP-SAN для всех сетевых интерфейсов
- Поддержка IPv4 и IPv6 адресов
- Установка CA в системные хранилища:
  - Ubuntu/Debian: `update-ca-certificates`
  - RHEL/CentOS: `update-ca-trust`
  - macOS: `security add-trusted-cert`
  - NSS-базы Chrome и Firefox (`certutil`)
- Вывод fingerprint и SANs по завершению

---

## 5. Веб-клиент (`web/src/`)

### `lib/protocol.ts`
- TypeScript-типы для всего протокола сигнализации
- Типы входных событий (мышь, клавиатура, скролл)

### `lib/signaling.ts` — `SignalingClient`
- WebSocket-клиент с типизированными подписками на события
- Авто-реконнект с экспоненциальной задержкой (до 30 сек)
- Регистрация пира и хранение peer_id
- Pong-ответы на heartbeat

### `lib/webrtc.ts` — `WebRTCViewer`
- Управление жизненным циклом `RTCPeerConnection`
- Получение offer от агента → создание answer
- Trickle ICE кандидаты через сигнальный канал
- Декодирование JPEG-фреймов из бинарных data channel сообщений
- Разбор 12-байтного заголовка (magic + width + height + seq)
- Delivery через Blob URL (с автоматическим revoke)
- Data channel `input` для отправки событий ввода

### `components/ConnectForm.tsx`
- Форма ввода 9-значного ID с форматированием XXX XXX XXX
- Отображение собственного ID с кнопкой копирования
- Блокировка при отсутствии соединения с сервером

### `components/RemoteScreen.tsx`
- Canvas-рендеринг JPEG-фреймов (через `Image` + `drawImage`)
- Нормализация координат мыши (0–1) для масштабирования
- Обработка: mousemove, mousedown, mouseup, wheel, keydown, keyup
- Блокировка кнопки `Ctrl+R/L/W/T` для навигации браузера
- `tabIndex=0` для захвата фокуса клавиатуры

### `components/StatusBar.tsx`
- Индикатор состояния сигнального сервера (зелёный/красный dot)
- Бейдж состояния подключения: idle/connecting/connected/failed
- Кнопка Disconnect в режиме активной сессии

### `components/HelpOverlay.tsx`
- Кнопка `?` в правом верхнем углу шапки
- Overlay с полным руководством пользователя (7 разделов):
  - Быстрый старт
  - Установка агента (Docker, скрипт, флаги CLI)
  - Подключение (пошаговая инструкция)
  - Управление (горячие клавиши и мышь)
  - Сертификаты (Chrome, Firefox, Linux, Windows, macOS)
  - Безопасность (таблица слоёв шифрования)
  - Устранение проблем (6 частых проблем)
- Все адреса/команды подставляются из `window.location` автоматически

### Стили (`index.css`)
- Тёмная тема (цвета vars), отзывчивый layout
- Sidebar (280px) + fullscreen canvas
- Google Fonts Inter

---

## 6. Десктопный агент (`agent/`)

### `internal/capture/capture.go`
- Захват экрана через `kbinani/screenshot` (X11, DXGI, CoreGraphics)
- Автоматическое масштабирование до 1280×720 (бинарный scaler)
- JPEG-кодирование (`image/jpeg`) с настраиваемым quality
- Поддержка нескольких дисплеев

### `internal/input/`
- Интерфейс `Injector` (MouseMove, MouseDown, MouseUp, Scroll, KeyDown, KeyUp)
- `LinuxInjector` — инъекция через `xdotool` (X11 XTEST extension)
- Маппинг JS key names → xdotool key names
- `StubInjector` — заглушка для других платформ
- Фабричные функции с build tags (`factory_linux.go`, `factory_other.go`)

### `internal/agent/agent.go`
- Авто-реконнект к сигнальному серверу (каждые 3 сек)
- Создание WebRTC PeerConnection при запросе от вьювера
- Отправка offer → ожидание answer → применение ICE
- Data channel `frames` (ordered, binary) — поток JPEG-фреймов
- 12-байтный заголовок: magic(4) + width(2) + height(2) + seq(4)
- Frame loop на тиккере по целевому FPS
- Data channel `input` — приём событий ввода от вьювера
- Преобразование нормализованных координат (0–1) в пиксели

---

## 7. Docker Compose + NGINX

### `nginx/nginx.conf`
- HTTP → HTTPS редирект
- TLS 1.2/1.3 с современными шифрами (одна строка — проверено)
- HSTS, X-Content-Type-Options, X-Frame-Options
- WebSocket proxy `/ws` → signaling server с таймаутами 3600s
- Раздача `ca.crt` по `/certs/ca.crt` для установки в браузер
- Статические файлы с агрессивным кэшированием (1 год для fingerprinted assets)

### `docker-compose.yml`
- Сервис `signal` — сервер сигнализации (internal), healthcheck через wget
- Сервис `relay` — сервер ретрансляции (порт 8081), healthcheck через nc
- Сервис `web` — NGINX + React (порты 80, 443)
- Внутренняя сеть `anyrest-internal`
- `restart: unless-stopped`

### `docker-compose.agent.yml`
- `network_mode: host` для WebRTC ICE кандидатов
- Монтирование X11 сокета `/tmp/.X11-unix`
- Переменная `DISPLAY` для захвата экрана

### Dockerfiles
- `Dockerfile.server` — multi-stage: Go builder → Alpine (wget для healthcheck)
- `Dockerfile.web` — multi-stage: **Node 24** builder → NGINX alpine
- `Dockerfile.agent` — Alpine с xdotool

---

## 8. Авто-установщик (`install.sh`)

- Определение публичного IP (4 fallback-сервиса + ip addr)
- Автоматическая установка Docker (через get.docker.com)
- Клонирование / обновление репозитория
- Генерация сертификатов и установка CA в системное хранилище
- Запись `.env` с автогенерированным RELAY_SECRET
- Сборка и запуск Docker Compose
- Ожидание готовности (health-poll до 60 сек)
- Установка systemd-сервиса для агента (Linux)
- Режимы: сервер (по умолчанию), `--agent` для управляемого ПК
- Цветной вывод, информативные сообщения

---

## Итог

| Требование | Статус |
|---|---|
| Без облачных ресурсов | ✅ Всё self-hosted |
| Docker авто-установка | ✅ `install.sh` + `docker-compose.yml` |
| HTTPS без домена | ✅ IP-SAN сертификат |
| Браузеры не блокируют | ✅ CA устанавливается в систему |
| E2E шифрование | ✅ DTLS 1.3 + AES-256-GCM |
| Все браузеры | ✅ WebRTC поддерживается везде |
| Linux агент | ✅ X11 + xdotool |
| WebRTC P2P | ✅ pion/webrtc v4 |
| Relay fallback | ✅ TCP + HMAC |
| Руководство в веб-интерфейсе | ✅ HelpOverlay (кнопка ?) |
| Docker сборка без ошибок | ✅ исправлено (node:24, no erasableSyntaxOnly) |
