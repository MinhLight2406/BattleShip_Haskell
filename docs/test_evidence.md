# Minh chứng kiểm thử

## Chỉ mục hiện hành và cách đọc — 2026-10-10

Các mục C-01..S-04 bên dưới là **kết quả lịch sử 2026-10-04/05**, giữ nguyên số test, working tree, giới hạn và lỗi tại thời điểm chạy. TQueue/unverified Linux trong đoạn cũ không mô tả hiện trạng sau C-07/Docker. Báo cáo hiện hành xem [report_final.md](report_final.md); phương pháp/lệnh/seed/coverage xem [testing.md](testing.md).

| Đợt bổ sung | Code/test liên quan | Bằng chứng hiện có |
|---|---|---|
| UI và native LAN/resume | frontend/test, bridge/connection/game | [frontend_integration.md](frontend_integration.md), [log UI](demo/frontend/test-evidence.log) theo ngày |
| A-06/B-06 | BoardSpec/ViewSpec/Generators; QuickCheck ≥1.000/property/coverage | Có trong full suite Linux **908 ví dụ** ở DK-08/09; không coi 908 là số random case |
| C-07 | CoordinatorSpec/ServerSpec; 128/126/2, batch/capacity/slow/races | Full suite Linux + DK-08 TCP nonreader; [contract](shared_contract.md) ghi policy |
| DK-04/DK-05 | Linux image test/runtime | [docker/README](../docker/README.md): 908 Haskell, 36 frontend, runtime 5/5 và 6/6 tại mốc tương ứng |
| DK-06/DK-07/DK-08 | Helper/mount/Compose/readiness/IP/resume/lifecycle | [DK-08](dk08_acceptance.md), [19-ca log](demo/dk08/automated-results.txt) |
| DK-08 UI | Chrome/Edge hai process/profile, cùng host qua LAN IP | [log browser](demo/dk08/two-browsers-results.txt), ảnh/log trong DK-08; không phải hai thiết bị |
| DK-09 | Build/test/lệnh README/helper/trận mới/stop/down | [DK-09](dk09_handover.md), [kết quả](demo/dk09/results.txt), [runtime](demo/dk09/runtime-handover.txt) |

Source bàn giao đã commit: `8bd7da92c083bcf9d8119f5c786342f9496c6cd7`. Hồ sơ DK-08/09 chạy trên working tree trước commit này, không gán cho lần chạy docs mới. Review cùng SHA và thiết bị thật vẫn chờ. Các hash/path trong log cũ phản ánh source/log cũ, không cần bằng hash docs đang được chỉnh.

Các gate chạy cho nhánh hoàn thiện docs được ghi tại [docs_review.md](docs_review.md) sau khi thực hiện; không điền kết quả chưa chạy.

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

## C-03 — 2026-10-04

Nhánh `Minh-Ghep_server_voi_luat`, tách từ `Minh-Chien_luoc` tại `6601377edfe0c00f9f73e2d4f6111e91cbb8af21`. Windows, Stack 3.11.1, LTS 24.59, GHC 9.10.3. Người dùng yêu cầu tiếp tục C-03; S-01 vẫn chờ xác nhận A/B/C/D.

```text
stack build
  Thành công: library, battleship-server, battleship-client.

stack test
  553 examples, 0 failures

stack test --ghc-options=-Werror
  553 examples, 0 failures

stack test --ghc-options=-Werror --test-arguments="--match C-03"
  40 examples, 0 failures
```

CoordinatorSpec bổ sung 40 test: 31 unit test thuần và 9 test TCP thật. Tổng suite tăng từ 513 lên 553; các assertion C-02/D-02 nhận lỗi mẫu được cập nhật sang lỗi Rules thật, không bỏ test. IntegrationSpec mở rộng test server executable hiện có để đặt hai fleet, nhận START/TURN, bắn A6 HIT và QUIT; client executable nhận lỗi NotReady với tiếng Việt UTF-8.

| Nhóm | Số test | Phạm vi |
|---|---:|---|
| Parser và đối số Step | 14 | Payload sai không gọi Step (stub cố ý lỗi nếu bị gọi); actor P1/P2 từ socket, đủ ba Command, giữ thứ tự danh sách PLACE và state cũ |
| Lỗi luật/state/batch | 17 | 12 loại GameError chỉ trả actor và giữ toàn bộ state; phase mới quyết định WAITING; thứ tự event/broadcast; lỗi encode không trả partial state/frame; retry sau lỗi/lặp với lõi thật |
| TCP | 9 | Stub P2 nhận FIRE, state của lần gọi thứ nhất được dùng ở lần thứ hai; transcript 7.1/7.2 và Miss chuyển lượt; fleet sai có thể sửa; simultaneous PLACE/FIRE; lỗi encode truyền ra supervisor; Sunk/Win cho cả hai actor và EOF/QUIT sau Win giữ winner/reason; EOF được gửi vào core như Quit |

Đường chạy production: recv → feedFrames → Coordinator.coordinate → parseCommand → Rules.step → encodeEvent → định tuyến theo registry → sendAll. Coordinator không chứa logic hình học, xác định trúng/chìm/thắng hoặc bản sao Coord/Command. Với Left, giữ state cũ; chỉ Right đã encode đủ batch mới được dùng để cập nhật. MVar bảo vệ parse/step/cập nhật/gửi để hai reader không ghi chồng hoặc xen byte. EOF/lỗi socket đi qua applyCommand Quit, terminal state ngăn broadcast lần hai.

**Điểm stub/Đợt 6:** `Server.runServerWith :: Step -> GameState -> PortNumber -> (PortNumber -> IO ()) -> IO ()`. Production `runServer = runServerWith Rules.step initialGameState`. Do A/B đã hoàn thiện, dùng lõi thật ngay; countingStub/eofStub/badEventStub chỉ nằm trong test để nhận biết việc gọi core, giữ state, dùng kết quả EOF và xử lý lỗi nội bộ. Không tạo một bộ luật mẫu trong server.

**Vấn đề phát hiện và sửa trong C-03:** lúc đầu lỗi encode của core ném exception vào reader, nhưng finalizer Quit báo hoàn tất bình thường; supervisor có thể nhận tín hiệu kết thúc trước exception nên test yêu cầu server báo lỗi bị thất bại. Kênh kết thúc chuyển thành Either SomeException (), reader lỗi đánh dấu ended và báo Left trước finalizer; supervisor truyền lỗi lên caller. Test yêu cầu đúng nội dung lỗi Coordinator, hai socket EOF và không có frame/turn/game-over giả. Các tên biến test che khuất hàm coordinate được đổi để build -Werror sạch.

Giới hạn: write vẫn trong MVar, peer chậm có thể trì hoãn người kia đến deadline send 2 giây; STM/TVar và queue writer riêng chưa triển khai. Client D-02 một lệnh vẫn đóng sau phản hồi, chưa phải client chơi tương tác. viewFor và bốn xác nhận S-01 còn thiếu. Lỗi recv Windows hiếm ghi tại B-02 không tái hiện trong các lượt full-suite C-03, chưa xác định nguyên nhân gốc nên không coi C-03 là minh chứng đã chữa lỗi đó.

Căn cứ slide: hàm thuần/ADT/pattern matching/Either cho Coordinator; dùng chung module/kiểu và Hspec describe/it/shouldBe (Chap8); MVar để đồng bộ state (Chap5); async/bracket/timeout quản lý worker và truyền lỗi (Chap7); TCP stream/Network.Socket (Chap11). C-03 đạt tiêu chí một lệnh client tới Step và phản hồi quay về server, được kiểm chứng cả stub lẫn lõi thật.

## D-03 — 2026-10-05

Nhánh `Luong_nhap_gui_dat_tau`, tách từ `Minh-Ghep_server_voi_luat` tại `f21c81602042324bdccdac61bbd8df98bef878ac`. Windows, Stack 3.11.1, LTS 24.59, GHC 9.10.3. S-01 vẫn chờ bốn xác nhận thật.

```text
stack build --ghc-options=-Werror
  Thành công: library, battleship-server, battleship-client.

stack test --ghc-options=-Werror --test-arguments="--match D-03"
  66 examples, 0 failures

stack test --ghc-options=-Werror
  618 examples, 0 failures

stack test
  Lượt nghiệm thu cuối: 618 examples, 0 failures
```

Thêm 66 test D-03: 59 ClientSpec và 7 IntegrationSpec. Suite tăng từ 553 lên 618 vì test CLI không đối số vốn đòi lỗi đã chuyển thành nghiệm thu mở hướng dẫn/hủy ở D-03; không bỏ nghiệm thu hành vi CLI đó. Các test D-02 còn lại giữ nguyên ý nghĩa, hai chế độ cùng dùng helper socket/framer/codec.

| Nhóm D-03 | Số test | Phạm vi |
|---|---:|---|
| Parser/preview thuần | 31 | Cú pháp A1 H/V, chữ thường/tab/space, thiếu/thừa tham số, hướng sai/tọa độ sai/Unicode không được ép thành ASCII; cả năm ShipId ở mép J10 theo H/V; vượt mép; golden toàn bộ 100 ô của fleet riêng |
| Terminal qua handle UTF-8 | 14 | Hướng dẫn đủ năm tàu và H/V; sửa cú pháp/hình học/chồng lấn; thay một tàu giữ bốn tàu còn lại và xem lại; sửa nhiều lần; lựa chọn GUI/SUA sai; HUY/EOF tại nhập/review/edit; hủy không kết nối |
| TCP | 14 | Một PLACE canonical sau WELCOME; phân mảnh CRLF/OK; giữ socket sau OK và chờ hơn 10 giây; cancel reader idle đóng socket; SERVER_FULL không gửi; ERROR/GAME_OVER khi chờ OK; handshake sai, ACK lặp, SHOT không được yêu cầu, malformed/overlong, EOF thiếu ACK; P2 đặt với server thật, nhận INCOMING rồi GAME_OVER |
| Executable | 7 | Mặc định có hướng dẫn, HUY trước connect; EOF sau đủ fleet nhưng chưa GUI không gửi; bốn port/argument sai; stdin của người mới gồm vượt biên/chồng tàu/SUA/GUI, preview UTF-8 và PLACE vào server thật đến START/INCOMING/GAME_OVER |

