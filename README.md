# BattleShip Haskell

Trò chơi Battleship dành cho hai người, với luật và server TCP viết bằng Haskell, giao diện web React kết nối qua cầu WebSocket–TCP. Bạn có thể clone dự án và dùng máy cá nhân làm server để chơi trên cùng máy hoặc qua mạng LAN.

## Clone dự án và tự chạy server

Hướng dẫn chính bên dưới dành cho **Windows, PowerShell 5.1+ và Docker Desktop chạy Linux containers**. Máy chủ cần cài Git, Docker Desktop và có Docker CLI/Compose trong PATH. Không cần cài riêng GHC, Stack, Node.js hay pnpm khi chạy bằng Docker; các công cụ được chuẩn bị trong image.

Chỉ máy làm server cần clone/build dự án. Người chơi dùng trình duyệt trên máy đó hoặc thiết bị khác cùng mạng. Máy chủ phải bật, không ngủ và Docker phải đang chạy trong suốt thời gian chơi.

### 1. Clone đúng nhánh

Mở PowerShell tại thư mục bạn muốn lưu dự án:

```powershell
git clone --branch persist-session-and-parser --single-branch https://github.com/MinhLight2406/BattleShip_Haskell.git
cd BattleShip_Haskell
```

Các lệnh tiếp theo đều chạy từ thư mục gốc `BattleShip_Haskell`, nơi có `compose.yaml`. Lần build đầu cần Internet để tải image, compiler và dependency.

<a id="chạy-bằng-docker--hướng-dẫn-chuẩn-dk-09"></a>
<a id="chạy-hai-service-bằng-compose--dk-07"></a>

### 2. Chuẩn bị và build Docker

Mở Docker Desktop, chọn Linux containers và chờ Docker sẵn sàng. Dùng terminal riêng cho Docker; lệnh xóa biến dưới đây tránh cấu hình từ lần chạy native ghi đè env-file và chỉ ảnh hưởng terminal hiện tại.

```powershell
Remove-Item Env:HOST,Env:PORT,Env:PUBLIC_ORIGIN,Env:WEB_PUBLIC_PORT,Env:BATTLESHIP_TCP_HOST,Env:BATTLESHIP_TCP_PORT,Env:BATTLESHIP_BIND_HOST,Env:BATTLESHIP_READY_FILE,Env:BATTLESHIP_SESSION_FILE,Env:LAN_CONFIG_DIR,Env:LAN_ORIGINS_FILE,Env:LAN_INTERFACE -ErrorAction SilentlyContinue

docker info
docker compose version
New-Item -ItemType Directory -Force .docker-runtime/lan | Out-Null
docker compose --env-file .env.example -p battleship config --quiet
docker compose --env-file .env.example -p battleship build
```

Nếu một lệnh báo lỗi, xử lý lỗi đó trước khi chạy bước tiếp theo. `config --quiet` thành công không in lỗi. `build` phải kết thúc với exit code 0; Dockerfile chạy build/test Haskell, build TypeScript/Vite và frontend unit test trước khi tạo runtime image.

Hướng dẫn dùng `.env.example` làm mẫu. Helper ở bước sau tạo cấu hình thực tế tại `.docker-runtime/lan/compose.env`; không cần tự tạo hoặc sửa `.env`.

### 3. Khởi động server: chọn một chế độ

**Chơi trên cùng máy:** chạy lệnh sau rồi mở `http://localhost:8081` bằng hai trình duyệt hoặc hai profile độc lập, ví dụ Chrome và Edge.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Start-LanCompose.ps1 -Mode Localhost -EnvFile .env.example -ProjectName battleship -ConfigDir .docker-runtime/lan
```

Helper Localhost kết thúc sau khi hai service healthy; container tiếp tục chạy.

**Chơi trên hai thiết bị cùng mạng LAN/Wi-Fi:** xem tên card mạng trên máy chủ:

```powershell
. ./scripts/Start-LanCompose.ps1
Get-LanHostInterfaces | Select-Object Name,IsUp,Addresses
```

Thay `Wi-Fi` bằng tên card đang kết nối mạng, ví dụ `Ethernet`, rồi chạy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Start-LanCompose.ps1 -Mode Auto -LanInterface 'Wi-Fi' -EnvFile .env.example -ProjectName battleship -ConfigDir .docker-runtime/lan
```

Giữ terminal Auto mở để helper cập nhật IP mỗi 2 giây. Cả hai người mở **Player URL** được in trong terminal, ví dụ `http://192.168.1.10:8081`. Trên thiết bị khác, `localhost` trỏ về chính thiết bị đó nên phải dùng IP máy chủ.

