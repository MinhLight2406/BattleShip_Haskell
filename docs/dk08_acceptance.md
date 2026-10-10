# Nghiệm thu Docker/LAN — DK-08

Nhánh `Test_2_container_va_LAN`, nền `17928c0`. Ngày chuẩn bị: 2026-10-10. Phụ thuộc DK-07; không đổi API, luật, snapshot hoặc chính sách nối lại 300.000 ms.

**Trạng thái:** **ĐẠT nghiệm thu một máy với hai trình duyệt theo yêu cầu thay thế của người dùng** ngày 2026-10-10. Bộ tự động nền **19/19 qua, 0 lỗi, 0 skip**; lần chạy bổ sung Chrome/Edge **1/1 qua**. Chưa kiểm chứng hai thiết bị vật lý cùng Wi-Fi; không ghi xác nhận thay B/C/D/R.

## 1. Bộ kiểm thử tự động

Từ checkout có Node >=24, dependency frontend và Chromium của Playwright; Docker Desktop chạy Linux containers. Build image DK-07 trước lần chạy đầu:

```powershell
docker compose --env-file .env.example -p battleship-build config --quiet
docker compose --env-file .env.example -p battleship-build build
pnpm --dir frontend install --frozen-lockfile
pnpm --dir frontend exec playwright install chromium
node --test scripts/test-compose.mjs
```

Nếu Docker CLI chưa có trong PATH, đặt `BATTLESHIP_DOCKER_CLI` bằng đường dẫn Docker Desktop. Hai image runtime `battleship-haskell:local` / `battleship-web:local` được dùng; không cần publish registry. Các test đặt project UUID/cổng OS cấp và chỉ cleanup tài nguyên của project đó.

Runner có 19 ca: 7 ca DK-07 và 12 ca DK-08. Linux host không chạy hai ca helper/LAN Windows; kết quả cần ghi số skip, không coi ca bị skip là đã nghiệm thu host Windows. Test LAN cần host có IPv4 đủ điều kiện; có thể chọn `BATTLESHIP_LAN_INTERFACE` và `BATTLESHIP_LAN_TEST_HOST`. Mặc định ưu tiên adapter Wi-Fi nếu có. Một máy chạy hai WebSocket qua IP LAN của chính nó vẫn là **test tự động trên một thiết bị**, không phải nghiệm thu hai thiết bị. Ca UI hiện chạy hai tiến trình Chromium riêng mặc định; đặt `BATTLESHIP_BROWSER_CHANNELS=chrome,msedge` nếu đã cài cả Chrome và Edge để kiểm tra hai trình duyệt đó.

| Kịch bản | Bằng chứng yêu cầu |
|---|---|
| Source sạch | Export file tracked và untracked không bị Git ignore của bản đang kiểm thử; không `.git`, `.env`, `.stack-work`, node_modules hay dist host. Compose build lại bằng Dockerfile có gate Linux |
| HTTP/WS, P1/P2/P3 | HTML/bundle thật, hai slot đúng, P3 nhận ERROR SERVER_FULL |
| Trận đầy đủ | PLACE sai/hợp lệ, chờ, lỗi lượt/tọa độ/bắn lặp, MISS, HIT, SUNK CV/BB/CR/SB, WIN, GAME_OVER và backend exit 0 |
| Riêng tư | Replay mỗi người chỉ chứa fleet của chính họ và đúng SHOT/INCOMING; cả hai bảng mục tiêu UI không có `.occupied` |
| Nối lại | Cả P1/P2 giữ token/fleet/history; token sai không chiếm slot; lệnh khi pause không tiến trận |
| Hết hạn | Clock 299999/300000 ms và 599999/600000 ms sau lần resume; trước hạn không thua, tại hạn Haskell nhận Quit cho đúng người |
| Origin/Host/port | Public khác internal, Host khác Origin bị từ chối, origin lạ/nội bộ bị từ chối trước khi tạo TCP |
| Restart | Restart Haskell/web giữa trận đóng WS cũ, không bịa ALL_SHIPS_SUNK; token cũ bị INVALID_SESSION; token/fleet mới không mang trạng thái cũ |
| Trận mới | start haskell sau GAME_OVER giữ web và mở P1/P2 mới |
| Đồng thời/C-07 | 10 cặp lệnh WS qua server thật; mỗi ô cập nhật một lần. TCP P1/P2/cả hai không đọc, core exit trong 10s trước khi gate cho client đọc lại; survivor nhận winner đúng |
| UI trình duyệt | Hai context Chromium tách biệt, desktop/mobile; nhập tàu bằng click, lỗi J10, trượt, reload/resume, trúng/chìm/thắng/thua; không pageerror |
| Dọn dịch vụ | stop/down <10s, process exit 0, marker mất, container/network được dọn, dùng lại cổng được |

