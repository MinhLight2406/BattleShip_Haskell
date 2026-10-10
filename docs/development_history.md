# Quá trình thực hiện đồ án

Tổng hợp yêu cầu cuộc trao đổi và lịch sử Git đến `8bd7da9`; ngày 2026-10-10. Đây là tiến trình sản phẩm, không phải phân công con người suy ra từ commit. A/B/C/D/R là vai trò trong task; review thật xem [shared_contract.md](shared_contract.md).

## 1. Trình tự và căn cứ

| Giai đoạn / task | Phụ thuộc chính | Sản phẩm / điểm giải quyết | Commit có thể tra |
|---|---|---|---|
| Khởi tạo/R-01 | Yêu cầu game, slide, tham khảo repo | Scaffold thư mục, luật MVP trước implementation | `d44b693`, `e44a50d` |
| C-01 | — | package/stack, hai Main/test, build xanh; Main không chứa luật | `5707785`, `87cf653`, `69c20c2` |
| A-01 | R-01 | Types/chữ ký/placeholders trạng thái chưa đặt | `96c1e48` |
| D-01 | R-01 | Wire v1, tọa độ, giới hạn dòng, transcript | `62ef601` |
| S-01 | A-01/D-01/C-01 | Ghép kiểu/protocol/Main/ownership, soát trùng Coord/Command | `f73dc87` |
| A-02, A-03 | S-01/A-02 | Board geometry/smart constructor, đủ năm ID, biên/chạm cạnh, khóa xác nhận | `ceb0739`, `1626f90` |
| B-01, B-02 | S-01/A-02/B-01 | Step đủ Command/Phase rồi Miss/Hit/Sunk/Win/turn/errors | `4685f93`, `6601377` |
| C-02, C-03 | S-01/B-01/D-02 | Hai TCP client/P3 từ chối; lệnh đi qua coordinator đến step | `141a219`, `f21c816` |
| D-02, D-03 | S-01/D-02 | Parser/encoder/one-shot, nhập nháp năm tàu/preview/sửa/gửi | `cad31d5`, `4eea8b5` |
| S-02 | A-03/B-02 | Nghiệm thu lõi thuần, fixture hợp lệ qua step thật | Các thay đổi nằm trong chuỗi sau `4eea8b5`, trước S-04 |
| B-03/B-04/B-05 | B-02/S-03 theo task | Góc nhìn riêng, lỗi không đổi state, nhất quán Event/View | Bộ mã nghiệm thu S-04 `0a84aba` |
| C-04/C-05/C-06 | C-03/B-02/B-03/S-03 | TVar, outbox riêng, EOF/FIN/timeout, race và cleanup | Bộ mã nghiệm thu S-04 `0a84aba` |
| D-04/D-05/D-06 | D-03/B-02/B-03/S-03 | Nhập bắn, hai bàn, kết thúc, checkout sạch/đầu cuối | Bộ mã nghiệm thu S-04 `0a84aba` |
| A-04/A-05 | A-03/S-03 | Invariant, mutation biên, regression I10 H/V | Bộ mã nghiệm thu S-04 `0a84aba` |
| S-03/S-04 | Lõi/server/client và sửa hồi quy | Terminal thật, log/ảnh, khóa kỹ thuật; review nhóm chưa có | `0a84aba`; merge `adb6991`, `4c8b3f7` |
| Frontend UI | Backend terminal đã có; yêu cầu mới | UI của thành viên và tích hợp thành client mạng thật | `a6ca31f`, `9a4d01e` |
| LAN/auto IP/resume | UI/bridge | HOST/origin, tự nhận IP, 5 phút reconnect, replay riêng | `1057a2d` |
| A-06/B-06 | A-03/A-04 và B-03/B-05 + generator A-06 | QuickCheck fleet và privacy, coverage/seed | `67e44e0` |
| C-07 | C-04/C-05/C-06 | Queue 128/126/2, batch không partial, slow receiver Quit | `0a7c250` |
| DK-01 | C-01/C-05/C-07/bridge LAN | Hợp đồng deploy, .env, health/IP/lifecycle | `e709bea` |
| DK-02 | DK-01 | Bind Haskell configurable, readiness/IPv4/compat API | `761f29c` |
| DK-03 | DK-01 | TCP DNS service, internal/public port, strict Origin/Host | `c8f02e5` |
| DK-04 | DK-02 | Image Haskell build/test/runtime Linux, non-root/ldd | `23f9fc5` |
| DK-05 | DK-03 | Image web frozen deps/build/test/production runtime | `4c8a05d` |
| DK-06 | DK-03 | Windows host IP helper/atomic allowlist/hot reload | `4726b1f` |
| DK-07 | DK-04/DK-05/DK-06 | Hai service/healthy dependency/private TCP/stop/restart | `17928c0` |
| DK-08/DK-09 | DK-07/DK-08 | Source sạch/Compose/UI, lệnh chuẩn/log/handover | `8bd7da9` |
| Hoàn thiện tài liệu | Toàn bộ hiện trạng | Báo cáo, rationale, slide mapping, lịch sử/test/demo | Nhánh `Update_docs_report`, chưa tự coi là commit nộp |

Các task S-02..S-04 được thực hiện trong working tree rồi chốt cùng bộ mã; không bịa một commit riêng cho mỗi task. Tra bằng `git show <SHA>`/`git log --all --oneline` và hồ sơ ngày chạy. Commit không chứng minh người phụ trách đã review.

