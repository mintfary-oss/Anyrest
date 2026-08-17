import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    // Dev server runs over HTTPS using the generated certs.
    // If certs are not present, Vite falls back to HTTP automatically.
    https: (() => {
      try {
        const fs = require('node:fs')
        const certPath = '../certs/server.crt'
        const keyPath  = '../certs/server.key'
        if (fs.existsSync(certPath) && fs.existsSync(keyPath)) {
          return { cert: fs.readFileSync(certPath), key: fs.readFileSync(keyPath) }
        }
      } catch { /* ignore */ }
      return undefined
    })(),
    port: 5173,
    host: '0.0.0.0',
  },
  build: {
    outDir: 'dist',
    sourcemap: true,
  },
  define: {
    // Replaced at Docker build time via --build-arg or env substitution
    'window.ANYREST_SIGNAL_URL': JSON.stringify(process.env.ANYREST_SIGNAL_URL ?? ''),
  },
})
