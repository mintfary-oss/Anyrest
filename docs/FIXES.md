# Ошибки и исправления в процессе разработки

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
