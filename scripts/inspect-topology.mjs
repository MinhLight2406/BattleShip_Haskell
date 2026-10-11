import { readFile, readdir } from 'node:fs/promises'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { pathToFileURL } from 'node:url'

const CPU = '/sys/devices/system/cpu'
const NODE = '/sys/devices/system/node'
const STATUS = '/proc/self/status'
const PERF_EVENTS = ['cycles', 'instructions', 'cache-references', 'cache-misses']
const execute = promisify(execFile)
const intersection = (left, right) => {
  if (left === null || right === null) return null
  const permitted = new Set(right)
  return left.filter((id) => permitted.has(id))
}

// Bound expansion so a malformed range cannot allocate an unbounded array.
export function parseIdList(text) {
  if (typeof text !== 'string' || text.length > 262144 || !text.trim()) {
    throw new Error('Danh sách ID phải có ít nhất một số nguyên không âm.')
  }
  const result = new Set()
  let expanded = 0
  for (const part of text.trim().split(',')) {
    const match = /^(\d+)(?:-(\d+))?$/.exec(part)
    if (!match) throw new Error(`Danh sách ID sai định dạng: ${part.slice(0, 60)}`)
    const from = Number(match[1])
    const to = Number(match[2] ?? match[1])
    if (!Number.isSafeInteger(from) || !Number.isSafeInteger(to) || from > to
      || to > 2147483647 || (expanded += to - from + 1) > 65536) {
      throw new Error('Khoảng ID không hợp lệ hoặc vượt giới hạn 65536 phần tử.')
    }
    for (let id = from; id <= to; id++) result.add(id)
  }
  return [...result].sort((a, b) => a - b)
}

function integer(text, { signed = false } = {}) {
  if (!(signed ? /^-?\d+$/ : /^\d+$/).test(text)) throw new Error('Cần số nguyên.')
  const value = Number(text)
  if (!Number.isSafeInteger(value)) throw new Error('Số nguyên vượt giới hạn.')
  return value
}

export async function probePerformance(run = execute) {
  const events = []
  for (const event of PERF_EVENTS) {
    try {
      const { stderr } = await run('perf', ['stat', '--no-big-num', '-x', ';', '-e', `${event}:u`,
        '--', process.execPath, '-e', 'const end=Date.now()+25; while(Date.now()<end) {}'],
      { timeout: 3000, maxBuffer: 65536, env: { ...process.env, LC_ALL: 'C' } })
      const row = stderr.split('\n').map((line) => line.split(';'))
        .find((fields) => fields[2]?.trim() === `${event}:u`)
      const count = row?.[0]?.trim()
      const usable = Boolean(count && /^\d+(?:\.\d+)?$/.test(count))
      events.push({ event, usable, count: usable ? Number(count) : null,
        reason: usable ? 'Đọc được counter user-space của tiến trình thử.'
          : 'Counter không được hỗ trợ/không được đếm hoặc kết quả perf không xác nhận được.' })
    } catch (error) {
      const reason = error.code === 'ENOENT' ? 'Không có lệnh perf trong môi trường này.'
        : error.killed ? 'Probe perf vượt deadline 3 giây.'
          : `perf thất bại (${error.code ?? 'UNKNOWN'}): ${String(error.stderr ?? error.message).trim().slice(0, 300)}`
      events.push({ event, usable: false, count: null, reason })
      if (error.code === 'ENOENT') {
        for (const remaining of PERF_EVENTS.slice(events.length)) {
          events.push({ event: remaining, usable: false, count: null, reason })
        }
        break
      }
    }
  }
  return { usable: events.every((event) => event.usable), scope: 'per-process user-space probe', events }
}

