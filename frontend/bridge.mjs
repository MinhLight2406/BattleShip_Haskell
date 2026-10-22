import http from 'node:http'
import net from 'node:net'
import { readFile } from 'node:fs/promises'
import { openSync, readSync, closeSync, fstatSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { networkInterfaces } from 'node:os'
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { WebSocketServer, WebSocket } from 'ws'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), 'dist')
const mime = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' }

export const RECONNECT_GRACE_MS = 5 * 60 * 1000
export const ROOM_WAIT_MS = 5 * 60 * 1000
const ROOM_BODY_LIMIT = 8192
const ROOM_CAPACITY = 2
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
  if (lanOriginsFile && (!path.isAbsolute(lanOriginsFile) || lanOriginsFile.includes('\0')))
    throw new Error('LAN_ORIGINS_FILE must be an absolute file path')
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
  return { host, port, tcpHost, tcpPort, publicPort, publicOrigin, autoLan, lanOriginsFile, lanInterface: env.LAN_INTERFACE || undefined }
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

async function readJsonBody(request) {
  const chunks = []
  let size = 0
  for await (const chunk of request) {
    size += chunk.length
    if (size > ROOM_BODY_LIMIT) throw Object.assign(new Error('Nội dung yêu cầu quá lớn.'), { status: 413 })
    chunks.push(chunk)
  }
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'))
    if (!value || Array.isArray(value) || typeof value !== 'object') throw new Error()
    return value
  } catch { throw Object.assign(new Error('Dữ liệu yêu cầu không hợp lệ.'), { status: 400 }) }
}

function validRoomText(value, min, max) {
  return typeof value === 'string' && value.trim().length >= min && [...value.trim()].length <= max &&
    !/[\u0000-\u001f\u007f]/.test(value)
}

function passwordDigest(salt, password) {
  return createHash('sha256').update(salt).update(password, 'utf8').digest()
}

