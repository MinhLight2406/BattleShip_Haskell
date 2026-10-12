import assert from 'node:assert/strict'
import { execFile, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { once } from 'node:events'
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import { inspectTopology } from './inspect-topology.mjs'

const execute = promisify(execFile)
const root = fileURLToPath(new URL('../', import.meta.url))
const seeds = [424242, 8675309, 20261011]
const profiles = [{ name: 'N1', rts: ['-N1'] }, { name: 'N2', rts: ['-N2'] }, { name: 'default', rts: [] }]
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex')
const numberOrNull = (value) => value !== undefined && value !== null && value !== ''
  && /^\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/.test(String(value)) && Number.isFinite(Number(value)) ? Number(value) : null

export function parseSample(text) {
  const value = JSON.parse(text)
  assert.equal(value.schemaVersion, 1, 'unsupported benchmark schema')
  for (const key of ['elapsedNs', 'games', 'commands', 'capabilities']) {
    assert.ok(numberOrNull(value[key]) > 0, `missing/invalid ${key}`)
  }
  assert.match(value.checksum, /^\d+$/)
  const metrics = {}
  for (const key of ['cpuSeconds', 'allocatedBytes', 'gcCpuSecondsAccounting', 'gcElapsedSecondsAccounting',
    'maxLiveBytesProcess', 'maxMemoryBytesProcess']) metrics[key] = numberOrNull(value[key])
  return { ...value, ...metrics }
}

export function parseRTS(text) {
  // GHC's --machine-readable output uses quoted key/value tuple pairs.
  const pairs = Object.fromEntries([...text.matchAll(/\("([^"\n]+)",\s*"([^"\n]*)"\)/g)].map((match) => [match[1], match[2]]))
  return { allocatedBytes: numberOrNull(pairs['bytes allocated']),
    cpuSeconds: numberOrNull(pairs['total_cpu_seconds']),
    gcCpuSecondsProcess: numberOrNull(pairs['GC_cpu_seconds']),
    gcElapsedSecondsProcess: numberOrNull(pairs['GC_wall_seconds']),
    maxLiveBytesProcess: numberOrNull(pairs['max_bytes_used']),
    maxMemoryBytesProcess: numberOrNull(pairs['peak_megabytes_allocated']) === null ? null
      : Number(pairs['peak_megabytes_allocated']) * 1024 * 1024,
    capabilities: numberOrNull(pairs['n_capabilities']), contextSwitches: null, migrations: null }
}

export function quantile(values, proportion) {
  if (!values.length) return null
  const sorted = [...values].sort((a, b) => a - b)
  const position = (sorted.length - 1) * proportion
  const lower = Math.floor(position)
  return sorted[lower] + (sorted[Math.ceil(position)] - sorted[lower]) * (position - lower)
}

export function summarize(samples) {
  const times = samples.map((sample) => sample.elapsedNs / sample.commands / 1000)
  const medianUs = quantile(times, 0.5)
  const blockMedians = [0, 1, 2].map((block) => quantile(times.slice(block * 10, (block + 1) * 10), 0.5))
  const stabilitySpread = blockMedians.every((value) => value !== null)
    ? (Math.max(...blockMedians) - Math.min(...blockMedians)) / medianUs : null
  const metricMedian = (key, normalize = false) => {
    const values = samples.filter((sample) => sample[key] !== null && sample[key] !== undefined)
      .map((sample) => normalize ? sample[key] / sample.commands : sample[key])
    return { median: quantile(values, 0.5), availableSamples: values.length }
  }
  // Fixed PRNG bootstrap of the sample median, not of individual commands.
  let state = 20261011
  const draws = []
  for (let repeat = 0; repeat < 2000; repeat++) {
    const resampled = times.map(() => { state = (Math.imul(1664525, state) + 1013904223) >>> 0; return times[state % times.length] })
    draws.push(quantile(resampled, 0.5))
  }
  return { samples: samples.length, medianUsPerCommand: medianUs, median95CI: [quantile(draws, .025), quantile(draws, .975)],
    p95SampleUsPerCommand: quantile(times, .95),
    p95ResponseUs: quantile(samples.flatMap((sample) => sample.responseUs ?? []), .95),
    blockMedians, stabilitySpread, stable: stabilitySpread === null ? null : stabilitySpread <= .1,
    allocatedBytesPerCommand: metricMedian('allocatedBytes', true), cpuSeconds: metricMedian('cpuSeconds'),
    gcCpuSecondsAccounting: metricMedian('gcCpuSecondsAccounting'), gcCpuSecondsProcess: metricMedian('gcCpuSecondsProcess'),
    maxLiveBytesProcess: metricMedian('maxLiveBytesProcess'), maxMemoryBytesProcess: metricMedian('maxMemoryBytesProcess') }
}

async function deadline(promise, label, ms = 10000) {
  let timer
  return Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label}: deadline ${ms}ms`)), ms) })])
    .finally(() => clearTimeout(timer))
}

export async function provenance(directory = root) {
  const files = ['package.yaml', 'stack.yaml', 'stack.yaml.lock', 'test/TestSupport/Generators.hs', 'bench/fixtures-v1.json',
    'frontend/bridge.mjs', 'frontend/package.json', 'frontend/pnpm-lock.yaml',
    'scripts/benchmark-runtime.mjs', 'scripts/inspect-topology.mjs', 'docker/benchmark.Dockerfile']
  async function collect(dir) {
    for (const entry of await readdir(path.join(directory, dir), { withFileTypes: true })) {
      const relative = `${dir}/${entry.name}`
      if (entry.isDirectory()) await collect(relative)
      else if (entry.name.endsWith('.hs')) files.push(relative)
    }
  }
  for (const dir of ['src', 'app', 'bench']) await collect(dir)
  const sourceHashes = {}
  for (const file of files.sort()) sourceHashes[file] = sha(await readFile(path.join(directory, file)))
  const git = async (args) => (await execute('git', args, { cwd: directory, windowsHide: true })).stdout.trim()
  return { head: await git(['rev-parse', 'HEAD']), branch: await git(['branch', '--show-current']),
    dirty: await git(['status', '--porcelain']), sourceHashes, host: { platform: os.platform(), release: os.release() },
    capturedAt: new Date().toISOString() }
}

function peerQueue(transport, frames, kind) {
  const queue = []
  let pending = '', ended = false, fault, wake
  transport.on(kind === 'web' ? 'message' : 'data', (bytes) => {
    const lines = kind === 'web' ? [bytes.toString()] : (pending + bytes).split('\n')
    if (kind !== 'web') pending = lines.pop()
    for (const raw of lines) {
      const line = raw.replace(/\r$/, '')
      if (line.startsWith('{')) {
        const metadata = JSON.parse(line)
        if (!['SESSION', 'CONNECTION'].includes(metadata.type)) fault = new Error(`unexpected bridge metadata ${metadata.type}`)
        // Tokens/SESSION content are never stored in the benchmark artifacts.
      } else { queue.push(line); frames.push(line) }
    }
    wake?.()
  })
  transport.on('close', () => { ended = true; wake?.() })
  transport.on('error', (error) => { fault = error; wake?.() })
  return { transport, frames, send(line) { kind === 'web' ? transport.send(line) : transport.write(line + '\n') },
    async read(expected) {
      await deadline((async () => {
        while (!queue.length) {
          if (fault) throw fault
          if (ended) throw new Error(`peer closed before ${expected}`)
          await new Promise((resolve) => { wake = resolve })
        }
        assert.equal(queue.shift(), expected, 'wire transcript differs from locked fixture')
      })(), `response ${expected}`)
    }, close() { kind === 'web' ? transport.terminate() : transport.destroy() },
    assertEmpty() { assert.equal(queue.length, 0, 'unexpected unconsumed response') } }
}

export async function networkSample({ mode, profile, workload, serverBinary, bridgeModule }) {
  const child = spawn(serverBinary, ['0', '+RTS', ...profile.rts, '-T', '-t', '--machine-readable', '-RTS'],
    { windowsHide: true, env: { ...process.env, GHCRTS: '', BATTLESHIP_BIND_HOST: '127.0.0.1', BATTLESHIP_READY_FILE: undefined } })
  let output = '', stderr = ''
  const exited = new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (code, signal) => resolve({ code, signal })) })
  child.stderr.on('data', (bytes) => { stderr += bytes })
  child.stdout.on('data', (bytes) => { output += bytes })
  let bridge
  const peers = []
  try {
    const tcpPort = await deadline(new Promise((resolve, reject) => {
      const check = () => { const match = /listening on 127\.0\.0\.1:(\d+)/.exec(output); if (match) resolve(Number(match[1])) }
      child.stdout.on('data', check); check()
      exited.then((status) => reject(new Error(`server stopped before ready: ${JSON.stringify(status)} ${stderr}`)), reject)
    }), 'server readiness')
    let port = tcpPort, WebSocket
    if (mode === 'web') {
      const modulePath = path.resolve(bridgeModule)
      assert.equal(sha(await readFile(modulePath)), sha(await readFile(path.join(root, 'frontend/bridge.mjs'))), 'bridge image/source hash mismatch')
      const { createBridge } = await import(pathToFileURL(modulePath).href)
      WebSocket = createRequire(modulePath)('ws').WebSocket
      bridge = createBridge({ tcpPort, devOrigin: undefined })
      bridge.server.listen(0, '127.0.0.1')
      await deadline(once(bridge.server, 'listening'), 'bridge listen')
      port = bridge.server.address().port
    }
    for (const player of ['P1', 'P2']) {
      const transport = mode === 'web'
        ? new WebSocket(`ws://127.0.0.1:${port}/play`, { origin: `http://127.0.0.1:${port}` })
        : net.connect({ host: '127.0.0.1', port })
      if (mode !== 'web') transport.setNoDelay(true)
      const peer = peerQueue(transport, [], mode)
      peers.push(peer)
      await deadline(once(transport, mode === 'web' ? 'open' : 'connect'), 'peer open')
      await peer.read(`WELCOME 1 ${player}`)
    }
    const responseUs = []
    const cpuStart = process.cpuUsage()
    const started = process.hrtime.bigint()
    for (const entry of workload.commands) {
      const begin = process.hrtime.bigint()
      peers[entry.actor === 'P1' ? 0 : 1].send(entry.command)
      await Promise.all(peers.map(async (peer, index) => {
        for (const frame of entry.responses[index ? 'P2' : 'P1']) await peer.read(frame)
      }))
      responseUs.push(Number(process.hrtime.bigint() - begin) / 1000)
    }
    const elapsedNs = Number(process.hrtime.bigint() - started)
    const nodeCpu = process.cpuUsage(cpuStart)
    const status = await deadline(exited, 'server exit')
    assert.equal(status.code, 0, stderr)
    peers.forEach((peer) => peer.assertEmpty())
    const frames = peers.map((peer) => peer.frames)
    const checksum = sha(JSON.stringify(frames))
    assert.equal(checksum, sha(JSON.stringify(['P1', 'P2'].map((player) => [`WELCOME 1 ${player}`, ...workload.commands.flatMap((entry) => entry.responses[player])]))))
    return { mode, games: 1, commands: workload.commandCount, seed: workload.seed,
      elapsedNs, responseUs, checksum, ...parseRTS(stderr), nodeCpuSecondsBridgeAndPeers: (nodeCpu.user + nodeCpu.system) / 1e6,
      nodeRssBytesBridgeAndPeers: process.memoryUsage().rss,
      rawRTS: stderr, metricScope: 'Haskell whole process incl startup/shutdown; Node bridge + harness' }
  } finally {
    peers.forEach((peer) => peer.close())
    if (bridge) await deadline(bridge.close(), 'bridge close')
    if (child.exitCode === null) child.kill()
    await deadline(exited, 'child cleanup')
  }
}