export async function inspectTopology({ platform = process.platform,
  readText = (file) => readFile(file, 'utf8'), listDirectory = readdir,
  perfProbe = probePerformance } = {}) {
  const diagnostics = []
  const report = { schemaVersion: 1, observedAt: new Date().toISOString(),
    scope: 'linux-visible-current-process', platform, inspectionOk: false,
    environment: { container: null, virtualMachine: null, evidence: [],
      physicalHostTopologyVerified: false },
    cpu: { online: null, allowed: null, effective: null, details: [] },
    memory: { onlineNodes: null, allowedNodes: null, effectiveNodes: null, nodes: [] },
    caches: [], capabilities: {}, diagnostics }
  const note = (code, source, reason) => diagnostics.push({ code, source, reason })
  async function read(file, parser = (text) => text.trim(), quietMissing = false) {
    try { return parser(await readText(file)) } catch (error) {
      if (!quietMissing || error.code !== 'ENOENT') {
        note(error.code ?? 'INVALID_DATA', file, error.code
          ? `Không đọc được nguồn (${error.code}).` : error.message)
      }
      return null
    }
  }
  async function list(dir) {
    try { return (await listDirectory(dir)).sort() } catch (error) {
      note(error.code ?? 'INVALID_DATA', dir, `Không đọc được thư mục (${error.code ?? error.message}).`)
      return []
    }
  }
  if (platform !== 'linux') {
    note('UNSUPPORTED_PLATFORM', 'platform', 'Chạy script trong Linux/WSL/container; không suy CPU Linux từ Windows.')
    report.capabilities = { affinity: { eligible: false, reason: 'Cần môi trường Linux.' },
      multiNodeNuma: { eligible: false, reason: 'Cần topology Linux.' },
      performanceCounters: { usable: null, events: [], reason: 'Chưa probe trên Linux.' } }
    return report
  }

  const status = await read(STATUS, (text) => text)
  function statusList(key) {
    try {
      const value = status?.split('\n').find((line) => line.startsWith(`${key}:`))?.split(':')[1]
      if (value === undefined) throw new Error(`Thiếu trường ${key}.`)
      return parseIdList(value)
    } catch (error) { note('INVALID_DATA', `${STATUS}:${key}`, error.message); return null }
  }
  report.cpu.online = await read(`${CPU}/online`, parseIdList)
  report.cpu.allowed = statusList('Cpus_allowed_list')
  report.cpu.effective = intersection(report.cpu.online, report.cpu.allowed)
  report.memory.onlineNodes = await read(`${NODE}/online`, parseIdList)
  report.memory.allowedNodes = statusList('Mems_allowed_list')
  report.memory.effectiveNodes = intersection(report.memory.onlineNodes, report.memory.allowedNodes)
  // Per-process masks work across cgroup v1/v2 and cgroup/mount namespaces.
  report.sources = { onlineCpus: `${CPU}/online`, allowedCpus: `${STATUS}:Cpus_allowed_list`,
    onlineMemoryNodes: `${NODE}/online`, allowedMemoryNodes: `${STATUS}:Mems_allowed_list`,
    cpuQuotaMeasured: false }

  for (const id of report.memory.onlineNodes ?? []) {
    const root = `${NODE}/node${id}`
    const cpus = await read(`${root}/cpulist`, (text) => text.trim() ? parseIdList(text) : [])
    const memoryBytes = await read(`${root}/meminfo`, (text) => {
      const match = /\bMemTotal:\s+(\d+)\s+kB\b/.exec(text)
      if (!match) throw new Error('Thiếu MemTotal kB của node.')
      const bytes = integer(match[1]) * 1024
      if (!Number.isSafeInteger(bytes)) throw new Error('MemTotal vượt giới hạn.')
      return bytes
    })
    report.memory.nodes.push({ id, cpus, effectiveCpus: intersection(cpus, report.cpu.effective),
      allowed: report.memory.effectiveNodes?.includes(id) ?? null, memoryBytes })
  }
  for (const id of report.cpu.online ?? []) {
    const root = `${CPU}/cpu${id}`
    async function topologyId(name) {
      return read(`${root}/topology/${name}`, (text) => {
        const value = integer(text.trim(), { signed: true })
        if (value === -1) throw new Error('Kernel không cung cấp ID topology (-1).')
        if (value < 0) throw new Error('ID topology âm.')
        return value
      })
    }
    const coreId = await topologyId('core_id')
    const socketId = await topologyId('physical_package_id')
    const siblings = await read(`${root}/topology/thread_siblings_list`, parseIdList)
    if (siblings && !siblings.includes(id)) note('INCONSISTENT_TOPOLOGY', root, 'thread_siblings_list thiếu chính CPU đang đọc.')
    const nodeIds = report.memory.nodes.filter((node) => node.cpus?.includes(id)).map((node) => node.id)
    if (report.memory.onlineNodes && nodeIds.length !== 1) {
      note('INCOMPLETE_NODE_MAPPING', root, `CPU có ${nodeIds.length} node mapping; không tự đoán node.`)
    }
    report.cpu.details.push({ id, allowed: report.cpu.effective?.includes(id) ?? null,
      coreId, socketId, threadSiblings: siblings,
      effectiveThreadSiblings: intersection(siblings, report.cpu.effective), nodeIds })
    for (const index of (await list(`${root}/cache`)).filter((name) => /^index\d+$/.test(name))) {
      const cacheRoot = `${root}/cache/${index}`
      const level = await read(`${cacheRoot}/level`, (text) => {
        const value = integer(text.trim()); if (value < 1) throw new Error('Cache level phải >= 1.'); return value
      })
      const type = await read(`${cacheRoot}/type`, (text) => {
        if (!['Data', 'Instruction', 'Unified'].includes(text.trim())) throw new Error('Cache type không hợp lệ.')
        return text.trim()
      })
      const sharedCpus = await read(`${cacheRoot}/shared_cpu_list`, parseIdList)
      const cacheId = await read(`${cacheRoot}/id`, (text) => integer(text.trim()), true)
      const sizeBytes = await read(`${cacheRoot}/size`, (text) => {
        const match = /^(\d+)([KMG]?)$/.exec(text.trim())
        if (!match) throw new Error('Cache size sai định dạng.')
        const size = integer(match[1]) * 1024 ** ({ '': 0, K: 1, M: 2, G: 3 }[match[2]])
        if (!Number.isSafeInteger(size)) throw new Error('Cache size vượt giới hạn.')
        return size
      })
      const lineBytes = await read(`${cacheRoot}/coherency_line_size`, (text) => integer(text.trim()))
      if (sharedCpus && !sharedCpus.includes(id)) note('INCONSISTENT_TOPOLOGY', cacheRoot, 'Cache sharing list thiếu CPU đang đọc.')
      // Include type + sharing mask; different caches can have the same level.
      const key = level !== null && type && sharedCpus
        ? `${level}:${type}:${cacheId ?? 'unknown'}:${sharedCpus.join(',')}` : cacheRoot
      let cache = report.caches.find((item) => item.key === key)
      if (!cache) {
        cache = { key, id: cacheId, level, type, sizeBytes, lineBytes, sharedCpus,
          effectiveSharedCpus: intersection(sharedCpus, report.cpu.effective), observedFromCpus: [] }
        report.caches.push(cache)
      } else if (cache.sizeBytes !== sizeBytes || cache.lineBytes !== lineBytes) {
        note('INCONSISTENT_TOPOLOGY', cacheRoot, 'Các CPU báo kích thước cache dùng chung khác nhau.')
      }
      cache.observedFromCpus.push(id)
    }
  }

  const evidence = report.environment.evidence
  for (const marker of ['/.dockerenv', '/run/.containerenv']) {
    if (await read(marker, () => true, true)) evidence.push({ layer: 'container', source: marker, detail: 'marker tồn tại' })
  }
  const cgroup = await read('/proc/self/cgroup', (text) => text, true)
  if (cgroup && /docker|containerd|kubepods|libpod|lxc/i.test(cgroup)) {
    evidence.push({ layer: 'container', source: '/proc/self/cgroup', detail: 'Có dấu hiệu runtime container.' })
  }
  const kernel = await read('/proc/sys/kernel/osrelease', (text) => text.trim())
  report.environment.kernelRelease = kernel
  if (kernel && /microsoft|wsl/i.test(kernel)) evidence.push({ layer: 'vm', source: '/proc/sys/kernel/osrelease', detail: 'Kernel WSL/Microsoft.' })
  for (const name of ['sys_vendor', 'product_name']) {
    const value = await read(`/sys/class/dmi/id/${name}`, (text) => text.trim(), true)
    if (value && /kvm|qemu|vmware|virtualbox|virtual machine|xen|bhyve|parallels/i.test(value)) {
      evidence.push({ layer: 'vm', source: `/sys/class/dmi/id/${name}`, detail: value.slice(0, 150) })
    }
  }
  const cpuinfo = await read('/proc/cpuinfo', (text) => text, true)
  if (cpuinfo && /^flags\s*:.*\bhypervisor\b/m.test(cpuinfo)) {
    evidence.push({ layer: 'vm', source: '/proc/cpuinfo', detail: 'CPU có hypervisor flag.' })
  }
  // Missing indicators do not prove bare metal or absence of containers.
  report.environment.container = evidence.some((item) => item.layer === 'container') ? true : null
  report.environment.virtualMachine = evidence.some((item) => item.layer === 'vm') ? true : null
  report.environment.interpretation = 'Chỉ mô tả Linux nhìn thấy; không xác nhận topology máy vật lý bên ngoài VM/container.'

  const affinityEligible = Boolean(report.cpu.effective?.length)
  const usableNodes = report.memory.nodes.filter((node) => node.allowed && node.memoryBytes > 0
    && node.effectiveCpus?.length && node.effectiveCpus.every((id) =>
      report.cpu.details.find((cpu) => cpu.id === id)?.nodeIds.length === 1)).map((node) => node.id)
  report.capabilities.affinity = { eligible: affinityEligible,
    reason: affinityEligible ? 'Có CPU online trong mask tiến trình; launcher còn phải áp dụng và kiểm tra affinity.'
      : 'Không xác nhận được CPU online và được phép.' }
  report.capabilities.multiNodeNuma = { eligible: usableNodes.length >= 2, usableNodes,
    reason: usableNodes.length >= 2 ? 'Ít nhất hai node có RAM và CPU được phép; chưa chứng minh placement/hiệu năng.'
      : 'Không xác nhận được ít nhất hai node có RAM và CPU được phép; chưa thể nghiệm thu local/remote.' }
  const paranoid = await read('/proc/sys/kernel/perf_event_paranoid', (text) => integer(text.trim(), { signed: true }))
  const pmuDevices = await list('/sys/bus/event_source/devices')
  const counters = perfProbe ? await perfProbe() : { usable: null, events: [], reason: 'Bỏ qua probe theo --no-perf; counter chưa được xác minh.' }
  report.capabilities.performanceCounters = { ...counters, perfEventParanoid: paranoid, pmuDevices }
  report.inspectionOk = affinityEligible && Boolean(report.memory.effectiveNodes?.length)
  if (!report.inspectionOk) note('INCOMPLETE_EFFECTIVE_MASKS', 'resources', 'Thiếu mask CPU/RAM đủ tin cậy; dừng preflight.')
  return report
}

