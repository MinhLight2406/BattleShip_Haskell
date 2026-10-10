import { test } from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import { once } from 'node:events'
import { mkdtempSync, rmSync, writeFileSync, renameSync, unlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { WebSocket } from 'ws'
import { createBridge, readBridgeConfig, parseLanOrigins, lanAddresses, RECONNECT_GRACE_MS } from '../bridge.mjs'
import { peer, listen, within } from './helpers.mjs'

async function fixture(t, options = {}) {
  let tcp
  const server = net.createServer((socket) => { tcp = socket })
  const tcpPort = await listen(server)
  const bridge = createBridge({ tcpPort, reconnectGraceMs: 0, ...options })
  const port = await listen(bridge.server)
  t.after(async () => {
    await bridge.close(); tcp?.destroy()
    await new Promise((resolve) => server.close(resolve))
  })
  const accepted = once(server, 'connection')
  const client = await peer(port)
  const [socket] = await within(accepted)
  return { client, socket, port }
}

test('bridge reassembles fragmented TCP/CRLF frames and adds one LF to commands', async (t) => {
  const { client, socket } = await fixture(t)
  socket.write('WEL')
  socket.write('COME 1 P1\r\nOK PLACE\nTURN P1\n')
  await client.wait('WELCOME 1 P1'); await client.wait('OK PLACE'); await client.wait('TURN P1')
  const received = once(socket, 'data')
  client.send('FIRE J10')
  assert.equal((await within(received))[0].toString(), 'FIRE J10\n')
  socket.end('SHOT J10 WIN\nGAME_OVER P1 ALL_SHIPS_SUNK\n')
  await client.wait('GAME_OVER P1 ALL_SHIPS_SUNK')
  assert.equal((await within(client.closed))[0], 1000)
})

test('bridge rejects newline injection without reaching TCP; closes binary/oversize commands', async (t) => {
  const { client, socket } = await fixture(t)
  let forwarded = ''
  socket.on('data', (bytes) => { forwarded += bytes })
  client.send('FIRE A1\nQUIT')
  await client.wait('ERROR INVALID_COMMAND')
  assert.equal(forwarded, '')
  client.ws.send(Buffer.from('QUIT'))
  assert.equal((await within(client.closed))[0], 1003)
})
test('maxPayload rejects more than 256 bytes', async (t) => {
  const { client } = await fixture(t)
  client.ws.on('error', () => {})
  client.send('X'.repeat(257))
  assert.equal((await within(client.closed))[0], 1009)
})
test('browser departure closes its TCP socket instead of leaving a ghost player', async (t) => {
  const { client, socket } = await fixture(t)
  const closed = once(socket, 'close')
  client.ws.close()
  await within(closed)
})
test('cross-origin browser cannot acquire a player slot', async (t) => {
  const bridge = createBridge({ tcpPort: 1 })
  const port = await listen(bridge.server)
  t.after(() => bridge.close())
  const ws = new WebSocket(`ws://127.0.0.1:${port}/play`, { origin: 'https://untrusted.example' })
  ws.on('error', () => {})
  const [, response] = await within(once(ws, 'unexpected-response'))
  assert.equal(response.statusCode, 401)
  ws.terminate()
})
test('HTTP serves built UI/hero and reports nonexistent assets clearly', async (t) => {
  const bridge = createBridge()
  const port = await listen(bridge.server)
  t.after(() => bridge.close())
  const response = await fetch(`http://127.0.0.1:${port}/`)
  assert.equal(response.status, 200)
  assert.match(await response.text(), /lang="vi"/)
  assert.equal((await fetch(`http://127.0.0.1:${port}/no-such-file`)).status, 404)
})

test('automatic LAN is the CLI default; explicit localhost and LAN binding still work', () => {
  assert.deepEqual(readBridgeConfig({}), { host: '0.0.0.0', port: 8080, tcpHost: '127.0.0.1', tcpPort: 4000,
    publicPort: undefined, publicOrigin: undefined, autoLan: true, lanOriginsFile: undefined, lanInterface: undefined })
  assert.equal(RECONNECT_GRACE_MS, 300000)
  assert.equal(readBridgeConfig({ HOST: 'localhost' }).host, '127.0.0.1')
  for (const host of ['192.168.1.10', '0.0.0.0']) {
    assert.deepEqual(readBridgeConfig({ HOST: host, PORT: '8081', PUBLIC_ORIGIN: 'http://192.168.1.10:8081/' }), {
      host, port: 8081, tcpHost: '127.0.0.1', tcpPort: 4000, publicPort: undefined,
      publicOrigin: 'http://192.168.1.10:8081', autoLan: false, lanOriginsFile: undefined, lanInterface: undefined,
    })
  }
  assert.equal(readBridgeConfig({ PUBLIC_ORIGIN: 'http://localhost:8080' }).publicOrigin, 'http://localhost:8080')
  assert.equal(readBridgeConfig({ HOST: '0.0.0.0', PORT: '80', PUBLIC_ORIGIN: 'http://192.168.1.10:80' }).publicOrigin, 'http://192.168.1.10')
})

test('LAN discovery ignores loopback/link-local/IPv6, deduplicates and supports interface selection', () => {
  const interfaces = {
    loopback: [{ family: 'IPv4', internal: true, address: '127.0.0.1' }],
    wifi: [{ family: 'IPv4', internal: false, address: '192.168.0.25' }, { family: 'IPv6', internal: false, address: 'fe80::1' }],
    ethernet: [{ family: 4, internal: false, address: '192.168.0.25' }, { family: 'IPv4', internal: false, address: '169.254.1.1' }],
    invalid: [{ family: 4, internal: false, address: '0.0.0.0' }, { family: 4, internal: false, address: '255.255.255.255' }],
  }
  assert.deepEqual(lanAddresses(interfaces), ['192.168.0.25'])
  assert.deepEqual(lanAddresses(interfaces, 'wifi'), ['192.168.0.25'])
  assert.deepEqual(lanAddresses({}), [])
  assert.deepEqual(lanAddresses(interfaces, 'missing'), [], 'an adapter disappearing during Wi-Fi change must not crash')
})

test('automatic origins follow the current interface IP, rejecting stale IP and mismatched Host', async (t) => {
  let ips = ['192.168.0.25']
  const bridge = createBridge({ autoLan: true, addresses: () => ips, tcpPort: 1 })
  const port = await listen(bridge.server)
  t.after(() => bridge.close())
  const request = async (ip, accepted, host = `${ip}:${port}`) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/play?resume=invalid`, {
      origin: `http://${ip}:${port}`, headers: { Host: host },
    })
    ws.on('error', () => {})
    if (accepted) {
      const [data] = await within(once(ws, 'message'))
      assert.equal(JSON.parse(data).type, 'RESUME_ERROR')
    } else {
      const [, response] = await within(once(ws, 'unexpected-response'))
      assert.equal(response.statusCode, 401)
    }
    ws.terminate()
  }
  await request('192.168.0.25', true)
  ips = ['192.168.1.126']
  await request('192.168.0.25', false)
  await request('192.168.1.126', true)
  await request('192.168.1.126', false, 'untrusted.example')
})

