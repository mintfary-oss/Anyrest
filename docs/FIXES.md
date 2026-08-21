# Ошибки и исправления

---

## #1 — `input.NewStubInjector` не определён на Linux

**Ошибка:** `cmd/main.go:80:16: undefined: input.NewStubInjector`  
**Причина:** build tag `!linux` — файл не компилируется на Linux.  
**Исправление:** Созданы `factory_linux.go` / `factory_other.go` с `NewDefaultInjector()`.

---

## #2 — PR не создан (пустой репозиторий)

**Ошибка:** `GraphQL: Head sha can't be blank, No commits between main and neo/...`  
**Причина:** Репозиторий был пустым — нет ветки `main`.  
**Исправление:** Прямой push на `main` как initial commit.

---

## #3 — Аутентификация git push

**Ошибка:** `remote: Invalid username or token`  
**Исправление:** `git remote set-url origin "https://TOKEN@github.com/..."`

---

## #4 — Стрим видео: VideoTrack → JPEG Data Channel

**Проблема:** H.264/VP8 требует CGO (libx264, libvpx) — сложная Docker-сборка.  
**Решение:** JPEG-фреймы через Data Channel. 12-байт header + JPEG payload. Без CGO.

---

## #5 — `<video>` вместо `<canvas>` в RemoteScreen

**Причина:** `<video srcObject>` работает только с MediaStream, не с Data Channel.  
**Исправление:** `<canvas>` + `Image + drawImage` + `URL.revokeObjectURL`.

---

## #6 — `vite.config.ts` — `https: true` без сертификатов

**Исправление:** IIFE, проверяющий наличие файлов, возвращает `{ cert, key }` или `undefined`.

---

## #7 — `Dockerfile.server` — `FROM scratch` без shell

**Ошибка:** healthcheck `CMD-SHELL` не работает в `scratch`.  
**Исправление:** `FROM alpine:3.21` + `apk add wget`.

---

## #8 — `nginx.conf` — ssl_ciphers на двух строках

**Ошибка:** `nginx: [emerg] invalid parameter`  
**Исправление:** Весь список шифров в одну строку.

---

## #9 — `gen-certs.sh` — process substitution `< <(...)`

**Ошибка:** `bash: /dev/fd/63: No such file or directory` (Alpine без `/dev/fd`).  
**Исправление:** `mktemp` вместо process substitution.

---

## #10 — `npm ci` — "Exit handler never called!"

**Ошибка:** `[web web-builder 4/6] RUN npm ci: 105.3s — Exit handler never called!`  
**Причина:** `node:22-alpine` → npm 10, lockfile создан npm 11 (lockfileVersion 3).  
**Исправление:** `node:22-alpine` → `node:24-alpine` (npm 11).

---

## #11 — TypeScript TS1294: `erasableSyntaxOnly` + parameter properties

**Ошибка:** `error TS1294: This syntax is not allowed when 'erasableSyntaxOnly' is enabled`  
**Причина:** `constructor(private readonly x: T)` запрещён при `erasableSyntaxOnly: true`.  
**Исправление:** Удалён флаг из `tsconfig.app.json` (Vite/esbuild сам транспилирует).

---

## #12 — npm install зависает на шаге 4/6 (~118 сек)

**Ошибка:** Docker скачивал 27 npm-пакетов при каждой чистой установке.  
**Исправление:**
- `web/dist/` добавлен в репозиторий (pre-built)
- `Dockerfile.web` = NGINX-only, без Node.js и npm
- Сборка web-контейнера: 2–3 мин → ~5 сек

---

## #13 — Docker Hub 429 Too Many Requests (alpine:3.21)

**Ошибка:**
```
alpine:3.21: unexpected status from HEAD request to
https://registry-1.docker.io/v2/library/alpine/manifests/3.21: 429 Too Many Requests
```
**Причина:** IP сервера превысил лимит анонимных pull-запросов к Docker Hub (100/6h).  
**Исправление в `install.sh`:**
1. `configure_mirror()` — `/etc/docker/daemon.json` с зеркалами
2. `pull_base_images()` — предварительный pull с 5 попытками и нарастающим backoff

---

## #14 — `--pull=never` не поддерживается старым Docker Compose

**Ошибка:** `invalid argument "never" for "--pull" flag: strconv.ParseBool: parsing "never": invalid syntax`  
**Причина:** В старых версиях Docker Compose `--pull` принимает только `true`/`false`, не строку `never`.  
**Исправление:** Убран флаг полностью — `docker compose build` без параметров использует кэш автоматически.

---

## #15 — `mirror.gcr.io` нестабилен в России

**Причина:** Google (GCR) блокируется или нестабилен в РФ.  
**Исправление:** Зеркала в `/etc/docker/daemon.json` заменены на РФ-доступные:
- `https://huecker.io` — публичное зеркало, работает в России
- `https://dockerhub.timeweb.cloud` — зеркало Timeweb (российский хостер)

---

## #16 — Go компиляция в Docker: 45+ минут

