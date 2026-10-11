// Repeat a whole worker layer after the first measurement exceeded NM-01 noise.
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { promisify } from 'node:util'
import { parseSample, summarize } from '../../../scripts/benchmark-runtime.mjs'
import { inspectTopology } from '../../../scripts/inspect-topology.mjs'

assert.equal(process.argv.length, 4, 'Usage: repeat-worker.mjs FIRST_RUN_DIRECTORY OUTPUT_DIRECTORY')
const [first, output] = process.argv.slice(2).map(value => path.resolve(value))
const root = fileURLToPath(new URL('../../../', import.meta.url))
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const original = JSON.parse(await readFile(path.join(first, 'manifest.json'), 'utf8'))
const originalSummary = JSON.parse(await readFile(path.join(first, 'summary.json'), 'utf8'))
assert.equal(originalSummary.results.length, 15, 'The first run must have completed all five layers')
assert.equal(original.smoke, false)
const binary = '/usr/local/bin/battleship-benchmark'
assert.equal(hash(await readFile(binary)), original.binaryHashes.benchmark)
for (const [file, digest] of Object.entries(original.source.sourceHashes))
  assert.equal(hash(await readFile(path.join(root, file))), digest, `Source changed: ${file}`)
const topology = await inspectTopology()
assert.equal(topology.inspectionOk, true)
assert.deepEqual(topology.cpu.effective, original.topology.cpu.effective)
const count = original.repetitions.worker
assert.ok(Number.isSafeInteger(count) && count > 0)
const originalRows = (await readFile(path.join(first, 'samples.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse)
const wanted = originalRows.find(row => row.mode === 'worker').checksum
const manifest = { schemaVersion: 1, reason: 'First worker layer exceeded 10% block median spread',
  startedAt: new Date().toISOString(), firstManifestSha256: hash(await readFile(path.join(first, 'manifest.json'))),
  scriptSha256: hash(await readFile(fileURLToPath(import.meta.url))),
  source: original.source, binaryHashes: original.binaryHashes, topology, profiles: original.profiles,
  repetitions: count, samples: 30, warmups: 5, compiler: original.compiler, snapshot: original.snapshot,
  buildFlags: original.buildFlags, fixtureHash: original.fixtureHash }
await mkdir(output, { recursive: true })
await writeFile(path.join(output, 'manifest.json'), JSON.stringify(manifest, null, 2))
await writeFile(path.join(output, 'samples.jsonl'), '')
const execute = promisify(execFile), rows = []
for (let index = -5; index < 30; index++) {
  for (let order = 0; order < 3; order++) {
    const profile = original.profiles[(order + index + 5) % 3]
    const result = await execute(binary, ['worker', String(count), '+RTS', ...profile.rts, '-T', '-RTS'],
      { env: { ...process.env, GHCRTS: '' }, timeout: 120000, maxBuffer: 1024 * 1024 })
    const row = { ...parseSample(result.stdout), profile: profile.name, sampleIndex: index, warmup: index < 0 }
    assert.equal(row.mode, 'worker'); assert.equal(row.compiler, original.compiler); assert.equal(row.checksum, wanted)
    const expectedN = originalRows.find(value => value.mode === 'worker' && value.profile === profile.name).capabilities
    assert.equal(row.capabilities, expectedN)
    rows.push(row)
    await writeFile(path.join(output, 'samples.jsonl'), JSON.stringify(row) + '\n', { flag: 'a' })
  }
  if (index < 0 || (index + 1) % 10 === 0) console.error(`worker repeat: ${index < 0 ? 'warmup ' + (index + 6) : 'sample ' + (index + 1)}/30`)
}
const results = original.profiles.map(profile => ({ mode: 'worker', profile: profile.name,
  ...summarize(rows.filter(row => !row.warmup && row.profile === profile.name)) }))
assert.ok(results.every(result => result.samples === 30))
const summary = { schemaVersion: 1, finishedAt: new Date().toISOString(), results }
await writeFile(path.join(output, 'summary.json'), JSON.stringify(summary, null, 2))
console.log(JSON.stringify(summary, null, 2))
