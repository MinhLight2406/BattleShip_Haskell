import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { once } from 'node:events'
import net from 'node:net'
import { before, test } from 'node:test'
import { setTimeout as delay } from 'node:timers/promises'
import { promisify } from 'node:util'
import { peer, within } from '../../frontend/test/helpers.mjs'

const execute = promisify(execFile)
const cli = process.env.BATTLESHIP_DOCKER_CLI ?? 'docker'
const image = process.env.BATTLESHIP_WEB_IMAGE ?? 'battleship-web:dk05'
const backend = process.env.BATTLESHIP_HASKELL_IMAGE ?? 'battleship-haskell:dk04'
const docker = (...args) => execute(cli, args, { windowsHide: true, timeout: 30000, maxBuffer: 1024 * 1024 })

before(async () => {
  assert.equal((await docker('info', '--format', '{{.OSType}}')).stdout.trim(), 'linux')
  for (const name of [image, backend]) await docker('image', 'inspect', name)
})

function resources(t) {
  const containers = [], networks = []
  t.after(async () => {
    for (const name of containers.reverse()) await docker('rm', '--force', name)
    for (const name of networks) await docker('network', 'rm', name)
  })
  return { containers, networks }
}

async function ready(name) {
  await within((async () => {
    for (;;) {
      const state = JSON.parse((await docker('inspect', '--format', '{{json .State}}', name)).stdout)
      if (!state.Running) throw new Error(`Container exited before ready: ${(await docker('logs', name)).stdout}`)
      if (state.Health.Status === 'healthy') return
      await delay(100)
    }
  })(), 'container health', 20000)
}

async function startWeb(t, { pool = resources(t), network, tcpHost = 'haskell', port = 8080 } = {}) {
  const reserve = net.createServer()
  reserve.listen(0, '127.0.0.1')
  await within(once(reserve, 'listening'), 'reserve public port')
  const publicPort = reserve.address().port
  await new Promise((resolve) => reserve.close(resolve))
  assert.notEqual(publicPort, port)
  const name = `battleship-dk05-web-${randomUUID()}`
  const origin = `http://127.0.0.1:${publicPort}`
  await docker('create', '--name', name, '--publish', `127.0.0.1:${publicPort}:${port}`,
    ...(network ? ['--network', network] : []), '--env', `PORT=${port}`,
    '--env', `WEB_PUBLIC_PORT=${publicPort}`, '--env', `PUBLIC_ORIGIN=${origin}`,
    '--env', `BATTLESHIP_TCP_HOST=${tcpHost}`, image)
  pool.containers.push(name)
  await docker('start', name)
  await ready(name)
  return { name, origin, port: publicPort }
}

async function pair(t) {
  const pool = resources(t)
  const network = `battleship-dk05-${randomUUID()}`
  await docker('network', 'create', network)
  pool.networks.push(network)
  const haskell = `battleship-dk05-haskell-${randomUUID()}`
  await docker('create', '--name', haskell, '--network', network, '--network-alias', 'haskell', backend)
  pool.containers.push(haskell)
  await docker('start', haskell)
  await ready(haskell)
  return { ...(await startWeb(t, { pool, network })), haskell }
}

const get = (url) => fetch(url, { signal: AbortSignal.timeout(5000) })

test('DK-05: runtime is pinned Node, non-root and contains only production application files/dependencies', async () => {
  const config = JSON.parse((await docker('image', 'inspect', image)).stdout)[0]
  assert.equal(config.Os, 'linux')
  assert.equal(config.Config.User, 'node')
  assert.deepEqual(config.Config.Entrypoint, ['node', 'bridge.mjs'])
  assert.ok(!config.Config.Cmd?.length)
  const script = String.raw`
    import assert from 'node:assert/strict';
    import fs from 'node:fs';
    import {createRequire} from 'node:module';
    const require = createRequire('/app/bridge.mjs');
    assert.equal(process.version, 'v24.21.0');
    assert.equal(process.getuid(), 1000);
    assert.equal(process.getgid(), 1000);
    assert.deepEqual(fs.readdirSync('/app').sort(), ['bridge.mjs', 'dist', 'node_modules']);
    for (const name of ['react', 'react-dom', 'ws']) require.resolve(name);
    for (const name of ['typescript', 'vite', 'playwright', '@types/node'])
      assert.throws(() => require.resolve(name + '/package.json'));
    const installed = fs.readdirSync('/app/node_modules/.pnpm');
    assert.ok(!installed.some(name => /^(typescript|vite|playwright|@types\+|@typescript\+|@vitejs\+)/.test(name)));
  `
  await docker('run', '--rm', '--network', 'none', '--entrypoint', 'node', image, '--input-type=module', '-e', script)
})

