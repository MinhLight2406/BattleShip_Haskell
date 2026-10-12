import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { quantile, summarize } from '../../../scripts/benchmark-runtime.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(here, '../../..')
const json = async (file) => JSON.parse(await readFile(path.join(root, file), 'utf8'))
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex')
const change = (before, after) => (after / before - 1) * 100

// Pair whole samples, never individual commands, and retain each source group's stability gate.
export function compare(before, after, beforeSamples, afterSamples) {
  assert.equal(beforeSamples.length, 30)
  assert.equal(afterSamples.length, 30)
  assert.ok(before.medianUsPerCommand > 0 && after.medianUsPerCommand > 0)
  const values = (samples) => samples.map((x) => x.elapsedNs / x.commands / 1000)
  const b = values(beforeSamples), a = values(afterSamples), draws = []
  let seed = 20261011
  for (let round = 0; round < 2000; round++) {
    const indices = b.map(() => { seed = (Math.imul(1664525, seed) + 1013904223) >>> 0; return seed % b.length })
    draws.push(change(quantile(indices.map((i) => b[i]), .5), quantile(indices.map((i) => a[i]), .5)))
  }
  return { observedPercentChange: change(before.medianUsPerCommand, after.medianUsPerCommand),
    paired95CI: [quantile(draws, .025), quantile(draws, .975)],
    timingEligible: before.stable === true && after.stable === true,
    causalAttribution: false, scope: 'cross-batch versions; paired by index for bootstrap, not isolated intervention',
    allocationPercentChange: change(before.allocatedBytesPerCommand.median, after.allocatedBytesPerCommand.median) }
}

