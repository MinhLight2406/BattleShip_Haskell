import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { WebSocket } from 'ws'
import { createBridge } from '../bridge.mjs'

export const within = (promise, label = 'operation', ms = 10000) => {
  let timer
  return Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label} timed out`)), ms) })])
    .finally(() => clearTimeout(timer))
}
export async function listen(server) {
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  return server.address().port
}
export async function peer(port, host = '127.0.0.1', token = '', options = {}) {
  const ws = new WebSocket(`ws://${host}:${port}/play${token ? '?resume=' + token : ''}`, { origin: `http://${host}:${port}`, ...options })
  const frames = [], queue = [], waiters = []
  const closed = once(ws, 'close')
  ws.on('message', (bytes) => {
    frames.push(bytes.toString()); queue.push(bytes.toString())
    for (const wake of waiters.splice(0)) wake()
  })
  ws.on('close', () => { for (const wake of waiters.splice(0)) wake() })
  await within(once(ws, 'open'), 'websocket open')
  return {
    ws, frames, closed,
    async wait(frame) {
      await within((async () => {
        while (!queue.includes(frame)) {
          if (ws.readyState === WebSocket.CLOSED) throw new Error(`closed waiting for ${frame}: ${frames.join(', ')}`)
          await new Promise((resolve) => waiters.push(resolve))
        }
        queue.splice(queue.indexOf(frame), 1)
      })(), frame)
    },
    async meta(type) {
      let result
      await within((async () => {
        while (!result) {
          const index = queue.findIndex((line) => line.startsWith('{') && JSON.parse(line).type === type)
          if (index >= 0) { result = JSON.parse(queue.splice(index, 1)[0]); return }
          if (ws.readyState === WebSocket.CLOSED) throw new Error(`closed waiting for ${type}`)
          await new Promise((resolve) => waiters.push(resolve))
        }
      })(), type)
      return result
    },
    send(line) { ws.send(line) },
  }
}

export async function game(t, bridgeOptions = {}) {
  const child = spawn(process.env.BATTLESHIP_SERVER ?? 'battleship-server', ['0'], { windowsHide: true })
  let output = ''
  child.stderr.on('data', (data) => { output += data })
  const exited = once(child, 'exit')
  const tcpPort = await within(new Promise((resolve, reject) => {
    child.on('error', reject)
    child.stdout.on('data', (data) => {
      output += data
      const match = output.match(/listening on 127\.0\.0\.1:(\d+)/)
      if (match) resolve(Number(match[1]))
    })
    child.once('exit', (code) => reject(new Error(`server exited ${code}: ${output}`)))
  }), 'Haskell start')
  const bridge = createBridge({ tcpPort, ...bridgeOptions })
  const port = await listen(bridge.server)
  t.after(async () => {
    await bridge.close()
    if (child.exitCode === null) child.kill()
    await within(exited, 'server cleanup')
  })
  return { port, tcpPort, exited, child, bridge, output: () => output }
}

export const fleet1 = 'PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H'
export const fleet2 = 'PLACE CV=A6:H;BB=A7:H;CR=A8:H;SB=A9:H;DD=A10:H'
export const winningShots = ['A6', 'B6', 'C6', 'D6', 'E6', 'A7', 'B7', 'C7', 'D7', 'A8', 'B8', 'C8', 'A9', 'B9', 'C9', 'A10', 'B10']
