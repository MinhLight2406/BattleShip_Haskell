import assert from 'node:assert/strict'
import { test } from 'node:test'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import net from 'node:net'
import { networkInterfaces } from 'node:os'
import path from 'node:path'
import { parseEnv } from 'node:util'
import { createBridge, parseLanOrigins } from '../bridge.mjs'
import { peer, listen, within } from './helpers.mjs'
import { adapter, root, script, quote, runPS, hostFixture, until } from './lan-helper-support.mjs'

test('DK-06: PowerShell 5.1 unit suite validates producer/filter/configuration/locking', async () => {
  const { stdout } = await runPS(`& ${quote(path.join(root, 'scripts/test/LanCompose.Tests.ps1'))}`)
  const summary = JSON.parse(stdout.split(/\r?\n/).find(line => line.startsWith('SUMMARY ')).slice(8))
  assert.equal(summary.passed, 19)
})

test('DK-06: actual adapter discovery matches Windows host IPv4, not a container interface', async () => {
  const { stdout } = await runPS(`. ${quote(script)}; ConvertTo-Json -InputObject @(Get-LanOrigins -Interfaces @(Get-LanHostInterfaces) -Port 8081) -Compress`)
  const expected = [...new Set(Object.values(networkInterfaces()).flat().filter(entry => entry.family === 'IPv4' && !entry.internal &&
    !entry.address.startsWith('169.254.') && !entry.address.startsWith('127.')).map(entry => `http://${entry.address}:8081`))].sort()
  assert.deepEqual(JSON.parse(stdout), expected)
})

test('DK-06: watcher refreshes timestamp, changes IP, handles offline and rejects duplicate writer', async (t) => {
  const fixture = hostFixture(t, 8099)
  const watcher = await fixture.start()
  const initial = JSON.parse(readFileSync(fixture.filename))
  assert.deepEqual(parseLanOrigins(readFileSync(fixture.filename), 8099), ['http://192.168.10.20:8099'])
  const env = parseEnv(readFileSync(path.join(fixture.lan, 'compose.env'), 'utf8'))
  assert.equal(env.PUBLIC_ORIGIN, '')
  assert.equal(env.LAN_ORIGINS_FILE, '/run/battleship-lan/origins.json')
  assert.equal(env.WEB_PUBLIC_PORT, '8099')
  await assert.rejects(runPS(fixture.bootstrap + `Invoke-LanCompose -ProjectRoot ${quote(fixture.directory)} -Options ${fixture.options}`), error => /already owns/.test(error.stderr))
  await until(() => JSON.parse(readFileSync(fixture.filename)).updatedAt > initial.updatedAt, 'heartbeat')
  fixture.replace([adapter('192.168.20.30'), adapter('10.8.0.3', 'VPN')])
  await until(() => JSON.parse(readFileSync(fixture.filename)).origins[0] === 'http://192.168.20.30:8099', 'IP change')
  fixture.replace([])
  await until(() => JSON.parse(readFileSync(fixture.filename)).origins.length === 0, 'offline')
  fixture.replace([adapter('192.168.30.40')])
  await until(() => JSON.parse(readFileSync(fixture.filename)).origins[0] === 'http://192.168.30.40:8099', 'network recovery')
  assert.equal(watcher.child.exitCode, null)
  assert.match(watcher.output(), /Player URL: http:\/\/192\.168\.20\.30:8099/)
})

test('DK-06: 200 PowerShell renames expose complete JSON and recover from transient Windows open errors', async (t) => {
  const fixture = hostFixture(t)
  await fixture.write(['http://192.168.10.20:8081'])
  let done = false, reads = 0
  const producer = runPS(`. ${quote(script)}; 1..200 | ForEach-Object { Write-LanOrigins ${quote(fixture.filename)} @('http://192.168.20.30:8081') }`).finally(() => { done = true })
  await until(() => {
    let bytes
    try { bytes = readFileSync(fixture.filename) }
    catch (error) {
      // A pending rename can briefly deny opens on Windows; the final file must exist.
      if (!done && ['EBUSY', 'ENOENT'].includes(error.code)) return false
      throw error
    }
    const origins = parseLanOrigins(bytes, 8081)
    assert.ok(['http://192.168.10.20:8081', 'http://192.168.20.30:8081'].includes(origins[0]))
    reads++
    return done
  }, 'atomic producer')
  await producer
  assert.ok(reads > 2)
})

