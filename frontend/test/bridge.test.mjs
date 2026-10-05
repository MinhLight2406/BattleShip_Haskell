import { test } from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import { once } from 'node:events'
import { WebSocket } from 'ws'
import { createBridge, readBridgeConfig, lanAddresses, RECONNECT_GRACE_MS } from '../bridge.mjs'
import { peer, listen, within } from './helpers.mjs'

async function fixture(t) {
  let tcp
  const server = net.createServer((socket) => { tcp = socket })
  const tcpPort = await listen(server)
  const bridge = createBridge({ tcpPort, reconnectGraceMs: 0 })
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
  assert.deepEqual(readBridgeConfig({}), { host: '0.0.0.0', port: 8080, tcpPort: 4000, publicOrigin: undefined, autoLan: true, lanInterface: undefined })
  assert.equal(RECONNECT_GRACE_MS, 300000)
  assert.equal(readBridgeConfig({ HOST: 'localhost' }).host, '127.0.0.1')
  for (const host of ['192.168.1.10', '0.0.0.0']) {
    assert.deepEqual(readBridgeConfig({ HOST: host, PORT: '8081', PUBLIC_ORIGIN: 'http://192.168.1.10:8081/' }), {
      host, port: 8081, tcpPort: 4000, publicOrigin: 'http://192.168.1.10:8081', autoLan: false, lanInterface: undefined,
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
  for (const name of ['PORT', 'BATTLESHIP_TCP_PORT']) {
    for (const value of ['0', '-1', '65536', '1.5', '0x1f90', '8e3', '', ' 8080', '08080', 'abc'])
      assert.throws(() => readBridgeConfig({ [name]: value }), new RegExp(name))
  }
  for (const host of ['', '192.168.1.999', 'machine name', '::1'])
    assert.throws(() => readBridgeConfig({ ...lan, HOST: host }), /HOST/)
  assert.throws(() => readBridgeConfig({ HOST: '0.0.0.0' }), /PUBLIC_ORIGIN is required/)
  for (const origin of ['', 'not a url', 'https://192.168.1.10:8080', 'http://192.168.1.10:8080/play',
    'http://192.168.1.10:8080/foo/..', 'http://192.168.1.10:8080/?x=1', 'http://192.168.1.10:8080/#x', 'http://user:password@192.168.1.10:8080',
    'http://0.0.0.0:8080', 'http://255.255.255.255:8080', 'http://localhost:8080', 'http://192.168.1.10:9090'])
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
