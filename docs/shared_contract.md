# Hợp đồng chung S-01 v2 — cập nhật A-02, chờ duyệt

Ngày đối chiếu kỹ thuật: 2026-10-04. Chủ trì tài liệu: R.

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

A-02/A-03 có Board thuần/fleet đúng MVP; B-01/B-02 có Rules.step cho mọi Command/Phase và kết quả bắn. C-02/C-03 nối hai slot TCP vào lõi thật qua Coordinator/MVar. D-02 có codec/client một lệnh; D-03 thêm nhập/sửa/xem trước fleet của mình, GUI gửi PLACE và giữ kết nối. Server/Client dùng framer chung. Chưa có nhập FIRE/render diễn biến trận, viewFor hoặc STM/queue writer. Nhánh `Luong_nhap_gui_dat_tau` giữ nguyên kiểu/chữ ký miền và wire v1. S-01 vẫn chờ bốn xác nhận.

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

PLACE thành công phát `[FleetAccepted actor]`; lần đặt bắt đầu trận phát `[FleetAccepted actor, GameStarted P1, TurnReady P1]`. QUIT phát duy nhất `[GameEnded winner OpponentLeft]`, giữ nguyên hai fleet/lịch sử. Lỗi trả Left, không có state mới/Event thành công; Coordinator giữ toàn bộ state cũ. RulesSpec và CoordinatorSpec kiểm tra hợp đồng này, gồm TCP thật; STM chưa triển khai.

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

### Phạm vi transport C-02/C-03

`Battleship.Server.runServer :: PortNumber -> (PortNumber -> IO ()) -> IO ()` bind `127.0.0.1`; callback nhận port thực tế sau listen, port 0 dành cho thử nghiệm không tranh port cố định. `PortNumber` thuộc `network`, không tạo kiểu miền trùng với Types. Hai kết nối nhận WELCOME theo thứ tự accept; kết nối thứ ba nhận ERROR SERVER_FULL rồi bị đóng, không tạo worker hay thay đổi hai slot.

Server tách dòng TCP với LF/CRLF và giới hạn 256 byte, gọi Coordinator.coordinate → Protocol.parseCommand → Step → Protocol.encodeEvent. Payload sai không tới Step; Left GameError giữ state cũ và trả lỗi actor-only. EOF/lỗi socket gọi applyCommand core actor Quit; sau Finished không gọi lại hoặc đổi winner. LINE_TOO_LONG gửi lỗi rồi xử lý rời trận qua core. Không thêm mã wire hoặc đổi luật R-01.

MVar bảo vệ registry, GameState, cờ kết thúc và thứ tự gửi batch. Bracket/withAsync quản lý listener/socket/reader; send có timeout/watchdog 2 giây. Encode toàn bộ batch trước commit; lỗi encode nội bộ dừng session và được báo qua kênh kết thúc có Either SomeException (), tránh finalizer Quit che lỗi. Chưa có TVar/queue writer: peer chậm có thể trì hoãn người kia đến deadline.

Coordinator API thuần: `coordinate :: Step -> PlayerId -> ByteString -> GameState -> Either ProtocolError (GameState, [(PlayerId, ByteString)])`; `applyCommand` cùng kết quả nhưng nhận Command thay payload, dùng cho EOF. `runServerWith :: Step -> GameState -> PortNumber -> (PortNumber -> IO ()) -> IO ()` là chỗ thay stub bằng lõi ở Đợt 6. Production `runServer` đã dùng Rules.step/initialGameState vì A/B hoàn thiện; test dùng stub/fixture qua API này. Danh tính lấy từ socket, không từ lệnh. Không viết lại luật thắng thua trong C.

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
- SharedContractSpec: API nguồn khớp bản chụp, chỉ Types định nghĩa Coord/Command, Fleet abstract và chỉ Board/Types truy cập representation private, danh sách chủ sở hữu đủ/không trùng, hai điểm vào Main có main :: IO (). Test đọc src/app/test trong repository; chạy test binary riêng cần đặt working directory ở gốc repo.
- ServerSpec C-02: TCP thật qua server library; slot/third client, QUIT/EOF, race kết nối/bỏ cuộc, framing byte và cleanup khi cancel/lỗi startup, dừng rồi bind lại cùng port.
- CoordinatorSpec C-03: unit test ranh giới parse/step/state/encode và TCP thật với stub/lõi thật; transcript, rollback, concurrent PLACE/FIRE, lỗi nội bộ, Sunk/Win và EOF giữ winner.
- ClientSpec D-02: client library với C-02/peer có kịch bản; handshake, một lệnh, phân mảnh, lỗi/EOF, cleanup, hiển thị tiếng Việt.
- ClientSpec D-03: parser địa phương, golden preview, handle nhập/sửa/hủy/EOF; một PLACE, giữ kết nối sau OK/quá 10 giây, cancel, lỗi wire và server thật. IntegrationSpec D-03 kiểm tra CLI mặc định/port và stdin sửa/preview/GUI đến START/INCOMING/GAME_OVER.
- IntegrationSpec: hai smoke test --help, CLI sai/bind lỗi, server executable thật với hai client và người thứ ba; client executable gửi QUIT/FIRE vào C-02, xác nhận tiếng Việt UTF-8 và exit code.

Căn cứ slide: ADT/pattern matching/Either cho kiểu và lỗi; hàm thuần và module để tách Coordinator khỏi socket; Hspec describe/it/shouldBe (Chap8); Network.Socket/bracket và TCP stream (Chap11); MVar giữ state/thứ tự cập nhật (Chap5), async/timeout quản lý worker/deadline (Chap7). C-03 đã điều phối nghiệp vụ; STM/queue writer thuộc task tiếp theo. Xem [architecture.md](architecture.md) và [test_evidence.md](test_evidence.md).

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
