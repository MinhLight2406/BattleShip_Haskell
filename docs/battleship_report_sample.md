# Đề tài xây dựng trò chơi Battleship hai người bằng Haskell

Báo cáo mẫu theo bố cục của tài liệu `Detai_1.docx.md`, dành cho đồ án BattleShip Haskell. Nội dung phản ánh hệ thống đã triển khai và bằng chứng kiểm thử lưu trong repository tại commit `94a7aaa`. Nhóm bổ sung tên môn học, giảng viên, thành viên và mã sinh viên trước khi nộp.

## 1 Mô tả

Xây dựng trò chơi Battleship cho hai người, trong đó server Haskell kiểm tra lệnh, quản lý trạng thái và quyết định kết quả. Người chơi có thể dùng client terminal hoặc giao diện web. Giao diện web kết nối đến bridge Node qua WebSocket; bridge chuyển lệnh đến server Haskell qua TCP.

Mỗi người sở hữu bàn 10 × 10, với tọa độ từ A1 đến J10 và năm tàu dài 5, 4, 3, 3, 2, tổng cộng 17 ô. Người chơi đặt tàu, xác nhận đội tàu và bắn vào bàn đối thủ. Hệ thống phân biệt trượt, trúng, chìm và thắng; vị trí tàu đối phương chưa bị bắn được giữ bí mật.

Ví dụ xử lý:

- Tàu dài 5 đặt ngang từ A1 chiếm A1 đến E1 và được chấp nhận nếu không chồng tàu.
- Tàu dài 5 đặt ngang từ J10 vượt biên nên bị từ chối.
- P1 bắn trượt thì chuyển lượt cho P2; bắn trúng hoặc chìm thì P1 tiếp tục.
- Bắn sai lượt hoặc bắn lặp trả lỗi, không làm thay đổi trạng thái trong lõi luật.
- Khi toàn bộ 17 ô tàu đối phương bị bắn trúng, trận kết thúc ngay.

Đồ án áp dụng hàm thuần, kiểu dữ liệu đại số, module, kiểm thử, luồng, STM và TCP trong bài giảng. React, WebSocket, khôi phục phiên và Docker là phần mở rộng phục vụ giao diện và triển khai.

## 2 Yêu cầu cụ thể

### 2.1 Phiên bản nền tảng

Phiên bản nền tảng gồm server TCP và hai client terminal, dùng chung thư viện Haskell:

- Định nghĩa thống nhất PlayerId, Coord, ShipId, Fleet, PlayerState, Phase, GameState, Command, Event và GameError.
- Biểu diễn đội tàu chưa đặt bằng Maybe Fleet; GameState chứa hai PlayerState riêng.
- Kiểm tra đủ năm danh tính CV, BB, CR, SB, DD, kích thước tương ứng 5, 4, 3, 3, 2; không chồng hoặc vượt biên; cho phép chạm cạnh và góc.
- Chỉ bắt đầu khi hai người đặt xong; P1 bắn trước. Không đặt lại đội tàu đã xác nhận.
- Từ chối bắn sớm, sai lượt, ngoài bàn, bắn lặp hoặc gửi lệnh sau khi kết thúc.
- Gán P1/P2 theo thứ tự kết nối; từ chối người thứ ba.
- Dùng một thông điệp ASCII trên một dòng TCP, giới hạn payload 256 byte; không để client tự khai danh tính người chơi.

Board kiểm tra hình học; Rules.step quyết định chuyển trạng thái; View giới hạn dữ liệu được phép thấy. Main chỉ đọc cấu hình và khởi chạy. Cách tách này cho phép kiểm thử luật mà không mở socket, đồng thời giúp terminal và web dùng cùng một kết quả xử lý.

### 2.2 Phiên bản mở rộng

Phiên bản mở rộng tái sử dụng lõi Haskell, bổ sung:

- Giao diện React/TypeScript để đặt tàu, xem hai bàn, bắn, theo dõi lượt và kết quả.
- Bridge Node phục vụ giao diện và chuyển WebSocket–TCP, giữ một kết nối TCP cho mỗi phiên.
- Chơi LAN với IP máy chủ Windows được lấy trước trận; helper cập nhật danh sách origin khi IP đổi mà không restart tiến trình.
- Giữ phiên web tối đa 300.000 ms sau khi bridge phát hiện mất WebSocket; nối lại đúng token trước hạn. Hết hạn gửi Quit để Haskell xử lý bỏ cuộc. Client terminal không có cơ chế resume này.
- Kiểm tra Origin/Host theo cấu hình; cập nhật IP không tự chuyển URL hoặc mã phiên sang thiết bị khách.
- Hai service Docker Compose là haskell và web; bridge gọi haskell:4000, chỉ công bố cổng web, mặc định host 8081 tới container 8080.
- Healthcheck đọc readiness hoặc gọi HTTP /healthz, không kết nối vào cổng chơi để tránh chiếm slot P1/P2.

