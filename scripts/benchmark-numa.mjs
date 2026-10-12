import assert from 'node:assert/strict'
import { execFile, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdir, readFile, readdir, readlink, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseEnv, promisify } from 'node:util'
import { resolveNuma, canRemote, numaCommand, verifyPlacement, validateFreeMemory, rejectPolicyFailure, startNuma } from './start-numa.mjs'
import { parseSample, summarize } from './benchmark-runtime.mjs'

const execute = promisify(execFile), root = fileURLToPath(new URL('../', import.meta.url))
const sha = bytes => createHash('sha256').update(bytes).digest('hex')
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

export function comparable(local, remote) {
  assert.equal(local.profile, 'local'); assert.equal(remote.profile, 'remote')
  for (const key of ['haskell', 'capabilities', 'policy', 'sysNice', 'ghcNuma', 'gameCapability']) assert.deepEqual(local[key], remote[key], `comparison changed ${key}`)
  assert.notDeepEqual(local.mems, remote.mems, 'Remote must use a different node.')
}

async function measuredChild(config, count) {
  const binary = '/usr/local/bin/battleship-benchmark'
  const rts = numaCommand(4000, config).slice(1); rts.splice(rts.length - 1, 0, '-T')
  const child = spawn('/usr/local/bin/battleship-numa-entrypoint', [binary, 'core', String(count), ...rts],
    { env: { ...process.env, GHCRTS: '', BATTLESHIP_NUMA_POLICY: config.policy, BATTLESHIP_NUMA_MEMS: config.mems?.join(',') ?? '' } })
  let stdout = '', stderr = '', observed, lastError
  child.stdout.on('data', bytes => { stdout += bytes }); child.stderr.on('data', bytes => { stderr += bytes })
  const closed = new Promise((resolve, reject) => { child.once('error', reject); child.once('close', (code, signal) => resolve({ code, signal })) })
  void closed.catch(() => {})
  const timer = setTimeout(() => child.kill('SIGKILL'), 120000)
  try {
    while (child.pid && child.exitCode === null && child.signalCode === null && !observed) {
      try {
        assert.equal(await readlink(`/proc/${child.pid}/exe`), binary)
        const tids = await readdir(`/proc/${child.pid}/task`)
        const status = (await Promise.all(tids.map(tid => readFile(`/proc/${child.pid}/task/${tid}/status`, 'utf8')))).join('')
        const stat = (await Promise.all(tids.map(tid => readFile(`/proc/${child.pid}/task/${tid}/stat`, 'utf8')))).join('')
        const maps = await readFile(`/proc/${child.pid}/numa_maps`, 'utf8')
        const candidate = verifyPlacement(config, status, stat, maps)
        assert.ok(candidate.tasks.some(t => t.name === 'ghc_worker'), 'RTS threads not initialized yet')
        assert.ok(Object.values(candidate.memory.privateAnonymousPages).reduce((sum, n) => sum + n, 0) >= 64,
          'Wait for a resident working heap, not only the first exec/stack page')
        observed = candidate
      } catch (error) { lastError = error.message; await sleep(5) }
    }
    const exit = await closed
    assert.equal(exit.code, 0, `benchmark failed ${exit.signal ?? exit.code}: ${stderr}`)
    rejectPolicyFailure(stderr)
    assert.ok(observed, `No verified in-flight RAM/CPU snapshot: ${lastError}`)
    const sample = parseSample(stdout)
    assert.equal(sample.compiler, 'ghc 9.10.3'); assert.equal(sample.capabilities, config.capabilities)
    return { ...sample, placement: observed }
  } finally {
    clearTimeout(timer)
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
    await closed
  }
}

export async function benchmarkInside(configFile, output) {
  const config = JSON.parse(await readFile(configFile, 'utf8'))
  await mkdir(output, { recursive: true })
  const build = await readFile('/usr/local/bin/build-source-sha256.txt', 'utf8')
  for (const line of build.trim().split('\n')) {
    const [, digest, file] = /^([a-f0-9]{64})\s+(.+)$/.exec(line) ?? []
    assert.ok(file && sha(await readFile(path.join(root, file))) === digest, `binary/source mismatch: ${file}`)
  }
  for (const node of config.mems ?? []) validateFreeMemory(await readFile(`/sys/devices/system/node/node${node}/meminfo`, 'utf8'), config.minFreeBytes)
  if (config.ghcNuma) {
    const support = await execute('/usr/local/bin/battleship-benchmark', ['+RTS', `-N${config.capabilities}`, config.ghcNuma, '--info', '-RTS'])
    rejectPolicyFailure(support.stdout + support.stderr)
  }
  if (config.policy === 'membind' || config.ghcNuma) {
    const result = await execute('numactl', [`--membind=${config.mems}`, '/bin/true'])
    rejectPolicyFailure(result.stdout + result.stderr)
  }
  // Fixed across all profiles; includes 3 seeded complete games/views per replay.
  const count = 1024, rows = []
  let checksum
  for (let index = -5; index < 30; index++) {
    const measured = await measuredChild(config, count)
    checksum ??= measured.checksum; assert.equal(measured.checksum, checksum)
    rows.push({ ...measured, profile: config.profile, sampleIndex: index, warmup: index < 0 })
    await writeFile(path.join(output, 'samples.jsonl'), rows.map(r => JSON.stringify(r)).join('\n') + '\n')
  }
  const manifest = { schemaVersion: 1, observedAt: new Date().toISOString(), config, repetitions: count,
    seeds: [424242, 8675309, 20261011], samples: 30, warmups: 5,
    binarySha256: sha(await readFile('/usr/local/bin/battleship-benchmark')), buildSourceHashes: build,
    harnessHashes: Object.fromEntries(await Promise.all(['scripts/benchmark-numa.mjs', 'scripts/start-numa.mjs', 'scripts/start-affinity.mjs',
      'scripts/inspect-topology.mjs', 'scripts/benchmark-runtime.mjs', 'docker/numa-entrypoint.sh'].map(async file => [file, sha(await readFile(path.join(root, file)))]))),
    measurementScope: 'pure core replay + both views; in-flight proc verification; not network latency',
    unsupportedMetrics: ['physical host topology outside VM', 'CPU cache misses without usable PMU', 'RAM residency of every future allocation'] }
  await writeFile(path.join(output, 'manifest.json'), JSON.stringify(manifest, null, 2))
  const result = summarize(rows.filter(r => !r.warmup))
  await writeFile(path.join(output, 'summary.json'), JSON.stringify(result, null, 2))
  return result
}

