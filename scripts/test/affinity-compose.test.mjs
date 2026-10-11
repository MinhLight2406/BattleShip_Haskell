import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { once } from 'node:events'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import net from 'node:net'
import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { parseEnv, promisify } from 'node:util'
import { startAffinity } from '../start-affinity.mjs'

const root = fileURLToPath(new URL('../../', import.meta.url))
const execute = promisify(execFile)
const { WebSocket } = createRequire(new URL('../../frontend/package.json', import.meta.url))('ws')
const cli = process.env.BATTLESHIP_DOCKER_CLI ?? 'docker'
const docker = (...args) => execute(cli, args, { windowsHide: true, timeout: 30000, maxBuffer: 1024 * 1024 })
const fixtures = JSON.parse(await readFile(path.join(root, 'bench/fixtures-v1.json'), 'utf8'))
async function within(promise, label, ms = 10000) {
  let pending
  return Promise.race([promise, new Promise((_, reject) => { pending = setTimeout(() => reject(new Error(`${label}: deadline ${ms}ms`)), ms) })])
    .finally(() => clearTimeout(pending))
}
async function freePort() {
  const socket = net.createServer(); socket.listen(0, '127.0.0.1')
  await once(socket, 'listening'); const port = socket.address().port
  await new Promise(resolve => socket.close(resolve)); return port
}
async function client(port, token = '') {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/play${token ? '?resume=' + token : ''}`, { origin: `http://127.0.0.1:${port}` })
  const frames = [], queue = [], metadata = []
  let wake, ended = false
  const closed = once(ws, 'close')
  ws.on('message', data => {
    const text = data.toString()
    if (text.startsWith('{')) metadata.push(JSON.parse(text))
    else { frames.push(text); queue.push(text) }
    wake?.()
  })
  ws.on('close', () => { ended = true; wake?.() })
  await within(once(ws, 'open'), 'WS open')
  return { ws, closed, frames, metadata,
    async expect(frame) {
      await within((async () => {
        while (!queue.length) { assert.ok(!ended, `closed before ${frame}`); await new Promise(resolve => { wake = resolve }) }
        assert.equal(queue.shift(), frame)
      })(), frame)
    } }
}
async function fixture(t, performance) {
  const directory = path.join(root, '.stack-work/nm04', `case-${randomUUID()}`)
  await mkdir(path.join(directory, 'lan'), { recursive: true })
  const port = await freePort()
  const base = { ...parseEnv(await readFile(path.join(root, '.env.example'), 'utf8')),
    BATTLESHIP_GAME_CAPABILITY: performance.HASKELL_AFFINITY === 'rts' ? '1' : '0',
    WEB_PUBLIC_PORT: String(port), PUBLIC_ORIGIN: `http://127.0.0.1:${port}`, LAN_CONFIG_DIR: path.join(directory, 'lan').replaceAll('\\', '/') }
  const options = { action: 'start', envFile: path.join(directory, 'base.env'), performanceFile: path.join(directory, 'performance.env'),
    project: `battleship-affinity-${randomUUID()}`, docker: cli, build: false }
  await writeFile(options.envFile, Object.entries(base).map(([k, v]) => `${k}=${v}`).join('\n'))
  await writeFile(options.performanceFile, Object.entries(performance).map(([k, v]) => `${k}=${v}`).join('\n'))
  let started = false
  t.after(async () => { if (started) await startAffinity({ ...options, action: 'stop' }) })
  const evidence = await startAffinity(options); started = true
  const clients = []
  t.after(() => clients.forEach(c => c.ws.terminate()))
  return { directory, options, evidence, port, clients,
    async pair() {
      for (const player of ['P1', 'P2']) {
        const c = await client(port); clients.push(c); await c.expect(`WELCOME 1 ${player}`)
      }
      return [...clients]
    }, async start() { await startAffinity(options); started = true },
    async stop() { const begin = Date.now(); await startAffinity({ ...options, action: 'stop' }); started = false; return Date.now() - begin } }
}