test('LAN-01: invalid configuration is rejected before any listener is opened', () => {
  const lan = { HOST: '0.0.0.0', PUBLIC_ORIGIN: 'http://192.168.1.10:8080' }
  for (const name of ['PORT', 'BATTLESHIP_TCP_PORT', 'WEB_PUBLIC_PORT']) {
    for (const value of ['0', '-1', '65536', '1.5', '0x1f90', '8e3', '', ' 8080', '08080', 'abc'])
      assert.throws(() => readBridgeConfig({ [name]: value }), new RegExp(name))
  }
  for (const host of ['', '192.168.1.999', 'machine name', '::1'])
    assert.throws(() => readBridgeConfig({ ...lan, HOST: host }), /HOST/)
  assert.throws(() => readBridgeConfig({ HOST: '0.0.0.0' }), /PUBLIC_ORIGIN is required/)
  for (const origin of ['', 'not a url', 'https://192.168.1.10:8080', 'http://192.168.1.10:8080/play',
    'http://192.168.1.10:8080/foo/..', 'http://192.168.1.10:8080/?x=1', 'http://192.168.1.10:8080/#x', 'http://user:password@192.168.1.10:8080',
    'http://0.0.0.0:8080', 'http://255.255.255.255:8080', 'http://192.168.1.10:9090'])
    assert.throws(() => readBridgeConfig({ ...lan, PUBLIC_ORIGIN: origin }), /PUBLIC_ORIGIN/)
  assert.throws(() => readBridgeConfig({ PUBLIC_ORIGIN: lan.PUBLIC_ORIGIN }), /PUBLIC_ORIGIN address/)
  assert.throws(() => readBridgeConfig({ HOST: '192.168.1.11', PUBLIC_ORIGIN: lan.PUBLIC_ORIGIN }), /PUBLIC_ORIGIN address/)
})