test('DK-05: runtime serves built HTML, JavaScript, CSS and the PNG referenced by CSS', async (t) => {
  const running = await startWeb(t, { port: 8090 })
  const page = await get(running.origin)
  assert.equal(page.status, 200)
  assert.match(page.headers.get('content-type'), /^text\/html/)
  const html = await page.text()
  assert.match(html, /lang="vi"/)
  assert.doesNotMatch(html, /main\.tsx/)
  const assets = [...html.matchAll(/(?:src|href)="([^" ]+\.(?:js|css))"/g)].map(match => match[1])
  assert.ok(assets.some(asset => asset.endsWith('.js')))
  assert.ok(assets.some(asset => asset.endsWith('.css')))
  let css = ''
  for (const asset of assets) {
    const response = await get(new URL(asset, running.origin))
    assert.equal(response.status, 200, asset)
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff')
    assert.match(response.headers.get('content-type'), asset.endsWith('.css') ? /^text\/css/ : /^text\/javascript/)
    const text = await response.text()
    assert.ok(text.length > 100)
    if (asset.endsWith('.css')) css += text
  }
  const pictures = [...css.matchAll(/url\(["']?([^()"']+\.png)["']?\)/g)].map(match => match[1])
  assert.ok(pictures.length, 'the hero image must remain in the built UI')
  for (const picture of pictures) {
    const response = await get(new URL(picture, running.origin))
    assert.equal(response.status, 200, picture)
    assert.equal(response.headers.get('content-type'), 'image/png')
    const bytes = Buffer.from(await response.arrayBuffer())
    assert.deepEqual(bytes.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
  }
  assert.equal((await get(running.origin + '/main.tsx')).status, 404)
  assert.equal((await get(running.origin + '/package.json')).status, 404)
})

test('DK-05: bad runtime configuration exits before listen with a clear diagnostic', async () => {
  for (const [name, value] of [['PORT', '0'], ['HOST', 'http://localhost'],
    ['BATTLESHIP_TCP_HOST', 'haskell:4000'], ['PUBLIC_ORIGIN', 'http://localhost:8080']]) {
    await assert.rejects(docker('run', '--rm', '--network', 'none', '--env', `${name}=${value}`, image), error => {
      assert.equal(error.code, 1)
      assert.equal(error.stdout, '')
      assert.match(error.stderr, /Battleship bridge configuration:/)
      assert.ok(error.stderr.includes(name), error.stderr)
      assert.doesNotMatch(error.stderr, /Unhandled/)
      return true
    })
  }
})

test('DK-05: unavailable backend DNS closes WebSocket clearly while HTTP remains healthy', async (t) => {
  const running = await startWeb(t, { tcpHost: 'missing-battleship.invalid' })
  const client = await peer(running.port)
  assert.equal((await within(client.closed, 'unavailable backend'))[0], 1011)
  assert.deepEqual(await (await get(running.origin + '/healthz')).json(), { status: 'ok' })
  assert.match((await docker('logs', running.name)).stderr, /TCP missing-battleship\.invalid:4000: (ENOTFOUND|EAI_AGAIN)/)
})

for (const signal of ['TERM', 'INT']) test(`DK-05: PID 1 handles SIG${signal} and closes HTTP/WebSocket/real Haskell TCP within deadline`, async (t) => {
  const running = await pair(t)
  for (let count = 0; count < 100; count++)
    assert.deepEqual(await (await get(running.origin + '/healthz')).json(), { status: 'ok' })
  const first = await peer(running.port)
  await first.wait('WELCOME 1 P1')
  const session = await first.meta('SESSION')
  const second = await peer(running.port)
  await second.wait('WELCOME 1 P2')
  let current = first
  if (signal === 'TERM') {
    first.ws.close()
    await within(first.closed)
    const pause = await second.meta('CONNECTION')
    assert.equal(pause.missing[0].player, 'P1')
    assert.ok(Math.abs(pause.missing[0].deadline - Date.now() - 300000) < 1000)
    current = await peer(running.port, '127.0.0.1', session.token)
    assert.ok((await current.meta('SESSION')).frames.includes('WELCOME 1 P1'))
  }
  const http = net.createConnection({ host: '127.0.0.1', port: running.port })
  t.after(() => http.destroy())
  const httpClosed = once(http, 'close')
  http.on('error', () => {})
  await within(once(http, 'connect'))
  const reply = once(http, 'data')
  http.write(`GET /healthz HTTP/1.1\r\nHost: 127.0.0.1:${running.port}\r\nConnection: keep-alive\r\n\r\n`)
  assert.match((await within(reply))[0].toString(), /^HTTP\/1\.1 200/)
  await docker('exec', running.name, 'node', '--input-type=module', '-e',
    "import fs from 'node:fs'; import assert from 'node:assert/strict'; assert.match(fs.readFileSync('/proc/1/cmdline', 'utf8'), /^node\\x00bridge\\.mjs\\x00$/)")
  await docker('kill', '--signal', signal, running.name)
  await within(Promise.all([current.closed, second.closed, httpClosed]), 'HTTP/WS shutdown')
  for (const name of [running.name, running.haskell])
    assert.equal((await within(docker('wait', name), 'container exit')).stdout.trim(), '0')
  await assert.rejects(get(running.origin + '/healthz'))
})
