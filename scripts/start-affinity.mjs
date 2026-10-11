import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseEnv, promisify } from 'node:util'
import { parseIdList, validateResources } from './inspect-topology.mjs'

const execute = promisify(execFile)
const root = fileURLToPath(new URL('../', import.meta.url))
const equalMask = (a, b) => JSON.stringify(a) === JSON.stringify(b)

export function resolveAffinity(topology, values) {
  assert.ok(topology.inspectionOk, 'Topology Linux chưa xác nhận được CPU/RAM mask.')
  const text = values.HASKELL_CAPABILITIES
  assert.match(text ?? '', /^[1-9]\d*$/, 'HASKELL_CAPABILITIES phải là số nguyên dương.')
  const capabilities = Number(text)
  assert.ok(Number.isSafeInteger(capabilities) && capabilities <= topology.cpu.effective.length,
    'Capability vượt số CPU logic được phép.')
  const mode = values.HASKELL_AFFINITY
  assert.ok(['container', 'rts'].includes(mode), 'HASKELL_AFFINITY phải là container hoặc rts.')
  const allowed = topology.cpu.effective
  const haskell = values.HASKELL_CPUSET === 'auto'
    ? (mode === 'rts' ? Array.from({ length: capabilities }, (_, i) => i) : allowed.slice(0, capabilities))
    : parseIdList(values.HASKELL_CPUSET)
  const firstCore = topology.cpu.details.find(cpu => cpu.id === haskell[0])
  const differentCore = allowed.find(id => {
    const cpu = topology.cpu.details.find(cpu => cpu.id === id)
    return !haskell.includes(id) && firstCore?.coreId !== null && firstCore?.socketId !== null
      && cpu?.coreId !== null && cpu?.socketId !== null && cpu && firstCore
      && (cpu.coreId !== firstCore.coreId || cpu.socketId !== firstCore.socketId)
  })
  const web = values.WEB_CPUSET === 'auto' ? [differentCore ?? allowed.find(id => !haskell.includes(id)) ?? allowed[0]]
    : parseIdList(values.WEB_CPUSET)
  for (const cpus of [haskell, web]) {
    const checked = validateResources(topology, { cpus: cpus.join(',') })
    assert.ok(checked.ok, checked.errors.join('; '))
  }
  assert.ok(capabilities <= haskell.length, 'Capability vượt số CPU trong HASKELL_CPUSET.')
  if (mode === 'rts') {
    assert.ok(equalMask(haskell, Array.from({ length: capabilities }, (_, i) => i)),
      'GHC 9.10.3 -qa cần mask 0..N-1 và N bằng số CPU để xác nhận mapping; dùng container cho mask khác.')
  }
  return { mode, capabilities, haskell, web,
    environment: { HASKELL_CPUSET: haskell.join(','), WEB_CPUSET: web.join(','), HASKELL_CAPABILITIES: String(capabilities) } }
}

export function rtsCommand(port, config) {
  assert.match(String(port), /^[1-9]\d*$/, 'TCP port phải là số nguyên 1..65535.')
  assert.ok(Number(port) <= 65535, 'TCP port vượt 65535.')
  return [String(port), '+RTS', `-N${config.capabilities}`, ...(config.mode === 'rts' ? ['-qa'] : []), '-RTS']
}

export function parseTasks(text) {
  const blocks = text.trim().split(/(?=^Name:)/m).filter(Boolean)
  assert.ok(blocks.length, 'Không đọc được task của PID 1.')
  return blocks.map(block => {
    const field = key => block.match(new RegExp(`^${key}:\\s*(.+)$`, 'm'))?.[1]?.trim()
    const pid = Number(field('Pid'))
    assert.ok(Number.isSafeInteger(pid) && pid > 0, 'Task thiếu PID hợp lệ.')
    return { tid: pid, name: field('Name'), allowed: parseIdList(field('Cpus_allowed_list')) }
  })
}

export function verifyContainer(inspect, tasks, requested, command) {
  assert.deepEqual(parseIdList(inspect.HostConfig.CpusetCpus), requested, 'Docker CpusetCpus khác yêu cầu.')
  assert.equal(inspect.State.Running, true, 'Container không chạy.')
  if (command) assert.deepEqual(inspect.Config.Cmd, command, 'RTS command thực tế khác yêu cầu.')
  assert.ok(tasks.some(task => task.tid === 1), 'Thiếu process chính PID 1.')
  for (const task of tasks) {
    assert.ok(task.allowed.length && task.allowed.every(id => requested.includes(id)),
      `Task ${task.tid} có CPU ngoài mask yêu cầu.`)
  }
  // Without -qa all tasks must retain the full cgroup mask; -qa can narrow it.
  if (!command?.includes('-qa')) for (const task of tasks) {
    assert.deepEqual(task.allowed, requested, `Task ${task.tid} mask khác cpuset.`)
  }
}

