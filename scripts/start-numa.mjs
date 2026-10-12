import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseEnv, promisify } from 'node:util'
import { parseIdList, validateResources } from './inspect-topology.mjs'
import { resolveAffinity, rtsCommand, parseTasks, verifyRuntime } from './start-affinity.mjs'

const execute = promisify(execFile)
const root = fileURLToPath(new URL('../', import.meta.url))
const equal = (a, b) => assert.deepEqual(a, b)
const positive = (text, label) => {
  assert.match(text ?? '', /^[1-9]\d*$/, `${label}: cần số nguyên dương.`)
  const n = Number(text); assert.ok(Number.isSafeInteger(n), `${label}: vượt giới hạn.`); return n
}
function nodeId(text, label) {
  assert.match(text ?? '', /^(0|[1-9]\d*)$/, `${label}: cần một node ID không âm hoặc auto.`)
  const n = Number(text); assert.ok(Number.isSafeInteger(n), `${label}: vượt giới hạn.`); return n
}

export function canRemote(topology) {
  return topology.inspectionOk && topology.memory.nodes.filter(n => n.allowed && n.memoryBytes > 0).length >= 2
}

export function resolveNuma(topology, values) {
  assert.ok(topology.inspectionOk, 'Không xác nhận được topology/mask Linux.')
  const profile = values.NUMA_PROFILE
  assert.ok(['default', 'local', 'remote', 'ghc'].includes(profile), 'NUMA_PROFILE: default|local|remote|ghc.')
  const nodes = topology.memory.nodes.filter(n => n.allowed && n.memoryBytes > 0 && n.effectiveCpus?.length)
  assert.ok(nodes.length, 'Không có node CPU/RAM được cấp.')
  const cpuNode = values.NUMA_CPU_NODE === 'auto' ? nodes[0].id : nodeId(values.NUMA_CPU_NODE, 'NUMA_CPU_NODE')
  const node = nodes.find(n => n.id === cpuNode)
  assert.ok(node, 'CPU node không tồn tại, thiếu RAM/CPU hoặc ngoài phạm vi được cấp.')
  const n = positive(values.HASKELL_CAPABILITIES, 'HASKELL_CAPABILITIES')
  const haskell = values.HASKELL_CPUSET === 'auto' ? node.effectiveCpus.slice(0, n) : parseIdList(values.HASKELL_CPUSET)
  assert.ok(haskell.every(id => node.effectiveCpus.includes(id)
    && topology.cpu.details.find(c => c.id === id)?.nodeIds?.length === 1
    && topology.cpu.details.find(c => c.id === id).nodeIds[0] === cpuNode), 'CPU không thuộc duy nhất node A đã chọn.')
  const affinity = resolveAffinity(topology, { ...values, HASKELL_CPUSET: haskell.join(','), HASKELL_AFFINITY: 'container' })
  let mems = null
  if (profile !== 'default') {
    if (profile === 'remote') assert.ok(canRemote(topology), 'Remote cần ít nhất hai RAM node được cấp; chưa nghiệm thu trên máy một node.')
    const selected = values.NUMA_MEMORY_NODE === 'auto'
      ? (profile === 'remote' ? topology.memory.nodes.find(n => n.allowed && n.memoryBytes > 0 && n.id !== cpuNode)?.id : cpuNode)
      : nodeId(values.NUMA_MEMORY_NODE, 'NUMA_MEMORY_NODE')
    assert.notEqual(selected, undefined, 'Remote cần ít nhất hai node được cấp; chưa nghiệm thu trên máy một node.')
    mems = [selected]
    // Remote RAM does not require permission to execute a CPU on node B.
    const valid = validateResources(topology, { cpus: haskell.join(','), mems: String(selected) })
    assert.ok(valid.ok, valid.errors.join('; '))
    assert.ok(profile === 'remote' ? selected !== cpuNode : selected === cpuNode,
      'Local/ghc cần RAM node A; remote cần RAM node B khác A.')
  } else assert.equal(values.NUMA_MEMORY_NODE, 'auto', 'Default không nhận memory node cố định.')
  const policy = values.NUMA_MEMORY_POLICY
  assert.ok(['cpuset', 'membind'].includes(policy), 'NUMA_MEMORY_POLICY: cpuset|membind.')
  assert.ok(profile !== 'default' || policy === 'cpuset', 'Default không được đặt membind.')
  assert.match(values.NUMA_SYS_NICE ?? '', /^[01]$/, 'NUMA_SYS_NICE: 0 hoặc 1.')
  if (profile === 'ghc') assert.ok(cpuNode < 32, 'Thí nghiệm GHC giới hạn node ID 0..31 cho bitmap RTS.')
  const minFreeBytes = positive(values.NUMA_MIN_FREE_MIB, 'NUMA_MIN_FREE_MIB') * 1024 * 1024
  assert.ok(Number.isSafeInteger(minFreeBytes), 'NUMA_MIN_FREE_MIB vượt giới hạn byte.')
  return { ...affinity, profile, cpuNode, mems, policy, sysNice: values.NUMA_SYS_NICE === '1', minFreeBytes,
    ghcNuma: profile === 'ghc' ? `--numa=${(1n << BigInt(cpuNode)).toString()}` : null,
    environment: { ...affinity.environment, NUMA_MEMORY_POLICY: policy, NUMA_SELECTED_MEMS: mems?.join(',') ?? '' } }
}