Flow: promptFleet dựng draft offline theo năm ShipId; parsePlacementInput dùng Protocol.parseCoord và Board.shipCells, kiểm tra giao tập ô với các tàu khác; Board.placeFleet kiểm tra fleet hoàn chỉnh trước preview/GUI. SUA chỉ thay tàu được chọn sau input hợp lệ; HUY/EOF trả Nothing. renderFleet chỉ nhận Fleet của chính người chơi, không cần GameState hoặc dữ liệu đối thủ. GUI mới kết nối, nhận danh tính rồi encode/send một PlaceFleet theo wire v1.

Sau OK PLACE, client giữ kết nối nhận WAITING/START/TURN/INCOMING/GAME_OVER. Deadline 10 giây chỉ áp dụng connect/handshake/ACK, không cho nhập offline hoặc chờ đối thủ sau OK. Reader lâu dài nằm dưới withAsync; supervisor đóng socket trước khi join lúc cancel để đánh thức recv Windows. Main chỉ xử lý CLI/port/UTF-8/lỗi; không chứa luật hoặc luồng nhập. Chế độ `[PORT] "COMMAND"` D-02 vẫn đóng sau một phản hồi.

**Lỗi transport cũ tái hiện:** lượt full-suite đầu có 618 examples, 1 failure ở C-02 simultaneous QUIT (50 session): `C-02 simultaneous QUIT P1 GAME_OVER: Network.Socket.recvBuf: invalid argument (Invalid argument)`, seed 1271559836. Đây là triệu chứng đã ghi ở B-02; Server/Coordinator/ServerSpec không thay đổi trong D-03. Chạy riêng `--match simultaneous` đạt 3/3 (gồm 50 session QUIT); hai lượt full-suite cuối đạt 618/618. Đã đọc nguồn network 3.2.9.0 tại cache và đối chiếu [Microsoft recv](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-recv), nhưng chưa xác định nguyên nhân gốc. Không sửa production bằng suy đoán, không bỏ test, không nuốt lỗi recv/coi exception là EOF hoặc ghi rằng lỗi này đã được chữa. Kết quả cuối xanh không bảo đảm triệu chứng hiếm sẽ không lặp lại.

Căn cứ slide: ADT/pattern matching với Maybe/Either cho input/hủy/lỗi; hàm thuần, Map/Set và module dùng lại Board/Protocol; Hspec describe/it/shouldBe (Chap8); Network.Socket/bracket và framing TCP (Chap11); async/deadline/cleanup (Chap7). Không thêm dependency, kiểu miền, lệnh wire hoặc logic thắng thua. Giới hạn D-03: chưa nhập FIRE/render diễn biến hai bàn; Ctrl+C rời trận, không có reconnect hoặc sửa fleet đã OK trên server. D-03 đạt yêu cầu nhập đủ năm tàu theo hướng dẫn terminal, xem trước/sửa và gửi PLACE hợp lệ.
## S-02 — Nghiệm thu lõi luật thuần (2026-10-05)

Hồ sơ chi tiết, chuỗi 25 lệnh và kết quả miền đã đối chiếu: [s02_acceptance.md](s02_acceptance.md) (tên file trước đây report_final.md). Bản kiểm tra là working tree trên `Luong_nhap_gui_dat_tau`, nền `4eea8b544a4da77995d451a137dd98b8f0a574c3`; chưa commit thay đổi S-02 tại thời điểm chạy.

```text
stack test --ghc-options=-Werror --test-arguments="--match S-02"
  26 examples, 0 failures
stack test --ghc-options=-Werror
  642 examples, 0 failures (trước sửa nốt fixture BoardSpec)
stack test
  642 examples, 0 failures (đã sửa fixture Board/Rules/Types)
stack test --ghc-options=-Werror --test-arguments="--match A-03"
  26 examples, 0 failures (sau sửa BoardSpec)
stack exec -- ghc -fno-code -fforce-recomp -Wall -Werror -hide-all-packages -package base -package containers -isrc -outputdir .stack-work/s02-core src/Battleship/Rules.hs
  Exit 0; Internal.Fleet, Types, Board, Rules — 4 modules, không server/network
```

S-02 gọi step production từ initialGameState qua PlaceFleet/chờ/Fire Miss/Hit/Sunk/Win và bốn lỗi; assert toàn bộ state cho Fire/lỗi, event order và winner không bị Quit sau kết thúc ghi đè. Fixture chơi hợp lệ không tự gán phase/history; giữ defensive corrupt-state probes với nhãn riêng. Thêm 26 test, bỏ hai fixture Win trong Turn trái bất biến, nên suite tăng 618 → 642. Lần build đầu helper head/tail bị -Werror, đã sửa và chạy lại xanh.

Kỹ thuật đạt; **A/B chưa xác nhận**. Lỗi TCP concurrent QUIT cũ không tái hiện ở đây, chưa được chữa bởi S-02. Log full-suite local ở `.stack-work/s02-test-werror.log` và `.stack-work/s02-test.log`; báo cáo lưu kết quả cần review.

## B-03 — Góc nhìn riêng và lọc bí mật (2026-10-05)

Thực hiện trên working tree `Luong_nhap_gui_dat_tau`, cùng các sửa đổi S-02 chưa commit. GHC 9.10.3, snapshot lts-24.59. Cài đặt `View.viewFor :: PlayerId -> GameState -> PlayerView`; chỉ lấy fleet/history của đúng người nhận, incoming qua shotsReceived, phase và Bool readiness đối thủ. Không copy hình học fleet đối thủ, không tự reveal khi Finished. Giữ nguyên Types và wire v1.

```text
stack test --ghc-options=-Werror --test-arguments="--match B-03"
  15 examples, 0 failures
stack test --ghc-options=-Werror
  Lượt đầu: 657 examples, 0 failures (28.0265 giây trong Hspec)
  Lượt cuối: 657 examples, 0 failures (27.9911 giây trong Hspec)
```

Lượt cuối gồm assertion mới về lỗi đặt tàu chồng lấn chỉ gửi actor và các cập nhật README/architecture/shared_contract. Log local: `.stack-work/b03-test-werror.log` và `.stack-work/b03-test-final.log`. Suite tăng 642 → 657, không bỏ/nới test cũ.

| Phạm vi ViewSpec B-03 | Bằng chứng |
|---|---|
| Chữ ký và trạng thái rỗng | typeRep hàm production khớp ViewFor; P1/P2 chưa có fleet hoặc shots |
| Chưa đặt/đã đặt/chờ/bắt đầu | OwnFleet lấy đúng người; đối thủ chỉ lộ readiness; không có fleet đối thủ |
| Bí mật chưa bắn | Hai viewer × 72 layout hợp lệ (ngang/dọc, dịch trong bàn): toàn PlayerView giống nhau khi chỉ đổi bố trí bí mật; soát riêng từng ô tàu chưa bắn không có trong outgoingShotsView |
| Quan sát trúng/chìm và bỏ cuộc | Hai bố trí có Carrier giống nhau, 12 ô tàu còn lại khác: whole views vẫn bằng nhau trước/sau từng Hit, Sunk Carrier và Quit; sau Quit vẫn còn 12 ô đối thủ bí mật |
| Hai bàn cùng tọa độ | Fleet của mình vẫn thấy đủ 17 ô dù trùng tọa độ bí mật đối thủ; outgoing chỉ có A1 đã bắn. Không dùng phép tìm tọa độ trong Show toàn view để nhầm hai bàn |
| Mọi transition thật đến thắng | Dựng toàn ván bằng production PlaceFleet/Fire cho cả hai winner, soát cả hai góc nhìn ở mọi state; đúng chiều outgoing/incoming, Miss/Hit/Sunk/Win và Finished |
| Ranh giới wire production | applyCommand Rules.step trả frame chính xác: OK/WAITING actor-only; PLACE thứ hai chỉ OK/START/TURN, không chuyển fleet; SHOT/INCOMING chỉ tọa độ đã bắn; lỗi sai lượt/chồng tàu chỉ trả người gửi |

Các fixture chơi dùng Rules.step và Board.placeFleet thật theo S-02. `checkProjection` đối chiếu toàn bộ record PlayerView với dữ liệu công khai được phép thấy, không chỉ kiểm tra thiếu một field. Thay bố trí bí mật mà không đổi quan sát phải giữ nguyên whole view; phép kiểm tra này phát hiện lộ geometry qua field khác.

Đã rà Server.publishTransition: chỉ send các frame Coordinator tạo; Coordinator dùng Protocol.encodeEvent/wireError theo người nhận. Server không serialize GameState; wire v1 không có snapshot nên chọn nhánh "sự kiện đã lọc" của B-03. Các test TCP hiện hữu về PLACE/FIRE/private payload cũng xanh trong full-suite. Không cần sửa Server hoặc đổi giao thức để thêm viewFor.