export function verifyRuntime(logs, tasks, config) {
  const matches = [...logs.matchAll(/^Battleship runtime capabilities: (\d+)$/gm)]
  assert.equal(matches.length, 1, 'Cần một log capability từ binary hiện tại; build lại image nếu log thiếu/cũ.')
  assert.equal(Number(matches[0][1]), config.capabilities, 'Capability runtime khác cấu hình.')
  if (config.gameCapability !== undefined) {
    const workers = [...logs.matchAll(/^Battleship game worker capability: (\d+)$/gm)]
    assert.equal(workers.length, 1, 'Thiếu log game worker của binary NM-05.')
    assert.equal(Number(workers[0][1]), config.gameCapability, 'Game worker capability khác yêu cầu.')
  }
  if (config.mode === 'rts') for (const cpu of config.haskell) {
    assert.ok(tasks.some(task => task.name === 'ghc_worker' && task.allowed.length === 1 && task.allowed[0] === cpu),
      `Chưa quan sát thread pin trên CPU ${cpu}; không xác nhận -qa từ tham số đơn thuần.`)
  }
}

export function parseArguments(args) {
  const options = { action: 'start', envFile: path.join(root, '.env'), performanceFile: path.join(root, '.env.performance'),
    project: 'battleship-affinity', docker: process.env.BATTLESHIP_DOCKER_CLI ?? 'docker', build: true }
  if (args[0] && !args[0].startsWith('--')) options.action = args.shift()
  assert.ok(['start', 'verify', 'stop', 'inspect'].includes(options.action), 'Action: start|verify|stop|inspect.')
  const names = { '--env-file': 'envFile', '--performance-file': 'performanceFile', '--project': 'project', '--docker': 'docker' }
  const seen = new Set()
  for (let index = 0; index < args.length; index++) {
    const arg = args[index]
    assert.ok(!seen.has(arg), `Tham số lặp: ${arg}`); seen.add(arg)
    if (arg === '--no-build') options.build = false
    else {
      assert.ok(names[arg] && args[index + 1] && !args[index + 1].startsWith('--'), `Tham số sai/thiếu: ${arg}`)
      options[names[arg]] = args[++index]
    }
  }
  assert.match(options.project, /^battleship-affinity(?:-[a-z0-9]+)*$/, 'Project phải bắt đầu battleship-affinity (chỉ a-z, 0-9 và dấu -).')
  return options
}

