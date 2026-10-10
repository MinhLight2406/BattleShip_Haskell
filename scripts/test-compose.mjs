import assert from 'node:assert/strict'
import { execFile, spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { once } from 'node:events'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import net from 'node:net'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { parseEnv, promisify } from 'node:util'
import { peer, within, fleet1, fleet2 } from '../frontend/test/helpers.mjs'
import { helperEnv, shell, script, until } from '../frontend/test/lan-helper-support.mjs'

const root = fileURLToPath(new URL('../', import.meta.url))
const composeFile = path.join(root, 'compose.yaml')
const example = parseEnv(readFileSync(path.join(root, '.env.example'), 'utf8'))
const cli = process.env.BATTLESHIP_DOCKER_CLI ?? 'docker'
const execute = promisify(execFile)
const docker = (...args) => execute(cli, args, { env: helperEnv(), windowsHide: true, timeout: 30000, maxBuffer: 1024 * 1024 })
const get = url => fetch(url, { signal: AbortSignal.timeout(3000) })

async function freePort() {
  const socket = net.createServer()
  socket.listen(0, '127.0.0.1')
  await within(once(socket, 'listening'), 'reserve public port')
  const port = socket.address().port
  await new Promise(resolve => socket.close(resolve))
  return port
}

function fixture(t, overrides = {}) {
  const parent = path.join(root, '.stack-work/dk07')
  mkdirSync(parent, { recursive: true })
  const directory = mkdtempSync(path.join(parent, 'compose-'))
  const lan = path.join(directory, 'lan')
  mkdirSync(lan)
  const envFile = path.join(directory, 'compose.env')
  const project = `battleship-dk07-${randomUUID()}`
  const values = { ...example, LAN_CONFIG_DIR: lan.replaceAll('\\', '/'), ...overrides }
  const save = () => writeFileSync(envFile, Object.entries(values).map(([key, value]) => `${key}='${value.replaceAll("'", "\\'")}'`).join('\n') + '\n')
  save()
  const files = [composeFile]
  let started = false
  let child
  const args = () => ['compose', '--project-directory', root, '--env-file', envFile, '-p', project, ...files.flatMap(file => ['-f', file])]
  const command = (...argsExtra) => execute(cli, [...args(), ...argsExtra], { env: helperEnv(), windowsHide: true,
    timeout: argsExtra[0] === 'up' ? 70000 : 30000, maxBuffer: 1024 * 1024 })
  const inspect = async service => {
    const id = (await command('ps', '--all', '--quiet', service)).stdout.trim()
    return id ? JSON.parse((await docker('inspect', id)).stdout)[0] : undefined
  }
  t.after(async () => {
    try {
      if (child?.exitCode === null && child.signalCode === null) {
        const closed = once(child, 'close'); child.kill(); await within(closed, 'host helper shutdown')
      }
      if (started) await command('down', '--remove-orphans')
    } finally {
      assert.equal(path.dirname(directory), parent, 'cleanup must stay inside the owned DK-07 fixture')
      rmSync(directory, { recursive: true, force: true })
    }
  })
  return { directory, lan, values, envFile, project, save, command, inspect,
    origin: () => `http://127.0.0.1:${values.WEB_PUBLIC_PORT}`,
    async model() { return JSON.parse((await command('config', '--format', 'json')).stdout) },
    override(data) {
      const filename = path.join(directory, 'override.json')
      writeFileSync(filename, JSON.stringify(data)); files.push(filename)
    },
    up() { started = true; return command('up', '-d', '--no-build', '--wait', '--wait-timeout', '60') },
    async healthy() {
      await until(async () => (await inspect('haskell'))?.State.Health?.Status === 'healthy' &&
        (await inspect('web'))?.State.Health?.Status === 'healthy', 'both Compose services healthy', 60000)
    },
    async pair() {
      const first = await peer(Number(values.WEB_PUBLIC_PORT)); t.after(() => first.ws.terminate())
      await first.wait('WELCOME 1 P1')
      const second = await peer(Number(values.WEB_PUBLIC_PORT)); t.after(() => second.ws.terminate())
      await second.wait('WELCOME 1 P2')
      return [first, second]
    },
    startHelper() {
      started = true
      child = spawn(shell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script,
        '-EnvFile', envFile, '-ConfigDir', lan, '-ProjectName', project, '-DockerCommand', cli], { env: helperEnv(), windowsHide: true })
      let output = ''
      child.on('error', error => { output += error.message })
      for (const stream of [child.stdout, child.stderr]) stream.on('data', bytes => { output += bytes.toString() })
      return { child, output: () => output }
    },
  }
}