Hai phiên bản là các giai đoạn phát triển của cùng hệ thống. Haskell vẫn quyết định luật; frontend hỗ trợ nhập và hiển thị theo sự kiện nhận được.

### 2.3 Đồng thời và giới hạn tài nguyên

Coordinator giữ một GameState trong TVar. Với mỗi lệnh, đọc trạng thái, gọi step, kiểm tra batch phản hồi, ghi trạng thái và xếp sự kiện trong cùng atomically. IO mạng thực hiện ngoài giao dịch.

Mỗi người có TBQueue 128 phần tử: tối đa 126 phản hồi thông thường, dành hai chỗ cho GAME_OVER và marker kết thúc. Nếu một batch không đủ chỗ, không commit nước gây tràn hoặc một phần phản hồi; xử lý Quit cho đúng người nhận quá tải. Khi cả hai cùng quá tải trong một batch, chọn P1 trước theo hợp đồng hiện hành. Luồng gửi riêng và timeout giúp socket chậm không giữ luồng gửi của đối thủ.

Hệ thống hiện phục vụ một phòng, hai người và một trận mỗi lần chạy Haskell. Trạng thái/token nằm trong RAM; restart hoặc tắt máy chủ làm mất phiên. Chưa có AI, nhiều phòng, tài khoản hoặc lưu trận.

## 3 Sản phẩm ứng dụng

Ứng dụng hiện cho phép người chơi:

- Vào phòng Cổ điển, đặt đủ năm tàu, xem trước và sửa nháp trước khi xác nhận.
- Biết mình là P1/P2 và đang chờ đối thủ hay đến lượt bắn.
- Xem bàn mình gồm đội tàu riêng và các phát bắn nhận được.
- Xem bảng mục tiêu chỉ gồm kết quả đã bắn, không có hình học tàu đối thủ chưa lộ.
- Chọn tọa độ, nhận trượt/trúng/chìm, lỗi nhập và kết quả thắng/thua.
- Tải lại trang hoặc nối lại phiên trước hạn khi bridge và Haskell còn chạy.
- Rời trận chủ động bằng Quit; hết hạn nối lại thì đối thủ thắng do bỏ cuộc.

Sản phẩm bàn giao gồm mã Haskell, frontend/bridge, hai Dockerfile, Compose, helper LAN, bộ kiểm thử, hướng dẫn và log/ảnh demo. Các phiên bản đã chốt là GHC 9.10.3 với snapshot lts-24.59; web image dùng Node 24.21.0 và pnpm 11.25.0.

