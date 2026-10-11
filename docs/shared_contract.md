# Hợp đồng chung S-01 v2 — Docker DK-09 và phụ lục NM-01, chờ duyệt

Ngày đối chiếu kỹ thuật: 2026-10-11. Chủ trì tài liệu: R.

**Hướng dẫn đọc hiện hành:** [chỉ mục docs](README.md), [kiến trúc](architecture.md), [rationale/đánh đổi](design_decisions.md), [slide mapping](slide_mapping.md) và [test](testing.md). Nhánh `Update_docs_report` dựa trên `8bd7da9` chỉ bổ sung/đồng bộ mô tả; không đổi fixture API/ownership, luật/wire hoặc ghi xác nhận thay nhóm. Mốc lập S-01 bên dưới là lịch sử, phần Docker đến DK-09 là hợp đồng đã bổ sung để nhóm duyệt.

**Trạng thái: đã lập bản hợp đồng để duyệt; CHƯA KHÓA vì chưa có xác nhận A/B/C/D.** Build/test xanh chỉ là bằng chứng kỹ thuật, không thay thế xác nhận của người phụ trách.

**Bổ sung NM-01 v1:** nhánh `Update_NUMA` tách từ `Update_docs_report` tại
`94a7aaaf68860a55cb7528c76f7c30f8fc1b6023`, lập [hợp đồng kiến trúc và phương
pháp đo](numa_design.md). Phụ lục mục 8 ghi quyết định cho NM-02..09;
source hiện tại vẫn theo các API/fixture bên dưới. Review nhóm của NM-01 được
theo dõi riêng trong tài liệu đó; cơ chế tương lai chưa là hiện trạng runtime.

Nhánh thực hiện: `Minh-Connect_Type_and_Main`, tách từ `Minh-Giao_thuc_lenh_va_event` tại `62ef6018a9d6167bda9909b04fce4a3c370ed936`. Bản nền này chứa C-01, A-01 và D-01; không đổi luật R-01.

## 1. Nguồn hợp đồng và phạm vi

| Nội dung | Nguồn chính |
|---|---|
| Luật và bất biến | [game_spec.md](game_spec.md), R-01 |
| Kiểu, constructor, trường, alias chữ ký | [Types.hs](../src/Battleship/Types.hs), A-01 |
| Byte framing, token, mã lỗi, thứ tự và người nhận | [protocol.md](protocol.md), D-01 |
| Khung hai executable và test suite | [package.yaml](../package.yaml), [stack.yaml](../stack.yaml), C-01 |
| Ghép các phần, chủ sở hữu và xác nhận | Tài liệu S-01 này |

Các module sử dụng kiểu chung bằng `import Battleship.Types` hoặc import có danh sách/qualified. Chỉ `src/Battleship/Types.hs` được định nghĩa `Coord` và `Command`; không tạo alias/ADT cùng tên ở Board, Rules, Protocol, Client, Server hoặc Main. `Show` dùng debug, không phải encoder TCP.

S-01 v1 đã đối chiếu kỹ thuật tại commit `f73dc87e336ba01d4723f642582403b1f20e2504` nhưng chưa có đủ bốn xác nhận. Người dùng yêu cầu tiếp tục A-02 trên nhánh `Minh-Build_board`: v2 cập nhật việc ẩn constructor Fleet và cài đặt Board; đây là nội dung mới để A/B/C/D duyệt, không phải bằng chứng v1/v2 đã khóa. R-01 và wire v1 giữ nguyên.

A-02/A-03 có Board thuần/fleet đúng MVP; B-01/B-02 có Rules.step cho mọi Command/Phase và kết quả bắn; B-03 có View.viewFor và test lọc bí mật. C-02/C-03/C-04/C-07 nối hai slot TCP vào lõi thật qua Coordinator/STM: một TVar GameState, hai TBQueue có giới hạn và writer riêng; MVar chỉ quản lý socket/cleanup. D-02 có codec/client một lệnh; D-03/D-04/D-05 thêm nhập/sửa/xem trước fleet, nhập FIRE theo TURN, hai bàn riêng tư và kết thúc trận. Frontend web dùng bridge TCP; codec/wire v1 giữ nguyên. A-06/B-06 kiểm tra tính chất bằng QuickCheck. S-01 vẫn chờ bốn xác nhận; API C-07 cần nhóm review trước hợp nhất.

## 2. API miền dùng chung

Block dưới là bản chụp các khai báo kiểu hiện có. `SharedContractSpec` so sánh token với Types.hs, bỏ comment và khác biệt trình bày; thay constructor, trường, kiểu trường, deriving hoặc alias sẽ làm test thất bại nếu tài liệu chưa được cập nhật.

<!-- contract:domain-api -->
```haskell
data PlayerId = P1 | P2
  deriving (Eq, Ord, Show, Enum, Bounded)

data Coord = Coord
  { coordColumn :: Int
  , coordRow :: Int
  } deriving (Eq, Ord, Show)

data ShipId = Carrier | Battleship | Cruiser | Submarine | Destroyer
  deriving (Eq, Ord, Show, Enum, Bounded)

data Orientation = Horizontal | Vertical
  deriving (Eq, Show)

data ShipPlacement = ShipPlacement
  { placementShip :: ShipId
  , placementStart :: Coord
  , placementOrientation :: Orientation
  } deriving (Eq, Show)

type FleetPlacement = [ShipPlacement]

type Fleet = Internal.Fleet ShipId Coord

data Outcome = Miss | Hit | Sunk ShipId | Win
  deriving (Eq, Show)

data PlayerState = PlayerState
  { playerFleet :: Maybe Fleet
  , playerShots :: Map Coord Outcome
  } deriving (Eq, Show)

data EndReason = AllShipsSunk | OpponentLeft
  deriving (Eq, Show)

data Phase = Placing | Turn PlayerId | Finished PlayerId EndReason
  deriving (Eq, Show)

data GameState = GameState
  { gamePlayer1 :: PlayerState
  , gamePlayer2 :: PlayerState
  , gamePhase :: Phase
  } deriving (Eq, Show)

data Command = PlaceFleet FleetPlacement | Fire Coord | Quit
  deriving (Eq, Show)

data Event
  = FleetAccepted PlayerId
  | GameStarted PlayerId
  | ShotResolved PlayerId Coord Outcome
  | TurnReady PlayerId
  | GameEnded PlayerId EndReason
  deriving (Eq, Show)

data GameError
  = InvalidCommand String
  | InvalidCoordinate Coord
  | InvalidFleetSize Int
  | MissingShip ShipId
  | DuplicateShip ShipId
  | ShipOutOfBounds ShipId Coord
  | ShipsOverlap Coord
  | FleetAlreadyPlaced
  | FleetsNotReady
  | NotYourTurn PlayerId
  | AlreadyFired Coord
  | GameAlreadyFinished
  deriving (Eq, Show)

data PlayerView = PlayerView
  { viewPlayer :: PlayerId
  , viewPhase :: Phase
  , ownFleetView :: Maybe Fleet
  , outgoingShotsView :: Map Coord Outcome
  , incomingShotsView :: Map Coord Outcome
  , opponentReady :: Bool
  } deriving (Eq, Show)

type Step = PlayerId -> Command -> GameState
  -> Either GameError (GameState, [Event])

type PlaceFleetFn = FleetPlacement -> Either GameError Fleet

type ViewFor = PlayerId -> GameState -> PlayerView
```