### Fixture clock và client chậm

`docker/test/controlled-clock.mjs` chỉ được mount làm entrypoint **test** trong web. Nó import `/app/bridge.mjs` nguyên bản, dùng mock Date/setTimeout của Node và file điều khiển trong mount chỉ đọc. Không thêm endpoint test hoặc biến thay grace vào ứng dụng/Compose production. Heartbeat/IO mạng vẫn chạy thật; winner đến từ server Haskell thật.

`docker/test/nonreading-clients.mjs` chạy bằng docker exec **bên trong web**, gọi TCP service haskell, không publish TCP ra host hoặc thêm service thứ ba. Hai client được gán slot trước khi flood 50000 lệnh sai; stream của client chậm được pause. Test chỉ mở gate đọc lại sau khi container Haskell đã exit 0, nên không thể đạt kết quả nhờ client bất ngờ đọc nhanh hơn. Linux build gate chạy lại cả QuickCheck A-06/B-06, 100 STM races C-06 và test gần đầy hàng đợi C-07.

Log cục bộ: `.stack-work/dk08/compose-full-test.log`, `clean-build.log`, `targeted-test.log`, `clients-ui-test.log`. Hai ảnh UI ở `.stack-work/dk08/ui-victory-desktop.png` và `ui-defeat-mobile.png`; không ghi token vào ảnh. Đây là artifact tự động, không dùng làm ảnh thiết bị thật.

### Kết quả tự động ngày 2026-10-10

Windows host; Docker Desktop 4.94.0 / Engine 29.8.2 / Compose 5.5.1, Linux amd64. Runner host Node 24.19.0; web image Node 24.21.0/pnpm 11.25.0; Chromium 153.0.8010.12. Haskell giữ lts-24.59/GHC 9.10.3.

| Gate | Kết quả thực tế |
|---|---|
| Build source sạch hai image | Qua; không có `.git`, `.env`, cache hoặc dependency host |
| `stack build` / `stack test --ghc-options=-Werror` trong Linux | Qua; **908 ví dụ, 0 lỗi**, gồm A-06/B-06/C-07 |
| Frontend stage test | **36/36 qua**; TypeScript/Vite build thành công |
| Frontend sau cập nhật tài liệu | **36/36 qua**, gồm 6 ca hợp đồng Docker; `git diff --check` và Node syntax check 3 file test không lỗi |
| `node --test scripts/test-compose.mjs` | **19/19 qua, 0 skip**, 534,2 giây |
| Trận UI desktop/mobile | Hai context Chromium độc lập đến thắng/thua; reload giữ phiên; không pageerror hoặc tàu đối phương trên bảng mục tiêu |
| TCP không đọc và đồng thời | P1, P2, cả hai không đọc đều dọn trong deadline; 10 cặp lệnh WS không mất/nhân đôi cập nhật |
| LAN qua IP host | HTTP và trận đầy đủ qua `192.168.1.126` tại thời điểm test; hai peer cùng một máy |
| Cleanup tự động | Không còn container/network `battleship-dk08-*` sau toàn bộ suite |

Bản log kết quả không chứa token được lưu tại [demo/dk08/automated-results.txt](demo/dk08/automated-results.txt); đây là lần chạy suite nền trước khi nâng ca UI thành hai tiến trình trình duyệt riêng. Lần chạy chọn riêng phát hiện kỳ vọng test sai: resume token sau restart backend chưa có GAME_OVER phải nhận INVALID_SESSION, không SESSION. Đã sửa test theo hành vi hiện có và chạy lại suite đầy đủ xanh; không sửa bridge để làm test qua. Không phát hiện lỗi production trong các ca này. Hai thiết bị vật lý và review nhóm cần xác nhận riêng nếu nhóm giữ tiêu chí đó.

## 2. Nghiệm thu một máy, hai trình duyệt — đã thực hiện

Người dùng yêu cầu thay trận hai thiết bị bằng một máy chạy hai trình duyệt, do agent tự thao tác và ghi kết quả. Ngày **2026-10-10, khoảng 20:00 (Asia/Saigon)**, Playwright điều khiển **Google Chrome 155.0.8059.39 (P1)** và **Microsoft Edge 155.0.4283.45 (P2)** chạy headless trong hai tiến trình riêng, profile/cookie/sessionStorage tách biệt. Đây là hai trình duyệt thật trên cùng Windows host; viewport Edge 390×844 chỉ mô phỏng kích thước di động, không phải điện thoại thật.

