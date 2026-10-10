// DK-01 checks deployment artifacts, not future bridge/server or Docker runtime.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { isIP } from 'node:net'
import path from 'node:path'
import { parseEnv } from 'node:util'

const example = readFileSync(new URL('../../.env.example', import.meta.url), 'utf8')
const document = readFileSync(new URL('../../docs/docker_deployment.md', import.meta.url), 'utf8')
const config = parseEnv(example)

test('DK-01: the env example has no malformed lines or duplicate active declarations', () => {
  const declarations = example.split(/\r?\n/).filter((line) => line.trim() && !line.trimStart().startsWith('#'))
  for (const line of declarations) assert.match(line, /^[A-Z][A-Z0-9_]*=[^\r\n]*$/)
  const names = declarations.map((line) => line.slice(0, line.indexOf('=')))
  assert.equal(new Set(names).size, names.length, 'a repeated key can silently overwrite a deployment value')
  assert.equal(Object.keys(config).length, names.length)
})

test('DK-01: container listeners and backend DNS match the two-service contract', () => {
  assert.equal(isIP(config.BATTLESHIP_BIND_HOST), 4)
  assert.equal(config.BATTLESHIP_BIND_HOST, '0.0.0.0')
  assert.equal(isIP(config.HOST), 4)
  assert.equal(config.HOST, '0.0.0.0')
  assert.equal(config.BATTLESHIP_TCP_HOST, 'haskell', 'container loopback cannot reach the other service')
  for (const name of ['BATTLESHIP_TCP_PORT', 'PORT', 'WEB_PUBLIC_PORT']) {
    assert.match(config[name], /^[1-9][0-9]{0,4}$/)
    assert.ok(Number(config[name]) <= 65535, `${name} exceeds the TCP port range`)
  }
})

test('DK-01: the example exercises port mapping and advertises the host port', () => {
  assert.notEqual(config.PORT, config.WEB_PUBLIC_PORT, 'keep the example that exposes an internal/public-port mixup')
  const origin = new URL(config.PUBLIC_ORIGIN)
  assert.equal(origin.protocol, 'http:')
  assert.equal(origin.hostname, 'localhost')
  assert.equal(origin.port || '80', config.WEB_PUBLIC_PORT)
  assert.equal(origin.pathname, '/')
  assert.equal(origin.username + origin.password + origin.search + origin.hash, '')
  assert.equal(origin.origin, config.PUBLIC_ORIGIN, 'use a canonical origin in the example')
})

test('DK-01: the shipped example selects one origin mode and keeps host-only values separate', () => {
  assert.equal(Boolean(config.PUBLIC_ORIGIN) !== Boolean(config.LAN_ORIGINS_FILE), true)
  assert.equal(config.LAN_ORIGINS_FILE, '', 'dynamic mode is an explicit alternative, not active alongside manual mode')
  assert.equal(config.LAN_INTERFACE, '')
  assert.ok(config.LAN_CONFIG_DIR)
  assert.equal(path.posix.isAbsolute(config.BATTLESHIP_READY_FILE), true)
  assert.equal(config.BATTLESHIP_READY_FILE.startsWith('/run/battleship-lan/'), false, 'readiness cannot be written in the read-only LAN mount')
  assert.match(example, /^# LAN_ORIGINS_FILE=\/run\/battleship-lan\/origins\.json$/m)
})

test('DK-01: every active key and nonempty default agrees with the documented configuration table', () => {
  const rows = document.split(/\r?\n/).filter((line) => line.startsWith('| `'))
  const defaults = new Map(rows.map((line) => {
    const cells = line.split('|').slice(1).map((cell) => cell.trim())
    return [cells[0].replaceAll('`', ''), cells[1]]
  }))
  for (const [name, value] of Object.entries(config)) {
    assert.ok(defaults.has(name), `undocumented variable: ${name}`)
    assert.equal(defaults.get(name), value ? '`' + value + '`' : 'Rỗng', `document/example drift: ${name}`)
  }
})

test('DK-01: the LAN JSON example is parseable and uses host origins at the public port', () => {
  const samples = [...document.matchAll(/```json\r?\n([\s\S]*?)\r?\n```/g)]
  assert.equal(samples.length, 1)
  const sample = JSON.parse(samples[0][1])
  assert.deepEqual(Object.keys(sample).sort(), ['origins', 'updatedAt', 'version'])
  assert.equal(sample.version, 1)
  assert.ok(Number.isSafeInteger(sample.updatedAt) && sample.updatedAt > 0)
  assert.ok(Array.isArray(sample.origins) && sample.origins.length > 0 && sample.origins.length <= 16)
  assert.equal(new Set(sample.origins).size, sample.origins.length)
  for (const value of sample.origins) {
    const origin = new URL(value)
    assert.equal(origin.protocol, 'http:')
    assert.equal(isIP(origin.hostname), 4)
    assert.ok(!origin.hostname.startsWith('127.') && !origin.hostname.startsWith('169.254.'))
    assert.ok(!['0.0.0.0', '255.255.255.255'].includes(origin.hostname))
    assert.equal(origin.port || '80', config.WEB_PUBLIC_PORT)
    assert.equal(value, origin.origin)
  }
})