`Map` và `Set` ở đây là kiểu từ `containers`, lần lượt `Data.Map.Strict` và `Data.Set`. `Internal` là module private `Battleship.Internal.Fleet` trong `other-modules` của library, không được expose. Từ NM-06, nó giữ data tổng quát `Fleet ship coord`: geometry Map, tập ô bất biến tính sẵn và UArray Int Word8 100 ô; Eq xét cả metadata, Show giữ dạng geometry cũ. Cách dùng tham số tránh vòng import Types ↔ Board. Types chỉ xuất type Fleet và hàm đọc `fleetShips :: Fleet -> Map ShipId (Set Coord)`; không xuất constructor hoặc trường record có thể cập nhật. Board là module production duy nhất tạo Fleet qua constructor private, sau khi kiểm tra toàn bộ request. Code luật/client chỉ import API public; không import Internal. Fixture test cũng dùng placeFleet. Hai helper đọc mới của Board được ghi ở phụ lục NM-06.

Các hàm theo alias đã công bố (placeFleet đã cài đặt ở A-02):

```haskell
-- A: Battleship.Board
placeFleet :: FleetPlacement -> Either GameError Fleet
-- B: Battleship.Rules
step :: PlayerId -> Command -> GameState
     -> Either GameError (GameState, [Event])
-- B: Battleship.View
viewFor :: PlayerId -> GameState -> PlayerView
```

Helper hiện có: `boardSize :: Int`, `shipLength :: ShipId -> Int`, `otherPlayer :: PlayerId -> PlayerId`, `initialGameState :: GameState`, `playerStateFor :: PlayerId -> GameState -> PlayerState`, `shotsReceived :: PlayerId -> GameState -> Map Coord Outcome`, `setPlayerState :: PlayerId -> PlayerState -> GameState -> GameState`.

`shotsReceived player state = playerShots (playerStateFor (otherPlayer player) state)` là hàm đọc thêm ở B-02, không phải field lưu thứ hai. Mỗi FIRE thành công chỉ thêm một entry vào playerShots của actor; cùng entry xuất hiện trong shotsReceived của đối thủ. Không sửa layout PlayerState/GameState hoặc các chữ ký Step/PlaceFleetFn/ViewFor. Helper này thuộc nội dung API để nhóm duyệt cùng S-01 còn chờ xác nhận.

API Board A-02: `inBounds :: Coord -> Bool`, `shipCells :: ShipPlacement -> Either GameError (Set Coord)`, `placeFleet :: PlaceFleetFn`. Độ dài lấy từ ID tàu, không nhận độ dài tùy chọn. Đặt đúng năm ID duy nhất bảo đảm đủ cả năm loại: thiếu entry trả InvalidFleetSize, năm entry nhưng lặp ID trả DuplicateShip; không cần nhánh MissingShip riêng. Thứ tự lỗi: kiểm tra count trước, rồi từng placement trái sang phải: trùng ID → điểm đầu → vượt biên → chồng. Điểm đầu ngoài bàn trả InvalidCoordinate; phần thân vượt bàn trả ShipOutOfBounds kèm ô ngoài đầu tiên. Nếu nhiều ô chồng, trả ô nhỏ nhất theo Ord Coord. Tàu chạm cạnh/góc được phép; chỉ Right mới có Fleet, không trả fleet từng phần.

API đọc thêm NM-06: `fleetCells :: Fleet -> Set Coord`,
`shipAt :: Coord -> Fleet -> Either GameError (Maybe ShipId)` thuộc Board.
Ngoài bàn trả InvalidCoordinate trước phép tính index, nước trả Right Nothing,
ô tàu trả Right (Just ship). Không xuất array, mã số nội bộ hay hàm đổi metadata.

A-03 trên nhánh `Minh-Dat_tau` giữ API và các guard đã có trong A-02/B-01, bổ sung nghiệm thu trong BoardSpec. Fleet phải có đúng Carrier/Battleship/Cruiser/Submarine/Destroyer, không chỉ đúng tổng chiều dài: lặp Cruiser thay Submarine vẫn đủ 17 ô nhưng bị từ chối. Board kiểm tra hình học độc lập với trạng thái; Rules.step kiểm tra FleetAlreadyPlaced trước Board và không cho thay fleet đã xác nhận khi chờ/đang chơi. Finished trả GameAlreadyFinished. Test kiểm tra cả P1/P2, request hợp lệ khác/sai, sửa request trước xác nhận và giữ đội tàu đầu tiên khi người thứ hai đặt. Năm probe GHC kiểm chứng public constructor/read access hợp lệ và chặn constructor thô, record update, coerce từ Map rỗng, import module private. Không thay khai báo kiểu, wire v1 hoặc quyền tạo Fleet.

Rules B-01/B-02 xuất `step :: Step`, dùng Board thật và không import Internal. Ma trận hiện có:

| Phase | PlaceFleet | Fire | Quit |
|---|---|---|---|
| Placing | Đã đặt → FleetAlreadyPlaced; chưa đặt → Board kiểm tra và lưu toàn bộ fleet; đủ hai người → Turn P1 | FleetsNotReady | Finished (otherPlayer actor) OpponentLeft |
| Turn current | Thiếu một fleet → FleetsNotReady; đủ → FleetAlreadyPlaced | Kiểm tra readiness, actor/current, tọa độ, bắn lặp; qua hết → ghi shot, Miss/Hit/Sunk/Win và phase mới | Finished (otherPlayer actor) OpponentLeft |
| Finished winner reason | GameAlreadyFinished | GameAlreadyFinished | GameAlreadyFinished, giữ winner/reason |

PLACE thành công phát `[FleetAccepted actor]`; lần đặt bắt đầu trận phát `[FleetAccepted actor, GameStarted P1, TurnReady P1]`. QUIT phát duy nhất `[GameEnded winner OpponentLeft]`, giữ nguyên hai fleet/lịch sử. Lỗi trả Left, không có state mới/Event thành công; Coordinator giữ toàn bộ state cũ. RulesSpec và CoordinatorSpec kiểm tra hợp đồng này, gồm TCP thật và giao dịch STM C-04.

B-02 thay nhánh FIRE tạm thời bằng kết quả thật. Không thuộc tàu đối thủ → Miss; thuộc tàu và sau phát bắn tất cả ô fleet đã được bắn → Win; nếu chỉ toàn bộ ô tàu đó đã được bắn → Sunk ship; còn lại → Hit. Kiểm tra tập tọa độ, không dùng tổng số shot hoặc vùng liên thông của các tàu chạm nhau. Ghi tọa độ/outcome mới vào lịch sử actor một lần, không sửa outcome cũ hay hai fleet. Miss đổi Turn sang đối thủ; Hit/Sunk giữ Turn actor; Win chuyển Finished actor AllShipsSunk. Event đúng thứ tự `[ShotResolved actor coord outcome, TurnReady next]` hoặc `[ShotResolved actor coord Win, GameEnded actor AllShipsSunk]`, không có Sunk/TurnReady thêm sau Win. FIRE lặp/sai vẫn Left theo ưu tiên B-01, không tiêu lượt. C-03 đã gọi step để thực thi các phản hồi này qua TCP.

