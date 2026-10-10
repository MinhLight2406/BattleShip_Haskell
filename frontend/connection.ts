import { createFleet, encodeFleet, parseFrame, applyFrame, emptyView, type ShipState } from './game.ts'

export type BridgeMessage =
  | { type: 'SESSION'; token: string; fleet: string | null; frames: string[] | null }
  | { type: 'CONNECTION'; missing: { player: 'P1' | 'P2'; deadline: number }[] }
  | { type: 'RESUME_ERROR'; code: 'INVALID_SESSION' | 'SESSION_ACTIVE'; message: string }

export function parseBridgeMessage(text: string): BridgeMessage {
  const value = JSON.parse(text)
  if (value?.type === 'SESSION' && /^[a-f0-9]{64}$/.test(value.token) &&
      (value.fleet === null || typeof value.fleet === 'string') &&
      (value.frames === null || (Array.isArray(value.frames) && value.frames.length <= 4096 &&
        value.frames.every((line: unknown) => typeof line === 'string' && parseFrame(line))))) return value
  if (value?.type === 'CONNECTION' && Array.isArray(value.missing) && value.missing.length <= 2 &&
      value.missing.every((entry: { player: string; deadline: number }) =>
        ['P1', 'P2'].includes(entry.player) && Number.isSafeInteger(entry.deadline) && entry.deadline > 0)) return value
  if (value?.type === 'RESUME_ERROR' && ['INVALID_SESSION', 'SESSION_ACTIVE'].includes(value.code) && typeof value.message === 'string') return value
  throw new Error('Thông báo khôi phục không hợp lệ.')
}

export function decodeOwnFleet(command: string): ShipState[] {
  const specs = command.replace(/^PLACE /, '').split(';')
  const fleet = createFleet().map((ship, index): ShipState => {
    const match = specs[index]?.match(/^([A-Z]{2})=([A-J])(10|[1-9]):([HV])$/)
    if (!match || match[1] !== ship.code.slice(0, 2)) throw new Error('Đội tàu khôi phục không hợp lệ.')
    const orientation = match[4] === 'H' ? 'horizontal' : 'vertical'
    return { ...ship, orientation, placement: { row: Number(match[3]) - 1,
      col: match[2].charCodeAt(0) - 65, orientation } }
  })
  if (encodeFleet(fleet) !== command) throw new Error('Đội tàu khôi phục không hợp lệ.')
  return fleet
}

export const replayView = (frames: string[]) => frames.reduce((view, line) => applyFrame(view, parseFrame(line)), emptyView())

export function recoveryURL(address: string, token: string): string {
  const url = new URL(address)
  const parts = url.hostname.split('.')
  if (url.protocol !== 'http:' || url.username || url.password || url.search || url.hash ||
      url.pathname !== '/' || !/^[a-f0-9]{64}$/.test(token) ||
      !(url.hostname === 'localhost' || (parts.length === 4 && parts.every((part) => /^\d{1,3}$/.test(part) && Number(part) <= 255))) ||
      ['0.0.0.0', '255.255.255.255'].includes(url.hostname) || Number(url.port || 80) < 1)
    throw new Error('Nhập địa chỉ HTTP và cổng máy chủ hiện tại, ví dụ http://192.168.0.25:8081.')
  url.hash = `resume=${token}`
  return url.href
}
