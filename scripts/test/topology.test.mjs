import { test } from 'node:test'
import assert from 'node:assert/strict'
import { inspectTopology, parseIdList, probePerformance, runCli, validateResources } from '../inspect-topology.mjs'

const CPU = '/sys/devices/system/cpu'
const NODE = '/sys/devices/system/node'
const STATUS = '/proc/self/status'
const unavailablePerf = async () => ({ usable: false, events: [], reason: 'fixture không có perf' })

function fixture({ cpus = [2, 6], allowed = cpus, nodes = [{ id: 3, cpus }],
  allowedNodes = nodes.map((node) => node.id), smt = false } = {}) {
  const files = new Map([
    [`${CPU}/online`, cpus.join(',')], [`${NODE}/online`, nodes.map((node) => node.id).join(',')],
    [STATUS, `Cpus_allowed_list:\t${allowed.join(',')}\nMems_allowed_list:\t${allowedNodes.join(',')}\n`],
    ['/proc/sys/kernel/osrelease', '6.8.0-fixture'], ['/proc/self/cgroup', '0::/user.slice/task'],
    ['/proc/sys/kernel/perf_event_paranoid', '2'], ['/proc/cpuinfo', 'flags : sse2\n'],
  ])
  for (const node of nodes) {
    files.set(`${NODE}/node${node.id}/cpulist`, node.cpus.join(','))
    files.set(`${NODE}/node${node.id}/meminfo`, `Node ${node.id} MemTotal: 1048576 kB\n`)
  }
  for (const id of cpus) {
    files.set(`${CPU}/cpu${id}/topology/core_id`, String(smt ? 7 : id))
    files.set(`${CPU}/cpu${id}/topology/physical_package_id`, '1')
    files.set(`${CPU}/cpu${id}/topology/thread_siblings_list`, (smt ? cpus : [id]).join(','))
    const root = `${CPU}/cpu${id}/cache/index0`
    files.set(`${root}/level`, '3')
    files.set(`${root}/type`, 'Unified')
    files.set(`${root}/shared_cpu_list`, cpus.join(','))
    files.set(`${root}/size`, '8M')
    files.set(`${root}/coherency_line_size`, '64')
  }
  const io = {
    platform: 'linux', perfProbe: unavailablePerf,
    readText: async (file) => {
      if (!files.has(file)) throw Object.assign(new Error('missing fixture'), { code: 'ENOENT' })
      const value = files.get(file)
      if (value instanceof Error) throw value
      return value
    },
    listDirectory: async (dir) => {
      if (dir === '/sys/bus/event_source/devices') return ['software', 'cpu']
      const children = [...files.keys()].filter((key) => key.startsWith(`${dir}/`))
        .map((key) => key.slice(dir.length + 1).split('/')[0])
      if (!children.length) throw Object.assign(new Error('missing directory'), { code: 'ENOENT' })
      return [...new Set(children)]
    },
  }
  return { files, io, inspect: () => inspectTopology(io) }
}

test('ID lists normalize ranges, duplicates and sparse IDs without assuming CPU 0', () => {
  assert.deepEqual(parseIdList(' 2,6-8,6,21\n'), [2, 6, 7, 8, 21])
  assert.deepEqual(parseIdList('2147483647'), [2147483647])
})
for (const value of ['', ' ', '-1', '4-2', '1,', ',1', '1,,2', '1, 2', '1.5', 'A1', '1-2-3',
  '0-65536', '9007199254740993', '2147483648', undefined]) {
  test(`reject malformed or unbounded ID list ${JSON.stringify(value)}`, () => assert.throws(() => parseIdList(value)))
}

test('one visible node is eligible for affinity, not for multi-node NUMA or a physical-host claim', async () => {
  const report = await fixture().inspect()
  assert.equal(report.inspectionOk, true)
  assert.deepEqual(report.cpu.effective, [2, 6])
  assert.deepEqual(report.memory.effectiveNodes, [3])
  assert.equal(report.capabilities.affinity.eligible, true)
  assert.equal(report.capabilities.multiNodeNuma.eligible, false)
  assert.equal(report.environment.physicalHostTopologyVerified, false)
  assert.equal(report.environment.container, null)
  assert.equal(report.environment.virtualMachine, null)
  assert.equal(validateResources(report, { requireNuma: true }).ok, false)
})

