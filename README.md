# BattleShip Haskell

Dự án Battleship cho hai người chơi, dự kiến chạy bằng hai client terminal kết nối đến một server TCP. Server giữ trạng thái trận đấu; luật chơi được triển khai bằng các hàm thuần Haskell.

**Trạng thái hiện tại:** đã có C-01, A-01, D-01, Board A-02/A-03, Rules B-01/B-02, server C-02, codec/client một lệnh D-02 và Coordinator C-03. Server thực thi PLACE/FIRE/QUIT qua Rules thật: đặt tàu, bắt đầu trận, Miss/Hit/Sunk/Win, chuyển lượt và bỏ cuộc. Một MVar bảo vệ trạng thái và thứ tự phản hồi của hai client. Test TCP kiểm chứng transcript từ kết nối đến phát bắn đầu và các kết quả kết thúc. `viewFor`, client tương tác/render bàn và STM/queue writer chưa triển khai.

**S-01:** bản hợp đồng chung v2 cập nhật A-02 ở [docs/shared_contract.md](docs/shared_contract.md). Chưa khóa mốc vì còn chờ xác nhận A/B/C/D; việc ẩn constructor Fleet, chủ sở hữu file và quy trình thay đổi được ghi tại đó.

## Build và test

Cài Git và Stack (đã kiểm tra với Stack 3.11.1). Cấu hình dùng snapshot LTS 24.59, tương ứng GHC 9.10.3. Stack dùng GHC phù hợp có sẵn trên PATH hoặc cài compiler cần thiết. Lần chạy đầu cần Internet để tải compiler/phụ thuộc.

Từ thư mục gốc của repository, chạy:

```sh
stack build
stack test
```

`stack build` biên dịch thư viện và hai executable. `stack test` chạy Types/Board/Rules, Protocol/Client, hợp đồng S-01, Server C-02, Coordinator C-03, executable và smoke test C-01. Test TCP dùng port do OS cấp, gồm cả stub và Rules production; ProtocolSpec kiểm tra các transcript trong tài liệu. Windows Application Control chặn executable sẽ khiến smoke test thất bại.

Chạy riêng hợp đồng giao thức:

```sh
stack test --test-arguments="--match D-01"
stack test --ghc-options=-Werror --test-arguments="--match D-02"
```

Chạy riêng đối chiếu hợp đồng chung hoặc kiểm tra biên dịch không có warning:

```sh
stack test --test-arguments="--match S-01"
stack test --ghc-options=-Werror
```

Kiểm tra S-01 đọc file trong src/app/test và docs/shared_contract.md từ gốc repository để phát hiện định nghĩa Coord/Command trùng, API lệch tài liệu hoặc file thiếu người phụ trách. Nếu chạy test binary trực tiếp, đặt working directory ở gốc repo.

Chạy riêng A-02:

```sh
stack test --test-arguments="--match A-02"
```

Chạy riêng nghiệm thu đặt tàu A-03:

```sh
stack test --ghc-options=-Werror --test-arguments="--match A-03"
```

BoardSpec gồm test thuần cho đúng năm ID/17 ô, mép A1/J10, tàu dài 3 trùng ID, tàu chạm cạnh và không đặt lại qua Rules.step. Năm test biên dịch chạy GHC có sẵn trong môi trường Stack trên probe tạm: API public hợp lệ phải biên dịch, constructor/record update/coerce/import private phải bị từ chối đúng nguyên nhân. Probe chỉ dùng package đã build, được xóa sau test; không cần dependency mới.

Chạy riêng luật B-01/B-02:

```sh
stack test --ghc-options=-Werror --test-arguments="--match B-01"
stack test --ghc-options=-Werror --test-arguments="--match B-02"
```

`step :: Step` có đủ nhánh Command/Phase. FIRE kiểm tra readiness → lượt → tọa độ → bắn lặp; sai trả Left và không tiêu lượt. FIRE hợp lệ ghi đúng một tọa độ/kết quả vào `playerShots` của người bắn; `shotsReceived opponent state` đọc chính lịch sử đó cho bàn đối thủ, không lưu bản sao thứ hai. Miss đổi lượt; Hit/Sunk giữ lượt; trúng toàn bộ ô tàu trả Win và Finished. Sự kiện là ShotResolved rồi TurnReady hoặc GameEnded, không có TURN sau WIN. C-03 kiểm chứng Coordinator giữ state cũ khi Left qua unit test và TCP thật.