Hai thiết bị phải truy cập được nhau trong cùng mạng; cho phép cổng web qua firewall trên mạng tin cậy nếu cần. Không cần mở cổng TCP 4000: Haskell chỉ giao tiếp với bridge trong mạng Docker. Hướng dẫn LAN này không tạo link chơi qua Internet.

Nếu cổng 8081 đang bận, thêm `-PublicPort 8082` vào **một trong hai lệnh khởi động trên**, rồi dùng URL cổng 8082. Chọn chế độ/cổng trước khi chơi. Muốn đổi khi deployment đã chạy, kết thúc trận, Ctrl+C helper Auto rồi `down` theo bước 6 trước khi khởi động cấu hình mới.

### 4. Kết nối hai người và chơi

1. Mỗi người mở URL bằng trình duyệt/profile riêng, chọn **Vào phòng tác chiến → Cổ điển**.
2. Đặt đủ năm tàu CV/BB/CR/SB/DD có độ dài 5/4/3/3/2, rồi chọn **Bắt đầu trận**.
3. Người xác nhận và kết nối trước nhận P1, người tiếp theo nhận P2. P1 bắn trước khi cả hai đã đặt tàu hợp lệ.
4. Bấm ô trên bàn đối phương khi đến lượt. Trúng hoặc chìm tàu được bắn tiếp; trượt thì đổi lượt.

Server hiện phục vụ **một trận hai người cùng lúc**; người thứ ba nhận thông báo phòng đầy. Chế độ Trinh sát chưa được hỗ trợ. Nút **Rời trận** gửi lệnh bỏ cuộc; đóng tab hoặc mất kết nối cho phép khôi phục trong 5 phút.

### 5. Xem trạng thái và mở trận mới

Mở PowerShell thứ hai tại thư mục gốc. Dùng đúng env-file helper đã tạo cho cả Localhost, Auto và cổng tùy chọn:

```powershell
docker compose --env-file .docker-runtime/lan/compose.env -p battleship ps --all
docker compose --env-file .docker-runtime/lan/compose.env -p battleship logs --tail 100 haskell web
```

Để theo dõi log liên tục:

```powershell
docker compose --env-file .docker-runtime/lan/compose.env -p battleship logs --follow --tail 30 haskell web
```

Ctrl+C ở terminal xem log chỉ dừng theo dõi log. Haskell `Exited (0)` sau thắng/bỏ cuộc là bình thường vì mỗi lần chạy chỉ xử lý một trận. Web healthy vẫn phục vụ kết quả, không có nghĩa trận mới đã sẵn sàng.

Sau GAME_OVER, chờ Haskell thoát rồi mở trận mới:

```powershell
docker compose --env-file .docker-runtime/lan/compose.env -p battleship start haskell
docker compose --env-file .docker-runtime/lan/compose.env -p battleship ps --all
```

Chờ Haskell healthy; mỗi người chọn **Về trang đầu**, đặt tàu và bắt đầu bằng phiên mới. Không dùng mã khôi phục trận đã kết thúc. Giữ helper Auto chạy nếu dùng LAN.

### 6. Dừng server và khôi phục trận

Lưu **mã khôi phục riêng của mỗi người** trong giao diện trước khi dừng; không chia sẻ mã với đối thủ. Nếu dùng Auto, Ctrl+C terminal helper trước. Sau đó chọn một lệnh:

```powershell
# Dừng, giữ container và dữ liệu.
docker compose --env-file .docker-runtime/lan/compose.env -p battleship stop --timeout 10

# Hoặc xóa container/mạng, vẫn giữ volume dữ liệu.
docker compose --env-file .docker-runtime/lan/compose.env -p battleship down --timeout 10
```

Nhật ký lệnh và phiên khôi phục được lưu trong volume `battleship-state` của project Compose `battleship`. Sau khi bật máy/Docker lại, chạy đúng lệnh khởi động ở bước 3 với cùng project và dữ liệu volume, rồi nhập mã riêng để tiếp tục trận. Khi mất kết nối trong lúc server vẫn chạy, khôi phục trước hạn 5 phút. Nếu IP đổi, mở Player URL mới rồi nhập mã.

**Không thêm `-v` vào lệnh `down` nếu muốn giữ trận:** tùy chọn này xóa volume dữ liệu. Trình duyệt có thể mất `sessionStorage` sau khi đóng nên cần lưu mã riêng. Khi trận kết thúc, ứng dụng xóa nhật ký trận đang chơi. Lưu dữ liệu không giúp server tiếp tục chạy khi máy chủ tắt/ngủ.

