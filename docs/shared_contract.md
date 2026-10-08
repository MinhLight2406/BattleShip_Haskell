# Hợp đồng chung S-01 v2 — cập nhật đến C-07, chờ duyệt

Ngày đối chiếu kỹ thuật: 2026-10-08. Chủ trì tài liệu: R.

**Trạng thái: đã lập bản hợp đồng để duyệt; CHƯA KHÓA vì chưa có xác nhận A/B/C/D.** Build/test xanh chỉ là bằng chứng kỹ thuật, không thay thế xác nhận của người phụ trách.

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

`Map` và `Set` ở đây là kiểu từ `containers`, lần lượt `Data.Map.Strict` và `Data.Set`. `Internal` là module private `Battleship.Internal.Fleet` trong `other-modules` của library, không được expose. Nó giữ newtype tổng quát `Fleet ship coord` có Eq/Show để tránh vòng import Types ↔ Board. Types chỉ xuất type Fleet và hàm đọc `fleetShips :: Fleet -> Map ShipId (Set Coord)`; không xuất constructor hoặc trường record có thể cập nhật. Board là module production duy nhất tạo Fleet qua constructor private, sau khi kiểm tra toàn bộ request. Code luật/client chỉ import API public; không import Internal. Fixture test cũng dùng placeFleet.

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
src/Battleship/Server.hs C
src/Battleship/Protocol.hs D
src/Battleship/Client.hs D
app/ServerMain.hs C
app/ClientMain.hs D
test/TypesSpec.hs A
test/BoardSpec.hs A
test/TestSupport/Generators.hs A
test/RulesSpec.hs B
test/ViewSpec.hs B
test/CoordinatorSpec.hs C
test/ServerSpec.hs C
test/ClientSpec.hs D
test/IntegrationSpec.hs C
test/ProtocolSpec.hs D
test/SharedContractSpec.hs R
test/Spec.hs R
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