async function readSeries(directory, layers) {
  const manifest = await json(`${directory}/manifest.json`)
  assert.equal(manifest.smoke, false, 'formal comparison needs full series')
  assert.equal(manifest.samples, 30)
  assert.equal(manifest.warmups, 5)
  assert.deepEqual(manifest.seeds, [424242, 8675309, 20261011])
  const all = (await readFile(path.join(root, directory, 'samples.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse)
  const expected = await json(`${directory}/summary.json`)
  assert.equal(all.length, layers.length * 3 * 35)
  assert.equal(all.filter((x) => !x.warmup).length, layers.length * 3 * 30)
  const groups = []
  for (const layer of layers) for (const profile of ['N1', 'N2', 'default']) {
    const samples = all.filter((x) => !x.warmup && x.mode === layer && x.profile === profile)
    assert.equal(samples.length, 30, `${layer}/${profile}`)
    assert.deepEqual(samples.map((x) => x.sampleIndex), Array.from({ length: 30 }, (_, i) => i))
    const summary = summarize(samples)
    const stored = expected.results.find((x) => x.mode === layer && x.profile === profile)
    for (const key of Object.keys(summary)) assert.deepEqual(summary[key], stored[key], `${directory} ${layer}/${profile}: ${key}`)
    groups.push({ mode: layer, profile, ...summary, raw: samples })
  }
  return { directory, manifest, groups }
}

export async function analyze() {
  const before = await readSeries('docs/performance_data/nm03_2026-10-11', ['core', 'coordinator', 'tcp', 'web'])
  const after = await readSeries('docs/numa_acceptance_data/nm09_2026-10-12/combined', ['core', 'coordinator', 'worker', 'tcp', 'web'])
  assert.equal(after.manifest.fixtureHash, before.manifest.fixtureHash)
  assert.equal(after.manifest.buildFlags, '-O2')
  assert.equal(after.manifest.compiler, 'ghc 9.10.3')
  const comparisons = before.groups.map((b) => {
    const a = after.groups.find((x) => x.mode === b.mode && x.profile === b.profile)
    return { mode: b.mode, profile: b.profile, beforeUs: b.medianUsPerCommand, afterUs: a.medianUsPerCommand,
      ...compare(b, a, b.raw, a.raw) }
  })
  const source = before.manifest.source.sourceHashes, snapshot = []
  for (const [file, expected] of Object.entries(source)) {
    const actual = sha(await readFile(path.join(here, 'baseline-source', file)))
    snapshot.push({ file, expected, actual, matches: actual === expected })
  }
  assert.deepEqual(snapshot.filter((x) => !x.matches).map((x) => x.file), ['scripts/benchmark-runtime.mjs'])
  const cleanGroups = after.groups.map(({ raw, ...rest }) => rest)
  const result = { schemaVersion: 1, analyzedAt: new Date().toISOString(),
    combined: { source: after.directory, measured: 450, warmups: 75, groups: cleanGroups }, comparisons,
    baselineSnapshot: { matchingFiles: 24, total: 25, exactHistoricalHarness: false, files: snapshot },
    note: 'Timing eligibility alone does not establish cause across separate batches. Null means unavailable, never zero.' }
  await writeFile(path.join(here, 'analysis.json'), JSON.stringify(result, null, 2) + '\n')
  await writeFile(path.join(here, 'snapshot.json'), JSON.stringify(result.baselineSnapshot, null, 2) + '\n')
  const fmt = (x) => x === null || !Number.isFinite(x) ? 'N/A' : x.toLocaleString('vi-VN', { minimumFractionDigits: 3, maximumFractionDigits: 3 })
  const rows = cleanGroups.map((x) => `| ${x.mode}/${x.profile} | ${fmt(x.medianUsPerCommand)} | ${fmt(x.p95ResponseUs)} | ${fmt(x.stabilitySpread * 100)}% | ${x.stable ? 'Đạt' : 'Chưa ổn định'} | ${fmt(x.allocatedBytesPerCommand.median)} |`)
  const changes = comparisons.map((x) => `| ${x.mode}/${x.profile} | ${fmt(x.beforeUs)} | ${fmt(x.afterUs)} | ${fmt(x.observedPercentChange)}% | [${fmt(x.paired95CI[0])}%; ${fmt(x.paired95CI[1])}%] | ${x.timingEligible ? 'Hai nhóm đạt' : 'Không đủ stability'} |`)
  const unstable = cleanGroups.filter((x) => !x.stable).map((x) => `${x.mode}/${x.profile}`)
  const block = `Series mới gồm **450 measured +75 warm-up**, ${cleanGroups.filter((x) => x.stable).length}/15 nhóm đạt stability. Thời điểm và calibration ở manifest.\n\n| Layer/profile | Median µs/command | p95 response µs | Spread | Stability | Allocation byte/command |\n|---|---:|---:|---:|---|---:|\n${rows.join('\n')}\n\nCore/coordinator/worker không có p95 response socket nên ghi N/A. p95 response mạng khác p95 của sample mean.\n\n| NM-03 →NM-09 | Baseline µs/command | Kết hợp µs/command | Thay đổi median | CI bootstrap cross-batch | Gate hai nhóm |\n|---|---:|---:|---:|---|---|\n${changes.join('\n')}\n\n${unstable.length ? `Nhóm chưa ổn định: **${unstable.join(', ')}**; không dùng median/CI của những nhóm đó để tuyên bố tăng tốc.` : 'Mọi nhóm loạt đầu đạt stability; điều đó không biến cross-batch comparison thành ablation nhân quả.'}\n\nDữ liệu máy đọc và phép tính lại: [analysis.json](numa_acceptance_data/nm09_2026-10-12/analysis.json). Dương là chậm hơn, âm là nhanh hơn trong series; không cộng phần trăm các thay đổi.\n`
  const document = path.join(root, 'docs/numa_acceptance.md')
  const text = await readFile(document, 'utf8')
  assert.equal(text.split('<!-- nm09:combined:start -->').length, 2)
  await writeFile(document, text.replace(/<!-- nm09:combined:start -->[\s\S]*?<!-- nm09:combined:end -->/, `<!-- nm09:combined:start -->\n\n${block}\n<!-- nm09:combined:end -->`))
  return { groups: cleanGroups.length, unstable, matchingBaselineFiles: 24 }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  console.log(JSON.stringify(await analyze(), null, 2))
}