## 3. Ghép kiểu với giao thức và hai Main

| Điểm giao nhau | Quy ước đã đối chiếu |
|---|---|
| Tọa độ | Cột/hàng bắt đầu từ 1; A1 = Coord 1 1, J10 = Coord 10 10; parser từ chối A01/a1/K1/A0/A11 |
| Đặt tàu | PLACE → PlaceFleet [ShipPlacement]; giữ danh sách để phát hiện thiếu/trùng ID; H tăng cột, V tăng hàng |
| Fleet chưa đặt | Nothing; không dùng Just (Fleet empty) để đánh dấu sẵn sàng |
| Hai người | GameState có hai PlayerState riêng; P1/P2 do socket server gán, không do client khai |
| Bắn/rời trận | FIRE → Fire Coord; QUIT/EOF → Quit của danh tính socket |
| Kết quả | ShotResolved → SHOT cho shooter, INCOMING cho otherPlayer; không gửi constructor Show |
| Lượt | Miss đổi lượt; Hit/Sunk giữ lượt; Win phát GameEnded, không có TurnReady |
| Lỗi | Left GameError giữ nguyên state, chỉ phản hồi actor; NotYourTurn chứa người đang có lượt |
| Bí mật | PlayerView không có fleet đối thủ; wire v1 không có VIEW/snapshot hoặc PLACE của đối thủ |
| TCP | 1 payload/LF, nhận CRLF, tối đa 256 byte; recv không tương đương một frame |
| Hiển thị | Mã ASCII cố định; client ánh xạ sang câu tiếng Việt |

Transcript chuẩn để C/D nghiệm thu là mục 7.1 của [protocol.md](protocol.md): WELCOME → PLACE/OK/WAITING → người thứ hai PLACE/OK → START P1/TURN P1 → FIRE A6 → SHOT/INCOMING HIT → TURN P1. Các mục 7.2–7.6 quy định lỗi, MISS, SUNK, WIN, QUIT, EOF và kết nối thứ ba. S-01 tham chiếu trực tiếp để tránh duy trì hai bản transcript có thể lệch nhau; ProtocolSpec đọc chính các block đó.

| Executable | Điểm vào | Module/kiểu | Chủ sở hữu |
|---|---|---|---|
| battleship-server | app/ServerMain.hs | Main; main :: IO () | C |
| battleship-client | app/ClientMain.hs | Main; main :: IO () | D |

Hai file đều tên module Main vì nằm trong hai component Cabal khác nhau; `other-modules: []` tránh Hpack đưa Main còn lại vào nhầm executable. Cả hai phụ thuộc cùng library `battleship-haskell`, trong đó Types chỉ được biên dịch như một module chung. ServerMain đọc port (mặc định 4000), gọi Server, in địa chỉ sẵn sàng; ClientMain hỗ trợ mặc định/`--place [PORT]` cho nhập đặt tàu D-03, `[PORT] "COMMAND"` cho một lệnh D-02. Main chọn CLI/port và UTF-8, luồng nhập/preview/check nằm trong Client. Smoke test dùng --help; executable test kiểm chứng TCP và stdin. Luật thuần thuộc Board/Rules/View.

### Phạm vi transport C-02/C-03/C-04/C-07

`Battleship.Server.runServer :: PortNumber -> (PortNumber -> IO ()) -> IO ()` bind `127.0.0.1`; callback nhận port thực tế sau listen, port 0 dành cho thử nghiệm không tranh port cố định. `PortNumber` thuộc `network`, không tạo kiểu miền trùng với Types. Hai kết nối nhận WELCOME theo thứ tự accept; kết nối thứ ba nhận ERROR SERVER_FULL rồi bị đóng, không tạo worker hay thay đổi hai slot.

**Bổ sung transport DK-02 (C/D cần review trước hợp nhất):** giữ nguyên `runServer`/`runServerWith`; thêm API sau trong Battleship.Server, không đổi domain/wire:

```haskell
-- ServerConfig abstract, không xuất constructor hoặc record label có thể update.
defaultServerConfig :: ServerConfig
parseServerConfig :: Maybe String -> Maybe FilePath -> Either String ServerConfig
serverBindHost :: ServerConfig -> String
serverReadyFile :: ServerConfig -> Maybe FilePath
runServerConfigured :: ServerConfig -> PortNumber -> (PortNumber -> IO ()) -> IO ()
```

`Nothing` dùng mặc định loopback/không marker; `Just ""` là lỗi. ServerMain đọc BATTLESHIP_BIND_HOST/BATTLESHIP_READY_FILE, parse trước IO listener, rồi chạy lõi Rules thật. IPv4 canonical/localhost được kiểm tra thuần; không DNS hoặc URL/port trong host. Readiness marker được xóa trước bind, ghi nguyên tử sau listen trước callback và dọn trong bracket trên mọi đường thoát có cleanup. Lỗi bind ghi rõ host/port; lỗi marker không báo ready. Healthcheck không tạo kết nối TCP vào cổng chơi. Unix giữ ReuseAddr để restart; Windows bật SO_EXCLUSIVEADDRUSE tránh hai listener wildcard/loopback tranh cùng cổng.

Library thêm `directory`/`filepath` cho marker; executable server thêm `unix` chỉ khi không phải Windows, dùng SIGTERM đưa tín hiệu kết thúc vào owner thread để chạy finalizer. Không sửa Board/Rules/View/Coordinator hoặc lifecycle một trận. Chi tiết cấu hình và vòng đời Docker ở [docker_deployment.md](docker_deployment.md); test DK-02 gồm parser, TCP, callback/marker và executable dùng env thật.

Server tách dòng TCP với LF/CRLF và giới hạn 256 byte, gọi atomically Coordinator.submitPayload → Protocol.parseCommand → Step → Protocol.encodeEvent. Payload sai không tới Step để xử lý lệnh; Left GameError giữ state cũ và xếp lỗi actor-only nếu batch đủ chỗ. Nếu xếp lỗi gây quá tải, C-07 gọi Step với Quit riêng cho người nhận bị quá tải. EOF/lỗi socket gọi atomically submitCommand core coordinator actor Quit; sau Finished không gọi lại Step hoặc đổi winner. LINE_TOO_LONG xếp lỗi nếu đủ chỗ rồi xử lý rời trận qua core; nếu hết chỗ, đi thẳng đường Quit quá tải. Không thêm mã wire hoặc đổi luật R-01.

Một TVar GameState trong Coordinator là nguồn sự thật; state/phản hồi lọc theo người nhận cùng commit trong STM. Hai TBQueue FIFO chứa Maybe ByteString, Just là frame, Nothing là marker sau batch cuối. Mỗi socket có một writer; send ngoài STM và có timeout/watchdog 2 giây. MVar chỉ giữ registry, các writer đã drain và cờ stopped cho cleanup/lỗi nội bộ; Lobby không có GameState. Encode lỗi không ghi state/queue, dừng session qua kênh Either SomeException (). WELCOME đứng đầu queue khi admission; supervisor chờ mọi writer hiện hữu nhận marker và dọn socket. Writer bị ngắt bỏ phần chưa gửi thay vì chờ peer đọc.

