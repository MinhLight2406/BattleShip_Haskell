// Test-only TCP peers inside web's network; host releases reads only after Haskell exits.
import assert from 'node:assert/strict'
import net from 'node:net'
import { EventEmitter } from 'node:events'
import { existsSync, writeFileSync } from 'node:fs'
import { setTimeout as delay } from 'node:timers/promises'

const peers = []
const deadline = setTimeout(() => {
  console.error('nonreading TCP fixture exceeded 12 seconds')
  process.exitCode = 1
  for (const peer of peers) peer.socket.destroy()
}, 12000)
async function connect(player) {
  const socket = net.createConnection({ host: process.env.BATTLESHIP_TCP_HOST, port: Number(process.env.BATTLESHIP_TCP_PORT), highWaterMark: 1 })
  const changed = new EventEmitter(), frames = []
  let pending = '', closed = false
  socket.on('error', () => {})
  socket.on('data', chunk => {
    pending += chunk.toString('ascii')
    let newline
    while ((newline = pending.indexOf('\n')) >= 0) { frames.push(pending.slice(0, newline)); pending = pending.slice(newline + 1) }
    changed.emit('change')
  })
  const ended = new Promise(resolve => socket.once('close', () => { closed = true; changed.emit('change'); resolve() }))
  const peer = { socket, frames, ended, async wait(frame) {
    while (!frames.includes(frame)) {
      assert.equal(closed, false, `closed before ${frame}`)
      await new Promise(resolve => changed.once('change', resolve))
    }
  } }
  peers.push(peer); await peer.wait(`WELCOME 1 P${player}`)
  return peer
}
try {
  const first = await connect(1), second = await connect(2)
  const actor = Number(process.argv[2]) // 0 means both; 1/2 leaves the opposite peer reading.
  assert.ok([0, 1, 2].includes(actor))
  const slow = actor === 0 ? peers : [peers[actor - 1]]
  for (const peer of slow) peer.socket.pause()
  for (const peer of slow) peer.socket.write('UNKNOWN\n'.repeat(50000))
  writeFileSync('/tmp/dk08-nonreaders-ready', 'flooded\n')
  if (actor) await peers[2 - actor].wait(`GAME_OVER P${3 - actor} OPPONENT_LEFT`)
  while (!existsSync('/run/battleship-lan/release-nonreaders')) await delay(25)
  for (const peer of slow) peer.socket.resume()
  await Promise.all([first.ended, second.ended])
  console.log(JSON.stringify({ players: ['P1', 'P2'], slow: actor || 'both', winner: actor ? `P${3 - actor}` : null, socketsClosed: 2 }))
} finally {
  clearTimeout(deadline)
  for (const peer of peers) peer.socket.destroy()
}
