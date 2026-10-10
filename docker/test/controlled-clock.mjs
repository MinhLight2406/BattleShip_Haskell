// Test-only entrypoint mounted into web; production bridge/API/images remain unchanged.
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync } from 'node:fs'
import { mock } from 'node:test'
import { createBridge, readBridgeConfig } from '/app/bridge.mjs'

mock.timers.enable({ apis: ['Date', 'setTimeout'], now: Date.now() })
const config = readBridgeConfig()
const bridge = createBridge(config)
let elapsed = 0
const status = () => writeFileSync('/tmp/dk08-clock-status.json', JSON.stringify({ elapsed, now: Date.now() }))
status()
bridge.server.listen(config.port, config.host)
const control = setInterval(() => {
  const next = JSON.parse(readFileSync('/run/battleship-lan/clock.json')).elapsed
  assert.ok(Number.isSafeInteger(next) && next >= elapsed && next <= 600000)
  if (next === elapsed) return
  mock.timers.tick(next - elapsed); elapsed = next; status()
}, 50)
for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, async () => {
  clearInterval(control)
  await bridge.close()
  mock.timers.reset()
})
