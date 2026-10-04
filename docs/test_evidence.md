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

## C-02 — 2026-10-04

Nhánh `Minh-Update_Server`, tách từ `Minh-Build_Rule` tại `4685f93dcc581b7b6e139fe8c2c25200deac5fa0`. Windows, Stack 3.11.1, LTS 24.59, GHC 9.10.3; snapshot chọn network 3.2.9.0 và async. S-01 tiếp tục chờ bốn xác nhận; người dùng yêu cầu thực hiện C-02, không ghi xác nhận thay thành viên.

```text
stack build
  Thành công: library, battleship-server, battleship-client.

stack test
  386 examples, 0 failures

stack test --ghc-options=-Werror
  386 examples, 0 failures

stack test --ghc-options=-Werror --test-arguments="--match C-02"
  32 examples, 0 failures
```

| Nhóm | Số test | Phạm vi |
|---|---:|---|
| ServerSpec | 26 | Server library với TCP thật: welcome đúng thứ tự/ba kết nối đồng thời, third client bị từ chối lặp, hai socket vẫn dùng được; QUIT/EOF cho P1/P2 và trước P2; đóng socket bất thường; hai QUIT đồng thời; phản hồi mẫu/bí mật; LF/CRLF/chia/gộp frame/tail EOF; payload 256/257 byte; cancel với 0/1/2 client; startup callback lỗi; port bị chiếm |
| IntegrationSpec C-02 | 6 | Bốn trường hợp CLI sai; executable bind port bị chiếm; chạy executable port 0, nhận P1/P2, từ chối người thứ ba, GAME_OVER/EOF đúng và exit 0 |
| IntegrationSpec C-01 | 2 | Server --help và client khung khởi chạy/thoát đúng; thay smoke server cũ vốn đòi chương trình luôn thoát ngay |

Test dùng port 0 do OS cấp, không dựa vào sleep để chờ server khởi động: callback sau listen hoặc dòng startup executable xác định readiness. Probe dòng chưa có LF dùng recvBufNoWait sau khoảng chờ ngắn, tránh chặn recv trên Windows. Các socket/test worker dùng bracket/withAsync; thao tác đọc có deadline và watchdog đóng socket, không chỉ dùng timeout với foreign call có thể không interrupt được. Ca cleanup kiểm tra connect bị từ chối và callback readiness của server mới trên cùng port.

Các lỗi phát hiện và sửa trong vòng kiểm thử C-02:

- Cancel worker trước khi đóng listener có thể treo ở accept Windows. Cleanup đóng listener trước khi cancel/join.
- Đóng client khi reader đang chờ có thể gây reset và mất GAME_OVER; chỉ shutdown mà chưa close lại có thể khiến worker chưa thoát. Cleanup dùng shutdown Both rồi close, sau đó hủy/chờ worker. Test yêu cầu cả hai nhận đúng một GAME_OVER, EOF và server kết thúc.
- SO_REUSEADDR trên Windows cho phép listener trùng port. Không bật tùy chọn đó trên Windows; Unix giữ reuse để hỗ trợ restart sau TIME_WAIT. Ca bind trùng phải thất bại ở cả library/executable.
- Smoke test C-01 đòi server in khung rồi thoát không còn đúng khi server lắng nghe thật; chuyển sang --help và thêm nghiệm thu vòng đời executable qua TCP.
- Kiểm tra header Main cũ đòi token `main` ngay sau `where`, vô tình cấm import. S-01 vẫn kiểm tra module Main và chữ ký main :: IO (), đồng thời cho phép import Server/CLI cần thiết.

