import http from 'node:http'
import net from 'node:net'
import { readFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { WebSocketServer, WebSocket } from 'ws'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), 'dist')
const mime = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' }

// One browser connection = one TCP player. Haskell remains the only rules engine.
export function createBridge({ tcpPort = 4000, devOrigin = 'http://127.0.0.1:5173' } = {}) {
  const server = http.createServer(async (request, response) => {
    if (!['GET', 'HEAD'].includes(request.method)) { response.writeHead(405).end(); return }
    try {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname)
      const filename = path.resolve(root, '.' + (pathname === '/' ? '/index.html' : pathname))
      if (!filename.startsWith(root + path.sep)) { response.writeHead(403).end(); return }
      const bytes = await readFile(filename)
      response.writeHead(200, { 'Content-Type': mime[path.extname(filename)] ?? 'application/octet-stream', 'X-Content-Type-Options': 'nosniff' })
      response.end(request.method === 'HEAD' ? undefined : bytes)
    } catch { response.writeHead(404).end('Build the UI first: pnpm build') }
  })
  const sockets = new Set()
  const websocket = new WebSocketServer({
    server, path: '/play', maxPayload: 256,
    verifyClient: ({ origin, req }) => {
      const port = server.address()?.port
      const origins = [`http://127.0.0.1:${port}`, `http://localhost:${port}`, devOrigin]
      return origins.includes(origin) && origins.some((url) => new URL(url).host === req.headers.host)
    },
  })
  websocket.on('connection', (ws) => {
    const tcp = net.createConnection({ host: '127.0.0.1', port: tcpPort })
    sockets.add(tcp)
    let buffer = Buffer.alloc(0)
    const timer = setTimeout(() => tcp.destroy(new Error('TCP connect timeout')), 5000)
    timer.unref()
    tcp.on('connect', () => clearTimeout(timer))
    const cleanup = () => { clearTimeout(timer); sockets.delete(tcp); tcp.destroy() }
    ws.on('error', cleanup)
    ws.on('close', cleanup)
    ws.on('message', (bytes, binary) => {
      if (binary) { ws.close(1003, 'Text commands only'); return }
      const line = bytes.toString('utf8')
      if (!line.length || /[^\x20-\x7e]/.test(line)) {
        ws.send('ERROR INVALID_COMMAND'); return
      }
      if (tcp.writableLength > 65536) { ws.close(1008, 'Too many pending commands'); return }
      tcp.write(line + '\n')
    })
    tcp.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk])
      let end
      while ((end = buffer.indexOf(10)) >= 0) {
        const payload = buffer.subarray(0, end)
        const line = payload.at(-1) === 13 ? payload.subarray(0, -1) : payload
        if (line.length > 256 || line.some((byte) => byte < 32 || byte > 126)) {
          tcp.destroy(new Error('Invalid server frame')); return
        }
        if (ws.readyState === WebSocket.OPEN) {
          if (ws.bufferedAmount > 65536) { ws.terminate(); return }
          ws.send(line.toString('ascii'))
        }
        buffer = buffer.subarray(end + 1)
      }
      if (buffer.length > 257) tcp.destroy(new Error('Server line too long'))
    })
    tcp.on('end', () => ws.close(buffer.length ? 1011 : 1000, buffer.length ? 'Incomplete server frame' : 'Match closed'))
    tcp.on('error', () => ws.close(1011, 'Haskell server unavailable'))
    tcp.on('close', () => { cleanup(); ws.close() })
  })
  return {
    server,
    close: async () => {
      for (const ws of websocket.clients) ws.terminate()
      for (const socket of sockets) socket.destroy()
      await new Promise((resolve) => websocket.close(resolve))
      server.closeAllConnections()
      await new Promise((resolve) => server.close(resolve))
    },
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const tcpPort = Number(process.env.BATTLESHIP_TCP_PORT ?? 4000)
  const port = Number(process.env.PORT ?? 8080)
  if (![tcpPort, port].every((value) => Number.isInteger(value) && value >= 1 && value <= 65535)) {
    throw new Error('PORT and BATTLESHIP_TCP_PORT must be integers from 1 to 65535')
  }
  const bridge = createBridge({ tcpPort })
  bridge.server.on('error', (error) => { console.error(error.message); process.exitCode = 1 })
  bridge.server.listen(port, '127.0.0.1', () => console.log(`Battleship UI: http://127.0.0.1:${port} → TCP ${tcpPort}`))
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => void bridge.close())
}