Hai runtime container production từ source đã build chạy bằng Compose trên mạng riêng. Cổng TCP Haskell không publish; hai trình duyệt vào **`http://192.168.1.126:54358`**, cổng host tạm thời do OS cấp → web container 8080 → `haskell:4000`. IP được lấy lại từ Wi-Fi host trước khi test. Project test độc lập với phiên demo cổng 8081; test không chiếm slot của phiên đó.

| Bước và kỳ vọng | Kết quả quan sát/kiểm tra |
|---|---|
| CV ngang tại J10 vượt biên | UI báo lỗi; 0 ô tàu được đặt |
| Đặt đủ năm tàu ngang | Chrome A1/A2/A3/A4/A5; Edge A6/A7/A8/A9/A10; mỗi bên đúng 17 ô |
| Ghép hai người | Wire nhận đúng WELCOME P1/P2; P1 đặt xong trước thấy chờ, sau đó được bắn; P2 chờ lượt và ô bắn bị khóa |
| Bắn J10 hai phía | Hai MISS đúng ở bảng mục tiêu/phòng thủ; chuyển P1 → P2 → P1 |
| Bắn A6 rồi tải lại Chrome | A6 HIT; giữ nguyên mã phiên (so sánh trong test, không ghi log), P1, 17 ô tàu, J10 MISS và A6 HIT; không đặt lại tàu |
| Tiếp tục bắn hết đội tàu | Đúng 17 ô trúng; E6/D7/C8/C9 chìm CV/BB/CR/SB; B10 là WIN |
| Hai giao diện đồng bộ | Mỗi kết quả bắn được kiểm tra trên bảng mục tiêu Chrome và bảng phòng thủ Edge |
| Giữ bí mật | Bảng mục tiêu cả hai không chứa `.occupied` tại từng bước; Edge chưa bắn vào đội tàu P1 nên bảng mục tiêu không hiển thị chúng |
| Kết thúc | Chrome hiện Bạn thắng, Edge hiện Bạn thua; toàn bộ ô bắn cả hai bị khóa |
| Lỗi trình duyệt/vòng đời | 0 pageerror; Haskell exit 0; đóng hai tiến trình trình duyệt và down project test trong cleanup |

**Kết luận: ĐẠT kịch bản nghiệm thu thay thế một máy/hai trình duyệt**, 1 test qua, 0 lỗi, 0 skip, khoảng 22,8 giây. Không phát hiện lỗi ứng dụng trong trận này. Lần thử đầu chưa chạy được vì Docker Engine tắt; đã khởi động Docker Desktop và chạy lại thành công. Không đổi luật, API, snapshot, runtime hay dependency; chỉ nâng ca UI để hai trình duyệt chạy riêng và reload đúng sau A6.

Minh chứng được lưu cùng báo cáo, không chứa mã phiên:

- [Log Chrome/Edge](demo/dk08/two-browsers-results.txt)
- [Chrome — P1 thắng](demo/dk08/chrome-p1-victory.png)
- [Edge — P2 thua, viewport di động](demo/dk08/edge-p2-defeat.png)

Lệnh tái hiện sau khi cài cả Chrome/Edge và chuẩn bị Docker/image/dependency:

```powershell
$env:BATTLESHIP_BROWSER_CHANNELS='chrome,msedge'
# Lấy IP Wi-Fi hiện tại, không dùng cố định IP ghi trong minh chứng.
. ./scripts/Start-LanCompose.ps1
$origins = @(Get-LanOrigins -Interfaces @(Get-LanHostInterfaces) -InterfaceName 'Wi-Fi' -Port 8081 -RequireInterface)
if ($origins.Count -ne 1) { throw 'Cần chọn một IPv4 Wi-Fi cho test trình duyệt.' }
$env:BATTLESHIP_LAN_TEST_HOST=([Uri]$origins[0]).Host
node --test --test-name-pattern='two separate browser processes' scripts/test-compose.mjs
Remove-Item Env:BATTLESHIP_BROWSER_CHANNELS,Env:BATTLESHIP_LAN_TEST_HOST
```

Cổng 54358 là cổng test của lần chạy này, đã giải phóng sau cleanup; không phải URL deployment cố định. Bộ 19 ca nền kiểm chứng riêng những phần không nằm trong trận UI này, gồm hết hạn 5 phút, lệnh wire sai, restart và client chậm. Chưa chạy lại cả 19 ca sau khi nâng riêng ca UI; đã chạy chính ca thay đổi thành công trên Chrome/Edge. Không có chữ ký nghiệm thu thay thành viên nhóm.

