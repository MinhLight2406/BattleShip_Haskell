import {
  type DragEvent,
  type MouseEvent,
  type ReactNode,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react'

const GRID_SIZE = 10
const ROW_LABELS = 'ABCDEFGHIJ'.split('')

type Screen = 'landing' | 'mode' | 'placement' | 'battle'
type GameMode = 'classic' | 'advanced'
type Orientation = 'horizontal' | 'vertical'
type ShipId = 'carrier' | 'battleship' | 'cruiser' | 'submarine' | 'destroyer'
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

type Coordinate = { row: number; col: number }
type Placement = Coordinate & { orientation: Orientation }
type ShipSpec = { id: ShipId; name: string; code: string; length: number }
type ShipState = ShipSpec & { orientation: Orientation; placement?: Placement }

const SHIP_SPECS: readonly ShipSpec[] = [
  { id: 'carrier', name: 'Hàng không mẫu hạm', code: 'CV-01', length: 5 },
  { id: 'battleship', name: 'Thiết giáp hạm', code: 'BB-07', length: 4 },
  { id: 'cruiser', name: 'Tuần dương hạm', code: 'CG-12', length: 3 },
  { id: 'submarine', name: 'Tàu ngầm', code: 'SS-24', length: 3 },
  { id: 'destroyer', name: 'Khu trục hạm', code: 'DD-31', length: 2 },
]

const createFleet = (): ShipState[] =>
  SHIP_SPECS.map((ship) => ({ ...ship, orientation: 'horizontal' }))

const cellsFor = (
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

const coordinateKey = ({ row, col }: Coordinate) => `${row}:${col}`

const isInsideBoard = ({ row, col }: Coordinate) =>
  row >= 0 && row < GRID_SIZE && col >= 0 && col < GRID_SIZE

const canPlace = (
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

const placeShip = (
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

const autoPlaceFleet = (source: ShipState[], random = Math.random) => {
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
    if (!placed) return source
  }

  return fleet
}

const shipAt = (fleet: ShipState[], row: number, col: number) => {
  for (const ship of fleet) {
    if (!ship.placement) continue
    const index = cellsFor(ship as ShipState & { placement: Placement }).findIndex(
      (cell) => cell.row === row && cell.col === col,
    )
    if (index >= 0) return { ship, index }
  }
  return null
}

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
  soundOn,
  onToggleSound,
  onHelp,
  onFullscreen,
  onHome,
}: {
  soundOn: boolean
  onToggleSound: () => void
  onHelp: () => void
  onFullscreen: () => void
  onHome: () => void
}) {
  return (
    <header className="topbar">
      <Brand onClick={onHome} />
      <nav aria-label="Công cụ trò chơi" className="topbar-actions">
        <IconButton
          icon={soundOn ? 'sound-on' : 'sound-off'}
          label={soundOn ? 'Tắt âm thanh giao diện' : 'Bật âm thanh giao diện'}
          onClick={onToggleSound}
          pressed={soundOn}
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
        <p className="eyebrow"><span /> MÔ PHỎNG CHIẾN THUẬT HẢI QUÂN</p>
        <h1>
          Làm chủ
          <span>đại dương.</span>
        </h1>
        <p className="hero-copy">
          Bố trí hạm đội, khóa tọa độ và chuẩn bị cho cuộc đấu trí trên biển.
          Mỗi quyết định đều để lại dấu vết.
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
      <p className="hero-footnote">PROTOTYPE GIAO DIỆN • REACT + TYPESCRIPT</p>
    </section>
  )
}

function ModeVisual({ advanced }: { advanced?: boolean }) {
  return (
    <div className={`mode-visual ${advanced ? 'advanced' : ''}`} aria-hidden="true">
      <div className="mode-radar">
        <span className="radar-sweep" />
        <span className="radar-ping ping-one" />
        {advanced && <span className="radar-ping ping-two" />}
      </div>
      <ShipGlyph length={advanced ? 3 : 5} />
      {advanced && <div className="scan-beam" />}
    </div>
  )
}

function ModeSelect({
  onSelect,
  onBack,
}: {
  onSelect: (mode: GameMode) => void
  onBack: () => void
}) {
  return (
    <section className="screen mode-screen">
      <div className="radar-backdrop" aria-hidden="true" />
      <div className="page-container mode-container">
        <button className="back-button" onClick={onBack} type="button">
          <Icon name="back" /> Quay lại
        </button>
        <div className="section-heading">
          <p className="eyebrow"><span /> BƯỚC 01 / 03</p>
          <h1>Chọn chế độ tác chiến</h1>
          <p>Chọn cấu hình phù hợp. Cả hai chế độ cùng dẫn tới bàn bố trí hạm đội.</p>
        </div>
        <div className="mode-grid">
          <article className="mode-card">
            <ModeVisual />
            <div className="mode-card-body">
              <span className="mode-index">01</span>
              <p className="mode-kicker">ĐỐI ĐẦU TIÊU CHUẨN</p>
              <h2>Cổ điển</h2>
              <p>Năm chiến hạm, lưới 10 × 10 và luật tác chiến nguyên bản.</p>
              <ul>
                <li><Icon name="check" size={18} /> Bố trí thủ công hoặc tự động</li>
                <li><Icon name="check" size={18} /> Phù hợp để trình diễn luồng chính</li>
              </ul>
              <button className="primary-button" onClick={() => onSelect('classic')} type="button">
                Chọn Cổ điển <Icon name="arrow-right" />
              </button>
            </div>
          </article>
          <article className="mode-card featured">
            <span className="mode-badge">MỞ RỘNG</span>
            <ModeVisual advanced />
            <div className="mode-card-body">
              <span className="mode-index">02</span>
              <p className="mode-kicker">TÁC CHIẾN NÂNG CAO</p>
              <h2>Trinh sát</h2>
              <p>Giao diện sẵn sàng cho radar và khí tài do Haskell cung cấp sau này.</p>
              <ul>
                <li><Icon name="check" size={18} /> Giữ nguyên luồng bố trí</li>
                <li><Icon name="check" size={18} /> Có điểm nối cho tính năng nâng cao</li>
              </ul>
              <button className="primary-button" onClick={() => onSelect('advanced')} type="button">
                Chọn Trinh sát <Icon name="arrow-right" />
              </button>
            </div>
          </article>
        </div>
      </div>
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
        <span className="board-label column-label" key={`column-${col}`}>{col + 1}</span>
      ))}
      {Array.from({ length: GRID_SIZE }, (_, row) => (
        <div className="board-row" key={`row-${row}`}>
          <span className="board-label row-label">{ROW_LABELS[row]}</span>
          {Array.from({ length: GRID_SIZE }, (_, col) => {
            const occupied = shipAt(fleet, row, col)
            const isPreview = previewKeys.has(coordinateKey({ row, col }))
            const classes = [
              'board-cell',
              occupied ? 'occupied' : '',
              occupied?.ship.id === selectedShipId ? 'selected' : '',
              occupied ? occupied.ship.orientation : '',
              occupied?.index === 0 ? 'segment-first' : '',
              occupied && occupied.index === occupied.ship.length - 1 ? 'segment-last' : '',
              isPreview ? (preview?.valid ? 'preview-valid' : 'preview-invalid') : '',
            ].filter(Boolean).join(' ')

            return (
              <button
                aria-label={`${ROW_LABELS[row]}${col + 1}${occupied ? `, ${occupied.ship.name}` : ', ô trống'}`}
                className={classes}
                disabled={!interactive}
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
                {enemy && <span className="enemy-dot" aria-hidden="true" />}
              </button>
            )
          })}
        </div>
      ))}
    </div>
  )
}

