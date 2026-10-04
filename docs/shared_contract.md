# Hợp đồng chung S-01 v1

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

S-01 duyệt hợp đồng trước khi viết nghiệp vụ. Board/Rules/View/Protocol/Coordinator/Server/Client hiện còn khung; chưa có `placeFleet`, `step`, `viewFor` thực thi, parser/encoder production hoặc trận TCP thật. Không tạo hàm giả dùng `undefined`/`error` để làm như đã có cài đặt.

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

newtype Fleet = Fleet
  { fleetShips :: Map ShipId (Set Coord)
  } deriving (Eq, Show)

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

`Map` và `Set` ở đây là kiểu từ `containers`, lần lượt `Data.Map.Strict` và `Data.Set`. Constructor Fleet mở cho fixture/module nội bộ; A-02 phải kiểm tra bất biến trước khi coi Fleet là hợp lệ.

Các hàm cần triển khai theo alias đã công bố:

```haskell
-- A: Battleship.Board
placeFleet :: FleetPlacement -> Either GameError Fleet
-- B: Battleship.Rules
step :: PlayerId -> Command -> GameState
     -> Either GameError (GameState, [Event])
-- B: Battleship.View
viewFor :: PlayerId -> GameState -> PlayerView
```

Helper hiện có: `boardSize :: Int`, `shipLength :: ShipId -> Int`, `otherPlayer :: PlayerId -> PlayerId`, `initialGameState :: GameState`, `playerStateFor :: PlayerId -> GameState -> PlayerState`, `setPlayerState :: PlayerId -> PlayerState -> GameState -> GameState`.

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

Hai file đều tên module Main vì nằm trong hai component Cabal khác nhau; `other-modules: []` tránh Hpack đưa Main còn lại vào nhầm executable. Cả hai phụ thuộc cùng library `battleship-haskell`, trong đó Types chỉ được biên dịch như một module chung. Main hiện in thông báo khung và thoát; smoke test kiểm tra đúng hành vi đó. Khi triển khai tiếp, Main gọi lớp IO Server/Client; luật thuần thuộc Board/Rules/View, không viết vào Main. Chữ ký IO cho Server/Client được chốt ở task triển khai tương ứng, S-01 không đặt trước tham số cấu hình chưa có.

## 4. Chủ sở hữu file

Danh sách dưới bao phủ toàn bộ file Haskell hiện tại và hai cấu hình. Tên A/B/C/D/R là vai trò, chưa thay bằng tên người khi chưa có thông tin. C và D cùng review IntegrationSpec; C phụ trách ghi file để tránh hai nhánh sửa cùng chỗ. R phụ trách Spec tổng, kiểm tra hợp đồng chung và tài liệu.

<!-- contract:owners -->
```text
src/Battleship/Types.hs A
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
- ProtocolSpec: kiểu A-01 trong grammar tham chiếu và transcript D-01, framing byte, lỗi, định tuyến.
- SharedContractSpec: API nguồn khớp bản chụp, chỉ Types định nghĩa Coord/Command, danh sách chủ sở hữu đủ/không trùng, hai điểm vào Main có main :: IO (). Test đọc src/app/test trong repository; chạy test binary riêng cần đặt working directory ở gốc repo.
- IntegrationSpec: hai executable được build từ package khởi chạy và thoát thành công. Đây là smoke test khung, không phải tích hợp TCP thật.

Căn cứ các slide đã cung cấp: ADT/pattern matching để chia Command/Event/GameError; lập trình module để dùng chung kiểu và phân công; Hspec describe/it/shouldBe để kiểm tra; Networking để tách TCP stream thành dòng. STM, thread, supervision và coordination nằm ở hợp đồng kiến trúc C, được cài đặt/kiểm chứng ở task sau. Xem [architecture.md](architecture.md) và [test_evidence.md](test_evidence.md).

## 6. Xác nhận và hiệu lực khóa

Mỗi người code cần đọc Types, protocol (đặc biệt transcript 7.1), hai Main, bảng chủ sở hữu và kết quả build/test **trên cùng commit S-01 được review**. R ghi tên/GitHub, ngày, SHA commit đã duyệt và link comment/PR hoặc lời xác nhận được cung cấp trực tiếp. Không dùng kết quả test hoặc tên tác giả commit làm chữ ký thay người.

| Vai trò | Người/GitHub | Commit đã duyệt | Ngày | Bằng chứng | Trạng thái |
|---|---|---|---|---|---|
| A | — | — | — | — | CHỜ XÁC NHẬN |
| B | — | — | — | — | CHỜ XÁC NHẬN |
| C | — | — | — | — | CHỜ XÁC NHẬN |
| D | — | — | — | — | CHỜ XÁC NHẬN |

Mẫu để mỗi thành viên ghi: `A — <tên/GitHub>: xác nhận S-01 v1 tại <SHA>; đã duyệt Types, giao thức/transcript, Main, chủ sở hữu và build/test.` B/C/D dùng mẫu tương ứng. Nếu có chỉnh sửa nội dung sau khi một người duyệt, người đó cần duyệt lại revision mới; commit chỉ bổ sung các bằng chứng xác nhận không thay đổi nội dung kỹ thuật thì không cần lặp chữ ký.

R chỉ chuyển trạng thái sang **ĐÃ KHÓA** khi đủ bốn xác nhận cho cùng nội dung và build/test xanh. Sau mốc khóa, mọi thay đổi cần A/B/C/D đồng ý trước khi hợp nhất. R ghi thay đổi, ảnh hưởng, bằng chứng test và bốn xác nhận; đổi hợp đồng thì tăng revision S-01, đổi wire không tương thích thì tăng phiên bản giao thức. Không tự sửa Types/transcript rồi coi test xanh là đã được nhóm đồng ý.

Checklist nghiệm thu hiện tại: nội dung kỹ thuật được đối chiếu và có kiểm tra chạy được; xác nhận của bốn người còn thiếu, nên **S-01 chưa đạt toàn bộ tiêu chí xong**.