test('LAN-01: an allowed Origin with a different Host is rejected', async (t) => {
  const bridge = createBridge({ tcpPort: 1 })
  const port = await listen(bridge.server)
  t.after(() => bridge.close())
  const ws = new WebSocket(`ws://127.0.0.1:${port}/play`, {
    origin: `http://127.0.0.1:${port}`, headers: { Host: `localhost:${port}` },
  })
  ws.on('error', () => {})
  const [, response] = await within(once(ws, 'unexpected-response'))
  assert.equal(response.statusCode, 401)
  ws.terminate()
})

test('DK-03: TCP host accepts native IPv4/DNS and rejects URL, port and malformed names', () => {
  assert.equal(readBridgeConfig({}).tcpHost, '127.0.0.1')
  for (const host of ['127.0.0.1', '192.168.1.126', 'localhost', 'haskell', 'game-server.example'])
    assert.equal(readBridgeConfig({ BATTLESHIP_TCP_HOST: host }).tcpHost, host)
  for (const host of ['', 'http://haskell', 'haskell:4000', 'a b', ' haskell', 'haskell\n', '::1',
    '-haskell', 'haskell-', 'a..b', 'a_b', '127.1', '127.00.0.1', '256.1.1.1', 'a'.repeat(64), `${'a.'.repeat(127)}b`])
    assert.throws(() => readBridgeConfig({ BATTLESHIP_TCP_HOST: host }), /BATTLESHIP_TCP_HOST/)
})

test('DK-03: separates PORT 8080/public 8081 and permits wildcard bind with localhost', () => {
  const env = { HOST: '0.0.0.0', PORT: '8080', WEB_PUBLIC_PORT: '8081', PUBLIC_ORIGIN: 'http://localhost:8081' }
  const config = readBridgeConfig(env)
  assert.equal(config.port, 8080); assert.equal(config.publicPort, 8081)
  assert.equal(config.autoLan, false); assert.equal(config.publicOrigin, 'http://localhost:8081')
  assert.equal(readBridgeConfig({ HOST: '0.0.0.0', PUBLIC_ORIGIN: 'http://localhost:8080' }).publicOrigin, 'http://localhost:8080')
  assert.throws(() => readBridgeConfig({ ...env, PUBLIC_ORIGIN: 'http://localhost:8080' }), /WEB_PUBLIC_PORT/)
  assert.throws(() => readBridgeConfig({ WEB_PUBLIC_PORT: '8081' }), /PUBLIC_ORIGIN or LAN_ORIGINS_FILE/)
  assert.equal(readBridgeConfig({ PUBLIC_ORIGIN: '', LAN_ORIGINS_FILE: '', LAN_INTERFACE: '' }).autoLan, true)
  for (const origin of ['http://127.1:8081', 'http://0x7f000001:8081', 'http://2130706433:8081', 'http://127.0.0.1:08081'])
    assert.throws(() => readBridgeConfig({ ...env, PUBLIC_ORIGIN: origin }), /PUBLIC_ORIGIN/)
  for (const filename of ['origins.json', 'bad\0path'])
    assert.throws(() => readBridgeConfig({ ...env, PUBLIC_ORIGIN: '', LAN_ORIGINS_FILE: filename }), /LAN_ORIGINS_FILE/)
  assert.throws(() => readBridgeConfig({ ...env, LAN_ORIGINS_FILE: path.join(tmpdir(), 'origins.json') }), /mutually exclusive/)
})