function Placement({
  mode,
  fleet,
  setFleet,
  onBack,
  onStart,
}: {
  mode: GameMode
  fleet: ShipState[]
  setFleet: (fleet: ShipState[]) => void
  onBack: () => void
  onStart: () => void
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
    setStatus(`${ship.name} đã vào vị trí ${ROW_LABELS[row]}${col + 1}.`)
  }

  const handleCellClick = (row: number, col: number) => {
    const occupied = shipAt(fleet, row, col)
    if (occupied && occupied.ship.id !== selectedId) {
      setSelectedId(occupied.ship.id)
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
    setFleet(
      fleet.map((ship) =>
        ship.id === selectedId ? { ...ship, placement: undefined } : ship,
      ),
    )
    setStatus(`${selectedShip.name} đã trở về quân cảng.`)
  }

  const randomize = () => {
    setFleet(autoPlaceFleet(fleet))
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
            <Icon name="back" /> Đổi chế độ
          </button>
          <div>
            <p className="eyebrow"><span /> BƯỚC 02 / 03 • {mode === 'classic' ? 'CỔ ĐIỂN' : 'TRINH SÁT'}</p>
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
                    setStatus(`Đã chọn ${ship.name}.`)
                  }}
                  onDragStart={(event: DragEvent<HTMLButtonElement>) => {
                    event.dataTransfer.setData('ship-id', ship.id)
                    event.dataTransfer.effectAllowed = 'move'
                    setSelectedId(ship.id)
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

function BattleReady({
  fleet,
  mode,
  onBack,
  onHome,
}: {
  fleet: ShipState[]
  mode: GameMode
  onBack: () => void
  onHome: () => void
}) {
  return (
    <section className="screen battle-screen">
      <div className="tactical-backdrop battle-backdrop" aria-hidden="true" />
      <div className="page-container battle-container">
        <div className="battle-heading">
          <div>
            <p className="eyebrow"><span /> BƯỚC 03 / 03 • HỆ THỐNG SẴN SÀNG</p>
            <h1>Phòng chiến đấu</h1>
          </div>
          <div className="connection-pill"><span /> Chờ máy chủ Haskell</div>
        </div>
        <div className="battle-boards">
          <article className="battle-board-card">
            <div className="battle-board-title">
              <div><small>LƯỚI PHÒNG THỦ</small><h2>Hạm đội của bạn</h2></div>
              <span>5 TÀU</span>
            </div>
            <Board fleet={fleet} />
          </article>
          <article className="battle-board-card enemy-card">
            <div className="battle-board-title">
              <div><small>LƯỚI TẤN CÔNG</small><h2>Vùng biển đối phương</h2></div>
              <span>ẨN DANH</span>
            </div>
            <div className="enemy-lock">
              <Icon name="lock" size={32} />
              <strong>Chưa nhận dữ liệu trận đấu</strong>
              <p>Khi backend Haskell kết nối, tọa độ tác chiến sẽ được kích hoạt tại đây.</p>
            </div>
            <Board enemy fleet={[]} />
          </article>
        </div>
        <div className="ready-banner">
          <div className="ready-icon"><Icon name="check" size={28} /></div>
          <div>
            <p className="eyebrow"><span /> PROTOTYPE HOÀN TẤT</p>
            <h2>Hạm đội đã sẵn sàng xuất kích</h2>
            <p>
              Chế độ {mode === 'classic' ? 'Cổ điển' : 'Trinh sát'} đã được cấu hình.
              Phần bắn, lượt chơi và kết quả sẽ do luồng xử lý Haskell đảm nhiệm.
            </p>
          </div>
          <div className="ready-actions">
            <button className="secondary-button" onClick={onBack} type="button">Chỉnh đội hình</button>
            <button className="text-button" onClick={onHome} type="button">Về trang đầu</button>
          </div>
        </div>
      </div>
    </section>
  )
}

function HelpDialog({ onClose }: { onClose: () => void }) {
  return (
    <div className="dialog-backdrop" onMouseDown={onClose} role="presentation">
      <section
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
          <li><span>01</span><div><strong>Chọn chế độ</strong><p>Cổ điển hoặc Trinh sát đều dẫn tới bàn bố trí.</p></div></li>
          <li><span>02</span><div><strong>Bố trí hạm đội</strong><p>Kéo tàu lên lưới, xoay hướng và tránh chồng lấn.</p></div></li>
          <li><span>03</span><div><strong>Bàn giao cho Haskell</strong><p>Sau “Bắt đầu trận”, prototype dừng tại điểm tích hợp backend.</p></div></li>
        </ol>
        <button className="primary-button dialog-button" onClick={onClose} type="button">Đã hiểu</button>
      </section>
    </div>
  )
}

export default function App() {
  const [screen, setScreen] = useState<Screen>('landing')
  const [mode, setMode] = useState<GameMode>('classic')
  const [fleet, setFleet] = useState<ShipState[]>(createFleet)
  const [soundOn, setSoundOn] = useState(true)
  const [helpOpen, setHelpOpen] = useState(false)
  const mainRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    mainRef.current?.focus()
  }, [screen])

  useEffect(() => {
    if (!helpOpen) return
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setHelpOpen(false)
    }
    window.addEventListener('keydown', closeOnEscape)
    return () => window.removeEventListener('keydown', closeOnEscape)
  }, [helpOpen])

  const goHome = () => {
    setScreen('landing')
    setHelpOpen(false)
  }

  const selectMode = (nextMode: GameMode) => {
    setMode(nextMode)
    setFleet(createFleet())
    setScreen('placement')
  }

  const toggleFullscreen = async () => {
    if (document.fullscreenElement) {
      await document.exitFullscreen()
    } else {
      await document.documentElement.requestFullscreen()
    }
  }

  return (
    <div className="app-shell">
      <a className="skip-link" href="#main-content">Bỏ qua thanh công cụ</a>
      <Header
        onFullscreen={() => void toggleFullscreen()}
        onHelp={() => setHelpOpen(true)}
        onHome={goHome}
        onToggleSound={() => setSoundOn((value) => !value)}
        soundOn={soundOn}
      />
      <div id="main-content" ref={mainRef} tabIndex={-1}>
        {screen === 'landing' && (
          <Landing onHelp={() => setHelpOpen(true)} onStart={() => setScreen('mode')} />
        )}
        {screen === 'mode' && (
          <ModeSelect onBack={() => setScreen('landing')} onSelect={selectMode} />
        )}
        {screen === 'placement' && (
          <Placement
            fleet={fleet}
            mode={mode}
            onBack={() => setScreen('mode')}
            onStart={() => setScreen('battle')}
            setFleet={setFleet}
          />
        )}
        {screen === 'battle' && (
          <BattleReady
            fleet={fleet}
            mode={mode}
            onBack={() => setScreen('placement')}
            onHome={goHome}
          />
        )}
      </div>
      {helpOpen && <HelpDialog onClose={() => setHelpOpen(false)} />}
    </div>
  )
}
