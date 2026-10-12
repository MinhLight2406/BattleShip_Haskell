import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { once } from 'node:events'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import net from 'node:net'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { parseEnv, promisify } from 'node:util'
import { peer, within } from '../../frontend/test/helpers.mjs'
import { startNuma, canRemote } from '../start-numa.mjs'

const root = fileURLToPath(new URL('../../', import.meta.url)), execute = promisify(execFile)
const cli = process.env.BATTLESHIP_DOCKER_CLI ?? 'docker'
const docker = (...args) => execute(cli, args, { windowsHide: true, timeout: 30000, maxBuffer: 1024 * 1024 })
const examples = parseEnv(await readFile(path.join(root, '.env.numa.example'), 'utf8'))
const workloads = JSON.parse(await readFile(path.join(root, 'bench/fixtures-v1.json'), 'utf8'))

async function fixture(t, profile, extra = {}) {
  const dir = path.join(root, '.stack-work/nm07', `case-${profile}-${randomUUID()}`)
  await mkdir(path.join(dir, 'lan'), { recursive: true })
  const listener = net.createServer(); listener.listen(0, '127.0.0.1'); await once(listener, 'listening')
  const port = listener.address().port; await new Promise(resolve => listener.close(resolve))
  const base = { ...parseEnv(await readFile(path.join(root, '.env.example'), 'utf8')), WEB_PUBLIC_PORT: String(port),
    PUBLIC_ORIGIN: `http://127.0.0.1:${port}`, LAN_CONFIG_DIR: path.join(dir, 'lan').replaceAll('\\', '/') }
  const options = { action: 'start', envFile: path.join(dir, 'base.env'), numaFile: path.join(dir, 'numa.env'),
    project: `battleship-numa-${randomUUID()}`, docker: cli, build: false }
  const save = (file, object) => writeFile(file, Object.entries(object).map(([k, v]) => `${k}=${v}`).join('\n'))
  await save(options.envFile, base); await save(options.numaFile, { ...examples, NUMA_PROFILE: profile, ...extra })
  let active = false
  const peers = []
  t.after(async () => { peers.forEach(p => p.ws.terminate()); if (active) await startNuma({ ...options, action: 'stop' }) })
  return { options, port, dir, peers,
    async start() { const result = await startNuma(options); active = true; return result },
    async stop() { const begin = Date.now(); await startNuma({ ...options, action: 'stop' }); active = false; return Date.now() - begin },
    async pair() { for (const id of ['P1', 'P2']) { const p = await peer(port); peers.push(p); await p.wait(`WELCOME 1 ${id}`) }; return peers.slice(-2) } }
}

for (const [profile, extra] of [['default', {}], ['local', {}], ['local', { NUMA_MEMORY_POLICY: 'membind', NUMA_SYS_NICE: '1' }], ['remote', {}]]) test(`NM-07 ${profile} ${extra.NUMA_MEMORY_POLICY ?? 'cpuset'}: placement, readiness, privacy, complete game and cleanup`, async t => {
  const topology = await startNuma({ action: 'inspect', docker: cli })
  if (profile === 'remote' && !canRemote(topology)) {
    t.skip('Chưa nghiệm thu remote: Linux chỉ cung cấp một node CPU/RAM được phép.'); return
  }
  const f = await fixture(t, profile, extra), evidence = await f.start()
  assert.equal(evidence.haskell.healthy, 'healthy')
  assert.equal((await fetch(`http://127.0.0.1:${f.port}`, { signal: AbortSignal.timeout(3000) })).status, 200)
  for (let i = 0; i < 5; i++) assert.equal((await fetch(`http://127.0.0.1:${f.port}/healthz`, { signal: AbortSignal.timeout(3000) })).status, 200)
  const pair = await f.pair(), third = await peer(f.port); f.peers.push(third)
  await third.wait('ERROR SERVER_FULL'); await within(third.closed, 'third closed')
  const workload = workloads[0]
  for (const entry of workload.commands) {
    pair[entry.actor === 'P1' ? 0 : 1].send(entry.command)
    await Promise.all(pair.map(async (p, index) => { for (const frame of entry.responses[index ? 'P2' : 'P1']) await p.wait(frame) }))
    if (entry === workload.commands[5]) await startNuma({ ...f.options, action: 'verify' })
  }
  for (const p of pair) await within(p.closed, 'game ended')
  const frames = pair.map(p => p.frames.filter(frame => !frame.startsWith('{')))
  for (let i = 0; i < 2; i++) assert.deepEqual(frames[i], [`WELCOME 1 P${i + 1}`, ...workload.commands.flatMap(e => e.responses[i ? 'P2' : 'P1'])])
  const stopMs = await f.stop(); assert.ok(stopMs < 10000)
  assert.equal((await docker('ps', '-a', '--filter', `label=com.docker.compose.project=${f.options.project}`, '--quiet')).stdout.trim(), '')
  const checkPort = net.createServer(); checkPort.listen(f.port, '127.0.0.1'); await once(checkPort, 'listening'); await new Promise(resolve => checkPort.close(resolve))
  await writeFile(path.join(f.dir, 'acceptance.json'), JSON.stringify({ profile, evidence, frames, seed: workload.seed, stopMs, removed: true }, null, 2))
})

