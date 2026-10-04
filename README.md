# BattleShip Haskell

Dự án Battleship cho hai người chơi, dự kiến chạy bằng hai client terminal kết nối đến một server TCP. Server giữ trạng thái trận đấu; luật chơi được triển khai bằng các hàm thuần Haskell.

**Trạng thái hiện tại:** đã có khung C-01, kiểu A-01, giao thức D-01 và Board A-02 (`inBounds`, `shipCells`, `placeFleet`). Fleet được tạo qua hàm kiểm tra và chỉ có API đọc; chưa triển khai lượt bắn/Rules, parser/encoder production, TCP hay `viewFor`.

**S-01:** bản hợp đồng chung v2 cập nhật A-02 ở [docs/shared_contract.md](docs/shared_contract.md). Chưa khóa mốc vì còn chờ xác nhận A/B/C/D; việc ẩn constructor Fleet, chủ sở hữu file và quy trình thay đổi được ghi tại đó.

## Build và test

Cài Git và Stack (đã kiểm tra với Stack 3.11.1). Cấu hình dùng snapshot LTS 24.59, tương ứng GHC 9.10.3. Stack dùng GHC phù hợp có sẵn trên PATH hoặc cài compiler cần thiết. Lần chạy đầu cần Internet để tải compiler/phụ thuộc.

Từ thư mục gốc của repository, chạy:

```sh
stack build
stack test
```

`stack build` biên dịch thư viện và hai executable. `stack test` chạy A-01 (`TypesSpec`), A-02 (`BoardSpec`), D-01 (`ProtocolSpec`), S-01 (`SharedContractSpec`) và hai smoke test C-01; tất cả phải đạt, không có failure. Smoke test kiểm tra server/client khởi chạy, in thông báo khung và thoát thành công. Windows Application Control chặn executable sẽ khiến smoke test thất bại.

Chạy riêng hợp đồng giao thức:

```sh
stack test --test-arguments="--match D-01"
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

Có thể kiểm tra hai điểm vào:

```sh
stack exec battleship-server
stack exec battleship-client
```

Hai chương trình hiện chỉ in thông báo khung đã sẵn sàng. `package.yaml` là nguồn cấu hình package; file `.cabal` được Stack/Hpack sinh tự động. Giữ `stack.yaml.lock` trong Git để chia sẻ cùng snapshot.

`Types` dùng `containers` cho `Map`/`Set`; test suite dùng Hspec, `process` để khởi chạy executable, `bytestring` để kiểm tra framing byte và `directory`/`filepath` để đối chiếu cây nguồn S-01 trên Windows/Linux. `docs/protocol.md` là data file để test đọc đúng tài liệu qua module Cabal tự sinh `Paths_battleship_haskell`. Thêm `text`, `stm`, `async`, `network` và QuickCheck ở task thực sự sử dụng chúng, vào đúng component cần thiết.

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

Trước khi tích hợp nghiệp vụ tiếp theo, cả nhóm review và ghi xác nhận S-01 v2 tại [docs/shared_contract.md](docs/shared_contract.md), gồm A-01/C-01/D-01 và cập nhật A-02. Phân công chi tiết gồm cả Main, test và YAML nằm ở đó. Board/Types đã có cài đặt; các module nghiệp vụ còn lại tiếp tục do từng thành viên triển khai.