test('DK-03: connects to service haskell using its DNS name and preserves framing', async (t) => {
  const connect = net.createConnection
  let resolved = false
  t.mock.method(net, 'createConnection', (...args) => {
    if (args[0]?.host !== 'haskell') return connect(...args)
    return connect({ ...args[0], autoSelectFamily: false, lookup: (host, _options, callback) => {
      assert.equal(host, 'haskell'); resolved = true
      queueMicrotask(() => callback(null, '127.0.0.1', 4))
    } })
  })
  const { client, socket } = await fixture(t, { tcpHost: 'haskell' })
  assert.equal(resolved, true)
  socket.write('WELCOME 1 P1\n')
  await client.wait('WELCOME 1 P1')
  const received = once(socket, 'data')
  client.send('QUIT')
  assert.equal((await within(received))[0].toString(), 'QUIT\n')
})

async function rejectedUpgrade(port, origin, host) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/play`, { origin, headers: { Host: host } })
  ws.on('error', () => {})
  try {
    const [, response] = await within(once(ws, 'unexpected-response'), 'rejected upgrade')
    assert.ok([400, 401].includes(response.statusCode))
  } finally { ws.terminate() }
}

test('DK-03: published authority is exact, internal/Vite/unconfigured origins cannot open TCP', async (t) => {
  const backend = net.createServer((socket) => socket.destroy())
  const tcpPort = await listen(backend)
  let accepted = 0
  backend.on('connection', () => accepted++)
  const bridge = createBridge({ tcpPort, host: '0.0.0.0', publicPort: 8081, publicOrigin: 'http://localhost:8081' })
  const internal = await listen(bridge.server)
  t.after(async () => { await bridge.close(); await new Promise((resolve) => backend.close(resolve)) })
  for (const [origin, host] of [
    ['http://localhost:8081', 'untrusted.example:8081'],
    ['http://localhost:8081', '127.0.0.1:8081'],
    ['http://localhost:8081', 'localhost:8081/'],
    ['http://localhost:8081', `localhost:${internal}`],
    [`http://localhost:${internal}`, `localhost:${internal}`],
    ['http://192.168.1.99:8081', '192.168.1.99:8081'],
    ['http://127.0.0.1:5173', '127.0.0.1:5173'],
    ['null', 'localhost:8081'], [undefined, 'localhost:8081'],
    ['http://localhost:8081', ['localhost:8081', 'untrusted.example:8081']],
    ['http://localhost:8081,http://evil.example', 'localhost:8081'],
  ]) await rejectedUpgrade(internal, origin, host)
  assert.equal(accepted, 0)
})

test('DK-03: HTTP port 80 normalizes Host authority without weakening Origin checks', async (t) => {
  const bridge = createBridge({ host: '0.0.0.0', publicPort: 80, publicOrigin: 'http://localhost' })
  const port = await listen(bridge.server)
  t.after(() => bridge.close())
  for (const host of ['localhost', 'localhost:80']) {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/play?resume=invalid`, { origin: 'http://localhost', headers: { Host: host } })
    ws.on('error', () => {})
    assert.equal(JSON.parse((await within(once(ws, 'message')))[0]).type, 'RESUME_ERROR')
    ws.terminate()
  }
  await rejectedUpgrade(port, 'http://localhost', 'localhost:81')
  await rejectedUpgrade(port, 'http://localhost', 'localhost/')
  await rejectedUpgrade(port, 'http://localhost', 'localhost:80/')
})

test('DK-03: health probes never allocate TCP/session/player slots', async (t) => {
  const backend = net.createServer((socket) => { socket.write('WELCOME 1 P1\n'); t.after(() => socket.destroy()) })
  const tcpPort = await listen(backend)
  let accepted = 0
  backend.on('connection', () => accepted++)
  const bridge = createBridge({ tcpPort })
  const port = await listen(bridge.server)
  t.after(async () => { await bridge.close(); await new Promise((resolve) => backend.close(resolve)) })
  for (let count = 0; count < 100; count++) {
    const response = await fetch(`http://127.0.0.1:${port}/healthz`)
    assert.equal(response.status, 200); assert.deepEqual(await response.json(), { status: 'ok' })
  }
  for (const method of ['HEAD', 'POST', 'OPTIONS'])
    assert.equal((await fetch(`http://127.0.0.1:${port}/healthz`, { method })).status, 405)
  assert.equal(accepted, 0)
  const client = await peer(port); await client.wait('WELCOME 1 P1')
  assert.equal(accepted, 1)
})