Thử hàm thuần bằng `stack ghci battleship-haskell:lib`:

```haskell
import Battleship.Types
import Battleship.Board
let placements = [ShipPlacement ship (Coord 1 row) Horizontal | (ship, row) <- zip [Carrier, Battleship, Cruiser, Submarine, Destroyer] [1..5]]
placeFleet placements -- Right fleet hợp lệ, đủ 17 ô
placeFleet (take 4 placements) -- Left (InvalidFleetSize 4)
shipCells (ShipPlacement Carrier (Coord 9 10) Horizontal) -- Left (ShipOutOfBounds Carrier (Coord 11 10))
```

`Fleet(..)` và record update `fleet { fleetShips = ... }` không còn là API công khai. Tạo fixture/game fleet bằng `placeFleet`; đọc các ô qua `fleetShips fleet`. Module `Battleship.Internal.Fleet` chỉ dành cho Board/Types và không được expose cho executable/client.

Mô phỏng một ván thuần trong GHCi, từ đặt tàu đến P1 thắng (không cần server):

```haskell
import Battleship.Rules
import Battleship.Types
import Battleship.Board
import Control.Monad (foldM)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
let p1 = [ShipPlacement ship (Coord 1 row) Horizontal | (ship, row) <- zip [Carrier, Battleship, Cruiser, Submarine, Destroyer] [1..5]]
let p2 = [placement { placementStart = Coord 1 (coordRow (placementStart placement) + 5) } | placement <- p1]
let play (state, batches) (player, command) = do { (next, events) <- step player command state; pure (next, batches ++ [events]) }
let game = do { fleet <- placeFleet p2; foldM play (initialGameState, []) ([(P1, PlaceFleet p1), (P2, PlaceFleet p2)] ++ [(P1, Fire cell) | cell <- Set.toList (Set.unions (Map.elems (fleetShips fleet)))]) }
fmap (gamePhase . fst) game -- Right (Finished P1 AllShipsSunk)
fmap (Map.size . shotsReceived P2 . fst) game -- Right 17
fmap (take 1 . reverse . snd) game -- batch cuối gồm ShotResolved ... Win, GameEnded P1 AllShipsSunk
```

## Chạy và kiểm tra server C-02/C-03

Khởi chạy server trong terminal thứ nhất (mặc định port 4000):

```sh
stack exec battleship-server
stack exec battleship-server -- 4001
stack exec battleship-server -- --help
```

Chọn một lệnh khởi chạy. Server in `Battleship server listening on 127.0.0.1:4000` rồi tiếp tục lắng nghe. Port `0` cho phép OS chọn port trống; dòng startup ghi port thực tế. Port sai hoặc bind thất bại được báo ở stderr và thoát với exit code khác 0.

Mở hai terminal PowerShell khác và chạy đoạn sau ở mỗi terminal (sửa port nếu cần):

```powershell
$tcpDemo = [System.Net.Sockets.TcpClient]::new()
try {
    $tcpDemo.Connect('127.0.0.1', 4000)
    $tcpReader = [System.IO.StreamReader]::new($tcpDemo.GetStream())
    while ($null -ne ($tcpLine = $tcpReader.ReadLine())) { $tcpLine }
} finally {
    $tcpDemo.Dispose()
}
```

Terminal kết nối trước nhận `WELCOME 1 P1`, terminal sau nhận `WELCOME 1 P2`; cả hai giữ kết nối dù chưa gửi lệnh. Chạy lại đoạn đó trong terminal thứ ba: chỉ nhận `ERROR SERVER_FULL` rồi EOF. Đóng một terminal client để ngắt kết nối; người còn lại nhận `GAME_OVER <người còn lại> OPPONENT_LEFT`, server đóng session và dừng. Muốn thử trận mới, khởi chạy server lại. Nhấn Ctrl+C ở terminal server để dừng và cleanup.

C-03 nhận PLACE/FIRE/QUIT theo [giao thức v1](docs/protocol.md), parser từ chối cú pháp/tọa độ sai; Board/Rules quyết định lỗi nghiệp vụ và kết quả. FIRE trước khi đủ hai fleet trả `ERROR FLEETS_NOT_READY`. Dòng quá dài nhận `ERROR LINE_TOO_LONG` rồi kết thúc session theo D-01. Không tái sử dụng slot hay nhận người thay thế. Đoạn PowerShell trên chỉ giữ kết nối/đọc để thử slot; nghiệm thu đặt tàu/bắn dùng test TCP bên dưới.

