import { defineConfig } from 'vite'

export default defineConfig({
  server: {
    host: '127.0.0.1',
    proxy: { '/play': { target: 'ws://127.0.0.1:8080', ws: true } },
  },
})
