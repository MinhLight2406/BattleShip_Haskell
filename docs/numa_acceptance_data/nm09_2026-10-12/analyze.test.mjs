import assert from 'node:assert/strict'
import test from 'node:test'
import { compare } from './analyze.mjs'

const samples = (us) => Array.from({ length: 30 }, () => ({ elapsedNs: us * 1000, commands: 1 }))
const summary = (us, stable = true) => ({ medianUsPerCommand: us, stable, allocatedBytesPerCommand: { median: 100 } })
test('same samples give zero change and reproducible CI', () => {
  const args = [summary(10), summary(10), samples(10), samples(10)]
  const first = compare(...args)
  assert.equal(first.observedPercentChange, 0)
  assert.deepEqual(first.paired95CI, [0, 0])
  assert.deepEqual(compare(...args), first)
  assert.equal(first.causalAttribution, false)
})
test('faster median retains sign but drift disqualifies timing', () => {
  const value = compare(summary(10), summary(5, false), samples(10), samples(5))
  assert.equal(value.observedPercentChange, -50)
  assert.deepEqual(value.paired95CI, [-50, -50])
  assert.equal(value.timingEligible, false)
})
test('zero and missing/short groups cannot become formal measurements', () => {
  assert.throws(() => compare(summary(0), summary(5), samples(10), samples(5)))
  assert.throws(() => compare(summary(10), summary(5), samples(10).slice(1), samples(5)))
})
