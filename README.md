# BattleShip Haskell

Dự án Battleship cho hai người chơi, dự kiến chạy bằng hai client terminal kết nối đến một server TCP. Server giữ trạng thái trận đấu; luật chơi được triển khai bằng các hàm thuần Haskell.

**Trạng thái hiện tại:** đã có khung C-01, kiểu A-01, giao thức D-01, Board A-02, khung Rules B-01 (`step`), server TCP C-02 và parser/encoder cùng client gửi một lệnh D-02. Step xử lý đặt tàu/bắt đầu trận/bỏ cuộc, kiểm tra lỗi trước khi bắn; tính kết quả Miss/Hit/Sunk/Win còn chờ task luật tiếp theo. Server dùng framer chung nhưng vẫn trả phản hồi mẫu cho PLACE/FIRE; chưa nối Coordinator/Rules để chơi trận thật hoặc có `viewFor`.

**S-01:** bản hợp đồng chung v2 cập nhật A-02 ở [docs/shared_contract.md](docs/shared_contract.md). Chưa khóa mốc vì còn chờ xác nhận A/B/C/D; việc ẩn constructor Fleet, chủ sở hữu file và quy trình thay đổi được ghi tại đó.

## Build và test

Cài Git và Stack (đã kiểm tra với Stack 3.11.1). Cấu hình dùng snapshot LTS 24.59, tương ứng GHC 9.10.3. Stack dùng GHC phù hợp có sẵn trên PATH hoặc cài compiler cần thiết. Lần chạy đầu cần Internet để tải compiler/phụ thuộc.

Từ thư mục gốc của repository, chạy:

```sh
stack build
stack test
```

`stack build` biên dịch thư viện và hai executable. `stack test` chạy A-01 (`TypesSpec`), A-02 (`BoardSpec`), B-01 (`RulesSpec`), D-01/D-02 (`ProtocolSpec`/`ClientSpec`), S-01 (`SharedContractSpec`), C-02/D-02 (`IntegrationSpec`) và hai smoke test C-01; tất cả phải đạt, không có failure. Smoke test dùng `--help` của cả hai executable. Test TCP dùng port do OS cấp và kiểm tra cả library lẫn executable; ProtocolSpec gọi parser/encoder production với các transcript trong tài liệu. Windows Application Control chặn executable sẽ khiến smoke test thất bại.

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

Chạy riêng khung luật B-01:

```sh
stack test --ghc-options=-Werror --test-arguments="--match B-01"
```

`step :: Step` có đủ nhánh Command/Phase. FIRE sai bị từ chối theo điều kiện; FIRE đã qua kiểm tra hiện trả `Left (InvalidCommand "B-01: shot resolution is not implemented")`, giữ nguyên state và không phát ShotResolved. Đây là điểm thay thế bằng logic bắn ở task tiếp theo, chưa phải game chơi được. Coordinator phải giữ state cũ khi Left; adapter trong RulesSpec kiểm tra hợp đồng này, chưa kiểm chứng Coordinator/STM thực tế.

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

## Chạy và kiểm tra server C-02

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

C-02 chỉ nhận chính xác `QUIT` với LF/CRLF. Mọi dòng còn lại trong giới hạn, gồm PLACE/FIRE, trả mẫu `ERROR INVALID_COMMAND`; chưa parse tọa độ, xác nhận đội tàu hay tạo SHOT. Dòng quá dài nhận `ERROR LINE_TOO_LONG` rồi kết thúc session theo D-01. Không tái sử dụng slot hay nhận người thay thế.

Chạy các kiểm thử tự động tương ứng:

```sh
stack test --ghc-options=-Werror --test-arguments="--match C-02"
```

## Chạy client D-02

Trong terminal khác khi server đang chạy, chọn một lệnh:

```sh
stack exec battleship-client -- 4000 "QUIT"
stack exec battleship-client -- 4000 "FIRE A1"
stack exec battleship-client -- 4000 "PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H"
stack exec battleship-client -- --help
```

Có thể bỏ PORT để dùng 4000, ví dụ `stack exec battleship-client -- "QUIT"`. Client nhận WELCOME, gửi đúng một lệnh rồi đọc phản hồi và hiển thị tiếng Việt bằng UTF-8. QUIT nhận GAME_OVER; PLACE/FIRE hợp lệ hiện nhận lỗi mẫu của C-02. Lệnh thiếu tham số hoặc tọa độ sai bị từ chối ngay ở client. Mỗi lần chạy client đóng kết nối sau phản hồi, khiến session C-02 kết thúc; khởi chạy lại server trước khi thử lệnh tiếp theo. Client chưa có vòng nhập nhiều lệnh hoặc render bàn; muốn giữ hai slot để thử P2/SERVER_FULL, dùng hai terminal PowerShell như mục trên.

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

Trước khi tích hợp nghiệp vụ tiếp theo, cả nhóm review và ghi xác nhận S-01 v2 tại [docs/shared_contract.md](docs/shared_contract.md), gồm A-01/C-01/D-01 và cập nhật A-02/B-01/C-02/D-02. Phân công chi tiết gồm cả Main, test và YAML nằm ở đó. Board/Types, khung step, transport hai client và codec/client một lệnh đã có cài đặt; logic kết quả bắn và các module nghiệp vụ còn lại tiếp tục do từng thành viên triển khai.
