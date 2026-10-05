import { test } from 'node:test'
import assert from 'node:assert/strict'
import { parseBridgeMessage, decodeOwnFleet, replayView, recoveryURL } from '../connection.ts'
import { encodeFleet, canFire, statusText } from '../game.ts'

const fleet = 'PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H'
const token = 'b'.repeat(64)
test('own fleet and filtered frames reconstruct exactly the same turn and boards', () => {
  assert.equal(encodeFleet(decodeOwnFleet(fleet)), fleet)
  for (const bad of [fleet.replace('A1:H', 'J10:H'), fleet.replace('A5:H', 'A1:H'), fleet + ';XX=A6:H'])
    assert.throws(() => decodeOwnFleet(bad))
  const view = replayView(['WELCOME 1 P1', 'OK PLACE', 'START P1', 'TURN P1', 'SHOT A6 HIT', 'TURN P1'])
  assert.deepEqual(view.outgoing, { A6: 'HIT' })
  assert.equal(canFire(view, 'A6', false), false)
  assert.equal(canFire(view, 'B6', false), true)
  view.missing = [{ player: 'P2', deadline: Date.now() + 300000 }]
  assert.equal(canFire(view, 'B6', false), false)
  assert.match(statusText(view, false), /Tạm dừng/)
})
test('transport metadata validates tokens, players and frames independently from protocol v1', () => {
  for (const frame of [
    { type: 'SESSION', token, fleet, frames: ['WELCOME 1 P1', 'OK PLACE'] },
    { type: 'CONNECTION', missing: [{ player: 'P1', deadline: Date.now() + 300000 }] },
    { type: 'RESUME_ERROR', code: 'INVALID_SESSION', message: 'Expired' },
  ]) assert.deepEqual(parseBridgeMessage(JSON.stringify(frame)), frame)
  for (const invalid of [
    { type: 'SESSION', token: 'P1', fleet: null, frames: null },
    { type: 'SESSION', token, fleet: null, frames: ['SECRET A1'] },
    { type: 'CONNECTION', missing: [{ player: 'P3', deadline: 10 }] },
    { type: 'CONNECTION', missing: [{ player: 'P1', deadline: -1 }] },
  ]) assert.throws(() => parseBridgeMessage(JSON.stringify(invalid)))
})
test('recovery across IPs puts the secret in a fragment; rejects unrelated URLs', () => {
  assert.equal(recoveryURL('http://192.168.0.25:8081', token), `http://192.168.0.25:8081/#resume=${token}`)
  for (const bad of ['javascript:alert(1)', 'https://192.168.0.25:8081', 'http://user:pass@192.168.0.25',
    'http://example.com', 'http://192.168.0.25/play', 'http://0.0.0.0', 'http://192.168.0.25:0'])
    assert.throws(() => recoveryURL(bad, token))
})