**Ошибка:** `docker compose build` зависал на 45+ минут — Go компилятор скачивал и
собирал pion/webrtc (~25 пакетов, >300 MB зависимостей) внутри Docker на каждом чистом деплое.

**Причина:** Докерфайлы использовали `FROM golang:1.26-alpine AS builder` и компилировали
Go-код прямо в контейнере. Образ golang весит ~300 MB. При ограниченном интернете и
медленном CPU сборка занимала 45+ минут.

**Исправление (радикальное):**

1. **Pre-built бинарники в репозитории** — добавлена папка `bin/`:
   - `bin/linux-amd64/anyrest-signal` (6.5 MB)
   - `bin/linux-amd64/anyrest-relay` (2.6 MB)
   - `bin/linux-amd64/anyrest-agent` (11 MB)
   - `bin/linux-arm64/anyrest-signal` (6.0 MB)
   - `bin/linux-arm64/anyrest-relay` (2.4 MB)
   - `bin/linux-arm64/anyrest-agent` (10 MB)

2. **Dockerfile.server переписан** — `FROM alpine:3.21` + `COPY bin/linux-${TARGETARCH}/anyrest-${CMD}`:
   - Нет стадии сборки, нет golang-образа, нет интернет-запросов
   - Время сборки: 45+ мин → **~5 секунд**

3. **Dockerfile.agent переписан** — аналогично, только `COPY + xdotool`

4. **install.sh обновлён:**
   - `detect_arch()` — автоматически определяет amd64 / arm64
   - `pull_base_images()` — только `alpine:3.21` (~8 MB) + `nginx:1.27-alpine` (~40 MB)
   - `golang:1.26-alpine` (~300 MB) больше не скачивается
   - `TARGETARCH=$ARCH docker compose build` — передаётся архитектура

5. **docker-compose.yml обновлён** — `TARGETARCH: "${TARGETARCH:-amd64}"` в `args`

**Итог:** Общее время установки: 45+ мин → **~2–3 минуты** на любом VPS.

---

## #18 — `apk add` зависает на 30+ минут (Alpine CDN заблокирован в России)

**Ошибка:** Docker сборка зависает на шаге `2/4` сервиса `signal`, 1800+ секунд — без прогресса.

**Причина:** `Dockerfile.server` использовал `FROM alpine:3.21` + `RUN apk add --no-cache ca-certificates wget`.
`apk add` подключается к `dl-cdn.alpinelinux.org` — этот CDN недоступен или заблокирован на многих серверах в России.
Соединение висит без ответа, timeout не срабатывает (Docker не ограничивает время `RUN`).

**Исправление:**

1. **`Dockerfile.server`** — заменён базовый образ с `alpine:3.21` на `busybox:1.37-musl`:
   - `busybox:1.37-musl` уже включает `wget` и `nc` как встроенные аплеты BusyBox
   - `apk add` полностью убран — **никаких сетевых запросов при сборке**
   - `ca-certificates` не нужен: signal/relay — серверы, не делают исходящих TLS соединений
   - Бинарник `CGO_ENABLED=0` — полностью статический, работает без libc
   - Время сборки: 30+ минут → **~3 секунды**

2. **`Dockerfile.agent`** — добавлено зеркало Яндекса для Alpine:
   ```dockerfile
   RUN echo "https://mirror.yandex.ru/mirrors/alpine/v3.21/main" > /etc/apk/repositories && \
       echo "https://mirror.yandex.ru/mirrors/alpine/v3.21/community" >> /etc/apk/repositories && \
       apk add --no-cache xdotool ca-certificates
   ```
   Яндекс — российское зеркало Alpine, работает без блокировок.

3. **`install.sh`** — обновлён `pull_base_images()`: `alpine:3.21` → `busybox:1.37-musl`

**Итог:**
| | До | После |
|--|----|----|
| Dockerfile.server base | alpine:3.21 + apk add | busybox:1.37-musl (нет apk) |
| Сборка signal/relay | 30+ минут (зависание) | ~3 секунды |
| Зависимость от Alpine CDN | ДА (блокируется в РФ) | НЕТ |

**Проблема:** `kbinani/screenshot` импортирует `gen2brain/shm` с CGO.
Кросс-компиляция с CGO требует целевой C-тулчейн.

**Решение:** `CGO_ENABLED=0 GOOS=linux GOARCH=amd64` — Go использует чистый X11 backend
(jezek/xgb), gen2brain/shm имеет pure-Go fallback. Бинарник статически слинкован,
не зависит от libc, запускается в `FROM scratch` или alpine без доп. библиотек.

---

## #19 — Установка зависала на apk/npm — watchdog не было

**Ошибка:** При медленном интернете или заблокированных CDN установка висла 45+ минут без вывода ошибки.
Пользователь не знал что делать — убивать ли процесс или ждать.

