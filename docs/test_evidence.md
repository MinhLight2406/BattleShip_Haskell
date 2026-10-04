# Minh chứng kiểm thử

## C-01 và A-01 — 2026-10-04

Môi trường: Windows, Stack 3.11.1, snapshot LTS 24.59, GHC 9.10.3.

```text
stack build
  Thành công: library, battleship-server, battleship-client.

stack test
  39 examples, 0 failures
  Test suite battleship-test passed

stack test --ghc-options=-Werror
  39 examples, 0 failures
  Test suite battleship-test passed
```

| Nhóm | Số test | Nội dung |
|---|---:|---|
| Hằng số R-01 | 8 | Bàn 10×10, năm ID/độ dài tàu, tổng 17 ô |
| PlayerId | 4 | Hai danh tính, chọn đối thủ, tính chất đổi hai lần |
| Khởi tạo | 3 | Placing, hai fleet vắng mặt tường minh, chưa có phát bắn |
| PlayerState độc lập | 19 | Chọn đúng người, một người sẵn sàng, cập nhật giữ đối thủ/phase/giá trị cũ, hai cập nhật độc lập giao hoán |
| Hợp đồng kiểu | 3 | Chữ ký Step/PlaceFleetFn/ViewFor bằng typeRep; không gọi hàm nghiệp vụ chưa triển khai |
| Smoke C-01 | 2 | Khởi chạy cả hai executable, kiểm tra exit code/stdout/stderr |

Các fixture với phase kết thúc chỉ kiểm tra helper cập nhật record, không chứng minh điều kiện thắng hoặc chuyển lượt. Kiểm tra đặt tàu hợp lệ, Hit/Sunk giữ lượt, Miss đổi lượt, thắng/bỏ cuộc, rollback lệnh lỗi và bí mật của `viewFor` cần cài đặt A-02/B/C/D trước khi ghi kết quả nghiệm thu.

A-01 còn chờ B/C/D review hợp đồng trong `Types.hs`, `architecture.md` và ánh xạ sự kiện trong `protocol.md`.

## D-01 — 2026-10-04

Cùng môi trường Windows, Stack 3.11.1, LTS 24.59, GHC 9.10.3. Nhánh thực hiện: `Minh-Giao_thuc_lenh_va_event`, tách từ `Minh-Dinh_nghia_kieu_ham` tại commit `96c1e48401fe22403f5a1c9c55489f4aba8780fb`.

```text
stack build
  Thành công: library, battleship-server, battleship-client.

stack test
  152 examples, 0 failures
  Test suite battleship-test passed

stack test --ghc-options=-Werror --test-arguments="--match D-01"
  113 examples, 0 failures
  Test suite battleship-test passed
```

| Nhóm D-01 | Số test | Nội dung |
|---|---:|---|
| Tọa độ | 11 | Toàn bộ 100 tọa độ hợp lệ trong một test; 10 dạng sai |
| Lệnh | 33 | PLACE/FIRE/QUIT, thứ tự tàu, giữ duplicate, cú pháp lỗi, phân loại lỗi tọa độ |
| Phản hồi/lỗi/định tuyến | 43 | 23 dạng phản hồi sai, 12 GameError A-01, 8 tổ hợp người bắn/kết quả |
| Framing byte | 15 | Chunk tách/gộp, từng vị trí cắt stream, LF/CRLF, 256/257 byte, UTF-8, control byte, dòng lỗi rồi dòng hợp lệ |
| Fixture tài liệu | 11 | Ví dụ lệnh/phản hồi và 8 transcript đọc trực tiếp từ protocol.md; khóa thứ tự và người nhận |

Đã bổ sung `bytestring` ở test component, đóng gói `docs/protocol.md` bằng `data-files` và khai báo module Cabal tự sinh `Paths_battleship_haskell`. Lượt chạy nghiêm ngặt ban đầu phát hiện thiếu module này trong cấu hình; sau sửa đã biên dịch và chạy thành công.

Các hàm tham chiếu trong `ProtocolSpec` chỉ kiểm tra hợp đồng D-01. Transcript là fixture đã chốt, không phải log một trận TCP thật. Chưa có parser/encoder production, Rules, server TCP hoặc client tương tác; kiểm tra tích hợp socket và chuyển trạng thái thực tế thuộc các task triển khai tiếp theo. R-01 và kiểu A-01 không thay đổi.

## S-01 — Đối chiếu kỹ thuật, chờ xác nhận — 2026-10-04

Nhánh `Minh-Connect_Type_and_Main`, tách từ `Minh-Giao_thuc_lenh_va_event` tại `62ef6018a9d6167bda9909b04fce4a3c370ed936`. Môi trường Windows, Stack 3.11.1, LTS 24.59, GHC 9.10.3.