### 7. Xử lý lỗi thường gặp

| Hiện tượng | Cách kiểm tra/xử lý |
|---|---|
| Không nhận lệnh `git` hoặc `docker` | Cài công cụ tương ứng, mở terminal mới và kiểm tra PATH |
| Không kết nối được Docker API | Mở Docker Desktop, chọn Linux containers, chờ `docker info` thành công |
| Build lần đầu lâu hoặc lỗi tải dependency | Kiểm tra Internet và lỗi trong log build; chạy lại bước build sau khi xử lý |
| Cổng 8081 đang được sử dụng | Dừng deployment cũ hoặc khởi động với `-PublicPort 8082` |
| Báo lỗi origin/cấu hình | Xóa biến shell như bước 2; dùng env-file hiệu lực `.docker-runtime/lan/compose.env` cho lệnh quản lý |
| Localhost mở được nhưng thiết bị khác không vào được | Kiểm tra Player URL, adapter, cùng mạng, helper Auto, firewall và chế độ cô lập thiết bị của Wi-Fi |
| Web mở được nhưng không vào trận | Xem `ps --all`; nếu trận cũ đã kết thúc và Haskell Exited, chạy `start haskell` rồi tạo phiên mới |
| Không khôi phục được trận | Kiểm tra mã riêng, hạn kết nối lại, volume còn tồn tại và có dùng đúng project `battleship` hay không |

## Thông tin dự án

### Kiến trúc và công nghệ

Luồng kết nối: **trình duyệt React → WebSocket `/play` → bridge Node.js → TCP → server Haskell**. Bridge phục vụ cả giao diện đã build; Haskell giữ luật và trạng thái trận đấu. Bridge lưu nhật ký để dựng lại trận bằng cách phát lại lệnh khi khởi động lại.

| Thành phần | Vai trò |
|---|---|
| Haskell | Kiểu dữ liệu, bàn cờ, luật thuần, góc nhìn riêng và server xử lý đồng thời |
| React, TypeScript, Vite | Giao diện đặt tàu, bắn và theo dõi trận |
| Node.js, `ws` | Cầu WebSocket–TCP, quản lý phiên và khôi phục |
| Docker Compose | Chạy hai service `haskell`/`web`, mạng nội bộ và volume dữ liệu |
| Hspec, QuickCheck, Node test, Playwright | Kiểm thử luật, giao thức, đồng thời, tích hợp và trình duyệt |

Cấu hình mặc định: web public **8081** → bridge trong container **8080**; Haskell dùng TCP **4000**, không publish ra host. HTTP `/healthz` kiểm tra bridge, không xác nhận backend sẵn sàng cho trận mới. Healthcheck Haskell đọc readiness marker để không chiếm slot người chơi.

### Luật chơi

- Bàn 10×10, tọa độ A1–J10; năm tàu dài 5, 4, 3, 3, 2, tổng 17 ô.
- Tàu phải nằm trong bàn và không chồng nhau.
- P1 bắn trước sau khi cả hai đã đặt tàu hợp lệ.
- Bắn trúng/chìm được bắn tiếp; bắn trượt chuyển lượt.
- Lệnh sai hoặc bắn lặp không đổi trạng thái và không mất lượt.
- Người bắn trúng toàn bộ 17 ô tàu đối phương thắng.

Xem [đặc tả luật](docs/game_spec.md) và [giao thức TCP](docs/protocol.md).

### Cấu trúc mã nguồn

| Đường dẫn | Nội dung |
|---|---|
| `src/Battleship/` | Types, Board, Rules, View, Protocol, Coordinator, GameWorker, Server và Client |
| `app/` | Điểm khởi chạy server và client terminal |
| `frontend/` | Giao diện React, bridge và test frontend |
| `test/` | Test Haskell và bộ sinh dữ liệu QuickCheck |
| `docker/`, `compose.yaml` | Dockerfile, cấu hình và tài liệu container |
| `scripts/` | Helper LAN, kiểm thử Docker và công cụ benchmark/runtime |
| `bench/` | Benchmark lõi và đội tàu |
| `docs/` | Đặc tả, kiến trúc, báo cáo, hướng dẫn và bằng chứng theo từng mốc |

Phân công module, chữ ký hàm và hợp đồng tích hợp: [hợp đồng chung](docs/shared_contract.md).

### Chạy trực tiếp để phát triển, không dùng Docker

Cách này cần Stack/GHC phù hợp với `stack.yaml` (LTS 24.59, GHC 9.10.3), Node.js **24+** và pnpm **11.25.0**. Dùng terminal mới, không export `.env.example` của Docker vào môi trường native.

