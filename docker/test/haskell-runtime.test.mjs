import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { EventEmitter, once } from 'node:events'
import net from 'node:net'
import { before, test } from 'node:test'
import { setTimeout as delay } from 'node:timers/promises'
import { promisify } from 'node:util'

const execute = promisify(execFile)
const cli = process.env.BATTLESHIP_DOCKER_CLI ?? 'docker'
const image = process.env.BATTLESHIP_HASKELL_IMAGE ?? 'battleship-haskell:dk04'
const docker = (...args) => execute(cli, args, { windowsHide: true, timeout: 30000, maxBuffer: 1024 * 1024 })

function within(promise, label, ms = 10000) {
  let timer
  return Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} exceeded ${ms} ms`)), ms)
  })]).finally(() => clearTimeout(timer))
}

before(async () => {
  try {
    const { stdout, stderr } = await docker('info', '--format', '{{.OSType}}')
    assert.equal(stdout.trim(), 'linux', `DK-04 requires a running Linux Docker Engine. ${stderr}`)
    await docker('image', 'inspect', image)
  } catch (error) {
    throw new Error(`DK-04 needs Docker Engine and the built image ${image}; this gate cannot be skipped. ${error.stderr ?? error.message}`)
  }
})

async function start(t, port = 4000, marker = '/tmp/battleship-ready') {
  const name = `battleship-dk04-${randomUUID()}`
  t.after(() => docker('rm', '--force', name))
  await docker('run', '--detach', '--name', name, '--publish', `127.0.0.1::${port}`,
    '--env', `BATTLESHIP_READY_FILE=${marker}`, image, ...(port === 4000 ? [] : [String(port)]))
  await within((async () => {
    for (;;) {
      const { stdout } = await docker('inspect', '--format', '{{json .State}}', name)
      const state = JSON.parse(stdout)
      if (!state.Running) throw new Error(`server exited before ready: ${(await docker('logs', name)).stdout}`)
      if (state.Health.Status === 'healthy') break
      await delay(100)
    }
  })(), 'marker readiness', 20000)
  const { stdout } = await docker('port', name, `${port}/tcp`)
  const mapping = /^127\.0\.0\.1:(\d+)\s*$/.exec(stdout)
  assert.ok(mapping, `unexpected publish mapping: ${stdout}`)
  return { name, port: Number(mapping[1]), marker }
}

async function client(t, port) {
  const socket = net.createConnection({ host: '127.0.0.1', port })
  t.after(() => socket.destroy())
  const changed = new EventEmitter(), lines = []
  let buffer = '', ended = false, failure
  const closed = new Promise((resolve) => socket.once('close', resolve))
  socket.on('data', (bytes) => {
    buffer += bytes.toString('ascii')
    let index
    while ((index = buffer.indexOf('\n')) >= 0) {
      lines.push(buffer.slice(0, index).replace(/\r$/, ''))
      buffer = buffer.slice(index + 1)
    }
    changed.emit('update')
  })
  socket.on('error', (error) => { failure = error; changed.emit('update') })
  socket.on('close', () => { ended = true; changed.emit('update') })
  await within(once(socket, 'connect'), 'TCP connect')
  return {
    socket, closed,
    read: () => within((async () => {
      while (!lines.length) {
        if (failure) throw failure
        if (ended) throw new Error(`TCP closed without the expected frame; tail: ${buffer}`)
        await once(changed, 'update')
      }
      return lines.shift()
    })(), 'TCP frame'),
  }
}

async function assertStopped(name, marker) {
  assert.equal((await within(docker('wait', name), 'server exit')).stdout.trim(), '0')
  await assert.rejects(docker('cp', `${name}:${marker}`, '-'), (error) =>
    error.code === 1 && /could not find|no such|not found/i.test(error.stderr))
}

test('DK-04: runtime is Linux, non-root, has dynamic dependencies and contains no toolchain', async () => {
  const config = JSON.parse((await docker('image', 'inspect', image)).stdout)[0]
  assert.equal(config.Os, 'linux')
  assert.equal(config.Config.User, '10001:10001')
  assert.deepEqual(config.Config.Entrypoint, ['/usr/local/bin/battleship-server'])
  assert.deepEqual(config.Config.Cmd, ['4000'])
  assert.ok(config.Config.Env.includes('BATTLESHIP_BIND_HOST=0.0.0.0'))
  const { stdout } = await docker('run', '--rm', '--network', 'none', '--entrypoint', 'sh', image, '-ec',
    'test "$(id -u)" = 10001; test "$(id -g)" = 10001; ' +
    'ldd /usr/local/bin/battleship-server > /tmp/dependencies; cat /tmp/dependencies; ' +
    'if grep -q "not found" /tmp/dependencies; then exit 1; fi; ' +
    'if command -v ghc || command -v stack; then exit 1; fi; ' +
    'test ! -e /build; /usr/local/bin/battleship-server --help')
  assert.match(stdout, /Usage: battleship-server/)
})

test('DK-04: runtime rejects malformed bind configuration before opening a listener', async () => {
  await assert.rejects(docker('run', '--rm', '--network', 'none', '--env',
    'BATTLESHIP_BIND_HOST=http://localhost:4000', image), (error) => {
    assert.equal(error.code, 1)
    assert.equal(error.stdout, '')
    assert.match(error.stderr, /BATTLESHIP_BIND_HOST/)
    return true
  })
})

for (const port of [4000, 4500]) test(`DK-04: real server on port ${port} keeps health out of slots and cleans up after Quit`, async (t) => {
  const marker = port === 4000 ? '/tmp/battleship-ready' : '/tmp/dk04-custom-ready'
  const running = await start(t, port, marker)
  await docker('exec', running.name, 'sh', '-ec',
    'i=0; while [ "$i" -lt 100 ]; do test "$(cat "$BATTLESHIP_READY_FILE")" = ready; i=$((i+1)); done')
  const first = await client(t, running.port)
  assert.equal(await first.read(), 'WELCOME 1 P1')
  const second = await client(t, running.port)
  assert.equal(await second.read(), 'WELCOME 1 P2')
  const third = await client(t, running.port)
  assert.equal(await third.read(), 'ERROR SERVER_FULL')
  await within(third.closed, 'third client EOF')
  first.socket.write('QUIT\n')
  assert.equal(await first.read(), 'GAME_OVER P2 OPPONENT_LEFT')
  assert.equal(await second.read(), 'GAME_OVER P2 OPPONENT_LEFT')
  await within(Promise.all([first.closed, second.closed]), 'player EOF')
  await assertStopped(running.name, running.marker)
})

test('DK-04: SIGTERM reaches PID 1, removes readiness and closes both clients cleanly', async (t) => {
  const running = await start(t)
  const first = await client(t, running.port)
  assert.equal(await first.read(), 'WELCOME 1 P1')
  const second = await client(t, running.port)
  assert.equal(await second.read(), 'WELCOME 1 P2')
  await docker('kill', '--signal', 'TERM', running.name)
  await within(Promise.all([first.closed, second.closed]), 'SIGTERM client cleanup')
  await assertStopped(running.name, running.marker)
})
