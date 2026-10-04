# BattleShip Haskell

Dự án Battleship cho hai người chơi, dự kiến chạy bằng hai client terminal kết nối đến một server TCP. Server giữ trạng thái trận đấu; luật chơi được triển khai bằng các hàm thuần Haskell.

**Trạng thái hiện tại:** đã có khung C-01 và kiểu/hợp đồng hàm A-01 trong `Types`. Test suite gồm unit test kiểu/helper và hai smoke test server/client; chưa triển khai luật chơi, TCP hay `viewFor`.

## Build và test

Cài Git và Stack (đã kiểm tra với Stack 3.11.1). Cấu hình dùng snapshot LTS 24.59, tương ứng GHC 9.10.3. Stack dùng GHC phù hợp có sẵn trên PATH hoặc cài compiler cần thiết. Lần chạy đầu cần Internet để tải compiler/phụ thuộc.

Từ thư mục gốc của repository, chạy:

```sh
stack build
stack test
```

`stack build` biên dịch thư viện và hai executable. `stack test` chạy unit test A-01 (`TypesSpec`) và hai smoke test C-01; tất cả phải đạt, không có failure. Smoke test kiểm tra server/client khởi chạy, in thông báo khung và thoát thành công. Windows Application Control chặn executable sẽ khiến smoke test thất bại.

Có thể kiểm tra hai điểm vào:

```sh
stack exec battleship-server
stack exec battleship-client
```

Hai chương trình hiện chỉ in thông báo khung đã sẵn sàng. `package.yaml` là nguồn cấu hình package; file `.cabal` được Stack/Hpack sinh tự động. Giữ `stack.yaml.lock` trong Git để chia sẻ cùng snapshot.

`Types` dùng `containers` cho `Map`/`Set`; test suite dùng Hspec và `process` để khởi chạy executable. Thêm `text`, `bytestring`, `stm`, `async`, `network` và QuickCheck ở task thực sự sử dụng chúng, vào đúng component cần thiết.

Thành viên A/B/D lấy nhánh nền đã chứa C-01 bằng `git fetch origin` và checkout/pull nhánh được nhóm thống nhất, rồi chạy hai lệnh trên trước khi thêm mã của mình.

## Luật chính

- Bàn 10×10, tọa độ A1–J10; mỗi người đặt năm tàu dài 5, 4, 3, 3, 2.
- Player 1 bắn trước sau khi cả hai đã đặt tàu hợp lệ.
- **Bắn trúng được bắn tiếp**, kể cả khi làm chìm tàu. **Bắn hụt mới chuyển lượt**.
- Lệnh sai hoặc bắn lặp không làm đổi trạng thái và không mất lượt.
- Người bắn trúng toàn bộ 17 ô tàu của đối phương thắng ngay.

Luật đầy đủ ở [docs/game_spec.md](docs/game_spec.md). Sơ đồ hoạt động ở [docs/architecture.md](docs/architecture.md); thông điệp giao tiếp dự kiến ở [docs/protocol.md](docs/protocol.md).

## Phân công thư mục

| Thành viên | File phụ trách |
|---|---|
| A | `Types.hs`, `Board.hs`, `BoardSpec.hs` |
| B | `Rules.hs`, `View.hs`, test luật và góc nhìn |
| C | `Coordinator.hs`, `Server.hs`, `ServerMain.hs`, test đồng thời |
| D | `Protocol.hs`, `Client.hs`, `ClientMain.hs`, test giao thức và tích hợp |
| R | `docs/`, báo cáo, minh chứng kiểm thử và demo |

Trước khi viết mã nghiệp vụ, cả nhóm review hợp đồng A-01 tại [docs/architecture.md](docs/architecture.md), rồi chốt giao thức tại S-01. Các module ngoài `Types` còn là khung để từng thành viên triển khai.