Căn cứ slide: phép chiếu record/hàm thuần, Maybe cho fleet chưa đặt, Map/Set cho lịch sử và tập ô bí mật, module tách IO, Hspec describe/it/shouldBe (Chap8). B-03 đạt tiêu chí kỹ thuật. S-01/S-02 vẫn còn các xác nhận nhóm đã ghi riêng; không dùng kết quả này thay chữ ký. Lỗi TCP Windows hiếm cũ không tái hiện ở hai lượt B-03, không tuyên bố đã chữa lỗi đó.

## C-04 — Cập nhật trận nguyên tử bằng STM (2026-10-05)

Working tree trên `Luong_nhap_gui_dat_tau`, nền `4eea8b544a4da77995d451a137dd98b8f0a574c3`, đang gồm S-02/B-03/C-04 chưa commit. Snapshot lts-24.59, GHC 9.10.3. Thêm dependency stm cho library/test; Stack build dùng package trong snapshot, không đổi stack.yaml hoặc luật/wire v1.

```text
stack test --ghc-options=-Werror --test-arguments="--match C-03"
  40 examples, 0 failures
stack test --ghc-options=-Werror --test-arguments="--match C-04"
  19 examples, 0 failures (0.0246 giây trong Hspec)
stack test --ghc-options=-Werror
  676 examples, 0 failures (27.9732 giây trong Hspec)
stack test
  Lượt nghiệm thu cuối: 676 examples, 0 failures (28.1020 giây trong Hspec)
```

Lượt cuối bao gồm API STM/server mới, test và tài liệu hợp đồng/protocol đã cập nhật. Log local: `.stack-work/c04-test-first.log` và `.stack-work/c04-test-final.log`; suite tăng 657 → 676 do thêm 19 test, không bỏ hoặc nới test cũ. Lần compile đầu có lỗi indentation của block reader lồng với writer, đã sửa trước các lượt xanh; không có failure runtime ở các lượt nghiệm thu C-04 này.

### Thay đổi và lý do

- Coordinator abstract giữ **đúng một TVar GameState**, hai TQueue (Maybe ByteString). Server tạo Coordinator một lần; bỏ field GameState khỏi Lobby. MVar chỉ quản lý registry, writer đã drain và cờ stopped của lifecycle/lỗi nội bộ; không là nguồn lượt/winner thứ hai.
- `submitPayload`/`submitCommand` là STM action: đọc state → parse/step → encode toàn bộ batch → writeTVar khi luật Right → xếp frame theo người nhận trong cùng atomically. Dùng chung prepare/encode với coordinate/applyCommand thuần, không sao chép luật. Giao dịch tranh chấp phải chạy lại theo state mới, tránh mất update hoặc hai phát trượt cùng tiêu lượt P1 cũ.
- Lỗi parser/luật được biểu diễn bằng accepted = Nothing: chỉ queue lỗi actor-only, **không gọi writeTVar**. Encode lỗi không ghi queue/state. `throwSTM` hoặc retry ở giao dịch bao ngoài rollback cả hai. Sau Finished không gọi step nữa hoặc xếp thêm event, giữ nguyên winner.
- Queue chứa frame đã lọc/encode từ Protocol, không chứa GameState/fleet bí mật. Một writer cho mỗi socket lấy frame trong atomically, rồi gửi sendAll **ngoài STM**. TQueue phù hợp kênh FIFO có một người đọc; không cần khả năng nhân bản người đọc của TChan. Socket chậm không giữ khóa gameplay.
- WELCOME được enqueue đầu khi admission trong STM, xóa frame cũ của slot chưa có socket. Transaction cuối enqueue GAME_OVER rồi Nothing cho cả hai queue; server chờ mọi writer đã admission xử lý marker trước khi cleanup. Admission muộn gặp Finished chờ writer cũ, tránh unwind bracket làm mất phản hồi cuối. Send hỏng đóng đúng socket, submit Quit đúng actor và bỏ các frame còn lại của socket hỏng.

### Bằng chứng 19 test C-04

| Nhóm | Kết quả được kiểm tra |
|---|---|
| State/queue khởi đầu | State duy nhất đúng fixture thật; hai outbox độc lập/rỗng |
| Parser và lỗi luật | Parser không gọi stub unusedCore; tọa độ/sai lượt không đổi toàn GameState, lỗi chỉ actor |
| PLACE đồng thời | Hai fleet được ghi; chỉ một START/Turn P1 mỗi recipient và một WAITING tổng cộng |
| Hai Miss của P1 | 50 race: chỉ một shot vào history, Turn P2; shot còn lại NotYourTurn P2 |
| P1/P2 Miss tranh lượt | 50 race: kết quả khớp đúng một thứ tự tuần tự hợp lệ; P2 chỉ được bắn khi P1 đã đổi lượt |
| Hai Hit/shot trùng | 50 + 50 race: không mất update, batch không xen nhau; cùng tọa độ chỉ ghi một lần rồi AlreadyFired |
| Quit tranh nhau | 50 race: hai recipient cùng một winner/GAME_OVER và một marker, Quit sau kết thúc không ghi đè |
| Ô cuối thắng | P1/P2: state Finished, SHOT/INCOMING WIN, GAME_OVER và marker cùng commit, không TURN sau WIN |
| Encode lỗi và rollback | Batch có frame lỗi giữa các event hoặc wireError không encode được: state/queues không đổi; throwSTM và retry/orElse rollback toàn bộ |
| Admission/framing/writer | WELCOME trước các event mới; LINE_TOO_LONG trước GAME_OVER; có thể commit shot khi cả hai queue chưa đọc |

Năm nhóm race chạy 50 lần = **250 cuộc đua**; barrier STM chờ cả hai worker sẵn sàng trước submit, không dùng MVar/lock quanh gameplay. Snapshot test đọc state và drain hai queue trong cùng atomically để đối chiếu cả batch. Các fixture chơi dựng qua production Rules/Board; sửa nearWin P2 để lấy lượt bằng P1 Miss thật, không gán phase trực tiếp.

Full-suite nghiệm thu lại server/client/TCP hiện có: connect/slot/third client, framing/overlong, concurrent PLACE/FIRE/QUIT, lỗi encode nội bộ, SUNK/WIN/EOF giữ winner, cancel/bind lại, client giữ kết nối và executable. Nguồn Coordinator không import socket hoặc unsafeIOToSTM; sendAll chỉ ở IO writer của Server. `step` và lõi Board/Rules/Types vẫn thuần.

Căn cứ slide đã đối chiếu: Chap6_Syncronization, trang 5, ví dụ readTVar/writeTVar trong atomically để sửa race; Chap5 message passing và shared structure; Chap7 async/supervision; Chap8 module/Hspec; Chap11 networking. Khác với counter trong slide, giao dịch này commit đồng thời cả state trận và queue phản hồi để không có state mới thiếu event hoặc event từ giao dịch chưa commit.

**C-04 đạt tiêu chí kỹ thuật.** Giới hạn MVP: TQueue không có bound; cần chính sách ngắt client chậm/queue giới hạn nếu chạy lâu dưới command flood. Lỗi recv Windows concurrent QUIT hiếm đã ghi trước đây không tái hiện ở các lượt C-04; không coi test xanh là bằng chứng đã xác định/chữa nguyên nhân cũ. Xác nhận S-01/S-02 của nhóm vẫn được ghi riêng, chưa tự ký thay người.

## D-04 — 2026-10-05

Bản kiểm tra: working tree nhánh `Luong_nhap_gui_dat_tau`, nền HEAD `4eea8b544a4da77995d451a137dd98b8f0a574c3`. HEAD nền chưa chứa S-02/B-03/C-04/D-04 chưa commit. Windows/PowerShell, snapshot lts-24.59, GHC 9.10.3; kết quả dưới đây không phải xác nhận của thành viên nhóm.

```text
stack build --ghc-options=-Werror
  Thành công: library, battleship-server, battleship-client.

stack test --ghc-options=-Werror --test-arguments="--match D-04"
  42 examples, 0 failures (lượt kiểm tra trước sửa newline console cuối).

stack test --ghc-options=-Werror
  718 examples, 0 failures
  Finished in 29.7521 seconds (bản D-04 cuối).
```

Log cuối: `.stack-work/d04-full-final.log`; build: `.stack-work/d04-build.log`. D-04 thêm 42 test; toàn suite từ 676 lên 718. Toàn suite cuối bao gồm 66 test D-03, không bỏ các kiểm tra đặt tàu/cancel/chờ quá 10 giây cũ. Ban đầu build -Werror phát hiện `tail` trong fixture mới; đổi thành `drop 1`, không tắt warning.

| Nhóm D-04 | Số test | Bằng chứng |
|---|---|---|
| Parser địa phương | 16 | A1/J10, chữ thường, FIRE/QUIT, whitespace; thiếu/thừa tham số, ngoài bàn/leading zero, non-ASCII/NUL và quá dài |
| Hiển thị thuần | 10 | Danh tính P1/P2, chờ/đến lượt, thắng/thua cho hai lý do; SHOT/INCOMING cho Miss/Hit/Sunk/Win |
| TCP với peer có kịch bản | 13 | Không gửi trước TURN hoặc khi chờ SHOT/TURN; lỗi retry và WrongTurn; bắn lặp địa phương; dòng 300 ký tự bị từ chối rồi nhập lại; Backspace/DEL; Quit/EOF chỉ gửi một lệnh; dòng cuối thiếu newline; EOF và phản hồi sai/quá dài/tọa độ SHOT sai |
| Executable + server/lõi thật | 3 | Một ván P2 thắng: PLACE → chờ → P1 Miss → P2 Miss → P1 Miss → P2 17 Hit/Sunk/Win; K1 và A6 lặp không gửi. Hai case stdin vẫn mở (rỗng hoặc nhập A), chờ 150 ms rồi đối thủ Quit; executable nhận GameOver và exit 0 |