export function numaCommand(port, config) {
  const command = rtsCommand(port, config)
  if (config.ghcNuma) command.splice(command.length - 1, 0, config.ghcNuma)
  return command
}

export function parseNumaMaps(text) {
  const rows = text.trim().split('\n').filter(Boolean).map(line => {
    const words = line.trim().split(/\s+/)
    assert.match(words[0], /^[a-f0-9]+$/, 'numa_maps thiếu địa chỉ VMA.')
    assert.ok(words[1], 'numa_maps thiếu policy.')
    const pages = {}; for (const word of words.slice(2)) {
      const match = /^N(\d+)=(\d+)$/.exec(word)
      if (match) { const count = Number(match[2]); assert.ok(Number.isSafeInteger(count), 'Page count vượt giới hạn.'); pages[match[1]] = count }
      else assert.ok(!/^N\d+=/.test(word), 'Page count sai định dạng.')
    }
    // Shared file page cache may predate this process; it is not private heap placement.
    const privateAnonymous = !words.some(w => w.startsWith('file=')) && words.some(w => /^(anon=[1-9]\d*|heap|stack)$/.test(w))
    return { address: words[0], policy: words[1], privateAnonymous, pages }
  })
  assert.ok(rows.length, 'numa_maps trống/không được cung cấp.')
  const byNode = {}; let boundPages = 0
  for (const row of rows.filter(r => r.privateAnonymous)) for (const [id, count] of Object.entries(row.pages)) {
    byNode[id] = (byNode[id] ?? 0) + count
    if (row.policy.startsWith('bind:')) boundPages += count
  }
  return { rows, privateAnonymousPages: byNode, boundPrivatePages: boundPages }
}

export function parseCpuStat(text) {
  return text.trim().split('\n').map(line => {
    const end = line.lastIndexOf(') '), fields = line.slice(end + 2).split(/\s+/)
    assert.ok(end > 0 && fields.length >= 37, 'Task stat thiếu processor field 39.')
    const tid = Number(line.slice(0, line.indexOf(' '))), cpu = Number(fields[36])
    assert.ok(Number.isSafeInteger(tid) && tid > 0 && /^\d+$/.test(fields[36]), 'Task stat sai CPU/PID.')
    return { tid, lastCpu: cpu }
  })
}

