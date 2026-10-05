import { test } from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import { once } from 'node:events'
import { WebSocket } from 'ws'
import { createBridge } from '../bridge.mjs'
import { peer, listen, within } from './helpers.mjs'

async function fixture(t) {
  let tcp
  const server = net.createServer((socket) => { tcp = socket })
  const tcpPort = await listen(server)
  const bridge = createBridge({ tcpPort })
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
