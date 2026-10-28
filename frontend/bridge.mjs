import http from 'node:http'
import net from 'node:net'
import { mkdir, open, readFile, rename, rm } from 'node:fs/promises'
import { openSync, readSync, closeSync, fstatSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { networkInterfaces } from 'node:os'
import { createHash, randomBytes } from 'node:crypto'
import { WebSocketServer, WebSocket } from 'ws'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), 'dist')
const mime = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' }

export const RECONNECT_GRACE_MS = 5 * 60 * 1000
export function lanAddresses(interfaces = networkInterfaces(), selected) {
  return [...new Set(Object.entries(interfaces)
    .filter(([name]) => !selected || name === selected)
    .flatMap(([, entries]) => entries ?? [])
    .filter(({ family, internal, address }) => (family === 'IPv4' || family === 4) && !internal &&
      net.isIP(address) === 4 && !address.startsWith('127.') && !address.startsWith('169.254.') &&
      !['0.0.0.0', '255.255.255.255'].includes(address))
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
  const tcpHost = env.BATTLESHIP_TCP_HOST ?? '127.0.0.1'
  const labels = tcpHost.split('.')
  if (net.isIP(tcpHost) !== 4 && (/^[0-9.]+$/.test(tcpHost) || tcpHost.length > 253 ||
      !labels.every((label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label))))
    throw new Error('BATTLESHIP_TCP_HOST must be a canonical IPv4 address or DNS hostname (no URL, port or whitespace)')
  const publicPort = env.WEB_PUBLIC_PORT === undefined ? undefined : readPort('WEB_PUBLIC_PORT', port)
  const originSetting = env.PUBLIC_ORIGIN || undefined
  const lanOriginsFile = env.LAN_ORIGINS_FILE || undefined
  const sessionFile = env.BATTLESHIP_SESSION_FILE || undefined
  if (lanOriginsFile && (!path.isAbsolute(lanOriginsFile) || lanOriginsFile.includes('\0')))
    throw new Error('LAN_ORIGINS_FILE must be an absolute file path')
  if (sessionFile && (!path.isAbsolute(sessionFile) || sessionFile.includes('\0')))
    throw new Error('BATTLESHIP_SESSION_FILE must be an absolute file path')
  if (originSetting && lanOriginsFile) throw new Error('PUBLIC_ORIGIN and LAN_ORIGINS_FILE are mutually exclusive')
  if (publicPort !== undefined && !originSetting && !lanOriginsFile)
    throw new Error('PUBLIC_ORIGIN or LAN_ORIGINS_FILE is required with WEB_PUBLIC_PORT')
  const autoLan = publicPort === undefined && !lanOriginsFile && env.HOST === undefined && !originSetting
  const host = env.HOST === 'localhost' ? '127.0.0.1' : (env.HOST ?? (autoLan || lanOriginsFile ? '0.0.0.0' : '127.0.0.1'))
  if (net.isIP(host) !== 4) throw new Error('HOST must be an IPv4 address or localhost')
  const local = host.startsWith('127.')
  let publicOrigin
  if (originSetting) {
    const url = parseHttpOrigin(originSetting, 'PUBLIC_ORIGIN')
    if (Number(url.port || 80) !== (publicPort ?? port))
      throw new Error(`PUBLIC_ORIGIN port must match ${publicPort === undefined ? 'PORT' : 'WEB_PUBLIC_PORT'}`)
    const originLocal = url.hostname === 'localhost' || url.hostname.startsWith('127.')
    if (host !== '0.0.0.0' && (local !== originLocal ||
        (url.hostname !== host && !(host === '127.0.0.1' && url.hostname === 'localhost'))))
      throw new Error('PUBLIC_ORIGIN address must match HOST; use HOST=0.0.0.0 with your LAN IP for all IPv4 interfaces')
    publicOrigin = url.origin
  }
  if (!local && !publicOrigin && !autoLan && !lanOriginsFile)
    throw new Error('PUBLIC_ORIGIN is required when HOST listens beyond localhost')
  return { host, port, tcpHost, tcpPort, publicPort, publicOrigin, autoLan, lanOriginsFile, sessionFile, lanInterface: env.LAN_INTERFACE || undefined }
}

function parseHttpOrigin(value, label) {
  // Validate raw authority too: URL otherwise accepts shortened/hex IPv4 forms.
  const match = typeof value === 'string' && /^http:\/\/(localhost|[0-9.]+)(?::([1-9][0-9]{0,4}))?\/?$/i.exec(value)
  if (!match || (match[1].toLowerCase() !== 'localhost' && net.isIP(match[1]) !== 4) ||
      (match[2] && Number(match[2]) > 65535) || ['0.0.0.0', '255.255.255.255'].includes(match[1]))
    throw new Error(`${label} must be a bare HTTP origin with canonical IPv4 or localhost; no path, query or credentials`)
  return new URL(value)
}

export function parseLanOrigins(bytes, publicPort, now = Date.now()) {
  if (bytes.length > 8192) throw new Error('LAN_ORIGINS_FILE exceeds 8 KiB')
  let data
  try { data = JSON.parse(new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes)) }
  catch { throw new Error('LAN_ORIGINS_FILE must contain UTF-8 JSON without BOM') }
  if (!data || Array.isArray(data) || Object.keys(data).sort().join(',') !== 'origins,updatedAt,version' ||
      data.version !== 1 || !Number.isSafeInteger(data.updatedAt) || data.updatedAt < 0 ||
      !Array.isArray(data.origins) || data.origins.length > 16)
    throw new Error('LAN_ORIGINS_FILE has an invalid version/updatedAt/origins schema')
  if (now - data.updatedAt < -2000 || now - data.updatedAt >= 10000)
    throw new Error('LAN_ORIGINS_FILE is stale or has a future timestamp')
  const origins = data.origins.map((value) => {
    const url = parseHttpOrigin(value, 'LAN_ORIGINS_FILE origin')
    if (url.origin !== value || net.isIP(url.hostname) !== 4 || url.hostname.startsWith('127.') ||
        url.hostname.startsWith('169.254.') || Number(url.port || 80) !== publicPort)
      throw new Error('LAN_ORIGINS_FILE origins must be canonical LAN IPv4 origins at WEB_PUBLIC_PORT')
    return url.origin
  })
  return [...new Set(origins)]
}

function loadSessions(filename) {
  let text
  try { text = readFileSync(filename, 'utf8') }
  catch (error) {
    if (error.code === 'ENOENT') return { commands: [], sessions: [] }
    throw error
  }
  let value
  try { value = JSON.parse(text) }
  catch { throw new Error('BATTLESHIP_SESSION_FILE contains invalid JSON; preserve the file and repair it before starting.') }
  if (!value || value.version !== 1 || !Array.isArray(value.commands) || !Array.isArray(value.sessions) ||
      value.commands.length > 4096 || value.sessions.length > 2 ||
      new Set(value.sessions.map((entry) => entry?.key)).size !== value.sessions.length ||
      new Set(value.sessions.map((entry) => entry?.session?.player)).size !== value.sessions.length ||
      !value.commands.every((entry) => entry && ['P1', 'P2'].includes(entry.player) &&
        typeof entry.line === 'string' && entry.line.length > 0 && entry.line.length <= 256 && /^[\x20-\x7e]+$/.test(entry.line)) ||
      !value.sessions.every((entry) => entry && /^[a-f0-9]{64}$/.test(entry.key) && entry.session &&
        ['P1', 'P2'].includes(entry.session.player) && (entry.session.fleet === null ||
          (typeof entry.session.fleet === 'string' && entry.session.fleet.length <= 256)) &&
        Array.isArray(entry.session.frames) && entry.session.frames.length <= 4096 &&
        entry.session.frames.every((frame) => typeof frame === 'string' && frame.length <= 256 && /^[\x20-\x7e]*$/.test(frame))))
    throw new Error('BATTLESHIP_SESSION_FILE has an invalid session journal; preserve the file and repair it before starting.')
  return value
}

function readLanOriginsFile(filename, publicPort) {
  const descriptor = openSync(filename, 'r')
  try {
    if (!fstatSync(descriptor).isFile()) throw new Error('LAN_ORIGINS_FILE must be a regular file')
    const bytes = Buffer.alloc(8193)
    let count = 0, received
    do { received = readSync(descriptor, bytes, count, bytes.length - count); count += received }
    while (received && count < bytes.length)
    return parseLanOrigins(bytes.subarray(0, count), publicPort)
  } finally { closeSync(descriptor) }
}

// One resumable browser session = one TCP player. Haskell owns every game rule.
export function createBridge({ tcpHost = '127.0.0.1', tcpPort = 4000, devOrigin = 'http://127.0.0.1:5173', host = '127.0.0.1', port = 8080,
  publicPort, publicOrigin, lanOriginsFile, sessionFile, autoLan = false, lanInterface, reconnectGraceMs = RECONNECT_GRACE_MS, heartbeatMs = 10000,
  addresses = () => lanAddresses(networkInterfaces(), lanInterface) } = {}) {
  const config = readBridgeConfig({ HOST: autoLan ? undefined : host, PORT: String(port),
    BATTLESHIP_TCP_HOST: tcpHost, BATTLESHIP_TCP_PORT: String(tcpPort), PUBLIC_ORIGIN: publicOrigin,
    WEB_PUBLIC_PORT: publicPort === undefined ? undefined : String(publicPort), LAN_ORIGINS_FILE: lanOriginsFile,
    BATTLESHIP_SESSION_FILE: sessionFile })
  let lanOrigins = config.lanOriginsFile ? readLanOriginsFile(config.lanOriginsFile, config.publicPort ?? config.port) : []
  const sessions = new Map()
  const durable = config.sessionFile ? loadSessions(config.sessionFile) : { commands: [], sessions: [] }
  for (const saved of durable.sessions) sessions.set(saved.key, { ...saved.session, token: undefined, tokenHash: saved.key,
    tcp: null, ws: null, commands: [], pendingAcks: [], deadline: null, grace: undefined, ended: false,
    restoring: false, replayQueue: [], replayWaiters: [] })
  let persistQueue = Promise.resolve()
  let forwardQueue = Promise.resolve()
  let restorePromise
  let matchEnded = false
  let stopping = false
  const server = http.createServer(async (request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname)
      if (pathname === '/healthz') {
        if (request.method !== 'GET') { response.writeHead(405, { Allow: 'GET' }).end(); return }
        response.writeHead(200, { 'Content-Type': 'application/json' }).end('{"status":"ok"}')
        return
      }
      if (!['GET', 'HEAD'].includes(request.method)) { response.writeHead(405).end(); return }
      const filename = path.resolve(root, '.' + (pathname === '/' ? '/index.html' : pathname))
      if (!filename.startsWith(root + path.sep)) { response.writeHead(403).end(); return }
      const bytes = await readFile(filename)
      response.writeHead(200, { 'Content-Type': mime[path.extname(filename)] ?? 'application/octet-stream', 'X-Content-Type-Options': 'nosniff' })
      response.end(request.method === 'HEAD' ? undefined : bytes)
    } catch { response.writeHead(404).end('Build the UI first: pnpm build') }
  })
  let lanError
  const lanMonitor = config.lanOriginsFile ? setInterval(() => {
    const previous = lanOrigins.join(',')
    try {
      lanOrigins = readLanOriginsFile(config.lanOriginsFile, config.publicPort ?? config.port)
      lanError = undefined
    } catch (error) {
      lanOrigins = []
      if (lanError !== error.message) console.error(`Battleship bridge LAN origins: ${error.message}`)
      lanError = error.message
    }
    if (previous !== lanOrigins.join(',')) server.emit('originsChanged')
  }, 2000) : undefined
  lanMonitor?.unref()
  server.once('close', () => clearInterval(lanMonitor))
  const originPort = () => config.publicPort ?? server.address()?.port ?? config.port
  const playerOrigins = () => config.lanOriginsFile ? [...lanOrigins] : config.autoLan
    ? addresses().map((ip) => parseHttpOrigin(`http://${ip}:${originPort()}`, 'LAN address').origin)
    : [config.publicOrigin ?? new URL(`http://${config.host === '0.0.0.0' ? '127.0.0.1' : config.host}:${originPort()}`).origin]
  const sockets = new Set()
  const websocket = new WebSocketServer({
    server, path: '/play', maxPayload: 256,
    verifyClient: ({ origin, req }) => {
      try {
        for (const name of ['origin', 'host'])
          if (req.rawHeaders.filter((_, index) => index % 2 === 0 && req.rawHeaders[index].toLowerCase() === name).length !== 1) return false
        if (typeof req.headers.host !== 'string' || req.headers.host.includes('/')) return false
        const url = parseHttpOrigin(origin, 'Origin')
        if (url.origin !== origin || parseHttpOrigin(`http://${req.headers.host}`, 'Host').origin !== origin) return false
        const origins = [`http://127.0.0.1:${originPort()}`, `http://localhost:${originPort()}`].map((value) => new URL(value).origin)
        if (config.publicPort === undefined && !config.lanOriginsFile) {
          if (devOrigin) origins.push(parseHttpOrigin(devOrigin, 'devOrigin').origin)
          if (config.host.startsWith('127.')) origins.push(new URL(`http://${config.host}:${originPort()}`).origin)
        }
        if (config.publicPort !== undefined || config.lanOriginsFile || config.autoLan || server.address()?.port === config.port)
          origins.push(...playerOrigins())
        return origins.includes(origin)
      } catch { return false }
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
  const tokenKey = (token) => createHash('sha256').update(token).digest('hex')
  const connectionState = () => ({ type: 'CONNECTION', missing: [...sessions.values()]
    .filter((session) => session.deadline && !session.ended)
    .map(({ player, deadline }) => ({ player, deadline })) })
  const notify = () => { for (const session of sessions.values()) send(session.ws, connectionState()) }
  let persistError
  const persistSnapshot = () => {
    if (!config.sessionFile) return Promise.resolve()
    persistQueue = persistQueue.catch(() => {}).then(async () => {
      if (persistError) throw persistError
      const savedSessions = [...sessions.entries()].filter(([, session]) => session.player && !matchEnded)
        .map(([key, session]) => ({ key, session: { player: session.player, fleet: session.fleet, frames: session.frames } }))
      durable.sessions = savedSessions
      const contents = JSON.stringify({ version: 1, commands: matchEnded ? [] : durable.commands, sessions: savedSessions })
      const temporary = `${config.sessionFile}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`
      let handle
      try {
        await mkdir(path.dirname(config.sessionFile), { recursive: true })
        handle = await open(temporary, 'w', 0o600)
        await handle.writeFile(contents, 'utf8')
        await handle.sync()
        await handle.close()
        handle = undefined
        await rename(temporary, config.sessionFile)
      } catch (error) {
        if (handle) await handle.close().catch(() => {})
        await rm(temporary, { force: true }).catch(() => {})
        persistError = error
        throw error
      }
    })
    return persistQueue
  }
  const persistCommand = async (session, line) => {
    if (!config.sessionFile) return
    if (persistError) throw persistError
    if (durable.commands.length >= 4096) throw new Error('Persistent match journal reached its 4096-command limit')
    durable.commands.push({ player: session.player, line })
    await persistSnapshot()
  }
  const clearPersistentMatch = () => { matchEnded = true; durable.commands = []; return persistSnapshot() }
  const expire = (session) => {
    if (session.ended) return
    session.ended = true
    clearTimeout(session.grace)
    if (config.sessionFile) void clearPersistentMatch().catch((error) => console.error(`Battleship session store: ${error.message}`))
    // Only Haskell decides the winner. Expiry is exactly the existing Quit command.
    if (session.tcp?.writable) {
      void persistCommand(session, 'QUIT').then(() => session.tcp?.end('QUIT\n'))
        .catch((error) => { console.error(`Battleship expiry persistence: ${error.message}`); session.tcp?.destroy() })
    }
    else session.tcp?.destroy()
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
      if (!session.player) { session.tcp?.destroy(); return }
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
      if (!session.tcp?.writable || session.tcp.writableLength > 65536) { ws.close(1011, 'Haskell server unavailable'); return }
      session.commands.push(line)
      if (session.commands.length > 256) { ws.close(1008, 'Too many pending commands'); return }
      const write = async () => {
        await persistCommand(session, line)
        if (!session.tcp?.writable) throw new Error('Haskell server unavailable')
        const acknowledged = new Promise((resolve, reject) => session.pendingAcks.push({ resolve, reject }))
        session.tcp.write(line + '\n')
        await acknowledged
      }
      forwardQueue = forwardQueue.then(write).catch((error) => {
        console.error(`Battleship bridge persistence/command: ${error.message}`)
        session.ws?.close(1011, 'Could not save match before sending command')
      })
    })
  }
  const nextReplayFrame = (session) => session.replayQueue.length
    ? Promise.resolve(session.replayQueue.shift())
    : new Promise((resolve, reject) => session.replayWaiters.push({ resolve, reject }))
  const openTcp = (session, restoring = false) => new Promise((resolve, reject) => {
    const tcp = net.createConnection({ host: config.tcpHost, port: config.tcpPort })
    session.tcp = tcp
    session.restoring = restoring
    sockets.add(tcp)
    let buffer = Buffer.alloc(0), welcomed = false, settled = false, cleaned = false
    const timer = setTimeout(() => tcp.destroy(new Error('TCP connect timeout')), 5000)
    timer.unref()
    tcp.on('connect', () => clearTimeout(timer))
    const fail = (error) => { if (!settled) { settled = true; reject(error) } }
    const cleanup = () => {
      if (cleaned) return
      cleaned = true
      clearTimeout(timer); clearTimeout(session.grace); sockets.delete(tcp)
      if (session.tcp === tcp) session.tcp = null
      for (const pending of session.pendingAcks ?? []) pending.reject(new Error('Haskell connection closed'))
      session.pendingAcks = []
      if (restoring) for (const pending of session.replayWaiters ?? []) pending.reject(new Error('Haskell connection closed during replay'))
      if (restoring) session.replayWaiters = []
      if (!config.sessionFile) session.ended = true
      // A failed restoration must leave the durable journal available for an
      // operator to restart Haskell and retry; it is not a player disconnect.
      if (!stopping && !restoring && sessions.has(session.tokenHash)) {
        session.grace = setTimeout(() => expire(session), RECONNECT_GRACE_MS)
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
          session.pendingAcks?.shift()?.resolve()
        }
        if (text.startsWith('GAME_OVER ')) session.pendingAcks?.shift()?.resolve()
        if (text.startsWith('WELCOME 1 ')) {
          session.player = text.slice(-2)
          if (session.tokenHash) sessions.set(session.tokenHash, session)
          welcomed = true
          if (session.restoring) {
            if (!settled) { settled = true; resolve() }
          } else {
            if (!settled) { settled = true; resolve() }
            if (session.token && session.tokenHash) {
              void persistSnapshot().catch((error) => session.ws?.close(1011, `Could not save session: ${error.message}`))
              send(session.ws, { type: 'SESSION', token: session.token, fleet: null, frames: null })
            }
          }
        }
        session.frames.push(text)
        if (session.frames.length > 4096) { tcp.destroy(new Error('Too many session frames')); return }
        if (session.restoring) {
          const waiter = session.replayWaiters.shift()
          if (waiter) waiter.resolve(text)
          else session.replayQueue.push(text)
        } else {
          if (text === 'OK PLACE') send(session.ws, { type: 'SESSION', token: session.token, fleet: session.fleet, frames: null })
          send(session.ws, text)
          if (text.startsWith('GAME_OVER ')) {
            session.ended = true
            if (config.sessionFile) void clearPersistentMatch().catch((error) => console.error(`Battleship session store: ${error.message}`))
          } else if (config.sessionFile) {
            void persistSnapshot().catch((error) => session.ws?.close(1011, `Could not save session: ${error.message}`))
          }
        }
        buffer = buffer.subarray(end + 1)
      }
      if (buffer.length > 257) tcp.destroy(new Error('Server line too long'))
    })
    tcp.on('end', () => {
      cleanup()
      if (!welcomed) fail(new Error('Haskell server closed before admitting a player slot'))
      else session.ws?.close(buffer.length ? 1011 : 1000, buffer.length ? 'Incomplete server frame' : 'Haskell server unavailable')
    })
    tcp.on('error', (error) => {
      console.error(`Battleship bridge TCP ${config.tcpHost}:${config.tcpPort}: ${error.code ?? error.message}`)
      cleanup(); fail(error); session.ws?.close(1011, 'Haskell server unavailable')
    })
    tcp.on('close', () => {
      cleanup()
      if (restoring && !welcomed) fail(new Error('Haskell server closed before restoring a player slot'))
      session.ws?.close()
    })
  })
  const restoreBackend = async () => {
    if (!config.sessionFile || !durable.sessions.length) return
    const ordered = [...sessions.values()].filter((session) => session.tokenHash).sort((a, b) => a.player.localeCompare(b.player))
    if (ordered.length !== durable.sessions.length) throw new Error('Saved player identities are incomplete')
    for (const session of ordered) {
      session.frames = []; session.commands = []; session.replayQueue = []; session.replayWaiters = []
      session.player = null; session.ended = false; session.deadline = null
      await openTcp(session, true)
      if (session.player !== (session.tokenHash && durable.sessions.find((saved) => saved.key === session.tokenHash)?.session.player))
        throw new Error('Restored player slot does not match saved identity')
    }
    // WELCOME arrives before any journaled command. Consume it so it cannot
    // be read as the response to the first PLACE/FIRE.
    for (const session of ordered) {
      const welcome = await nextReplayFrame(session)
      if (welcome !== `WELCOME 1 ${session.player}`)
        throw new Error(`Unexpected ${session.player} restore welcome: ${welcome}`)
    }
    for (const entry of durable.commands) {
      const actor = ordered.find((session) => session.player === entry.player)
      if (!actor?.tcp?.writable) throw new Error(`No restored TCP slot for ${entry.player}`)
      actor.commands.push(entry.line)
      actor.tcp.write(entry.line + '\n')
      const first = await nextReplayFrame(actor)
      const drain = async (session, count) => {
        for (let index = 0; index < count; index++) {
          await nextReplayFrame(session)
        }
      }
      if (first.startsWith('ERROR ')) continue
      if (first === 'OK PLACE') {
        if (actor.player === 'P1') await drain(actor, 1)
        else {
          const firstPlayer = ordered.find((session) => session.player === 'P1')
          await drain(firstPlayer, 2)
          await drain(actor, 2)
        }
      } else if (first.startsWith('SHOT ')) {
        const second = await nextReplayFrame(actor)
        if (!second.startsWith('TURN ') && !second.startsWith('GAME_OVER ')) throw new Error('Unexpected shot replay response')
        for (const session of ordered) if (session !== actor) await drain(session, 2)
      } else if (first.startsWith('GAME_OVER ')) {
        for (const session of ordered) if (session !== actor) await drain(session, 1)
      } else throw new Error(`Unexpected replay response: ${first}`)
    }
    const finished = ordered.some((session) => session.frames.some((frame) => frame.startsWith('GAME_OVER ')))
    for (const session of ordered) { session.restoring = false; session.ended = finished }
    if (finished) { matchEnded = true; durable.commands = [] }
    await persistSnapshot()
  }
  const ensureRestored = async () => {
    if (!config.sessionFile || !durable.sessions.length) return
    if (restorePromise) return restorePromise
    const links = [...sessions.values()].filter((session) => session.tcp?.writable).length
    if (links === sessions.size) return
    if (links > 0) throw new Error('A partial backend match is still connected; restart Haskell before restoring all saved players')
    restorePromise = restoreBackend().finally(() => { restorePromise = undefined })
    return restorePromise
  }
  // Ping detects a Wi-Fi loss even when the browser cannot send a close frame.
  const heartbeat = setInterval(() => {
    for (const ws of websocket.clients) {
      if (!ws.alive) ws.terminate()
      else { ws.alive = false; ws.ping() }
    }
  }, heartbeatMs)
  heartbeat.unref()
  websocket.on('connection', async (ws, request) => {
    const url = new URL(request.url, 'http://localhost')
    if (url.searchParams.has('resume')) {
      const token = url.searchParams.get('resume')
      const session = sessions.get(tokenKey(token))
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
      if (session.resuming) {
        send(ws, { type: 'RESUME_ERROR', code: 'SESSION_ACTIVE', message: 'Phiên đang được khôi phục; hãy thử lại sau.' })
        ws.close(1008, 'Session is restoring'); return
      }
      session.resuming = true
      clearTimeout(session.grace)
      session.deadline = null
      session.token = token
      try { await ensureRestored() }
      catch (error) {
        session.resuming = false
        console.error(`Battleship bridge restore: ${error.message}`)
        send(ws, { type: 'RESUME_ERROR', code: 'SERVER_UNAVAILABLE', message: 'Không thể khôi phục trận từ dữ liệu đã lưu.' })
        ws.close(1011, 'Could not restore match'); return
      }
      attach(session, ws)
      session.resuming = false
      send(ws, { type: 'SESSION', token, fleet: session.fleet, frames: session.frames })
      notify()
      if (session.ended) ws.close(1000, 'Match closed')
      return
    }
    if (matchEnded) {
      sessions.clear(); durable.commands = []; matchEnded = false
      try { await persistSnapshot() }
      catch (error) { send(ws, { type: 'RESUME_ERROR', code: 'SERVER_UNAVAILABLE', message: 'Không thể lưu trạng thái mới.' }); ws.close(1011); return }
    } else {
      try { await ensureRestored() }
      catch (error) {
        console.error(`Battleship bridge restore: ${error.message}`)
        send(ws, { type: 'RESUME_ERROR', code: 'SERVER_UNAVAILABLE', message: 'Không thể khôi phục trận từ dữ liệu đã lưu.' })
        ws.close(1011, 'Could not restore match'); return
      }
    }
    const token = randomBytes(32).toString('hex')
    const session = { tcp: null, token, tokenHash: tokenKey(token), ws: null, player: null, fleet: null,
      frames: [], commands: [], pendingAcks: [], replayQueue: [], replayWaiters: [], deadline: null, ended: false }
    attach(session, ws)
    try { await openTcp(session) }
    catch { ws.close(1011, 'Haskell server unavailable') }
  })
  return {
    server,
    playerOrigins,
    close: async () => {
      stopping = true
      clearInterval(heartbeat)
      clearInterval(lanMonitor)
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
  let config, bridge
  try {
    config = readBridgeConfig()
    if (config.autoLan && config.lanInterface && !networkInterfaces()[config.lanInterface])
      throw new Error(`LAN_INTERFACE does not exist or has no active address: ${config.lanInterface}`)
    bridge = createBridge(config)
  }
  catch (error) {
    console.error(`Battleship bridge configuration: ${error.message}`)
    process.exit(1)
  }
  bridge.server.on('error', (error) => { console.error(`Battleship bridge listen (${config.host}:${config.port}): ${error.message}`); process.exitCode = 1 })
  bridge.server.listen(config.port, config.host, () => {
    let previous
    const logAddresses = () => {
      const links = bridge.playerOrigins()
      const signature = links.join(',')
      if (signature === previous) return
      previous = signature
      console.log(`Battleship UI → TCP ${config.tcpHost}:${config.tcpPort}; reconnect grace: 5 minutes`)
      console.log(`Listening on ${config.host}:${config.port}.`)
      for (const address of links) console.log(`Open ${address} on each player device.`)
      if (!links.length) console.log(`No LAN IPv4 yet. Local UI: http://127.0.0.1:${config.publicPort ?? config.port}`)
    }
    logAddresses()
    bridge.server.on('originsChanged', logAddresses)
    if (config.autoLan) {
      const monitor = setInterval(logAddresses, 2000)
      monitor.unref()
      bridge.server.once('close', () => clearInterval(monitor))
    }
  })
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => void bridge.close())
}