test('DK-06: producer and reader hot update retain two TCP sessions, deadline and identity on resume', async (t) => {
  const fixture = hostFixture(t)
  const watcher = await fixture.start()
  let count = 0
  const sockets = new Set()
  const backend = net.createServer(socket => {
    sockets.add(socket)
    socket.on('close', () => sockets.delete(socket))
    socket.write(`WELCOME 1 P${++count}\n`)
  })
  const tcpPort = await listen(backend)
  t.mock.timers.enable({ apis: ['setInterval'] })
  const bridge = createBridge({ host: '0.0.0.0', publicPort: 8081, tcpPort, lanOriginsFile: fixture.filename })
  const port = await listen(bridge.server)
  t.after(async () => { await bridge.close(); for (const socket of sockets) socket.destroy(); await new Promise(resolve => backend.close(resolve)) })
  const connect = (ip, token = '') => peer(port, '127.0.0.1', token, { origin: `http://${ip}:8081`, headers: { Host: `${ip}:8081` } })
  const first = await connect('192.168.10.20'); await first.wait('WELCOME 1 P1')
  const { token } = await first.meta('SESSION')
  const second = await connect('192.168.10.20'); await second.wait('WELCOME 1 P2')
  fixture.replace([adapter('192.168.20.30')])
  await until(() => JSON.parse(readFileSync(fixture.filename)).origins[0] === 'http://192.168.20.30:8081', 'new IP')
  t.mock.timers.tick(2000)
  assert.equal(first.ws.readyState, 1)
  assert.equal(count, 2)
  first.ws.close(); await within(first.closed)
  const pause = await second.meta('CONNECTION')
  assert.ok(Math.abs(pause.missing[0].deadline - Date.now() - 300000) < 1000)
  await watcher.stop()
  t.mock.method(console, 'error', () => {})
  for (const bytes of ['{', JSON.stringify({ version: 1, updatedAt: Date.now(), origins: ['http://evil.example:8081'] }), 'X'.repeat(8193)]) {
    writeFileSync(fixture.filename, bytes); t.mock.timers.tick(2000)
    assert.deepEqual(bridge.playerOrigins(), [])
    assert.equal(second.ws.readyState, 1)
    assert.equal(count, 2)
  }
  await fixture.write(['http://192.168.20.30:8081']); t.mock.timers.tick(2000)
  second.send('FIRE A1')
  assert.deepEqual(await second.meta('CONNECTION'), pause, 'origin replacement cannot extend the old pause deadline')
  const restored = await connect('192.168.20.30', token)
  const replay = await restored.meta('SESSION')
  assert.equal(replay.token, token)
  assert.ok(replay.frames.includes('WELCOME 1 P1'))
  assert.equal(count, 2, 'resume must reuse TCP P1, not allocate another slot')
})

test('DK-06: Compose starts once while the host heartbeat remains fresh during a long startup', async (t) => {
  const fixture = hostFixture(t)
  const fake = path.join(fixture.directory, 'fake-docker.ps1')
  const compose = path.join(fixture.directory, 'compose.yaml')
  const finished = path.join(fixture.directory, 'finished')
  const argumentsFile = path.join(fixture.directory, 'arguments.json')
  writeFileSync(compose, 'services: {}')
  writeFileSync(fake, `[IO.File]::WriteAllText(${quote(argumentsFile)}, (ConvertTo-Json -InputObject @($args) -Compress)); Start-Sleep -Seconds 11; [IO.File]::WriteAllText(${quote(finished)}, 'done'); exit 0`)
  const code = fixture.bootstrap + `
    $writer = (Get-Item Function:Write-LanOrigins).ScriptBlock;
    function Write-LanOrigins([string]$Path, [string[]]$Origins) {
      & $writer $Path $Origins;
      if ([IO.File]::Exists(${quote(finished)})) { throw 'TEST_STOP_COMPOSE' }
    }
    try { Invoke-LanCompose ${quote(fixture.directory)} @{Mode='Auto'; LanInterface='Wi-Fi'; ConfigDir=${quote(fixture.lan)}; DockerCommand=${quote(fake)}; ComposeFile=${quote(compose)}} }
    catch { if ($_.Exception.Message -notmatch 'TEST_STOP_COMPOSE') { throw }; exit 0 }
  `
  let done = false
  let failure
  const process = runPS(code).catch(error => { failure = error }).finally(() => { done = true })
  const timestamps = new Set()
  await until(() => {
    if (existsSync(fixture.filename)) {
      const data = JSON.parse(readFileSync(fixture.filename))
      assert.ok(Date.now() - data.updatedAt < 5000, 'Compose startup cannot stall the 10-second freshness window')
      timestamps.add(data.updatedAt)
    }
    return done
  }, 'Compose startup and cleanup', 25000)
  await process
  if (failure) throw failure
  assert.ok(timestamps.size >= 4)
  const args = JSON.parse(readFileSync(argumentsFile, 'utf8'))
  assert.equal(args[0], 'compose')
  assert.deepEqual(args.slice(-5), ['up', '-d', '--wait', '--wait-timeout', '60'])
  assert.equal(args[args.indexOf('--env-file') + 1], path.join(fixture.lan, 'compose.env'))
})

test('DK-06: missing Compose and failed Compose report errors without silently continuing', async (t) => {
  const fixture = hostFixture(t)
  await assert.rejects(runPS(fixture.bootstrap + `Invoke-LanCompose ${quote(fixture.directory)} @{}`), error => /Compose file is missing/.test(error.stderr))
  const fake = path.join(fixture.directory, 'failed-docker.ps1')
  const compose = path.join(fixture.directory, 'compose.yaml')
  writeFileSync(compose, 'services: {}'); writeFileSync(fake, 'exit 7')
  await assert.rejects(runPS(fixture.bootstrap + `Invoke-LanCompose ${quote(fixture.directory)} @{Mode='Localhost'; ConfigDir=${quote(fixture.lan)}; DockerCommand=${quote(fake)}; ComposeFile=${quote(compose)}}`), error => /exit 7|startup failed/.test(error.stderr))
})
