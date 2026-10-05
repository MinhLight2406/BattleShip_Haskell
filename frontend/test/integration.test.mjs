import { test } from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import { game, peer, within, listen, fleet1, fleet2, winningShots } from './helpers.mjs'

test('two browsers over bridge play real Haskell game; errors, private events, sinking and victory', async (t) => {
  const server = await game(t)
  const first = await peer(server.port)
  await first.wait('WELCOME 1 P1')
  first.send('PLACE CV=J10:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H')
  await first.wait('ERROR SHIP_OUT_OF_BOUNDS CV')
  first.send(fleet1); await first.wait('OK PLACE'); await first.wait('WAITING OPPONENT')
  first.send('FIRE A6'); await first.wait('ERROR FLEETS_NOT_READY')
  const second = await peer(server.port)
  await second.wait('WELCOME 1 P2')
  const third = await peer(server.port)
  await third.wait('ERROR SERVER_FULL'); await within(third.closed)
  assert.equal(third.frames.some((line) => line.startsWith('WELCOME')), false)
  second.send(fleet2)
  await second.wait('OK PLACE'); await first.wait('START P1'); await second.wait('START P1')
  await first.wait('TURN P1'); await second.wait('TURN P1')
  second.send('FIRE A1'); await second.wait('ERROR NOT_YOUR_TURN P1')
  first.send('FIRE K1'); await first.wait('ERROR INVALID_COORDINATE')
  first.send('FIRE J10'); await first.wait('SHOT J10 MISS'); await second.wait('INCOMING J10 MISS')
  await first.wait('TURN P2'); await second.wait('TURN P2')
  second.send('FIRE J10'); await second.wait('SHOT J10 MISS'); await first.wait('INCOMING J10 MISS')
  await first.wait('TURN P1'); await second.wait('TURN P1')
  first.send('FIRE J10'); await first.wait('ERROR ALREADY_FIRED J10')
  for (const [index, coord] of winningShots.entries()) {
    const outcome = index === 16 ? 'WIN' : ({ 4: 'SUNK CV', 8: 'SUNK BB', 11: 'SUNK CR', 14: 'SUNK SB' }[index] ?? 'HIT')
    first.send(`FIRE ${coord}`)
    await first.wait(`SHOT ${coord} ${outcome}`); await second.wait(`INCOMING ${coord} ${outcome}`)
    if (outcome !== 'WIN') { await first.wait('TURN P1'); await second.wait('TURN P1') }
  }
  await first.wait('GAME_OVER P1 ALL_SHIPS_SUNK'); await second.wait('GAME_OVER P1 ALL_SHIPS_SUNK')
  await within(first.closed); await within(second.closed)
  assert.deepEqual(await within(server.exited, 'server exit'), [0, null])
  assert.equal(first.frames.some((line) => line.includes('CV=A6')), false)
  assert.equal(second.frames.some((line) => line.startsWith('SHOT A6')), false)
  assert.equal(first.frames.some((line) => line.includes('SHIP_OUT_OF_BOUNDS CV')), true)
  const reuse = net.createServer()
  await new Promise((resolve, reject) => {
    reuse.once('error', reject); reuse.listen(server.tcpPort, '127.0.0.1', resolve)
  })
  await new Promise((resolve) => reuse.close(resolve))
})

for (const duringBattle of [false, true]) test(`WebSocket disconnect ${duringBattle ? 'mid-game' : 'while waiting'} gives opponent win after grace and clean exit`, async (t) => {
  const server = await game(t, { reconnectGraceMs: 150 })
  const first = await peer(server.port); await first.wait('WELCOME 1 P1')
  const second = await peer(server.port); await second.wait('WELCOME 1 P2')
  first.send(fleet1); await first.wait('OK PLACE'); await first.wait('WAITING OPPONENT')
  if (duringBattle) { second.send(fleet2); await second.wait('OK PLACE'); await first.wait('TURN P1') }
  second.ws.close()
  await first.wait('GAME_OVER P1 OPPONENT_LEFT')
  await within(first.closed); await within(second.closed)
  assert.deepEqual(await within(server.exited), [0, null])
})