test('multiple sparse nodes support local/remote selection with CPUs on A and RAM on B', async () => {
  const report = await fixture({ nodes: [{ id: 3, cpus: [2] }, { id: 9, cpus: [6] }] }).inspect()
  assert.deepEqual(report.capabilities.multiNodeNuma.usableNodes, [3, 9])
  assert.equal(report.capabilities.multiNodeNuma.eligible, true)
  assert.deepEqual(report.cpu.details.map((cpu) => cpu.nodeIds), [[3], [9]])
  assert.equal(validateResources(report, { cpus: '2', mems: '9', requireNuma: true }).ok, true)
})

test('online CPUs outside the process mask and offline IDs are rejected separately', async () => {
  const report = await fixture({ cpus: [2, 6, 21], allowed: [6] }).inspect()
  assert.deepEqual(report.cpu.effective, [6])
  const invalid = validateResources(report, { cpus: '2,6,7' })
  assert.equal(invalid.ok, false)
  assert.equal(invalid.errors.length, 2)
  assert.match(invalid.errors[0], /ID 2.*ngoài mask/)
  assert.match(invalid.errors[1], /ID 7.*online/)
  assert.equal(validateResources(report, { cpus: '6' }).ok, true)
})

test('SMT retains two logical CPUs with the same socket/core and intersects allowed siblings', async () => {
  const report = await fixture({ smt: true, allowed: [6] }).inspect()
  assert.deepEqual(report.cpu.details.map((cpu) => [cpu.socketId, cpu.coreId]), [[1, 7], [1, 7]])
  assert.deepEqual(report.cpu.details[0].threadSiblings, [2, 6])
  assert.deepEqual(report.cpu.details[0].effectiveThreadSiblings, [6])
})

test('core IDs can repeat in different sockets without merging the cores', async () => {
  const setup = fixture({ smt: true })
  setup.files.set(`${CPU}/cpu6/topology/physical_package_id`, '4')
  setup.files.set(`${CPU}/cpu2/topology/thread_siblings_list`, '2')
  setup.files.set(`${CPU}/cpu6/topology/thread_siblings_list`, '6')
  const report = await setup.inspect()
  assert.deepEqual(report.cpu.details.map((cpu) => [cpu.socketId, cpu.coreId]), [[1, 7], [4, 7]])
})

test('nonexistent and disallowed memory nodes cannot pass preflight', async () => {
  const report = await fixture({ nodes: [{ id: 3, cpus: [2] }, { id: 9, cpus: [6] }], allowedNodes: [3] }).inspect()
  const result = validateResources(report, { mems: '9,10' })
  assert.equal(result.ok, false)
  assert.match(result.errors[0], /ID 9.*ngoài mask/)
  assert.match(result.errors[1], /ID 10.*online/)
  assert.equal(report.capabilities.multiNodeNuma.eligible, false)
})

test('memory-only nodes are valid RAM targets but do not establish a second CPU/RAM NUMA locality', async () => {
  const report = await fixture({ nodes: [{ id: 3, cpus: [2, 6] }, { id: 9, cpus: [] }] }).inspect()
  assert.equal(validateResources(report, { mems: '9' }).ok, true)
  assert.equal(report.capabilities.multiNodeNuma.eligible, false)
})

for (const [file, value] of [
  [`${CPU}/online`, null], [`${CPU}/online`, '2-no'],
  [STATUS, 'Mems_allowed_list: 3\n'], [STATUS, 'Cpus_allowed_list: 2,6\nMems_allowed_list: nope\n'],
  [`${NODE}/online`, null], [STATUS, Object.assign(new Error('denied'), { code: 'EACCES' })],
]) {
  test(`missing/malformed mask fails closed: ${file} ${String(value)}`, async () => {
    const setup = fixture()
    if (value === null) setup.files.delete(file); else setup.files.set(file, value)
    const report = await setup.inspect()
    assert.equal(report.inspectionOk, false)
    assert.equal(validateResources(report, { cpus: '2', mems: '3' }).ok, false)
    assert.ok(report.diagnostics.some((item) => item.source.startsWith(file)))
  })
}