Coordinator API thuần coordinate/applyCommand giữ chữ ký cũ, dùng chung prepare/encode với API STM. Server dùng các chữ ký C-04/C-07 dưới đây; Coordinator là kiểu abstract, không xuất TVar hoặc constructor. Bool kết quả nghĩa là tiếp tục nhận lệnh: Right True kể cả khi vừa xếp lỗi lệnh, Right False sau Finished; Left ProtocolError là lỗi encode/hợp đồng batch nội bộ. NextFrame block khi queue rỗng; Nothing là end marker.

```haskell
newCoordinator :: GameState -> STM Coordinator
newCoordinatorWithCapacity :: Natural -> GameState -> STM Coordinator
readGameState :: Coordinator -> STM GameState
submitPayload :: Step -> Coordinator -> PlayerId -> ByteString -> STM (Either ProtocolError Bool)
submitCommand :: Step -> Coordinator -> PlayerId -> Command -> STM (Either ProtocolError Bool)
submitTooLong :: Step -> Coordinator -> PlayerId -> STM (Either ProtocolError Bool)
welcomePlayer :: Coordinator -> PlayerId -> STM (Either ProtocolError Bool)
nextFrame :: Coordinator -> PlayerId -> STM (Maybe ByteString)
queuedFrameCount :: Coordinator -> PlayerId -> STM Natural
isSlowClient :: Coordinator -> PlayerId -> STM Bool
```

Caller dùng atomically; không gọi socket IO/unsafeIOToSTM trong các STM action này. `runServerWith :: Step -> GameState -> PortNumber -> (PortNumber -> IO ()) -> IO ()` giữ seam C-03; production dùng Rules.step/initialGameState. Danh tính lấy từ socket, không từ lệnh; không viết lại luật thắng thua trong C. Library/test thêm dependency stm tại package.yaml, snapshot vẫn lts-24.59/GHC 9.10.3.

#### Giới hạn và chính sách client chậm C-07

- Mặc định **128 phần tử mỗi người**: tối đa **126 frame thường**, dành **2 chỗ** cho đúng một `GAME_OVER` và marker `Nothing`. Giới hạn tính phần tử đang nằm trong queue, bao gồm WELCOME/lỗi; không bao gồm frame writer đang gửi hoặc bộ đệm TCP của OS. Payload vẫn tối đa 256 byte, frame LF tối đa 257 byte; dữ liệu frame nằm trong một queue khoảng 32 KiB, chưa tính overhead Haskell. Đây là lựa chọn MVP cho một trận hai người.
- `newCoordinatorWithCapacity` dùng `Natural` của `Numeric.Natural`; dung lượng nhỏ nhất **5**, đủ batch `OK PLACE/START/TURN` và hai chỗ kết thúc. Giá trị nhỏ hơn ném lỗi cấu hình trong STM. Test dùng 5/8 để chủ động tạo tình huống thiếu chỗ. Hai API đọc chỉ quan sát độ dài/cờ transport, không cho sửa queue.
- Mỗi submit encode toàn bộ batch, kiểm tra số frame thường cần cho **cả P1 và P2 trước mọi write** trong cùng giao dịch. Nếu đủ chỗ mới ghi trạng thái và tất cả frame. Không dùng việc `writeTBQueue` đợi chỗ trống làm chính sách điều tiết trận.
- Nếu thiếu chỗ, hủy toàn bộ batch và trạng thái dự kiến của lệnh đó, gọi `core overloadedPlayer Quit oldState`. Người nhận bị quá tải có thể khác người gửi lệnh. Chỉ commit kết quả Quit và thông báo kết thúc đã lọc; không bỏ âm thầm SHOT/INCOMING/TURN. Quit production giữ nguyên fleet/lịch sử và kết thúc theo Rules. Ngay cả lệnh bắn thắng cũng bị hủy nếu frame SHOT không đủ chỗ.
- Nếu **cùng một batch** làm cả hai queue quá tải, chọn P1 để gọi Quit trước (P2 thắng `OPPONENT_LEFT`), đánh dấu cả hai socket cần đóng. Giữa các giao dịch tranh nhau, giao dịch kết thúc commit trước quyết định kết quả; các submit/EOF sau Finished không đổi winner hoặc thêm marker.
- Trước commit, batch Finished phải có đúng một `GAME_OVER` khớp phase làm frame cuối của mỗi người; batch thường không có GAME_OVER. Fallback Quit phải chỉ tạo GAME_OVER. Core thử nghiệm sai hợp đồng trả `Left InvalidMessage`, không ghi trạng thái/queue/cờ; không thể chiếm hết phần dự trữ và khiến STM chờ vô hạn.
- Cờ client chậm là metadata transport trong TVar riêng (tối đa hai danh tính), không phải bản sao GameState. Mỗi socket có worker chờ cờ bằng STM; worker đóng đúng socket **ngoài STM**, đánh thức recv/send. Writer lỗi bỏ phần FIFO còn lại (đã giới hạn 128) tới marker, báo dọn xong; không chờ drain qua mạng cho client bị ngắt. Đối thủ còn đọc vẫn nhận GAME_OVER sau các frame trước đó. Cleanup có thể đóng socket nhiều lần an toàn, nhưng chỉ có một chuyển trạng thái kết thúc và một thông báo hoàn tất session.
- Watchdog gửi **2 giây** và grace dọn reader **200 ms** giữ nguyên. Người chưa gửi lệnh/đang nhập tàu không bị xem là chậm. Chính sách nối lại **5 phút** của phiên web ở bridge giữ nguyên; C-07 giới hạn outbox của kết nối TCP Haskell, không thêm timeout nhập của trình duyệt.

**Tác động API cần nhóm review trước hợp nhất:** `submitTooLong` thêm tham số `Step` để Quit quá tải dùng đúng core đã tiêm; thêm constructor dung lượng và hai phép đọc ở trên. Caller trong Server/test đã cập nhật. Không đổi Types, Board, Rules, View hoặc wire v1; chưa ghi xác nhận A/B/C/D thay nhóm.

Lệnh kiểm tra: `stack test --ghc-options=-Werror --test-arguments="--match=C-07"`; sau đó `stack build` và `stack test --ghc-options=-Werror`. Test STM dùng cổng đồng bộ, mỗi kịch bản tranh chấp chạy 100 lần; TCP dùng socket thật không đọc, deadline 10 giây cho mỗi thao tác/đợi server, kiểm tra peer đóng và bind lại cổng.

**Kết quả chạy thật 2026-10-08:** nhánh `Update_gioi_han_cho_hang_doi` tách từ `67e44e0`; `stack build` thành công, toàn bộ `stack test --ghc-options=-Werror` **856 examples, 0 failures** (gồm QuickCheck A-06/B-06). C-07 có **25 examples, 0 failures**, gồm 300 cuộc đua STM và 10 session cả hai socket không đọc. Chạy thêm `node --test test/integration.test.mjs test/reconnect.test.mjs` tại frontend với `BATTLESHIP_SERVER` trỏ executable vừa build: **11/11 qua**, gồm ván thật, riêng tư và mốc nối lại 300.000 ms. Log cục bộ ở `.stack-work/c07/{build,test,web-test}.log` (ignored, không thuộc sản phẩm Git). Bằng chứng này không thay xác nhận review API của nhóm.