test('DK-07: rendered Compose has exactly two services, explicit env, private TCP and read-only LAN directory', async t => {
  const f = fixture(t)
  await f.command('config', '--quiet')
  const model = await f.model()
  assert.deepEqual(Object.keys(model.services).sort(), ['haskell', 'web'])
  const { haskell, web } = model.services
  assert.equal(haskell.ports, undefined, 'the Haskell game port must never be published')
  assert.deepEqual(haskell.command, ['4000'])
  assert.deepEqual(Object.keys(haskell.environment).sort(), ['BATTLESHIP_BIND_HOST', 'BATTLESHIP_READY_FILE'])
  assert.deepEqual(Object.keys(web.environment).sort(), ['BATTLESHIP_TCP_HOST', 'BATTLESHIP_TCP_PORT', 'HOST', 'LAN_ORIGINS_FILE', 'PORT', 'PUBLIC_ORIGIN', 'WEB_PUBLIC_PORT'])
  assert.equal(web.environment.BATTLESHIP_TCP_HOST, 'haskell')
  assert.equal(web.environment.BATTLESHIP_TCP_PORT, '4000')
  assert.equal(web.ports.length, 1)
  assert.equal(web.ports[0].published, '8081'); assert.equal(web.ports[0].target, 8080)
  assert.ok(!web.ports[0].host_ip || web.ports[0].host_ip === '0.0.0.0')
  assert.equal(web.depends_on.haskell.condition, 'service_healthy')
  assert.ok(!web.depends_on.haskell.restart, 'restarting web would destroy its retained sessions')
  assert.equal(web.volumes.length, 1)
  assert.equal(web.volumes[0].source, f.values.LAN_CONFIG_DIR)
  assert.equal(web.volumes[0].target, '/run/battleship-lan')
  assert.equal(web.volumes[0].read_only, true)
  assert.equal(web.volumes[0].bind.create_host_path, false)
  for (const [service, file] of [[haskell, 'docker/haskell.Dockerfile'], [web, 'docker/web.Dockerfile']]) {
    assert.equal(service.build.dockerfile, file); assert.equal(service.build.target, 'runtime')
    assert.equal(path.resolve(service.build.context), path.resolve(root))
    assert.equal(service.restart, 'no'); assert.equal(service.stop_signal, 'SIGTERM')
    assert.equal(service.stop_grace_period, '10s')
    assert.equal(service.healthcheck.interval, '2s'); assert.equal(service.healthcheck.timeout, '1s')
    assert.equal(service.healthcheck.start_period, '10s'); assert.equal(service.healthcheck.retries, 5)
    assert.ok(!service.privileged && !service.network_mode && !service.container_name && !service.env_file)
  }
  // Compose re-escapes literal dollars in config output; the container must get single dollars.
  assert.deepEqual(haskell.healthcheck.test, ['CMD-SHELL', 'test "$$(cat "$$BATTLESHIP_READY_FILE")" = ready'])
  assert.match(web.healthcheck.test.at(-1), /\/healthz/)
  assert.doesNotMatch(JSON.stringify([haskell.healthcheck, web.healthcheck]), /createConnection|WELCOME|\/play|4000|token|fleet/)
})

test('DK-07: port mapping is consistent; empty/unset required values fail without hidden defaults', async t => {
  const f = fixture(t, { WEB_PUBLIC_PORT: '8099', PORT: '8090', BATTLESHIP_TCP_PORT: '4100', PUBLIC_ORIGIN: 'http://localhost:8099' })
  const { haskell, web } = (await f.model()).services
  assert.deepEqual(haskell.command, ['4100']); assert.equal(web.environment.BATTLESHIP_TCP_PORT, '4100')
  assert.equal(web.ports[0].published, '8099'); assert.equal(web.ports[0].target, 8090)
  for (const name of ['BATTLESHIP_BIND_HOST', 'BATTLESHIP_READY_FILE', 'BATTLESHIP_TCP_HOST', 'BATTLESHIP_TCP_PORT', 'HOST', 'PORT', 'WEB_PUBLIC_PORT', 'LAN_CONFIG_DIR']) {
    const previous = f.values[name]
    for (const value of ['', undefined]) {
      if (value === undefined) delete f.values[name]; else f.values[name] = value
      f.save()
      await assert.rejects(f.command('config', '--quiet'), error => error.stderr.includes(name))
    }
    f.values[name] = previous; f.save()
  }
})