test('unknown core/socket IDs and hidden cache produce explicit partial information', async () => {
  const setup = fixture()
  setup.files.set(`${CPU}/cpu2/topology/core_id`, '-1')
  setup.files.delete(`${CPU}/cpu2/topology/physical_package_id`)
  setup.files.delete(`${CPU}/cpu2/topology/thread_siblings_list`)
  for (const file of [...setup.files.keys()]) if (file.startsWith(`${CPU}/cpu2/cache/`)) setup.files.delete(file)
  const report = await setup.inspect()
  assert.equal(report.inspectionOk, true, 'missing optional topology must not disable a valid CPU mask')
  assert.equal(report.cpu.details[0].coreId, null)
  assert.equal(report.cpu.details[0].socketId, null)
  assert.equal(report.cpu.details[0].threadSiblings, null)
  assert.ok(report.diagnostics.some((item) => item.reason.includes('(-1)')))
  assert.ok(report.diagnostics.some((item) => item.source === `${CPU}/cpu2/cache`))
})

test('zero or unknown RAM and ambiguous CPU/node mapping cannot certify multi-node NUMA', async () => {
  for (const content of ['Node 9 MemTotal: 0 kB', 'corrupt']) {
    const setup = fixture({ nodes: [{ id: 3, cpus: [2] }, { id: 9, cpus: [6] }] })
    setup.files.set(`${NODE}/node9/meminfo`, content)
    const report = await setup.inspect()
    assert.equal(report.capabilities.multiNodeNuma.eligible, false)
    assert.equal(validateResources(report, { mems: '9' }).ok, false)
  }
  const report = await fixture({ nodes: [{ id: 3, cpus: [2, 6] }, { id: 9, cpus: [6] }] }).inspect()
  assert.equal(report.capabilities.multiNodeNuma.eligible, false)
  assert.ok(report.diagnostics.some((item) => item.code === 'INCOMPLETE_NODE_MAPPING'))
})

test('shared cache is deduplicated while retaining full and effective CPU masks', async () => {
  const report = await fixture({ allowed: [6] }).inspect()
  assert.equal(report.caches.length, 1)
  const cache = report.caches[0]
  assert.deepEqual(cache.sharedCpus, [2, 6])
  assert.deepEqual(cache.effectiveSharedCpus, [6])
  assert.deepEqual(cache.observedFromCpus, [2, 6])
  assert.equal(cache.sizeBytes, 8 * 1024 * 1024)
  assert.equal(cache.lineBytes, 64)
})

test('cache types/levels are not merged and plain-byte sizes are not mistaken for KiB', async () => {
  const setup = fixture()
  const prefix = `${CPU}/cpu2/cache/`
  for (const [name, value] of [['level', '3'], ['type', 'Instruction'], ['shared_cpu_list', '2'],
    ['size', '256'], ['coherency_line_size', '64']]) setup.files.set(`${prefix}index1/${name}`, value)
  const report = await setup.inspect()
  assert.equal(report.caches.length, 2)
  assert.equal(report.caches.find((cache) => cache.type === 'Instruction').sizeBytes, 256)
})

test('malformed optional cache information is null with a diagnostic, never silently invented', async () => {
  const setup = fixture()
  setup.files.set(`${CPU}/cpu2/cache/index0/size`, '8MB')
  setup.files.set(`${CPU}/cpu2/cache/index0/shared_cpu_list`, 'bad')
  const report = await setup.inspect()
  assert.equal(report.caches[0].sizeBytes, null)
  assert.equal(report.caches[0].sharedCpus, null)
  assert.ok(report.diagnostics.some((item) => item.code === 'INVALID_DATA' && item.source.endsWith('/size')))
})

