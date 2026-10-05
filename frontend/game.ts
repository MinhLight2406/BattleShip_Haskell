export const GRID_SIZE = 10
export const COLUMN_LABELS = 'ABCDEFGHIJ'.split('')

export type Orientation = 'horizontal' | 'vertical'
export type ShipId = 'carrier' | 'battleship' | 'cruiser' | 'submarine' | 'destroyer'
export type Coordinate = { row: number; col: number }
export type Placement = Coordinate & { orientation: Orientation }
export type ShipSpec = { id: ShipId; name: string; code: string; length: number }
export type ShipState = ShipSpec & { orientation: Orientation; placement?: Placement }

export const SHIP_SPECS: readonly ShipSpec[] = [
  { id: 'carrier', name: 'Hàng không mẫu hạm', code: 'CV-01', length: 5 },
  { id: 'battleship', name: 'Thiết giáp hạm', code: 'BB-07', length: 4 },
  { id: 'cruiser', name: 'Tuần dương hạm', code: 'CR-12', length: 3 },
  { id: 'submarine', name: 'Tàu ngầm', code: 'SB-24', length: 3 },
  { id: 'destroyer', name: 'Khu trục hạm', code: 'DD-31', length: 2 },
]

export const createFleet = (): ShipState[] =>
  SHIP_SPECS.map((ship) => ({ ...ship, orientation: 'horizontal' }))

export const cellsFor = (
  ship: Pick<ShipState, 'length'> & { placement: Placement },
): Coordinate[] =>
  Array.from({ length: ship.length }, (_, index) => ({
    row:
      ship.placement.row +
      (ship.placement.orientation === 'vertical' ? index : 0),
    col:
      ship.placement.col +
      (ship.placement.orientation === 'horizontal' ? index : 0),
  }))

export const coordinateKey = ({ row, col }: Coordinate) => `${row}:${col}`

export const isInsideBoard = ({ row, col }: Coordinate) =>
  Number.isInteger(row) && Number.isInteger(col) &&
  row >= 0 && row < GRID_SIZE && col >= 0 && col < GRID_SIZE

export const canPlace = (
  fleet: ShipState[],
  shipId: ShipId,
  placement: Placement,
) => {
  const ship = fleet.find((item) => item.id === shipId)
  if (!ship) return false

  const candidate = cellsFor({ ...ship, placement })
  if (!candidate.every(isInsideBoard)) return false

  const occupied = new Set(
    fleet
      .filter((item) => item.id !== shipId && item.placement)
      .flatMap((item) => cellsFor(item as ShipState & { placement: Placement }))
      .map(coordinateKey),
  )

  return candidate.every((cell) => !occupied.has(coordinateKey(cell)))
}

export const placeShip = (
  fleet: ShipState[],
  shipId: ShipId,
  placement: Placement,
) =>
  canPlace(fleet, shipId, placement)
    ? fleet.map((ship) =>
        ship.id === shipId
          ? { ...ship, orientation: placement.orientation, placement }
          : ship,
      )
    : null

export const autoPlaceFleet = (source: ShipState[], random = Math.random): ShipState[] => {
  let fleet: ShipState[] = source.map((ship) => ({ ...ship, placement: undefined }))

  for (const ship of fleet) {
    let placed = false
    for (let attempt = 0; attempt < 400 && !placed; attempt += 1) {
      const orientation: Orientation = random() > 0.5 ? 'horizontal' : 'vertical'
      const row = Math.floor(random() * GRID_SIZE)
      const col = Math.floor(random() * GRID_SIZE)
      const next = placeShip(fleet, ship.id, { row, col, orientation })
      if (next) {
        fleet = next
        placed = true
      }
    }
    if (!placed) return createFleet().map((item, row) => ({
      ...item, placement: { row, col: 0, orientation: 'horizontal' },
    }))
  }

  return fleet
}

export const shipAt = (fleet: ShipState[], row: number, col: number) => {
  for (const ship of fleet) {
    if (!ship.placement) continue
    const index = cellsFor(ship as ShipState & { placement: Placement }).findIndex(
      (cell) => cell.row === row && cell.col === col,
    )
    if (index >= 0) return { ship, index }
  }
  return null
}

