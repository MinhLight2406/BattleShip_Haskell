import http from 'node:http'
import net from 'node:net'
import { readFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { networkInterfaces } from 'node:os'
import { randomBytes } from 'node:crypto'
import { WebSocketServer, WebSocket } from 'ws'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), 'dist')
const mime = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' }

export const RECONNECT_GRACE_MS = 5 * 60 * 1000
export function lanAddresses(interfaces = networkInterfaces(), selected) {
  return [...new Set(Object.entries(interfaces)
    .filter(([name]) => !selected || name === selected)
    .flatMap(([, entries]) => entries ?? [])
    .filter(({ family, internal, address }) => (family === 'IPv4' || family === 4) && !internal &&
      net.isIP(address) === 4 && !address.startsWith('127.') && !address.startsWith('169.254.'))
    .map(({ address }) => address))]
}

export function readBridgeConfig(env = process.env) {
  const readPort = (name, fallback) => {
    const value = env[name] ?? String(fallback)
    if (!/^[1-9][0-9]{0,4}$/.test(value) || Number(value) > 65535)
      throw new Error(`${name} must be a decimal integer from 1 to 65535`)
    return Number(value)
  }
  const port = readPort('PORT', 8080)
  const tcpPort = readPort('BATTLESHIP_TCP_PORT', 4000)
  const autoLan = env.HOST === undefined && env.PUBLIC_ORIGIN === undefined
  const host = env.HOST === 'localhost' ? '127.0.0.1' : (env.HOST ?? (autoLan ? '0.0.0.0' : '127.0.0.1'))
  if (net.isIP(host) !== 4) throw new Error('HOST must be an IPv4 address or localhost')
  const local = host.startsWith('127.')
  let publicOrigin
  if (env.PUBLIC_ORIGIN !== undefined) {
    let url
    try { url = new URL(env.PUBLIC_ORIGIN) }
    catch { throw new Error('PUBLIC_ORIGIN must be an HTTP origin, e.g. http://192.168.1.10:8080') }
    if (url.protocol !== 'http:' || url.username || url.password || url.search || url.hash ||
        url.pathname !== '/' || !/^http:\/\/[^/?#@\\\s]+\/?$/i.test(env.PUBLIC_ORIGIN) ||
        !(net.isIP(url.hostname) === 4 || url.hostname === 'localhost') ||
        ['0.0.0.0', '255.255.255.255'].includes(url.hostname))
      throw new Error('PUBLIC_ORIGIN must be a bare HTTP origin with an IPv4 address or localhost; no path, query or credentials')
    if (Number(url.port || 80) !== port) throw new Error('PUBLIC_ORIGIN port must match PORT')
    const originLocal = url.hostname === 'localhost' || url.hostname.startsWith('127.')
    if (local !== originLocal || (host !== '0.0.0.0' && url.hostname !== host && !(host === '127.0.0.1' && url.hostname === 'localhost')))
      throw new Error('PUBLIC_ORIGIN address must match HOST; use HOST=0.0.0.0 with your LAN IP for all IPv4 interfaces')
    publicOrigin = url.origin
  }
  if (!local && !publicOrigin && !autoLan) throw new Error('PUBLIC_ORIGIN is required when HOST listens beyond localhost')
  return { host, port, tcpPort, publicOrigin, autoLan, lanInterface: env.LAN_INTERFACE }
}

// One resumable browser session = one TCP player. Haskell owns every game rule.
export function createBridge({ tcpPort = 4000, devOrigin = 'http://127.0.0.1:5173', host = '127.0.0.1', port = 8080,
  publicOrigin, autoLan = false, lanInterface, reconnectGraceMs = RECONNECT_GRACE_MS, heartbeatMs = 10000,
  addresses = () => lanAddresses(networkInterfaces(), lanInterface) } = {}) {
  const config = readBridgeConfig({ HOST: autoLan ? undefined : host, PORT: String(port),
    BATTLESHIP_TCP_PORT: String(tcpPort), PUBLIC_ORIGIN: publicOrigin })
  const sessions = new Map()
  let stopping = false
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
      const actualPort = server.address()?.port
      const origins = [`http://127.0.0.1:${actualPort}`, `http://localhost:${actualPort}`, devOrigin]
      if (config.host.startsWith('127.')) origins.push(`http://${config.host}:${actualPort}`)
      if (config.publicOrigin && actualPort === config.port) origins.push(config.publicOrigin)
      if (config.autoLan) origins.push(...addresses().map((ip) => new URL(`http://${ip}:${actualPort}`).origin))
      return origins.some((allowed) => new URL(allowed).origin === origin) && new URL(origin).host === req.headers.host
    },
  })
  // ws mirrors listener errors; the caller handles them on the HTTP server.
  websocket.on('error', () => {})
  const send = (ws, message) => {
    if (ws?.readyState === WebSocket.OPEN) {
      if (ws.bufferedAmount > 65536) { ws.terminate(); return }
      ws.send(typeof message === 'string' ? message : JSON.stringify(message))
    }
  }
  const connectionState = () => ({ type: 'CONNECTION', missing: [...sessions.values()]
    .filter((session) => session.deadline && !session.ended)
    .map(({ player, deadline }) => ({ player, deadline })) })
  const notify = () => { for (const session of sessions.values()) send(session.ws, connectionState()) }
  const expire = (session) => {
    if (session.ended) return
    session.ended = true
    clearTimeout(session.grace)
    // Only Haskell decides the winner. Expiry is exactly the existing Quit command.
    if (session.tcp.writable) session.tcp.end('QUIT\n')
    else session.tcp.destroy()
  }
  const attach = (session, ws) => {
    session.ws = ws
    ws.alive = true
    ws.on('pong', () => { ws.alive = true })
    ws.on('error', () => ws.terminate())
    ws.on('close', () => {
      if (session.ws !== ws) return
      session.ws = null
      if (stopping || session.ended) return
      if (!session.player) { session.tcp.destroy(); return }
      if (reconnectGraceMs === 0) { expire(session); return }
      session.deadline = Date.now() + reconnectGraceMs
      session.grace = setTimeout(() => expire(session), reconnectGraceMs)
      notify()
    })
    ws.on('message', (bytes, binary) => {
      if (session.ended) return
      if (binary) { ws.close(1003, 'Text commands only'); return }
      const line = bytes.toString('utf8')
      if (!line.length || /[^\x20-\x7e]/.test(line)) { send(ws, 'ERROR INVALID_COMMAND'); return }
      if (line !== 'QUIT' && [...sessions.values()].some((peer) => peer.deadline && !peer.ended)) {
        send(ws, connectionState()); return
      }
      if (session.tcp.writableLength > 65536) { ws.close(1008, 'Too many pending commands'); return }
      session.commands.push(line)
      if (session.commands.length > 256) { ws.close(1008, 'Too many pending commands'); return }
      session.tcp.write(line + '\n')
    })
  }
  // Ping detects a Wi-Fi loss even when the browser cannot send a close frame.
  const heartbeat = setInterval(() => {
    for (const ws of websocket.clients) {
      if (!ws.alive) ws.terminate()
      else { ws.alive = false; ws.ping() }
    }
  }, heartbeatMs)
  heartbeat.unref()
  websocket.on('connection', (ws, request) => {
    const url = new URL(request.url, 'http://localhost')
    if (url.searchParams.has('resume')) {
      const token = url.searchParams.get('resume')
      const session = sessions.get(token)
      if (!session || (session.ended && !session.frames.some((line) => line.startsWith('GAME_OVER '))) ||
          (session.deadline && Date.now() >= session.deadline && !session.ended)) {
        if (session && !session.ended) expire(session)
        send(ws, { type: 'RESUME_ERROR', code: 'INVALID_SESSION', message: 'Phiên không tồn tại hoặc đã hết 5 phút khôi phục.' })
        ws.close(1008, 'Invalid or expired session'); return
      }
      if (session.ws) {
        send(ws, { type: 'RESUME_ERROR', code: 'SESSION_ACTIVE', message: 'Đang chờ kết nối cũ đóng; sẽ tự thử lại.' })
        ws.close(1008, 'Session already connected'); return
      }
      clearTimeout(session.grace)
      session.deadline = null
      attach(session, ws)
      send(ws, { type: 'SESSION', token, fleet: session.fleet, frames: session.frames })
      notify()
      if (session.ended) ws.close(1000, 'Match closed')
      return
    }
    const tcp = net.createConnection({ host: '127.0.0.1', port: tcpPort })
    sockets.add(tcp)
    const token = randomBytes(32).toString('hex')
    const session = { tcp, token, ws: null, player: null, fleet: null, frames: [], commands: [], deadline: null, ended: false }
    attach(session, ws)
    let buffer = Buffer.alloc(0)
    const timer = setTimeout(() => tcp.destroy(new Error('TCP connect timeout')), 5000)
    timer.unref()
    tcp.on('connect', () => clearTimeout(timer))
    let cleaned = false
    const cleanup = () => {
      if (cleaned) return
      cleaned = true
      clearTimeout(timer); clearTimeout(session.grace); sockets.delete(tcp); session.ended = true
      if (!stopping && sessions.has(token)) {
        session.grace = setTimeout(() => sessions.delete(token), RECONNECT_GRACE_MS)
        session.grace.unref()
      }
    }
    tcp.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk])
      let end
      while ((end = buffer.indexOf(10)) >= 0) {
        const payload = buffer.subarray(0, end)
        const line = payload.at(-1) === 13 ? payload.subarray(0, -1) : payload
        if (line.length > 256 || line.some((byte) => byte < 32 || byte > 126)) {
          tcp.destroy(new Error('Invalid server frame')); return
        }
        const text = line.toString('ascii')
        if (text === 'OK PLACE' || text.startsWith('ERROR ') || text.startsWith('SHOT ')) {
          const command = session.commands.shift()
          if (text === 'OK PLACE' && command?.startsWith('PLACE ')) session.fleet = command
        }
        if (text.startsWith('WELCOME 1 ')) {
          session.player = text.slice(-2)
          sessions.set(token, session)
          send(session.ws, { type: 'SESSION', token, fleet: null, frames: null })
        }
        session.frames.push(text)
        if (session.frames.length > 4096) { tcp.destroy(new Error('Too many session frames')); return }
        if (text === 'OK PLACE') send(session.ws, { type: 'SESSION', token, fleet: session.fleet, frames: null })
        send(session.ws, text)
        buffer = buffer.subarray(end + 1)
      }
      if (buffer.length > 257) tcp.destroy(new Error('Server line too long'))
    })
    tcp.on('end', () => { cleanup(); session.ws?.close(buffer.length ? 1011 : 1000, buffer.length ? 'Incomplete server frame' : 'Match closed') })
    tcp.on('error', () => { cleanup(); session.ws?.close(1011, 'Haskell server unavailable') })
    tcp.on('close', () => { cleanup(); session.ws?.close() })
  })
  return {
    server,
    close: async () => {
      stopping = true
      clearInterval(heartbeat)
      for (const session of sessions.values()) clearTimeout(session.grace)
      for (const ws of websocket.clients) ws.terminate()
      for (const socket of sockets) socket.destroy()
      await new Promise((resolve) => websocket.close(resolve))
      server.closeAllConnections()
      await new Promise((resolve) => server.close(resolve))
    },
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let config
  try {
    config = readBridgeConfig()
    if (config.autoLan && config.lanInterface && !networkInterfaces()[config.lanInterface])
      throw new Error(`LAN_INTERFACE does not exist or has no active address: ${config.lanInterface}`)
  }
  catch (error) {
    console.error(`Battleship bridge configuration: ${error.message}`)
    process.exit(1)
  }
  const bridge = createBridge(config)
  bridge.server.on('error', (error) => { console.error(`Battleship bridge listen (${config.host}:${config.port}): ${error.message}`); process.exitCode = 1 })
  bridge.server.listen(config.port, config.host, () => {
    let previous
    const logAddresses = () => {
      const links = config.autoLan ? lanAddresses(networkInterfaces(), config.lanInterface)
        .map((ip) => `http://${ip}:${config.port}`) : [config.publicOrigin ?? `http://${config.host}:${config.port}`]
      const signature = links.join(',')
      if (signature === previous) return
      previous = signature
      console.log(`Battleship UI → TCP 127.0.0.1:${config.tcpPort}; reconnect grace: 5 minutes`)
      console.log(`Listening on ${config.host}:${config.port}.`)
      for (const address of links) console.log(`Open ${address} on each player device.`)
      if (!links.length) console.log(`No LAN IPv4 yet. Local UI: http://127.0.0.1:${config.port}`)
    }
    logAddresses()
    if (config.autoLan) {
      const monitor = setInterval(logAddresses, 2000)
      monitor.unref()
      bridge.server.once('close', () => clearInterval(monitor))
    }
  })
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => void bridge.close())
}