```text
stack build
  Thành công: library, battleship-server, battleship-client.

stack test
  161 examples, 0 failures

stack test --ghc-options=-Werror
  161 examples, 0 failures

stack test --ghc-options=-Werror --test-arguments="--match S-01"
  9 examples, 0 failures
```

| Kiểm tra S-01 mới | Số test | Kết quả |
|---|---:|---|
| Nhận diện khai báo | 4 | data/newtype/alias nhiều dòng và family; bỏ comment lồng/literal; không nhầm tên dài, chữ ký hay tham chiếu |
| API so với bản hợp đồng | 1 | Constructor, trường, kiểu trường, deriving và ba alias khớp bản chụp |
| Coord/Command duy nhất | 2 | Quét 19 file Haskell trong src/app/test; mỗi kiểu chỉ khai báo một lần tại src/Battleship/Types.hs |
| Chủ sở hữu | 1 | 19 file Haskell và hai YAML đều có đúng một vai trò phụ trách trong bản hợp đồng |
| Hai Main | 1 | Hai file Main riêng, xuất main và có chữ ký main :: IO (); hai smoke test C-01 vẫn xanh |

SharedContractSpec dùng `directory`/`filepath` ở test component để đọc cây nguồn. Checker xét token và các dạng khai báo nêu trên, không thay thế compiler Haskell; GHC và TypesSpec vẫn kiểm tra kiểu/import. Chạy từ gốc repo để đối chiếu đúng file nguồn.

Trước S-01 không có định nghĩa Coord/Command trùng để phải xóa; còn thiếu bản hợp đồng tập trung, bảng người phụ trách đủ app/test/YAML, kiểm tra tự động API lệch tài liệu và bằng chứng A/B/C/D duyệt. Đã bổ sung các phần kỹ thuật tại [shared_contract.md](shared_contract.md), tái dùng 113 test D-01, 37 test A-01 và hai smoke test C-01.

**Chưa đủ nghiệm thu S-01:** chưa nhận được bốn xác nhận thật trên cùng nội dung. Bảng A/B/C/D đang CHỜ XÁC NHẬN; không ghi ĐÃ KHÓA chỉ vì build/test xanh. Không có thử nghiệm TCP thật hoặc cài đặt nghiệp vụ trong S-01.

## A-02 — 2026-10-04

Nhánh `Minh-Build_board`, tách từ `Minh-Connect_Type_and_Main` tại `f73dc87e336ba01d4723f642582403b1f20e2504`. Tiếp tục theo yêu cầu người dùng khi S-01 còn chờ xác nhận; bản hợp đồng v2 ghi thay đổi abstract Fleet để nhóm duyệt. Môi trường vẫn Windows, Stack 3.11.1, LTS 24.59, GHC 9.10.3.

```text
stack build
  Thành công: library, battleship-server, battleship-client.

stack test
  240 examples, 0 failures

stack test --ghc-options=-Werror
  240 examples, 0 failures

stack test --ghc-options=-Werror --test-arguments="--match A-02"
  78 examples, 0 failures
```

| Nhóm A-02 | Số test | Nội dung |
|---|---:|---|
| inBounds | 11 | Toàn bộ 100 ô; ngoài bốn cạnh, số âm, minBound/maxBound Int |
| shipCells | 41 | Mỗi loại tàu theo H/V, đúng chiều dài, sát mép/vượt mép; điểm đầu cực trị; duyệt đủ 1000 tổ hợp ID/ô/hướng |
| placeFleet | 26 | Hai fleet trong transcript, 120 hoán vị, fleet dọc/sát mép, chạm cạnh/góc, thiếu/thừa entry, trùng cả năm ID, chồng song song/giao nhau, sai tọa độ, sửa rồi gửi lại, ưu tiên lỗi |

Mọi Right Fleet trong các fixture kiểm tra có đúng năm ID, từng tàu dài 5/4/3/3/2, hợp các ô có kích thước 17 và tất cả trong bàn. Lỗi trả Left, không có đội tàu từng phần. Chiều dài lấy theo ShipId; request không chứa số chiều dài tùy chọn. Với năm ID duy nhất, đủ cả năm loại được bảo đảm; thiếu entry dùng InvalidFleetSize, lặp dùng DuplicateShip.

Đã kiểm tra thêm API public bằng GHC, dùng `stack exec -- ghc -fno-code -fforce-recomp -hide-all-packages -package base -package containers -package battleship-haskell <probe.hs>`; probe đặt trong .stack-work/a02-api-probes (không commit):