export function verifyPlacement(config, status, stat, maps) {
  const tasks = parseTasks(status), observed = parseCpuStat(stat), memory = parseNumaMaps(maps)
  for (const task of tasks) {
    assert.ok(task.allowed.length && task.allowed.every(id => config.haskell.includes(id)), 'Task ngoài CPU mask.')
    const cpu = observed.find(c => c.tid === task.tid)
    assert.ok(cpu && config.haskell.includes(cpu.lastCpu), `Task ${task.tid}: CPU thực thi chưa khớp mask.`)
    const block = status.trim().split(/(?=^Name:)/m).find(b => Number(b.match(/^Pid:\s*(\d+)/m)?.[1]) === task.tid)
    const mems = parseIdList(block?.match(/^Mems_allowed_list:\s*(.+)$/m)?.[1])
    if (config.mems) equal(mems, config.mems)
  }
  const pages = Object.entries(memory.privateAnonymousPages)
  assert.ok(pages.reduce((sum, [, n]) => sum + n, 0) > 0, 'Chưa quan sát trang anonymous; không xác nhận placement.')
  if (config.mems) assert.ok(pages.every(([id, n]) => !n || config.mems.includes(Number(id))), 'Trang private anonymous nằm ngoài RAM node yêu cầu.')
  if (config.ghcNuma || config.policy === 'membind') {
    assert.ok(memory.boundPrivatePages > 0, 'Chưa quan sát memory policy bind; không xác nhận từ argv.')
    for (const row of memory.rows.filter(r => r.privateAnonymous && r.policy.startsWith('bind:'))) equal(parseIdList(row.policy.slice(5)), config.mems)
  }
  return { tasks, cpuSamples: observed, memory, scope: 'snapshot of last CPU and private anonymous resident pages; not all future pages or physical host topology' }
}

export function validateFreeMemory(text, minimum) {
  const match = /\bMemFree:\s+(\d+)\s+kB/.exec(text)
  assert.ok(match, 'Không đọc được MemFree của node; không đoán RAM trống.')
  const bytes = Number(match[1]) * 1024
  assert.ok(Number.isSafeInteger(bytes) && bytes >= minimum, 'RAM node không đủ mức preflight; đây không phải reservation.')
  return bytes
}

export function rejectPolicyFailure(text) {
  assert.ok(!/(?:mbind|set_mempolicy|get_mempolicy).*?(?:failed|not permitted|denied)|(?:numa|numactl).*?(?:not available|not supported|not compiled)|compiled without NUMA support/i.test(text),
    `NUMA policy bị từ chối/không hỗ trợ: ${text.slice(0, 800)}`)
}

export function parseArguments(args) {
  const options = { action: 'start', envFile: path.join(root, '.env'), numaFile: path.join(root, '.env.numa'),
    project: 'battleship-numa', docker: process.env.BATTLESHIP_DOCKER_CLI ?? 'docker', build: true }
  if (args[0] && !args[0].startsWith('--')) options.action = args.shift()
  assert.ok(['inspect', 'start', 'verify', 'stop'].includes(options.action), 'Action: inspect|start|verify|stop.')
  const flags = { '--env-file': 'envFile', '--numa-file': 'numaFile', '--project': 'project', '--docker': 'docker' }, seen = new Set()
  for (let i = 0; i < args.length; i++) {
    const flag = args[i]; assert.ok(!seen.has(flag), `Tham số lặp: ${flag}`); seen.add(flag)
    if (flag === '--no-build') options.build = false
    else { assert.ok(flags[flag] && args[i + 1] && !args[i + 1].startsWith('--'), `Tham số sai/thiếu: ${flag}`); options[flags[flag]] = args[++i] }
  }
  assert.match(options.project, /^battleship-numa(?:-[a-z0-9]+)*$/, 'Project cần prefix battleship-numa.')
  return options
}