test('cache instance IDs distinguish caches even when type, level and sharing mask match', async () => {
  const setup = fixture()
  for (const cpu of [2, 6]) {
    const root = `${CPU}/cpu${cpu}/cache/index0`
    setup.files.set(`${root}/id`, '13')
    for (const name of ['level', 'type', 'shared_cpu_list', 'size', 'coherency_line_size']) {
      setup.files.set(`${CPU}/cpu${cpu}/cache/index1/${name}`, setup.files.get(`${root}/${name}`))
    }
    setup.files.set(`${CPU}/cpu${cpu}/cache/index1/id`, '29')
  }
  const report = await setup.inspect()
  assert.deepEqual(report.caches.map((cache) => cache.id), [13, 29])
  assert.ok(report.caches.every((cache) => cache.observedFromCpus.length === 2))
})

test('empty effective CPU masks fail inspection instead of falling back to all online CPUs', async () => {
  const report = await fixture({ allowed: [21] }).inspect()
  assert.deepEqual(report.cpu.effective, [])
  assert.equal(report.inspectionOk, false)
  assert.equal(report.capabilities.affinity.eligible, false)
  assert.equal(validateResources(report, { cpus: '2' }).ok, false)
})

test('missing NUMA cpulist keeps CPU affinity available but never guesses CPU/node mapping', async () => {
  const setup = fixture()
  setup.files.delete(`${NODE}/node3/cpulist`)
  const report = await setup.inspect()
  assert.equal(report.capabilities.affinity.eligible, true)
  assert.deepEqual(report.cpu.details[0].nodeIds, [])
  assert.deepEqual(report.capabilities.multiNodeNuma.usableNodes, [])
  assert.ok(report.diagnostics.some((item) => item.source.endsWith('/cpulist')))
})

test('container inside WSL/VM is represented as two layers, not a Linux physical host', async () => {
  const setup = fixture()
  setup.files.set('/.dockerenv', '')
  setup.files.set('/proc/sys/kernel/osrelease', '6.6.87.2-microsoft-standard-WSL2')
  const report = await setup.inspect()
  assert.equal(report.environment.container, true)
  assert.equal(report.environment.virtualMachine, true)
  assert.equal(report.environment.physicalHostTopologyVerified, false)
  assert.equal(report.memory.onlineNodes.length, 1)
})

test('VM with hidden DMI and missing cache remains partial without a fabricated bare-metal claim', async () => {
  const setup = fixture()
  setup.files.set('/proc/cpuinfo', 'flags : sse2 hypervisor\n')
  setup.files.set('/sys/class/dmi/id/product_name', Object.assign(new Error('denied'), { code: 'EACCES' }))
  for (const file of [...setup.files.keys()]) if (file.includes('/cache/')) setup.files.delete(file)
  const report = await setup.inspect()
  assert.equal(report.environment.virtualMachine, true)
  assert.equal(report.environment.container, null)
  assert.deepEqual(report.caches, [])
  assert.ok(report.diagnostics.some((item) => item.code === 'EACCES'))
})

test('Docker cgroup evidence detects a container without a marker', async () => {
  const setup = fixture()
  setup.files.set('/proc/self/cgroup', '0::/system.slice/docker-fixture.scope\n')
  setup.files.set('/sys/class/dmi/id/product_name', 'KVM')
  const report = await setup.inspect()
  assert.equal(report.environment.container, true)
  assert.equal(report.environment.virtualMachine, true)
})

test('no perf probe is unknown even with PMU files and permissive paranoid policy', async () => {
  const setup = fixture()
  setup.files.set('/proc/sys/kernel/perf_event_paranoid', '-1')
  const report = await inspectTopology({ ...setup.io, perfProbe: null })
  assert.equal(report.capabilities.performanceCounters.usable, null)
  assert.equal(report.capabilities.performanceCounters.perfEventParanoid, -1)
  assert.deepEqual(report.capabilities.performanceCounters.pmuDevices, ['cpu', 'software'])
})