export function validateResources(report, { cpus, mems, requireNuma = false } = {}) {
  const errors = []
  const requested = { cpus: null, mems: null, requireNuma }
  for (const [name, input, online, allowed] of [
    ['cpus', cpus, report.cpu.online, report.cpu.allowed],
    ['mems', mems, report.memory.onlineNodes, report.memory.allowedNodes],
  ]) {
    if (input === undefined) continue
    try { requested[name] = parseIdList(input) } catch (error) { errors.push(`${name}: ${error.message}`); continue }
    if (online === null || allowed === null) {
      errors.push(`${name}: thiếu topology/mask được phép; không thể xác nhận cấu hình.`); continue
    }
    for (const id of requested[name]) {
      if (!online.includes(id)) errors.push(`${name}: ID ${id} không tồn tại trong tập online (có thể offline).`)
      else if (!allowed.includes(id)) errors.push(`${name}: ID ${id} nằm ngoài mask được cấp cho tiến trình.`)
      else if (name === 'mems') {
        const node = report.memory.nodes.find((item) => item.id === id)
        if (!node || node.memoryBytes === null || node.memoryBytes <= 0) errors.push(`mems: node ${id} không xác nhận được RAM khả dụng.`)
      }
    }
  }
  if (requireNuma) {
    // A local/remote experiment may pin CPUs to A and allocate RAM only on B.
    if (!report.capabilities.multiNodeNuma?.eligible) {
      errors.push('NUMA: môi trường cần ít nhất hai node có CPU/RAM được phép.')
    }
  }
  return { ok: report.inspectionOk && errors.length === 0, requested, errors }
}