## 2. Những yêu cầu thay đổi hướng triển khai

### Từ khung package sang hợp đồng nhóm

Ban đầu chỉ dựng cấu hình/build. C-01 thêm executable/test rỗng và smoke kiểm tra chạy; A-01/D-01 tiếp theo chốt kiểu/wire. S-01 được đặt trước các module xử lý để B/C/D không tự định nghĩa lại Coord hoặc đoán transcript. Lệnh build/test trở thành gate mỗi đợt.

### Từ luật thuần sang server/terminal đầy đủ

Board/Rules trước, codec/server nối sau; C-03 có seam nhận Step nhưng production đã dùng lõi thật khi A/B hoàn thiện. S-02 bỏ fixture gameplay ghép tay, C-04 sở hữu state bằng STM, C-05 sửa đường gửi/đóng socket thật, D-05 hiển thị từ dữ liệu riêng tư. S-03/D-06 lưu log demo, không dùng stub để vượt acceptance.

### Từ terminal sang giao diện nhóm

S-04 cấm mở rộng GUI tại thời điểm terminal, nhưng người dùng sau đó yêu cầu dùng nhánh frontend-ui. Đây là authorization/phạm vi mới: UI được nối qua bridge để giữ core đã nghiệm thu. Bản terminal freeze vẫn là hồ sơ lịch sử; không ghi GUI được chốt từ đầu hoặc giấu quá trình mở phạm vi.

### Từ LAN thủ công sang tự nhận IP và nối lại

Yêu cầu ban đầu thêm HOST/PUBLIC_ORIGIN. Sau đó người dùng muốn đổi Wi-Fi trước ván không phải cố định IP hiện tại, giữa ván có 5 phút quay lại. Native bridge dò interface; khi dùng container phải chuyển nguồn IP sang Windows host. Token/replay giữ TCP trong web, còn core xử lý Quit như cũ. Auto IP không tự làm thiết bị khách biết địa chỉ mới.

### Từ hàng đợi không giới hạn sang C-07

Outbox đời C-04 từng TQueue không giới hạn. User yêu cầu bounded queue/client chậm; C-07 thêm kiểm tra batch và chỗ terminal. Giữ đoạn bằng chứng C-04/C-05 với giới hạn cũ vì nó là kết quả thời điểm đó; kiến trúc hiện hành ghi TBQueue.

### Từ chạy host sang hai service Docker

Docker được chọn sau câu hỏi “host tắt server có sống không?”. Câu trả lời kỹ thuật vẫn là không: cần host luôn bật. User chốt phân task trước rồi DK-01..09 lần lượt, có giai đoạn cài Docker Desktop/WSL trước khi kiểm chứng Linux. Build/test Linux không bị thay bằng kiểm tra Dockerfile văn bản.

### Phạm vi nghiệm thu thiết bị

DK-08 đầu tiên yêu cầu hai thiết bị cùng Wi-Fi. Sau đó user yêu cầu một máy/hai browser để tự chạy; nghiệm thu đã làm hai process Chrome/Edge và ghi đúng phạm vi này. Không dùng kết quả đó tuyên bố hai thiết bị thật hoặc đổi Wi-Fi vật lý đã qua. Checklist thiết bị thật vẫn còn để nhóm dùng khi có điều kiện.

## 3. Những vấn đề đã sửa và còn mở

| Vấn đề | Xử lý / bằng chứng | Hiện trạng |
|---|---|---|
| Fixture chơi dùng state/Win/Turn không đúng production | S-02 replay step thật, bỏ fixture gameplay giả | Đã sửa kỹ thuật |
| TCP đóng còn input gây reset/mất GAME_OVER | C-05 half-close/drain deadline, regression unread/QUIT | Đã sửa; sau đó test Linux/container |
| UI đảo tọa độ/mã tàu/nút chưa có luật | Tích hợp frontend, codec/DOM/input tests | Đã sửa kỹ thuật |
| IP cố định hoặc container IP | Native discovery rồi DK-06 host helper | Đã triển khai, physical Wi-Fi change chưa nghiệm thu |
| PUBLIC_ORIGIN bị ép bằng PORT internal | DK-03 WEB_PUBLIC_PORT/strict authority | Đã sửa với port mapping thật |
| Queue đầy/retry có thể giữ kết thúc | C-07 whole batch + reserved terminal + slow flag | Có STM/TCP/Linux/container test |
| R9-S03-01 wrap terminal 80 cột | Task D ghi cụ thể ở round9_fixes | TODO; không chặn kết quả trận |
| Thiếu xác nhận nhóm | Bảng review cùng SHA | Chờ lời xác nhận thật |

## 4. Cách tra và tiếp tục

```sh
git log --all --date=short --format="%h %ad %s"
git show 8bd7da9 --stat
git show 0a7c250 -- src/Battleship/Coordinator.hs src/Battleship/Server.hs
git log --diff-filter=A --format="%H %s" -- docs/s04_feature_freeze.md
```

Lấy revision đang review từ Git, giữ ngày/phạm vi log. Task kỹ thuật đã đạt không tự đóng gate chữ ký. Nếu mở rộng yêu cầu, ghi task/phụ thuộc/test mới thay vì sửa hồ sơ cũ cho có vẻ tính năng luôn tồn tại.
