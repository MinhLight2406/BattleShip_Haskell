import {
  type DragEvent,
  type FormEvent,
  type MouseEvent,
  type ReactNode,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react'

import {
  GRID_SIZE, COLUMN_LABELS, SHIP_SPECS, createFleet, cellsFor, coordinateKey,
  canPlace, placeShip, autoPlaceFleet, shipAt, wireCoord, encodeFleet,
  parseFrame, applyFrame, emptyView, canFire, statusText, outcomeText,
  type ShipState, type ShipId, type Orientation, type Coordinate, type PlayerView, type Outcome,
} from './game.ts'
import { parseBridgeMessage, decodeOwnFleet, replayView, recoveryURL } from './connection.ts'

type Screen = 'landing' | 'rooms' | 'placement' | 'battle'
type MusicTrack = 'lobby' | 'placement' | 'battle'
type SoundEffect = 'enter-room' | 'start-match' | 'pickup' | 'place' | 'hit' | 'miss' | 'sunk'
type RoomInfo = {
  roomId: string
  roomName: string
  seat: 'P1' | 'P2'
  displayName: string
  opponentName: string | null
  ticket?: string
  expiresAt: number | null
}
type IconName =
  | 'anchor'
  | 'arrow-right'
  | 'back'
  | 'check'
  | 'close'
  | 'fullscreen'
  | 'help'
  | 'lock'
  | 'play'
  | 'rotate'
  | 'shuffle'
  | 'sound-off'
  | 'sound-on'
  | 'trash'

function Icon({ name, size = 22 }: { name: IconName; size?: number }) {
  const paths: Record<IconName, ReactNode> = {
    anchor: (
      <>
        <circle cx="12" cy="5" r="2.5" />
        <path d="M12 7.5V21M5 12H2.5M21.5 12H19M5 12c0 5 3 8 7 8s7-3 7-8M5 12l-2.5 3M19 12l2.5 3" />
      </>
    ),
    'arrow-right': <path d="M5 12h14M14 6l6 6-6 6" />,
    back: <path d="M19 12H5M10 7l-5 5 5 5" />,
    check: <path d="m5 12 4 4L19 6" />,
    close: <path d="m6 6 12 12M18 6 6 18" />,
    fullscreen: <path d="M8 3H3v5M16 3h5v5M8 21H3v-5M16 21h5v-5" />,
    help: (
      <>
        <circle cx="12" cy="12" r="9" />
        <path d="M9.6 9a2.6 2.6 0 1 1 4.4 1.9c-1 .8-2 1.2-2 2.6M12 17.5h.01" />
      </>
    ),
    lock: (
      <>
        <rect x="5" y="10" width="14" height="11" rx="2" />
        <path d="M8 10V7a4 4 0 0 1 8 0v3" />
      </>
    ),
    play: <path d="m8 5 11 7-11 7Z" />,
    rotate: (
      <>
        <path d="M20 7v5h-5" />
        <path d="M18.4 17a8 8 0 1 1 .9-8.8L20 12" />
      </>
    ),
    shuffle: (
      <>
        <path d="M3 7h3c4 0 4 10 8 10h7" />
        <path d="m18 14 3 3-3 3M3 17h3c1.7 0 2.7-1.8 3.7-4M14 7h7M18 4l3 3-3 3" />
      </>
    ),
    'sound-off': (
      <>
        <path d="M11 5 6 9H3v6h3l5 4Z" />
        <path d="m17 9 5 5M22 9l-5 5" />
      </>
    ),
    'sound-on': (
      <>
        <path d="M11 5 6 9H3v6h3l5 4Z" />
        <path d="M15 9.5a4 4 0 0 1 0 5M18 7a7 7 0 0 1 0 10" />
      </>
    ),
    trash: (
      <>
        <path d="M4 7h16M9 7V4h6v3M7 7l1 14h8l1-14M10 11v6M14 11v6" />
      </>
    ),
  }

  return (
    <svg
      aria-hidden="true"
      className="icon"
      fill="none"
      height={size}
      viewBox="0 0 24 24"
      width={size}
      stroke="currentColor"
      strokeLinecap="round"
      strokeLinejoin="round"
      strokeWidth="1.8"
    >
      {paths[name]}
    </svg>
  )
}

function IconButton({
  label,
  icon,
  onClick,
  pressed,
}: {
  label: string
  icon: IconName
  onClick: () => void
  pressed?: boolean
}) {
  return (
    <button
      aria-label={label}
      aria-pressed={pressed}
      className="icon-button"
      onClick={onClick}
      title={label}
      type="button"
    >
      <Icon name={icon} />
    </button>
  )
}

function ShipGlyph({ length = 4 }: { length?: number }) {
  return (
    <svg
      aria-hidden="true"
      className="ship-glyph"
      style={{ width: `${Math.max(78, length * 27)}px` }}
      viewBox="0 0 160 38"
    >
      <defs>
        <linearGradient id="hull" x1="0" x2="1">
          <stop offset="0" stopColor="#8aa6af" />
          <stop offset="0.52" stopColor="#d3e1e4" />
          <stop offset="1" stopColor="#526a74" />
        </linearGradient>
      </defs>
      <path
        d="M8 19 24 7h104l25 12-25 12H24Z"
        fill="url(#hull)"
        stroke="currentColor"
        strokeWidth="2"
      />
      <path d="M54 12h45v14H54Z" fill="#37505b" />
      <path d="M68 7h17v24H68ZM112 14h17v10h-17Z" fill="#1d3540" />
      <path d="M20 19h25M99 19h46" stroke="#d8fbff" strokeWidth="2" />
    </svg>
  )
}

function Brand({ onClick }: { onClick: () => void }) {
  return (
    <button className="brand" onClick={onClick} type="button">
      <span className="brand-mark" aria-hidden="true">
        <Icon name="anchor" size={26} />
      </span>
      <span>
        <strong>HẠM ĐỘI</strong>
        <small>PHÒNG TÁC CHIẾN</small>
      </span>
    </button>
  )
}

function Header({
  onHelp,
  onFullscreen,
  onHome,
  onSoundToggle,
  soundEnabled,
}: {
  onHelp: () => void
  onFullscreen: () => void
  onHome: () => void
  onSoundToggle: () => void
  soundEnabled: boolean
}) {
  return (
    <header className="topbar">
      <Brand onClick={onHome} />
      <nav aria-label="Công cụ trò chơi" className="topbar-actions">
        <IconButton
          icon={soundEnabled ? 'sound-on' : 'sound-off'}
          label={soundEnabled ? 'Tắt âm thanh' : 'Bật âm thanh'}
          onClick={onSoundToggle}
          pressed={soundEnabled}
        />
        <IconButton icon="help" label="Mở hướng dẫn" onClick={onHelp} />
        <IconButton
          icon="fullscreen"
          label="Bật hoặc tắt toàn màn hình"
          onClick={onFullscreen}
        />
      </nav>
    </header>
  )
}

function Landing({ onStart, onHelp }: { onStart: () => void; onHelp: () => void }) {
  return (
    <section className="screen landing-screen">
      <div className="hero-image" aria-hidden="true" />
      <div className="hero-shade" aria-hidden="true" />
      <div className="hero-content">
        <h1>
          Làm chủ
          <span>đại dương</span>
        </h1>
        <p className="hero-copy">
          Mất liên lạc với tiền đồn ngoài khơi. Triển khai hạm đội và dò tìm thứ đang ẩn dưới mặt nước.
        </p>
        <div className="hero-actions">
          <button className="primary-button hero-cta" onClick={onStart} type="button">
            Vào phòng tác chiến <Icon name="arrow-right" />
          </button>
          <button className="text-button" onClick={onHelp} type="button">
            Xem cách vận hành
          </button>
        </div>
        <dl className="hero-metrics">
          <div><dt>10 × 10</dt><dd>Lưới chiến thuật</dd></div>
          <div><dt>05</dt><dd>Chiến hạm</dd></div>
          <div><dt>01</dt><dd>Nhiệm vụ</dd></div>
        </dl>
      </div>
      <p className="hero-footnote">BATTLESHIP • ĐỐI ĐẦU HAI NGƯỜI</p>
    </section>
  )
}

type BoardPreview = { cells: Coordinate[]; valid: boolean }

function Board({
  fleet,
  interactive = false,
  selectedShipId,
  preview,
  enemy = false,
  shots = {},
  shotEffects = {},
  onCellClick,
  onCellDrop,
  onCellHover,
  onLeave,
}: {
  fleet: ShipState[]
  interactive?: boolean
  selectedShipId?: ShipId
  preview?: BoardPreview
  enemy?: boolean
  shots?: Record<string, Outcome>
  shotEffects?: Record<string, 'hit' | 'miss'>
  onCellClick?: (row: number, col: number) => void
  onCellDrop?: (shipId: ShipId, row: number, col: number) => void
  onCellHover?: (row: number, col: number) => void
  onLeave?: () => void
}) {
  const previewKeys = new Set(preview?.cells.map(coordinateKey))

  return (
    <div className={`board ${enemy ? 'enemy-board' : ''}`} onMouseLeave={onLeave}>
      <span className="board-corner" />
      {Array.from({ length: GRID_SIZE }, (_, col) => (
        <span className="board-label column-label" key={`column-${col}`}>{COLUMN_LABELS[col]}</span>
      ))}
      {Array.from({ length: GRID_SIZE }, (_, row) => (
        <div className="board-row" key={`row-${row}`}>
          <span className="board-label row-label">{row + 1}</span>
          {Array.from({ length: GRID_SIZE }, (_, col) => {
            const occupied = shipAt(fleet, row, col)
            const coord = wireCoord({ row, col })
            const result = shots[coord]
            const isPreview = previewKeys.has(coordinateKey({ row, col }))
            const classes = [
              'board-cell',
              result ? `shot-${result.split(' ')[0].toLowerCase()}` : '',
              occupied ? 'occupied' : '',
              selectedShipId !== undefined && occupied?.ship.id === selectedShipId ? 'selected' : '',
              occupied ? occupied.ship.orientation : '',
              occupied?.index === 0 ? 'segment-first' : '',
              occupied && occupied.index === occupied.ship.length - 1 ? 'segment-last' : '',
              isPreview ? (preview?.valid ? 'preview-valid' : 'preview-invalid') : '',
            ].filter(Boolean).join(' ')

            return (
              <button
                aria-label={`${coord}${enemy ? (result ? '' : ', chưa bắn') : occupied ? `, ${occupied.ship.name}` : ', ô trống'}${result ? `, ${outcomeText(result)}` : ''}`}
                data-coordinate={coord}
                data-outcome={result}
                className={classes}
                disabled={!interactive || (enemy && Boolean(result))}
                key={`${row}-${col}`}
                onClick={() => onCellClick?.(row, col)}
                onDragOver={(event) => {
                  if (interactive) event.preventDefault()
                }}
                onDrop={(event: DragEvent<HTMLButtonElement>) => {
                  event.preventDefault()
                  const shipId = event.dataTransfer.getData('ship-id') as ShipId
                  if (SHIP_SPECS.some((ship) => ship.id === shipId)) {
                    onCellDrop?.(shipId, row, col)
                  }
                }}
                onMouseEnter={() => onCellHover?.(row, col)}
                type="button"
              >
                {occupied && <span className="ship-segment" aria-hidden="true" />}
                {enemy && !result && <span className="enemy-dot" aria-hidden="true" />}
                {result && <span className="shot-marker" aria-hidden="true">{result === 'MISS' ? '•' : '×'}</span>}
                {shotEffects[coord] && <img className="shot-effect" src={`/effects/${shotEffects[coord] === 'hit' ? 'bantrung' : 'banhut'}.gif`} alt="" aria-hidden="true" />}
              </button>
            )
          })}
        </div>
      ))}
    </div>
  )
}

function Placement({
  fleet,
  setFleet,
  onBack,
  onStart,
  onPickup,
  onPlace,
  onStartSound,
}: {
  fleet: ShipState[]
  setFleet: (fleet: ShipState[]) => void
  onBack: () => void
  onStart: () => void
  onPickup: () => void
  onPlace: () => void
  onStartSound: () => void
}) {
  const [selectedId, setSelectedId] = useState<ShipId>(fleet[0].id)
  const [hoveredCell, setHoveredCell] = useState<Coordinate | null>(null)
  const [status, setStatus] = useState('Chọn một tàu rồi nhấp hoặc kéo vào lưới.')
  const selectedShip = fleet.find((ship) => ship.id === selectedId) ?? fleet[0]
  const placedCount = fleet.filter((ship) => ship.placement).length
  const allPlaced = placedCount === fleet.length

  const preview = useMemo<BoardPreview | undefined>(() => {
    if (!hoveredCell || !selectedShip) return undefined
    const placement = { ...hoveredCell, orientation: selectedShip.orientation }
    return {
      cells: cellsFor({ ...selectedShip, placement }),
      valid: canPlace(fleet, selectedShip.id, placement),
    }
  }, [fleet, hoveredCell, selectedShip])

  const tryPlace = (shipId: ShipId, row: number, col: number) => {
    const ship = fleet.find((item) => item.id === shipId)
    if (!ship) return
    const next = placeShip(fleet, shipId, { row, col, orientation: ship.orientation })
    setSelectedId(shipId)
    if (!next) {
      setStatus('Vị trí không hợp lệ: tàu vượt biên hoặc chồng lên tàu khác.')
      return
    }
    setFleet(next)
    onPlace()
    setStatus(`${ship.name} đã vào vị trí ${wireCoord({ row, col })}.`)
  }

  const handleCellClick = (row: number, col: number) => {
    const occupied = shipAt(fleet, row, col)
    if (occupied && occupied.ship.id !== selectedId) {
      setSelectedId(occupied.ship.id)
      onPickup()
      setStatus(`Đã chọn ${occupied.ship.name}.`)
      return
    }
    tryPlace(selectedId, row, col)
  }

  const rotateSelected = () => {
    const orientation: Orientation =
      selectedShip.orientation === 'horizontal' ? 'vertical' : 'horizontal'

    if (selectedShip.placement) {
      const placement = { ...selectedShip.placement, orientation }
      const next = placeShip(fleet, selectedId, placement)
      if (!next) {
        setStatus('Không đủ khoảng trống để xoay tàu tại vị trí này.')
        return
      }
      setFleet(next)
    } else {
      setFleet(
        fleet.map((ship) =>
          ship.id === selectedId ? { ...ship, orientation } : ship,
        ),
      )
    }
    setStatus(`Đã xoay ${selectedShip.name} theo chiều ${orientation === 'horizontal' ? 'ngang' : 'dọc'}.`)
  }

  const removeSelected = () => {
    onPickup()
    setFleet(
      fleet.map((ship) =>
        ship.id === selectedId ? { ...ship, placement: undefined } : ship,
      ),
    )
    setStatus(`${selectedShip.name} đã trở về quân cảng.`)
  }

  const randomize = () => {
    setFleet(autoPlaceFleet(fleet))
    onPlace()
    setStatus('Bộ chỉ huy đã đề xuất một đội hình ngẫu nhiên.')
  }

  const clearFleet = () => {
    setFleet(fleet.map((ship) => ({ ...ship, placement: undefined })))
    setStatus('Đã dọn trống bàn bố trí.')
  }

  return (
    <section className="screen placement-screen">
      <div className="tactical-backdrop" aria-hidden="true" />
      <div className="page-container placement-container">
        <div className="placement-heading">
          <button className="back-button" onClick={onBack} type="button">
            <Icon name="back" /> Về sảnh
          </button>
          <div>
            <p className="eyebrow"><span /> BƯỚC 01 / 02 • CỔ ĐIỂN</p>
            <h1>Bố trí hạm đội</h1>
          </div>
          <div className="fleet-progress" aria-label={`Đã bố trí ${placedCount} trên ${fleet.length} tàu`}>
            <strong>{placedCount}/{fleet.length}</strong>
            <span>ĐÃ VÀO VỊ TRÍ</span>
          </div>
        </div>

        <div className="placement-layout">
          <aside className="fleet-dock" aria-label="Danh sách chiến hạm">
            <div className="panel-heading">
              <span>HẠM ĐỘI</span>
              <small>KÉO HOẶC CHỌN TÀU</small>
            </div>
            <div className="ship-list">
              {fleet.map((ship) => (
                <button
                  aria-pressed={ship.id === selectedId}
                  className={`ship-card ${ship.id === selectedId ? 'active' : ''} ${ship.placement ? 'placed' : ''}`}
                  draggable
                  key={ship.id}
                  onClick={() => {
                    setSelectedId(ship.id)
                    onPickup()
                    setStatus(`Đã chọn ${ship.name}.`)
                  }}
                  onDragStart={(event: DragEvent<HTMLButtonElement>) => {
                    event.dataTransfer.setData('ship-id', ship.id)
                    event.dataTransfer.effectAllowed = 'move'
                    setSelectedId(ship.id)
                    onPickup()
                  }}
                  type="button"
                >
                  <span className="ship-card-copy">
                    <strong>{ship.name}</strong>
                    <small>{ship.code} • {ship.length} Ô</small>
                  </span>
                  <ShipGlyph length={ship.length} />
                  <span className="ship-state">
                    {ship.placement ? <><Icon name="check" size={15} /> Đã đặt</> : 'Chờ lệnh'}
                  </span>
                </button>
              ))}
            </div>
          </aside>

          <main className="board-panel">
            <div className="board-toolbar">
              <p><span className="status-light" /> KÊNH BỐ TRÍ AN TOÀN</p>
              <span>LƯỚI 10 × 10</span>
            </div>
            <div className="board-shell">
              <Board
                fleet={fleet}
                interactive
                onCellClick={handleCellClick}
                onCellDrop={tryPlace}
                onCellHover={(row, col) => setHoveredCell({ row, col })}
                onLeave={() => setHoveredCell(null)}
                preview={preview}
                selectedShipId={selectedId}
              />
              <div className="board-scanline" aria-hidden="true" />
            </div>
            <p className="placement-status" aria-live="polite">{status}</p>
          </main>

          <aside className="command-panel" aria-label="Điều khiển bố trí">
            <div className="panel-heading">
              <span>ĐIỀU KHIỂN</span>
              <small>{selectedShip.code}</small>
            </div>
            <div className="selected-summary">
              <span>ĐANG CHỌN</span>
              <strong>{selectedShip.name}</strong>
              <small>{selectedShip.orientation === 'horizontal' ? 'Hướng ngang' : 'Hướng dọc'} • {selectedShip.length} ô</small>
            </div>
            <div className="command-grid">
              <button onClick={rotateSelected} type="button">
                <Icon name="rotate" /> <span>Xoay tàu</span>
              </button>
              <button onClick={randomize} type="button">
                <Icon name="shuffle" /> <span>Tự bố trí</span>
              </button>
              <button disabled={!selectedShip.placement} onClick={removeSelected} type="button">
                <Icon name="back" /> <span>Thu hồi</span>
              </button>
              <button className="danger-command" onClick={clearFleet} type="button">
                <Icon name="trash" /> <span>Dọn bàn</span>
              </button>
            </div>
            <div className="command-tip">
              <strong>Gợi ý thao tác</strong>
              <p>Kéo tàu vào ô đầu tiên hoặc chọn tàu rồi nhấp một tọa độ. Dùng “Xoay tàu” để đổi hướng.</p>
            </div>
            <button
              className="primary-button deploy-button"
              disabled={!allPlaced}
              onClick={onStart}
              onPointerDown={onStartSound}
              onKeyDown={(event) => {
                if (!event.repeat && (event.key === 'Enter' || event.key === ' ')) onStartSound()
              }}
              type="button"
            >
              <Icon name="play" /> Bắt đầu trận
            </button>
            {!allPlaced && <small className="deploy-hint">Bố trí đủ 5 tàu để tiếp tục</small>}
          </aside>
        </div>
      </div>
    </section>
  )
}

function Battle({ fleet, view, pending, room, shotEffects, onFire, onHome }: {
  fleet: ShipState[]; view: PlayerView; pending: boolean
  shotEffects: Record<string, 'hit' | 'miss'>
  room: RoomInfo | null
  onFire: (row: number, col: number) => void; onHome: () => void
}) {
  const ready = view.phase === 'playing' && view.player === view.turn && !pending && !view.missing?.length
  const won = view.winner === view.player
  return (
    <section className="screen battle-screen">
      <div className="tactical-backdrop battle-backdrop" aria-hidden="true" />
      <div className="page-container battle-container">
        <div className="battle-heading">
          <div><p className="eyebrow"><span /> CỔ ĐIỂN • {room?.roomId ?? view.player ?? 'ĐANG KẾT NỐI'}</p><h1>{room?.roomName ?? 'Phòng chiến đấu'}</h1></div>
          <div className="connection-pill"><span />{view.player ? room?.displayName ?? 'Người chơi ' + view.player : 'Kết nối máy chủ'}</div>
        </div>
        <div className="game-status" role="status">{statusText(view, pending)}</div>
        {view.error && <p className="game-error" role="alert">{view.error}</p>}
        <div className="battle-boards">
          <article className="battle-board-card" aria-label="Bàn phòng thủ">
            <div className="battle-board-title"><div><small>LƯỚI PHÒNG THỦ</small><h2>{room?.displayName ?? 'Hạm đội của bạn'}</h2></div><span>{view.accepted ? 'ĐÃ XÁC NHẬN' : 'ĐỘI HÌNH ĐÃ CHỌN'}</span></div>
            <Board fleet={fleet} shots={view.incoming} />
          </article>
          <article className="battle-board-card enemy-card" aria-label="Bàn mục tiêu">
            <div className="battle-board-title"><div><small>LƯỚI TẤN CÔNG</small><h2>{room?.opponentName ?? 'Vùng biển đối phương'}</h2></div><span>{ready ? 'CHỌN Ô BẮN' : 'CHỜ'}</span></div>
            <Board enemy fleet={[]} interactive={ready} shots={view.outgoing} shotEffects={shotEffects} onCellClick={onFire} />
          </article>
        </div>
        <div className="ready-banner">
          <div><h2>{view.phase === 'finished' ? 'Trận đấu kết thúc' : 'Nhật ký tác chiến'}</h2>
            <p>• Trượt: chuyển lượt. × Trúng/chìm: giữ lượt. Chỉ các ô đã bắn được hiển thị.</p>
            <ol className="shot-log" aria-label="Kết quả bắn">{Object.entries(view.outgoing).map(([coord, result]) => <li key={coord}>{coord}: {outcomeText(result)}</li>)}</ol>
            {view.phase === 'finished' && <p>Phòng này đã kết thúc. Tạo phòng mới để bắt đầu trận khác.</p>}
          </div>
          <button className="secondary-button" onClick={onHome} type="button">{['finished', 'disconnected'].includes(view.phase) ? 'Về trang đầu' : 'Rời trận (bỏ cuộc)'}</button>
        </div>
      </div>
      {view.phase === 'finished' && view.winner && <div className="match-result-backdrop">
        <section aria-labelledby="match-result-title" aria-modal="true" className="match-result" role="dialog">
          <h2 id="match-result-title">{won ? 'BẠN ĐÃ THẮNG' : 'BẠN ĐÃ THUA'}</h2>
          <img src={`/effects/${won ? 'thangcuoc' : 'thuacuoc'}.gif`} alt={won ? 'GIF ăn mừng chiến thắng' : 'GIF tiếc nuối khi thua cuộc'} />
          <button className="primary-button" onClick={onHome} type="button">Về trang đầu</button>
        </section>
      </div>}
    </section>
  )
}

function RoomSetup({ onBack, onReady }: { onBack: () => void; onReady: (room: RoomInfo) => void }) {
  const [action, setAction] = useState<'create' | 'join'>('create')
  const [displayName, setDisplayName] = useState('Player1')
  const [roomName, setRoomName] = useState('')
  const [roomLookup, setRoomLookup] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    setError(''); setBusy(true)
    try {
      const response = await fetch(`/api/rooms/${action}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(action === 'create'
          ? { roomName, password, displayName }
          : { room: roomLookup, password, displayName }),
      })
      const value = await response.json()
      if (!response.ok) throw new Error(typeof value.error === 'string' ? value.error : 'Không thể xử lý phòng.')
      onReady({ ...value, opponentName: value.opponentName ?? null })
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Không kết nối được máy chủ phòng.')
    } finally { setBusy(false) }
  }

  const chooseAction = (next: 'create' | 'join') => {
    setAction(next); setError('')
    if ((next === 'join' && displayName === 'Player1') || (next === 'create' && displayName === 'Player2'))
      setDisplayName(next === 'create' ? 'Player1' : 'Player2')
  }

  return (
    <section className="screen room-screen">
      <div className="radar-backdrop" aria-hidden="true" />
      <div className="page-container room-container">
        <button className="back-button" onClick={onBack} type="button"><Icon name="back" /> Quay lại</button>
        <div className="section-heading">
          <p className="eyebrow"><span /> KẾT NỐI QUA INTERNET</p>
          <h1>Phòng tác chiến</h1>
          <p>Tạo phòng riêng hoặc nhập tên/ID phòng bạn bè gửi. Mật khẩu được nhập dạng chữ thường.</p>
        </div>
        <div className="room-panel">
          <div className="room-tabs" role="tablist" aria-label="Thao tác phòng">
            <button aria-selected={action === 'create'} className={action === 'create' ? 'active' : ''}
              onClick={() => chooseAction('create')} role="tab" type="button">Tạo phòng</button>
            <button aria-selected={action === 'join'} className={action === 'join' ? 'active' : ''}
              onClick={() => chooseAction('join')} role="tab" type="button">Tham gia phòng</button>
          </div>
          <form className="room-form" onSubmit={(event) => void submit(event)}>
            <label>Tên hiển thị
              <input autoComplete="nickname" maxLength={24} onChange={(event) => setDisplayName(event.target.value)}
                required value={displayName} />
            </label>
            {action === 'create' ? <label>Tên phòng
              <input autoComplete="off" maxLength={48} onChange={(event) => setRoomName(event.target.value)}
                placeholder="Ví dụ: Hạm đội Sao Bắc" required value={roomName} />
            </label> : <label>Tên hoặc ID phòng
              <input autoComplete="off" maxLength={48} onChange={(event) => setRoomLookup(event.target.value)}
                placeholder="Nhập tên phòng hoặc ID" required value={roomLookup} />
            </label>}
            <label>Mật khẩu phòng
              <input autoComplete="off" maxLength={128} onChange={(event) => setPassword(event.target.value)}
                required type="text" value={password} />
            </label>
            {error && <p className="room-error" role="alert">{error}</p>}
            <button className="primary-button room-submit" disabled={busy} type="submit">
              {busy ? 'Đang kết nối…' : action === 'create' ? 'Tạo phòng' : 'Tham gia'}
              {!busy && <Icon name="arrow-right" />}
            </button>
          </form>
          <p className="room-note">Phòng sẽ tự hết hạn sau 5 phút nếu chưa có người thứ hai tham gia.</p>
        </div>
      </div>
    </section>
  )
}

function HelpDialog({ onClose }: { onClose: () => void }) {
  const dialogRef = useRef<HTMLElement>(null)
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null
    const buttons = dialogRef.current?.querySelectorAll<HTMLButtonElement>('button')
    buttons?.[0]?.focus()
    const trap = (event: KeyboardEvent) => {
      if (event.key !== 'Tab' || !buttons?.length) return
      if (event.shiftKey && document.activeElement === buttons[0]) {
        event.preventDefault(); buttons[buttons.length - 1].focus()
      } else if (!event.shiftKey && document.activeElement === buttons[buttons.length - 1]) {
        event.preventDefault(); buttons[0].focus()
      }
    }
    document.addEventListener('keydown', trap)
    return () => { document.removeEventListener('keydown', trap); previous?.focus() }
  }, [])
  return (
    <div className="dialog-backdrop" onMouseDown={onClose} role="presentation">
      <section
        ref={dialogRef}
        aria-labelledby="help-title"
        aria-modal="true"
        className="help-dialog"
        onMouseDown={(event: MouseEvent) => event.stopPropagation()}
        role="dialog"
      >
        <button aria-label="Đóng hướng dẫn" className="dialog-close" onClick={onClose} type="button">
          <Icon name="close" />
        </button>
        <p className="eyebrow"><span /> HƯỚNG DẪN NHANH</p>
        <h2 id="help-title">Ba bước vào trận</h2>
        <ol className="help-steps">
          <li><span>01</span><div><strong>Tạo hoặc tham gia phòng</strong><p>Một người tạo phòng và gửi tên hoặc mã phòng cùng mật khẩu cho bạn chơi.</p></div></li>
          <li><span>02</span><div><strong>Bố trí hạm đội</strong><p>Kéo tàu lên lưới, xoay hướng và tránh chồng lấn.</p></div></li>
          <li><span>03</span><div><strong>Vào trận</strong><p>Nhấn “Bắt đầu trận” để xác nhận tàu. Đợi đủ hai người, rồi bấm ô đối phương khi đến lượt. Trúng/chìm giữ lượt; trượt chuyển lượt. Mất kết nối có 5 phút khôi phục bằng mã riêng. Nút rời trận là bỏ cuộc ngay.</p></div></li>
        </ol>
        <button className="primary-button dialog-button" onClick={onClose} type="button">Đã hiểu</button>
      </section>
    </div>
  )
}

export default function App() {
  const [screen, setScreen] = useState<Screen>('landing')
  const [soundEnabled, setSoundEnabled] = useState(true)
  const [fleet, setFleet] = useState<ShipState[]>(createFleet)
  const [helpOpen, setHelpOpen] = useState(false)
  const [view, setView] = useState<PlayerView>(emptyView)
  const [shotEffects, setShotEffects] = useState<Record<string, 'hit' | 'miss'>>({})
  const [pending, setPending] = useState(false)
  const [notice, setNotice] = useState('')
  const [token, setToken] = useState('')
  const [roomInfo, setRoomInfo] = useState<RoomInfo | null>(null)
  const [recoveryCode, setRecoveryCode] = useState('')
  const [serverAddress, setServerAddress] = useState(location.origin)
  const [now, setNow] = useState(Date.now())
  const tokenRef = useRef('')
  const roomTicketRef = useRef('')
  const commandRef = useRef('')
  const reconnectRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const retryUntilRef = useRef(0)
  const viewRef = useRef(view)
  const pendingRef = useRef(false)
  const socketRef = useRef<WebSocket | null>(null)
  const timerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const mainRef = useRef<HTMLDivElement>(null)
  const lobbyMusicRef = useRef<HTMLAudioElement | null>(null)
  const placementMusicRef = useRef<HTMLAudioElement | null>(null)
  const battleMusicRef = useRef<HTMLAudioElement | null>(null)
  const effectAudioRef = useRef<Partial<Record<SoundEffect, HTMLAudioElement>>>({})
  const sunkAudioTimerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const activeMusicRef = useRef<MusicTrack>('lobby')
  const musicStoppedAtEndRef = useRef(false)
  const soundEnabledRef = useRef(true)
  const shotEffectTimersRef = useRef(new Map<string, ReturnType<typeof setTimeout>>())

  const updateView = (next: PlayerView) => { viewRef.current = next; setView(next) }
  const showShotEffect = (coord: string, effect: 'hit' | 'miss') => {
    clearTimeout(shotEffectTimersRef.current.get(coord))
    setShotEffects((current) => ({ ...current, [coord]: effect }))
    shotEffectTimersRef.current.set(coord, setTimeout(() => {
      setShotEffects((current) => {
        const next = { ...current }
        delete next[coord]
        return next
      })
      shotEffectTimersRef.current.delete(coord)
    }, effect === 'hit' ? 860 : 3500))
  }
  const musicAudio = (track: MusicTrack) => {
    lobbyMusicRef.current ??= new Audio('/audio/freefire-lobby.mp3')
    placementMusicRef.current ??= new Audio('/audio/amthanhchontau.m4a')
    battleMusicRef.current ??= new Audio('/audio/amthanhtrandau.mp3')
    return track === 'lobby' ? lobbyMusicRef.current : track === 'placement' ? placementMusicRef.current : battleMusicRef.current
  }
  const playMusic = (track: MusicTrack) => {
    const next = musicAudio(track)
    musicStoppedAtEndRef.current = false
    for (const audio of [lobbyMusicRef.current, placementMusicRef.current, battleMusicRef.current]) {
      if (audio && audio !== next) audio.pause()
    }
    if (activeMusicRef.current !== track) {
      next.currentTime = 0
      activeMusicRef.current = track
    }
    next.loop = true
    next.volume = track === 'lobby' ? 0.24 : 0.6
    if (!soundEnabledRef.current) return
    void next.play().catch(() => {})
  }
  const playSound = (sound: SoundEffect) => {
    if (!soundEnabledRef.current) return
    const files = {
      'enter-room': 'vaophongtacchien.mp3',
      'start-match': 'batdau.mp3',
      pickup: 'nhatlen.mp3',
      place: 'datxuong.mp3',
      hit: 'trungtau.mp3',
      miss: 'trungnuoc.mp3',
      sunk: 'tauchim.mp3',
    } satisfies Record<SoundEffect, string>
    const audio = effectAudioRef.current[sound] ?? new Audio(`/audio/${files[sound]}`)
    effectAudioRef.current[sound] = audio
    audio.preload = 'auto'
    audio.volume = sound === 'start-match' ? 0.85 : 0.8
    audio.currentTime = 0
    if (sound === 'sunk') {
      clearTimeout(sunkAudioTimerRef.current)
      sunkAudioTimerRef.current = setTimeout(() => {
        audio.pause()
        audio.currentTime = 0
      }, 4000)
    }
    void audio.play().catch(() => {})
  }
  const preloadAudio = () => {
    const lobbyMusic = musicAudio('lobby')
    const placementMusic = musicAudio('placement')
    const battleMusic = musicAudio('battle')
    const clips: Record<SoundEffect, string> = {
      'enter-room': 'vaophongtacchien.mp3',
      'start-match': 'batdau.mp3',
      pickup: 'nhatlen.mp3',
      place: 'datxuong.mp3',
      hit: 'trungtau.mp3',
      miss: 'trungnuoc.mp3',
      sunk: 'tauchim.mp3',
    }
    for (const [sound, file] of Object.entries(clips) as [SoundEffect, string][]) {
      const audio = effectAudioRef.current[sound] ?? new Audio(`/audio/${file}`)
      audio.preload = 'auto'
      effectAudioRef.current[sound] = audio
      audio.load()
    }
    lobbyMusic.preload = 'auto'
    placementMusic.preload = 'auto'
    battleMusic.preload = 'auto'
    lobbyMusic.load()
    placementMusic.load()
    battleMusic.load()
  }
  const releasePending = () => {
    clearTimeout(timerRef.current)
    pendingRef.current = false
    setPending(false)
  }
  const saveToken = (value: string) => {
    tokenRef.current = value; setToken(value)
    try { value ? sessionStorage.setItem('battleship.resume', value) : sessionStorage.removeItem('battleship.resume') } catch { /* The visible code also works without browser storage. */ }
  }
  const closeSession = (quit = false) => {
    clearTimeout(timerRef.current)
    clearTimeout(reconnectRef.current)
    const socket = socketRef.current
    socketRef.current = null
    if (quit && socket?.readyState === WebSocket.OPEN) socket.send('QUIT')
    socket?.close()
  }
  useEffect(() => {
    const leave = () => socketRef.current?.close()
    window.addEventListener('pagehide', leave)
    return () => {
      window.removeEventListener('pagehide', leave); closeSession()
      shotEffectTimersRef.current.forEach((timer) => clearTimeout(timer))
      shotEffectTimersRef.current.clear()
    }
  }, [])
  useEffect(() => {
    preloadAudio()
    playMusic('lobby')
    const resumeMusic = () => {
      if (!soundEnabledRef.current || musicStoppedAtEndRef.current) return
      const audio = musicAudio(activeMusicRef.current)
      if (audio?.paused) void audio.play().catch(() => {})
    }
    window.addEventListener('pointerdown', resumeMusic)
    window.addEventListener('keydown', resumeMusic)
    return () => {
      window.removeEventListener('pointerdown', resumeMusic)
      window.removeEventListener('keydown', resumeMusic)
      clearTimeout(sunkAudioTimerRef.current)
      lobbyMusicRef.current?.pause()
      placementMusicRef.current?.pause()
      battleMusicRef.current?.pause()
      Object.values(effectAudioRef.current).forEach((audio) => audio?.pause())
    }
  }, [])
  useEffect(() => { mainRef.current?.focus() }, [screen])
  useEffect(() => {
    const ticker = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(ticker)
  }, [])
  useEffect(() => {
    if (!helpOpen) return
    const escape = (event: KeyboardEvent) => { if (event.key === 'Escape') setHelpOpen(false) }
    window.addEventListener('keydown', escape)
    return () => window.removeEventListener('keydown', escape)
  }, [helpOpen])

  const goHome = () => {
    if (tokenRef.current && viewRef.current.phase !== 'finished' &&
        !window.confirm('Rời trận sẽ tính là bỏ cuộc. Bạn muốn rời?')) return
    closeSession(true); saveToken(''); releasePending(); updateView(emptyView())
    shotEffectTimersRef.current.forEach((timer) => clearTimeout(timer))
    shotEffectTimersRef.current.clear(); setShotEffects({})
    playMusic('lobby')
    setRoomInfo(null); roomTicketRef.current = ''
    setScreen('landing'); setHelpOpen(false); setNotice('')
  }
  const connect = (resume = '') => {
    if (socketRef.current?.readyState === WebSocket.OPEN || socketRef.current?.readyState === WebSocket.CONNECTING) return
    releasePending(); setScreen('battle'); setNotice('')
    const query = resume ? `?resume=${encodeURIComponent(resume)}` : roomTicketRef.current
      ? `?ticket=${encodeURIComponent(roomTicketRef.current)}` : ''
    playMusic('battle')
    const socket = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/play${query}`)
    socketRef.current = socket
    const current = () => socketRef.current === socket
    const timedOut = () => {
      if (!current()) return
      updateView({ ...viewRef.current, phase: 'disconnected', error: 'Máy chủ không phản hồi. Kiểm tra địa chỉ hiện tại và server Haskell.' })
      releasePending(); socket.close()
    }
    timerRef.current = setTimeout(timedOut, 10000)
    socket.onmessage = (message) => {
      if (!current()) return
      try {
        if (String(message.data).startsWith('{')) {
          const meta = parseBridgeMessage(String(message.data))
          if (meta.type === 'RESUME_ERROR') {
            if (meta.code === 'INVALID_SESSION') saveToken('')
            updateView({ ...viewRef.current, phase: 'disconnected', error: meta.message })
            releasePending(); socket.close(); return
          }
          if (meta.type === 'ROOM_ERROR') {
            setNotice(meta.message); setScreen('rooms'); releasePending(); socket.close(); return
          }
          if (meta.type === 'ROOM_SESSION') {
            setRoomInfo((previous) => ({
              roomId: meta.roomId, roomName: meta.roomName, seat: meta.seat,
              displayName: meta.displayName, opponentName: meta.opponentName,
              ticket: previous?.ticket, expiresAt: null,
            }))
            return
          }
          if (meta.type === 'CONNECTION') {
            if (meta.missing.length) releasePending()
            updateView({ ...viewRef.current, missing: meta.missing }); return
          }
          saveToken(meta.token)
          if (meta.fleet) { setFleet(decodeOwnFleet(meta.fleet)); commandRef.current = meta.fleet }
          if (meta.frames) {
            updateView(replayView(meta.frames)); releasePending(); retryUntilRef.current = 0
            if (viewRef.current.phase === 'finished') saveToken('')
            if (!viewRef.current.accepted && viewRef.current.phase !== 'finished') {
              if (commandRef.current) socket.send(commandRef.current)
              else { setFleet(createFleet()); setScreen('placement'); setNotice('Phiên đã khôi phục. Hãy bố trí và xác nhận hạm đội.'); playMusic('placement') }
            }
          }
          return
        }
        const frame = parseFrame(String(message.data))
        if (frame.kind === 'WELCOME' && viewRef.current.player !== null) throw new Error('Máy chủ gửi danh tính lặp.')
        if (frame.kind === 'SHOT') showShotEffect(frame.coord, frame.outcome === 'MISS' ? 'miss' : 'hit')
        if (frame.kind === 'SHOT' || frame.kind === 'INCOMING') {
          playSound(frame.outcome === 'MISS' ? 'miss' :
            frame.outcome === 'WIN' || frame.outcome.startsWith('SUNK ') ? 'sunk' : 'hit')
        }
        updateView(applyFrame(viewRef.current, frame))
        if (frame.kind === 'WELCOME' && !resume) socket.send(commandRef.current)
        if (['OK', 'TURN', 'ERROR', 'GAME_OVER'].includes(frame.kind)) releasePending()
        if (frame.kind === 'GAME_OVER') {
          clearTimeout(reconnectRef.current)
          battleMusicRef.current?.pause()
          lobbyMusicRef.current?.pause()
          musicStoppedAtEndRef.current = true
          activeMusicRef.current = 'lobby'
          saveToken('')
        }
      } catch (error) {
        updateView({ ...viewRef.current, phase: 'disconnected', error: (error as Error).message })
        releasePending(); socket.close()
      }
    }
    socket.onclose = (event) => {
      if (!current()) return
      socketRef.current = null
      releasePending()
      if (viewRef.current.phase !== 'finished') updateView({ ...viewRef.current, phase: 'disconnected',
        error: viewRef.current.error ?? (event.code === 1011 ? 'Không kết nối được server Haskell. Hãy chạy server trước.' : 'Kết nối kết thúc trước khi nhận kết quả trận.') })
      if (viewRef.current.phase !== 'finished' && tokenRef.current) {
        if (!retryUntilRef.current) retryUntilRef.current = Date.now() + 300000
        if (Date.now() < retryUntilRef.current) reconnectRef.current = setTimeout(() => connect(tokenRef.current), 2000)
        else updateView({ ...viewRef.current, error: 'Hết thời gian tự kết nối. Mở IP hiện tại và nhập mã để xem kết quả từ máy chủ.' })
      }
    }
    socket.onerror = () => {
      if (current()) updateView({ ...viewRef.current, error: 'Không kết nối được cầu WebSocket. Kiểm tra lệnh pnpm start.' })
    }
  }
  const start = () => {
    try { commandRef.current = encodeFleet(fleet) }
    catch (error) { setNotice((error as Error).message); return }
    playMusic('battle')
    if (socketRef.current?.readyState === WebSocket.OPEN && tokenRef.current) {
      socketRef.current.send(commandRef.current); setScreen('battle'); return
    }
    updateView(emptyView()); retryUntilRef.current = 0; connect()
  }
  const resumeGame = (code: string) => {
    if (!/^[a-f0-9]{64}$/.test(code.trim())) { setNotice('Mã khôi phục phải có 64 ký tự.'); return }
    saveToken(code.trim()); retryUntilRef.current = 0; updateView(emptyView()); connect(code.trim())
  }
  useEffect(() => {
    let code = new URLSearchParams(location.hash.slice(1)).get('resume') ?? ''
    if (code) history.replaceState(null, '', location.pathname)
    if (!code) { try { code = sessionStorage.getItem('battleship.resume') ?? '' } catch { /* Manual code entry remains available. */ } }
    const boot = setTimeout(() => { if (code) resumeGame(code) }, 0)
    return () => clearTimeout(boot)
  }, [])
  const fire = (row: number, col: number) => {
    const coord = wireCoord({ row, col })
    const socket = socketRef.current
    if (!canFire(viewRef.current, coord, pendingRef.current) || socket?.readyState !== WebSocket.OPEN) return
    pendingRef.current = true; setPending(true)
    socket.send(`FIRE ${coord}`)
    timerRef.current = setTimeout(() => {
      updateView({ ...viewRef.current, phase: 'disconnected', error: 'Quá thời gian chờ kết quả. Trận đã ngắt để tránh dùng lượt cũ.' })
      releasePending(); socket.close()
    }, 10000)
  }
  const toggleFullscreen = async () => {
    try {
      if (document.fullscreenElement) await document.exitFullscreen()
      else await document.documentElement.requestFullscreen()
    } catch { setNotice('Trình duyệt chưa cho phép mở toàn màn hình.') }
  }
  const toggleSound = () => {
    const enabled = !soundEnabledRef.current
    soundEnabledRef.current = enabled
    setSoundEnabled(enabled)
    if (!enabled) {
      clearTimeout(sunkAudioTimerRef.current)
      lobbyMusicRef.current?.pause()
      placementMusicRef.current?.pause()
      battleMusicRef.current?.pause()
      Object.values(effectAudioRef.current).forEach((audio) => audio?.pause())
      return
    }
    if (!musicStoppedAtEndRef.current) playMusic(activeMusicRef.current)
  }
  return (
    <div className="app-shell">
      <a className="skip-link" href="#main-content">Bỏ qua thanh công cụ</a>
      <Header onFullscreen={() => void toggleFullscreen()} onHelp={() => setHelpOpen(true)} onHome={goHome} onSoundToggle={toggleSound} soundEnabled={soundEnabled} />
      {notice && <p className="game-error" role="alert">{notice}</p>}
      {screen === 'landing' && <section className="recovery-panel" aria-label="Khôi phục trận">
        <label>Mã khôi phục<input aria-label="Mã khôi phục" value={recoveryCode} onChange={(event) => setRecoveryCode(event.target.value)} /></label>
        <button className="secondary-button" onClick={() => resumeGame(recoveryCode)} type="button">Khôi phục trận</button>
      </section>}
      {screen === 'battle' && token && view.phase !== 'finished' && <section className="recovery-panel" aria-label="Kết nối lại">
        <label>Mã riêng để quay lại (hãy lưu trước khi đổi Wi-Fi)<input aria-label="Mã phiên của bạn" readOnly value={token} /></label>
        <p>Không chia sẻ mã này với đối thủ. Nếu máy chủ đổi IP, nhập link mới được in trên terminal máy chủ.</p>
        {view.missing?.map((entry) => <p key={entry.player}>{entry.player} còn {Math.max(0, Math.ceil((entry.deadline - now) / 1000))} giây để quay lại.</p>)}
        {view.phase === 'disconnected' && <>
          <p>Đang tự thử lại địa chỉ cũ. Thời gian thử còn khoảng {Math.max(0, Math.ceil((retryUntilRef.current - now) / 1000))} giây; máy chủ quyết định hạn khôi phục.</p>
          <label>Địa chỉ máy chủ hiện tại<input aria-label="Địa chỉ máy chủ hiện tại" value={serverAddress} onChange={(event) => setServerAddress(event.target.value)} /></label>
          <button className="secondary-button" type="button" onClick={() => {
            try { location.assign(recoveryURL(serverAddress, token)) } catch (error) { setNotice((error as Error).message) }
          }}>Kết nối địa chỉ mới</button>
        </>}
      </section>}
      <div id="main-content" ref={mainRef} tabIndex={-1}>
        {screen === 'landing' && <Landing onHelp={() => setHelpOpen(true)} onStart={() => {
          playSound('enter-room')
          setScreen('rooms')
        }} />}
        {screen === 'rooms' && <RoomSetup onBack={() => { playMusic('lobby'); setScreen('landing') }} onReady={(room) => {
          roomTicketRef.current = room.ticket ?? ''
          setRoomInfo(room); setFleet(createFleet()); setNotice(''); playMusic('placement'); setScreen('placement')
        }} />}
        {screen === 'placement' && roomInfo && <div className="room-share-card">
          <div><small>{roomInfo.roomName} • PHÒNG {roomInfo.seat}</small><strong>{roomInfo.roomId}</strong>
            <span>{roomInfo.expiresAt ? `Chờ người thứ hai · còn ${Math.max(0, Math.ceil((roomInfo.expiresAt - now) / 1000))} giây` : 'Bạn có thể chia sẻ tên phòng hoặc mã này.'}</span>
          </div>
          {roomInfo.expiresAt && <button className="secondary-button" onClick={() => {
            void navigator.clipboard?.writeText(roomInfo.roomId).catch(() => setNotice('Không sao chép được mã phòng.'))
          }} type="button">Sao chép mã</button>}
        </div>}
        {screen === 'placement' && <Placement
          fleet={fleet}
          onBack={() => setScreen('rooms')}
          onPickup={() => playSound('pickup')}
          onPlace={() => playSound('place')}
          onStart={start}
          onStartSound={() => playSound('start-match')}
          setFleet={setFleet}
        />}
        {screen === 'battle' && <Battle fleet={fleet} view={view} pending={pending} room={roomInfo} shotEffects={shotEffects} onFire={fire} onHome={goHome} />}
      </div>
      {helpOpen && <HelpDialog onClose={() => setHelpOpen(false)} />}
    </div>
  )
}