test('NM-07 wrapper is PID 1, SIGTERM closes active peers and restart creates fresh P1', async t => {
  const f = await fixture(t, 'local', { NUMA_MEMORY_POLICY: 'membind', NUMA_SYS_NICE: '1' }), evidence = await f.start(), pair = await f.pair()
  const exe = (await docker('exec', evidence.haskell.id, 'readlink', '/proc/1/exe')).stdout.trim()
  assert.equal(exe, '/usr/local/bin/battleship-server')
  const stopMs = await f.stop(); assert.ok(stopMs < 10000)
  for (const p of pair) await within(p.closed, 'SIGTERM closes peer')
  await f.start(); const first = await peer(f.port); f.peers.push(first); await first.wait('WELCOME 1 P1'); await f.stop()
  await writeFile(path.join(f.dir, 'acceptance.json'), JSON.stringify({ profile: 'shutdown-restart', stopMs, closedPeers: 2, freshPlayer: 'P1', pid1Executable: exe }, null, 2))
})

test('NM-07 numactl failure never starts the requested program; no fallback', async () => {
  const script = 'mkdir /tmp/stub; printf "#!/bin/sh\\nexit 77\\n" > /tmp/stub/numactl; chmod +x /tmp/stub/numactl; export PATH=/tmp/stub:$PATH; exec /usr/local/bin/battleship-numa-entrypoint sh -c "echo SERVER_STARTED"'
  await assert.rejects(docker('run', '--rm', '--network', 'none', '-e', 'BATTLESHIP_NUMA_POLICY=membind', '-e', 'BATTLESHIP_NUMA_MEMS=0',
    '--entrypoint', 'sh', 'battleship-haskell:local', '-ec', script), error => error.code === 77 && !error.stdout.includes('SERVER_STARTED'))
})

test('NM-07 GHC NUMA is separately verified or explicitly unaccepted when permission/kernel is missing', async t => {
  const f = await fixture(t, 'ghc', { NUMA_SYS_NICE: '1' })
  try {
    const evidence = await f.start(); assert.ok(evidence.placement.memory.boundPrivatePages > 0)
    await f.stop(); await writeFile(path.join(f.dir, 'acceptance.json'), JSON.stringify({ profile: 'ghc', verified: true, evidence }, null, 2))
  } catch (error) {
    const detail = error.message + '\n' + (error.stderr ?? '')
    if (!/Operation not permitted|Permission denied|not supported|not available|compiled without NUMA support|policy bị từ chối/i.test(detail)) throw error
    await writeFile(path.join(f.dir, 'acceptance.json'), JSON.stringify({ profile: 'ghc', verified: false, reason: detail }, null, 2))
    t.skip(`Chưa nghiệm thu GHC NUMA: ${detail.slice(-500)}`)
  }
})