| Probe | Kết quả dự đoán / thực tế |
|---|---|
| PublicApi: tạo bằng placeFleet và đọc fleetShips | Biên dịch thành công, exit 0 |
| BadConstructor: Fleet Map.empty | Bị từ chối: constructor không có ở term level, exit 1 |
| BadRecordUpdate: fleet { fleetShips = Map.empty } | Bị từ chối: không có record field công khai, exit 1 |
| BadInternalImport: import Battleship.Internal.Fleet | Bị từ chối: hidden module, exit 1 |
| BadCoercion: coerce từ Map rỗng sang Fleet | Bị từ chối: constructor newtype không trong scope, exit 1 |

Bốn lỗi biên dịch trên là kết quả mong đợi của kiểm tra âm, không phải lỗi build package. SharedContractSpec thêm một test giới hạn truy cập Internal và bảo đảm Types không xuất Fleet(..); tổng S-01 hiện 10 test. Fixture TypesSpec chuyển sang placeFleet thay vì tạo raw Fleet. Không thêm dependency runtime; module private dùng containers sẵn có.

R-01/wire v1 không đổi. Rules.step, View.viewFor và TCP thực tế chưa được cài đặt/kiểm thử ở A-02. S-01 v2 vẫn chưa có bốn xác nhận nên chưa khóa; unit test xanh không thay thế bước xác nhận đó.

## B-01 — 2026-10-04

Nhánh `Minh-Build_Rule`, tách từ `Minh-Build_board` tại `ceb073968e4ab41ca0d2565de12dc9305872902c`. Môi trường Windows, Stack 3.11.1, LTS 24.59, GHC 9.10.3. Tiếp tục theo yêu cầu người dùng; S-01 vẫn chờ bốn xác nhận, không ghi đã khóa.

```text
stack build
  Thành công: library, battleship-server, battleship-client.

stack test
  354 examples, 0 failures

stack test --ghc-options=-Werror
  354 examples, 0 failures

stack test --ghc-options=-Werror --test-arguments="--match B-01"
  114 examples, 0 failures
```

| Nhóm RulesSpec | Số test | Nội dung |
|---|---:|---|
| Chữ ký thực tế | 1 | Type của hàm step đã cài khớp alias Step |
| Ma trận Command/Phase | 42 | Ba lệnh × Placing/Turn/Finished; cả hai actor/current turn, bốn tổ hợp winner/reason |
| Đặt tàu/bắt đầu | 19 | Board thật; P1/P2 đặt trước; luôn Turn P1; sự kiện đúng thứ tự; không đặt lại; năm lỗi Board; lỗi rồi sửa request |
| FIRE/ưu tiên lỗi | 48 | Tọa độ bốn cạnh/cực trị; bắn lặp mọi Outcome; sai lượt trước tọa độ/lặp; readiness cho raw Turn thiếu fleet; nhánh FIRE hợp lệ tạm thời |
| Kết thúc/lịch sử | 4 | Quit giữ fleet/history; Quit/EOF lặp không đổi winner; Finished từ chối payload sai; chuỗi lỗi không đổi state/event |

Rules pattern-match từng Command và từng Phase, không có undefined/error hoặc IO trong production. -Wall và -Werror kiểm tra nhánh thiếu khi compiler biên dịch; các test chạy qua mọi tổ hợp constructor hiện có. Không định nghĩa lại Coord/Command; không import Fleet private; không thêm dependency hoặc sửa Main.

`applyAsCaller` trong test mô phỏng hợp đồng coordinator: Left giữ nguyên toàn bộ GameState và không có Event thành công. Các assertion còn kiểm tra chính step trả đúng Left; lỗi đặt đội tàu thứ hai rồi sửa lại phải giữ đội tàu thứ nhất và khởi động được trận. Đây không phải kiểm thử Coordinator/STM/socket production, các module đó chưa triển khai.

**Giới hạn có chủ đích của B-01:** khung xử lý PLACE/bắt đầu/QUIT và các lỗi trước FIRE. Nhánh FIRE qua mọi kiểm tra trả `Left (InvalidCommand "B-01: shot resolution is not implemented")`; chưa tạo Miss/Hit/Sunk/Win hoặc phát ShotResolved, chưa có chuyển lượt sau một phát bắn. Test lịch sử có Outcome Win chỉ là fixture để kiểm tra bắn lặp, không chứng minh thắng trận. Task luật tiếp theo thay nhánh Left tạm thời này và cập nhật test tương ứng.

Kiểu/chữ ký chung, luật R-01 và wire v1 giữ nguyên. Các transcript bắn D-01 là hợp đồng đích, chưa được thực thi trong B-01. Tài liệu hiện tại ghi rõ trạng thái triển khai thay vì coi game đã chơi được.