function argumentsFor(profile) { return ['+RTS', ...profile.rts, '-T', '-RTS'] }

export function benchmarkModes(baseline = false) {
  return baseline ? ['core', 'coordinator', 'tcp', 'web'] : ['core', 'coordinator', 'worker', 'tcp', 'web']
}

export async function runBenchmark(options) {
  const { output, benchBinary, serverBinary, bridgeModule, samples = 30, warmups = 5, smoke = false } = options
  const modes = benchmarkModes(options.baseline)
  assert.ok(smoke || (samples >= 30 && warmups >= 5), 'formal baseline needs >=30 samples and >=5 warmups')
  const topology = await inspectTopology()
  assert.equal(topology.inspectionOk, true, 'baseline must run in Linux with verified masks')
  await mkdir(output, { recursive: true })
  const source = options.provenanceFile ? JSON.parse(await readFile(options.provenanceFile, 'utf8')) : await provenance()
  for (const [file, hash] of Object.entries(source.sourceHashes)) assert.equal(sha(await readFile(path.join(root, file))), hash, `source changed: ${file}`)
  if (options.buildManifest) {
    for (const line of (await readFile(options.buildManifest, 'utf8')).trim().split('\n')) {
      const match = /^([a-f0-9]{64})\s+(.+)$/.exec(line)
      assert.ok(match, 'invalid build checksum manifest')
      assert.equal(sha(await readFile(path.join(root, match[2]))), match[1], `binary/source mismatch: ${match[2]}`)
    }
  }
  const binaryHashes = { benchmark: sha(await readFile(benchBinary)), server: sha(await readFile(serverBinary)) }
  const execBench = async (args, profile) => execute(benchBinary, [...args, ...argumentsFor(profile)],
    { timeout: 120000, maxBuffer: 1024 * 1024, windowsHide: true, env: { ...process.env, GHCRTS: '' } })
  const workloads = []
  for (const seed of seeds) {
    const first = JSON.parse((await execBench(['fixture', String(seed)], profiles[0])).stdout)
    const second = JSON.parse((await execBench(['fixture', String(seed)], profiles[1])).stdout)
    assert.deepEqual(first, second, 'seed fixture varies by run/RTS profile')
    workloads.push(first)
  }
  await writeFile(path.join(output, 'fixtures.json'), JSON.stringify(workloads, null, 2))
  const fixtureHash = sha(JSON.stringify(workloads))
  const locked = JSON.parse(await readFile(path.join(root, 'bench/fixtures-v1.json'), 'utf8'))
  assert.deepEqual(workloads, locked, 'workload differs from pre-optimization fixtures-v1')
  const repetitions = {}
  const checksums = new Map()
  for (const mode of modes.filter((mode) => !['tcp', 'web'].includes(mode))) {
    let count = 1
    for (let round = 0; round < 4; round++) {
      const measured = parseSample((await execBench([mode, String(count)], profiles[0])).stdout)
      if (smoke || measured.elapsedNs >= 1e9) break
      count = Math.min(100000, Math.ceil(count * 1.25e9 / measured.elapsedNs))
    }
    repetitions[mode] = count
  }
  const cgroupMembership = await readFile('/proc/self/cgroup', 'utf8').catch(() => null)
  const cgroupLimits = { membership: cgroupMembership, namespaceRootVerified: cgroupMembership?.trim() === '0::/' }
  for (const name of ['cpu.max', 'memory.max', 'memory.swap.max']) {
    cgroupLimits[name] = cgroupLimits.namespaceRootVerified
      ? (await readFile(`/sys/fs/cgroup/${name}`, 'utf8').catch(() => null))?.trim() ?? null : null
  }
  const manifest = { schemaVersion: 1, startedAt: new Date().toISOString(), smoke, source, topology, cgroupLimits, binaryHashes,
    compiler: 'ghc 9.10.3', snapshot: 'lts-24.59', buildFlags: options.buildFlags ?? 'not supplied',
    runtime: { node: process.version, platform: process.platform, arch: process.arch, cpus: os.cpus().map((cpu) => cpu.model) },
    profiles, seeds, fixtureHash, repetitions, samples, warmups, modes,
    unsupportedMetrics: { contextSwitches: 'No instrumented kernel/perf counter', migrations: 'No instrumented kernel/perf counter',
      peakRss: 'Not measured; RTS heap/live bytes are reported separately' } }
  await writeFile(path.join(output, 'manifest.json'), JSON.stringify(manifest, null, 2))
  await writeFile(path.join(output, 'samples.jsonl'), '')
  const results = []
  for (const mode of modes) {
    const groups = new Map(profiles.map((profile) => [profile.name, []]))
    for (let index = -warmups; index < samples; index++) {
      // Rotate profile order; each measured index uses the same network seed.
      const offset = (index + warmups) % profiles.length
      for (let order = 0; order < profiles.length; order++) {
        const profile = profiles[(order + offset) % profiles.length]
        const workload = workloads[((index % 3) + 3) % 3]
        let sample
        if (mode === 'core' || mode === 'coordinator' || mode === 'worker') {
          sample = parseSample((await execBench([mode, String(repetitions[mode])], profile)).stdout)
          const key = `${mode}:${sample.repetitions}`
          if (!checksums.has(key)) checksums.set(key, sample.checksum)
          assert.equal(sample.checksum, checksums.get(key), 'semantic checksum varies between samples/profiles')
          assert.equal(sample.compiler, 'ghc 9.10.3')
          if (profile.name !== 'default') assert.equal(sample.capabilities, Number(profile.name.slice(1)))
        } else {
          sample = await networkSample({ mode, profile, workload, serverBinary, bridgeModule })
          if (profile.name !== 'default') assert.equal(sample.capabilities, Number(profile.name.slice(1)), 'server RTS profile differs')
        }
        sample = { ...sample, profile: profile.name, sampleIndex: index, warmup: index < 0 }
        await writeFile(path.join(output, 'samples.jsonl'), JSON.stringify(sample) + '\n', { flag: 'a' })
        if (index >= 0) groups.get(profile.name).push(sample)
      }
      if (index < 0 || (index + 1) % 10 === 0 || smoke) console.error(`${mode}: ${index < 0 ? 'warmup ' + (index + warmups + 1) : 'sample ' + (index + 1)}/${samples}`)
    }
    for (const profile of profiles) results.push({ mode, profile: profile.name, ...summarize(groups.get(profile.name)) })
  }
  const report = { schemaVersion: 1, finishedAt: new Date().toISOString(), fixtureHash, results }
  await writeFile(path.join(output, 'summary.json'), JSON.stringify(report, null, 2))
  console.log(JSON.stringify(report, null, 2))
  return report
}