test('perf checks all required events with bounded subprocesses and no shell', async () => {
  const calls = []
  const result = await probePerformance(async (command, args, options) => {
    calls.push({ command, args, options })
    return { stderr: `123;;${args[args.indexOf('-e') + 1]};100;100.00;\n` }
  })
  assert.equal(result.usable, true)
  assert.equal(result.events.length, 4)
  assert.ok(calls.every((call) => call.command === 'perf' && call.options.timeout === 3000 && !call.options.shell))
  assert.deepEqual(result.events.map((event) => event.count), [123, 123, 123, 123])
})

test('perf missing, denied, timeout, unsupported and uncounted are distinct failed evidence', async () => {
  for (const [error, expected] of [
    [Object.assign(new Error('missing'), { code: 'ENOENT' }), /Không có lệnh perf/],
    [Object.assign(new Error('denied'), { code: 255, stderr: 'No permission to enable cycles:u event.' }), /permission/],
    [Object.assign(new Error('timeout'), { killed: true }), /deadline/],
  ]) {
    const report = await probePerformance(async () => { throw error })
    assert.equal(report.usable, false)
    assert.equal(report.events.length, 4)
    assert.ok(report.events.every((event) => event.count === null && expected.test(event.reason)))
  }
  for (const count of ['<not supported>', '<not counted>']) {
    const report = await probePerformance(async (_command, args) => ({ stderr: `${count};;${args[args.indexOf('-e') + 1]};\n` }))
    assert.equal(report.usable, false)
    assert.ok(report.events.every((event) => event.count === null))
  }
})

test('mixed perf results cannot certify all the counters required for a benchmark', async () => {
  const report = await probePerformance(async (_command, args) => {
    const event = args[args.indexOf('-e') + 1]
    return { stderr: `${event === 'cache-misses:u' ? '<not supported>' : '123'};;${event};\n` }
  })
  assert.equal(report.usable, false)
  assert.equal(report.events[0].usable, true)
  assert.equal(report.events[3].usable, false)
})

test('non-Linux returns a structured unsupported report without reading Linux files', async () => {
  const report = await inspectTopology({ platform: 'win32', readText: () => assert.fail('must not read') })
  assert.equal(report.inspectionOk, false)
  assert.equal(report.capabilities.performanceCounters.usable, null)
  assert.equal(report.diagnostics[0].code, 'UNSUPPORTED_PLATFORM')
})

test('CLI rejects bad arguments before inspecting or probing the machine', async () => {
  for (const args of [['--cpus'], ['--cpus', '2-1'], ['--mems', ''], ['--unknown'],
    ['--cpus', '2', '--cpus', '6'], ['--no-perf', '--no-perf']]) {
    const lines = []
    const exit = await runCli(args, { inspect: () => assert.fail('must fail before IO'), out: (line) => lines.push(line) })
    assert.equal(exit, 2)
    assert.match(JSON.parse(lines[0]).error, /ID|Tham số/)
  }
})

test('CLI emits valid JSON with exit codes for accepted, rejected and incomplete inspections', async () => {
  for (const [args, setup, expected] of [
    [['--cpus', '6', '--mems', '3', '--no-perf'], fixture(), 0],
    [['--cpus', '0', '--no-perf'], fixture(), 2],
    [['--require-numa', '--no-perf'], fixture(), 2],
    [['--no-perf'], fixture(), 1],
  ]) {
    if (expected === 1) setup.files.delete(STATUS)
    const lines = []
    const exit = await runCli(args, { inspect: (options) => inspectTopology({ ...setup.io, ...options }), out: (line) => lines.push(line) })
    assert.equal(exit, expected)
    const report = JSON.parse(lines[0])
    assert.equal(report.schemaVersion, 1)
    assert.equal(report.validation.ok, expected === 0)
    assert.equal(report.capabilities.performanceCounters.usable, null)
  }
})

test('CLI handles unexpected IO failure and help without launching a game', async () => {
  const lines = []
  assert.equal(await runCli([], { inspect: async () => { throw new Error('fixture unexpected') }, out: (line) => lines.push(line) }), 1)
  assert.match(JSON.parse(lines[0]).error, /fixture unexpected/)
  assert.equal(await runCli(['--help'], { inspect: () => assert.fail(), out: (line) => lines.push(line) }), 0)
  assert.match(lines[1], /Không mở trận/)
})