for (const dnsFailure of [false, true]) test(`DK-03: ${dnsFailure ? 'DNS failure' : 'connection refused'} closes WS cleanly and leaves bridge usable`, async (t) => {
  const backend = net.createServer((socket) => { socket.write('WELCOME 1 P1\n'); t.after(() => socket.destroy()) })
  const tcpPort = await listen(backend)
  await new Promise((resolve) => backend.close(resolve))
  const errors = []
  t.mock.method(console, 'error', (message) => errors.push(message))
  const connect = net.createConnection
  if (dnsFailure) t.mock.method(net, 'createConnection', (...args) => {
    if (args[0]?.host !== 'missing.invalid') return connect(...args)
    return connect({ ...args[0], autoSelectFamily: false, lookup: (_host, _options, callback) => {
      queueMicrotask(() => callback(Object.assign(new Error('test DNS failure'), { code: 'ENOTFOUND' })))
    } })
  })
  const bridge = createBridge({ tcpPort, tcpHost: dnsFailure ? 'missing.invalid' : '127.0.0.1' })
  const port = await listen(bridge.server)
  t.after(async () => { await bridge.close(); if (backend.listening) await new Promise((resolve) => backend.close(resolve)) })
  for (let attempt = 0; attempt < 2; attempt++) {
    const client = await peer(port)
    const [code, reason] = await within(client.closed)
    assert.equal(code, 1011); assert.equal(reason.toString(), 'Haskell server unavailable')
    assert.equal(client.frames.length, 0, 'no usable resume token before WELCOME')
    assert.equal((await fetch(`http://127.0.0.1:${port}/healthz`)).status, 200)
  }
  assert.equal(errors.length, 2)
  assert.ok(errors.every((message) => message.includes(`TCP ${dnsFailure ? 'missing.invalid' : '127.0.0.1'}:${tcpPort}`) &&
    message.includes(dnsFailure ? 'ENOTFOUND' : 'ECONNREFUSED')))
  if (!dnsFailure) {
    backend.listen(tcpPort, '127.0.0.1'); await within(once(backend, 'listening'))
    const client = await peer(port); await client.wait('WELCOME 1 P1')
  }
})

