import assert from 'node:assert/strict'
import { test } from 'node:test'
import { summarizeFleet } from '../benchmark-fleet.mjs'

test('retained heap is reported only for live retained fleets, separately from allocation', () => {
  const row = { elapsedNs: 1000, commands: 1, allocatedBytes: 5000, retainedFleets: 2, retainedHeapDeltaBytes: 200 }
  const result = summarizeFleet(Array.from({ length: 30 }, () => row))
  assert.equal(result.retainedBytesPerFleet, 100)
  assert.equal(result.allocatedBytesPerCommand.median, 5000)
  assert.equal(result.stable, true)
})
test('missing retained heap is unavailable rather than zero', () => {
  assert.equal(summarizeFleet([{ elapsedNs: 1000, commands: 1 }]).retainedBytesPerFleet, null)
  assert.equal(summarizeFleet([{ elapsedNs: 1000, commands: 1, retainedFleets: 0, retainedHeapDeltaBytes: 0 }]).retainedBytesPerFleet, null)
})
