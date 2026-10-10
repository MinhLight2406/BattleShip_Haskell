# Báo cáo nghiệm thu lõi luật thuần — S-02

Ngày chạy thực tế: **2026-10-05**, Windows/PowerShell. Chủ trì hồ sơ: R.

**Kết luận kỹ thuật: đạt. Xác nhận nhóm: CHỜ A/B.** Đây là hồ sơ S-02, chưa phải báo cáo nghiệm thu toàn bộ dự án.

Bản được kiểm tra là working tree trên nhánh `Luong_nhap_gui_dat_tau`, dựa trên commit `4eea8b544a4da77995d451a137dd98b8f0a574c3`. Thay đổi S-02 chưa được commit; SHA nền không phải SHA chứa các sửa đổi này. Snapshot `lts-24.59`, GHC **9.10.3**, Haskell2010.

## 1. Vấn đề trước nghiệm thu và cách sửa

| Trước S-02 | Ảnh hưởng | Đã sửa |
|---|---|---|
| RulesSpec tự gán Turn/Finished, lịch sử Hit/Miss và trạng thái còn một ô để thắng | Test có thể xanh dù không có chuỗi lệnh hợp lệ nào tạo được fixture; bỏ qua lỗi chuyển lượt/đặt tàu/tích lũy lịch sử | `waitingFor`, `readyState`, `withHistories`, `turnFor`, `finishedState` dựng trạng thái bằng production `step`; kiểm tra thắng với mọi ô cuối, tàu dọc và 16 phát trượt cũng dùng lệnh thật |
| Hai test đưa kết quả Win vào lịch sử nhưng giữ phase Turn | Trái bất biến: Win phải kết thúc trận; kỳ vọng AlreadyFired sau Win không mô tả ván hợp lệ | Bỏ hai trường hợp Win giả. Bắn lặp Miss/Hit/Sunk được tạo bằng phát bắn thật; sau Win được kiểm tra trả GameAlreadyFinished ở các test kết thúc |
| BoardSpec tự tạo GameState có hai fleet, rồi gán lượt/kết thúc | Không chứng minh fleet đã được xác nhận và khóa qua Rules | Gọi hai PlaceFleet thật; chuyển sang P2 bằng một phát trượt; kết thúc bằng Quit hoặc bắn đủ 17 ô thật |
| TypesSpec dựng baseline PlayerState với lịch sử tự điền | Trạng thái ví dụ chưa chứng minh có thể đạt được bằng luật | Baseline đi qua hai PlaceFleet và ba Fire thật; các test record/helper vẫn kiểm tra cập nhật record riêng |
| Chưa có hồ sơ nghiệm thu riêng kết nối chờ, lỗi, bắn và thắng thành một chuỗi | Khó đối chiếu bước nào chuyển phase/lượt và lỗi có tiêu lượt không | Thêm 26 test S-02: 25 bước liên tiếp và một kiểm tra tổng kết cuối ván |

Không thay luật R-01, Types, Board hoặc Rules production. Không thêm dependency. Tất cả fleet chơi hợp lệ trong fixture đi qua smart constructor `Board.placeFleet`, trực tiếp hoặc qua `step`.

**Phân biệt fixture với giá trị kỳ vọng:** các bảng tọa độ/kết quả mong đợi và record trong `shouldBe` là oracle để đối chiếu kết quả thật, không phải dữ liệu thay cho engine. Giữ test cố tình tạo Turn thiếu fleet hoặc history có tọa độ ngoài bàn, với nhãn `defensive corrupt-state probe`, để kiểm tra guard; chúng không dùng làm ván nghiệm thu. TypesSpec có test record-update thuần, không tuyên bố đó là transition hợp lệ. Stub trong CoordinatorSpec phục vụ kiểm tra ranh giới giao thức, không tham gia nghiệm thu lõi S-02.

## 2. Chuỗi lệnh đã kiểm tra

Nguồn chạy: `test/RulesSpec.hs`, nhóm `S-02 pure core acceptance`. `acceptanceTrace` gọi trực tiếp `Battleship.Rules.step`, bắt đầu bằng `initialGameState`; Right lấy state/events thật, Left giữ nguyên state cũ. Test đối chiếu phase, thứ tự event và toàn bộ state cho mỗi phát bắn/lỗi; không mở server hoặc socket.