export async function benchmarkMatrix(envFile, output, docker = process.env.BATTLESHIP_DOCKER_CLI ?? 'docker', image = 'battleship-benchmark:nm07') {
  const existing = await readdir(output).catch(error => { if (error.code !== 'ENOENT') throw error; return [] })
  assert.equal(existing.length, 0, 'Choose a fresh/empty output folder; preserve previous samples.')
  await mkdir(output, { recursive: true })
  const topology = await startNuma({ action: 'inspect', docker }), values = parseEnv(await readFile(envFile, 'utf8'))
  const matrix = { schemaVersion: 1, topology, results: [], speedupClaim: false }
  const configs = {}
  for (const profile of ['default', 'local', 'remote', 'ghc']) {
    try { configs[profile] = resolveNuma(topology, { ...values, NUMA_PROFILE: profile,
      ...(profile === 'default' ? { NUMA_MEMORY_NODE: 'auto', NUMA_MEMORY_POLICY: 'cpuset' } : {}) }) }
    catch (error) {
      if (profile !== 'remote' || canRemote(topology)) throw error
      matrix.results.push({ profile, accepted: false, reason: error.message, requiredEnvironment: 'two permitted NUMA nodes' })
    }
  }
  if (configs.remote) comparable(configs.local, configs.remote)
  let checksum
  for (const [profile, config] of Object.entries(configs)) {
    const file = path.join(output, `${profile}.json`); await writeFile(file, JSON.stringify(config))
    const args = ['run', '--rm', '--network', 'none', '--read-only', '--tmpfs', '/tmp', '--cpuset-cpus', config.haskell.join(','),
      ...(config.mems ? ['--cpuset-mems', config.mems.join(',')] : []), ...(config.sysNice ? ['--cap-add', 'SYS_NICE'] : []),
      '--mount', `type=bind,source=${root},target=/probe,readonly`, '--mount', `type=bind,source=${path.resolve(output)},target=/results`,
      '--entrypoint', 'node', image, '/probe/scripts/benchmark-numa.mjs', '--inside', `/results/${profile}.json`, `/results/${profile}`]
    try {
      await execute(docker, args, { windowsHide: true, timeout: 180000, maxBuffer: 4 * 1024 * 1024 })
      const summary = JSON.parse(await readFile(path.join(output, profile, 'summary.json'), 'utf8'))
      const rows = (await readFile(path.join(output, profile, 'samples.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse)
      checksum ??= rows[0].checksum; assert.ok(rows.every(r => r.checksum === checksum), 'profile changed workload/checksum')
      matrix.results.push({ profile, accepted: true, placementVerified: true, timingEligible: summary.stable === true, config, summary })
    } catch (error) {
      const detail = error.message + '\n' + (error.stderr ?? '')
      matrix.results.push({ profile, accepted: false, reason: detail })
      await writeFile(path.join(output, 'matrix.json'), JSON.stringify(matrix, null, 2))
      if (profile !== 'ghc' || !/not permitted|denied|not supported|not available|compiled without NUMA support/i.test(detail)) throw error
    }
    await writeFile(path.join(output, 'matrix.json'), JSON.stringify(matrix, null, 2))
    console.log(`NUMA ${profile}: ${matrix.results.at(-1).accepted ? 'measured' : 'unaccepted'}`)
  }
  return matrix
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const args = process.argv.slice(2)
    if (args[0] === '--inside' && args.length === 3) await benchmarkInside(args[1], args[2])
    else { assert.ok(args.length >= 2 && args.length <= 4, 'Usage: node scripts/benchmark-numa.mjs ENV_FILE NEW_OUTPUT [DOCKER_CLI] [IMAGE]'); await benchmarkMatrix(...args) }
  } catch (error) { console.error(error.stack + (error.stderr ? '\n' + error.stderr : '')); process.exitCode = 1 }
}