export async function startNuma(options) {
  const docker = (...args) => execute(options.docker, args, { windowsHide: true, timeout: 30000, maxBuffer: 4 * 1024 * 1024 })
  const probe = async () => JSON.parse((await docker('run', '--rm', '--network', 'none', '--read-only', '--mount',
    `type=bind,source=${root},target=/probe,readonly`, '--entrypoint', 'node', 'battleship-web:local', '/probe/scripts/inspect-topology.mjs', '--no-perf')).stdout)
  if (options.action === 'inspect') return probe()
  const base = parseEnv(await readFile(options.envFile, 'utf8')), envBase = { ...process.env, ...base }
  const baseArgs = ['compose', '--project-directory', root, '--env-file', path.resolve(options.envFile), '-p', options.project, '-f', path.join(root, 'compose.yaml')]
  const run = (args, env = envBase, timeout = 30000) => execute(options.docker, args, { env, windowsHide: true, timeout, maxBuffer: 16 * 1024 * 1024 })
  if (options.action === 'stop') { await run([...baseArgs, 'down', '--remove-orphans'], envBase, 15000); return { stopped: true } }
  assert.equal(JSON.parse((await docker('info', '--format', '{{json .}}')).stdout).OSType, 'linux', 'Cần Docker Linux.')
  const topology = await probe(), config = resolveNuma(topology, parseEnv(await readFile(options.numaFile, 'utf8')))
  config.gameCapability = Number(base.BATTLESHIP_GAME_CAPABILITY ?? '0')
  assert.ok(Number.isInteger(config.gameCapability) && config.gameCapability >= 0 && config.gameCapability < config.capabilities, 'Worker capability phải thuộc 0..N-1.')
  const command = numaCommand(base.BATTLESHIP_TCP_PORT, config), folder = path.join(root, '.stack-work/nm07', options.project)
  await mkdir(folder, { recursive: true })
  const runtime = path.join(folder, 'runtime.json')
  await writeFile(runtime, JSON.stringify({ services: { haskell: { command, ...(config.sysNice ? { cap_add: ['SYS_NICE'] } : {}) } } }))
  const env = { ...envBase, ...config.environment }, args = [...baseArgs, '-f', path.join(root, 'compose.affinity.yaml'), '-f', path.join(root, 'compose.numa.yaml'), '-f', runtime]
  const compose = (...extra) => run([...args, ...extra], env, extra[0] === 'build' ? 1200000 : 70000)
  await compose('config', '--quiet')
  const model = JSON.parse((await compose('config', '--format', 'json')).stdout)
  equal(Object.keys(model.services).sort(), ['haskell', 'web']); equal(model.services.haskell.command, command)
  assert.ok(!model.services.haskell.ports, 'Không publish cổng Haskell.')
  const inspect = async service => {
    const id = (await compose('ps', '--all', '--quiet', service)).stdout.trim(); assert.ok(id, `Thiếu ${service}.`)
    return JSON.parse((await docker('inspect', id)).stdout)[0]
  }
  const check = async () => {
    const container = await inspect('haskell')
    assert.equal(container.State.Running, true, 'Haskell không chạy.'); equal(parseIdList(container.HostConfig.CpusetCpus), config.haskell)
    equal(container.HostConfig.CpusetMems ? parseIdList(container.HostConfig.CpusetMems) : null, config.mems)
    equal(container.Config.Cmd, command)
    const logs = await docker('logs', container.Id); rejectPolicyFailure(logs.stdout + logs.stderr)
    const status = (await docker('exec', container.Id, 'sh', '-ec', 'for f in /proc/1/task/*/status; do cat "$f"; done')).stdout
    const stat = (await docker('exec', container.Id, 'sh', '-ec', 'for f in /proc/1/task/*/stat; do cat "$f"; done')).stdout
    const maps = (await docker('exec', container.Id, 'cat', '/proc/1/numa_maps')).stdout
    const placement = verifyPlacement(config, status, stat, maps); verifyRuntime(logs.stdout + logs.stderr, placement.tasks, config)
    const web = await inspect('web'); assert.equal(web.State.Health?.Status, 'healthy', 'Web chưa healthy.')
    return { schemaVersion: 1, observedAt: new Date().toISOString(), config, topology, placement,
      haskell: { id: container.Id, image: container.Image, healthy: container.State.Health?.Status }, web: { id: web.Id, image: web.Image, ports: model.services.web.ports },
      measurement: 'placement verification; no latency/cache-speedup conclusion' }
  }
  if (options.action === 'verify') { const evidence = await check(); await writeFile(path.join(folder, 'verification.json'), JSON.stringify(evidence, null, 2)); return evidence }
  assert.equal((await compose('ps', '--all', '--quiet')).stdout.trim(), '', 'Project đã có container; verify hoặc stop trước khi đổi profile.')
  let created = false
  try {
    if (options.build) { const built = await compose('build'); await writeFile(path.join(folder, 'build.log'), built.stdout + built.stderr) }
    for (const node of config.mems ?? []) {
      const free = (await docker('run', '--rm', '--network', 'none', '--entrypoint', 'cat', 'battleship-web:local', `/sys/devices/system/node/node${node}/meminfo`)).stdout
      validateFreeMemory(free, config.minFreeBytes)
    }
    if (config.ghcNuma) {
      const support = await docker('run', '--rm', '--network', 'none', ...(config.sysNice ? ['--cap-add', 'SYS_NICE'] : []),
        '--cpuset-cpus', config.haskell.join(','), '--cpuset-mems', config.mems.join(','), '--entrypoint', '/usr/local/bin/battleship-server',
        model.services.haskell.image, '+RTS', `-N${config.capabilities}`, config.ghcNuma, '--info', '-RTS')
      rejectPolicyFailure(support.stdout + support.stderr)
    }
    if (config.policy === 'membind' || config.ghcNuma) {
      const policy = await docker('run', '--rm', '--network', 'none', ...(config.sysNice ? ['--cap-add', 'SYS_NICE'] : []),
        '--cpuset-cpus', config.haskell.join(','), '--cpuset-mems', config.mems.join(','), '--entrypoint', 'numactl', model.services.haskell.image,
        `--membind=${config.mems}`, '/bin/true')
      rejectPolicyFailure(policy.stdout + policy.stderr)
    }
    if (!base.LAN_ORIGINS_FILE) await mkdir(path.resolve(root, base.LAN_CONFIG_DIR), { recursive: true })
    created = true; await compose('create', '--no-build')
    const container = await inspect('haskell')
    assert.equal(container.State.Running, false, 'Áp dụng memory mask trước khi process chạy.')
    if (config.mems) await docker('update', '--cpuset-mems', config.mems.join(','), container.Id)
    const configured = await inspect('haskell')
    equal(configured.HostConfig.CpusetMems ? parseIdList(configured.HostConfig.CpusetMems) : null, config.mems)
    await compose('start', '--wait', '--wait-timeout', '60', 'haskell')
    await compose('start', '--wait', '--wait-timeout', '60', 'web')
    const evidence = await check(); await writeFile(path.join(folder, 'verification.json'), JSON.stringify(evidence, null, 2))
    return evidence
  } catch (error) {
    if (created) try {
      const container = await inspect('haskell'), logs = await docker('logs', container.Id)
      error.message += `; Haskell startup: ${logs.stdout + logs.stderr}; OOMKilled=${container.State.OOMKilled}`
    } catch { /* Keep the original error if Docker cannot read the failed process. */ }
    await writeFile(path.join(folder, 'failure.json'), JSON.stringify({ verified: false, message: error.message, stderr: error.stderr ?? null, config }, null, 2))
    if (created) try { await compose('down', '--remove-orphans') } catch (cleanup) { error.message += `; cleanup: ${cleanup.message}` }
    throw error
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { const result = await startNuma(parseArguments(process.argv.slice(2))); console.log(JSON.stringify(result, null, 2)) }
  catch (error) { console.error(`Battleship NUMA: ${error.message}${error.stderr ? '\n' + error.stderr : ''}`); process.exitCode = 1 }
}
