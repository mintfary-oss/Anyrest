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
- `https://mirror.gcr.io` — оставлено как резервное

Добавлен DNS: `77.88.8.8` (Yandex), `1.1.1.1` (Cloudflare), `8.8.8.8` (Google).

---

## #13 — Docker Hub 429 Too Many Requests (alpine:3.21)

**Ошибка:**
```
alpine:3.21: unexpected status from HEAD request to
https://registry-1.docker.io/v2/library/alpine/manifests/3.21: 429 Too Many Requests
```
**Причина:** IP сервера превысил лимит анонимных pull-запросов к Docker Hub (100/6h).  
**Исправление в `install.sh`:**
1. `configure_mirror()` — `/etc/docker/daemon.json` с `mirror.gcr.io` + `dockerhub.azk8s.cn`
2. `pull_base_images()` — предварительный pull с 5 попытками и нарастающим backoff
3. `docker compose build --pull=never` — без обращений к registry во время сборки