Đội P1 đặt ngang: Carrier A1–E1, Battleship A2–D2, Cruiser A3–C3, Submarine A4–C4, Destroyer A5–B5. Đội P2 đặt ngang tương ứng ở hàng 6/7/8/9/10. Mỗi đội đủ năm ID, 17 ô.

Bảng dưới dùng tọa độ A1..J10 để dễ đọc; đây là kết quả miền của `step`, không phải transcript byte TCP. Với dòng Fire hợp lệ, event đầu là `ShotResolved actor coord outcome`, event sau là `TurnReady` như cột phase; riêng Win là `GameEnded P1 AllShipsSunk`. Dòng lỗi trả `Left` và không có state/event thành công.

| Bước | Actor và lệnh | Kết quả được test đối chiếu thành công | Phase sau khi caller xử lý |
|---:|---|---|---|
| 1 | P1 PlaceFleet đội P1 | `[FleetAccepted P1]`; P2 chưa có fleet | Placing — chờ đối thủ |
| 2 | P1 Fire A6 | Left FleetsNotReady; giữ nguyên state | Placing |
| 3 | P2 PlaceFleet đội P2 | `[FleetAccepted P2, GameStarted P1, TurnReady P1]` | Turn P1 |
| 4 | P1 Fire J10 | Miss | Turn P2 |
| 5 | P2 Fire J10 | Miss | Turn P1 |
| 6 | P1 Fire A6 | Hit | Turn P1 |
| 7 | P2 Fire A1 | Left (NotYourTurn P1); giữ nguyên state | Turn P1 |
| 8 | P1 Fire A6 | Left (AlreadyFired A6); giữ nguyên state | Turn P1 |
| 9 | P1 Fire B6 | Hit | Turn P1 |
| 10 | P1 Fire C6 | Hit | Turn P1 |
| 11 | P1 Fire D6 | Hit | Turn P1 |
| 12 | P1 Fire E6 | Sunk Carrier | Turn P1 |
| 13 | P1 Fire A7 | Hit | Turn P1 |
| 14 | P1 Fire B7 | Hit | Turn P1 |
| 15 | P1 Fire C7 | Hit | Turn P1 |
| 16 | P1 Fire D7 | Sunk Battleship | Turn P1 |
| 17 | P1 Fire A8 | Hit | Turn P1 |
| 18 | P1 Fire B8 | Hit | Turn P1 |
| 19 | P1 Fire C8 | Sunk Cruiser | Turn P1 |
| 20 | P1 Fire A9 | Hit | Turn P1 |
| 21 | P1 Fire B9 | Hit | Turn P1 |
| 22 | P1 Fire C9 | Sunk Submarine | Turn P1 |
| 23 | P1 Fire A10 | Hit | Turn P1 |
| 24 | P1 Fire B10 | Win, rồi GameEnded P1 AllShipsSunk; không có TurnReady/Sunk thêm | Finished P1 AllShipsSunk |
| 25 | P2 Quit | Left GameAlreadyFinished; không ghi đè winner | Finished P1 AllShipsSunk |

Không có Command WAIT trong hợp đồng: chờ được biểu diễn bằng Placing khi P2 còn `Nothing`. Thông điệp TCP WAITING thuộc Protocol/Coordinator; lõi không tự gửi mạng.

Tổng kết đã được assert: **21 lệnh thành công, 4 lỗi**; P1 có 18 tọa độ bắn (1 Miss, 12 Hit, 4 Sunk, 1 Win); đủ chính xác 17 ô của fleet P2 bị bắn. P2 có đúng một Miss ở J10. `shotsReceived P2` chính là history P1; hai fleet không đổi và state khởi đầu vẫn rỗng. Test B-02 còn mô phỏng ván hoàn chỉnh cho cả P1 và P2 thắng.

## 3. Kết quả chạy thật

Chạy từ gốc repository:

| Lệnh | Kết quả thực tế |
|---|---|
| `stack test --ghc-options=-Werror --test-arguments="--match S-02"` | **26 examples, 0 failures**, 0.0061 giây trong Hspec |
| `stack test --ghc-options=-Werror` | **642 examples, 0 failures**, 27.9946 giây; lượt này trước khi thay nốt fixture BoardSpec |
| `stack test` | **642 examples, 0 failures**, 27.9834 giây; đã có fixture Board/Rules/Types mới |
| `stack test --ghc-options=-Werror --test-arguments="--match A-03"` | **26 examples, 0 failures**, 0.7982 giây; biên dịch toàn bộ test suite với -Werror sau sửa BoardSpec |

