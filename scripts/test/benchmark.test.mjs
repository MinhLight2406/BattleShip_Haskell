import { test } from 'node:test'
import assert from 'node:assert/strict'
import { parseRTS, parseSample, quantile, summarize } from '../benchmark-runtime.mjs'

const sample = { schemaVersion: 1, elapsedNs: 1e9, games: 3, commands: 75, capabilities: 1, checksum: '18446744073709551615' }
test('JSON parser retains a 64-bit checksum as a string and marks optional metrics missing', () => {
  const parsed = parseSample(JSON.stringify(sample))
  assert.equal(parsed.checksum, sample.checksum)
  assert.equal(parsed.allocatedBytes, null)
  assert.equal(parsed.gcCpuSecondsAccounting, null)
})
test('unsupported, invalid and null metrics never become zero', () => {
  const parsed = parseSample(JSON.stringify({ ...sample, allocatedBytes: 'N/A', cpuSeconds: -1,
    gcCpuSecondsAccounting: null, maxLiveBytesProcess: 'NaN', maxMemoryBytesProcess: 0 }))
  assert.equal(parsed.allocatedBytes, null)
  assert.equal(parsed.cpuSeconds, null)
  assert.equal(parsed.gcCpuSecondsAccounting, null)
  assert.equal(parsed.maxLiveBytesProcess, null)
  assert.equal(parsed.maxMemoryBytesProcess, 0)
})
test('invalid required metrics/schema/checksum fail instead of producing a baseline', () => {
  for (const replacement of [{ schemaVersion: 2 }, { elapsedNs: 0 }, { commands: null }, { checksum: 42 }]) {
    assert.throws(() => parseSample(JSON.stringify({ ...sample, ...replacement })))
  }
})
test('RTS parser handles real machine-readable pairs, optional omissions and ordinary stderr', () => {
  const parsed = parseRTS('server diagnostic\n[("bytes allocated", "1234"), ("GC_cpu_seconds", "1.2e-3"), ("max_bytes_used", "5678"), ("peak_megabytes_allocated", "8")]')
  assert.equal(parsed.allocatedBytes, 1234)
  assert.equal(parsed.gcCpuSecondsProcess, .0012)
  assert.equal(parsed.maxLiveBytesProcess, 5678)
  assert.equal(parsed.maxMemoryBytesProcess, 8 * 1024 * 1024)
  assert.equal(parsed.cpuSeconds, null)
  assert.equal(parsed.migrations, null)
  assert.equal(parseRTS('counter unavailable').allocatedBytes, null)
})
test('summary computes medians, response p95 and three-block noise using measured samples', () => {
  const samples = Array.from({ length: 30 }, (_, index) => ({ ...sample, elapsedNs: (index + 1) * 75000,
    allocatedBytes: index < 2 ? null : 7500, responseUs: [index + 1] }))
  const result = summarize(samples)
  assert.equal(result.medianUsPerCommand, 15.5)
  assert.ok(Math.abs(result.p95ResponseUs - 28.55) < 1e-10)
  assert.deepEqual(result.blockMedians, [5.5, 15.5, 25.5])
  assert.equal(result.stable, false)
  assert.equal(result.allocatedBytesPerCommand.median, 100)
  assert.equal(result.allocatedBytesPerCommand.availableSamples, 28)
  assert.deepEqual(summarize(samples).median95CI, result.median95CI, 'bootstrap seed is fixed')
})
test('summary preserves unknown metrics and insufficient blocks as null', () => {
  const result = summarize([sample])
  assert.equal(result.stable, null)
  assert.equal(result.gcCpuSecondsProcess.median, null)
  assert.equal(result.p95ResponseUs, null)
  assert.equal(quantile([], .95), null)
})