test('DK-07: web cannot start before the real Haskell listener writes readiness', async t => {
  const f = fixture(t, { WEB_PUBLIC_PORT: String(await freePort()) })
  f.values.PUBLIC_ORIGIN = f.origin(); f.save()
  f.override({ services: { haskell: { entrypoint: ['sh', '-ec',
    'trap "exit 0" TERM INT; while [ ! -f /tmp/dk07-start ]; do sleep 0.1; done; exec /usr/local/bin/battleship-server "$$@"', 'dk07-gate'] } } })
  const startup = f.up()
  // Observe a failed production probe, then open the gate; no sleep-based race.
  startup.catch(() => {})
  await until(async () => (await f.inspect('haskell'))?.State.Health?.Log?.some(log => log.ExitCode !== 0), 'listener not ready', 20000)
  const core = await f.inspect('haskell')
  assert.notEqual(core.State.Health.Status, 'healthy')
  assert.ok(!(await f.inspect('web'))?.State.Running)
  await assert.rejects(get(f.origin() + '/healthz'))
  await docker('exec', core.Id, 'touch', '/tmp/dk07-start')
  await startup
  const ready = await f.inspect('haskell'), web = await f.inspect('web')
  const firstHealthy = ready.State.Health.Log.find(log => log.ExitCode === 0)
  assert.ok(Date.parse(firstHealthy.End) <= Date.parse(web.State.StartedAt))
  const pair = await f.pair()
  pair[0].send('QUIT')
  for (const client of pair) { await client.wait('GAME_OVER P2 OPPONENT_LEFT'); await within(client.closed) }
})

test('DK-07: backend startup failure cannot report readiness or start web', async t => {
  const f = fixture(t, { BATTLESHIP_BIND_HOST: 'http://localhost', WEB_PUBLIC_PORT: String(await freePort()) })
  f.values.PUBLIC_ORIGIN = f.origin(); f.save()
  await assert.rejects(f.up(), error => /haskell|dependency/i.test(error.stderr))
  const core = await f.inspect('haskell')
  assert.equal(core.State.Running, false); assert.equal(core.State.ExitCode, 1)
  assert.notEqual(core.State.Health.Status, 'healthy')
  assert.ok(!(await f.inspect('web'))?.State.Running)
  assert.match((await docker('logs', core.Id)).stderr, /BATTLESHIP_BIND_HOST/)
  await assert.rejects(get(f.origin() + '/healthz'))
})

test('DK-07: 100 health probes preserve P1/P2; stop cleans real sockets and restart reuses the port', async t => {
  const f = fixture(t, { WEB_PUBLIC_PORT: String(await freePort()) })
  f.values.PUBLIC_ORIGIN = f.origin(); f.save()
  await f.up()
  const core = await f.inspect('haskell'), web = await f.inspect('web')
  const page = await get(f.origin())
  assert.equal(page.status, 200); assert.match(page.headers.get('content-type'), /^text\/html/)
  const html = await page.text()
  assert.match(html, /lang="vi"/); assert.doesNotMatch(html, /main\.tsx/)
  const bundle = html.match(/src="([^" ]+\.js)"/)
  assert.ok(bundle, 'Compose must serve the built React bundle')
  assert.equal((await get(new URL(bundle[1], f.origin()))).status, 200)
  assert.deepEqual(core.HostConfig.PortBindings, {})
  assert.ok(Object.values(core.NetworkSettings.Ports ?? {}).every(binding => binding === null))
  assert.equal(core.Config.User, '10001:10001'); assert.equal(web.Config.User, 'node')
  assert.deepEqual(core.Config.Healthcheck.Test, ['CMD-SHELL', 'test "$(cat "$BATTLESHIP_READY_FILE")" = ready'])
  await docker('exec', core.Id, 'sh', '-ec', `i=0; while [ "$i" -lt 100 ]; do ${core.Config.Healthcheck.Test[1]}; i=$((i+1)); done`)
  const probe = web.Config.Healthcheck.Test
  assert.equal(probe[0], 'CMD')
  await docker('exec', web.Id, ...probe.slice(1, -1), `for (let i = 0; i < 100; i++) { ${probe.at(-1)} }`)
  const pair = await f.pair()
  const tokens = []
  for (const client of pair) tokens.push((await client.meta('SESSION')).token)
  pair[0].send(fleet1); await pair[0].wait('OK PLACE')
  pair[1].send(fleet2); await pair[1].wait('OK PLACE')
  for (const client of pair) { await client.wait('START P1'); await client.wait('TURN P1') }
  const third = await peer(Number(f.values.WEB_PUBLIC_PORT))
  await third.wait('ERROR SERVER_FULL'); await within(third.closed)
  const logged = await f.command('logs', '--no-color')
  const logs = logged.stdout + logged.stderr
  for (const secret of [...tokens, fleet1, fleet2]) assert.equal(logs.includes(secret), false)
  const http = net.createConnection({ host: '127.0.0.1', port: Number(f.values.WEB_PUBLIC_PORT) })
  http.on('error', () => {}); t.after(() => http.destroy())
  const httpClosed = once(http, 'close')
  await within(once(http, 'connect'))
  const response = once(http, 'data')
  http.write(`GET /healthz HTTP/1.1\r\nHost: 127.0.0.1:${f.values.WEB_PUBLIC_PORT}\r\nConnection: keep-alive\r\n\r\n`)
  assert.match((await within(response))[0].toString(), /^HTTP\/1\.1 200/)
  const start = performance.now()
  await f.command('stop')
  await within(Promise.all([...pair.map(client => client.closed), httpClosed]), 'HTTP/WS stop')
  assert.ok(performance.now() - start < 10000, 'stop must complete within 10 seconds')
  for (const service of ['haskell', 'web']) {
    const state = (await f.inspect(service)).State
    assert.equal(state.Running, false); assert.equal(state.ExitCode, 0); assert.equal(state.OOMKilled, false)
  }
  await assert.rejects(docker('cp', `${core.Id}:/tmp/battleship-ready`, path.join(f.directory, 'stale-ready')), /No such|Could not find/i)
  await assert.rejects(get(f.origin() + '/healthz'))
  await f.up()
  const next = await f.pair()
  assert.notEqual((await next[0].meta('SESSION')).token, tokens[0])
  next[0].send('QUIT')
  for (const client of next) { await client.wait('GAME_OVER P2 OPPONENT_LEFT'); await within(client.closed) }
})