## 3. Kịch bản bổ sung trên hai thiết bị thật cùng Wi-Fi — chưa thực hiện

Giữ máy chủ Windows và Docker Desktop bật; cả hai thiết bị cùng Wi-Fi, dùng hai bộ nhớ trình duyệt riêng. Sau build, trên máy chủ chạy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Start-LanCompose.ps1 -LanInterface 'Wi-Fi' -ProjectName battleship-lan-acceptance -ConfigDir .docker-runtime/dk08-acceptance
```

Tên adapter phải đúng tên trên máy. Dùng URL **Player URL** helper in ra, cổng mặc định 8081; thiết bị thứ hai không dùng localhost hoặc IP container. Giữ helper chạy; nó cập nhật IP. Khi đổi IP giữa trận, mở URL mới và dùng mã riêng trước hạn 5 phút; mã này không tự chuyển sang sessionStorage của origin mới. Không gửi mã phiên trong báo cáo/ảnh.

### Kịch bản ngắn

1. Thiết bị 1 vào Cổ điển; thử CV tại J10, xác nhận lỗi vượt biên và tàu chưa được đặt. Đặt năm tàu ngang tại A1/A2/A3/A4/A5 theo thứ tự CV/BB/CR/SB/DD, nhấn Bắt đầu trận. Xác nhận P1/chờ đối thủ.
2. Thiết bị 2 mở URL LAN, đặt năm tàu ngang tại A6/A7/A8/A9/A10, nhấn Bắt đầu trận. Xác nhận P2; P1 được bắn, P2 chờ. Cả hai bảng mục tiêu không hiển thị tàu đối phương.
3. P1 bắn J10 trượt → P2 đến lượt; P2 bắn J10 trượt → P1 đến lượt.
4. P1 bắn A6 trúng rồi reload trang: giữ P1, 17 ô tàu của mình, A6 đã trúng, không phải đặt lại tàu. Kiểm tra P2 thấy A6 ở bàn phòng thủ.
5. P1 tiếp tục B6/C6/D6/E6 (chìm CV), A7/B7/C7/D7 (chìm BB), A8/B8/C8 (chìm CR), A9/B9/C9 (chìm SB), A10/B10 (thắng). P1 thấy thắng, P2 thấy thua, không còn ô bắn được.
6. Chụp màn hình hai thiết bị sau kết thúc; che mã khôi phục nếu có. Ghi thiết bị/trình duyệt, kết quả, thời điểm, lỗi phát hiện. Không ghi đội tàu của trận thật đang diễn ra hoặc token vào log health.

Trận đủ gồm 17 ô tàu; các bố trí trên là dữ liệu demo được hai người thống nhất, không phải kiểm thử chơi cạnh tranh. Lệnh sai trên wire, hết hạn 5 phút, restart và client chậm đã có ca tự động riêng.

### Bản ghi thiết bị thật

| Mục | Kết quả |
|---|---|
| Máy chủ/giao diện/IP/cổng | Windows host, Wi-Fi, `http://192.168.1.126:8081`; lấy từ helper lúc 19:14 ngày 2026-10-10. Hai service healthy; HTTP `/healthz` 200, chưa dùng TCP probe chiếm slot |
| Thiết bị 1 / trình duyệt | Chờ người chạy xác nhận |
| Thiết bị 2 / trình duyệt | Chờ người chạy xác nhận |
| Cùng Wi-Fi | Chờ xác nhận |
| P1/P2, chờ/lượt, riêng tư | Chờ xác nhận |
| MISS/HIT/SUNK/WIN và reload | Chờ xác nhận |
| Hai màn hình thắng/thua / log | Chưa có ảnh hoặc kết quả thiết bị thật |
| B/C/D/R xác nhận | Chưa có xác nhận người phụ trách |

Sau GAME_OVER, start haskell bằng **đúng env-file/project** để mở trận mới. Sau nghiệm thu, Ctrl+C helper rồi:

```powershell
docker compose --env-file .docker-runtime/dk08-acceptance/compose.env -p battleship-lan-acceptance down
```

Tiêu chí gốc DK-08 gồm hai thiết bị thật; mục này chưa thực hiện. Theo yêu cầu mới, nghiệm thu hiện tại đã hoàn thành ở phạm vi **một máy/hai trình duyệt** tại mục 2. Không dùng kết quả đó để xác nhận Wi-Fi giữa hai thiết bị, firewall/router hoặc thao tác cảm ứng trên điện thoại thật.
