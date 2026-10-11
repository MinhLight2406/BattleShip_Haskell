// NM-06: separate lookup/union/construction costs, with retained-heap accounting.
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { fileURLToPath, pathToFileURL } from 'node:url'
import path from 'node:path'
import { promisify } from 'node:util'
import { parseSample, summarize } from './benchmark-runtime.mjs'
import { inspectTopology } from './inspect-topology.mjs'

const execute = promisify(execFile)
export function summarizeFleet(rows) {
  const result = summarize(rows)
  const retained = rows.filter(row => row.retainedFleets > 0 && Number.isFinite(row.retainedHeapDeltaBytes))
  result.retainedBytesPerFleet = retained.length
    ? retained.reduce((sum, row) => sum + row.retainedHeapDeltaBytes / row.retainedFleets, 0) / retained.length : null
  return result
}

async function main(args) {
  assert.equal(args.length, 3, 'Usage: benchmark-fleet.mjs before|after OUTPUT SOURCE_HASHES_JSON')
  const [label, outputArg, hashesArg] = args
  assert.ok(['before', 'after'].includes(label))
  const output = path.resolve(outputArg), binary = '/usr/local/bin/battleship-fleet-benchmark'
  const modes = label === 'before' ? ['scan', 'union', 'construct', 'retain']
    : ['scan', 'indexed', 'union', 'cached', 'construct', 'retain']
  const sha = bytes => createHash('sha256').update(bytes).digest('hex')
  const topology = await inspectTopology()
  assert.equal(topology.inspectionOk, true)
  assert.equal(topology.cpu.effective.length, 1, 'Run this microbenchmark with one selected allowed CPU')
  const sample = async (mode, count) => {
    const { stdout } = await execute(binary, [mode, String(count), '+RTS', '-N1', '-T', '-RTS'],
      { env: { ...process.env, GHCRTS: '' }, timeout: 120000, maxBuffer: 1024 * 1024 })
    const row = parseSample(stdout)
    assert.equal(row.mode, mode); assert.equal(row.capabilities, 1)
    return row
  }
  const counts = {}, checksums = {}
  for (const mode of modes) {
    let count = mode === 'retain' ? 2000 : 64
    if (mode !== 'retain') {
      while (count < 1000000 && (await sample(mode, count)).elapsedNs < 500000000) count = Math.min(count * 2, 1000000)
    }
    counts[mode] = count; checksums[mode] = (await sample(mode, count)).checksum
  }
  const manifest = { schemaVersion: 1, label, startedAt: new Date().toISOString(), compiler: 'GHC 9.10.3',
    snapshot: 'lts-24.59', buildFlags: label === 'before' ? '-O2' : '-O2 -Werror', binarySha256: sha(await readFile(binary)),
    scriptSha256: sha(await readFile(fileURLToPath(import.meta.url))),
    sourceHashes: JSON.parse(await readFile(hashesArg, 'utf8')), topology, counts,
    seeds: [424242, 8675309, 20261011], samples: 30, warmups: 5, rts: ['-N1', '-T'],
    unit: 'lookup / union traversal / constructed fleet, according to mode',
    unsupportedMetrics: ['hardware cache misses', 'migrations', 'context switches', 'peak RSS'],
    retainedScope: 'live heap delta after GC / retained fleets; includes list/reference overhead, not RSS' }
  await mkdir(output, { recursive: true })
  await writeFile(path.join(output, 'manifest.json'), JSON.stringify(manifest, null, 2))
  await writeFile(path.join(output, 'samples.jsonl'), '')
  const rows = []
  for (let index = -5; index < 30; index++) {
    for (let order = 0; order < modes.length; order++) {
      const mode = modes[(order + index + 5) % modes.length]
      const row = { ...await sample(mode, counts[mode]), sampleIndex: index, warmup: index < 0 }
      assert.equal(row.checksum, checksums[mode], 'Checksum changed between repetitions')
      rows.push(row)
      await writeFile(path.join(output, 'samples.jsonl'), JSON.stringify(row) + '\n', { flag: 'a' })
    }
    if ((index + 1) % 10 === 0) console.error(`${label}: ${index + 1}/30`)
  }
  const results = modes.map(mode => ({ mode, ...summarizeFleet(rows.filter(row => !row.warmup && row.mode === mode)) }))
  const summary = { schemaVersion: 1, finishedAt: new Date().toISOString(), results }
  await writeFile(path.join(output, 'summary.json'), JSON.stringify(summary, null, 2))
  console.log(JSON.stringify(summary, null, 2))
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  main(process.argv.slice(2)).catch(error => { console.error(error.stack); process.exitCode = 1 })
