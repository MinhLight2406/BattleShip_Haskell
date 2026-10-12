import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const cli = process.env.BATTLESHIP_DOCKER_CLI ?? 'docker'
const args = ['compose', '--env-file', '.env.example', '-p', 'battleship-nm09-config', '-f', 'compose.yaml']
const config = (override) => JSON.parse(execFileSync(cli,
  [...args, ...(override ? ['-f', 'compose.report.yaml'] : []), 'config', '--format', 'json'],
  { cwd: root, windowsHide: true, encoding: 'utf8' }))
test('N1 reporting profile preserves services, ports, health, security and LAN config', () => {
  const base = config(false), proposed = config(true)
  assert.deepEqual(Object.keys(proposed.services).sort(), ['haskell', 'web'])
  assert.deepEqual(proposed.services.web, base.services.web)
  assert.deepEqual(proposed.services.haskell.command, ['4000', '+RTS', '-N1', '-RTS'])
  assert.equal(proposed.services.haskell.environment.BATTLESHIP_GAME_CAPABILITY, '0')
  const normalized = structuredClone(proposed.services.haskell)
  normalized.command = base.services.haskell.command
  normalized.environment.BATTLESHIP_GAME_CAPABILITY = base.services.haskell.environment.BATTLESHIP_GAME_CAPABILITY
  assert.deepEqual(normalized, base.services.haskell)
  assert.equal(proposed.services.haskell.cpuset, undefined)
  assert.equal(proposed.services.haskell.ports, undefined)
  execFileSync(cli, [...args, '-f', 'compose.report.yaml', 'config', '--quiet'], { cwd: root, windowsHide: true })
})
