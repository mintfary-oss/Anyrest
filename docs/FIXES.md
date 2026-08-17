# Ошибки и исправления в процессе разработки

---

## Ошибка #1: `input.NewStubInjector` не определён на Linux

**Когда:** Сборка агента (`go build -o /dev/null ./...`)

**Ошибка:**
```
# github.com/mintfary-oss/anyrest/agent/cmd
cmd/main.go:80:16: undefined: input.NewStubInjector
```

**Причина:**  
`input_stub.go` имеет build tag `//go:build !linux` — на Linux он не компилируется.  
В `cmd/main.go` использовался `switch runtime.GOOS` с вызовом `input.NewStubInjector()` в ветке `default`, но на Linux компилятор видит только функции из `input_linux.go`.

**Исправление:**  
Созданы два файла-фабрики с взаимоисключающими build tags:

```go
// factory_linux.go
//go:build linux
func NewDefaultInjector(display string) Injector {
    return NewLinuxInjector(display)
}

// factory_other.go
//go:build !linux
func NewDefaultInjector(display string) Injector {
    return NewStubInjector()
}
```

`cmd/main.go` теперь просто вызывает `input.NewDefaultInjector(*displayStr)` — компилируется на любой ОС.

---

## Ошибка #2: PR не создан — пустой репозиторий

**Когда:** `gh pr create` для ветки `neo/initial-anyrest-impl-k9a7f`

**Ошибка:**
```
pull request create failed: GraphQL: Head sha can't be blank, 
Base sha can't be blank, No commits between main and neo/initial-anyrest-impl-k9a7f, 
Base ref must be a branch (createPullRequest)
```

**Причина:**  
Репозиторий был полностью пустым — нет ветки `main`, нет ни одного коммита на базовой ветке. GitHub не позволяет создать PR без базовой ветки.

**Исправление:**  
Следуем процедуре для пустых репозиториев: напрямую пушим коммит на ветку `main`, создавая её как первичную ветку репозитория. Документационные файлы добавлены по запросу пользователя перед итоговым пушем.

---

## Ошибка #3: Аутентификация при git push

**Когда:** `git push -u origin neo/initial-anyrest-impl-k9a7f`

**Ошибка:**
```
remote: Invalid username or token. 
Password authentication is not supported for Git operations.
fatal: Authentication failed
```

**Причина:**  
Стандартный git credential helper не имел токена для `github.com/mintfary-oss`.

**Исправление:**  
```bash
git remote set-url origin "https://x-access-token:TOKEN@github.com/mintfary-oss/Anyrest.git"
```

---

## Ошибка #4: Стрим видео vs JPEG через Data Channel

**Когда:** Проектирование видео-стрима

**Проблема:**  
Первоначальный план предполагал WebRTC VideoTrack с H.264/VP8 кодированием в Go.  
Для этого нужны CGO-зависимости (libx264, libvpx), которые:
- Усложняют Docker-сборку
- Требуют нативных библиотек в образе
- Добавляют нестабильные C-биндинги

**Решение:**  
Использование **JPEG-фреймов через Data Channel**:
- Захват → JPEG → бинарное сообщение (12-байт header + payload)
- Нет CGO зависимостей
- Работает сразу на любой платформе
- Качество достаточно для remote desktop при 15fps, 1280×720, quality=75
- Типичный размер фрейма: 30–150 KB (хорошо вписывается в SCTP 256KB лимит)

---

## Ошибка #5: RemoteScreen использовал `<video>` вместо `<canvas>`

**Когда:** Обновление веб-клиента под JPEG-фреймы

**Проблема:**  
`RemoteScreen.tsx` использовал `<video srcObject={stream}>` — это работает только с `MediaStream` из WebRTC VideoTrack, но не с бинарными Data Channel сообщениями.

**Исправление:**  
Переработан на `<canvas ref={canvasRef}>` с рендерингом через `Image + drawImage`:
```typescript
const img = new Image();
img.onload = () => {
    ctx.drawImage(img, 0, 0);
    URL.revokeObjectURL(frameUrl); // освобождение памяти
};
img.src = URL.createObjectURL(new Blob([jpeg], { type: 'image/jpeg' }));
```

---

## Ошибка #6: `vite.config.ts` — неправильная структура HTTPS

**Когда:** Конфигурация Vite dev-сервера

**Проблема:**  
`https: true` в Vite не работает если нет certfile — нужно явно передавать cert/key или undefined.