async function main(args) {
  args = args.flatMap((arg) => arg.startsWith('--') && arg.includes('=')
    ? [arg.slice(0, arg.indexOf('=')), arg.slice(arg.indexOf('=') + 1)] : [arg])
  const options = { output: path.join(root, '.stack-work/nm03/baseline'),
    benchBinary: process.env.BATTLESHIP_BENCHMARK ?? '/usr/local/bin/battleship-benchmark',
    serverBinary: process.env.BATTLESHIP_SERVER ?? '/usr/local/bin/battleship-server',
    bridgeModule: process.env.BENCH_BRIDGE_MODULE ?? path.join(root, 'frontend/bridge.mjs') }
  const keys = { '--output': 'output', '--bench': 'benchBinary', '--server': 'serverBinary', '--bridge-module': 'bridgeModule',
    '--provenance': 'provenanceFile', '--build-manifest': 'buildManifest', '--build-flags': 'buildFlags' }
  if (args[0] === '--prepare' && args.length === 2) {
    await mkdir(path.dirname(path.resolve(args[1])), { recursive: true })
    await writeFile(args[1], JSON.stringify(await provenance(), null, 2))
    return
  }
  for (let index = 0; index < args.length; index++) {
    const arg = args[index]
    if (arg === '--smoke') { options.smoke = true; options.samples = 1; options.warmups = 0 }
    else if (arg === '--baseline') options.baseline = true
    else if (keys[arg] && args[index + 1]) options[keys[arg]] = path.resolve(args[++index])
    else throw new Error(`Unknown/missing argument: ${arg}`)
  }
  // Build flags are descriptive text, not a path.
  if (options.buildFlags) options.buildFlags = args[args.indexOf('--build-flags') + 1]
  options.benchBinary = path.resolve(options.benchBinary)
  options.serverBinary = path.resolve(options.serverBinary)
  await runBenchmark(options)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { await main(process.argv.slice(2)) } catch (error) { console.error(error.stack); process.exitCode = 1 }
}
