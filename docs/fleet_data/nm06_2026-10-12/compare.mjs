// Deterministic paired bootstrap over complete samples, never selected outliers.
import assert from 'node:assert/strict'
import { readFile, writeFile } from 'node:fs/promises'
import { quantile } from '../../../scripts/benchmark-runtime.mjs'
const json = async file => JSON.parse(await readFile(new URL(file, import.meta.url), 'utf8'))
const rows = async file => (await readFile(new URL(file, import.meta.url), 'utf8')).trim().split('\n').map(JSON.parse)
function pairedRatio(first, second) {
  const a = new Map(first.filter(row => !row.warmup).map(row => [row.sampleIndex, row.elapsedNs / row.commands]))
  const b = new Map(second.filter(row => !row.warmup).map(row => [row.sampleIndex, row.elapsedNs / row.commands]))
  const ids = [...a.keys()].sort((x, y) => x - y)
  assert.equal(ids.length, 30); assert.ok(ids.every(id => b.has(id)))
  let seed = 20261011
  const ratios = []
  for (let i = 0; i < 2000; i++) {
    const sample = ids.map(() => { seed = (Math.imul(1664525, seed) + 1013904223) >>> 0; return ids[seed % ids.length] })
    ratios.push((quantile(sample.map(id => b.get(id)), .5) / quantile(sample.map(id => a.get(id)), .5) - 1) * 100)
  }
  return { observedPercentChange: (quantile([...b.values()], .5) / quantile([...a.values()], .5) - 1) * 100,
    paired95CI: [quantile(ratios, .025), quantile(ratios, .975)], bootstrapDraws: 2000, seed: 20261011 }
}
const micro = await rows('after-repeat/samples.jsonl')
const microSummary = await json('after-repeat/summary.json')
const byMode = Object.fromEntries(microSummary.results.map(row => [row.mode, row]))
const lookup = pairedRatio(micro.filter(row => row.mode === 'scan'), micro.filter(row => row.mode === 'indexed'))
const occupied = pairedRatio(micro.filter(row => row.mode === 'union'), micro.filter(row => row.mode === 'cached'))
lookup.timingEligible = byMode.scan.stable && byMode.indexed.stable
occupied.timingEligible = byMode.union.stable && byMode.cached.stable
const core = await rows('core-paired-repeat/samples.jsonl')
const coreSummary = await json('core-paired-repeat/summary.json')
const game = ['N1', 'N2', 'default'].map(profile => {
  const first = coreSummary.results.find(row => row.profile === profile && row.variant === 'before')
  const second = coreSummary.results.find(row => row.profile === profile && row.variant === 'after')
  return { profile, ...pairedRatio(core.filter(row => row.profile === profile && row.variant === 'before'),
    core.filter(row => row.profile === profile && row.variant === 'after')), timingEligible: first.stable && second.stable,
    allocationPercentChange: (second.allocatedBytesPerCommand.median / first.allocatedBytesPerCommand.median - 1) * 100 }
})
const result = { schemaVersion: 1, lookup, occupied, game,
  note: 'Timing requires BOTH complete groups to meet <=10% noise; CI alone cannot override failed stability. No causal CPU-cache claim.' }
await writeFile(new URL('comparisons.json', import.meta.url), JSON.stringify(result, null, 2) + '\n')
console.log(JSON.stringify(result, null, 2))
