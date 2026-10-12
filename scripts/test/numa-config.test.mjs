import assert from 'node:assert/strict'
import { test } from 'node:test'
import { resolveNuma, numaCommand, parseNumaMaps, parseCpuStat, verifyPlacement, validateFreeMemory, rejectPolicyFailure, parseArguments } from '../start-numa.mjs'
import { comparable } from '../benchmark-numa.mjs'

const topology = () => ({ inspectionOk: true, cpu: { online: [3, 7, 11, 19], allowed: [3, 7, 11], effective: [3, 7, 11],
  details: [3, 7, 11].map(id => ({ id, nodeIds: [id === 11 ? 5 : 2], coreId: id, socketId: id === 11 ? 1 : 0 })) },
  memory: { onlineNodes: [2, 5, 9], allowedNodes: [2, 5], effectiveNodes: [2, 5],
    nodes: [{ id: 2, allowed: true, memoryBytes: 1e9, effectiveCpus: [3, 7] },
      { id: 5, allowed: true, memoryBytes: 1e9, effectiveCpus: [11] }, { id: 9, allowed: false, memoryBytes: 1e9, effectiveCpus: [] }] },
  capabilities: { multiNodeNuma: { eligible: true } } })
const values = { NUMA_PROFILE: 'local', NUMA_CPU_NODE: 'auto', NUMA_MEMORY_NODE: 'auto', HASKELL_CPUSET: 'auto',
  WEB_CPUSET: 'auto', HASKELL_CAPABILITIES: '1', NUMA_MEMORY_POLICY: 'cpuset', NUMA_SYS_NICE: '0', NUMA_MIN_FREE_MIB: '64' }
const config = changes => resolveNuma(topology(), { ...values, ...changes })
const stat = (tid, cpu) => { const f = Array(37).fill('0'); f[0] = 'S'; f[36] = String(cpu); return `${tid} (worker with space) ${f.join(' ')}\n` }
const status = 'Name:\tserver\nPid:\t1\nCpus_allowed_list:\t3\nMems_allowed_list:\t2\n'

test('noncontiguous node/CPU IDs are preserved; local/remote keep CPU/N identical and GHC off', () => {
  const local = config(), remote = config({ NUMA_PROFILE: 'remote' })
  assert.deepEqual(local.haskell, [3]); assert.deepEqual(local.mems, [2]); assert.deepEqual(remote.mems, [5])
  assert.deepEqual(local.haskell, remote.haskell); assert.deepEqual(numaCommand(4000, local), numaCommand(4000, remote))
  assert.equal(local.ghcNuma, null)
  assert.equal(config({ NUMA_PROFILE: 'default' }).mems, null)
  assert.deepEqual(numaCommand(4000, config({ NUMA_PROFILE: 'ghc' })), ['4000', '+RTS', '-N1', '--numa=4', '-RTS'])
})
test('one visible node cannot run remote, even when its ID is not zero', () => {
  const t = topology(); t.memory.allowedNodes = [2]; t.memory.effectiveNodes = [2]; t.memory.nodes[1].allowed = false
  t.capabilities.multiNodeNuma.eligible = false
  assert.doesNotThrow(() => resolveNuma(t, values))
  assert.throws(() => resolveNuma(t, { ...values, NUMA_PROFILE: 'remote' }), /hai .*node/)
})

