import assert from 'node:assert/strict'
import { execFile, spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { once } from 'node:events'
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import net from 'node:net'
import { networkInterfaces } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { parseEnv, promisify } from 'node:util'
import { peer, within, fleet1, fleet2, winningShots } from '../frontend/test/helpers.mjs'
import { helperEnv, shell, script, until } from '../frontend/test/lan-helper-support.mjs'
import { lanAddresses } from '../frontend/bridge.mjs'
import { validateProfile } from './test-runtime-profiles.mjs'
import { rtsCommand, parseTasks, verifyContainer, verifyRuntime } from './start-affinity.mjs'
import { verifyPlacement } from './start-numa.mjs'

const root = fileURLToPath(new URL('../', import.meta.url))
const composeFile = path.join(root, 'compose.yaml')
const example = parseEnv(readFileSync(path.join(root, '.env.example'), 'utf8'))
const cli = process.env.BATTLESHIP_DOCKER_CLI ?? 'docker'
const execute = promisify(execFile)
const docker = (...args) => execute(cli, args, { env: helperEnv(), windowsHide: true, timeout: 30000, maxBuffer: 1024 * 1024 })
const get = url => fetch(url, { signal: AbortSignal.timeout(3000) })
const require = createRequire(new URL('../frontend/package.json', import.meta.url))
const { WebSocket } = require('ws')
const runtimeProfile = process.env.BATTLESHIP_RUNTIME_PROFILE_FILE
  ? validateProfile(JSON.parse(readFileSync(process.env.BATTLESHIP_RUNTIME_PROFILE_FILE, 'utf8'))) : null
const evidenceDir = process.env.BATTLESHIP_RUNTIME_EVIDENCE_DIR

async function freePort() {
  const socket = net.createServer()
  socket.listen(0, '127.0.0.1')
  await within(once(socket, 'listening'), 'reserve public port')
  const port = socket.address().port
  await new Promise(resolve => socket.close(resolve))
  return port
}

function fixture(t, overrides = {}) {
  const parent = path.join(root, '.stack-work/dk08')
  mkdirSync(parent, { recursive: true })
  const directory = mkdtempSync(path.join(parent, 'compose-'))
  const lan = path.join(directory, 'lan')
  mkdirSync(lan)
  const envFile = path.join(directory, 'compose.env')
  const project = `battleship-dk08-${randomUUID()}`
  const values = { ...example, LAN_CONFIG_DIR: lan.replaceAll('\\', '/'), ...overrides }
  const save = () => writeFileSync(envFile, Object.entries(values).map(([key, value]) => `${key}='${value.replaceAll("'", "\\'")}'`).join('\n') + '\n')
  save()
  const files = [composeFile]
  const overlay = data => {
    const filename = path.join(directory, `override-${files.length}.json`)
    writeFileSync(filename, JSON.stringify(data)); files.push(filename)
  }
  if (runtimeProfile) {
    const c = runtimeProfile.config, command = rtsCommand(values.BATTLESHIP_TCP_PORT, c)
    if (c.ghcNuma) command.splice(command.length - 1, 0, c.ghcNuma)
    overlay({ services: {
      haskell: { command, environment: { BATTLESHIP_GAME_CAPABILITY: String(c.gameCapability) },
        ...(c.haskell ? { cpuset: c.haskell.join(',') } : {}),
        ...(c.sysNice ? { cap_add: ['SYS_NICE'] } : {}),
        ...(c.mems ? { entrypoint: ['/usr/local/bin/battleship-numa-entrypoint', '/usr/local/bin/battleship-server'],
          environment: { BATTLESHIP_GAME_CAPABILITY: String(c.gameCapability), BATTLESHIP_NUMA_POLICY: c.policy, BATTLESHIP_NUMA_MEMS: c.mems.join(',') } } : {}) },
      web: c.web ? { cpuset: c.web.join(',') } : {},
    } })
  }
  let started = false
  let child
  let sourceRoot = root
  const args = () => ['compose', '--project-directory', sourceRoot, '--env-file', envFile, '-p', project, ...files.flatMap(file => ['-f', file])]
  const command = (...argsExtra) => execute(cli, [...args(), ...argsExtra], { env: helperEnv(), windowsHide: true,
    timeout: argsExtra[0] === 'build' ? 600000 : argsExtra[0] === 'up' ? 70000 : 30000, maxBuffer: 16 * 1024 * 1024 })
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
      assert.equal(path.dirname(directory), parent, 'cleanup must stay inside the owned Compose fixture')
      rmSync(directory, { recursive: true, force: true })
    }
  })
  return { directory, lan, values, envFile, project, save, command, inspect,
    origin: () => `http://127.0.0.1:${values.WEB_PUBLIC_PORT}`,
    async model() { return JSON.parse((await command('config', '--format', 'json')).stdout) },
    async cleanSource() {
      const snapshot = path.join(directory, 'source')
      mkdirSync(snapshot)
      const { stdout } = await execute('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], { cwd: root, windowsHide: true })
      for (const file of new Set(stdout.split('\0').filter(Boolean))) {
        const source = path.resolve(root, file), target = path.resolve(snapshot, file)
        assert.ok(source.startsWith(path.resolve(root) + path.sep) && target.startsWith(snapshot + path.sep))
        mkdirSync(path.dirname(target), { recursive: true }); copyFileSync(source, target)
      }
      for (const forbidden of ['.git', '.env', '.stack-work', 'frontend/node_modules', 'frontend/dist'])
        assert.equal(existsSync(path.join(snapshot, forbidden)), false, `clean snapshot contains ${forbidden}`)
      sourceRoot = snapshot; files[0] = path.join(snapshot, 'compose.yaml')
      const built = await command('build')
      writeFileSync(path.join(root, '.stack-work/dk08/clean-build.log'), built.stdout + built.stderr)
    },
    override: overlay,
    async up() {
      started = true
      if (runtimeProfile?.config.mems) {
        await command('create', '--no-build')
        const core = await inspect('haskell')
        assert.equal(core.State.Running, false, 'Memory mask phải có trước khi process chạy.')
        await docker('update', '--cpuset-mems', runtimeProfile.config.mems.join(','), core.Id)
        assert.equal((await inspect('haskell')).HostConfig.CpusetMems, runtimeProfile.config.mems.join(','))
      }
      return command('up', '-d', '--no-build', '--no-recreate', '--wait', '--wait-timeout', '60')
    },
    async verifyProfile() {
      assert.ok(runtimeProfile)
      const c = runtimeProfile.config, core = await inspect('haskell'), web = await inspect('web')
      const command = rtsCommand(values.BATTLESHIP_TCP_PORT, c)
      if (c.ghcNuma) command.splice(command.length - 1, 0, c.ghcNuma)
      assert.deepEqual(core.Config.Cmd, command)
      assert.equal(core.State.Health.Status, 'healthy'); assert.equal(web.State.Health.Status, 'healthy')
      const statuses = (await docker('exec', core.Id, 'sh', '-ec', 'for f in /proc/1/task/*/status; do cat "$f"; done')).stdout
      const tasks = parseTasks(statuses)
      if (c.haskell) verifyContainer(core, tasks, c.haskell, command)
      if (c.web) {
        const status = (await docker('exec', web.Id, 'sh', '-ec', 'for f in /proc/1/task/*/status; do cat "$f"; done')).stdout
        verifyContainer(web, parseTasks(status), c.web)
      }
      const logs = await docker('logs', '--since', core.State.StartedAt, core.Id)
      verifyRuntime(logs.stdout + logs.stderr, tasks, c)
      let placement = null
      if (c.mems) {
        assert.equal(core.HostConfig.CpusetMems, c.mems.join(','))
        const stat = (await docker('exec', core.Id, 'sh', '-ec', 'for f in /proc/1/task/*/stat; do cat "$f"; done')).stdout
        const maps = (await docker('exec', core.Id, 'cat', '/proc/1/numa_maps')).stdout
        placement = verifyPlacement(c, statuses, stat, maps)
      }
      return { profile: runtimeProfile.name, command, tasks, placement, haskellImage: core.Image, webImage: web.Image }
    },
    clockFixture() {
      copyFileSync(path.join(root, 'docker/test/controlled-clock.mjs'), path.join(lan, 'controlled-clock.mjs'))
      writeFileSync(path.join(lan, 'clock.json'), '{"elapsed":0}')
      this.override({ services: { web: { entrypoint: ['node', '/run/battleship-lan/controlled-clock.mjs'] } } })
    },
    async advanceClock(elapsed) {
      const temporary = path.join(lan, 'clock.tmp')
      writeFileSync(temporary, JSON.stringify({ elapsed })); renameSync(temporary, path.join(lan, 'clock.json'))
      const web = await inspect('web')
      await until(async () => JSON.parse((await docker('exec', web.Id, 'cat', '/tmp/dk08-clock-status.json')).stdout).elapsed === elapsed,
        'container clock applied', 5000)
    },
    async healthy() {
      await until(async () => (await inspect('haskell'))?.State.Health?.Status === 'healthy' &&
        (await inspect('web'))?.State.Health?.Status === 'healthy', 'both Compose services healthy', 60000)
    },
    async pair(host = '127.0.0.1') {
      const first = await peer(Number(values.WEB_PUBLIC_PORT), host); t.after(() => first.ws.terminate())
      await first.wait('WELCOME 1 P1')
      const second = await peer(Number(values.WEB_PUBLIC_PORT), host); t.after(() => second.ws.terminate())
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
  assert.deepEqual(Object.keys(haskell.environment).sort(), ['BATTLESHIP_BIND_HOST', 'BATTLESHIP_GAME_CAPABILITY', 'BATTLESHIP_READY_FILE'])
  assert.equal(haskell.environment.BATTLESHIP_GAME_CAPABILITY, '0')
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

test('NM-08: three locked seeds have complete, identical private transcripts under the selected runtime', async t => {
  const f = fixture(t, { WEB_PUBLIC_PORT: String(await freePort()) })
  f.values.PUBLIC_ORIGIN = f.origin(); f.save(); await f.up()
  const workloads = JSON.parse(readFileSync(path.join(root, 'bench/fixtures-v1.json'), 'utf8'))
  const games = [], placements = []
  for (const [index, workload] of workloads.entries()) {
    if (index) { await f.command('start', 'haskell'); await f.healthy() }
    if (runtimeProfile) placements.push(await f.verifyProfile())
    const pair = await f.pair()
    for (const entry of workload.commands) {
      pair[entry.actor === 'P1' ? 0 : 1].send(entry.command)
      await Promise.all(pair.map(async (p, actor) => {
        for (const frame of entry.responses[actor ? 'P2' : 'P1']) await p.wait(frame)
      }))
    }
    for (const p of pair) await within(p.closed, 'locked game finished')
    const frames = pair.map(p => p.frames.filter(frame => !frame.startsWith('{')))
    for (const [actor, actual] of frames.entries()) assert.deepEqual(actual,
      [`WELCOME 1 P${actor + 1}`, ...workload.commands.flatMap(e => e.responses[actor ? 'P2' : 'P1'])])
    games.push({ seed: workload.seed, checksum: workload.checksum, commandCount: workload.commandCount, frames })
    assert.equal((await docker('wait', (await f.inspect('haskell')).Id)).stdout.trim(), '0')
  }
  if (evidenceDir) writeFileSync(path.join(evidenceDir, `${runtimeProfile.name}-transcript.json`),
    JSON.stringify({ schemaVersion: 1, games, placements }, null, 2))
})

test('DK-08: build from a clean source snapshot, then complete a private game over mapped HTTP/WebSocket ports', async t => {
  const f = fixture(t, { WEB_PUBLIC_PORT: String(await freePort()) })
  f.values.PUBLIC_ORIGIN = f.origin(); f.save()
  await f.cleanSource(); await f.up()
  assert.equal((await get(f.origin())).status, 200)
  const [first, second] = await f.pair()
  first.send('PLACE CV=J10:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H')
  await first.wait('ERROR SHIP_OUT_OF_BOUNDS CV')
  first.send(fleet1); await first.wait('OK PLACE'); await first.wait('WAITING OPPONENT')
  first.send('FIRE A6'); await first.wait('ERROR FLEETS_NOT_READY')
  const third = await peer(Number(f.values.WEB_PUBLIC_PORT))
  await third.wait('ERROR SERVER_FULL'); await within(third.closed)
  assert.equal(third.frames.some(frame => frame.startsWith('WELCOME ')), false)
  second.send(fleet2); await second.wait('OK PLACE')
  for (const client of [first, second]) { await client.wait('START P1'); await client.wait('TURN P1') }
  second.send('FIRE A1'); await second.wait('ERROR NOT_YOUR_TURN P1')
  first.send('FIRE K1'); await first.wait('ERROR INVALID_COORDINATE')
  first.send('FIRE J10'); await first.wait('SHOT J10 MISS'); await second.wait('INCOMING J10 MISS')
  for (const client of [first, second]) await client.wait('TURN P2')
  second.send('FIRE J10'); await second.wait('SHOT J10 MISS'); await first.wait('INCOMING J10 MISS')
  for (const client of [first, second]) await client.wait('TURN P1')
  first.send('FIRE J10'); await first.wait('ERROR ALREADY_FIRED J10')
  for (const [index, coord] of winningShots.entries()) {
    const outcome = index === 16 ? 'WIN' : ({ 4: 'SUNK CV', 8: 'SUNK BB', 11: 'SUNK CR', 14: 'SUNK SB' }[index] ?? 'HIT')
    first.send(`FIRE ${coord}`)
    await first.wait(`SHOT ${coord} ${outcome}`); await second.wait(`INCOMING ${coord} ${outcome}`)
    if (outcome !== 'WIN') for (const client of [first, second]) await client.wait('TURN P1')
    assert.equal(first.frames.join('\n').includes('CV=A6'), false)
    assert.equal(second.frames.join('\n').includes('CV=A1'), false)
  }
  for (const client of [first, second]) { await client.wait('GAME_OVER P1 ALL_SHIPS_SUNK'); await within(client.closed) }
  const core = await f.inspect('haskell')
  assert.equal((await within(docker('wait', core.Id))).stdout.trim(), '0')
  assert.equal(first.frames.filter(frame => frame.startsWith('SHOT ')).length, 18)
  assert.equal(second.frames.filter(frame => frame.startsWith('SHOT ')).length, 1)
  assert.equal(second.frames.some(frame => frame.startsWith('SHOT A6 ')), false)
  t.diagnostic('Clean export excludes .git/.env/host caches; production images built with all Linux tests. Full game: 17 hits + misses/errors, Haskell exit 0.')
})

test('DK-08: strict Origin/Host rejection cannot allocate a slot; both players resume their own private history', async t => {
  const f = fixture(t, { WEB_PUBLIC_PORT: String(await freePort()) })
  f.values.PUBLIC_ORIGIN = f.origin(); f.save(); await f.up()
  const reject = async (origin, host) => {
    const ws = new WebSocket(`ws://127.0.0.1:${f.values.WEB_PUBLIC_PORT}/play`, { origin, headers: { Host: host } })
    ws.on('error', () => {})
    const rejected = new Promise((resolve, reject) => {
      ws.once('unexpected-response', (_request, response) => { response.resume(); ws.terminate(); resolve(response.statusCode) })
      ws.once('open', () => { ws.terminate(); reject(new Error('invalid Origin/Host accepted')) })
    })
    assert.equal(await within(rejected, 'rejected handshake'), 401)
  }
  await reject(f.origin(), `localhost:${f.values.WEB_PUBLIC_PORT}`)
  await reject('http://127.0.0.1:8080', '127.0.0.1:8080')
  await reject('http://evil.example:8081', 'evil.example:8081')
  const pair = await f.pair()
  const tokens = []
  for (const client of pair) tokens.push((await client.meta('SESSION')).token)
  pair[0].send(fleet1); await pair[0].wait('OK PLACE')
  pair[1].send(fleet2); await pair[1].wait('OK PLACE')
  for (const client of pair) { await client.wait('START P1'); await client.wait('TURN P1') }
  pair[0].send('FIRE A6'); await pair[0].wait('SHOT A6 HIT'); await pair[1].wait('INCOMING A6 HIT')
  for (const actor of [0, 1]) {
    const waiting = pair[1 - actor]
    pair[actor].ws.close(); await within(pair[actor].closed)
    let pause
    do { pause = await waiting.meta('CONNECTION') } while (!pause.missing.length)
    assert.equal(pause.missing[0].player, `P${actor + 1}`)
    assert.ok(pause.missing[0].deadline > Date.now() && pause.missing[0].deadline <= Date.now() + 300000,
      'Phiên đang chờ trong thời hạn; ranh giới 5 phút được kiểm tra bằng clock fixture.')
    waiting.send('FIRE B6'); assert.deepEqual(await waiting.meta('CONNECTION'), pause)
    const stranger = await peer(Number(f.values.WEB_PUBLIC_PORT), '127.0.0.1', 'a'.repeat(64))
    assert.equal((await stranger.meta('RESUME_ERROR')).code, 'INVALID_SESSION'); await within(stranger.closed)
    const restored = await peer(Number(f.values.WEB_PUBLIC_PORT), 'localhost', tokens[actor])
    t.after(() => restored.ws.terminate())
    const replay = await restored.meta('SESSION')
    assert.equal(replay.token, tokens[actor]); assert.equal(replay.fleet, actor === 0 ? fleet1 : fleet2)
    assert.ok(replay.frames.includes(`WELCOME 1 P${actor + 1}`))
    assert.ok(replay.frames.includes(actor === 0 ? 'SHOT A6 HIT' : 'INCOMING A6 HIT'))
    assert.equal(JSON.stringify(replay).includes(actor === 0 ? 'CV=A6' : 'CV=A1'), false)
    assert.deepEqual((await restored.meta('CONNECTION')).missing, [])
    assert.deepEqual((await waiting.meta('CONNECTION')).missing, [])
    pair[actor] = restored
  }
  pair[0].send('FIRE A6'); await pair[0].wait('ERROR ALREADY_FIRED A6')
  pair[0].send('FIRE B6'); await pair[0].wait('SHOT B6 HIT')
  pair[0].send('QUIT')
  for (const client of pair) { await client.wait('GAME_OVER P2 OPPONENT_LEFT'); await within(client.closed) }
})

for (const inBattle of [false, true]) test(`DK-08: exact five-minute clock boundary ${inBattle ? 'during battle after a successful resume' : 'while placing'} forfeits the correct player`, async t => {
  const f = fixture(t, { WEB_PUBLIC_PORT: String(await freePort()) })
  f.values.PUBLIC_ORIGIN = f.origin(); f.save(); f.clockFixture(); await f.up()
  const pair = await f.pair()
  const tokens = []
  for (const client of pair) tokens.push((await client.meta('SESSION')).token)
  pair[0].send(fleet1); await pair[0].wait('OK PLACE')
  if (inBattle) {
    pair[1].send(fleet2); await pair[1].wait('OK PLACE')
    for (const client of pair) { await client.wait('START P1'); await client.wait('TURN P1') }
  }
  pair[0].ws.close(); await within(pair[0].closed); await pair[1].meta('CONNECTION')
  await f.advanceClock(299999)
  assert.equal((await f.inspect('haskell')).State.Running, true)
  assert.equal(pair[1].frames.some(frame => frame.startsWith('GAME_OVER ')), false)
  let missing = 0, boundary = 300000
  if (inBattle) {
    const restored = await peer(Number(f.values.WEB_PUBLIC_PORT), '127.0.0.1', tokens[0])
    t.after(() => restored.ws.terminate())
    assert.equal((await restored.meta('SESSION')).token, tokens[0]); await restored.meta('CONNECTION')
    await pair[1].meta('CONNECTION'); pair[0] = restored
    await f.advanceClock(300000)
    restored.send('FIRE A6'); await restored.wait('SHOT A6 HIT')
    assert.equal(restored.frames.some(frame => frame.startsWith('GAME_OVER ')), false, 'old expiry must be cancelled')
    pair[1].ws.close(); await within(pair[1].closed); await restored.meta('CONNECTION')
    missing = 1; boundary = 600000
    await f.advanceClock(599999)
    assert.equal((await f.inspect('haskell')).State.Running, true)
  }
  await f.advanceClock(boundary)
  const winner = `P${2 - missing}`
  await pair[1 - missing].wait(`GAME_OVER ${winner} OPPONENT_LEFT`); await within(pair[1 - missing].closed)
  const core = await f.inspect('haskell')
  assert.equal((await within(docker('wait', core.Id))).stdout.trim(), '0')
  const late = await peer(Number(f.values.WEB_PUBLIC_PORT), 'localhost', tokens[missing])
  const result = await late.meta('SESSION')
  assert.ok(result.frames.includes(`GAME_OVER ${winner} OPPONENT_LEFT`)); await within(late.closed)
  t.diagnostic('Clock fixture imports unmodified /app/bridge.mjs; default RECONNECT_GRACE_MS remains 300000, winner comes from real Haskell Quit.')
})

for (const service of ['haskell', 'web']) test(`DK-08: restarting ${service} mid-game closes old sessions and never restores old state`, async t => {
  const f = fixture(t, { WEB_PUBLIC_PORT: String(await freePort()) })
  f.values.PUBLIC_ORIGIN = f.origin(); f.save(); await f.up()
  const pair = await f.pair(), token = (await pair[0].meta('SESSION')).token
  pair[0].send(fleet1); await pair[0].wait('OK PLACE')
  pair[1].send(fleet2); await pair[1].wait('OK PLACE'); await pair[0].wait('START P1'); await pair[0].wait('TURN P1')
  pair[0].send('FIRE A6'); await pair[0].wait('SHOT A6 HIT')
  await f.command('restart', service)
  for (const client of pair) await within(client.closed, 'old session closes on restart')
  assert.equal(pair[0].frames.includes('GAME_OVER P1 ALL_SHIPS_SUNK'), false)
  if (service === 'web') {
    const core = await f.inspect('haskell')
    assert.equal((await within(docker('wait', core.Id))).stdout.trim(), '0')
    await f.command('start', 'haskell')
  }
  await f.healthy()
  const old = await peer(Number(f.values.WEB_PUBLIC_PORT), '127.0.0.1', token)
  assert.equal((await old.meta('RESUME_ERROR')).code, 'INVALID_SESSION', 'unfinished sessions cannot replay into a restarted match')
  await within(old.closed)
  const fresh = await f.pair()
  const current = await fresh[0].meta('SESSION')
  assert.notEqual(current.token, token); assert.equal(current.fleet, null)
  fresh[0].send('FIRE A6'); await fresh[0].wait('ERROR FLEETS_NOT_READY')
  fresh[0].send('QUIT')
  for (const client of fresh) { await client.wait('GAME_OVER P2 OPPONENT_LEFT'); await within(client.closed) }
})

test('DK-08: concurrent WebSocket shots have one valid actor and exactly one update per target', async t => {
  const f = fixture(t, { WEB_PUBLIC_PORT: String(await freePort()) })
  f.values.PUBLIC_ORIGIN = f.origin(); f.save(); await f.up()
  const pair = await f.pair()
  pair[0].send(fleet1); await pair[0].wait('OK PLACE')
  pair[1].send(fleet2); await pair[1].wait('OK PLACE')
  for (const client of pair) { await client.wait('START P1'); await client.wait('TURN P1') }
  // Hits retain P1's turn: P2's command cannot become valid through a preceding miss.
  for (const [index, coord] of winningShots.slice(0, 10).entries()) {
    pair[0].send(`FIRE ${coord}`); pair[1].send('FIRE A1')
    const outcome = { 4: 'SUNK CV', 8: 'SUNK BB' }[index] ?? 'HIT'
    await pair[0].wait(`SHOT ${coord} ${outcome}`); await pair[1].wait(`INCOMING ${coord} ${outcome}`)
    await pair[1].wait('ERROR NOT_YOUR_TURN P1')
    for (const client of pair) await client.wait('TURN P1')
    pair[0].send(`FIRE ${coord}`); await pair[0].wait(`ERROR ALREADY_FIRED ${coord}`)
    assert.equal(pair[0].frames.filter(frame => frame.startsWith(`SHOT ${coord} `)).length, 1)
    assert.equal(pair[1].frames.some(frame => frame.startsWith('SHOT A1 ')), false)
  }
  pair[0].send('QUIT')
  for (const client of pair) { await client.wait('GAME_OVER P2 OPPONENT_LEFT'); await within(client.closed) }
})

for (const actor of [1, 2, 0]) test(`DK-08: C-07 ${actor ? 'P' + actor : 'both clients'} stops reading TCP; server and sockets exit within deadline`, async t => {
  const f = fixture(t, { WEB_PUBLIC_PORT: String(await freePort()) })
  f.values.PUBLIC_ORIGIN = f.origin(); f.save()
  copyFileSync(path.join(root, 'docker/test/nonreading-clients.mjs'), path.join(f.lan, 'nonreading-clients.mjs'))
  await f.up()
  const web = await f.inspect('web'), core = await f.inspect('haskell')
  let failure
  const running = docker('exec', web.Id, 'node', '/run/battleship-lan/nonreading-clients.mjs', String(actor))
    .catch(error => { failure = error })
  await until(async () => {
    if (failure) throw failure
    try { await docker('exec', web.Id, 'test', '-f', '/tmp/dk08-nonreaders-ready'); return true } catch { return false }
  }, 'both TCP clients admitted and flooding', 10000)
  // The process must terminate while the client streams are still paused.
  assert.equal((await within(docker('wait', core.Id), 'C-07 container shutdown', 10000)).stdout.trim(), '0')
  writeFileSync(path.join(f.lan, 'release-nonreaders'), 'release\n')
  const result = await running
  if (failure) throw failure
  const report = JSON.parse(result.stdout.trim())
  assert.equal(report.socketsClosed, 2); assert.equal(report.winner, actor ? `P${3 - actor}` : null)
  assert.equal((await f.inspect('haskell')).State.Running, false)
  assert.equal((await get(f.origin() + '/healthz')).status, 200)
})

test('DK-08: two separate browser processes play the production React UI to victory without secret reveal', async t => {
  const { chromium } = require('playwright')
  const channels = process.env.BATTLESHIP_BROWSER_CHANNELS?.split(',') ?? [undefined, undefined]
  assert.equal(channels.length, 2, 'BATTLESHIP_BROWSER_CHANNELS must specify two browsers')
  assert.ok(channels.every(channel => channel === undefined || ['chrome', 'msedge'].includes(channel)), 'supported channels: chrome,msedge')
  const host = process.env.BATTLESHIP_LAN_TEST_HOST ?? '127.0.0.1'
  assert.ok(host === '127.0.0.1' || lanAddresses(networkInterfaces()).includes(host), 'browser host must be a current host LAN IPv4')
  const f = fixture(t, { WEB_PUBLIC_PORT: String(await freePort()) })
  const origin = `http://${host}:${f.values.WEB_PUBLIC_PORT}`
  f.values.PUBLIC_ORIGIN = origin; f.save(); await f.up()
  const pages = [], errors = [], received = [[], []], versions = []
  for (const [actor, viewport] of [{ width: 1440, height: 1000 }, { width: 390, height: 844 }].entries()) {
    const browser = await chromium.launch({ headless: true, channel: channels[actor] }); t.after(() => browser.close())
    versions.push(`${channels[actor] ?? 'Chromium'} ${browser.version()}`)
    const context = await browser.newContext({ viewport })
    const page = await context.newPage(); page.setDefaultTimeout(10000)
    page.on('websocket', ws => ws.on('framereceived', ({ payload }) => received[actor].push(payload.toString())))
    page.on('pageerror', error => errors.push(error.message)); await page.goto(origin); pages.push(page)
  }
  const status = (page, text) => page.locator('.game-status').filter({ hasText: text }).waitFor()
  const target = (page, coord) => page.locator(`[aria-label="Bàn mục tiêu"] [data-coordinate="${coord}"]`)
  const own = (page, coord) => page.locator(`[aria-label="Bàn phòng thủ"] [data-coordinate="${coord}"]`)
  for (const [actor, page] of pages.entries()) {
    await page.getByRole('button', { name: 'Vào phòng tác chiến' }).click()
    await page.getByRole('button', { name: 'Chọn Cổ điển' }).click()
    if (actor === 0) {
      await page.locator('.board-panel [data-coordinate="J10"]').click()
      await page.locator('.placement-status').filter({ hasText: 'vượt biên' }).waitFor()
      assert.equal(await page.locator('.board-cell.occupied').count(), 0)
    }
    for (const [index, name] of ['Hàng không mẫu hạm', 'Thiết giáp hạm', 'Tuần dương hạm', 'Tàu ngầm', 'Khu trục hạm'].entries()) {
      await page.getByRole('button', { name: new RegExp(name) }).click()
      await page.locator(`.board-panel [data-coordinate="A${index + (actor === 0 ? 1 : 6)}"]`).click()
    }
    assert.equal(await page.locator('.board-cell.occupied').count(), 17)
    await page.getByRole('button', { name: 'Bắt đầu trận' }).click()
    if (actor === 0) await status(page, 'Chờ đối thủ')
  }
  const [first, second] = pages
  await status(first, 'Đến lượt bạn'); await status(second, 'Lượt đối thủ')
  await until(() => received.every((frames, actor) => frames.includes(`WELCOME 1 P${actor + 1}`)), 'both browser identities received')
  for (const [actor, frames] of received.entries()) assert.ok(frames.includes(`WELCOME 1 P${actor + 1}`), 'two distinct player slots')
  assert.equal(await target(second, 'A1').isDisabled(), true)
  await target(first, 'J10').click(); await status(second, 'Đến lượt bạn')
  assert.equal(await own(second, 'J10').getAttribute('data-outcome'), 'MISS')
  await target(second, 'J10').click(); await status(first, 'Đến lượt bạn')
  assert.equal(await own(first, 'J10').getAttribute('data-outcome'), 'MISS')
  const token = await first.getByRole('textbox', { name: 'Mã phiên của bạn' }).inputValue()
  for (const [index, coord] of winningShots.entries()) {
    await target(first, coord).click()
    const outcome = index === 16 ? 'WIN' : ({ 4: 'SUNK CV', 8: 'SUNK BB', 11: 'SUNK CR', 14: 'SUNK SB' }[index] ?? 'HIT')
    await until(async () => await target(first, coord).getAttribute('data-outcome') === outcome, 'UI shot acknowledged')
    await until(async () => await own(second, coord).getAttribute('data-outcome') === outcome, 'opponent UI shot acknowledged')
    assert.equal(await first.locator('.enemy-board .occupied').count(), 0)
    assert.equal(await second.locator('.enemy-board .occupied').count(), 0)
    if (outcome !== 'WIN') await status(first, 'Đến lượt bạn')
    if (index === 0) {
      await first.reload(); await status(first, 'Đến lượt bạn')
      assert.equal(await first.getByRole('textbox', { name: 'Mã phiên của bạn' }).inputValue(), token)
      assert.equal(await target(first, 'J10').getAttribute('data-outcome'), 'MISS')
      assert.equal(await target(first, 'A6').getAttribute('data-outcome'), 'HIT')
      assert.equal(await first.locator('[aria-label="Bàn phòng thủ"] .occupied').count(), 17)
    }
  }
  await status(first, 'Bạn thắng'); await status(second, 'Bạn thua')
  for (const page of pages) assert.equal(await page.locator('.enemy-board button:not(:disabled)').count(), 0)
  assert.deepEqual(errors, [])
  // Redact recovery tokens in shareable screenshots.
  for (const [index, page] of pages.entries()) {
    await page.evaluate(() => { document.activeElement?.blur(); window.scrollTo(0, 0) })
    await page.screenshot({ path: evidenceDir ? path.join(evidenceDir, `${runtimeProfile.name}-ui-${index}.png`)
      : path.join(root, `.stack-work/dk08/ui-${index === 0 ? 'victory-desktop' : 'defeat-mobile'}.png`),
      fullPage: true, mask: [page.getByRole('textbox', { name: 'Mã phiên của bạn' })] })
  }
  const core = await f.inspect('haskell')
  assert.equal((await within(docker('wait', core.Id))).stdout.trim(), '0')
  t.diagnostic(`ONE Windows/Linux host; TWO separate browser processes: ${versions.join(' / ')}; origin ${origin}. P1/P2, invalid placement, MISS/HIT/SUNK/WIN, reload after A6, privacy and exit 0 passed.`)
})

test('DK-08: Windows LAN IPv4 from the host helper serves a complete game over the real host network address', { skip: process.platform !== 'win32' }, async t => {
  const interfaces = networkInterfaces()
  const selected = process.env.BATTLESHIP_LAN_INTERFACE ?? Object.keys(interfaces).find(name => /wi-?fi/i.test(name))
  const addresses = lanAddresses(interfaces, selected)
  const host = process.env.BATTLESHIP_LAN_TEST_HOST ?? addresses[0]
  assert.ok(host && addresses.includes(host), 'no eligible host LAN IPv4; set BATTLESHIP_LAN_INTERFACE / BATTLESHIP_LAN_TEST_HOST')
  const f = fixture(t, { WEB_PUBLIC_PORT: String(await freePort()), LAN_INTERFACE: selected ?? '' })
  const helper = f.startHelper()
  await until(async () => {
    if (helper.child.exitCode !== null) throw new Error(helper.output())
    return (await f.inspect('web'))?.State.Health?.Status === 'healthy'
  }, 'LAN Compose ready', 60000)
  const origin = `http://${host}:${f.values.WEB_PUBLIC_PORT}`
  assert.equal((await get(origin)).status, 200)
  assert.ok(JSON.parse(readFileSync(path.join(f.lan, 'origins.json'))).origins.includes(origin))
  const pair = await f.pair(host)
  pair[0].send(fleet1); await pair[0].wait('OK PLACE')
  pair[1].send(fleet2); await pair[1].wait('OK PLACE')
  for (const client of pair) { await client.wait('START P1'); await client.wait('TURN P1') }
  for (const [index, coord] of winningShots.entries()) {
    const outcome = index === 16 ? 'WIN' : ({ 4: 'SUNK CV', 8: 'SUNK BB', 11: 'SUNK CR', 14: 'SUNK SB' }[index] ?? 'HIT')
    pair[0].send(`FIRE ${coord}`)
    await pair[0].wait(`SHOT ${coord} ${outcome}`); await pair[1].wait(`INCOMING ${coord} ${outcome}`)
    if (outcome !== 'WIN') for (const client of pair) await client.wait('TURN P1')
  }
  for (const client of pair) { await client.wait('GAME_OVER P1 ALL_SHIPS_SUNK'); await within(client.closed) }
  t.diagnostic(`LAN host address ${origin}; two automated WebSocket peers on ONE Windows computer, not two physical devices.`)
})