Lệnh chạy localhost sau khi chuẩn bị Docker/image, từ thư mục gốc dự án:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Start-LanCompose.ps1 -Mode Localhost -EnvFile .env.example -ProjectName battleship -ConfigDir .docker-runtime/lan
```

Khi hai service healthy, mở http://localhost:8081 trên Chrome và Edge hoặc hai profile độc lập. Sau trận, chờ Haskell Exited rồi chạy lệnh sau và tạo phiên mới ở giao diện:

```powershell
docker compose --env-file .docker-runtime/lan/compose.env -p battleship start haskell
```

Chơi LAN dùng Mode Auto và tên adapter thực tế; thiết bị khách mở Player URL helper in ra. Hướng dẫn build, đổi cổng và stop/down nằm trong README gốc.

## 4 Chỉ số đánh giá

Đánh giá bằng tính đúng của trạng thái, riêng tư và vòng đời kết nối. Số liệu dưới đây được viện dẫn từ hồ sơ nghiệm thu đã lưu; việc soạn báo cáo này không chạy lại các suite runtime.

| Hạng mục | Tiêu chí đánh giá | Kết quả đã ghi nhận |
|---|---|---|
| Build Haskell | Build với snapshot đã chốt và -Werror | Qua trên Linux amd64 |
| Kiểm thử Haskell | Số example qua và số lỗi | 908 example, 0 lỗi tại DK-08/DK-09 |
| Frontend | Unit test, TypeScript và build giao diện | 36/36 test; TypeScript/Vite qua |
| Tích hợp Compose | Readiness, game, resume, lỗi và cleanup | 19/19 test, 0 skip tại DK-08 |
| QuickCheck | Mỗi property chạy ít nhất 1.000 trường hợp, có coverage và seed | A-06/B-06 nằm trong suite xanh |
| Trận qua giao diện | Hai người đặt tàu, bắn và kết thúc đúng | Chrome/Edge trên cùng một máy đến thắng/thua |
| Riêng tư | Quan sát không đổi khi bí mật đổi nhưng thông tin công khai giống nhau | Property cho cả P1/P2 và kiểm tra event/UI |
| Đồng thời và queue | Không dùng lượt cũ, không ghi thiếu batch, không vượt capacity | Test STM/TCP, gồm 100 lần race gần giới hạn |
| Dừng dịch vụ | Không treo socket/worker; stop/down trong deadline | Kiểm tra vận hành DK-09 dưới 10 giây |

Không cộng số dữ liệu sinh QuickCheck vào số example Hspec. Tỷ lệ test qua không thay cho đo hiệu năng. Dự án chưa có benchmark tải, độ trễ p95 hoặc đo RAM dài hạn, nên không đưa ra các số liệu này.

Kiểm thử LAN đã qua IP host và hai trình duyệt trên một máy. Hai thiết bị Wi-Fi thật, đổi Wi-Fi vật lý giữa trận và xác nhận A/B/C/D/R còn chờ. Các ca thời hạn năm phút dùng clock kiểm soát, không phải nghiệm thu chờ năm phút trên mạng thật.

## 5 Phân tích bắt buộc

### 5.1 Giải thích cách thiết kế

**Hàm thuần và kiểu dữ liệu.** step nhận người chơi, lệnh và trạng thái, trả lỗi hoặc trạng thái/sự kiện mới. Maybe diễn tả chưa đặt tàu; Either diễn tả thất bại; pattern matching phân biệt phase và command. Lợi ích là tái hiện cùng đầu vào, test độc lập IO và hạn chế thao tác nhầm trên dữ liệu. Fleet che constructor và chỉ được tạo qua Board; riêng Coord/GameState công khai vẫn cần kiểm tra khi dùng.

**STM và batch phản hồi.** Đọc/ghi TVar trong cùng giao dịch giữ state nhất quán khi hai lệnh đến gần nhau. Kiểm tra đủ chỗ cho toàn batch trước commit ngăn nước bắn đã đổi state nhưng SHOT hoặc TURN chưa được xếp. Khóa thủ công có thể thực hiện yêu cầu này nhưng phải quản lý thêm mở/đóng khóa và rollback khi lỗi; STM phù hợp nội dung đã học và dữ liệu dùng chung nhỏ của một trận.

**Queue hữu hạn và client chậm.** Chỉ đổi TQueue thành TBQueue có thể làm giao dịch đợi khi đầy. Preflight, chỗ kết thúc và Quit tạo đường thoát có giới hạn. Đánh đổi là người nhận quá tải bị xử thua; không bỏ âm thầm event vì client có thể mất đồng bộ. Capacity queue không phải giới hạn toàn bộ RAM hoặc bộ đệm kernel.

**Góc nhìn riêng.** Server phát sự kiện đã lọc theo người nhận; không serialize nguyên GameState. Kiểm tra hai bí mật khác nhau với cùng quan sát công khai phát hiện lộ dữ liệu chính xác hơn việc cấm một tên tọa độ xuất hiện, vì tọa độ có thể trùng tàu của người đang xem hoặc ô đã bắn.

**Bridge và Docker.** Bridge giúp trình duyệt dùng WebSocket trong khi lõi giữ TCP đã học. Hai service tách môi trường Node/Haskell, multi-stage giữ công cụ build khỏi runtime. Đánh đổi là thêm codec, phiên và cấu hình phải test. HTTP/Origin/Host hiện phục vụ LAN; chưa có TLS hay cơ chế tài khoản cho triển khai Internet.

**Cập nhật IP và resume.** Helper lấy IPv4 host, ghi file nguyên tử và bridge cập nhật allowlist; TCP/token giữ nguyên nên có thể nối lại. IP container không phải địa chỉ người chơi cần mở. Khi host hoặc tiến trình dừng, RAM mất; Docker không cung cấp khả năng tiếp tục trận sau khi tắt máy.

### 5.2 Ba mươi tình huống cần trình bày khi nghiệm thu

Các dòng dưới đây là ca đúng, ca sai và ca gián đoạn cần phân tích, không phải danh sách 30 lỗi production đã phát hiện. Đối chiếu với BoardSpec, RulesSpec, ViewSpec, ProtocolSpec, CoordinatorSpec, ServerSpec, test bridge/LAN và runner Compose.

| STT | Tình huống | Kết quả mong đợi |
|---|---|---|
| 1 | Đủ năm tàu hợp lệ | Chấp nhận, tổng 17 ô |
| 2 | Tàu kết thúc tại J10 | Chấp nhận nếu đúng hướng |
| 3 | Tàu vượt mép bàn | Từ chối, không lưu một phần |
| 4 | Hai tàu dùng chung ô | Từ chối chồng lấn |
| 5 | Hai tàu chạm cạnh | Chấp nhận |
| 6 | Hai tàu dài 3 có ID riêng | Chấp nhận CR và SB |
| 7 | Lặp ShipId hoặc thiếu tàu | Từ chối đội tàu |
| 8 | Đổi thứ tự danh sách tàu | Fleet chuẩn hóa không đổi |
| 9 | Đặt lại sau xác nhận | Trả lỗi, giữ đội tàu cũ |
| 10 | Bắn khi chưa đủ hai đội tàu | Trả lỗi, không tiêu lượt |
| 11 | Bắn sai lượt | Trả lỗi, giữ state |
| 12 | Bắn tọa độ ngoài bàn | Trả lỗi, giữ state |
| 13 | Bắn lặp một tọa độ | Trả lỗi, không tăng history |
| 14 | Bắn vào nước | MISS và chuyển lượt |
| 15 | Trúng nhưng chưa chìm | HIT và giữ lượt |
| 16 | Trúng ô cuối một tàu | SUNK, chưa thắng thì giữ lượt |
| 17 | Trúng ô cuối toàn fleet | WIN, kết thúc ngay |
| 18 | Gửi lệnh sau khi kết thúc | Không đổi winner hoặc state |
| 19 | Đổi tàu bí mật, giữ thông tin công khai | Toàn bộ view vẫn bằng nhau |
| 20 | Lệnh quá dài hoặc thiếu tham số | Parser từ chối |
| 21 | Người thứ ba kết nối | Lỗi phòng đầy, không thay P1/P2 |
| 22 | Hai lệnh cùng dùng lượt cũ | STM chỉ chấp nhận theo state đã commit |
| 23 | Queue thiếu một chỗ cho batch | Hủy batch/nước; Quit đúng người nhận chậm |
| 24 | Một hoặc cả hai client không đọc TCP | Kết thúc và dọn trong deadline |
| 25 | Origin hoặc Host sai | Từ chối WebSocket trước cấp phiên |
| 26 | Mất WebSocket rồi resume trước hạn | Giữ player và lịch sử riêng |
| 27 | Hết hạn resume | Quit đúng người; đối thủ thắng |
| 28 | File LAN cập nhật sai hoặc quá hạn | Loại origin LAN, giữ localhost/phiên sống |
| 29 | Healthcheck nhiều lần, backend chưa ready | Không chiếm slot; web chờ core healthy |
| 30 | Restart giữa trận và Compose down | Phiên cũ mất rõ; dọn container/network/cổng |

Đặc biệt, khi một phát MISS hợp lệ đã chuyển lượt, lệnh của đối thủ đến sau có thể hợp lệ trong cùng đợt gửi gần nhau. Test phải xét thứ tự commit, không áp đặt mọi cặp lệnh đồng thời đều chỉ có một lệnh được chấp nhận.

### 5.3 Vấn đề đã sửa và phần còn mở

Lỗi thực tế đã ghi nhận là đóng TCP khi còn input chưa đọc có thể làm mất GAME_OVER do reset. Server đã sửa bằng gửi kết thúc, half-close, cho reader hiện hữu đọc bỏ dữ liệu hữu hạn rồi đóng; test hồi quy được lưu. Tích hợp UI đã sửa ánh xạ hàng/cột và tên tàu, đồng thời khóa thao tác theo sự kiện server.

Vấn đề còn mở R9-S03-01 là thông báo kết thúc terminal dài 81 ký tự bị xuống dòng trên console 80 cột. Lỗi ảnh hưởng trình bày, chưa làm sai luật hoặc người thắng. Nhóm cần sửa renderer và chạy lại console trước khi đánh dấu hoàn tất.

Trước khi nộp, bổ sung thông tin thành viên, kiểm kê nguồn asset và xác nhận cùng SHA. Nghiệm thu hai thiết bị/đổi Wi-Fi thật được ghi riêng khi có kết quả; không thay bằng test mô phỏng.

### 5.4 Tài liệu đối chiếu

- [Báo cáo kỹ thuật tổng thể](report_final.md), [lý do thiết kế](design_decisions.md) và [luật chơi](game_spec.md).
- [Đối chiếu 14 slide](slide_mapping.md): QuickCheck có trong Chap8; STM, TBQueue và TCP có căn cứ bài giảng. Docker/React/WebSocket là phần mở rộng. NUMA, Map–Reduce và NFS chưa được triển khai.
- [Hướng dẫn kiểm thử](testing.md), [nghiệm thu DK-08](dk08_acceptance.md), [bàn giao DK-09](dk09_handover.md) và [lỗi Đợt 9](round9_fixes.md).
- [Hướng dẫn chạy tại README](../README.md). Bản mẫu này giữ năm mục của tài liệu tham khảo; chi tiết module, commit và log được dẫn đến docs chuyên biệt.
