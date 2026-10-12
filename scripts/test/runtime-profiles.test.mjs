import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { buildProfiles, compareTranscripts, inPairs, parseTap, redact, validateProfile } from '../test-runtime-profiles.mjs'

const topology = (ids = [0, 1, 4], nodes = [0]) => ({ inspectionOk: true,
  cpu: { online: ids, allowed: ids, effective: ids, details: ids.map(id => ({ id, coreId: id, socketId: 0, nodeIds: [nodes[0]] })) },
  memory: { onlineNodes: nodes, allowedNodes: nodes, nodes: nodes.map((id, i) => ({ id, allowed: true,
    memoryBytes: 1e9, effectiveCpus: i ? [] : ids })) } })
const base = () => buildProfiles(topology())[0]

test('artifact logs redact raw/escaped recovery tokens and resume URLs while preserving binary checksums', () => {
  const token = 'a'.repeat(64), checksum = 'b'.repeat(64)
  const payload = JSON.stringify({ token })
  const input = [payload, JSON.stringify(payload), `resume=${token}`, `sha256=${checksum}`].join('\n')
  const output = redact(input)
  assert.equal(output.includes(token), false)
  assert.equal(output.includes(checksum), true)
  assert.equal(output.match(/\[REDACTED\]/g).length, 3)
})

test('profile batches admit at most two independent jobs and finish every job', async () => {
  let active = 0, maximum = 0
  const seen = []
  await inPairs([0, 1, 2, 3, 4], async value => {
    active++; maximum = Math.max(maximum, active)
    await Promise.resolve(); seen.push(value); active--
  })
  assert.equal(maximum, 2); assert.equal(active, 0); assert.deepEqual(seen.sort(), [0, 1, 2, 3, 4])
})
test('a failed profile waits for sibling cleanup and does not launch the next batch', async () => {
  let cleaned = false
  const seen = []
  await assert.rejects(inPairs([0, 1, 2], async value => {
    seen.push(value)
    if (value === 0) throw new Error('profile failed')
    await Promise.resolve(); cleaned = true
  }), /profile failed/)
  assert.equal(cleaned, true); assert.deepEqual(seen, [0, 1])
})

test('matrix keeps CPU IDs from topology, marks missing remote separately, and uses worker capability 1 for N2', () => {
  const profiles = buildProfiles(topology([3, 7]))
  assert.deepEqual(profiles.find(p => p.name === 'affinity-single').config.haskell, [7])
  assert.equal(profiles.find(p => p.name === 'N2').config.gameCapability, 1)
  for (const name of ['affinity-qa', 'numa-remote']) assert.equal(profiles.find(p => p.name === name).status, 'unaccepted')
  assert.equal(profiles.find(p => p.name === 'numa-local').config.mems[0], 0)
})
test('memory-only remote node is eligible and preserves local CPU/workload settings', () => {
  const profiles = buildProfiles(topology([0, 1], [2, 9]))
  const local = profiles.find(p => p.name === 'numa-local').config, remote = profiles.find(p => p.name === 'numa-remote').config
  assert.deepEqual(local.haskell, remote.haskell); assert.equal(local.capabilities, remote.capabilities)
  assert.deepEqual(remote.mems, [9])
})
test('unknown topology and malformed profile masks, capabilities, policy or RTS are rejected', () => {
  assert.throws(() => buildProfiles({ inspectionOk: false }))
  for (const changes of [{ capabilities: 0 }, { gameCapability: 1 }, { haskell: [] }, { haskell: [2, 1] },
    { haskell: [1], capabilities: 2 }, { web: [-1] }, { policy: 'wildcard' }, { policy: 'membind' },
    { ghcNuma: '--numa=1 -N99' }, { mode: 'rts', haskell: [3] }]) {
    const p = base(); Object.assign(p.config, changes); assert.throws(() => validateProfile(p))
  }
})
test('TAP missing metrics, all skipped, failure, cancellation and inconsistent totals cannot pass', () => {
  const good = '# tests 2\n# pass 2\n# fail 0\n# cancelled 0\n# skipped 0\n# todo 0\n'
  assert.equal(parseTap(good).pass, 2)
  for (const bad of ['', good.replace('# tests 2', '# tests 3'), good.replace('# fail 0', '# fail 1'),
    good.replace('# cancelled 0', '# cancelled 1'), good.replace('# pass 2', '# pass 0').replace('# skipped 0', '# skipped 2')])
    assert.throws(() => parseTap(bad))
})
test('transcript comparison detects order, outcome, missing seed and leaked session metadata', () => {
  const fixtures = JSON.parse(readFileSync(new URL('../../bench/fixtures-v1.json', import.meta.url), 'utf8'))
  const original = { schemaVersion: 1, games: fixtures.map(f => ({ seed: f.seed, frames: ['P1', 'P2'].map(p =>
    [`WELCOME 1 ${p}`, ...f.commands.flatMap(c => c.responses[p])]) })) }
  assert.match(compareTranscripts(original, structuredClone(original)), /^[a-f0-9]{64}$/)
  for (const change of [x => x.games.pop(), x => x.games[0].frames[0].reverse(),
    x => x.games[0].frames[0].push('{"token":"secret"}'), x => x.games[0].frames[0][1] = 'ERROR WRONG']) {
    const altered = structuredClone(original); change(altered); assert.throws(() => compareTranscripts(original, altered))
  }
})