### API giao thức/client D-02

`Protocol.parseCommand` dùng Command/Coord từ Types; `parseResponse` dùng Response/WireError riêng cho các token wire, không định nghĩa lại kiểu miền. Parser nhận ByteString payload không có terminator, encoder trả frame LF và Either ProtocolError. Server/Client dùng `feedFrames pending chunk` để xử lý LF/CRLF và giới hạn byte. `wireError` loại bỏ tham số debug không được truyền; `encodeEvent phaseMới event` trả danh sách người nhận/frame, dùng SHOT/INCOMING và WAITING đúng hợp đồng. Chữ ký và quy ước đầy đủ tại mục 9 của protocol.md.

`Client.runClient :: HostName -> PortNumber -> Command -> (Response -> IO ()) -> IO ()` nhận WELCOME, gửi một lệnh, callback hiển thị phản hồi, rồi đóng socket khi nhận OK PLACE/SHOT phù hợp, ERROR hoặc GAME_OVER. Có deadline 10 giây và cleanup; chưa có vòng nhập tương tác/render bàn nên không dùng client này để chơi trọn ván. Test D-02 nhận lỗi Rules thật qua server tích hợp; CoordinatorSpec giữ hai kết nối để kiểm chứng nhiều lệnh/TCP.

D-03 thêm `runPlacementClient :: HostName -> PortNumber -> Handle -> Handle -> IO ()`, `promptFleet :: Handle -> Handle -> IO (Maybe FleetPlacement)`, `parsePlacementInput :: ShipId -> String -> Either String ShipPlacement` và `renderFleet :: Fleet -> String`. Dựng/sửa draft offline, Board.shipCells/placeFleet dùng chung với server; HUY/EOF trả Nothing và không gửi, GUI trả request đầy đủ. Preview chỉ nhận Fleet của mình. Kết nối sau GUI, gửi một PLACE canonical; OK chuyển sang giữ socket nhận event, không chịu deadline chờ đối thủ. Supervisor đóng socket trước khi join reader khi cancel. Không thêm dependency/Command/Event mới; nhập nước bắn thuộc task tiếp theo.

## 4. Chủ sở hữu file

Danh sách dưới bao phủ toàn bộ file Haskell hiện tại và hai cấu hình. Tên A/B/C/D/R là vai trò, chưa thay bằng tên người khi chưa có thông tin. C và D cùng review IntegrationSpec; C phụ trách ghi file để tránh hai nhánh sửa cùng chỗ. R phụ trách Spec tổng, kiểm tra hợp đồng chung và tài liệu.

<!-- contract:owners -->
```text
src/Battleship/Types.hs A
src/Battleship/Internal/Fleet.hs A
src/Battleship/Board.hs A
src/Battleship/Rules.hs B
src/Battleship/View.hs B
src/Battleship/Coordinator.hs C
src/Battleship/GameWorker.hs C
src/Battleship/Server.hs C
src/Battleship/Protocol.hs D
src/Battleship/Client.hs D
app/ServerMain.hs C
app/ClientMain.hs D
test/TypesSpec.hs A
test/BoardSpec.hs A
test/FleetIndexSpec.hs A
test/TestSupport/Generators.hs A
test/RulesSpec.hs B
test/ViewSpec.hs B
test/CoordinatorSpec.hs C
test/GameWorkerSpec.hs C
test/ServerSpec.hs C
test/ClientSpec.hs D
test/IntegrationSpec.hs C
test/ProtocolSpec.hs D
test/SharedContractSpec.hs R
test/Spec.hs R
bench/Main.hs B
bench/Fixtures.hs B
bench/FixturesSpec.hs B
bench/FleetMain.hs A
package.yaml C
stack.yaml C
```

`stack.yaml.lock` do Stack tạo và C quản lý cùng snapshot. File .cabal do Hpack sinh, không sửa trực tiếp. README.md và docs/ thuộc R. Thêm file mới phải bổ sung người phụ trách vào bản hợp đồng; quyền Git không tự được áp đặt bởi bảng này.

## 5. Build/test và căn cứ slide

Stack đã dùng: 3.11.1; snapshot `lts-24.59`, GHC 9.10.3; Haskell2010. Chạy từ thư mục gốc của repository:

```sh
stack build
stack test
stack test --ghc-options=-Werror
stack test --test-arguments="--match S-01"
```

- TypesSpec: kiểu/alias, helper, hằng số R-01, hai trạng thái riêng.
- BoardSpec A-02/A-03: hình học/fleet đúng MVP, mép/chạm cạnh/lặp ID dài 3, toàn bộ 3125 tổ hợp năm ID, đặt lại bị Rules từ chối và các probe GHC bảo vệ API Fleet.
- ProtocolSpec D-01/D-02: gọi API production với golden vectors/transcript D-01, framing byte, lỗi, định tuyến và round-trip; giữ Coord/Command của Types.
- RulesSpec B-01/B-02: chữ ký step thực tế, đủ Command/Phase cho hai actor/turn/winner/reason, Board thật, bắt đầu P1 một lần, rollback hợp đồng Left, readiness/sai lượt/tọa độ/bắn lặp, Quit/EOF lặp; mọi kết quả bắn, lịch sử/shot nhận, tàu chạm cạnh/ngang/dọc, mọi thứ tự bắn từng tàu và ván thuần cho cả hai winner.
- ViewSpec B-03: chữ ký viewFor thuần; đúng chủ fleet/history/readiness, toàn ván Miss/Hit/Sunk/Win cho cả hai winner, soát mọi ô đối thủ chưa bắn và đối chiếu toàn PlayerView; 72 layout bí mật cho mỗi viewer, bí mật sau Quit, tọa độ trùng giữa hai bàn và frame/errors actor-only qua Coordinator production. Không đổi PlayerView hoặc wire v1; Server dùng sự kiện đã lọc.
- QuickCheck A-06/B-06: generator dùng chung do A phụ trách, A/B cùng review. Mỗi property chạy tối thiểu 1.000 trường hợp; BoardSpec kiểm tra đội tàu và độ bao phủ mép/góc, ViewSpec tạo trạng thái qua step và đối chiếu hai trận có bí mật khác nhau nhưng cùng sự kiện công khai. Bao phủ Placing/Turn/Finished, Sunk và cả hai lý do kết thúc; Hspec in seed và phản ví dụ để tái hiện.
- SharedContractSpec: API nguồn khớp bản chụp, chỉ Types định nghĩa Coord/Command, Fleet abstract và chỉ Board/Types truy cập representation private, danh sách chủ sở hữu đủ/không trùng, hai điểm vào Main có main :: IO (). Test đọc src/app/test trong repository; chạy test binary riêng cần đặt working directory ở gốc repo.
- ServerSpec C-02: TCP thật qua server library; slot/third client, QUIT/EOF, race kết nối/bỏ cuộc, framing byte và cleanup khi cancel/lỗi startup, dừng rồi bind lại cùng port.
- CoordinatorSpec C-03: unit test ranh giới parse/step/state/encode và TCP thật với stub/lõi thật; transcript, rollback, concurrent PLACE/FIRE, lỗi nội bộ, Sunk/Win và EOF giữ winner.
- CoordinatorSpec C-04: 19 test STM, 250 race có barrier, commit state/queue, lỗi không ghi state, encode lỗi/throwSTM/retry rollback toàn bộ, FIFO/end marker, WELCOME và queue chưa đọc không giữ lượt; server C-02/C-03 chạy trên TVar/writer production.
- CoordinatorSpec/ServerSpec C-07: giới hạn 128/126/2, batch thiếu chỗ không commit một phần, đúng người quá tải, Quit qua core, kết thúc/đánh thức writer khi đầy, rollback toàn bộ kể cả cờ transport, 300 cuộc đua STM có gate (100 lần/kịch bản), socket thật không đọc một/cả hai bên, deadline cleanup và tái sử dụng cổng; client đọc bình thường giữ FIFO.
- ClientSpec D-02: client library với C-02/peer có kịch bản; handshake, một lệnh, phân mảnh, lỗi/EOF, cleanup, hiển thị tiếng Việt.
- ClientSpec D-03: parser địa phương, golden preview, handle nhập/sửa/hủy/EOF; một PLACE, giữ kết nối sau OK/quá 10 giây, cancel, lỗi wire và server thật. IntegrationSpec D-03 kiểm tra CLI mặc định/port và stdin sửa/preview/GUI đến START/INCOMING/GAME_OVER.
- ClientSpec D-04: input A1/FIRE/QUIT và lỗi, lượt/thắng/thua theo danh tính, một FIRE đang chờ, SHOT khớp tọa độ, lỗi/retry/bắn lặp/EOF và chuỗi Miss/Hit/Sunk/Win. IntegrationSpec D-04 chơi một ván thật đến thắng, GAME_OVER khi stdin mở và chưa nhập xong.
- IntegrationSpec: hai smoke test --help, CLI sai/bind lỗi, server executable thật với hai client và người thứ ba; client executable gửi QUIT/FIRE vào C-02, xác nhận tiếng Việt UTF-8 và exit code.