function originFile(t, origins = ['http://192.168.1.10:8081']) {
  const directory = mkdtempSync(path.join(tmpdir(), 'battleship-dk03-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const filename = path.join(directory, 'origins.json')
  const replace = (values = origins, updatedAt = Date.now()) => {
    writeFileSync(filename + '.tmp', JSON.stringify({ version: 1, updatedAt, origins: values }))
    renameSync(filename + '.tmp', filename)
  }
  replace()
  return { filename, replace }
}

test('DK-03: LAN file schema, canonical origins, byte limit and freshness boundaries are strict', () => {
  const now = 100000
  const valid = { version: 1, updatedAt: now, origins: ['http://192.168.1.10:8081'] }
  const parse = (data) => parseLanOrigins(Buffer.from(JSON.stringify(data)), 8081, now)
  assert.deepEqual(parse(valid), valid.origins)
  assert.deepEqual(parse({ ...valid, origins: [...valid.origins, ...valid.origins] }), valid.origins)
  assert.deepEqual(parse({ ...valid, origins: [] }), [])
  for (const age of [-2000, 9999]) assert.deepEqual(parse({ ...valid, updatedAt: now - age }), valid.origins)
  for (const age of [-2001, 10000]) assert.throws(() => parse({ ...valid, updatedAt: now - age }), /timestamp|stale/)
  for (const data of [null, [], 1, { ...valid, version: 2 }, { ...valid, updatedAt: -1 }, { ...valid, updatedAt: 1.5 },
    { ...valid, updatedAt: Number.MAX_SAFE_INTEGER + 1 }, { ...valid, extra: 1 }, { version: 1, origins: [] },
    { ...valid, origins: 'wrong' }, { ...valid, origins: Array(17).fill(valid.origins[0]) }])
    assert.throws(() => parse(data), /schema/)
  for (const origin of ['http://localhost:8081', 'http://127.0.0.1:8081', 'http://169.254.1.1:8081',
    'http://0.0.0.0:8081', 'http://255.255.255.255:8081', 'http://192.168.1.10:8080',
    'http://192.168.1.10:8081/', 'http://192.168.1.10:8081/a', 'http://192.168.1.10:8081?x=1', 7])
    assert.throws(() => parse({ ...valid, origins: [origin] }), /origin/)
  assert.throws(() => parseLanOrigins(Buffer.alloc(8193), 8081, now), /8 KiB/)
  const json = Buffer.from(JSON.stringify(valid))
  assert.deepEqual(parseLanOrigins(Buffer.concat([json, Buffer.alloc(8192 - json.length, 32)]), 8081, now), valid.origins)
  for (const bytes of [Buffer.from('{'), Buffer.from('\ufeff' + JSON.stringify(valid)), Buffer.from([0xff])])
    assert.throws(() => parseLanOrigins(bytes, 8081, now), /UTF-8 JSON/)
})

test('DK-03: invalid LAN file fails before bridge creation; a fresh empty file permits localhost', async (t) => {
  const { filename } = originFile(t, [])
  const options = { host: '0.0.0.0', publicPort: 8081, lanOriginsFile: filename }
  const bridge = createBridge(options)
  const port = await listen(bridge.server)
  t.after(() => bridge.close())
  assert.deepEqual(bridge.playerOrigins(), [])
  const ws = new WebSocket(`ws://127.0.0.1:${port}/play?resume=invalid`, { origin: 'http://localhost:8081', headers: { Host: 'localhost:8081' } })
  assert.equal(JSON.parse((await within(once(ws, 'message')))[0]).type, 'RESUME_ERROR')
  ws.terminate()
  writeFileSync(filename, 'broken')
  assert.throws(() => createBridge(options), /LAN_ORIGINS_FILE/)
  unlinkSync(filename)
  assert.throws(() => createBridge(options), /ENOENT/)
})

test('DK-03: hot LAN replacements, errors, expiration and recovery update the exact allowlist without restart', async (t) => {
  t.mock.timers.enable({ apis: ['Date', 'setInterval'], now: Date.now() })
  t.mock.method(console, 'error', () => {})
  const { filename, replace } = originFile(t)
  const bridge = createBridge({ host: '0.0.0.0', publicPort: 8081, lanOriginsFile: filename })
  const port = await listen(bridge.server)
  t.after(() => bridge.close())
  const allowed = async (ip) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/play?resume=invalid`, { origin: `http://${ip}:8081`, headers: { Host: `${ip}:8081` } })
    assert.equal(JSON.parse((await within(once(ws, 'message')))[0]).type, 'RESUME_ERROR')
    ws.terminate()
  }
  await allowed('192.168.1.10')
  replace(['http://192.168.2.20:8081']); t.mock.timers.tick(2000)
  await rejectedUpgrade(port, 'http://192.168.1.10:8081', '192.168.1.10:8081')
  await allowed('192.168.2.20')
  for (const spoil of [() => writeFileSync(filename, 'broken'), () => writeFileSync(filename, 'X'.repeat(8193)), () => unlinkSync(filename)]) {
    spoil(); t.mock.timers.tick(2000)
    assert.deepEqual(bridge.playerOrigins(), [])
    await rejectedUpgrade(port, 'http://192.168.2.20:8081', '192.168.2.20:8081')
    assert.equal((await fetch(`http://127.0.0.1:${port}/healthz`)).status, 200)
    replace(['http://192.168.2.20:8081']); t.mock.timers.tick(2000)
    await allowed('192.168.2.20')
  }
  t.mock.timers.tick(8000)
  assert.deepEqual(bridge.playerOrigins(), [], '10-second freshness expiry removes old LAN origins')
  replace(); t.mock.timers.tick(2000)
  await allowed('192.168.1.10')
})