Các thời gian trên do Hspec báo, không bao gồm thời gian build. Suite từ 618 lên 642: thêm 26 test S-02 và bỏ hai trường hợp Win/Turn mâu thuẫn nêu ở mục 1. Không bỏ test TCP hoặc nới assertion để đạt xanh.

Lần biên dịch S-02 đầu với -Werror báo warning `head`/`tail` trong helper test mới; đã đổi sang pattern matching có lỗi fixture rõ ràng và `drop 1`, sau đó chạy xanh. Không có lỗi test runtime ở các lượt S-02 này. Log hai lượt full-suite tại `.stack-work/s02-test-werror.log` và `.stack-work/s02-test.log` (local, được Git ignore); bảng này lưu kết quả để review trong repository.

## 4. Kiểm chứng lõi độc lập server và tính thuần

Lệnh đã chạy thành công, exit code 0:

```sh
stack exec -- ghc -fno-code -fforce-recomp -Wall -Werror -hide-all-packages -package base -package containers -isrc -outputdir .stack-work/s02-core src/Battleship/Rules.hs
```

GHC biên dịch đúng **bốn module**: `Battleship.Internal.Fleet`, `Battleship.Types`, `Battleship.Board`, `Battleship.Rules`. Không có Server/Client/Coordinator/Protocol trong đồ thị này, không cấp package network/async/stm. Đây là kiểm tra biên dịch dependency; việc chạy ván thật được kiểm chứng riêng bởi 26 test S-02 gọi `step` trực tiếp.

Chữ ký production được test B-01 đối chiếu với alias:

```haskell
PlayerId -> Command -> GameState
  -> Either GameError (GameState, [Event])
```

Kiểm tra nguồn Rules và dependency lõi: chỉ ADT/pattern matching, Either/Maybe, hàm thuần và Map/Set; không thao tác IO, STM, socket hoặc unsafePerformIO/unsafeDupablePerformIO. Hspec dùng IO để chạy assertion, không biến `step` thành hàm IO. Stack test có build-tools server/client để phục vụ các test khác; chọn nhóm S-02 không khởi chạy chúng.

Căn cứ kiến thức slide: kiểu dữ liệu đại số, Maybe/Either và pattern matching biểu diễn state/lệnh/lỗi; trạng thái bất biến và `foldM`/`scanl` xử lý chuỗi lệnh; module tách lõi khỏi IO; Hspec `describe`/`it`/`shouldBe` theo phần Module Programming (Chap8). Không cần cơ chế concurrency của server để quyết định trúng/chìm/thắng.

## 5. Phạm vi còn chờ và xác nhận

| Tiêu chí S-02 | Trạng thái |
|---|---|
| Fixture chơi hợp lệ dùng lõi thật, không giả phase/history | ĐẠT |
| Chuỗi đặt tàu → chờ → trượt → trúng → chìm → thắng | ĐẠT |
| Stack test xanh | ĐẠT — 642/642 |
| Step thuần và độc lập server | ĐẠT — kiểm tra nguồn/chữ ký, compile riêng và test trực tiếp |
| A xác nhận A-03 và fixture đặt tàu trong revision S-02 | CHỜ XÁC NHẬN |
| B xác nhận B-02, kết quả/phases/events và không đổi luật | CHỜ XÁC NHẬN |

Chưa có bằng chứng xác nhận trực tiếp từ A/B, không dùng test xanh hay tác giả commit thay chữ ký. Khi A/B review cần ghi tên, ngày, SHA chứa bản S-02 thực sự được duyệt và link/lời xác nhận. S-01 cũng còn chờ xác nhận A/B/C/D trong `shared_contract.md`.

Lỗi TCP Windows hiếm ở concurrent QUIT đã ghi ở B-02/D-03 không tái hiện trong hai lượt full-suite S-02, nhưng chưa xác định/sửa nguyên nhân gốc. Đây là vấn đề transport riêng; S-02 không thay Server và không tuyên bố đã chữa lỗi đó. Không ảnh hưởng việc chạy lõi thuần trực tiếp.
