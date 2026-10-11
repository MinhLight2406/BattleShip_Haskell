// Paired complete-game measurement: alternate old/new binaries on each profile.
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { promisify } from 'node:util'
import { parseSample, summarize } from '../../../scripts/benchmark-runtime.mjs'
import { inspectTopology } from '../../../scripts/inspect-topology.mjs'

assert.equal(process.argv.length, 4, 'Usage: paired-core.mjs OUTPUT SOURCE_HASHES_JSON')
const [output, sourceFile] = process.argv.slice(2)
const execute = promisify(execFile), sha = bytes => createHash('sha256').update(bytes).digest('hex')
const profiles = [{ name: 'N1', rts: ['-N1'] }, { name: 'N2', rts: ['-N2'] }, { name: 'default', rts: [] }]
const binaries = { before: '/usr/local/bin/battleship-benchmark-before', after: '/usr/local/bin/battleship-benchmark' }
const sample = async (variant, profile, count) => {
  const { stdout } = await execute(binaries[variant], ['core', String(count), '+RTS', ...profile.rts, '-T', '-RTS'],
    { timeout: 120000, maxBuffer: 1024 * 1024, env: { ...process.env, GHCRTS: '' } })
  const row = parseSample(stdout)
  assert.equal(row.compiler, 'ghc 9.10.3'); assert.equal(row.mode, 'core')
  return row
}
let count = 64
while (count < 100000 && (await sample('before', profiles[0], count)).elapsedNs < 500000000) count = Math.min(count * 2, 100000)
const wanted = (await sample('before', profiles[0], count)).checksum
const manifest = { schemaVersion: 1, startedAt: new Date().toISOString(), compiler: 'GHC 9.10.3', snapshot: 'lts-24.59',
  repetitions: count, samples: 30, warmups: 5, profiles, seeds: [424242, 8675309, 20261011],
  binaryHashes: Object.fromEntries(await Promise.all(Object.entries(binaries).map(async ([variant, file]) => [variant, sha(await readFile(file))]))),
  sourceHashes: JSON.parse(await readFile(sourceFile, 'utf8')), topology: await inspectTopology(),
  scriptSha256: sha(await readFile(new URL(import.meta.url))),
  scope: 'Full core replay + both views + structural checksum; 25 commands/game; includes fleet construction.',
  optimization: '-O2 for both binaries; after build also enables -Werror diagnostic gate',
  unsupportedMetrics: ['hardware cache misses', 'context switches', 'migrations', 'peak RSS'] }
await mkdir(output, { recursive: true })
await writeFile(output + '/manifest.json', JSON.stringify(manifest, null, 2))
await writeFile(output + '/samples.jsonl', '')
const rows = []
for (let index = -5; index < 30; index++) {
  for (let order = 0; order < profiles.length; order++) {
    const profile = profiles[(order + index + 5) % profiles.length]
    for (const variant of index % 2 === 0 ? ['before', 'after'] : ['after', 'before']) {
      const row = { ...await sample(variant, profile, count), variant, profile: profile.name, sampleIndex: index, warmup: index < 0 }
      assert.equal(row.checksum, wanted)
      if (profile.name !== 'default') assert.equal(row.capabilities, Number(profile.name.slice(1)))
      rows.push(row); await writeFile(output + '/samples.jsonl', JSON.stringify(row) + '\n', { flag: 'a' })
    }
  }
  if ((index + 1) % 10 === 0) console.error(`paired core: ${index + 1}/30`)
}
const results = profiles.flatMap(profile => ['before', 'after'].map(variant => ({ variant, profile: profile.name,
  ...summarize(rows.filter(row => !row.warmup && row.profile === profile.name && row.variant === variant)) })))
assert.ok(results.every(result => result.samples === 30))
const summary = { schemaVersion: 1, finishedAt: new Date().toISOString(), results }
await writeFile(output + '/summary.json', JSON.stringify(summary, null, 2))
console.log(JSON.stringify(summary, null, 2))