Network/bracket bám Chap11; MVar bám Chap5; withAsync/link/race/timeout bám Chap7. Send có watchdog/deadline 2 giây để giải phóng socket khi peer không đọc. Đây không phải benchmark hoặc kiểm thử tải/backpressure; các ca trên kiểm chứng lifecycle/framing của demo localhost hai người. Source tham khảo API chính thức: [network](https://hackage.haskell.org/package/network-3.2.9.0), [async](https://hackage.haskell.org/package/async/docs/Control-Concurrent-Async.html).

**Giới hạn C-02:** server chỉ xử lý QUIT và transport, mọi payload khác trong giới hạn nhận mẫu ERROR INVALID_COMMAND. Chưa nối parser/encoder Protocol, Coordinator/STM, Rules.step hoặc viewFor; không phát OK PLACE/START/TURN/SHOT giả. R-01/Types/wire v1 không đổi; transcript đặt tàu/bắn D-01 vẫn là mục tiêu task tích hợp sau. README có hướng dẫn chạy server và hai terminal TCP PowerShell cùng terminal thứ ba.

## D-02 — 2026-10-04

Nhánh `Minh-Parser`, tách từ `Minh-Update_Server` tại `141a219690ecec94cb9cb2a6c6b7809896dafc7c`. Windows, Stack 3.11.1, LTS 24.59, GHC 9.10.3. S-01 tiếp tục chờ bốn xác nhận; người dùng yêu cầu thực hiện D-02, không ghi xác nhận thay thành viên.

```text
stack build
  Thành công: library, battleship-server, battleship-client.

stack test
  450 examples, 0 failures

stack test --ghc-options=-Werror
  450 examples, 0 failures

stack test --ghc-options=-Werror --test-arguments="--match D-02"
  177 examples, 0 failures
```

| Nhóm D-02 | Số test | Phạm vi |
|---|---:|---|
| ProtocolSpec D-01/D-02 | 145 | Production parse/encode với grammar và golden vectors D-01; toàn bộ 100 tọa độ; lệnh thiếu/thừa tham số, ASCII/tọa độ/chiều sai; 120 hoán vị fleet; giữ entry trùng/thiếu; raw Coord cực trị; mọi Response/WireError/outcome/reason; count 0..256; định tuyến và thứ tự batch Event; LF/CRLF/chia/gộp/biên 256–257 byte; không mất frame hợp lệ trước lỗi; đọc và encode/parse các block transcript từ tài liệu |
| ClientSpec | 22 | TCP thật với C-02: P1/P2, QUIT, PLACE/FIRE mẫu, SERVER_FULL, validate trước kết nối, callback lỗi/cleanup. Peer có kịch bản: handshake phân mảnh, một lệnh LF, PLACE chuẩn, async TURN/INCOMING trước SHOT, GAME_OVER, phiên bản/handshake sai, phản hồi sai/quá dài/non-ASCII, SHOT sai tọa độ, EOF và tail thiếu LF; hiển thị tiếng Việt |
| IntegrationSpec D-02 | 10 | Tám CLI sai bị từ chối trước kết nối; executable gửi QUIT/FIRE vào C-02 thật, đọc tiếng Việt UTF-8 đúng, stderr rỗng, exit 0 và session đóng |

ProtocolSpec đã bỏ grammar/encoder tham chiếu riêng trong test: các adapter chỉ chuyển String/ByteString, gọi API production và đọc fixture. Golden payload độc lập cùng transcript giúp bắt lỗi mà chỉ round-trip có thể bỏ sót. Tổng suite tăng từ 386 lên 450 test; các ca C-02 và S-01 vẫn đạt sau khi Server dùng framer chung và bổ sung chủ sở hữu ClientSpec. Hai smoke test C-01 nay dùng --help của cả hai executable.

Các vấn đề xử lý trong D-02:

- Protocol/Client trước đó chỉ là khung; chưa có codec production hoặc executable nói chuyện TCP. Đã cài đặt codec thuần và client một lệnh, Main chỉ xử lý CLI/hiển thị.
- Test grammar tham chiếu chỉ kiểm chứng đặc tả, có thể xanh dù production chưa cài. Đã chuyển sang API production, thêm golden encoding, round-trip và TCP/executable tests.
- Event nội bộ không khớp một-một với wire. Response/WireError riêng giữ đúng token/tham số; ShotResolved tạo SHOT/INCOMING, không dựng tọa độ giả cho lỗi không chứa tọa độ, không echo debug string.
- TCP có thể phân mảnh/gộp frame. Dùng feedFrames chung với buffer có giới hạn, giữ frame hoàn chỉnh trước lỗi và không parse phần thiếu LF ở EOF. C-02 giữ handler mẫu, không thêm luật bắn vào server/client.
- Hai test executable ban đầu thất bại vì Windows locale không encode được ký tự tiếng Việt (hPutChar/cannot encode character). Đã đặt stdout/stderr client UTF-8 và đọc pipe test UTF-8; cả hai case giao tiếp đạt, không đổi code page toàn máy.

Căn cứ slide: ADT/pattern matching và Either cho lỗi tường minh; Chap8 tách module codec thuần/IO client và Hspec describe/it/shouldBe; Chap11 dùng Network.Socket/bracket và xử lý TCP stream; Chap7 dùng async/deadline để quản lý I/O. Tái sử dụng network/bytestring/async đã có trong snapshot; ClientMain khai báo thêm network/bytestring ở component executable vì import trực tiếp, không thêm thư viện mới vào dependency set.

**Giới hạn nghiệm thu:** transcript đặt tàu/bắn đã được codec encode/parse đúng, chưa được server thực thi thành trận thật. C-02 vẫn trả ERROR INVALID_COMMAND mẫu cho PLACE/FIRE; QUIT/slot/EOF hoạt động thật. Client gửi một lệnh rồi đóng, có deadline 10 giây cho connect/handshake/gửi/đọc, chưa có vòng nhập/render bàn hoặc chờ lượt lâu. Coordinator/STM, kết quả bắn và viewFor thuộc task tiếp theo; S-01 chưa khóa. README và mục 9 protocol.md ghi API/quy ước và cách chạy.

## A-03 — 2026-10-04

Nhánh `Minh-Dat_tau`, tách từ `Minh-Parser` tại `cad31d53d88286b513b0a79a06f39984b673661e`. Windows, Stack 3.11.1, LTS 24.59, GHC 9.10.3. Người dùng yêu cầu tiếp tục A-03; S-01 vẫn chờ xác nhận A/B/C/D.

```text
stack build
  Thành công: library, battleship-server, battleship-client.

stack test
  476 examples, 0 failures

stack test --ghc-options=-Werror
  476 examples, 0 failures

stack test --ghc-options=-Werror --test-arguments="--match A-03"
  26 examples, 0 failures
```

BoardSpec có 78 test A-02 và thêm 26 test A-03; tổng toàn dự án tăng từ 450 lên 476. Các test thuần gọi Board/Rules production, không cần socket hoặc server; năm test GHC kiểm chứng ranh giới package public.

| Nhóm mới | Số test | Phạm vi |
|---|---:|---|
| Mép, ID và chạm cạnh | 12 | Mỗi loại tàu ở A1/J10 theo H/V; hai fleet ngang/dọc chứa cả A1 và J10; CR/SB cùng dài 3 được phép khi khác ID; lặp CR hoặc SB vẫn đủ 5 tàu/17 ô bị từ chối; tiếp xúc E1/F1 và hai tàu song song hợp lệ; duyệt toàn bộ 5^5 = 3125 tổ hợp ID, chỉ 120 hoán vị đúng năm ID được chấp nhận |
| Xác nhận qua Rules.step | 9 | Cả P1/P2; chuỗi request cùng fleet/fleet hợp lệ khác/fleet sai bị từ chối sau xác nhận; giữ fleet đầu khi đối thủ đặt và chỉ bắt đầu một lần; sai trước xác nhận có thể sửa, không giữ fleet từng phần; cấm đặt lại ở Turn P1/Turn P2 và mọi winner/reason Finished |
| Ranh giới API bằng GHC | 5 | Positive control import Board/Types, gọi placeFleet và đọc fleetShips biên dịch thành công; bốn probe constructor thô/record update/coerce từ Map rỗng/import private phải exit 1 với diagnostic đúng nguyên nhân |

Các probe dùng `ghc -fno-code -fforce-recomp -hide-all-packages -package base -package containers -package battleship-haskell -i <probe.hs>` trong môi trường Stack. `-i` xóa đường dẫn import nguồn để kiểm tra đúng package đã build, không import src trực tiếp và vô tình bỏ qua hidden module. Probe được tạo trong thư mục tạm và xóa bằng bracket, không commit artifact hoặc cần dependency mới. Các lỗi biên dịch âm là kết quả mong đợi, không phải lỗi build dự án. Stack cung cấp GHC/package database; nên chạy các test này bằng stack test.

Rà soát trước A-03 cho thấy A-02 đã kiểm tra đủ năm ID, chiều dài cố định, vượt biên/chồng; B-01 đã cấm đặt lại. Không phát hiện lỗi thuật toán đặt tàu cần sửa. Phần còn thiếu là nhóm nghiệm thu A-03 độc lập: trường hợp lặp một ID dài 3 thay ID dài 3 còn lại (tổng vẫn 17), chuỗi thử thay bằng fleet hợp lệ khác sau xác nhận, và tự động hóa kiểm tra public API bằng compiler thay vì chỉ các probe thủ công A-02. Nếu thiếu các test này, thay đổi sau có thể chỉ kiểm tra tổng ô, cho thay fleet hoặc expose constructor mà không bị nhóm test đặt tàu phát hiện rõ.

Giữ placeFleet thuần với chữ ký đã thống nhất: nó kiểm tra một request và không có GameState để biết ai đã đặt. Quy tắc không đặt lại được kiểm tra qua Rules.step trước khi gọi Board; test caller giữ state cũ khi Left, chưa kiểm chứng Coordinator/STM thực tế. Board bổ sung Haddock về đúng ID/độ dài, chạm cạnh và ranh giới xác nhận; README/hợp đồng chung bổ sung hướng dẫn nghiệm thu. Không đổi Types, constructor export, luật R-01, wire v1 hoặc dependency.

Căn cứ slide: ADT cho hai ShipId dài 3 riêng biệt; hàm thuần/Either và quy nạp trên danh sách cho kiểm tra toàn bộ fleet; module/constructor ẩn để giữ bất biến; Hspec describe/it/shouldBe cho unit test (Chap8). A-03 đạt tiêu chí ở API miền public với giá trị được tạo theo kiểu an toàn; tích hợp PLACE vào TCP server, kết quả bắn và viewFor vẫn thuộc các task sau. C-02 tiếp tục dùng phản hồi mẫu PLACE/FIRE.

## B-02 — 2026-10-04

Nhánh `Minh-Chien_luoc`, tách từ `Minh-Dat_tau` tại `1626f90c863fa495f32fe849887a5db02266db3c`. Windows, Stack 3.11.1, LTS 24.59, GHC 9.10.3. Người dùng yêu cầu tiếp tục B-02; S-01 vẫn chờ bốn xác nhận.

```text
stack build
  Thành công: library, battleship-server, battleship-client.

stack test
  Lượt nghiệm thu cuối: 513 examples, 0 failures

stack test --ghc-options=-Werror
  Lượt nghiệm thu cuối: 513 examples, 0 failures

stack test --ghc-options=-Werror --test-arguments="--match B-02"
  37 examples, 0 failures
```

RulesSpec giữ 114 test B-01 (thay assertion FIRE tạm thời bằng kết quả thật) và thêm 37 test B-02. Tổng suite tăng từ 476 lên 513. Tất cả test luật gọi step production bằng giá trị thuần, không cần socket hoặc IO server; helper test chỉ kiểm tra assertion và mô phỏng caller giữ state cũ khi Left.

| Nhóm mới B-02 | Số test | Phạm vi |
|---|---:|---|
| Miss/Hit/100 ô | 6 | Cả hai actor, target là fleet đối thủ; mỗi tọa độ trong 100 ô trên bàn được xét như phát bắn đầu; Miss đổi lượt, Hit giữ lượt; full-state equality kiểm tra một entry mới và giữ nguyên fleet/lịch sử khác |
| Chìm từng tàu | 10 | Mỗi ShipId × P1/P2, tất cả hoán vị thứ tự bắn: 120/24/6/6/2 thứ tự cho CV/BB/CR/SB/DD; các ô đầu Hit, ô cuối Sunk ship; giữ Hit lịch sử, không tiêu lượt, mọi ô đã bắn đều bị từ chối khi thử lại; CR/SB chạm cạnh vẫn là hai tàu riêng |
| Thắng/ưu tiên terminal | 10 | Mỗi loại tàu có thể là tàu cuối; cả hai actor, thử mọi ô làm ô cuối trong 17 ô tàu, có thêm Miss trong lịch sử; Win ưu tiên Sunk, chỉ ShotResolved Win rồi GameEnded, không TURN; mọi lệnh sau Finished giữ winner/reason và bị từ chối |
| Biên lịch sử/hướng/lỗi | 8 | Đủ 17 shot nhưng gồm nhiều Miss chưa thắng; fleet dọc và các ShipId dài 3; sai lượt/tọa độ/bắn lặp/đặt lại không tiêu lượt sau Hit; bắn lặp một Miss thật sau khi đối thủ trả lượt |
| Hai bàn/shot nhận | 1 | Hai người được bắn cùng tọa độ trên hai bàn riêng; shotsReceived đúng chiều và rỗng ban đầu |
| Ván thuần từ trạng thái rỗng | 2 | P1 thắng và P2 thắng: hai PLACE theo thứ tự khác nhau, START P1 một lần, Miss đổi lượt rồi 17 ô tàu bị trúng; batch/outcome/thứ tự event, hai fleet, toàn bộ lịch sử và Finished đúng |

Đã chạy trực tiếp đoạn GHCi mô phỏng trong README (trích chính block Haskell, không viết lại script). Kết quả: `Right (Finished P1 AllShipsSunk)`, `Right 17`, batch cuối `[ShotResolved P1 (Coord 5 6) Win, GameEnded P1 AllShipsSunk]`. Thứ tự ô từ Set cho phép Carrier là tàu cuối, không mặc định Destroyer phải quyết định thắng.

Các thay đổi chính:

- Bỏ Left InvalidCommand tạm thời ở FIRE hợp lệ; xác định membership theo fleet đối thủ, kiểm tra các tập ô tàu đã bắn để tính Sunk/Win, không đếm tổng shot hoặc vùng liên thông.
- Giữ ưu tiên lỗi B-01: readiness → lượt → tọa độ → lặp. Chỉ Right ghi một tọa độ và Outcome, giữ nguyên hai fleet/lịch sử đối thủ; Miss đổi lượt, Hit/Sunk giữ lượt theo R-01; Win chuyển Finished và không có TurnReady.
- Thêm `shotsReceived :: PlayerId -> GameState -> Map Coord Outcome` vào Types: lấy playerShots của người kia, phù hợp hợp đồng đã dùng lịch sử bắn ra làm dữ liệu gốc. Đây là accessor, không thêm field lưu hai bản; shot nhận của đối thủ tăng một entry khi actor bắn. Khai báo PlayerState/GameState, alias Step và wire v1 giữ nguyên; helper mới được ghi vào hợp đồng chung để review.
- Cập nhật test B-01 vốn đòi nhánh FIRE chưa triển khai, tài liệu trạng thái/API và ví dụ mô phỏng. Không thêm dependency, không đưa luật vào Main hoặc TCP server mẫu.

**Lần lỗi TCP được ghi nhận:** lượt stack test đầu tiên có 513 example và một lỗi ngoài test luật: C-02 `serializes simultaneous QUITs into one consistent final broadcast`, Network.Socket.recvBuf InvalidArgument trên Windows. Chạy riêng 50 lần không tái hiện; bổ sung test này lặp 50 session trong cùng process và gắn thông tin P1/P2, GAME_OVER/EOF cho IOException. Lượt khoanh vùng và hai lượt full-suite nghiệm thu cuối đều đạt. Test vẫn yêu cầu hai GAME_OVER giống nhau và EOF, không nuốt lỗi recv hoặc coi IOException là EOF. Chưa xác định được nguyên nhân gốc của lần lỗi hiếm, không ghi rằng transport đã được sửa; giữ minh chứng để điều tra nếu tái hiện. Server production không thay đổi ở B-02. Quy ước EOF/lỗi của API được đối chiếu [Microsoft recv](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-recv).

Căn cứ slide: hàm thuần/state bất biến, ADT/pattern matching và Either cho kết quả/lỗi; Map/Set với phép kiểm tra tập con để xác định chìm/thắng; foldM để nối chuỗi lệnh thuần; Hspec describe/it/shouldBe theo Chap8. B-02 đạt tiêu chí mô phỏng ván thuần. Coordinator/STM, viewFor và tích hợp PLACE/FIRE vào server C-02 vẫn thuộc task sau; server tiếp tục trả phản hồi mẫu cho PLACE/FIRE. S-01 chưa khóa.