**Исправление:**  
```typescript
https: (() => {
    try {
        if (fs.existsSync(certPath) && fs.existsSync(keyPath)) {
            return { cert: fs.readFileSync(certPath), key: fs.readFileSync(keyPath) }
        }
    } catch { /* ignore */ }
    return undefined  // fallback на HTTP
})(),
```

Сервер поднимается на HTTP если сертификатов нет (удобно для разработки).

---

## Ошибка #7: `Dockerfile.server` — FROM scratch без shell

**Когда:** Первый `docker compose up --build` на реальном сервере

**Ошибка:**
```
web container depends_on signal (healthy) — never became healthy
```

**Причина:**  
`FROM scratch` не содержит shell (`/bin/sh`), поэтому `CMD-SHELL` в healthcheck не работает. Docker считает контейнер нездоровым, и web-контейнер не стартует.

**Исправление:**  
Заменено на `FROM alpine:3.21` с установкой `wget` и `ca-certificates`.  
Healthcheck переписан на `wget -qO- http://localhost:8080/health`.

---

## Ошибка #8: `nginx.conf` — ssl_ciphers на нескольких строках

**Когда:** Старт NGINX-контейнера

**Ошибка:**
```
nginx: [emerg] invalid parameter "ECDHE-RSA-AES128-GCM-SHA256:..." 
in /etc/nginx/nginx.conf:44
```

**Причина:**  
Директива `ssl_ciphers` была разбита на несколько строк — NGINX не поддерживает продолжение строки с `\`.

**Исправление:**  
Весь список шифров помещён в одну строку.

---

## Ошибка #9: `gen-certs.sh` — process substitution `< <(...)`

**Когда:** Генерация сертификатов в Docker Alpine

**Ошибка:**
```
bash: /dev/fd/63: No such file or directory
```

**Причина:**  
`< <(...)` (process substitution) требует `/dev/fd/` — в минимальных Alpine-контейнерах этого нет.

**Исправление:**  
Использование временного файла через `mktemp`:
```bash
local ip_file
ip_file="$(mktemp)"
collect_ips | sort -u > "$ip_file"
while IFS= read -r ip; do
    ...
done < "$ip_file"
rm -f "$ip_file"
```

---

## Ошибка #10: `npm ci` — "Exit handler never called!" в Docker

**Когда:** `docker compose up --build` — стадия `[web web-builder 4/6] RUN npm ci`

**Ошибка:**
```
npm error Exit handler never called!
npm error This is an error with npm itself. Please report this error at:
npm error    https://github.com/npm/cli/issues
```

**Причина:**  
- `node:22-alpine` поставляется с **npm 10**
- `package-lock.json` в репозитории создан **npm 11** (lockfileVersion: 3)
- npm 10 не может полностью обработать lockfile v3 → зависает/крашится через ~105 сек

**Исправление:**  
В `Dockerfile.web` изменена базовая образ:
```dockerfile
# Было:
FROM node:22-alpine AS web-builder
# Стало:
FROM node:24-alpine AS web-builder
```
Node 24 поставляется с npm 11 — той же версией, что создала lockfile. `npm ci` работает без ошибок.

---

## Ошибка #11: TypeScript TS1294 — `erasableSyntaxOnly` запрещает parameter properties

**Когда:** `npm run build` в стадии Docker (после исправления ошибки #10)

**Ошибка:**
```
src/lib/signaling.ts(24,15): error TS1294: This syntax is not allowed when 'erasableSyntaxOnly' is enabled.
src/lib/webrtc.ts(38,5): error TS1294: This syntax is not allowed when 'erasableSyntaxOnly' is enabled.
src/lib/webrtc.ts(39,5): error TS1294: This syntax is not allowed when 'erasableSyntaxOnly' is enabled.
src/lib/webrtc.ts(40,5): error TS1294: This syntax is not allowed when 'erasableSyntaxOnly' is enabled.
```

**Причина:**  
`tsconfig.app.json` содержал `"erasableSyntaxOnly": true`. Этот флаг (TypeScript 5.5+) запрещает синтаксис, который не может быть просто «стёрт» при компиляции — в том числе **parameter properties** в конструкторах:
```typescript
// Запрещено при erasableSyntaxOnly: true
constructor(private readonly serverUrl: string) { ... }
```
Флаг предназначен для сред, где TypeScript запускается напрямую (Node.js native strips). Для Vite/esbuild он не нужен — esbuild сам транспилирует TypeScript.

**Исправление:**  
Удалена строка `"erasableSyntaxOnly": true` из `web/tsconfig.app.json`.  
Проверено: `npm run build` выдаёт чистый бандл 217 KB, 0 ошибок TypeScript.