export async function runCli(args, { inspect = inspectTopology, out = console.log } = {}) {
  const options = {}
  let noPerf = false
  try {
    for (let index = 0; index < args.length; index++) {
      const arg = args[index]
      if (arg === '--help') {
        out('node scripts/inspect-topology.mjs [--cpus 2,4-5] [--mems 0,2] [--require-numa] [--no-perf]\nĐọc topology Linux; xuất JSON. Không mở trận, không thay CPU/RAM affinity.')
        return 0
      }
      if (arg === '--no-perf' && !noPerf) { noPerf = true; continue }
      if (arg === '--require-numa' && !options.requireNuma) { options.requireNuma = true; continue }
      if ((arg === '--cpus' || arg === '--mems') && options[arg.slice(2)] === undefined) {
        const value = args[++index]
        parseIdList(value)
        options[arg.slice(2)] = value
      } else throw new Error(`Tham số không hợp lệ hoặc lặp lại: ${arg}`)
    }
  } catch (error) { out(JSON.stringify({ schemaVersion: 1, error: error.message })); return 2 }
  try {
    const report = await inspect({ perfProbe: noPerf ? null : probePerformance })
    report.validation = validateResources(report, options)
    out(JSON.stringify(report, null, 2))
    return report.inspectionOk ? (report.validation.ok ? 0 : 2) : 1
  } catch (error) { out(JSON.stringify({ schemaVersion: 1, error: `Không hoàn tất inspection: ${error.message}` })); return 1 }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await runCli(process.argv.slice(2))
}
