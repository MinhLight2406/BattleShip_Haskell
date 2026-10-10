# Hướng dẫn và căn cứ kiểm thử

Source đối chiếu `8bd7da9`, 2026-10-10. Kết quả theo ngày ở [test_evidence.md](test_evidence.md), [DK-08](dk08_acceptance.md), [DK-09](dk09_handover.md). Lệnh dưới đây chạy từ **gốc repo** nếu không ghi khác. Cần môi trường compiler/Node/pnpm tương ứng; Docker runtime không cần các tool phát triển cài trên host.

## 1. Phân lớp test

| Lớp | File / nội dung | Vì sao cần |
|---|---|---|
| Kiểu/contract | TypesSpec, SharedContractSpec | Constructor/field/chữ ký, một Coord/Command, owner/component đúng |
| Geometry/invariant | BoardSpec | Năm ID/17 ô, mép/góc, ID 3 ô trùng, chạm cạnh, smart-constructor compile probe |
| Luật thuần | RulesSpec | Đặt/chờ/Miss/Hit/Sunk/Win, lượt/lặp/out-of-bounds/finished, Left không đổi state |
| Privacy | ViewSpec | Own fleet/history, Event→View, bí mật khác nhưng quan sát/view giống nhau |
| Codec/framing | ProtocolSpec; unit/bridge web | Transcript, roundtrip miền hợp lệ, LF/CRLF/chunk/oversize/token thiếu |
| STM | CoordinatorSpec | State/frame batch nguyên tử, đúng recipient, queue capacity/reserved end/races |
| TCP/terminal thật | ServerSpec, ClientSpec, IntegrationSpec | Admission, socket/readiness/EOF/watchdog/CLI/worker cleanup |
| Frontend unit | unit.test.ts, connection.test.ts | Nháp/encode/parser/reducer/pending/replay/recovery URL |
| Bridge/DNS/LAN | bridge.test.mjs, reconnect/lan/lan-helper | Origin/Host, metadata/token/TTL/IP/clock, TCP giữ đúng actor |
| Browser | browser.test.mjs; test-compose browser | DOM/click/keyboard/biên/riêng tư/reload/thắng-thua thật |
| Linux image/Compose | docker/test/*, scripts/test-compose.mjs | Runtime non-root/lib/static assets, health không slot, restart/down và mapped port |

Không gọi toàn bộ test mạng/browser/container là unit test. Mock/fixture codec hoặc lỗi nội bộ hợp lý để chủ động tạo failure; gameplay hợp lệ phải qua production Board/step. `runServerWith` là test seam, production `runServerConfigured` luôn dùng Rules.step/initialGameState.

## 2. Gate Haskell

```sh
stack build
stack test --ghc-options=-Werror
```

Build chốt hai executable/library; -Werror yêu cầu warning compiler được xử lý. Test không chỉ parse output “có chữ xanh”: exit code phải 0, không skip gate bắt buộc. Chạy nhóm liên quan khi sửa nhỏ, rồi full suite ở commit chốt:

```sh
stack test --ghc-options=-Werror --test-arguments="--match A-06"
stack test --ghc-options=-Werror --test-arguments="--match B-06"
stack test --ghc-options=-Werror --test-arguments="--match C-07"
stack test --ghc-options=-Werror --test-arguments="--match S-01"
stack test --ghc-options=-Werror --test-arguments="--match DK-02"
```

Mẫu unit test: input cụ thể → gọi hàm → expectation cụ thể. Ví dụ Board nhận Destroyer bắt đầu I10 ngang thì các ô I10/J10 hợp lệ; dọc từ I10 vượt row 10, phải Left ShipOutOfBounds. Không lấy `shipCells` tính expected cho chính test của `shipCells`; expected phải do quy tắc/fixture độc lập.

Lỗi Rules không trả state mới. Test dùng `before`, assert chính xác Left, rồi dùng lại `before` cho lệnh tiếp để kiểm chứng không tiêu lượt; coordinator test assert TVar và frames sau rejection. Sau Finished, late EOF/Quit/FIRE không đổi winner.

## 3. A-06: generator/tính chất đội tàu

Nguồn: [Generators.hs](../test/TestSupport/Generators.hs), [BoardSpec.hs](../test/BoardSpec.hs). QuickCheck chỉ là dependency test suite, không runtime.

Generator dùng bảng độ dài/ô 10×10 độc lập, liệt kê tập candidate hữu hạn, lọc bằng geometry test tự viết rồi chọn phần tử; không dùng kết quả placeFleet để quyết định “valid”. Xếp longest-first, Carrier ngẫu nhiên hướng, Destroyer hướng đối diện để có H/V; danh sách tàu được shuffle. Không dùng `suchThat` thử lại vô hạn. Với năm tàu nhỏ, số segment rời nhau theo hướng đủ lớn so với số ô đã chiếm; private-pair giữ Carrier và cho Destroyer tránh fleet cũ vẫn có candidate theo budget trong comment generator.

Năm property: Right; đúng ID/độ dài/17 ô; trong grid độc lập; mỗi ô đúng một ship; permutation cùng Fleet. Có property coverage riêng:

- Mỗi mép ≥20%; mỗi góc A1/J1/A10/J10 ≥1%.
- Mixed directions ≥90% (generator chủ động có cả hai); chạm cạnh hợp lệ ≥20%.
- Carrier start ở mỗi nửa trái/phải/trên/dưới ≥10%.

`modifyMaxSuccess (max 1000)` cho mỗi property ít nhất 1.000 case. `checkCoverage` dùng kiểm tra thống kê, có thể chạy nhiều case hơn để đạt độ tin cậy, không khóa đúng 1.000. Không đọc “passed” của assertion riêng mà bỏ qua coverage failure.

## 4. B-06: oracle privacy và dữ liệu nhất quán

Nguồn [ViewSpec.hs](../test/ViewSpec.hs). Với mỗi P1/P2:

1. Sinh hai fleet hợp lệ và **chuỗi Command**, trạng thái được tạo bằng step thật.
2. Dựng public observations từ request mình đã biết + Event nhận; oracle không lấy toàn GameState để trả view hộ implementation.
3. So ownFleet/history/toàn record projection ở từng bước, không chỉ cuối.
4. Private pair giữ Carrier và các quan sát MISS/HIT/SUNK Carrier giống nhau nhưng di chuyển thật phần tàu chưa bị bắn; assert events và toàn view bằng nhau, moved cells không đã quan sát.
5. Giai đoạn placing/playing/finished, cả winner/reason/outcome được kiểm tra bằng `cover`.

Coverage phase placing/playing ≥15%, finished ≥30%; mỗi reason/winner ≥15%, Miss/Hit/Sunk ≥10%, Win ≥15% trong property coverage. Private pair thêm cover SUNK ≥15%, ended-by-sinking/quit/still-playing ≥10%. Test cho cả hai viewer; each property ≥1.000 case.

Không sinh arbitrary GameState bằng gán history rời rạc. Không assert “mọi Coord fleet đối thủ không xuất hiện đâu trong view”: own Coord có thể trùng và shots công khai hợp lệ. So sánh bất khả phân biệt quan sát là kiểm tra đúng bí mật.

### Seed và regression

Hspec/QuickCheck in input phản ví dụ và seed khi thất bại. Giữ nguyên filter/seed/toolchain/source khi chạy lại:

```sh
# 12345 chỉ minh họa; thay bằng seed được output thất bại in ra.
stack test --ghc-options=-Werror --test-arguments="--match A-06 --seed 12345"
stack test --ghc-options=-Werror --test-arguments="--match B-06 --seed 12345"
```

Giữ tên property, cả input/trace, vị trí transition, seed, phiên bản GHC/QuickCheck và log. Với generator `forAll` hiện tại, input được in nhưng không có custom shrinker chuyên biệt; không hứa luôn tìm phản ví dụ nhỏ nhất. Sau sửa lỗi, thêm Hspec fixture cụ thể dựa trên case gây lỗi rồi giữ property. Không bịa một regression QuickCheck phát hiện nếu chưa có failure thật; A-05 và test biên hiện có là các regression/fixture đã ghi riêng.

## 5. C-06/C-07: test đồng thời và client chậm

STM test dùng capacity nhỏ (≥5), queue đã điền và gate MVar/STM để hai worker bắt đầu cùng điều kiện. Kiểm tra state + toàn batch từng recipient, queuedFrameCount ≤capacity, GAME_OVER trước Nothing, late command không thêm kết thúc.

Race dùng phát **HIT** để người đang có lượt vẫn giữ lượt: lệnh đối thủ chắc chắn sai ở mọi thứ tự commit. Nếu chọn MISS, lệnh đối thủ có thể đúng sau khi lượt đổi; hai lệnh đúng nối tiếp không phải lỗi atomicity. Các near-limit races trong CoordinatorSpec lặp 100 lần; chạy full suite không cần giả định sleep để tạo race.

TCP thật test client không đọc/flood input; writer watchdog/slow flag phải làm core kết thúc trong deadline, đối thủ còn đọc nhận GAME_OVER. Cả hai không đọc vẫn phải đóng/thoát; không yêu cầu peer chậm nhận được mọi buffered frame. Container fixture dùng marker đồng bộ: xác nhận hai TCP được admit/flood, giữ stream paused đến khi core thoát, rồi release để thu kết quả; không pause/resume sớm làm test mất ý nghĩa.

Queue budget không phải bộ đệm kernel. TCP test bắt lifecycle/không treo, STM test chứng minh dung lượng queue/batch. Kết hợp hai loại tránh dùng timing socket để suy ra trực tiếp số phần tử TBQueue.

## 6. Frontend và bridge native

```sh
pnpm --dir frontend install --frozen-lockfile
pnpm --dir frontend build
pnpm --dir frontend test
stack exec -- node --test frontend/test/integration.test.mjs frontend/test/reconnect.test.mjs
stack exec -- node --test frontend/test/lan.test.mjs
pnpm --dir frontend test:lan-helper
```

`build` gồm `tsc --noEmit` và Vite. `pnpm test` gồm unit/connection/bridge/Docker-artifact (36 ca ở lần DK-09), **không** tự chạy integration/browser/LAN/helper. `stack exec` đưa battleship-server đã build vào PATH; Node phải có trong PATH. Helper test yêu cầu Windows/PowerShell 5.1. Windows cần hoàn tất process test web trước rebuild executable Haskell đang được dùng.

Browser cần Playwright dependency và browser đã cài; nếu chưa có:

```sh
pnpm --dir frontend exec playwright install chromium
stack exec -- node --test frontend/test/browser.test.mjs
```

Chromium test không đại diện mọi Firefox/Safari/điện thoại; viewport 390 px là mô phỏng. Với hai tab cùng browser, dùng session/profile độc lập để không nhập mã của cùng phiên; Chrome/Edge nghiệm thu đã chạy hai process/profile riêng.

## 7. Docker runtime/Compose

Build chuẩn từ README chạy test trong stage Linux. Bộ chuyên biệt dưới đây cần Node/dependency test trên host **chỉ để chạy harness**, không cần để người dùng chơi image. Chuẩn bị image trước runtime/Compose test; không tự gán image cũ cho source mới.

```powershell
docker build -f docker/haskell.Dockerfile -t battleship-haskell:local .
docker build -f docker/web.Dockerfile -t battleship-web:local .
$env:BATTLESHIP_HASKELL_IMAGE = 'battleship-haskell:local'
$env:BATTLESHIP_WEB_IMAGE = 'battleship-web:local'
node --test docker/test/haskell-runtime.test.mjs
node --test docker/test/web-runtime.test.mjs
node --test docker/test/lan-runtime.test.mjs
node --test scripts/test-compose.mjs
```

Các runtime harness mặc định dùng tag lịch sử `battleship-haskell:dk04`/`battleship-web:dk05`; block trên override về image `:local` vừa build. Compose dùng `:local` theo compose.yaml. Không build một tag rồi vô tình kiểm tra tag khác.

Test script có project/thư mục/port riêng, cleanup tài nguyên sở hữu; không chạy `docker system prune` hoặc dọn deployment người dùng. `BATTLESHIP_DOCKER_CLI` tùy chọn đường dẫn CLI. Browser Compose có `BATTLESHIP_BROWSER_CHANNELS=chrome,msedge` khi cả hai browser đã cài; mặc định hai process Chromium. `BATTLESHIP_LAN_TEST_HOST` phải là IPv4 host đang có, `BATTLESHIP_LAN_INTERFACE` chọn adapter; xem DK-08. Các ca Windows helper/adapter có skip ngoài Windows, nên kiểm tra skip trong output thay vì gọi toàn suite đạt mọi platform.

Source sạch DK-08 là export source không .git/.env/.stack-work/node_modules/dist, rồi build trên Linux; compiler/dependency cache của Docker có thể được dùng. Không tương đương cài từ máy trống/offline/bit-for-bit reproducible.

Clock fixture điều khiển Date/timers kiểm tra 299.999 ms chưa Quit và 300.000 ms Quit, hoặc hạn ngắn khi test lifecycle. Production vẫn 5 phút. Không cần chờ thực 5 phút mọi ca; không coi đây là nghiệm thu mạng Wi-Fi đổi vật lý.

## 8. Ghi bằng chứng và chọn gate

Mỗi lần nghiệm thu ghi SHA hoặc working-tree nền/diff, ngày/timezone, OS/toolchain, command, exit, counts/skip, log/ảnh và giới hạn. Không log token/fleet đối thủ. [demo_script.md](demo_script.md) cho kịch bản thao tác và mẫu record không cần sửa luật.

| Phần đổi | Gate cần ưu tiên |
|---|---|
| Docs kiểu/owner/wire/env | S-01, ProtocolSpec/transcript frontend, Docker artifact, link/diff checks |
| Board/Rules/View | Unit/property, full Haskell trước chốt; UI/integration nếu wire/semantics đổi |
| Coordinator/Server | STM/race/TCP, full Haskell; runtime/container cho shutdown/blocking IO |
| Bridge/origin/resume/helper | Unit/integration/reconnect/LAN/helper, web runtime/Compose ca liên quan |
| Dockerfile/Compose | Config/build/test stage, runtime/lifecycle/Compose và demo |

Docs-only không yêu cầu mặc định chạy lại mọi suite container nhiều phút khi source/config không đổi; ghi rõ gate mới chạy và viện dẫn các kết quả runtime có ngày trước. Khi gate mới phát hiện rủi ro thật, mở rộng kiểm tra đúng phần đó.
