import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseEnv } from 'node:util'
import { readFileSync } from 'node:fs'
import { resolveAffinity, rtsCommand, parseTasks, verifyContainer, verifyRuntime, parseArguments } from '../start-affinity.mjs'

const topology = (ids = [2, 6, 9]) => ({ inspectionOk: true,
  cpu: { online: [...ids, 12], allowed: ids, effective: ids,
    details: ids.map((id, i) => ({ id, coreId: i === 1 ? 0 : i, socketId: 0 })) },
  memory: { onlineNodes: [3], allowedNodes: [3] } })
const settings = { HASKELL_CPUSET: 'auto', WEB_CPUSET: 'auto', HASKELL_CAPABILITIES: '1', HASKELL_AFFINITY: 'container' }
const tasks = [{ tid: 1, name: 'battleship-serv', allowed: [2] }, { tid: 8, name: 'ghc_worker', allowed: [2] }]
const container = { HostConfig: { CpusetCpus: '2' }, Config: { Cmd: ['4000', '+RTS', '-N1', '-RTS'] }, State: { Running: true } }

test('auto selects permitted IDs and prefers a separate core for web, not an SMT sibling', () => {
  const config = resolveAffinity(topology(), settings)
  assert.deepEqual(config.haskell, [2]); assert.deepEqual(config.web, [9])
  assert.deepEqual(config.environment, { HASKELL_CPUSET: '2', WEB_CPUSET: '9', HASKELL_CAPABILITIES: '1' })
  assert.deepEqual(resolveAffinity(topology([6]), settings).web, [6], 'one-CPU environment shares explicitly')
})

test('noncontiguous masks, ranges and overlapping services are valid in container mode', () => {
  const config = resolveAffinity(topology(), { ...settings, HASKELL_CPUSET: '6,2,6', WEB_CPUSET: '2,9', HASKELL_CAPABILITIES: '2' })
  assert.deepEqual(config.haskell, [2, 6]); assert.deepEqual(config.web, [2, 9])
  assert.deepEqual(rtsCommand(4100, config), ['4100', '+RTS', '-N2', '-RTS'])
})

