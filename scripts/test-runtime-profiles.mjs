import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { networkInterfaces } from 'node:os'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import { resolveAffinity, rtsCommand } from './start-affinity.mjs'
import { canRemote, resolveNuma, startNuma } from './start-numa.mjs'
import { lanAddresses } from '../frontend/bridge.mjs'

const root = fileURLToPath(new URL('../', import.meta.url)), execute = promisify(execFile)
const require = createRequire(new URL('../frontend/package.json', import.meta.url))
export const redact = text => text.replace(/(\\*"token\\*"\s*:\s*\\*")[a-f0-9]{64}/g, '$1[REDACTED]').replace(/resume=[a-f0-9]{64}/g, 'resume=[REDACTED]')
const numaValues = { NUMA_CPU_NODE: 'auto', NUMA_MEMORY_NODE: 'auto', HASKELL_CPUSET: 'auto', WEB_CPUSET: 'auto',
  HASKELL_CAPABILITIES: '1', NUMA_MEMORY_POLICY: 'cpuset', NUMA_SYS_NICE: '0', NUMA_MIN_FREE_MIB: '64' }

export function validateProfile(profile) {
  assert.match(profile.name, /^[a-zA-Z0-9-]+$/)
  const c = profile.config
  assert.ok(Number.isSafeInteger(c.capabilities) && c.capabilities > 0)
  assert.ok(Number.isInteger(c.gameCapability) && c.gameCapability >= 0 && c.gameCapability < c.capabilities)
  for (const mask of [c.haskell, c.web, c.mems]) if (mask !== null) {
    assert.ok(Array.isArray(mask) && mask.length > 0)
    assert.ok(mask.every((id, i) => Number.isSafeInteger(id) && id >= 0 && (i === 0 || id > mask[i - 1])))
  }
  assert.ok(c.haskell === null || c.capabilities <= c.haskell.length)
  assert.ok(['container', 'rts'].includes(c.mode))
  if (c.mode === 'rts') assert.deepEqual(c.haskell, Array.from({ length: c.capabilities }, (_, i) => i))
  assert.ok(['cpuset', 'membind'].includes(c.policy))
  assert.equal(typeof c.sysNice, 'boolean')
  if (c.policy === 'membind') assert.ok(c.mems?.length)
  if (c.ghcNuma !== null) assert.match(c.ghcNuma, /^--numa=[1-9]\d*$/)
  return profile
}

export function buildProfiles(topology) {
  assert.ok(topology.inspectionOk && topology.cpu.effective.length, 'Topology chưa kiểm chứng; không được đoán CPU/node.')
  const profiles = [1, 2].map(n => ({ name: `N${n}`, config: { capabilities: n, gameCapability: n - 1,
    haskell: null, web: null, mems: null, mode: 'container', policy: 'cpuset', sysNice: false, ghcNuma: null } }))
  const affinity = resolveAffinity(topology, { HASKELL_CPUSET: String(topology.cpu.effective.at(-1)), WEB_CPUSET: 'auto',
    HASKELL_CAPABILITIES: '1', HASKELL_AFFINITY: 'container' })
  profiles.push({ name: 'affinity-single', config: { ...affinity, gameCapability: 0, mems: null, policy: 'cpuset', sysNice: false, ghcNuma: null } })
  if ([0, 1].every(id => topology.cpu.effective.includes(id))) {
    profiles.push({ name: 'affinity-qa', config: { ...resolveAffinity(topology, { HASKELL_CPUSET: '0,1', WEB_CPUSET: 'auto',
      HASKELL_CAPABILITIES: '2', HASKELL_AFFINITY: 'rts' }), gameCapability: 1, mems: null, policy: 'cpuset', sysNice: false, ghcNuma: null } })
  } else profiles.push({ name: 'affinity-qa', status: 'unaccepted', reason: 'Mapping -qa cần CPU 0,1 được cấp; không tự ánh xạ lại.' })
  for (const name of ['local', 'remote', 'ghc']) {
    if (name === 'remote' && !canRemote(topology)) {
      profiles.push({ name: 'numa-remote', status: 'unaccepted', reason: 'Thiếu hai RAM node Linux được cấp; chưa nghiệm thu remote.' }); continue
    }
    profiles.push({ name: `numa-${name}`, config: { ...resolveNuma(topology, { ...numaValues, NUMA_PROFILE: name }), gameCapability: 0 } })
  }
  profiles.push({ name: 'numa-membind', config: { ...resolveNuma(topology, { ...numaValues, NUMA_PROFILE: 'local',
    NUMA_MEMORY_POLICY: 'membind', NUMA_SYS_NICE: '1' }), gameCapability: 0 } })
  return profiles.map(p => p.config ? validateProfile(p) : p)
}

export function parseTap(text) {
  const metric = key => Number(text.match(new RegExp(`^# ${key} (\\d+)$`, 'm'))?.[1] ?? NaN)
  const result = Object.fromEntries(['tests', 'pass', 'fail', 'cancelled', 'skipped', 'todo'].map(k => [k, metric(k)]))
  assert.ok(Object.values(result).every(Number.isSafeInteger), 'Thiếu kết quả TAP; không đánh dấu pass theo exit code đơn thuần.')
  assert.equal(result.fail + result.cancelled + result.todo, 0, 'Bộ test chưa xanh.')
  assert.ok(result.pass > 0, 'Không có test được chạy.')
  assert.equal(result.tests, result.pass + result.fail + result.cancelled + result.skipped + result.todo)
  return result
}

export function compareTranscripts(reference, actual) {
  assert.equal(actual.schemaVersion, 1)
  assert.deepEqual(actual.games, reference.games, 'Cùng seed/chuỗi lệnh phải có cùng transcript P1/P2.')
  assert.equal(actual.games.length, 3, 'Cần đủ ba seed cố định.')
  for (const game of actual.games) {
    assert.equal(game.frames.length, 2)
    for (const frames of game.frames) {
      assert.ok(frames.at(-1).startsWith('GAME_OVER '), 'Workload phải kết thúc thật.')
      assert.ok(frames.every(frame => !frame.startsWith('{')), 'Không lưu metadata/token phiên vào bằng chứng.')
    }
  }
  return createHash('sha256').update(JSON.stringify(actual.games)).digest('hex')
}

export async function inPairs(items, action) {
  for (let i = 0; i < items.length; i += 2) {
    const results = await Promise.allSettled(items.slice(i, i + 2).map(action))
    const failed = results.find(result => result.status === 'rejected')
    if (failed) throw failed.reason
  }
}

export async function runProfiles(options = {}) {
  const docker = options.docker ?? process.env.BATTLESHIP_DOCKER_CLI ?? 'docker', stack = options.stack ?? 'stack'
  const output = path.resolve(options.output ?? path.join(root, '.stack-work/nm08', new Date().toISOString().replaceAll(/[:.]/g, '-')))
  await mkdir(output, { recursive: true })
  const previous = options.resume ? JSON.parse(await readFile(path.join(output, 'report.json'), 'utf8')) : null
  const report = { schemaVersion: 1, startedAt: new Date().toISOString(), hostPlatform: process.platform, commands: [], profiles: [] }
  let reuseNative = false
  let reuseLinux = false
  async function run(label, binary, args, env = {}, timeout = 1200000, cwd = root) {
    console.log(`NM-08: ${label}`)
    const log = path.join(output, `${label}.log`)
    if ((reuseNative && ['windows-build', 'native-N1', 'native-N2'].includes(label)) || (reuseLinux && label.endsWith('-linux'))) {
      const saved = previous.commands.find(c => c.label === label && c.exitCode === 0 && c.binary === binary && JSON.stringify(c.args) === JSON.stringify(args))
      if (saved) { report.commands.push({ ...saved, reusedFrom: saved.reusedFrom ?? previous.startedAt }); return readFile(log, 'utf8') }
    }
    try {
      const result = await execute(binary, args, { cwd, env: { ...process.env, ...env }, windowsHide: true, timeout, maxBuffer: 32 * 1024 * 1024 })
      await writeFile(log, redact(result.stdout + result.stderr))
      report.commands.push({ label, binary, args, exitCode: 0, log: path.basename(log) }); return result.stdout
    } catch (error) {
      await writeFile(log, redact((error.stdout ?? '') + (error.stderr ?? '') + '\n' + error.message))
      report.commands.push({ label, binary, args, exitCode: error.code ?? null, log: path.basename(log) }); throw error
    }
  }
  const node = (label, args, env = {}, cwd = root) => run(label, process.execPath, args, env, 1200000, cwd)
  try {
    report.commit = (await run('commit', 'git', ['rev-parse', 'HEAD'])).trim()
    report.dirty = (await run('worktree', 'git', ['status', '--short'])).trim()
    const sourceFiles = ['package.yaml', 'stack.yaml', ...await Promise.all(['src', 'app', 'test', 'bench'].map(async folder =>
      (await readdir(path.join(root, folder), { recursive: true })).filter(f => f.endsWith('.hs')).map(f => `${folder}/${f.replaceAll('\\', '/')}`))).then(x => x.flat())]
    report.sourceHashes = Object.fromEntries(await Promise.all(sourceFiles.sort().map(async f => [f, createHash('sha256').update(await readFile(path.join(root, f))).digest('hex')])))
    if (previous) { assert.deepEqual(report.sourceHashes, previous.sourceHashes, 'Source Haskell đổi: không được reuse native gate.'); reuseNative = true }
    await run('windows-build', stack, ['build'])
    for (const n of [1, 2]) await run(`native-N${n}`, stack, ['test', '--ghc-options=-Werror', `--test-arguments=+RTS -N${n} -RTS`])
    const install = (await run('stack-install-path', stack, ['path', '--local-install-root'])).trim()
    const frontendEnv = { BATTLESHIP_SERVER: path.join(install, 'bin', `battleship-server${process.platform === 'win32' ? '.exe' : ''}`),
      BATTLESHIP_LAN_TEST_HOST: process.env.BATTLESHIP_LAN_TEST_HOST ?? lanAddresses(networkInterfaces())[0] ?? '' }
    report.frontend = { lanHost: frontendEnv.BATTLESHIP_LAN_TEST_HOST,
      unit: parseTap(await node('frontend-unit', ['--test', '--test-reporter=tap', 'test/unit.test.ts', 'test/connection.test.ts', 'test/bridge.test.mjs', 'test/docker-contract.test.mjs', 'test/lan.test.mjs', 'test/lan-helper.test.mjs'], frontendEnv, path.join(root, 'frontend'))) }
    await node('frontend-types', [path.join(path.dirname(require.resolve('typescript/package.json')), 'bin/tsc'), '--noEmit'], {}, path.join(root, 'frontend'))
    await node('frontend-build', [path.join(path.dirname(require.resolve('vite/package.json')), 'bin/vite.js'), 'build'], {}, path.join(root, 'frontend'))
    report.frontend.integration = parseTap(await node('frontend-integration', ['--test', '--test-reporter=tap', 'test/integration.test.mjs', 'test/reconnect.test.mjs'],
      frontendEnv, path.join(root, 'frontend')))
    const scripts = (await readdir(path.join(root, 'scripts/test'))).filter(f => f.endsWith('.test.mjs') && !f.endsWith('compose.test.mjs')).map(f => `scripts/test/${f}`)
    report.scriptTests = parseTap(await node('scripts-unit', ['--test', '--test-reporter=tap', ...scripts]))
    if (!options.prepared) {
      await run('linux-image', docker, ['build', '-f', 'docker/haskell.Dockerfile', '--target', 'test', '-t', 'battleship-regression:test', '.'])
      await run('runtime-image', docker, ['build', '-f', 'docker/haskell.Dockerfile', '--target', 'runtime', '-t', 'battleship-haskell:local', '.'])
      await run('web-image', docker, ['build', '-f', 'docker/web.Dockerfile', '--target', 'runtime', '-t', 'battleship-web:local', '.'])
    }
    report.docker = JSON.parse(await run('docker-version', docker, ['version', '--format', '{{json .}}']))
    report.compose = (await run('compose-version', docker, ['compose', 'version'])).trim()
    report.images = JSON.parse(await run('image-identities', docker, ['inspect', 'battleship-haskell:local', 'battleship-web:local', options.testImage ?? 'battleship-regression:test']))
      .map(image => ({ id: image.Id, tags: image.RepoTags }))
    reuseLinux = Boolean(previous && JSON.stringify(previous.images) === JSON.stringify(report.images))
    report.topology = await startNuma({ action: 'inspect', docker })
    let reference
    report.profiles = buildProfiles(report.topology)
    await inPairs(report.profiles, async profile => {
      if (!profile.config) return
      const c = profile.config
      if (c.ghcNuma) {
        try { await run('ghc-numa-support', docker, ['run', '--rm', '--network', 'none', '--entrypoint', '/usr/local/bin/battleship-server',
          'battleship-haskell:local', '+RTS', '-N1', c.ghcNuma, '--info', '-RTS']) }
        catch (error) {
          if (!/compiled without NUMA support/.test(error.stderr ?? '')) throw error
          report.commands.findLast(command => command.label === 'ghc-numa-support').expectedUnsupported = true
          profile.status = 'unaccepted'; profile.reason = 'Binary GHC 9.10.3 biên dịch không có NUMA support.'; return
        }
      }
      const cpus = c.haskell ? ['--cpuset-cpus', c.haskell.join(',')] : []
      const mems = c.mems ? ['--cpuset-mems', c.mems.join(',')] : []
      const rts = rtsCommand(4000, c).slice(2, -1).concat(c.ghcNuma ?? [])
      await run(`${profile.name}-linux`, docker, ['run', '--rm', ...cpus, ...mems, '--entrypoint', 'stack', options.testImage ?? 'battleship-regression:test',
        'test', '--system-ghc', '--no-install-ghc', '--ghc-options=-Werror', `--test-arguments=+RTS ${rts.join(' ')} -RTS`])
      const file = path.join(output, `${profile.name}.json`)
      await writeFile(file, JSON.stringify(profile, null, 2))
      const text = await node(`${profile.name}-compose`, ['--test', '--test-concurrency=1', '--test-reporter=tap',
        '--test-name-pattern=NM-08:|DK-07: 100 health|DK-07: one match|DK-08: strict|DK-08: exact|DK-08: restarting|DK-08: concurrent|DK-08: C-07|DK-08: two separate',
        'scripts/test-compose.mjs'], { BATTLESHIP_DOCKER_CLI: docker, BATTLESHIP_RUNTIME_PROFILE_FILE: file, BATTLESHIP_RUNTIME_EVIDENCE_DIR: output })
      profile.tests = parseTap(text)
      assert.equal(profile.tests.skipped, 0, 'Profile đủ điều kiện không được âm thầm bỏ test.')
      const transcript = JSON.parse(await readFile(path.join(output, `${profile.name}-transcript.json`), 'utf8'))
      reference ??= transcript
      profile.transcriptHash = compareTranscripts(reference, transcript)
      profile.status = 'passed'
    })
    report.status = 'passed-with-unaccepted-profiles'
    if (report.profiles.every(p => p.status === 'passed')) report.status = 'passed'
    return report
  } catch (error) { report.status = 'failed'; report.error = error.message; throw error }
  finally {
    report.finishedAt = new Date().toISOString()
    await writeFile(path.join(output, 'report.json'), JSON.stringify(report, null, 2))
    console.log(`NM-08 report: ${path.join(output, 'report.json')}`)
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const options = {}, args = process.argv.slice(2)
    while (args.length) {
      const key = args.shift()
      if (key === '--prepared') options.prepared = true
      else if (key === '--resume') options.resume = true
      else {
        const fields = { '--docker': 'docker', '--stack': 'stack', '--output': 'output', '--test-image': 'testImage' }
        assert.ok(fields[key] && args.length, `Tham số không hợp lệ: ${key}`); options[fields[key]] = args.shift()
      }
    }
    await runProfiles(options)
  } catch (error) { console.error(error.message); process.exitCode = 1 }
}
