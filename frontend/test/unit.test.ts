import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  createFleet, placeShip, autoPlaceFleet, cellsFor, coordinateKey, wireCoord,
  encodeFleet, parseFrame, applyFrame, emptyView, canFire, statusText,
  type ShipState, type Placement,
} from '../game.ts'

const placed = () => createFleet().map((ship, row): ShipState => ({
  ...ship, placement: { row, col: 0, orientation: 'horizontal' },
}))

test('column letter + row number match Haskell coordinates, including J10', () => {
  for (const [row, col, expected] of [[0, 0, 'A1'], [0, 1, 'B1'], [1, 0, 'A2'], [9, 9, 'J10']] as const)
    assert.equal(wireCoord({ row, col }), expected)
  for (const coord of [{ row: -1, col: 0 }, { row: 10, col: 0 }, { row: 0, col: 0.5 }]) assert.throws(() => wireCoord(coord))
})

test('placement rejects corners/overlap, allows touching and preserves input on errors', () => {
  const fleet = placed()
  const before = structuredClone(fleet)
  assert.equal(placeShip(fleet, 'carrier', { row: 9, col: 9, orientation: 'horizontal' }), null)
  assert.equal(placeShip(fleet, 'destroyer', { row: 1, col: 0, orientation: 'vertical' }), null)
  assert.ok(placeShip(fleet, 'destroyer', { row: 9, col: 8, orientation: 'horizontal' }))
  assert.ok(placeShip(fleet, 'destroyer', { row: 8, col: 9, orientation: 'vertical' }))
  assert.deepEqual(fleet, before)
  assert.equal(encodeFleet(fleet), 'PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H')
  assert.throws(() => encodeFleet(createFleet()))
  assert.throws(() => encodeFleet([...fleet.slice(0, 4), fleet[0]]))
})

test('random and exhausted random placement always produce 17 distinct in-board cells', () => {
  for (let iteration = 0; iteration < 100; iteration++) {
    const fleet = autoPlaceFleet(createFleet(), iteration === 0 ? () => 0 : Math.random)
    const cells = fleet.flatMap((ship) => cellsFor(ship as ShipState & { placement: Placement }))
    assert.equal(cells.length, 17)
    assert.equal(new Set(cells.map(coordinateKey)).size, 17)
    assert.ok(cells.every(({ row, col }) => row >= 0 && row <= 9 && col >= 0 && col <= 9))
    assert.equal(encodeFleet(fleet).split(';').length, 5)
  }
})

test('decode every actual server response in docs/protocol.md transcripts', () => {
  const text = readFileSync(new URL('../../docs/protocol.md', import.meta.url), 'utf8')
  const lines = [...text.matchAll(/^S -> C[123]: (.+)$/gm)].map((match) => match[1].trim())
  assert.ok(lines.length >= 35)
  for (const line of lines) assert.ok(parseFrame(line), line)
  assert.deepEqual(parseFrame('INCOMING J10 SUNK SB'), { kind: 'INCOMING', coord: 'J10', outcome: 'SUNK SB' })
  for (const invalid of ['WELCOME 2 P1', 'START P2', 'SHOT A01 HIT', 'SHOT K1 MISS', 'SHOT A1 SUNK CG',
    'TURN  P1', 'TURN P1\n', 'ERROR NOT_YOUR_TURN', 'ERROR INVALID_FLEET_SIZE 257',
    'ERROR INVALID_FLEET_SIZE 01', 'ERROR SHIPS_OVERLAP J11', 'ERROR ???', 'x'.repeat(257)]) {
    assert.throws(() => parseFrame(invalid), invalid)
  }
})

test('server events alone drive turns, error preservation and private shot history', () => {
  let view = emptyView()
  for (const frame of ['WELCOME 1 P1', 'OK PLACE', 'WAITING OPPONENT', 'START P1']) view = applyFrame(view, parseFrame(frame))
  assert.equal(canFire(view, 'A1', false), false, 'START alone must not grant a turn')
  view = applyFrame(view, parseFrame('TURN P1'))
  assert.equal(canFire(view, 'A1', true), false)
  assert.equal(canFire(view, 'A1', false), true)
  assert.equal(canFire(view, 'K1', false), false)
  view = applyFrame(view, parseFrame('SHOT A1 HIT'))
  assert.equal(canFire(view, 'A1', false), false)
  const before = structuredClone(view)
  view = applyFrame(view, parseFrame('ERROR NOT_YOUR_TURN P2'))
  assert.deepEqual(view.outgoing, before.outgoing)
  assert.equal(view.turn, before.turn, 'ERROR must not invent a state transition')
  view = applyFrame(view, parseFrame('TURN P2'))
  assert.equal(canFire(view, 'B1', false), false)
  view = applyFrame(view, parseFrame('INCOMING J10 MISS'))
  assert.deepEqual(view.incoming, { J10: 'MISS' })
  view = applyFrame(view, parseFrame('GAME_OVER P1 ALL_SHIPS_SUNK'))
  assert.equal(canFire(view, 'B1', false), false)
  assert.match(statusText(view, false), /Bạn thắng/)
  assert.deepEqual(Object.keys(view.outgoing), ['A1'])
  for (const hidden of ['B1', 'C1', 'D1', 'E1']) assert.equal(JSON.stringify(view).includes(hidden), false)
  assert.equal('enemyFleet' in view, false)
})