test('DK-07: one match exits without restart; start haskell opens a new match; down releases containers/network', async t => {
  const f = fixture(t, { WEB_PUBLIC_PORT: String(await freePort()) })
  f.values.PUBLIC_ORIGIN = f.origin(); f.save()
  await f.up()
  const pair = await f.pair()
  const web = await f.inspect('web'), core = await f.inspect('haskell')
  pair[0].send('QUIT')
  for (const client of pair) { await client.wait('GAME_OVER P2 OPPONENT_LEFT'); await within(client.closed) }
  assert.equal((await within(docker('wait', core.Id))).stdout.trim(), '0')
  assert.equal((await f.inspect('haskell')).RestartCount, 0)
  assert.equal((await f.inspect('haskell')).State.Running, false)
  assert.deepEqual(await (await get(f.origin() + '/healthz')).json(), { status: 'ok' })
  await f.command('start', 'haskell'); await f.healthy()
  assert.equal((await f.inspect('web')).State.StartedAt, web.State.StartedAt)
  const next = await f.pair()
  const start = performance.now()
  await f.command('down', '--remove-orphans')
  for (const client of next) await within(client.closed)
  assert.ok(performance.now() - start < 10000, 'down must complete within 10 seconds')
  assert.equal((await docker('ps', '--all', '--quiet', '--filter', `label=com.docker.compose.project=${f.project}`)).stdout.trim(), '')
  assert.equal((await docker('network', 'ls', '--quiet', '--filter', `label=com.docker.compose.project=${f.project}`)).stdout.trim(), '')
  // Start the same project/port after down, proving no stale listener remains.
  await f.up(); const final = await f.pair()
  final[0].send('QUIT')
  for (const client of final) { await client.wait('GAME_OVER P2 OPPONENT_LEFT'); await within(client.closed) }
})

test('DK-07: actual Windows Auto helper starts production Compose and keeps the mounted file fresh', { skip: process.platform !== 'win32' }, async t => {
  const f = fixture(t, { WEB_PUBLIC_PORT: String(await freePort()) })
  const helper = f.startHelper()
  await until(async () => {
    if (helper.child.exitCode !== null) throw new Error(`helper exited: ${helper.output()}`)
    return (await f.inspect('web'))?.State.Health?.Status === 'healthy'
  }, 'host helper started real Compose', 60000)
  const web = await f.inspect('web')
  const env = parseEnv(readFileSync(path.join(f.lan, 'compose.env'), 'utf8'))
  assert.equal(env.PUBLIC_ORIGIN, '')
  assert.equal(env.LAN_ORIGINS_FILE, '/run/battleship-lan/origins.json')
  assert.equal(env.WEB_PUBLIC_PORT, f.values.WEB_PUBLIC_PORT)
  const mount = web.Mounts.find(item => item.Destination === '/run/battleship-lan')
  assert.equal(mount.RW, false)
  const filename = path.join(f.lan, 'origins.json')
  const first = JSON.parse(readFileSync(filename))
  await until(() => JSON.parse(readFileSync(filename)).updatedAt > first.updatedAt, 'host heartbeat after Compose startup')
  const pair = await f.pair()
  assert.equal(helper.child.exitCode, null)
  pair[0].send('QUIT')
  for (const client of pair) { await client.wait('GAME_OVER P2 OPPONENT_LEFT'); await within(client.closed) }
})