Tại thư mục gốc:

```powershell
stack build
pnpm --dir frontend install --frozen-lockfile
pnpm --dir frontend build
```

Mở hai terminal tại thư mục gốc, mỗi terminal chạy một tiến trình:

```powershell
# Terminal 1: Haskell mặc định lắng nghe ở 127.0.0.1:4000.
stack exec battleship-server -- 4000
```

```powershell
# Terminal 2: lưu phiên vào tệp cục bộ rồi chạy web/bridge.
$env:BATTLESHIP_SESSION_FILE = Join-Path (Get-Location) '.battleship-sessions.json'
node frontend/bridge.mjs
```

Mở `http://127.0.0.1:8080` bằng hai trình duyệt/profile riêng hoặc dùng link LAN bridge in ra. Server và bridge phải tiếp tục chạy. Sau GAME_OVER, chạy lại Haskell để mở trận mới; sau khi dừng cả hai giữa trận, chạy Haskell trước rồi bridge với cùng tệp phiên để khôi phục.

Để chơi bằng terminal thay cho web, chạy server rồi mở hai terminal khác, mỗi terminal chạy:

```powershell
stack exec battleship-client -- 4000
```

Client hướng dẫn đặt tàu và chơi. Hai client này kết nối server localhost; không chạy cùng lúc với hai người đang dùng web vì cùng chia sẻ hai slot.

### Build và kiểm thử

Sau khi cài các công cụ/dependency của cách chạy trực tiếp:

```powershell
stack test --ghc-options=-Werror
pnpm --dir frontend build
pnpm --dir frontend test
```

Kiểm thử hai container cần Docker Linux, hai runtime image vừa build và dependency frontend:

```powershell
node scripts/test-compose.mjs
```

Các bộ test tích hợp, trình duyệt, LAN và runtime profile có điều kiện riêng; xem [hướng dẫn kiểm thử](docs/testing.md), [tích hợp frontend](docs/frontend_integration.md) và [tài liệu Docker](docker/README.md). Kết quả cũ trong báo cáo thuộc ngày/revision được ghi, không thay cho lần kiểm thử checkout hiện tại.

### Tài liệu kỹ thuật và báo cáo

| Nội dung | Tài liệu |
|---|---|
| Chỉ mục toàn bộ tài liệu | [docs/README.md](docs/README.md) |
| Kiến trúc, luồng xử lý | [architecture.md](docs/architecture.md) |
| Luật, giao thức, hợp đồng module | [game_spec.md](docs/game_spec.md), [protocol.md](docs/protocol.md), [shared_contract.md](docs/shared_contract.md) |
| Docker, biến môi trường, Origin/Host và LAN | [docker_deployment.md](docs/docker_deployment.md), [docker/README.md](docker/README.md) |
| Kiến trúc và quyết định thiết kế | [architecture.md](docs/architecture.md), [design_decisions.md](docs/design_decisions.md) |
| Kịch bản demo và bằng chứng | [demo_script.md](docs/demo_script.md), [test_evidence.md](docs/test_evidence.md) |
| Lịch sử phát triển | [development_history.md](docs/development_history.md) |
| CPU affinity và worker | [affinity_runtime.md](docs/affinity_runtime.md), [worker_locality.md](docs/worker_locality.md) |
| Fleet index và NUMA | [fleet_index.md](docs/fleet_index.md), [numa_experiments.md](docs/numa_experiments.md) |
| Hồi quy runtime và đánh giá kỹ thuật | [runtime_regression.md](docs/runtime_regression.md), [numa_acceptance.md](docs/numa_acceptance.md) |

### Phạm vi đã kiểm chứng và giới hạn

Hồ sơ Docker trước đây ghi nhận Linux **amd64** và Chrome/Edge trên cùng máy; helper tự cập nhật IP dành cho Windows. Ngày 2026-10-28, hai ca Compose restart Haskell/web để khôi phục trận **2/2 qua**, dùng bridge hiện tại bind-mount vào image cache; chưa phải build image mới. Xem [log khôi phục](docs/demo/dk10/persistence-restart-results.txt).

Tắt/bật toàn máy, hai thiết bị Wi-Fi thật, đổi Wi-Fi vật lý và arm64 chưa được nghiệm thu. Xác nhận nhóm được ghi riêng trong hồ sơ; test kỹ thuật không thay cho xác nhận đó. CPU affinity/NUMA là các cấu hình thử nghiệm tùy chọn, không cần bật để chơi.
