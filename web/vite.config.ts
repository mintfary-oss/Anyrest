import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],

  server: {
    // Dev server — HTTPS только если сертификаты уже сгенерированы.
    // В продакшне TLS обрабатывает NGINX, поэтому здесь это опционально.
    https: (() => {
      try {
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        const fs = require('node:fs') as typeof import('fs')
        const certPath = '../certs/server.crt'
        const keyPath  = '../certs/server.key'
        if (fs.existsSync(certPath) && fs.existsSync(keyPath)) {
          return { cert: fs.readFileSync(certPath), key: fs.readFileSync(keyPath) }
        }
      } catch { /* нет сертификатов — используем HTTP для разработки */ }
      return undefined
    })(),
    port: 5173,
    host: '0.0.0.0',
  },

  build: {
    outDir: 'dist',
    // sourcemap отключён в продакшне чтобы не раскрывать исходники
    sourcemap: false,
  },

  define: {
    // BUGFIX: определяем window.ANYREST_SIGNAL_URL ТОЛЬКО если переменная
    // реально задана. Если передать пустую строку, оператор ?? не сработает
    // (пустая строка не является null/undefined), и WebSocket подключится к "".
    // В продакшне через NGINX сигнал всегда на том же хосте,
    // поэтому wss://${window.location.host}/ws работает без дополнительных настроек.
    ...(process.env.ANYREST_SIGNAL_URL
      ? { 'window.ANYREST_SIGNAL_URL': JSON.stringify(process.env.ANYREST_SIGNAL_URL) }
      : {}),
  },
})
