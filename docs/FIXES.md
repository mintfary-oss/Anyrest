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

## #17 — CGO_ENABLED в agent — кросс-компиляция

**Проблема:** `kbinani/screenshot` импортирует `gen2brain/shm` с CGO.
Кросс-компиляция с CGO требует целевой C-тулчейн.

**Решение:** `CGO_ENABLED=0 GOOS=linux GOARCH=amd64` — Go использует чистый X11 backend
(jezek/xgb), gen2brain/shm имеет pure-Go fallback. Бинарник статически слинкован,
не зависит от libc, запускается в `FROM scratch` или alpine без доп. библиотек.