export type PlayerId = 'P1' | 'P2'
export type Outcome = 'MISS' | 'HIT' | 'WIN' | `SUNK ${string}`
export type Frame =
  | { kind: 'WELCOME'; player: PlayerId }
  | { kind: 'OK' | 'WAITING' }
  | { kind: 'START' | 'TURN'; player: PlayerId }
  | { kind: 'SHOT' | 'INCOMING'; coord: string; outcome: Outcome }
  | { kind: 'GAME_OVER'; player: PlayerId; reason: 'ALL_SHIPS_SUNK' | 'OPPONENT_LEFT' }
  | { kind: 'ERROR'; code: string; argument?: string }

// This projection contains only the server's public frames, never an enemy fleet.
export type PlayerView = {
  player: PlayerId | null
  phase: 'connecting' | 'waiting' | 'playing' | 'finished' | 'disconnected'
  accepted: boolean
  turn: PlayerId | null
  outgoing: Record<string, Outcome>
  incoming: Record<string, Outcome>
  winner: PlayerId | null
  reason?: string
  error?: string
}
export const emptyView = (): PlayerView => ({
  player: null, phase: 'connecting', accepted: false, turn: null,
  outgoing: {}, incoming: {}, winner: null,
})
export const wireCoord = (coord: Coordinate) => {
  if (!isInsideBoard(coord)) throw new Error('Tọa độ ngoài bàn.')
  return `${COLUMN_LABELS[coord.col]}${coord.row + 1}`
}
export const encodeFleet = (fleet: ShipState[]) => {
  if (fleet.length !== 5 || SHIP_SPECS.some((spec) => {
    const matches = fleet.filter((ship) => ship.id === spec.id)
    return matches.length !== 1 || matches[0].length !== spec.length ||
      !matches[0].placement || !canPlace(fleet, spec.id, matches[0].placement)
  })) throw new Error('Cần đủ 5 tàu đúng kích thước, không chồng hoặc vượt biên.')
  return 'PLACE ' + SHIP_SPECS.map((spec) => {
    const ship = fleet.find((item) => item.id === spec.id)!
    const start = ship.placement!
    return `${spec.code.slice(0, 2)}=${wireCoord(start)}:${start.orientation === 'horizontal' ? 'H' : 'V'}`
  }).join(';')
}

const coordPattern = '[A-J](?:10|[1-9])'
const shipPattern = '(?:CV|BB|CR|SB|DD)'
// docs/protocol.md is the wire contract. UI labels are deliberately separate.
export function parseFrame(line: string): Frame {
  if (line.length > 256 || /[^\x20-\x7e]/.test(line)) throw new Error('Phản hồi sai định dạng.')
  let match: RegExpMatchArray | null
  if ((match = line.match(/^WELCOME 1 (P[12])$/))) return { kind: 'WELCOME', player: match[1] as PlayerId }
  if (line === 'OK PLACE') return { kind: 'OK' }
  if (line === 'WAITING OPPONENT') return { kind: 'WAITING' }
  if (line === 'START P1') return { kind: 'START', player: 'P1' }
  if ((match = line.match(/^TURN (P[12])$/))) return { kind: 'TURN', player: match[1] as PlayerId }
  if ((match = line.match(new RegExp(`^(SHOT|INCOMING) (${coordPattern}) (MISS|HIT|WIN|SUNK ${shipPattern})$`)))) {
    return { kind: match[1] as 'SHOT' | 'INCOMING', coord: match[2], outcome: match[3] as Outcome }
  }
  if ((match = line.match(/^GAME_OVER (P[12]) (ALL_SHIPS_SUNK|OPPONENT_LEFT)$/))) {
    return { kind: 'GAME_OVER', player: match[1] as PlayerId, reason: match[2] as 'ALL_SHIPS_SUNK' | 'OPPONENT_LEFT' }
  }
  if ((match = line.match(/^ERROR (INVALID_COMMAND|INVALID_COORDINATE|FLEET_ALREADY_PLACED|FLEETS_NOT_READY|GAME_FINISHED|LINE_TOO_LONG|SERVER_FULL)$/))) {
    return { kind: 'ERROR', code: match[1] }
  }
  if ((match = line.match(new RegExp(`^ERROR (MISSING_SHIP|DUPLICATE_SHIP|SHIP_OUT_OF_BOUNDS) (${shipPattern})$`))) ||
      (match = line.match(new RegExp(`^ERROR (SHIPS_OVERLAP|ALREADY_FIRED) (${coordPattern})$`))) ||
      (match = line.match(/^ERROR (NOT_YOUR_TURN) (P[12])$/)) ||
      (match = line.match(/^ERROR (INVALID_FLEET_SIZE) (0|[1-9][0-9]{0,2})$/))) {
    if (match[1] !== 'INVALID_FLEET_SIZE' || Number(match[2]) <= 256)
      return { kind: 'ERROR', code: match[1], argument: match[2] }
  }
  throw new Error('Phản hồi không thuộc giao thức phiên bản 1.')
}