### Kiểm tra terminal Windows thật và lỗi đã sửa

Test pipe ban đầu xanh nhưng console thật lộ lỗi: sau khi nhập A chưa Enter, server đã kết thúc mà client vẫn chờ. Nhấn Enter mới hiển thị GameOver. Chỉ thêm NoBuffering/đổi echo vẫn không đủ trên môi trường này. Đã dùng System.Win32.Console để lưu/khôi phục mode CONIN$, tắt ENABLE_LINE_INPUT và ENABLE_ECHO_INPUT trong phiên chơi; dependency Win32 2.14.1.0 có sẵn trong GHC, chỉ khai báo khi os(windows). Theo [Microsoft Console API](https://learn.microsoft.com/windows/console/getconsolemode), ENABLE_LINE_INPUT khiến ReadFile/ReadConsole chờ carriage return. Console được mở read/write để SetConsoleMode hoạt động; mở read-only ban đầu báo Access denied và đã sửa.

Sau tắt đọc nguyên dòng, decoder CRLF còn giữ Enter raw CR đến khi có phím kế tiếp. withKeyboard đặt noNewlineTranslation trong phiên chơi, xử lý CR/LF và Backspace/DEL trực tiếp, echo tại UI. Bracket khôi phục buffer, echo, newline và console mode; đóng HANDLE CONIN$ riêng, không đóng input/output người gọi cung cấp. Getter newline dùng base GHC.IO.Handle dưới khóa; cần kiểm tra lại khi nâng GHC khỏi bản đã chốt.

Lần cuối chạy server và **hai executable client qua PTY/console** trên localhost port 56275:

1. P1 đặt fleet hàng 1..5, P2 hàng 6..10; hai client nhận đúng danh tính và START/TURN.
2. P1 gõ `J11`, Backspace, `0`, Enter: thành J10, gửi ngay, nhận `Bạn bắn J10: trượt.`; cả hai chuyển sang P2.
3. P2 gõ `fire a1`, Enter: gửi ngay FIRE A1, nhận `Bạn bắn A1: trúng.` và được nhập tiếp; P1 thấy INCOMING và phải chờ.
4. P2 gõ A, chưa Enter. P1 Ctrl+C: P2 nhận `Người chơi 2 thắng ... Bạn thắng!`, tự thoát exit 0; server exit 0. Không cần phím kế tiếp. P1 bị người dùng hủy nên exit 1, không coi là lỗi nghiệm thu.

Một lượt test chạy đồng thời với executable đang mở bị Windows khóa file khi Stack copy; đã đóng hết các phiên thử và chạy suite cuối tuần tự, xanh như trên. Không đổi luật/Types hoặc wire v1; không thêm luật thắng thua vào client. Client chỉ giữ trạng thái nhập và tập tọa độ SHOT đã được server xác nhận; codec thuần trong Protocol, câu chữ tiếng Việt trong Client. Chờ đối thủ/nhập không có timeout 10 giây của request kết nối/PLACE.

Căn cứ slide: ADT/pattern matching/Either cho InputStage, Command, Response và input lỗi; hàm thuần tách parser địa phương/render khỏi IO (Chap8); async quản lý reader/cleanup và truyền exception (Chap7); TQueue/atomically/orElse chờ dữ liệu mạng (Chap6); TCP stream/encode/parse theo giao thức (Chap11). Đặc thù console dùng API nền tảng cho IO bàn phím, không thay kiến thức hoặc luật miền.

**D-04 đạt tiêu chí kỹ thuật.** Chưa render lại hai bàn sau từng nước bắn; không cần fleet bí mật của đối thủ. Runtime được kiểm tra trên Windows; nhánh CPP khác nền tảng chưa được chạy ở Linux/macOS trong môi trường này. Bốn xác nhận S-01 và xác nhận A/B S-02 vẫn chờ riêng. Lỗi recv Windows concurrent QUIT hiếm cũ không tái hiện trong suite D-04, không tuyên bố đã chữa nguyên nhân đó.

## A-04 — 2026-10-05

Working tree nhánh `Luong_nhap_gui_dat_tau`, nền HEAD `4eea8b544a4da77995d451a137dd98b8f0a574c3`; các sửa đổi chưa commit. Snapshot lts-24.59, GHC 9.10.3, Windows/PowerShell.

```text
stack test --ghc-options=-Werror --test-arguments="--match A-04"
  17 examples, 0 failures; 0.0108 giây.
stack test --ghc-options=-Werror
  735 examples, 0 failures; 29.8272 giây.
```

Log: `.stack-work/a04-targeted.log` và `.stack-work/a04-full.log`. A-04 thêm 17 test, không bỏ test cũ; toàn suite tăng từ 718 lên 735.

| Nhóm mới | Test | Phạm vi |
|---|---:|---|
| Bốn góc | 1 | Một fleet hỗn hợp chứa A1, J1, A10 và J10 |
| Fleet hợp lệ | 2 | 50 layout: 25 phép dịch của đội tàu hỗn hợp 6×6 và 25 layout chuyển vị; cả hai hướng, chạm cạnh hợp lệ |
| Trong/ngoài mép | 4 | Mỗi mép trái/trên/phải/dưới có một fleet hợp lệ, rồi dịch Destroyer một ô ra ngoài và kiểm tra lỗi cụ thể |
| Bất biến qua API | 10 | 5 ShipId × 2 hướng × 144 vị trí trong miền 0..11: 1.440 request. Kiểm tra mọi Right; mỗi nhóm phải có ít nhất một fleet được chấp nhận |

`checkInvariants` dùng tập 100 ô A1..J10 ghi theo R-01, độc lập với `Board.inBounds` và `boardSize`; từng tàu có kích thước 5/4/3/3/2, tổng danh sách tọa độ là 17, và bảng đếm có đúng 17 giá trị bằng 1. Bảng đếm phát hiện ô xuất hiện ở nhiều tàu, không lặp thuật toán giao tập của Board. Các fixture chỉ tạo ShipPlacement và gọi smart constructor `placeFleet`; không tự tạo Fleet hoặc dùng shipCells để tính dữ liệu kỳ vọng. Việc tăng độ độc lập của helper cũng áp dụng cho các test A-02/A-03 đang dùng nó.

### Chứng minh phát hiện lỗi biên bằng mutation

Hai bản sao cô lập trong `.stack-work/a04-mutation/`, mỗi bản copy Types, Internal.Fleet, Rules, Board và BoardSpec hiện tại. GHC biên dịch các source này với -Werror, xóa đường tìm source mặc định và không import package battleship-haskell đã cài. Compile log xác nhận Board được lấy từ thư mục mutant. Chỉ chạy `--match "every accepted fleet"`: đây là 10 test mới của A-04, không dựa vào test âm A-02/A-03.

| Cố ý nới kiểm tra | Kết quả | Ô sai được phát hiện |
|---|---|---|
| `column <= boardSize` thành `column <= boardSize + 1` | Exit 1 như dự kiến; 10 examples, 10 failures | Carrier G1..K1 bị chấp nhận, nhưng K1 ngoài tập 100 ô |
| `row <= boardSize` thành `row <= boardSize + 1` | Exit 1 như dự kiến; 10 examples, 10 failures | Carrier A11..E11 bị chấp nhận, nhưng hàng 11 ngoài bàn |

Log từng bản: `.stack-work/a04-mutation/column-plus-one/test.log`, `.stack-work/a04-mutation/row-plus-one/test.log`; script kiểm tra hiện tại: `stack exec -- powershell -NoProfile -File .stack-work/a04-mutation/check.ps1`. Script kiểm tra compiler thành công trước khi công nhận mutation bị bắt, và đối chiếu nội dung Board.hs thật sau thử nghiệm. Thư mục này bị Git ignore; không đưa mã cố ý sai vào source production. Full-suite xanh ở trên chạy với Board thật không thay đổi.

**A-04 đạt tiêu chí kỹ thuật:** các bất biến đội tàu được kiểm tra trên dữ liệu trả về và lỗi nới biên đã thực sự bị test A-04 phát hiện. Căn cứ slide: hàm thuần/Either, kiểm tra ADT và fold trên cấu trúc danh sách/Map; Hspec describe/it/shouldBe theo Chap8. Không thêm dependency hoặc đổi luật/giao thức/production.

## B-04 — 2026-10-05

Working tree nhánh `Luong_nhap_gui_dat_tau`, nền HEAD `4eea8b544a4da77995d451a137dd98b8f0a574c3`; các sửa đổi chưa commit. Snapshot lts-24.59, GHC 9.10.3, Windows/PowerShell.

```text
stack test --ghc-options=-Werror --test-arguments="--match B-04"
  4 examples, 0 failures; 0.0072 giây.
stack test --ghc-options=-Werror
  739 examples, 0 failures; 29.9575 giây.
```

Log: `.stack-work/b04-targeted.log` và `.stack-work/b04-full.log`. B-04 thêm 4 test Hspec: hai chuỗi trong RulesSpec và cùng hai chuỗi trong ViewSpec. Chuỗi P1 thắng có 80 lệnh, chuỗi P2 thắng có 81 lệnh; mỗi chuỗi gồm 59 lần bị từ chối. Tổng dữ liệu là 161 lệnh với 118 lỗi, không phải 161 test Hspec độc lập.

| Ca lỗi | Kỳ vọng cụ thể |
|---|---|
| FIRE khi chưa ai đặt tàu hoặc mới một bên đặt | `FleetsNotReady`, kiểm tra cả P1/P2 |
| FIRE sai lượt, gồm cả tọa độ đã bắn | `NotYourTurn` kèm người đang có lượt |
| FIRE ngoài bàn khi đúng lượt | `InvalidCoordinate` kèm tọa độ: 0, âm, 11, minBound/maxBound ở hai trục; kiểm tra cả P1/P2 |
| Bắn lặp ô Miss, Hit hoặc Sunk khi đúng lượt | `AlreadyFired` kèm tọa độ; ô Hit cũ vẫn không được bắn lại sau khi tàu chìm |
| Lệnh sau thắng | `GameAlreadyFinished` cho cả hai người: FIRE ô thắng/ô mới/ngoài bàn, PLACE hợp lệ/rỗng và QUIT |

Các bước hợp lệ xen giữa lỗi tiếp tục đến thắng thật, đối chiếu toàn trạng thái phát bắn, phase và danh sách event. Dữ liệu kỳ vọng dùng đội tàu 5/4/3/3/2 và tọa độ đã ghi theo hợp đồng; trạng thái đầu vào được dựng bằng production `step`, không gán giả phase/history/fleet. Mỗi lỗi đối chiếu `Left` chính xác và toàn bộ `GameState` được caller giữ nguyên, không chỉ kiểm tra phase hoặc số ô bắn. Vì `step` thuần trả `Left` không kèm state mới, đây là kiểm tra hợp đồng caller giữ giá trị cũ; kiểm tra rollback STM thuộc C-04.

ViewSpec dùng chung bảng lệnh và trace với RulesSpec, kiểm tra đầy đủ `PlayerView` cho cả hai người trước và sau từng lệnh. Khi có lỗi, hai góc nhìn không thay đổi; mọi ô tàu đối thủ chưa bắn vẫn không có trong dữ liệu bàn đối thủ. Sau kết thúc, người thua vẫn chưa bắn 17 ô tàu người thắng và cả 17 ô tiếp tục được giấu, nên kiểm tra bí mật ở trạng thái thắng không bị rỗng.

**B-04 đạt tiêu chí kỹ thuật:** mọi nhóm lỗi có kỳ vọng cụ thể, state và góc nhìn được kiểm tra xuyên suốt hai ván, toàn suite xanh với warning coi là lỗi. Dùng ADT/pattern matching/Either và hàm thuần để mô phỏng chuỗi lệnh; Hspec `describe`/`it`/`shouldBe` theo cách kiểm thử module ở Chap8.

## C-05 — 2026-10-05

Working tree nhánh `Luong_nhap_gui_dat_tau`, nền HEAD `4eea8b544a4da77995d451a137dd98b8f0a574c3`; các sửa đổi chưa commit. Windows/PowerShell, snapshot lts-24.59, GHC 9.10.3.

```text
stack test --ghc-options=-Werror --test-arguments="--match C-05"
  35 examples, 0 failures; 9.8214 giây.
stack test --ghc-options=-Werror --test-arguments="--match consistent"
  2 examples, 0 failures; 10.5276 giây.
stack test --ghc-options=-Werror
  774 examples, 0 failures; 56.5487 giây.
```

Log cuối: `.stack-work/c05-targeted-fixed.log`, `.stack-work/c05-quit-race-fixed.log`, `.stack-work/c05-full-fixed.log`. Toàn suite tăng từ 739 lên 774: 10 test Coordinator và 25 test TCP mới. Bộ lọc consistent chạy 50 race STM C-04 và 50 phiên QUIT đồng thời TCP C-02; không coi 100 vòng lặp này là 100 test Hspec riêng.

| Nhóm mới | Test Hspec | Kiểm chứng |
|---|---:|---|
| Outbox đặt tàu/bắt đầu | 2 | Cả thứ tự P1/P2 đặt trước; OK/WAITING chỉ người đặt, OK cuối chỉ người đặt cuối, START/TURN đúng một lần cho cả hai |
| Outbox phát bắn | 2 | SHOT chỉ người bắn, INCOMING chỉ đối thủ; đối chiếu nguyên danh sách frame, không có payload Fleet/GameState |
| Kết thúc STM | 6 | Hai người × chưa đặt/đang chờ/đang chơi; Quit chỉ đổi phase, GAME_OVER trước marker mỗi queue; Quit/FIRE/overlong/admission đến muộn không đổi winner hoặc thêm frame |
| TCP riêng tư | 2 | Cả thứ tự đặt trước; peer chưa đặt không nhận OK/WAITING hoặc lỗi FIRE của người kia; sau đó START và SHOT/INCOMING đúng FIFO |
| TCP ngắt kết nối | 18 | Hai người × ba giai đoạn × EOF/đóng hẳn/EOF kèm dòng thiếu LF; đối thủ nhận đúng GAME_OVER OPPONENT_LEFT rồi EOF, server thoát và cùng cổng mở lại được |
| Chưa có P2 | 2 | P1 EOF trước/sau đặt tàu đều kết thúc accept đang chờ, không đợi người thay thế |
| Cả hai rời cùng lúc | 1 | 20 phiên đóng đồng thời; server thoát, listener giải phóng và mở lại được |
| Client không đọc | 1 | P1 giữ socket mở sau WELCOME, giảm receive buffer rồi gửi 50.000 UNKNOWN; không đọc/không gửi Quit/EOF. Watchdog send xử lý P1 rời trận, P2 chỉ nhận GAME_OVER rồi EOF; server thoát và cổng mở lại được |
| Dữ liệu dư sau Quit | 1 | 10 phiên, mỗi phiên gửi 2.000 QUIT trong một write; cả hai nhận GAME_OVER trước EOF, không có phản hồi dư sau kết thúc |

### Lỗi thật đã tái hiện và sửa

Lượt full-suite trước sửa: `.stack-work/c05-full.log`, 773 examples/1 failure, 33.2571 giây. Lỗi C-02 QUIT đồng thời cũ tái hiện tại P1 GAME_OVER: `Network.Socket.recvBuf: invalid argument`. Thêm hồi quy gửi 2.000 QUIT để tạo dữ liệu chưa đọc khi kết thúc; `.stack-work/c05-unread-before.log` thất bại ngay với cùng IOException (bộ lọc unread còn chọn hai test Types có tên unready: tổng 3 examples/1 failure).

Server trước đó đóng cả hai chiều sau khi writer gửi xong, dù reader có thể còn dữ liệu TCP chưa đọc. Đóng như vậy có thể reset kết nối và mất phản hồi cuối. Sửa đúng luồng kết thúc socket: writer gửi hết FIFO, shutdown chiều gửi để FIN đi sau GAME_OVER; reader hiện hữu đọc bỏ input còn lại bằng buffer 4096 byte, không gọi parser/step; writer chờ readerDone tối đa 200 ms rồi shutdown Both/close để đánh thức recv đang chặn. MVar readerDone chỉ báo vòng đời IO, không giữ GameState. Client không đọc vẫn chịu watchdog send 2 giây hiện có; send hỏng đóng ngay và submit Quit đúng actor. Cleanup bắt buộc không phụ thuộc peer chịu đóng socket.

Sau sửa, hồi quy unread: `.stack-work/c05-unread-after.log`, 3 examples/0 failures, 2.1385 giây; 10 phiên trong test hồi quy đều qua. Sau đó chạy lại toàn C-05, ca QUIT đồng thời và full-suite cuối như trên. Không bỏ/skip hoặc nới kỳ vọng GAME_OVER của test cũ, không bắt IOException ở phía đọc để coi lỗi là thành công. Chưa kiểm tra runtime Linux/macOS trong môi trường này.

Lượt C-05 đầu mất 81.6539 giây nhưng không treo: đo từng bước trong `.stack-work/c05-close-timing.log` xác định thao tác connect vào cổng đã đóng trên Windows mất khoảng 2 giây/lần. Server đã thoát trước phép dò này. Các test C-05 cuối kiểm tra mở lại cùng cổng thay vì lặp cả hai phép dò; vẫn kiểm tra đầy đủ EOF và wait server. Log đo tạm không phải benchmark; mã in thời gian đã được bỏ. Lần compile đầu bắt warning biến coordinate trùng tên hàm import; đổi thành position, giữ -Werror.

Cơ chế định tuyến Coordinator của C-04 đã đáp ứng C-05: một TVar GameState, hai outbox riêng, phản hồi lỗi chỉ actor và sự kiện đã lọc bởi Protocol; không serialize GameState. C-05 giữ cơ chế đó, sửa luồng đóng TCP trong Server và chỉnh mô tả outbox ở Protocol/architecture cho đúng cách hoạt động thật. Không thêm dependency hay luật thắng thua trong IO; mọi EOF/lỗi socket trước kết thúc dùng Quit qua Rules.step, mọi lệnh đến sau Finished không thay người thắng.

**C-05 đạt tiêu chí kỹ thuật trên Windows:** gửi đúng người, người đặt trước được chờ, cả hai sẵn sàng được START, ngắt kết nối có kết quả rõ và dọn socket/worker/listener. Áp dụng STM cho commit state/event (Chap6), MVar cho thông báo reader kết thúc, async/bracket/finally cho vòng đời luồng (Chap5/Chap7), và phân biệt chiều gửi/nhận của TCP với codec theo dòng (Chap11). TQueue vẫn có giới hạn MVP đã ghi ở C-04: chưa giới hạn dung lượng cho command flood kéo dài.

## D-05 — 2026-10-05

Working tree nhánh `Luong_nhap_gui_dat_tau`, nền HEAD `4eea8b544a4da77995d451a137dd98b8f0a574c3`; các sửa đổi chưa commit. Windows/PowerShell, snapshot lts-24.59, GHC 9.10.3.

```text
stack build --ghc-options=-Werror
  Library và hai executable biên dịch thành công sau bổ sung renderer.
stack test --ghc-options=-Werror --test-arguments="--match D-05"
  20 examples, 0 failures; 0.3656 giây.
stack test --ghc-options=-Werror
  794 examples, 0 failures; 56.9165 giây.
```

Log: `.stack-work/d05-build.log`, `.stack-work/d05-targeted-final.log`, `.stack-work/d05-full.log`. Full-suite là bản cuối gồm thay đổi CLI, renderer và test executable. D-05 thêm 20 test, không bỏ test D-03/D-04/C-05 cũ. Helper đọc transcript ban đầu sai cú pháp operator section `++`; đã sửa dấu ngoặc và chạy lại, không tắt warning.

| Nhóm | Test Hspec | Phạm vi |
|---|---:|---|
| Bàn ban đầu | 1 | Đúng 10 hàng/tọa độ A..J, 100 ô đối thủ là ?, fleet mình hiện đúng CV/BB/CR/SB/DD |
| Ô nhận sự kiện | 8 | Hai chiều SHOT/INCOMING × Miss/Hit/Sunk/Win tại J10; đúng o/X/#/*, không đổi fleet hoặc bảng còn lại, không suy ra lượt từ kết quả bắn |
| Lỗi giao thức | 1 | Mọi WireError giữ nguyên PlayerView và cả hai bàn, kể cả khi đã có lịch sử bắn |
| Oracle góc nhìn thật | 4 | Hai người xem × hai chuỗi B-04 đến thắng; chỉ fold Response được route cho người xem. Sau mỗi lệnh thành công/lỗi, toàn PlayerView bằng View.viewFor của state thật, số ? bằng số ô chưa bắn và bảng mục tiêu không có mã tàu |
| CLI thân thiện | 5 | --play với port 0/65536/abc và port đơn 0/65536 đều thất bại trước kết nối |
| Hai executable + server thật | 1 | Client P1 dùng [PORT], P2 dùng --play [PORT]. Chỉ nhập tọa độ/hướng, GUI và tọa độ bắn; sửa tàu vượt biên, K1 và A6 lặp; cả hai Miss rồi P1 đủ 17 Hit/Sunk/Win. Kiểm tra bảng cuối, bí mật, thắng/thua và cả hai exit 0 |

Client giữ PlayerView từ fleet mình đã được chấp nhận và các Response đã lọc, không giữ GameState hoặc fleet đối thủ. Hai Map lịch sử là dữ liệu renderer và nguồn kiểm tra bắn lặp; bỏ Set ô bắn phụ trong phiên chơi. renderBoards thuần, chỉ nhận PlayerView; renderGrid được dùng chung với preview, giữ test preview D-03 hiện có. Các ô chưa bắn luôn ?, cả sau SUNK/kết thúc. # chỉ đánh dấu phát làm chìm, * phát thắng; các Hit cũ không bị gán lại tàu hoặc thay hình.

### Hai terminal/console Windows thật

Chạy executable đã build bằng ba phiên PTY trên localhost port **57745**: server, client [PORT] và client --play [PORT]. Không thay stdin bằng file/pipe cho lượt này.

1. P1 nhập J10 H cho Carrier: báo vượt mép và hỏi lại; sửa A1 H, đặt các tàu còn lại hàng 2..5 rồi GUI. P1 nhận danh tính và chờ; hai bàn hiện cạnh nhau, toàn mục tiêu là ?.
2. P2 đặt hàng 6..10 rồi GUI; nhận đúng danh tính, START/TURN P1. Bàn mình P2 hiện fleet ở hàng 6..10, mục tiêu vẫn ?.
3. P1 gõ K1: báo lỗi, vẫn nhập được. Gõ J11, Backspace, 0, Enter: thành J10, gửi ngay và trượt, chuyển P2. P2 chỉ nhập J10, cũng trượt, chuyển về P1. Ô J10 hiện o trên bảng mục tiêu người bắn và bàn mình người nhận.
4. P1 nhập A6 trúng; nhập A6 lại bị chặn tại client, rồi tiếp tục B6..E6, hàng 7..9 và A10/B10. Hiển thị đủ bốn SUNK và phát WIN; cả hai bàn cập nhật sau từng sự kiện. Không gõ PLACE/FIRE hoặc mã người chơi trong phiên.
5. Bảng cuối P1 có X/#/* trên 17 ô đã bắn ở hàng 6..10 và o tại J10; bảng mục tiêu P2 chỉ có o tại J10, 99 ô còn lại vẫn ?. Fleet P1 chưa bị bắn tiếp tục bị giấu cả sau thắng. Thông báo Bạn thắng!/Bạn thua. ở cuối. **Cả hai client và server exit 0.**

README có hướng dẫn ba terminal và chú giải ký hiệu; ClientMain hỗ trợ không tham số/[PORT]/--play/--place cho trận đầy đủ. Hàm thuần/pattern matching trên Response/PlayerView theo ADT và lập trình hàm; tách renderer khỏi codec/IO theo Chap8, giữ reader async và hàng đợi sự kiện của D-04 theo Chap6/Chap7, TCP theo Chap11. **D-05 đạt tiêu chí kỹ thuật trên Windows**; runtime Linux/macOS chưa được kiểm tra trong môi trường này.

## S-03 — 2026-10-05

Hồ sơ đầy đủ tại [s03_acceptance.md](s03_acceptance.md), log được lưu lâu dài tại [demo/s03](demo/s03/README.md). Working tree nhánh Luong_nhap_gui_dat_tau, HEAD nền 4eea8b544a4da77995d451a137dd98b8f0a574c3, 27 file source/config được định danh bằng SHA-256; không coi HEAD nền là bản chứa các thay đổi chưa commit.

Đã chạy stack clean (exit 0), stack build --ghc-options=-Werror (biên dịch lại 9 module và hai Main, exit 0), stack test --ghc-options=-Werror (**794 examples, 0 failures**, 56.6764 giây). Build/test log đặt trong docs/demo/s03, không bị Stack clean hoặc .gitignore xóa/ẩn. Sau build mở server production và hai client PTY Windows thật trên port 58267; không stub, không input pipe/file.

Hai fleet mới gồm cả ngang/dọc và các mép. Thử đặt Carrier vượt biên, K1 và B1 bắn lặp rồi sửa được; sáu lần đổi lượt bằng Miss, Hit/Sunk giữ lượt. P1 thắng I2 sau 20 phát (3 Miss, 12 Hit, 4 Sunk, 1 Win); P2 có 5 phát (3 Miss, 2 Hit). Hai client và server đều exit 0. Log thô từng chunk cùng input/timestamp/exit được giữ tại raw_console.json; bản text chỉ bỏ ANSI và chuẩn hóa newline.

verify_demo.ps1 đã chạy Passed true: source hash khớp, 25 phát bắn đúng thứ tự/người đang có lượt, 6 chuyển lượt, 54 snapshot hai bàn, 10.800 ô được kiểm tra từ lịch sử sự kiện. Mọi ô đối thủ chưa bắn vẫn ? sau mỗi snapshot, gồm 15 ô tàu P1 còn giấu đối với P2 cả sau kết thúc. Các oracle đội tàu/kết quả không được dùng làm trạng thái server.

Phát hiện một vấn đề trình bày P3: thông báo kết thúc P1 dài 81 ký tự, wrap/repaint trên console 80 cột làm đuôi c. tách trong log. Ghi task **R9-S03-01** tại [round9_fixes.md](round9_fixes.md) cho D/C kiểm tra lại ở Đợt 9; không thay renderer trong lượt nghiệm thu này. Không phát hiện lỗi luật/lộ tàu/mạng chặn ván. **Kỹ thuật đã hoàn tất, S-03 chưa đủ tiêu chí xong vì chưa có các xác nhận thật A/B/C/D/R**; bảng và mẫu xác nhận nằm trong hồ sơ, không ký thay thành viên.

## A-05 — 2026-10-05

Đối chiếu [S-03](s03_acceptance.md) và [task Đợt 9](round9_fixes.md): không có lỗi đặt tàu đã ghi còn mở. Carrier bắt đầu J10 H bị từ chối đúng, sửa J1 V thành công; lỗi R9-S03-01 thuộc hiển thị terminal, không thuộc Board.

Rà mã phía D (`Protocol.parseCoord`, `parseCommand`, `Client.parsePlacementInput`) với `Board.shipCells`/`placeFleet`: tọa độ wire dùng cột trước/hàng sau, hàng 10 được đọc trọn; H tăng cột, V tăng hàng. Parser kiểm tra token, Board kiểm tra toàn bộ chiều dài; client dùng cùng parser/Board sau khi chuẩn hóa input thân thiện. Không phát hiện bất đồng với hợp đồng. Đây là review mã kỹ thuật; **chưa có xác nhận trực tiếp của thành viên D**, không ghi thay chữ ký nhóm.

Thêm **đúng một test Hspec** tại `BoardSpec.a05Spec`: parse hai lệnh PLACE đủ năm tàu, chỉ khác DD=I10:H/V. Với H, đối chiếu toàn bộ placements và Fleet: DD chiếm chính xác I10/J10, đủ 17 ô trong bàn và không chồng. Với V, parser vẫn nhận tọa độ bắt đầu hợp lệ nhưng Board trả chính xác `ShipOutOfBounds Destroyer (Coord 9 11)`. Kỳ vọng được ghi tường minh, không gọi shipCells để tính oracle. Test nối parser thật với smart constructor thật, bắt nhầm trục/hàng hai chữ số và nhầm biên bao gồm J10; không chỉ lặp lại test hình học trực tiếp cũ.

```text
stack test --ghc-options=-Werror --test-arguments="--match A-05"
  1 example, 0 failures; 0.0009 giây.
stack test --ghc-options=-Werror
  795 examples, 0 failures; 56.9805 giây; exit 0.
```

Log: `.stack-work/a05-targeted.log`, `.stack-work/a05-full.log`. Working tree nhánh `Luong_nhap_gui_dat_tau`, HEAD nền `4eea8b544a4da77995d451a137dd98b8f0a574c3`; thay đổi chưa commit. Không sửa production Board/parser, kiểu/chữ ký, luật hoặc wire v1; không thêm dependency. Không còn lỗi đặt tàu được ghi tại S-03; phần kiểm chứng kỹ thuật A-05 hoàn tất, review trực tiếp với D còn chờ.

Giữ nguyên log và manifest SHA-256 của demo S-03 như bằng chứng lịch sử. BoardSpec đã thay đổi sau demo vì thêm A-05, nên chạy verify_demo.ps1 trên working tree mới sẽ báo hash không khớp; không cập nhật hash cũ để gán demo trước đó cho phiên bản mới.

## B-05 — 2026-10-05

Rà [hồ sơ S-03](s03_acceptance.md) và [task Đợt 9](round9_fixes.md): không có lỗi lượt, thắng hoặc riêng tư được ghi còn mở. R9-S03-01 là wrap thông báo cuối trên terminal, thuộc D; không phải lỗi luật hoặc lộ tàu.

Rà `Rules.step`, các constructor Event và `View.viewFor`: FleetAccepted không mang đội tàu, ShotResolved chỉ mang tọa độ đã bắn/kết quả, TurnReady và GameEnded khớp phase mới. Miss chuyển lượt, Hit/Sunk giữ lượt, Win kết thúc không có TurnReady tiếp theo. View chỉ có fleet của chính người xem, hai lịch sử bắn và cờ sẵn sàng của đối thủ; không lấy geometry đối thủ. Không phát hiện lỗi cần sửa trong production Rules/View.

Thêm **4 test Hspec** tại `ViewSpec.b05Spec`, dùng lõi production và helper/trace hiện có:

- Hai test, lần lượt P1/P2 thắng: với cả hai người xem, bắt đầu từ PlayerView rỗng được ghi tường minh, cập nhật bằng từng Event rồi so sánh toàn record với viewFor sau mỗi lệnh. Bao gồm đặt tàu, chờ, bắt đầu, lỗi, Miss/Hit/Sunk/Win và lệnh sau kết thúc. Reducer chỉ diễn giải event; FleetAccepted của mình dùng PLACE đã biết, của đối thủ chỉ đổi readiness. Không dùng GameState để dựng góc nhìn kỳ vọng hoặc tính lại kết quả bắn/lượt/thắng. Lệnh lỗi giữ góc nhìn trước và phải đúng lỗi trong bảng B-04.
- Hai test, lần lượt P1/P2 xem: chạy song song hai ván có Carrier giống nhau nhưng 12 ô của bốn tàu còn lại khác hoàn toàn. Qua đặt tàu, Hit/Sunk Carrier và Quit, toàn danh sách Event và toàn PlayerView của người xem phải giống nhau sau từng bước. Xác nhận hai fleet chỉ chung đúng 5 ô Carrier, mỗi bên còn 12 ô tàu chưa bắn sau kết thúc; kỳ vọng lịch sử ghi tường minh chỉ có bốn Hit và một Sunk. Nếu làm lộ tọa độ hoặc dữ liệu phụ phụ thuộc đội tàu bí mật, kiểm tra toàn record/event sẽ thất bại.

```text
stack test --ghc-options=-Werror --test-arguments="--match B-05"
  4 examples, 0 failures; 0.0044 giây.
stack test --ghc-options=-Werror
  799 examples, 0 failures; 56.6438 giây; exit 0.
```

Log: `.stack-work/b05-targeted.log`, `.stack-work/b05-full.log`. Nhánh `Luong_nhap_gui_dat_tau`, HEAD nền `4eea8b544a4da77995d451a137dd98b8f0a574c3`; thay đổi chưa commit. Không thêm network/IO/STM vào Rules hoặc View, không thay contract/luật/wire và không thêm dependency. **B-05 đạt tiêu chí kỹ thuật:** không còn lỗi luật/riêng tư được ghi tại S-03 và có test phòng ngừa rò bí mật/không nhất quán event-view. Test tự động không thay xác nhận nhóm S-03 còn chờ; log/hash demo cũ được giữ nguyên, ViewSpec cũng đã thay đổi sau demo.

## C-06 — 2026-10-05

Rà test C-04/C-05 và Server: đã có rollback/race STM và ngắt kết nối TCP, nhưng race bắn khác người qua TCP mới chạy một phiên. C-06 bổ sung kiểm tra lặp với lượt P1 và P2, đối chiếu chính xác state/outbox và chứng minh phát bị từ chối chưa được ghi. Không phát hiện lỗi production mới; không sửa `Server.hs` trong lượt này.

Thêm **12 test Hspec** tại `CoordinatorSpec.c06Spec`:

| Nhóm | Test | Lặp trong mỗi lần chạy | Kỳ vọng |
|---|---:|---:|---|
| Hai người bắn đồng thời, lượt P1/P2 | 2 | 100 race STM/test = 200 | Chỉ người đến lượt có thêm một Hit; toàn GameState còn lại giữ nguyên. So sánh nguyên hai outbox với hai thứ tự tuần tự hợp lệ, một ERROR đúng người, không có frame dư/xen giữa batch |
| Hai client production gửi FIRE qua TCP | 2 | 20 phiên/test = 40 | Một SHOT, một INCOMING, TURN giữ nguyên và ERROR đúng người. Sau Miss chuyển lượt, tọa độ từng bị từ chối phải bắn Hit lần đầu, không bị AlreadyFired. Quit cuối, cả hai GAME_OVER/EOF và server thoát |
| Người đã đặt tàu rời đi khi chờ; rời đi sau Hit giữa trận | 8 | Hai người × hai giai đoạn × EOF/đóng hẳn × 5 phiên = 40 | Người còn lại nhận đúng GAME_OVER OPPONENT_LEFT rồi EOF. Với half-close, người rời cũng nhận kết quả/EOF. Chờ server kết thúc thành công, không chỉ hủy worker test để coi là sạch |

Chọn phát Hit cho race khác người vì Hit giữ lượt: bất kể lệnh nào được xử lý trước, đúng một lệnh hợp lệ. Nếu dùng Miss, lượt có thể chuyển trước khi lệnh đối thủ chạy và cả hai được chấp nhận đúng luật; không đặt kỳ vọng sai hoặc sửa luật để ép chỉ một lệnh thành công.

Dùng chung gate cho hai worker: cả hai báo đã tới rồi mới mở gate; không dùng sleep để đoán thời điểm tranh chấp, không thêm khóa ngoài STM. Helper test `concurrentlyAtGate` được tách từ `concurrentlySubmit` để dùng cho cả STM và TCP; socket IO chạy sau khi rời giao dịch gate. Hai outbox được đọc cùng GameState trong một snapshot nguyên tử. Kỳ vọng state/frames STM được ghi độc lập bằng Hit và các wire literal, không lấy output applyCommand làm oracle. `Right True` từ submit chỉ nghĩa phiên còn chạy, không nghĩa lệnh được luật chấp nhận; state và ERROR/SHOT mới là bằng chứng chấp nhận/từ chối.

Các helper đọc socket có watchdog/timeout 10 giây và chờ server cũng có timeout 10 giây; EOF được kiểm tra sau frame cuối để phát hiện thông báo thừa. Full-suite giữ các test C-05 mở lại cùng cổng, ngắt kết nối chưa đặt tàu, EOF thiếu LF, dữ liệu dư sau Quit và client không đọc.

```text
stack test --ghc-options=-Werror --test-arguments="--match C-06"
  12 examples, 0 failures; 16.8988 giây.
stack test --ghc-options=-Werror
  811 examples, 0 failures; 73.7474 giây; exit 0.
```

Log: `.stack-work/c06-targeted.log`, `.stack-work/c06-full.log`. C-06 chạy lại trong full-suite: tổng hai lượt là 400 race STM, 80 phiên race TCP và 80 phiên ngắt kết nối C-06. Không tính mỗi vòng lặp là một test Hspec riêng. Lần compile đầu -Werror bắt kết quả `[()]` bị bỏ trong do-block gửi TCP; đã ghi `_ <-` tường minh rồi chạy lại, không tắt warning hoặc nới kỳ vọng.

Nhánh `Luong_nhap_gui_dat_tau`, HEAD nền `4eea8b544a4da77995d451a137dd98b8f0a574c3`; thay đổi chưa commit. Không đổi contract, gameplay, dependency hoặc đưa IO mạng vào STM/lõi thuần. **C-06 đạt tiêu chí kỹ thuật trên Windows:** test đồng thời qua lặp lại, kết quả/state/thông báo khớp và các phiên ngắt kết nối kết thúc sạch. Chưa chạy runtime Linux/macOS; kết quả tự động không thay xác nhận nhóm S-03 còn chờ. Giữ nguyên log/hash demo S-03 như bằng chứng lịch sử; CoordinatorSpec đã thay đổi sau demo.

## D-06 — 2026-10-05

**Đạt tiêu chí kỹ thuật trên Windows.** Hướng dẫn tái hiện trong [README](../README.md) và [d06_demo.md](d06_demo.md); toàn bộ artifact tại [demo/d06](demo/d06/README.md).

### Checkout thực sự sạch

Working tree gốc còn thay đổi chưa commit, nên không dùng clone HEAD nền cũ để tuyên bố đã kiểm tra D-06. Sao chép đúng 57 file tracked/untracked không bị ignore sang repository snapshot độc lập, commit cục bộ `68418d6d00368ce5f182f4a1e11289ffcdf03311`, tạo `source.bundle` rồi clone bundle vào `.stack-work/d06-validation-20261005/checkout`. Tác giả snapshot ghi rõ Codex D-06 snapshot; không sửa index, nhánh, HEAD hoặc remote của repository gốc.

Git status trước build rỗng, không có .stack-work trong checkout mới. Build log cho thấy cả 9 module và hai Main được biên dịch/link lại. Cache compiler/dependency Stack dùng chung vẫn có thể được dùng lại; đây là kiểm tra package từ checkout sạch, không phải cài lại toolchain từ máy trống. Snapshot dùng LTS 24.59/GHC 9.10.3, Stack 3.11.1. Bundle 186.405 byte, Git bundle verify thành công; SHA-256 ở checkout.json. Clone này cũng sạch sau build/test/demo; 57 source hash không đổi.

```text
# Tại checkout snapshot, trước demo:
stack build
  Exit 0, biên dịch lại thư viện và hai executable.
stack test
  815 examples, 0 failures; 74.6259 giây; exit 0.
# Tại cùng checkout, kiểm tra lệnh lọc README sau demo:
stack test --ghc-options=-Werror --test-arguments="--match D-06"
  4 examples, 0 failures; 0.6240 giây; exit 0.
```

Log build/test/targeted và trạng thái/hash đặt tại demo/d06, bên ngoài checkout build để không làm bẩn nó. Bundle chứa phiên bản source/hướng dẫn trước khi thêm kết quả cuối và log D-06; các file code/config chạy demo không thay đổi sau tạo snapshot. HEAD nền repository gốc vẫn `4eea8b544a4da77995d451a137dd98b8f0a574c3`; đó không phải commit chứa D-06. Bundle là artifact tái hiện thật, không cần pull những thay đổi chưa push.

### Bốn test đầu cuối mới

IntegrationSpec khởi chạy `battleship-server` và `battleship-client` từ PATH môi trường Stack. Không dùng server thư viện/stub cho D-06; port 0 được đọc từ startup executable. Collector stdout/stderr chạy đồng thời để bảng không làm đầy pipe, đọc stdout theo ký tự vì prompt đặt tàu chưa có LF. Mỗi input được gửi sau prompt hoặc phản hồi tương ứng; không đóng stdin sớm hoặc nạp sẵn toàn bộ kịch bản.

- Trận mixed fleet mới P2 thắng: sửa J10 V vượt biên, K1/A01 sai và C2 bắn lặp; Hit giữ lượt, các Miss chuyển lượt, đủ bốn Sunk và H4 Win. Kiểm tra cả hai client/server exit 0, stderr rỗng, hai bảng cuối đúng số ô chưa bắn, không có ID tàu trên bảng mục tiêu; 16 ô tàu P2 chưa bị P1 bắn tiếp tục được giấu cả sau P1 thua.
- Client đầu bị đóng khi đã GUI nhưng chưa có người thứ hai: server tự thoát, không treo accept. Khi chưa có đối thủ kết nối không đòi một thông báo tới socket không tồn tại.
- P1 đóng giữa trận: P2 nhận thắng do bỏ cuộc và exit 0, server exit 0.
- P2 đóng giữa trận: P1 đang nhập dở J với stdin vẫn mở cũng nhận thắng và exit 0, không phải Enter/EOF mới kết thúc. Process bị terminate được chờ kết thúc nhưng không đòi exit 0.

Full-suite gồm cả C-05/C-06 kiểm tra hai socket đang chờ đặt tàu, ngắt khi chơi, mở lại cùng port, EOF thiếu LF, client không đọc và lệnh đồng thời. Helper test có timeout và cleanup process trong finally, không thêm dependency hoặc thay luật/giao thức. Lượt -Werror ban đầu bắt dùng head; đổi thành take 1. Lượt runtime đầu có một timeout do test chờ sai câu hiển thị ("Đang chờ đối thủ đặt tàu." thay vì "Đang chờ đối thủ."); đã sửa kỳ vọng đúng renderer, không nới timeout. Nhãn lỗi của helper dùng ASCII/show để Hspec trên console Windows không che nguyên nhân bằng lỗi encode Unicode. Trước snapshot, targeted tại working tree gốc cũng đạt 4/0, 0.7288 giây.

### Trận tương tác thật từ checkout sạch

Ba phiên PTY chạy `stack exec battleship-server -- 0`, client với port **49754** và `--play 49754`. Chỉ nhập hướng/tọa độ/GUI/SUA; không input file/pipe hoặc gõ wire thô. Đội tàu được chọn khác cả S-03 và test D-06:

| Tàu | P1 | P2 |
|---|---|---|
| CV | B6 H | E2 V |
| BB | J2 V | F10 H |
| CR | D8 H | B1 H |
| SB | A1 V | J6 V |
| DD | H9 V | A9 H |

P1 thử H10 H cho CV, đọc lỗi rồi sửa B6 H. Đặt DD ban đầu G9 H, nhìn preview rồi SUA DD; thử J10 V sai, sửa H9 V và GUI. P2 GUI sau; đúng hai danh tính, chờ/bắt đầu/lượt. P1 nhập K0 sai, rồi gõ E11, hai Backspace và 2/Enter thành E2 Hit. Không gửi E11 lên server. P2 thử B6 lặp sau Hit: bị chặn và vẫn nhập được.

P1 E2 Hit/J10 Miss → P2 B6 Hit/J10 Miss → P1 E3 Hit/I9 Miss → P2 A1 Hit/J9 Miss → P1 E4 Hit/I8 Miss → P2 bắn C6/D6/E6/F6, J2/J3/J4/J5, D8/E8/F8, A2/A3, H9/H10. Các bước cuối nhập từng ô sau khi đã quan sát prompt và kết quả, không nạp cả danh sách trước. F6/J5/F8/A3 là bốn Sunk, H10 Win. Tổng **25 phát**, **5 đổi lượt**, P2 thắng: P1 6 phát (3 Hit/3 Miss), P2 19 (12 Hit/2 Miss/4 Sunk/1 Win). **Cả ba exit 0.**

`verify_demo.ps1` đã đối chiếu snapshot/bundle/source hash, thứ tự lượt và SHOT/INCOMING, mọi hàng của 54 snapshot hai bàn: **10.800 ô**, Passed true. P1 cuối có 94 ô mục tiêu chưa bắn, gồm **14 ô tàu P2 vẫn giấu**; P2 có 81 ô chưa bắn. raw_console.json giữ nguyên 42 kết quả tool/input/timestamp/exit; text log chỉ bỏ ANSI/chuyển newline. Bảng tọa độ/kết quả literal trong validator là oracle người quan sát, không được nạp vào server hoặc gọi lại luật để tự chứng minh.

Không phát hiện lỗi gameplay/kết nối mới. Vấn đề wrap thông báo cuối 81 ký tự R9-S03-01 xuất hiện lại ở người thắng P2 trên console 80 cột, nhưng winner và exit đầy đủ; giữ task trình bày đã mở, không sửa lạc phạm vi D-06. Runtime Linux/macOS chưa được chạy, và các xác nhận nhóm S-01/S-02/S-03 còn chờ không được ký thay.

## S-04 — 2026-10-05

Chạy lại tại working tree trên nhánh `Luong_nhap_gui_dat_tau` trước commit chốt:

```text
stack build --ghc-options=-Werror
  Exit 0; biên dịch lại 9 module thư viện và hai Main.
stack test --ghc-options=-Werror
  815 examples, 0 failures; 74.5740 giây; exit 0.
```

Log đầy đủ và thời điểm/exit code tại [demo/s04](s04_feature_freeze.md#3-kiểm-tra-bản-chốt). Bộ test gồm A-05/B-05/C-06/D-06, dùng lõi thuần và executable/server production; các test stub riêng chỉ kiểm tra ranh giới hợp đồng, không thay trận đầy đủ. Không thay mã chạy hoặc thêm dependency/test mới chỉ để khóa tính năng.

Đối chiếu 27 file code/config/contract với checkout D-06 được ghi ở `demo/s04/d06-source-comparison.json`: chỉ chuẩn hóa CRLF/LF, tất cả khớp. Demo và hash D-06 được giữ nguyên theo snapshot lịch sử; không cần chơi lại cùng kịch bản thủ công để thay log. Full-suite lần này đã chạy lại bốn test D-06, gồm P2 thắng và ngắt kết nối hai phía.

[Hồ sơ S-04](s04_feature_freeze.md) xác định commit đầu tiên thêm hồ sơ là bản chốt, phạm vi chỉ sửa lỗi/test/tài liệu, lỗi P3 R9-S03-01 còn mở và bảng xác nhận A/B/C/D/R còn chờ. Chốt kỹ thuật đã đạt; thống nhất bản báo cáo chưa đạt cho đến khi có xác nhận thật trên cùng SHA. Các lời ghi nhận ở S-01/S-02/S-03 vẫn giữ trạng thái chờ, không bị thay bằng kết quả tự động.