Chạy các kiểm thử tự động tương ứng:

```sh
stack test --ghc-options=-Werror --test-arguments="--match C-02"
stack test --ghc-options=-Werror --test-arguments="--match C-03"
```

## Chạy client D-02

Trong terminal khác khi server đang chạy, chọn một lệnh:

```sh
stack exec battleship-client -- 4000 "QUIT"
stack exec battleship-client -- 4000 "FIRE A1"
stack exec battleship-client -- 4000 "PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H"
stack exec battleship-client -- --help
```

Có thể bỏ PORT để dùng 4000, ví dụ `stack exec battleship-client -- "QUIT"`. Client nhận WELCOME, gửi đúng một lệnh rồi đọc phản hồi và hiển thị tiếng Việt bằng UTF-8. QUIT nhận GAME_OVER; PLACE hợp lệ nhận OK, FIRE trước khi đủ hai fleet báo chưa sẵn sàng. Lệnh thiếu tham số/tọa độ sai bị từ chối ngay ở client. Client đóng kết nối sau phản hồi khiến session kết thúc; khởi chạy lại server trước khi thử lệnh tiếp theo. Client chưa có vòng nhập nhiều lệnh/render bàn nên chưa dùng để chơi trọn ván tương tác; CoordinatorSpec giữ hai kết nối để nghiệm thu TCP.

`package.yaml` là nguồn cấu hình package; file `.cabal` được Stack/Hpack sinh tự động. Giữ `stack.yaml.lock` trong Git để chia sẻ cùng snapshot.

`Types` dùng `containers` cho `Map`/`Set`; C-02/D-02 dùng `network` cho TCP, `bytestring` cho framing/codec theo byte, `async` cho vòng đời worker và deadline. Hai Main dùng PortNumber từ `network`; ClientMain dùng `bytestring` để đưa lệnh CLI vào parser. Test suite dùng Hspec, `network`/`async` để kiểm tra TCP thật, `process` để khởi chạy executable và `directory`/`filepath` để đối chiếu cây nguồn S-01 trên Windows/Linux. `docs/protocol.md` là data file để test đọc đúng tài liệu qua module Cabal tự sinh `Paths_battleship_haskell`. `stm` sẽ được thêm khi Coordinator thực sự sử dụng; chưa cần thêm QuickCheck hoặc text.

Thành viên A/B/D lấy nhánh nền đã chứa C-01 bằng `git fetch origin` và checkout/pull nhánh được nhóm thống nhất, rồi chạy hai lệnh trên trước khi thêm mã của mình.

## Luật chính

- Bàn 10×10, tọa độ A1–J10; mỗi người đặt năm tàu dài 5, 4, 3, 3, 2.
- Player 1 bắn trước sau khi cả hai đã đặt tàu hợp lệ.
- **Bắn trúng được bắn tiếp**, kể cả khi làm chìm tàu. **Bắn hụt mới chuyển lượt**.
- Lệnh sai hoặc bắn lặp không làm đổi trạng thái và không mất lượt.
- Người bắn trúng toàn bộ 17 ô tàu của đối phương thắng ngay.

Luật đầy đủ ở [docs/game_spec.md](docs/game_spec.md). Sơ đồ hoạt động ở [docs/architecture.md](docs/architecture.md); giao thức v1 đã chốt ở [docs/protocol.md](docs/protocol.md).

## Phân công thư mục

| Thành viên | File phụ trách |
|---|---|
| A | `Types.hs`, `Board.hs`, `BoardSpec.hs` |
| B | `Rules.hs`, `View.hs`, test luật và góc nhìn |
| C | `Coordinator.hs`, `Server.hs`, `ServerMain.hs`, test đồng thời |
| D | `Protocol.hs`, `Client.hs`, `ClientMain.hs`, test giao thức và tích hợp |
| R | `docs/`, báo cáo, minh chứng kiểm thử và demo |

Trước khi tích hợp nghiệp vụ tiếp theo, cả nhóm review và ghi xác nhận S-01 v2 tại [docs/shared_contract.md](docs/shared_contract.md), gồm các cập nhật đến C-03. Phân công chi tiết gồm cả Main, test và YAML nằm ở đó. Board/Types, Rules, Coordinator/server và codec/client một lệnh đã có cài đặt; STM/queue writer và góc nhìn tiếp tục theo task tương ứng.
