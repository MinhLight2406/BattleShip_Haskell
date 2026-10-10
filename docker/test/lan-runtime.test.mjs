import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { once } from 'node:events'
import { mkdirSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { before, test } from 'node:test'
import { promisify } from 'node:util'
import { peer, within, fleet1, fleet2 } from '../../frontend/test/helpers.mjs'
import { adapter, hostFixture, helperEnv, quote, runPS, script, until } from '../../frontend/test/lan-helper-support.mjs'

const { WebSocket } = createRequire(new URL('../../frontend/package.json', import.meta.url))('ws')
const execute = promisify(execFile)
const cli = process.env.BATTLESHIP_DOCKER_CLI ?? 'docker'
const webImage = process.env.BATTLESHIP_WEB_IMAGE ?? 'battleship-web:dk05'
const coreImage = process.env.BATTLESHIP_HASKELL_IMAGE ?? 'battleship-haskell:dk04'
const docker = (...args) => execute(cli, args, { env: helperEnv(), windowsHide: true, timeout: 30000, maxBuffer: 1024 * 1024 })
before(async () => {
  assert.equal(process.platform, 'win32', 'DK-06 must test the producer on the Windows host')
  assert.equal((await docker('info', '--format', '{{.OSType}}')).stdout.trim(), 'linux')
  for (const name of [webImage, coreImage]) await docker('image', 'inspect', name)
})
const health = name => until(async () => {
  const state = JSON.parse((await docker('inspect', '--format', '{{json .State}}', name)).stdout)
  if (!state.Running) throw new Error(`container stopped: ${(await docker('logs', name)).stderr}`)
  return state.Health.Status === 'healthy'
}, 'container readiness', 20000)

test('DK-06: generated env is accepted by real Compose with spaces/apostrophe and read-only directory mount', async (t) => {
  const fixture = hostFixture(t)
  const directory = path.join(fixture.directory, "LAN space'quote")
  mkdirSync(directory)
  await runPS(`. ${quote(script)}; $s = Get-LanSettings ${quote(fixture.directory)} @{ConfigDir=${quote(directory)}} @{}; Write-LanComposeEnv $s; Write-LanOrigins $s.OriginPath @()`)
  const compose = path.join(fixture.directory, 'fixture-compose.json')
  writeFileSync(compose, JSON.stringify({ services: { web: { image: webImage,
    environment: { PUBLIC_ORIGIN: '${PUBLIC_ORIGIN}', LAN_ORIGINS_FILE: '${LAN_ORIGINS_FILE}', WEB_PUBLIC_PORT: '${WEB_PUBLIC_PORT}' },
    ports: ['${WEB_PUBLIC_PORT}:8080'],
    volumes: [{ type: 'bind', source: '${LAN_CONFIG_DIR}', target: '/run/battleship-lan', read_only: true }],
  } } }))
  const config = JSON.parse((await docker('compose', '--project-directory', fixture.directory, '--env-file', path.join(directory, 'compose.env'),
    '-f', compose, '-p', 'dk06-env-test', 'config', '--format', 'json')).stdout).services.web
  assert.equal(config.environment.PUBLIC_ORIGIN, '')
  assert.equal(config.environment.LAN_ORIGINS_FILE, '/run/battleship-lan/origins.json')
  assert.equal(config.ports[0].published, '8081')
  assert.equal(path.resolve(config.volumes[0].source), directory)
  assert.equal(config.volumes[0].read_only, true)
})

test('DK-06: Windows atomic file updates cross a read-only Docker mount without restarting web/core or losing P1', async (t) => {
  const id = randomUUID(), network = `battleship-dk06-${id}`
  const containers = []
  let networkCreated = false
  t.after(async () => {
    for (const name of containers.reverse()) await docker('rm', '--force', name)
    if (networkCreated) await docker('network', 'rm', network)
  })
  const fixture = hostFixture(t)
  const watcher = await fixture.start()
  await docker('network', 'create', network); networkCreated = true
  const core = `battleship-dk06-core-${id}`, web = `battleship-dk06-web-${id}`
  await docker('create', '--name', core, '--network', network, '--network-alias', 'haskell', coreImage)
  containers.push(core); await docker('start', core); await health(core)
  await docker('create', '--name', web, '--network', network, '--publish', '127.0.0.1::8080',
    '--mount', `type=bind,source=${fixture.lan},target=/run/battleship-lan,readonly`,
    '--env', 'PUBLIC_ORIGIN=', '--env', 'LAN_ORIGINS_FILE=/run/battleship-lan/origins.json', webImage)
  containers.push(web); await docker('start', web); await health(web)
  const port = Number((await docker('port', web, '8080/tcp')).stdout.trim().split(':').at(-1))
  const inspect = async name => JSON.parse((await docker('inspect', name)).stdout)[0]
  const original = { core: (await inspect(core)).State.StartedAt, web: (await inspect(web)).State.StartedAt }
  assert.equal((await inspect(web)).Mounts.find(mount => mount.Destination === '/run/battleship-lan').RW, false)
  const options = ip => ({ origin: `http://${ip}:8081`, headers: { Host: `${ip}:8081` } })
  const connect = (ip, token = '') => peer(port, '127.0.0.1', token, options(ip))
  const probe = async ip => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/play?resume=invalid`, options(ip))
    ws.on('error', () => {})
    return within(new Promise((resolve, reject) => {
      ws.once('unexpected-response', (_request, response) => { ws.terminate(); resolve(response.statusCode) })
      ws.once('message', bytes => { ws.close(); try { assert.equal(JSON.parse(bytes).type, 'RESUME_ERROR'); resolve(200) } catch (error) { reject(error) } })
    }), 'origin handshake')
  }
  const first = await connect('192.168.10.20'); await first.wait('WELCOME 1 P1')
  const { token } = await first.meta('SESSION')
  const second = await connect('192.168.10.20'); await second.wait('WELCOME 1 P2')
  first.send(fleet1); await first.wait('OK PLACE'); await first.wait('WAITING OPPONENT')
  fixture.replace([adapter('192.168.20.30')])
  await until(async () => await probe('192.168.20.30') === 200, 'new origin allowlist')
  assert.equal(await probe('192.168.10.20'), 401)
  assert.equal(first.ws.readyState, WebSocket.OPEN)
  second.send(fleet2); await second.wait('OK PLACE')
  for (const client of [first, second]) { await client.wait('START P1'); await client.wait('TURN P1') }
  first.ws.close(); await within(first.closed)
  const pause = await second.meta('CONNECTION')
  assert.ok(Math.abs(pause.missing[0].deadline - Date.now() - 300000) < 1000)
  fixture.replace([adapter('192.168.30.40')])
  await until(async () => await probe('192.168.30.40') === 200, 'origin update during reconnect grace')
  await watcher.stop()
  writeFileSync(fixture.filename, '{')
  await until(async () => await probe('192.168.30.40') === 401, 'reject unfinished JSON')
  assert.equal(await probe('evil.example'), 401)
  assert.equal(second.ws.readyState, WebSocket.OPEN)
  const response = await fetch(`http://127.0.0.1:${port}/healthz`, { signal: AbortSignal.timeout(5000) })
  assert.equal(response.status, 200)
  await fixture.write(['http://192.168.30.40:8081'])
  await until(async () => await probe('192.168.30.40') === 200, 'valid file recovery')
  second.send('FIRE A1'); assert.deepEqual(await second.meta('CONNECTION'), pause)
  const restored = await connect('192.168.30.40', token)
  const replay = await restored.meta('SESSION')
  assert.equal(replay.token, token); assert.equal(replay.fleet, fleet1)
  assert.ok(replay.frames.includes('WELCOME 1 P1'))
  assert.equal(JSON.stringify(replay).includes('CV=A6'), false)
  assert.equal((await inspect(core)).State.StartedAt, original.core)
  assert.equal((await inspect(web)).State.StartedAt, original.web)
  restored.send('QUIT')
  for (const client of [restored, second]) { await client.wait('GAME_OVER P2 OPPONENT_LEFT'); await within(client.closed) }
  assert.equal((await within(docker('wait', core))).stdout.trim(), '0')
  t.diagnostic('Real Windows producer -> read-only directory mount -> web -> real Haskell; simulated adapter IP changes, no hardware Wi-Fi switch.')
})