for (const value of ['', '-1', '2-', '6-2', '1;echo bad', '9999999999', undefined]) {
  test(`rejects invalid CPU syntax ${JSON.stringify(value)}`, () => {
    assert.throws(() => resolveAffinity(topology(), { ...settings, HASKELL_CPUSET: value }))
  })
}
test('offline, outside mask, incomplete topology and bad web mask fail before start', () => {
  for (const config of [{ HASKELL_CPUSET: '3' }, { HASKELL_CPUSET: '12' }, { WEB_CPUSET: '12' }])
    assert.throws(() => resolveAffinity(topology(), { ...settings, ...config }))
  assert.throws(() => resolveAffinity({ ...topology(), inspectionOk: false }, settings))
})
for (const value of ['0', '-1', '1.5', '', '2 -qa', '01', '4', '999999999999999999']) {
  test(`rejects invalid/outside capabilities ${JSON.stringify(value)}`, () => {
    assert.throws(() => resolveAffinity(topology(), { ...settings, HASKELL_CAPABILITIES: value }))
  })
}
test('N must fit the selected Haskell mask, not only the host mask', () => {
  assert.throws(() => resolveAffinity(topology(), { ...settings, HASKELL_CPUSET: '2', HASKELL_CAPABILITIES: '2' }))
})
test('-qa is structured and allowed only for confirmed 0..N-1 mapping with exact N', () => {
  const config = resolveAffinity(topology([0, 1, 2]), { ...settings, HASKELL_CAPABILITIES: '2', HASKELL_AFFINITY: 'rts' })
  assert.deepEqual(config.haskell, [0, 1])
  assert.deepEqual(rtsCommand('4000', config), ['4000', '+RTS', '-N2', '-qa', '-RTS'])
  for (const mask of ['0,2', '1,2', '0-2']) assert.throws(() => resolveAffinity(topology([0, 1, 2]), {
    ...settings, HASKELL_CPUSET: mask, HASKELL_CAPABILITIES: '2', HASKELL_AFFINITY: 'rts' }))
  assert.throws(() => resolveAffinity(topology(), { ...settings, HASKELL_AFFINITY: 'rts' }))
  assert.throws(() => resolveAffinity(topology(), { ...settings, HASKELL_AFFINITY: 'other' }))
})
test('port and CLI reject malformed values without invoking Docker', () => {
  for (const value of ['0', '65536', '4000;echo', '', 'http://host']) assert.throws(() => rtsCommand(value, { capabilities: 1 }))
  for (const args of [['bad'], ['--project', 'other'], ['--docker'], ['--no-build', '--no-build'], ['--unknown']])
    assert.throws(() => parseArguments(args))
  assert.equal(parseArguments(['verify', '--project', 'battleship-affinity-test', '--no-build']).action, 'verify')
})
test('proc status parser preserves kernel CPU IDs and rejects missing masks', () => {
  const text = 'Name:\tserver\nPid:\t1\nCpus_allowed_list:\t2,6\nName:\tghc_worker\nPid:\t8\nCpus_allowed_list:\t6\n'
  assert.deepEqual(parseTasks(text), [{ tid: 1, name: 'server', allowed: [2, 6] }, { tid: 8, name: 'ghc_worker', allowed: [6] }])
  for (const text of ['', 'Name:\tserver\nPid:\t1\n', 'Name:\tserver\nPid:\tbad\nCpus_allowed_list:\t2\n']) assert.throws(() => parseTasks(text))
})
test('requested Docker mask, process/task masks and actual RTS command must agree', () => {
  verifyContainer(container, tasks, [2], container.Config.Cmd)
  assert.throws(() => verifyContainer({ ...container, HostConfig: { CpusetCpus: '6' } }, tasks, [2]))
  assert.throws(() => verifyContainer(container, [{ ...tasks[0], allowed: [2, 6] }], [2]))
  assert.throws(() => verifyContainer(container, tasks, [2], ['4000', '+RTS', '-N2', '-RTS']))
  assert.throws(() => verifyContainer({ ...container, State: { Running: false } }, tasks, [2]))
  assert.throws(() => verifyContainer(container, [tasks[1]], [2]))
})
test('runtime capability and -qa thread evidence are required, not inferred from command', () => {
  const config = { mode: 'rts', capabilities: 2, haskell: [0, 1] }
  const logs = 'Battleship runtime capabilities: 2\n'
  const workers = [{ tid: 1, name: 'server', allowed: [0, 1] }, { tid: 8, name: 'ghc_worker', allowed: [0] }, { tid: 9, name: 'ghc_worker', allowed: [1] }]
  verifyRuntime(logs, workers, config)
  for (const log of ['', 'Battleship runtime capabilities: 1\n', logs + logs]) assert.throws(() => verifyRuntime(log, workers, config))
  assert.throws(() => verifyRuntime(logs, workers.slice(0, 2), config))
  assert.throws(() => verifyRuntime(logs, workers.map(t => ({ ...t, name: 'other' })), config))
})
test('example declares only affinity settings and does not override port/origin deployment', () => {
  const values = parseEnv(readFileSync(new URL('../../.env.performance.example', import.meta.url), 'utf8'))
  assert.deepEqual(values, settings)
  assert.match(readFileSync(new URL('../../.gitignore', import.meta.url), 'utf8'), /!\/\.env\.performance\.example/)
})

test('NM-05 requires the observed worker capability to match the chosen index', () => {
  const config = { mode: 'container', capabilities: 2, haskell: [0, 1], gameCapability: 1 }
  const log = 'Battleship runtime capabilities: 2\nBattleship game worker capability: 1\n'
  verifyRuntime(log, [], config)
  for (const text of ['Battleship runtime capabilities: 2\n', log + 'Battleship game worker capability: 1\n',
    log.replace('worker capability: 1', 'worker capability: 0')]) assert.throws(() => verifyRuntime(text, [], config))
})