**Исправление в `install.sh` v3:**
- Глобальный watchdog-процесс: `(sleep 1200; kill -TERM $PPID) &` — автоматически прерывает через 20 мин
- Каждый шаг обёрнут в `run_step <таймаут_сек>` через команду `timeout`
- При срабатывании watchdog выводится имя зависшего шага и команда для проверки логов
- Ловушка `trap on_error ERR` — любая ошибка вызывает финальный отчёт перед выходом

---

## #20 — Порты не открывались автоматически

**Проблема:** После успешной установки браузер не мог открыть `https://IP` — порты 80/443 были закрыты
системным firewall (ufw/firewalld/iptables). Пользователь не знал что нужно открывать порты вручную.

**Исправление:** Добавлена функция `open_ports()` в `install.sh`, вызываемая до запуска Docker:
- `ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 8081/tcp` (если ufw активен)
- `firewall-cmd --permanent --add-port=...` + `reload` (если firewalld активен)
- `iptables -I INPUT -p tcp --dport ... -j ACCEPT` (fallback, все дистрибутивы)
- Сохранение правил через `netfilter-persistent` / `iptables-save`

---

## #21 — Нет диагностики после установки

**Проблема:** Установка завершалась просто с сообщением "открыть https://IP".
Если что-то не работало — пользователь не знал причину (провайдер? firewall? сертификат?).

**Исправление:** Добавлена полная диагностика после запуска стека:

1. **`check_local()`** — локальная проверка:
   - `curl -fsSk https://$IP/health` — HTTPS endpoint
   - HTTP redirect code — редирект 80→443
   - WebSocket handshake — `Sec-WebSocket-Key` через curl
   - TCP relay — `nc -z $IP 8081`

2. **`check_external()`** — внешняя видимость:
   - `api.hackertarget.com/nmap/?q=$IP&port=$PORT` — сканирует порты снаружи
   - `portchecker.online/api/v1/query` — резервный API
   - Раздельно: 443 (критично), 8081 (relay), 80 (не критично)

3. **`check_isp_browser()`** — блокировки и совместимость браузеров:
   - Исходящий HTTPS: `curl https://dns.google`
   - DNS разрешение: `getent hosts github.com`
   - Сертификат: IP-SAN проверка, алгоритм подписи (SHA-256 vs SHA-1)
   - TLS 1.2/1.3: `openssl s_client -tls1_2 / -tls1_3`
   - HSTS и X-Content-Type-Options заголовки
   - WebSocket Upgrade: HTTP 101 ответ

4. **`print_report()`** — финальный отчёт ✓/✗ по каждому пункту с объяснением.

---

## #22 — Агент не поддерживал Windows (StubInjector)

**Проблема:** На Windows агент запускался, захватывал экран, но ввод (мышь/клавиатура)
не инжектировался — `StubInjector` возвращал `errUnsupported` на всё.
Соединение между Windows и Linux ломалось на уровне управления (AnyDesk-подобная проблема).

**Исправление:**
1. Создан `agent/internal/input/input_windows.go` — реализация через Win32 `SendInput` (user32.dll):
   - Без CGO: `syscall.NewLazyDLL("user32.dll")` + pure Go struct packing
   - `MouseMove` — абсолютные координаты (нормализация в 0–65535)
   - `MouseDown/Up` — left/middle/right через MOUSEEVENTF_*DOWN/UP
   - `Scroll` — `MOUSEEVENTF_WHEEL` и `MOUSEEVENTF_HWHEEL`
   - `KeyDown/KeyUp` — таблица JavaScript key → Win32 VK code, Unicode fallback
   - `screenSize()` через `GetSystemMetrics(SM_CXSCREEN/SM_CYSCREEN)`

2. Создан `agent/internal/input/factory_windows.go` — `NewDefaultInjector()` → `WindowsInjector`

3. Обновлены build tags:
   - `factory_other.go`: `!linux` → `!linux && !windows`
   - `input_stub.go`: `!linux` → `!linux && !windows`

4. Кросс-компиляция успешна:
   ```
   CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build → anyrest-agent.exe (11 MB)
   ```

5. Скриншот: `kbinani/screenshot` уже поддерживал Windows через `lxn/win` (pure Go Win32 GDI).

---

## #23 — Нет Windows-установщика

**Проблема:** Пользователи Windows не могли автоматически установить агент.

**Исправление:**
1. `install.ps1` — PowerShell установщик:
   - `-AgentOnly` (по умолчанию): скачивает `anyrest-agent.exe`, устанавливает как Windows Service
   - `-ServerMode`: Docker Desktop + Docker Compose + firewall + certs
   - Автоматически открывает порты через `New-NetFirewallRule`
   - Диагностика: DNS, HTTPS, TCP проверки

2. `cmd/installer/main.go` — Go-программа с `//go:embed install.ps1`:
   - Пишет PS1 во временный файл, запускает через `powershell.exe -ExecutionPolicy Bypass`
   - Кросс-компиляция: `CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build` → `anyrest-installer.exe` (2.1 MB)
   - Пользователь двойным кликом запускает .exe — больше ничего не нужно