export async function startAffinity(options) {
  const docker = (...args) => execute(options.docker, args, { windowsHide: true, timeout: 30000, maxBuffer: 4 * 1024 * 1024 })
  // Stop must reach down immediately, even if topology/platform has changed.
  if (options.action !== 'stop') {
    const info = JSON.parse((await docker('info', '--format', '{{json .}}')).stdout)
    assert.equal(info.OSType, 'linux', 'Cần Docker Engine Linux.')
  }
  const probe = async () => JSON.parse((await docker('run', '--rm', '--network', 'none', '--read-only',
    '--mount', `type=bind,source=${root},target=/probe,readonly`, '--entrypoint', 'node', 'battleship-web:local',
    '/probe/scripts/inspect-topology.mjs', '--no-perf')).stdout)
  if (options.action === 'inspect') { const topology = await probe(); console.log(JSON.stringify(topology, null, 2)); return topology }
  const base = parseEnv(await readFile(options.envFile, 'utf8'))
  const folder = path.join(root, '.stack-work/nm04', options.project)
  const baseArgs = ['compose', '--project-directory', root, '--env-file', path.resolve(options.envFile), '-p', options.project, '-f', path.join(root, 'compose.yaml')]
  const baseEnv = { ...process.env, ...base }
  const composeRun = (args, env = baseEnv, timeout = 30000) => execute(options.docker, args, { env, windowsHide: true, timeout, maxBuffer: 16 * 1024 * 1024 })
  if (options.action === 'stop') {
    await composeRun([...baseArgs, 'down', '--remove-orphans'], baseEnv, 15000)
    console.log(`Stopped ${options.project}; trận/phiên cũ không được phục hồi.`); return
  }
  const topology = await probe()
  const config = resolveAffinity(topology, parseEnv(await readFile(options.performanceFile, 'utf8')))
  const gameCapability = base.BATTLESHIP_GAME_CAPABILITY ?? '0'
  assert.match(gameCapability, /^(0|[1-9]\d*)$/, 'BATTLESHIP_GAME_CAPABILITY phải là chỉ số capability không âm.')
  config.gameCapability = Number(gameCapability)
  assert.ok(Number.isSafeInteger(config.gameCapability) && config.gameCapability < config.capabilities,
    'Game worker capability phải nhỏ hơn N.')
  const command = rtsCommand(base.BATTLESHIP_TCP_PORT, config)
  await mkdir(folder, { recursive: true })
  const runtimeOverride = path.join(folder, 'runtime.json')
  await writeFile(runtimeOverride, JSON.stringify({ services: { haskell: { command } } }))
  const env = { ...baseEnv, ...config.environment }
  const args = [...baseArgs, '-f', path.join(root, 'compose.affinity.yaml'), '-f', runtimeOverride]
  const compose = (...extra) => composeRun([...args, ...extra], env, extra[0] === 'build' ? 1200000 : extra[0] === 'up' ? 70000 : 30000)
  await compose('config', '--quiet')
  const model = JSON.parse((await compose('config', '--format', 'json')).stdout)
  assert.deepEqual(Object.keys(model.services).sort(), ['haskell', 'web'])
  assert.deepEqual(model.services.haskell.command, command)
  assert.ok(!model.services.haskell.ports, 'Không publish cổng chơi Haskell.')
  const inspect = async service => {
    const id = (await compose('ps', '--all', '--quiet', service)).stdout.trim()
    assert.ok(id, `Thiếu container ${service}.`)
    return JSON.parse((await docker('inspect', id)).stdout)[0]
  }
  const check = async service => {
    const container = await inspect(service)
    const tasks = parseTasks((await docker('exec', container.Id, 'sh', '-ec', 'for f in /proc/1/task/*/status; do cat "$f"; done')).stdout)
    verifyContainer(container, tasks, config[service], service === 'haskell' ? command : undefined)
    const result = { id: container.Id, image: container.Image, cpuset: container.HostConfig.CpusetCpus, tasks }
    if (service === 'haskell') {
      const logs = await docker('logs', container.Id)
      verifyRuntime(logs.stdout + logs.stderr, tasks, config)
      result.capabilities = config.capabilities
      result.gameCapability = config.gameCapability
      result.rtsPinObserved = config.mode === 'rts'
    }
    return result
  }
  if (options.action === 'verify') {
    const evidence = { schemaVersion: 1, observedAt: new Date().toISOString(), config,
      haskell: await check('haskell'), web: await check('web') }
    await writeFile(path.join(folder, 'verification.json'), JSON.stringify(evidence, null, 2))
    console.log(JSON.stringify(evidence, null, 2)); return evidence
  }
  assert.equal((await compose('ps', '--all', '--quiet')).stdout.trim(), '',
    'Project đã có container; dùng verify hoặc stop trước khi đổi profile (restart mất trận).')
  let created = false
  try {
    if (options.build) { const built = await compose('build'); await writeFile(path.join(folder, 'build.log'), built.stdout + built.stderr) }
    if (!base.LAN_ORIGINS_FILE) await mkdir(path.resolve(root, base.LAN_CONFIG_DIR), { recursive: true })
    created = true
    await compose('create', '--no-build')
    for (const service of ['haskell', 'web']) {
      const container = await inspect(service)
      assert.deepEqual(parseIdList(container.HostConfig.CpusetCpus), config[service], 'Created mask khác yêu cầu.')
    }
    await compose('up', '-d', '--no-build', '--wait', '--wait-timeout', '60', 'haskell')
    const haskell = await check('haskell')
    await compose('up', '-d', '--no-build', '--wait', '--wait-timeout', '60', 'web')
    const web = await check('web')
    const evidence = { schemaVersion: 1, observedAt: new Date().toISOString(), config, topology, haskell, web,
      model: { haskell: { cpuset: model.services.haskell.cpuset, command }, web: {
        cpuset: model.services.web.cpuset, ports: model.services.web.ports, origins: model.services.web.environment.PUBLIC_ORIGIN,
        originFile: model.services.web.environment.LAN_ORIGINS_FILE } } }
    await writeFile(path.join(folder, 'verification.json'), JSON.stringify(evidence, null, 2))
    console.log(`Verified ${options.project}: Haskell CPU ${config.haskell} / N${config.capabilities} / ${config.mode}; web CPU ${config.web}.`)
    console.log(`Open ${base.PUBLIC_ORIGIN || 'URL LAN trong log web'}; host port ${base.WEB_PUBLIC_PORT} -> container ${base.PORT}.`)
    console.log('CPU mask không dành độc quyền CPU; đổi profile cần stop và mở trận mới.')
    return evidence
  } catch (error) {
    if (created) {
      try { await compose('down', '--remove-orphans') } catch (cleanup) { error.message += `; cleanup thất bại: ${cleanup.message}` }
    }
    throw error
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { await startAffinity(parseArguments(process.argv.slice(2))) }
  catch (error) { console.error(`Battleship affinity: ${error.message}`); process.exitCode = 1 }
}
