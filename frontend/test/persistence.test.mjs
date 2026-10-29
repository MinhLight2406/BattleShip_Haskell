import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import net from 'node:net'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { createBridge } from '../bridge.mjs'
import { fleet1, fleet2, listen, peer, within } from './helpers.mjs'

async function startHaskell() {
  const child = spawn(process.env.BATTLESHIP_SERVER ?? 'battleship-server', ['0'], { windowsHide: true })
  let output = ''
  child.stderr.on('data', (data) => { output += data })
  const port = await within(new Promise((resolve, reject) => {
    child.on('error', reject)
    child.stdout.on('data', (data) => {
      output += data
      const match = output.match(/listening on 127\.0\.0\.1:(\d+)/)
      if (match) resolve(Number(match[1]))
    })
    child.once('exit', (code) => reject(new Error(`server exited ${code}: ${output}`)))
  }), 'Haskell start')
  return {
    child,
    async stop() {
      if (child.exitCode !== null || child.signalCode !== null) return
      const exited = once(child, 'exit')
      child.kill()
      await within(exited, 'Haskell shutdown')
    },
  }
}

async function startBridge(tcpPort, sessionFile) {
  const bridge = createBridge({ tcpPort, sessionFile })
  const port = await listen(bridge.server)
  return { bridge, port }
}

test('web journal restores the same P1/P2, turn and private history after Haskell and bridge restart', async (t) => {
  const directory = mkdtempSync(path.join(tmpdir(), 'battleship-persistence-'))
  const sessionFile = path.join(directory, 'sessions.json')
  let server, bridge
  const sockets = []
  t.after(async () => {
    for (const client of sockets) client.ws.terminate()
    await bridge?.close()
    await server?.stop()
    rmSync(directory, { recursive: true, force: true })
  })

  server = await startHaskell()
  let port
  ;({ bridge, port } = await startBridge(server.port, sessionFile))
  const first = await peer(port), second = await peer(port)
  sockets.push(first, second)
  const firstCode = (await first.meta('SESSION')).token
  const secondCode = (await second.meta('SESSION')).token
  first.send(fleet1); await first.wait('OK PLACE')
  second.send(fleet2); await second.wait('OK PLACE')
  await first.wait('START P1'); await first.wait('TURN P1')
  first.send('FIRE J10')
  await first.wait('SHOT J10 MISS'); await first.wait('TURN P2')
  await second.wait('INCOMING J10 MISS'); await second.wait('TURN P2')

  const oldServer = server, oldBridge = bridge
  server = undefined; bridge = undefined
  await oldServer.stop()
  await oldBridge.close()
  server = await startHaskell()
  ;({ bridge, port } = await startBridge(server.port, sessionFile))

  const resumedFirst = await peer(port, '127.0.0.1', firstCode)
  const restoredFirst = await resumedFirst.meta('SESSION')
  assert.ok(restoredFirst.frames.includes('WELCOME 1 P1'))
  assert.ok(restoredFirst.frames.includes('OK PLACE'))
  assert.ok(restoredFirst.frames.includes('SHOT J10 MISS'))
  assert.ok(restoredFirst.frames.includes('TURN P2'))
  assert.equal(restoredFirst.fleet, fleet1)

  const resumedSecond = await peer(port, '127.0.0.1', secondCode)
  const restoredSecond = await resumedSecond.meta('SESSION')
  assert.ok(restoredSecond.frames.includes('WELCOME 1 P2'))
  assert.ok(restoredSecond.frames.includes('INCOMING J10 MISS'))
  assert.ok(restoredSecond.frames.includes('TURN P2'))
  assert.equal(restoredSecond.fleet, fleet2)
  sockets.push(resumedFirst, resumedSecond)

  resumedSecond.send('FIRE A1')
  await resumedSecond.wait('SHOT A1 HIT')
  await resumedSecond.wait('TURN P2')
  await resumedFirst.wait('INCOMING A1 HIT')

  const journal = JSON.parse(readFileSync(sessionFile, 'utf8'))
  assert.deepEqual(journal.commands.map(({ player, line }) => `${player}:${line}`), [
    `P1:${fleet1}`, `P2:${fleet2}`, 'P1:FIRE J10', 'P2:FIRE A1',
  ])
})