for (const mode of ['container', 'rts']) test(`NM-04: ${mode} affinity, real port mapping and complete golden game`, async t => {
  const topology = await startAffinity({ action: 'inspect', docker: cli })
  const config = { HASKELL_CPUSET: mode === 'rts' ? '0,1' : String(topology.cpu.effective.at(-1)),
    WEB_CPUSET: 'auto', HASKELL_CAPABILITIES: mode === 'rts' ? '2' : '1', HASKELL_AFFINITY: mode }
  // Failing a required experiment is explicit; never silently skip it as green.
  const f = await fixture(t, config)
  const otherCpu = topology.cpu.effective.find(id => !f.evidence.config.web.includes(id))
  assert.notEqual(otherCpu, undefined, 'need a second CPU for actual mismatch experiment')
  await docker('update', '--cpuset-cpus', String(otherCpu), f.evidence.web.id)
  await assert.rejects(startAffinity({ ...f.options, action: 'verify' }), /CpusetCpus khác yêu cầu/)
  await docker('update', '--cpuset-cpus', f.evidence.config.web.join(','), f.evidence.web.id)
  await startAffinity({ ...f.options, action: 'verify' })
  for (let i = 0; i < 5; i++) assert.equal((await fetch(`http://127.0.0.1:${f.port}/healthz`, { signal: AbortSignal.timeout(3000) })).status, 200)
  const html = await fetch(`http://127.0.0.1:${f.port}`, { signal: AbortSignal.timeout(3000) }); assert.equal(html.status, 200); assert.match(await html.text(), /<html/)
  for (const headers of [{ Origin: `http://evil.example:${f.port}` },
    { Origin: `http://127.0.0.1:${f.port}`, Host: `evil.example:${f.port}` }]) {
    const status = await within(new Promise((resolve, reject) => {
      const ws = new WebSocket(`ws://127.0.0.1:${f.port}/play`, { headers })
      ws.on('unexpected-response', (_, response) => { const status = response.statusCode; response.resume(); ws.terminate(); resolve(status) })
      ws.on('error', () => {}); ws.on('open', () => { ws.terminate(); reject(new Error('bad origin/host admitted')) })
    }), 'origin/Host rejected')
    assert.equal(status, 401)
  }
  const pair = await f.pair()
  const third = await client(f.port); f.clients.push(third)
  await third.expect('ERROR SERVER_FULL'); await within(third.closed, 'third client closed')
  const workload = fixtures[mode === 'rts' ? 1 : 0]
  for (const entry of workload.commands) {
    pair[entry.actor === 'P1' ? 0 : 1].ws.send(entry.command)
    await Promise.all(pair.map(async (c, index) => { for (const response of entry.responses[index ? 'P2' : 'P1']) await c.expect(response) }))
    if (entry.command === workload.commands[5].command && entry === workload.commands[5]) {
      await startAffinity({ ...f.options, action: 'verify' })
    }
  }
  for (const c of pair) await within(c.closed, 'full game closed')
  for (const [index, c] of pair.entries()) {
    assert.deepEqual(c.frames, [`WELCOME 1 P${index + 1}`, ...workload.commands.flatMap(e => e.responses[index ? 'P2' : 'P1'])])
    for (const metadata of c.metadata) {
      if (metadata.type === 'SESSION' && metadata.fleet) assert.equal(metadata.fleet,
        workload.commands.find(e => e.actor === `P${index + 1}` && e.command.startsWith('PLACE ')).command)
    }
  }
  const stopMs = await f.stop(); assert.ok(stopMs < 10000, `cleanup ${stopMs}ms`)
  assert.equal((await docker('ps', '-a', '--filter', `label=com.docker.compose.project=${f.options.project}`, '--quiet')).stdout.trim(), '')
  const listener = net.createServer(); listener.listen(f.port, '127.0.0.1'); await once(listener, 'listening'); await new Promise(resolve => listener.close(resolve))
  await writeFile(path.join(f.directory, 'acceptance.json'), JSON.stringify({ mode, topology,
    evidence: f.evidence, seed: workload.seed, commands: workload.commandCount, frames: pair.map(c => c.frames),
    actualMismatchRejected: true, badOriginHostStatus: 401, healthChecks: 5, stopMs, removed: true }, null, 2))
})

test('NM-04: SIGTERM during an active two-player session closes peers and permits a new game', async t => {
  const config = { HASKELL_CPUSET: 'auto', WEB_CPUSET: 'auto', HASKELL_CAPABILITIES: '1', HASKELL_AFFINITY: 'container' }
  const f = await fixture(t, config)
  const pair = await f.pair()
  const stopMs = await f.stop()
  assert.ok(stopMs < 10000); for (const c of pair) await within(c.closed, 'shutdown WS')
  await f.start()
  const first = await client(f.port); f.clients.push(first); await first.expect('WELCOME 1 P1')
  await f.stop()
  await writeFile(path.join(f.directory, 'acceptance.json'), JSON.stringify({ mode: 'shutdown-restart', stopMs,
    closedPeers: 2, newWelcome: 'WELCOME 1 P1', evidence: f.evidence }, null, 2))
})