export const errorText = (code: string, argument?: string) => {
  const messages: Record<string, string> = {
    INVALID_COMMAND: 'Lệnh không hợp lệ.', INVALID_COORDINATE: 'Tọa độ phải từ A1 đến J10.',
    FLEET_ALREADY_PLACED: 'Đội tàu đã xác nhận, không thể đặt lại.',
    FLEETS_NOT_READY: 'Chờ cả hai người đặt xong tàu.', GAME_FINISHED: 'Trận đã kết thúc.',
    LINE_TOO_LONG: 'Lệnh quá dài.', SERVER_FULL: 'Phòng đã đủ hai người. Hãy chờ server mở trận mới.',
    INVALID_FLEET_SIZE: 'Đội tàu phải có đúng năm tàu.', MISSING_SHIP: 'Thiếu tàu',
    DUPLICATE_SHIP: 'Tàu bị lặp', SHIP_OUT_OF_BOUNDS: 'Tàu vượt biên',
    SHIPS_OVERLAP: 'Tàu chồng lấn tại', ALREADY_FIRED: 'Bạn đã bắn ô',
    NOT_YOUR_TURN: 'Chưa đến lượt bạn. Người đang bắn:',
  }
  return `${messages[code] ?? 'Server từ chối lệnh.'}${argument ? ` ${argument}` : ''}`
}
export function applyFrame(view: PlayerView, frame: Frame): PlayerView {
  switch (frame.kind) {
    case 'WELCOME': return { ...view, player: frame.player, phase: 'waiting' }
    case 'OK': return { ...view, accepted: true, error: undefined }
    case 'WAITING': return { ...view, phase: 'waiting' }
    case 'START': return { ...view, phase: 'playing', error: undefined }
    case 'TURN': return { ...view, turn: frame.player, error: undefined }
    case 'SHOT': return { ...view, outgoing: { ...view.outgoing, [frame.coord]: frame.outcome }, error: undefined }
    case 'INCOMING': return { ...view, incoming: { ...view.incoming, [frame.coord]: frame.outcome } }
    case 'GAME_OVER': return { ...view, phase: 'finished', winner: frame.player, reason: frame.reason, turn: null }
    case 'ERROR': return { ...view, error: errorText(frame.code, frame.argument) }
  }
}
export const canFire = (view: PlayerView, coord: string, pending: boolean) =>
  view.phase === 'playing' && view.player !== null && view.turn === view.player &&
  !pending && new RegExp(`^${coordPattern}$`).test(coord) && !view.outgoing[coord]

export const outcomeText = (result: Outcome) => result === 'MISS' ? 'Trượt' :
  result === 'HIT' ? 'Trúng' : result === 'WIN' ? 'Trúng — hạ tàu cuối cùng' : 'Chìm tàu ' + result.slice(5)

export const statusText = (view: PlayerView, pending: boolean) => {
  if (view.phase === 'finished') return `${view.winner === view.player ? 'Bạn thắng!' : 'Bạn thua.'} ${view.reason === 'OPPONENT_LEFT' ? 'Đối thủ đã rời trận.' : view.winner === view.player ? 'Hạm đội đối phương đã bị đánh chìm.' : 'Hạm đội của bạn đã bị đánh chìm.'}`
  if (view.phase === 'disconnected') return 'Đã ngắt kết nối. Khởi động lại server để mở trận mới.'
  if (view.phase === 'connecting') return 'Đang kết nối máy chủ…'
  if (view.phase === 'waiting') return view.accepted ? 'Đã xác nhận hạm đội. Chờ đối thủ đặt tàu…' : 'Đang gửi hạm đội…'
  return pending ? 'Đang chờ kết quả phát bắn…' : view.turn === view.player ? 'Đến lượt bạn — chọn ô trên vùng biển đối phương.' : 'Lượt đối thủ — chờ kết quả.'
}