Căn cứ slide: ADT/pattern matching/Either cho kiểu và lỗi; hàm thuần và module để tách luật khỏi socket; Hspec describe/it/shouldBe (Chap8); Network.Socket/bracket và TCP stream (Chap11); MVar cho registry/lifecycle (Chap5), TVar/readTVar/writeTVar/atomically và rollback khi tranh chấp (Chap6 Syncronization), async/timeout quản lý worker/deadline (Chap7). C-04 cập nhật trận bằng STM và writer riêng. Xem [architecture.md](architecture.md) và [test_evidence.md](test_evidence.md).

## 6. Xác nhận và hiệu lực khóa

Mỗi người code cần đọc Types, protocol (đặc biệt transcript 7.1), hai Main, bảng chủ sở hữu và kết quả build/test **trên cùng commit S-01 được review**. R ghi tên/GitHub, ngày, SHA commit đã duyệt và link comment/PR hoặc lời xác nhận được cung cấp trực tiếp. Không dùng kết quả test hoặc tên tác giả commit làm chữ ký thay người.

| Vai trò | Người/GitHub | Commit đã duyệt | Ngày | Bằng chứng | Trạng thái |
|---|---|---|---|---|---|
| A | — | — | — | — | CHỜ XÁC NHẬN |
| B | — | — | — | — | CHỜ XÁC NHẬN |
| C | — | — | — | — | CHỜ XÁC NHẬN |
| D | — | — | — | — | CHỜ XÁC NHẬN |

Mẫu để mỗi thành viên ghi: `A — <tên/GitHub>: xác nhận S-01 v2 tại <SHA>; đã duyệt Types, Board/ẩn Fleet, giao thức/transcript, Main, chủ sở hữu và build/test.` B/C/D dùng mẫu tương ứng. Nếu có chỉnh sửa nội dung sau khi một người duyệt, người đó cần duyệt lại revision mới; commit chỉ bổ sung các bằng chứng xác nhận không thay đổi nội dung kỹ thuật thì không cần lặp chữ ký.

R chỉ chuyển trạng thái sang **ĐÃ KHÓA** khi đủ bốn xác nhận cho cùng nội dung và build/test xanh. Sau mốc khóa, mọi thay đổi cần A/B/C/D đồng ý trước khi hợp nhất. R ghi thay đổi, ảnh hưởng, bằng chứng test và bốn xác nhận; đổi hợp đồng thì tăng revision S-01, đổi wire không tương thích thì tăng phiên bản giao thức. Không tự sửa Types/transcript rồi coi test xanh là đã được nhóm đồng ý.

Checklist nghiệm thu hiện tại: nội dung kỹ thuật được đối chiếu và có kiểm tra chạy được; xác nhận của bốn người còn thiếu, nên **S-01 chưa đạt toàn bộ tiêu chí xong**.

## 7. Hợp đồng Docker và bàn giao DK-09

