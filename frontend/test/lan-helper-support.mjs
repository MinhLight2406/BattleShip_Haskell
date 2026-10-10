import assert from 'node:assert/strict'
import { execFile, spawn } from 'node:child_process'
import { once } from 'node:events'
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { setTimeout as delay } from 'node:timers/promises'
import { promisify } from 'node:util'

export const root = fileURLToPath(new URL('../../', import.meta.url))
export const script = path.join(root, 'scripts/Start-LanCompose.ps1')
export const shell = process.env.BATTLESHIP_POWERSHELL ?? path.join(process.env.SystemRoot ?? 'C:/Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe')
export const quote = value => "'" + String(value).replaceAll("'", "''") + "'"
const encoded = code => ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', Buffer.from(code, 'utf16le').toString('base64')]
export function helperEnv() {
  const env = { ...process.env }
  for (const key of ['HOST', 'PORT', 'PUBLIC_ORIGIN', 'WEB_PUBLIC_PORT', 'BATTLESHIP_TCP_HOST',
    'BATTLESHIP_TCP_PORT', 'BATTLESHIP_BIND_HOST', 'BATTLESHIP_READY_FILE', 'LAN_CONFIG_DIR', 'LAN_ORIGINS_FILE', 'LAN_INTERFACE']) delete env[key]
  return env
}
export const runPS = code => promisify(execFile)(shell, encoded(code), { env: helperEnv(), windowsHide: true, timeout: 30000, maxBuffer: 1024 * 1024 })
export async function until(predicate, label, timeout = 8000) {
  const deadline = Date.now() + timeout
  do { if (await predicate()) return; await delay(25) } while (Date.now() < deadline)
  throw new Error(`${label} exceeded ${timeout} ms`)
}
export const adapter = (ip, name = 'Wi-Fi') => ({ Name: name, IsUp: true, IsLoopback: false, Addresses: [ip] })

export function hostFixture(t, port = 8081) {
  const parent = path.join(root, '.stack-work/dk06')
  mkdirSync(parent, { recursive: true })
  const directory = mkdtempSync(path.join(parent, 'node-'))
  const lan = path.join(directory, 'lan')
  const state = path.join(directory, 'interfaces.json')
  const filename = path.join(lan, 'origins.json')
  const children = []
  t.after(async () => {
    for (const child of children) {
      if (child.exitCode === null && child.signalCode === null) { const closed = once(child, 'close'); child.kill(); await closed }
    }
    assert.equal(path.dirname(directory), parent, 'cleanup must stay inside the test directory')
    rmSync(directory, { recursive: true })
  })
  copyFileSync(path.join(root, '.env.example'), path.join(directory, '.env.example'))
  const replace = values => {
    writeFileSync(state + '.tmp', JSON.stringify(values))
    renameSync(state + '.tmp', state)
  }
  replace([adapter('192.168.10.20'), adapter('10.8.0.2', 'VPN')])
  const bootstrap = `. ${quote(script)}; function Get-LanHostInterfaces { $items = [IO.File]::ReadAllText(${quote(state)}) | ConvertFrom-Json; foreach ($item in $items) { $item } };`
  const options = `@{Mode='Auto'; WatchOnly=$true; ConfigDir=${quote(lan)}; LanInterface='Wi-Fi'; PublicPort=${quote(port)}}`
  return { directory, lan, state, filename, port, replace, bootstrap, options,
    async start(code = `Invoke-LanCompose -ProjectRoot ${quote(directory)} -Options ${options}`) {
      const child = spawn(shell, encoded(bootstrap + code), { env: helperEnv(), windowsHide: true })
      children.push(child)
      let output = ''
      child.stdout.on('data', bytes => { output += bytes })
      child.stderr.on('data', bytes => { output += bytes })
      child.on('error', error => { output += error.message })
      await until(() => {
        if (child.exitCode !== null) throw new Error(`helper exited ${child.exitCode}: ${output}`)
        try { return existsSync(path.join(lan, 'compose.env')) && JSON.parse(readFileSync(filename)).origins.length === 1 } catch { return false }
      }, 'host helper initial file')
      return { child, output: () => output, async stop() {
        if (child.exitCode === null && child.signalCode === null) { const closed = once(child, 'close'); child.kill(); await closed }
      } }
    },
    async write(origins) {
      mkdirSync(lan, { recursive: true })
      await runPS(`. ${quote(script)}; Write-LanOrigins ${quote(filename)} @(${origins.map(quote).join(',')})`)
    },
  }
}