// One resumable browser session = one TCP player. Haskell owns every game rule.
export function createBridge({ tcpHost = '127.0.0.1', tcpPort = 4000, devOrigin = 'http://127.0.0.1:5173', host = '127.0.0.1', port = 8080,
  publicPort, publicOrigin, lanOriginsFile, autoLan = false, lanInterface, reconnectGraceMs = RECONNECT_GRACE_MS,
  roomWaitMs = ROOM_WAIT_MS, heartbeatMs = 10000,
  addresses = () => lanAddresses(networkInterfaces(), lanInterface) } = {}) {
  const config = readBridgeConfig({ HOST: autoLan ? undefined : host, PORT: String(port),
    BATTLESHIP_TCP_HOST: tcpHost, BATTLESHIP_TCP_PORT: String(tcpPort), PUBLIC_ORIGIN: publicOrigin,
    WEB_PUBLIC_PORT: publicPort === undefined ? undefined : String(publicPort), LAN_ORIGINS_FILE: lanOriginsFile })
  let lanOrigins = config.lanOriginsFile ? readLanOriginsFile(config.lanOriginsFile, config.publicPort ?? config.port) : []
  const sessions = new Map()
  const roomsById = new Map()
  const roomsByName = new Map()
  const roomTickets = new Map()
  let stopping = false
  const forgetRoom = (room) => {
    clearTimeout(room.expiry)
    roomsById.delete(room.id)
    roomsByName.delete(room.nameKey)
    for (const player of room.players) roomTickets.delete(player.ticket)
  }
  const issueRoomTicket = (room, seat, displayName) => {
    const ticket = randomBytes(32).toString('hex')
    roomTickets.set(ticket, { room, seat, displayName, used: false })
    return ticket
  }
  const respondJson = (response, status, value) => {
    response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' })
    response.end(JSON.stringify(value))
  }
  const apiError = (status, message) => Object.assign(new Error(message), { status })
  const validateRoomInput = (body, joining = false) => {
    if (body.displayName !== undefined && !validRoomText(body.displayName, 1, 24))
      throw apiError(400, 'Tên người chơi cần từ 1 đến 24 ký tự.')
    if (!validRoomText(body.password, 1, 128)) throw apiError(400, 'Mật khẩu phòng cần từ 1 đến 128 ký tự.')
    if (!validRoomText(joining ? body.room : body.roomName, 1, 48))
      throw apiError(400, joining ? 'Nhập tên hoặc ID phòng.' : 'Tên phòng cần từ 1 đến 48 ký tự.')
  }
  const createRoom = (body) => {
    validateRoomInput(body)
    const roomName = body.roomName.trim().normalize('NFC')
    const nameKey = roomName.toLocaleLowerCase('vi')
    const existing = roomsByName.get(nameKey)
    if (existing?.status === 'waiting' && Date.now() >= existing.expiresAt) {
      existing.status = 'expired'
      forgetRoom(existing)
    }
    if (roomsByName.has(nameKey)) throw apiError(409, 'Tên phòng đang được sử dụng.')
    let id
    do { id = randomBytes(12).toString('hex').toUpperCase() } while (roomsById.has(id))
    const salt = randomBytes(16)
    const room = {
      id, name: roomName, nameKey, salt, passwordHash: passwordDigest(salt, body.password),
      players: [], status: 'waiting', createdAt: Date.now(), expiresAt: Date.now() + roomWaitMs,
      sessions: new Set(), expiry: undefined,
    }
    const displayName = (body.displayName ?? 'Player1').trim().normalize('NFC')
    const player = { seat: 'P1', displayName, ticket: '' }
    player.ticket = issueRoomTicket(room, player.seat, displayName)
    room.players.push(player)
    room.expiry = setTimeout(() => {
      if (room.status !== 'waiting') return
      room.status = 'expired'
      forgetRoom(room)
      for (const session of room.sessions) expire(session)
    }, Math.max(1, roomWaitMs))
    room.expiry.unref?.()
    roomsById.set(id, room)
    roomsByName.set(nameKey, room)
    return { roomId: id, roomName, seat: 'P1', displayName, ticket: player.ticket, expiresAt: room.expiresAt }
  }
  const joinRoom = (body) => {
    validateRoomInput(body, true)
    const lookup = body.room.trim().normalize('NFC')
    const room = roomsById.get(lookup.toUpperCase()) ?? roomsByName.get(lookup.toLocaleLowerCase('vi'))
    if (!room || room.status !== 'waiting' || Date.now() >= room.expiresAt) {
      if (room?.status === 'waiting') { room.status = 'expired'; forgetRoom(room) }
      throw apiError(404, 'Không tìm thấy phòng đang chờ.')
    }
    const actual = passwordDigest(room.salt, body.password)
    if (!timingSafeEqual(actual, room.passwordHash)) throw apiError(403, 'Mật khẩu phòng không đúng.')
    if (room.players.length >= ROOM_CAPACITY) throw apiError(409, 'Phòng đã đủ người.')
    const displayName = (body.displayName ?? 'Player2').trim().normalize('NFC')
    const player = { seat: 'P2', displayName, ticket: '' }
    player.ticket = issueRoomTicket(room, player.seat, displayName)
    room.players.push(player)
    room.status = 'paired'
    room.expiresAt = null
    clearTimeout(room.expiry)
    room.expiry = undefined
    notifyRoom(room)
    return { roomId: room.id, roomName: room.name, seat: 'P2', displayName, opponentName: room.players[0].displayName, ticket: player.ticket, expiresAt: null }
  }
  const server = http.createServer(async (request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname)
      if (pathname === '/healthz') {
        if (request.method !== 'GET') { response.writeHead(405, { Allow: 'GET' }).end(); return }
        response.writeHead(200, { 'Content-Type': 'application/json' }).end('{"status":"ok"}')
        return
      }
      if (pathname === '/api/rooms/create' || pathname === '/api/rooms/join') {
        if (request.method !== 'POST') { response.writeHead(405, { Allow: 'POST' }).end(); return }
        if (!/^application\/json(?:\s*;|$)/i.test(request.headers['content-type'] ?? '')) {
          respondJson(response, 415, { error: 'Gửi thông tin phòng dưới dạng JSON.' }); return
        }
        try {
          const body = await readJsonBody(request)
          const result = pathname.endsWith('/create') ? createRoom(body) : joinRoom(body)
          respondJson(response, 201, result)
        } catch (error) {
          respondJson(response, error.status ?? 400, { error: error.message ?? 'Yêu cầu không hợp lệ.' })
        }
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
  const connectionState = () => ({ type: 'CONNECTION', missing: [...sessions.values()]
    .filter((session) => session.deadline && !session.ended)
    .map(({ player, deadline }) => ({ player, deadline })) })
  const roomState = (session) => session.room ? ({
    type: 'ROOM_SESSION', roomId: session.room.id, roomName: session.room.name,
    seat: session.roomSeat, displayName: session.displayName,
    opponentName: session.room.players.find((player) => player.seat !== session.roomSeat)?.displayName ?? null,
  }) : null
  const notifyRoom = (room) => {
    for (const session of room.sessions) {
      if (session.ws) send(session.ws, roomState(session))
    }
  }
  const notify = () => { for (const session of sessions.values()) send(session.ws, connectionState()) }
  const expire = (session) => {
    if (session.ended) return
    session.ended = true
    clearTimeout(session.grace)
    // Only Haskell decides the winner. Expiry is exactly the existing Quit command.
    if (session.room && !session.roomHandshakeSent) { session.tcp.destroy(); return }
    if (session.tcp.writable) session.tcp.end('QUIT\n')
    else session.tcp.destroy()
  }
  const rejectRoomTicket = (ws, message) => {
    send(ws, { type: 'ROOM_ERROR', message })
    ws.close(1008, 'Invalid room ticket')
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
      if (roomState(session)) send(ws, roomState(session))
      notify()
      if (session.ended) ws.close(1000, 'Match closed')
      return
    }
    let roomTicket
    if (url.searchParams.has('ticket')) {
      const value = url.searchParams.get('ticket')
      roomTicket = roomTickets.get(value)
      if (!roomTicket || roomTicket.used || roomTicket.room.status === 'expired' || roomTicket.room.status === 'finished' ||
          (roomTicket.room.status === 'waiting' && Date.now() >= roomTicket.room.expiresAt)) {
        rejectRoomTicket(ws, 'Vé vào phòng không hợp lệ hoặc đã hết hạn.')
        return
      }
      roomTicket.used = true
    }
    const tcp = net.createConnection({ host: config.tcpHost, port: config.tcpPort })
    sockets.add(tcp)
    const token = randomBytes(32).toString('hex')
    const session = {
      tcp, token, ws: null, player: null, fleet: null, frames: [], commands: [], deadline: null, ended: false,
      room: roomTicket?.room ?? null, roomSeat: roomTicket?.seat ?? null, displayName: roomTicket?.displayName ?? null,
      roomHandshakeSent: false,
    }
    session.room?.sessions.add(session)
    attach(session, ws)
    let buffer = Buffer.alloc(0)
    const timer = setTimeout(() => tcp.destroy(new Error('TCP connect timeout')), 5000)
    timer.unref()
    tcp.on('connect', () => {
      clearTimeout(timer)
      if (session.room) {
        if (session.ended || session.room.status === 'expired') { tcp.destroy(); return }
        session.roomHandshakeSent = true
        tcp.write(`ROOM ${session.room.id} ${session.roomSeat}\n`)
      }
    })
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
          if (session.room && session.player !== session.roomSeat) {
            tcp.destroy(new Error('Room seat assignment did not match the ticket'))
            return
          }
          sessions.set(token, session)
          send(session.ws, { type: 'SESSION', token, fleet: null, frames: null })
          if (roomState(session)) notifyRoom(session.room)
        }
        session.frames.push(text)
        if (session.frames.length > 4096) { tcp.destroy(new Error('Too many session frames')); return }
        if (text === 'OK PLACE') send(session.ws, { type: 'SESSION', token, fleet: session.fleet, frames: null })
        if (text.startsWith('GAME_OVER ')) {
          if (session.room) {
            session.room.status = 'finished'
            forgetRoom(session.room)
          }
        }
        send(session.ws, text)
        buffer = buffer.subarray(end + 1)
      }
      if (buffer.length > 257) tcp.destroy(new Error('Server line too long'))
    })
    tcp.on('end', () => { cleanup(); session.ws?.close(buffer.length ? 1011 : 1000, buffer.length ? 'Incomplete server frame' : 'Match closed') })
    tcp.on('error', (error) => {
      console.error(`Battleship bridge TCP ${config.tcpHost}:${config.tcpPort}: ${error.code ?? error.message}`)
      cleanup(); session.ws?.close(1011, 'Haskell server unavailable')
    })
    tcp.on('close', () => { cleanup(); session.ws?.close() })
  })
  return {
    server,
    playerOrigins,
    close: async () => {
      stopping = true
      clearInterval(heartbeat)
      clearInterval(lanMonitor)
      for (const room of roomsById.values()) clearTimeout(room.expiry)
      roomsById.clear(); roomsByName.clear(); roomTickets.clear()
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