Đây là phần bổ sung triển khai để nhóm review, không thay ADT/chữ ký lõi R-01 hoặc wire TCP v1. Nguồn cấu hình chi tiết: [docker_deployment.md](docker_deployment.md), `.env.example` và `compose.yaml`. Lệnh vận hành duy nhất cho bàn giao: [README — hướng dẫn chuẩn DK-09](../README.md#chạy-bằng-docker--hướng-dẫn-chuẩn-dk-09); [dk09_handover.md](dk09_handover.md) ghi môi trường, kết quả và danh sách review. Những mốc nhánh/SHA ở các mục trước là lịch sử, không phải commit chốt Docker mới.

### Cấu hình, API và vòng đời cần duyệt

| Phần | Thay đổi/hợp đồng hiện tại | Ảnh hưởng |
|---|---|---|
| Haskell DK-02 | ServerConfig/parseServerConfig/runServerConfigured và readiness callback/marker; giữ runServer/runServerWith cũ | Native vẫn loopback; Docker bind 0.0.0.0, health đọc marker sau listen, không chiếm slot |
| Bridge DK-03 | BATTLESHIP_TCP_HOST/WEB_PUBLIC_PORT, PUBLIC_ORIGIN hoặc LAN_ORIGINS_FILE, `/healthz` HTTP | Compose gọi DNS haskell:4000; public 8081 khác internal 8080; Origin/Host chính xác |
| Helper DK-06 | Windows IPv4 host, origin file nguyên tử/heartbeat 2 giây, env-file hiệu lực | Mount cả thư mục chỉ đọc; đổi IP không restart; file sai/quá hạn bỏ LAN allowlist, giữ phiên đang mở |
| Compose DK-07 | Đúng haskell/web; chỉ publish web; service_healthy; restart no; SIGTERM/grace 10 giây | Một trận/lần chạy; start haskell sau GAME_OVER, không restart web; stop/down/restart mất trận |
| C-07 | TBQueue 128/126/2, kiểm tra cả batch, Quit đúng người quá tải | Bảo toàn tính nguyên tử và riêng tư; không đợi client chậm trong STM |
| Web session | Token riêng, grace 300.000 ms khi mất WS; cùng TCP/lõi khi resume hợp lệ | Đổi origin cần mã phiên; restart web/core hoặc tắt host không giữ thời hạn/phiên |

DK-04/05 chỉ đóng gói image; DK-08 thêm test/fixture và minh chứng; DK-09 chỉ hoàn thiện tài liệu/hợp đồng. Không thêm database/lưu trận, nhiều phòng, AI hoặc giao thức công khai mới. C-07/DK-02 là thay đổi API đã nêu ở mục 3, vẫn cần review trước hợp nhất; Docker không tạo bản sao GameState hay serialize bí mật ra health/log.

### Chủ sở hữu phần Docker

Bảng này bổ sung triển khai ngoài Haskell; giữ nguyên block `contract:owners` phục vụ kiểm tra nguồn ở mục 4.

| File/phần | Phụ trách | Review |
|---|---|---|
| docker/haskell.Dockerfile, .dockerignore | A | C |
| docker/web.Dockerfile, frontend/bridge.mjs và frontend test | D | C |
| scripts/Start-LanCompose.ps1, scripts/test/LanCompose.Tests.ps1 | C/D | R |
| compose.yaml, .env.example | C | D/R |
| scripts/test-compose.mjs, docker/test/*.mjs | B/C/D | R |
| README.md, docs/, docker/README.md | R | A/B/C/D |

### Bằng chứng và xác nhận trước hợp nhất

Linux amd64 build thật dùng lts-24.59/GHC 9.10.3: **908 ví dụ Haskell/0 lỗi** với -Werror; frontend **36/36**; suite Compose nền **19/19, 0 skip**. Theo yêu cầu người dùng, nghiệm thu thay thế **một máy/Chrome và Edge riêng** qua IPv4 host đã đến thắng/thua, reload giữ trận, không lộ tàu; log/ảnh tại [dk08_acceptance.md](dk08_acceptance.md). Kết quả này không xác nhận hai thiết bị Wi-Fi, đổi Wi-Fi vật lý hoặc arm64. DK-09 đối chiếu lệnh và test tài liệu được ghi riêng trong hồ sơ bàn giao, không dùng số test cũ làm kết quả lần chạy mới.

| Vai trò | Cần review | Commit/link xác nhận | Trạng thái |
|---|---|---|---|
| R | Hướng dẫn đủ để người khác làm lại, giới hạn/bằng chứng và commit bàn giao | Chưa được cung cấp | CHỜ |
| A | Image Haskell/snapshot/Linux gate, không đổi Fleet/API miền | Chưa được cung cấp | CHỜ |
| B | Riêng tư, luật thật, test đồng thời/client chậm và phạm vi nghiệm thu | Chưa được cung cấp | CHỜ |
| C | Bind/readiness, queue/cleanup, Compose/helper và mở trận mới | Chưa được cung cấp | CHỜ |
| D | Bridge DNS/public port, Origin/Host/resume và thao tác UI | Chưa được cung cấp | CHỜ |

Mỗi thành viên ghi tên/GitHub, SHA **cùng bản bàn giao**, ngày và link bằng chứng; dùng mẫu: `<vai trò> — <tên>: đã review Docker DK-09 tại <SHA>, đồng ý hợp đồng triển khai và phạm vi nghiệm thu <link>`. Tra SHA bằng `git log -1 --format=%H` trên nhánh bàn giao. R chỉ đánh dấu chốt khi có đủ xác nhận; test xanh hoặc commit/push không thay chữ ký.

## 8. Phụ lục NM-01 v1 — worker/locality và cấu hình NUMA để review

Nguồn quyết định chi tiết là [numa_design.md](numa_design.md): ma trận slide,
quyền sở hữu, mọi đường lệnh/kết thúc, API dự kiến và tiêu chí đo trước kết quả.
Phần này là hợp đồng triển khai tương lai; NM-01 chưa sửa runtime Haskell,
bridge hoặc Compose. Block `contract:domain-api`/`contract:owners` tiếp tục
đối chiếu file hiện có để SharedContractSpec kiểm tra đúng source.

### Quyết định chung

- NM-05 thêm worker trận trên capability chọn trước; reader framing và gửi
  request, worker gọi Coordinator, writer gửi FIFO riêng ngoài STM. Một
  GameState và nguyên tử state + toàn bộ batch tiếp tục có hiệu lực.
- Mailbox thường **32 request chờ**, gồm admission, payload, dòng quá dài và
  QUIT wire theo FIFO. Mỗi reader chờ ack xử lý trước request kế; queue đầy
  backpressure có thể hủy, không tự tính thua hoặc bỏ lệnh.
- Control riêng gồm cờ stop và tập tối đa P1/P2 mất TCP; không đợi slot của
  queue 32. Worker chọn stop, disconnect, rồi FIFO; hai disconnect cùng chờ
  chọn P1 trước. Quit qua core, không đổi winner sau Finished.
- C-07 giữ outbox **128/126/2**, preflight cả batch, hủy shot khi thiếu chỗ,
  Quit đúng recipient và marker cuối. Watchdog **2 s**, reader grace **200 ms**,
  deadline test cleanup **10 s**; resume web vẫn **300.000 ms** ở bridge.
- NM-05 dự kiến thêm `GameRuntimeConfig` abstract, parser từ count RTS và
  chỉ số worker, runner `runServerWithRuntime`; chữ ký ở mục 7 numa_design.
  Runner/config/API Coordinator cũ giữ tương thích. Env mới dự kiến
  `BATTLESHIP_GAME_CAPABILITY` do Main đọc, mặc định 0; chưa có trong NM-01.
- NM-06 có thể thêm fleet index private/dữ liệu tính sẵn; constructor Fleet,
  geometry, lịch sử shot, API thuần và riêng tư tiếp tục qua gate hiện có.
- Ba chế độ: mặc định, affinity theo CPU mask, NUMA theo CPU/RAM node được
  kiểm chứng. Capability khác CPU/node ID; quota khác affinity. Local/remote
  cần >= 2 node nhìn thấy; thiếu điều kiện ghi chưa nghiệm thu.

### Đo lường và hiệu lực

NM-03 lấy baseline trước thay đổi; fixture seed cố định/evaluation đầy đủ.
Mỗi biến thể/workload **5 warm-up + 30 mẫu đo**, 3 block. Dao động median block
baseline **<= 10%**; nhiễu hơn ghi chưa đủ kết luận. Báo median/p95, allocation,
GC/RAM và counter phần cứng có tên/giới hạn khi hỗ trợ. Chỉ gọi cải thiện khi
metric chính giảm **>= 5%** và khoảng tin cậy 95% không cắt 0; xấu đi ổn định
**> 10%** cần điều tra/review trước chọn mặc định. Chi tiết ở mục 8 numa_design.

Phụ trách: R tài liệu/gate; A Fleet/layout; B luật/view/benchmark; C worker,
STM/topology/Docker; D framing/bridge/resume/UI. File Haskell mới chỉ thêm vào
fixture ownership khi thực sự có source. Bảng review NM-01 ở mục 10 numa_design,
**A/B/C/D còn chờ**; các phụ thuộc giữ bảng xác nhận lịch sử. Chưa đánh dấu
hợp đồng đã khóa hoặc API dự kiến đã được triển khai.


## 9. Phụ lục NM-03 — benchmark và baseline trước tối ưu

Nguồn triển khai, lệnh tái hiện và kết quả đo là
[performance_baseline.md](performance_baseline.md). Component benchmark và
suite fixture riêng dùng cùng snapshot `lts-24.59`/GHC `9.10.3`, generator
A-06 và lõi thật. Không thêm constructor domain, sửa luật hoặc dependency
QuickCheck của production. `SharedContractSpec` quét thêm `bench` và bảng
ownership ghi `Main.hs`, `Fixtures.hs`, `FixturesSpec.hs` thuộc B.

Workload v1 gồm ba seed theo NM-01, mỗi trận 25 lệnh có lỗi, hai lượt trượt,
17 phát trúng/chìm/thắng và view của P1/P2. Golden transcript và checksum
được chốt trước thay đổi tối ưu. Bốn lớp core/STM/TCP/web có phạm vi đo
riêng; structural digest ép đầy đủ dữ liệu thuần và là một phần workload.

Baseline dùng cùng binary Linux `-O2` cho N1/N2/default; mỗi lớp/profile
5 warm-up và 30 mẫu đo, ba block để kiểm tra nhiễu. Công cụ lưu source hash,
binary hash, topology thực, số capability và metric có phạm vi rõ. Counter
không đo được ghi N/A; một node Docker/WSL không chứng minh NUMA vật lý.
Không dùng kết quả timing làm test chức năng hoặc tự thay mặc định RTS.

Image `docker/benchmark.Dockerfile` phục vụ thí nghiệm, không thêm service
Compose production. Một trận/một GameState, step thuần, batch STM nguyên tử,
queue 128/126/2, framing, privacy và resume 5 phút tiếp tục là gate bắt buộc.
Chờ B/A/C/R review component/fixture và cách dùng baseline trước hợp nhất;
chưa có xác nhận con người để ghi thay nhóm.

## 10. Phụ lục NM-04 — CPU affinity tùy chọn

Nguồn cấu hình và bằng chứng là [affinity_runtime.md](affinity_runtime.md).
Base Compose/default không có cpuset mới; affinity chạy bằng override và
launcher riêng. `.env.performance.example` khai báo HASKELL_CPUSET,
WEB_CPUSET, HASKELL_CAPABILITIES và HASKELL_AFFINITY (container/rts).
Mask auto đọc topology Linux của Docker, không suy từ Node Windows.

RTS command dùng argv list; N dương và <= số CPU mask Haskell. Mode rts dùng
-qa khi mask 0..N-1, N=mask size, rồi kiểm chứng ghc_worker singleton và mọi
task không vượt mask. Main thêm log `Battleship runtime capabilities: N`
sau thông báo listen để đối chiếu N thực; framing TCP/luật/API miền giữ nguyên.

Launcher kiểm tra created cpuset, khởi động Haskell và xác nhận process trước
web. Sai cấu hình dừng/rollback project riêng; profile đổi phải stop và mở
trận mới. Verify đọc process đang chạy, không tạo slot người chơi. CPU mask
không dành độc quyền CPU, không cấu hình RAM NUMA và không tự chứng minh tăng
tốc. Helper LAN `-WatchOnly` giữ cập nhật origin trong cấu hình affinity.

S-01 có regression LF/CRLF: marker của cùng hợp đồng phải đọc được trên
Linux và Windows. Đây là sửa portability của test, không nới kiểm tra API
hoặc ownership. C/D cần review CLI/config/log và evidence trước hợp nhất;
chưa ghi xác nhận thay thành viên.

## 11. Phụ lục NM-05 — Worker và locality, chờ B/C/R review

Hiện trạng ngày 2026-10-12 trên Update_NUMA; xem [hồ sơ NM-05](worker_locality.md).
Luật, Types và TCP v1 giữ nguyên. Chỉ worker submit coordinator trong server;
API STM coordinator cũ vẫn dùng trực tiếp cho test/benchmark. Một GameState,
state + toàn batch sự kiện cùng commit, không IO/socket trong step hoặc STM.

- Mailbox production TBQueue 32; từng reader chờ ack trước frame tiếp theo.
- WELCOME, payload, parser error, oversized input và wire Quit đi FIFO.
- EOF/send failure dùng control Set tối đa P1/P2, không đợi chỗ queue.
- Stop ưu tiên trước disconnect và FIFO; khi cùng pending, P1 trước P2.
- Kết thúc/flush/đánh thức producer cùng STM; worker lỗi dừng phiên, không
  tự tạo kết quả thắng. Writers còn được drain batch cuối khi thắng bình thường.
- Outbox C-07 giữ 128/126/2, rollback batch tràn và Quit đúng recipient.
- Yêu cầu socket SO_SNDBUF 65536 byte, OS có thể điều chỉnh; send watchdog
  2 giây và reader grace 200 ms giữ nguyên. Gate cleanup vẫn 10 giây.
- BATTLESHIP_GAME_CAPABILITY mặc định 0; canonical integer và index < N,
  kiểm tra trước listen. Không phải CPU ID/node ID, không đổi trong trận.
- Runtime API mới: GameRuntimeConfig abstract, defaultGameRuntimeConfig,
  parseGameRuntimeConfig, gameCapability và runServerWithRuntime theo NM-01.
- GameWorker export request/ack, runner, control và diagnostic đọc cho test;
  coordinator/queue constructors không public. Hpack expose module mới,
  ownership của module/test là C. Không đổi Fleet để viết test.

Main nhận cấu hình; worker withAsyncOn khởi tạo/ép state và chạy coordinator.
Capability check cùng cpuset/RTS là bằng chứng execution, không chứng minh
RAM physical locality; cần NM-07. Resume bridge vẫn 300000 ms, Origin/Host
và port mapping không đổi. Số đo NM-03 được giữ nguyên; NM-05 có layer worker
và ghi riêng chi phí strictness/SO_SNDBUF. Chưa ghi xác nhận review thay nhóm.

## 12. Phụ lục NM-06 — Metadata Fleet, chờ A/B/R review

Ngày 2026-10-12 trên Update_NUMA; xem [phân tích NM-06](fleet_index.md).
Private Fleet có geometry Map, occupied Set và UArray Int Word8 100 ô,
được tạo cùng nhau từ geometry đã kiểm tra ở Board.placeFleet. Các field
strict; Eq gồm metadata, Show giữ diagnostic geometry cũ. Không expose
constructor/array/setter, không đổi alias Fleet/Step/PlaceFleetFn/ViewFor.

Board thêm fleetCells và shipAt như mục 3; shipAt kiểm tra ngoài bàn trước
index arithmetic. Codes private 0 nước, 1..5 theo ShipId; không thuộc wire v1.
Rules dùng lookup/occupied để tìm tàu/kiểm tra thắng và vẫn dùng geometry để
kiểm tra chìm. Miss/Hit/Sunk/Win, thứ tự lỗi, lượt và private view giữ nguyên.
Không thêm lịch sử bắn, hit-counter hoặc cache mutable phải đồng bộ.

Library thêm array >=0.5.8 && <0.6, snapshot hiện tại chọn array 0.5.8.0.
Benchmark riêng battleship-fleet-benchmark, 9 test FleetIndexSpec (5 property
ít nhất 1.000 trường hợp/property), các suite luật/riêng tư/concurrency là
gate. Occupied/index là dữ liệu chương trình; kết luận cache CPU/NUMA chỉ có
thể đưa ra khi có counter/placement evidence. Số liệu và chi phí bộ nhớ nằm
trong hồ sơ NM-06; test không thay xác nhận A/B/R trước hợp nhất.