test('remote needs RAM on B, not permission to execute CPUs on B (memory-only node is valid)', () => {
  const t = topology(); t.cpu.allowed = [3, 7]; t.cpu.effective = [3, 7]
  t.memory.nodes[1].effectiveCpus = []; t.capabilities.multiNodeNuma.eligible = false
  assert.deepEqual(resolveNuma(t, { ...values, NUMA_PROFILE: 'remote' }).mems, [5])
})
for (const change of [{ NUMA_CPU_NODE: '1' }, { NUMA_CPU_NODE: '9' }, { NUMA_MEMORY_NODE: '9' },
  { NUMA_MEMORY_NODE: '1' }, { HASKELL_CPUSET: '11' }, { HASKELL_CPUSET: '19' }, { HASKELL_CAPABILITIES: '3' },
  { NUMA_PROFILE: 'remote', NUMA_MEMORY_NODE: '2' }, { NUMA_MEMORY_NODE: '5' },
  { NUMA_PROFILE: 'default', NUMA_MEMORY_NODE: '2' }, { NUMA_PROFILE: 'default', NUMA_MEMORY_POLICY: 'membind' },
  { NUMA_PROFILE: 'fake' }, { NUMA_SYS_NICE: 'true' }, { NUMA_MEMORY_POLICY: 'preferred' }, { NUMA_MIN_FREE_MIB: '0' },
  { NUMA_MIN_FREE_MIB: '9007199254740991' }, { NUMA_CPU_NODE: '' }, { NUMA_MEMORY_NODE: 'http://2' }]) {
  test(`rejects invalid/outside/inconsistent resource config ${JSON.stringify(change)}`, () => assert.throws(() => config(change)))
}
test('incomplete topology and ambiguous CPU mapping fail closed', () => {
  const t = topology(); t.cpu.details[0].nodeIds = [2, 5]; assert.throws(() => resolveNuma(t, values))
  t.cpu.details[0].nodeIds = [5]; assert.throws(() => resolveNuma(t, values))
  assert.throws(() => resolveNuma({ ...topology(), inspectionOk: false }, values))
})
test('private anonymous pages and file page cache are reported separately, mixed page sizes are not guessed', () => {
  const maps = parseNumaMaps('1000 default file=/lib/libc.so N5=30 kernelpagesize_kB=4\n2000 bind:2 heap anon=7 N2=7 kernelpagesize_kB=64\n')
  assert.deepEqual(maps.privateAnonymousPages, { 2: 7 }); assert.equal(maps.boundPrivatePages, 7)
  assert.equal(maps.rows.length, 2)
  for (const text of ['', 'no-address default N2=1', '2000 default N2=x']) assert.throws(() => parseNumaMaps(text))
})
test('CPU field 39 handles task names containing spaces', () => {
  assert.deepEqual(parseCpuStat(stat(1, 3)), [{ tid: 1, lastCpu: 3 }])
  for (const text of ['', '1 (worker) S 1']) assert.throws(() => parseCpuStat(text))
})
test('CPU mask alone is insufficient: actual CPU, memory mask, resident pages and bind policy must match', () => {
  verifyPlacement(config(), status, stat(1, 3), '1000 default heap anon=2 N2=2')
  assert.throws(() => verifyPlacement(config(), status, stat(1, 11), '1000 default heap anon=2 N2=2'))
  assert.throws(() => verifyPlacement(config(), status.replace('Mems_allowed_list:\t2', 'Mems_allowed_list:\t5'), stat(1, 3), '1000 default heap anon=2 N2=2'))
  assert.throws(() => verifyPlacement(config(), status, stat(1, 3), '1000 default heap anon=2 N5=2'))
  assert.throws(() => verifyPlacement(config(), status, stat(1, 3), '1000 default file=/lib.so N2=2'))
  assert.throws(() => verifyPlacement(config({ NUMA_MEMORY_POLICY: 'membind' }), status, stat(1, 3), '1000 default heap anon=2 N2=2'))
  verifyPlacement(config({ NUMA_MEMORY_POLICY: 'membind' }), status, stat(1, 3), '1000 bind:2 heap anon=2 N2=2')
  assert.throws(() => verifyPlacement(config({ NUMA_MEMORY_POLICY: 'membind' }), status, stat(1, 3), '1000 bind:5 heap anon=2 N2=2'))
})
test('missing/insufficient free RAM cannot be relabelled as supported', () => {
  assert.equal(validateFreeMemory('Node 2 MemFree: 65536 kB', 64 * 1024 * 1024), 64 * 1024 * 1024)
  assert.throws(() => validateFreeMemory('MemFree: 1 kB', 64 * 1024 * 1024))
  assert.throws(() => validateFreeMemory('MemTotal: 99999 kB', 1))
})
test('NUMA syscalls rejected with exit zero are still failures', () => {
  for (const text of ['mbind: Operation not permitted', 'set_mempolicy: Permission denied', 'get_mempolicy failed', 'NUMA not supported', 'This GHC build was compiled without NUMA support.'])
    assert.throws(() => rejectPolicyFailure(text))
  assert.doesNotThrow(() => rejectPolicyFailure('Battleship runtime capabilities: 1'))
})
test('CLI keeps stop accessible and rejects malformed/duplicate options', () => {
  assert.equal(parseArguments(['stop']).action, 'stop')
  for (const args of [['restart'], ['--project', 'other'], ['--numa-file'], ['--no-build', '--no-build']]) assert.throws(() => parseArguments(args))
})

test('local/remote comparison refuses changes to CPU, N, policy or GHC RTS mode', () => {
  const local = config(), remote = config({ NUMA_PROFILE: 'remote' })
  comparable(local, remote)
  for (const change of [{ haskell: [7] }, { capabilities: 2 }, { policy: 'membind' }, { ghcNuma: '--numa=4' }, { mems: [2] }])
    assert.throws(() => comparable(local, { ...remote, ...change }))
})
