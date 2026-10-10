# BattleShip Haskell

Dự án Battleship cho hai người chơi qua client terminal hoặc giao diện web. Server TCP giữ trạng thái trận đấu; luật chơi được triển khai bằng các hàm thuần Haskell.

## Chạy bằng Docker — hướng dẫn chuẩn DK-09

Từ thư mục gốc có `compose.yaml`. Cần **Docker Desktop đang chạy Linux containers**, Docker CLI/Compose trong PATH, PowerShell 5.1+ trên Windows và hai trình duyệt/profile độc lập. Chạy sản phẩm bằng Docker không cần cài GHC, Stack, Node hay pnpm trên host; Dockerfile tự build/test trên Linux. Lần build đầu cần Internet và thời gian tải compiler/dependency. Đã kiểm chứng Linux **amd64**; helper tự lấy IP dùng Windows host.

### 1. Chuẩn bị và build

Dùng terminal PowerShell riêng cho Docker. Nếu terminal còn biến từ cách chạy native, xóa chúng **chỉ trong terminal này** để shell không ghi đè env-file:

```powershell
Remove-Item Env:HOST,Env:PORT,Env:PUBLIC_ORIGIN,Env:WEB_PUBLIC_PORT,Env:BATTLESHIP_TCP_HOST,Env:BATTLESHIP_TCP_PORT,Env:BATTLESHIP_BIND_HOST,Env:BATTLESHIP_READY_FILE,Env:LAN_CONFIG_DIR,Env:LAN_ORIGINS_FILE,Env:LAN_INTERFACE -ErrorAction SilentlyContinue
docker info
docker compose version
New-Item -ItemType Directory -Force .docker-runtime/lan | Out-Null
docker compose --env-file .env.example -p battleship config --quiet
docker compose --env-file .env.example -p battleship build
```

`config --quiet` thành công không in lỗi; `build` phải exit 0, đã chạy `stack build`, `stack test --ghc-options=-Werror`, TypeScript/Vite và frontend unit test trong image. `.env.example` là mẫu Docker; không export vào shell native. Hướng dẫn này dùng mẫu bằng `-EnvFile .env.example`, helper tạo env-file hiệu lực riêng, không sửa mẫu hoặc `.env` cá nhân. Nếu Docker CLI chưa được nhận diện, mở terminal mới sau khi cài Desktop hoặc thêm thư mục `resources/bin` của Docker Desktop vào PATH.

### 2. Start: chọn một chế độ

**Localhost**, chơi trên máy chủ bằng Chrome/Edge hoặc hai profile:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Start-LanCompose.ps1 -Mode Localhost -EnvFile .env.example -ProjectName battleship -ConfigDir .docker-runtime/lan
```

Mở **http://localhost:8081** ở cả hai trình duyệt. Helper localhost thoát sau khi hai service healthy; container tiếp tục chạy.

**LAN tự lấy IP**, trước trận lấy đúng tên adapter của host:

```powershell
. ./scripts/Start-LanCompose.ps1
Get-LanHostInterfaces | Select-Object Name,IsUp,Addresses
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Start-LanCompose.ps1 -Mode Auto -LanInterface 'Wi-Fi' -EnvFile .env.example -ProjectName battleship -ConfigDir .docker-runtime/lan
```

Thay `Wi-Fi` bằng tên thực vừa liệt kê, ví dụ `Ethernet`. Dùng link **Player URL** helper in ra trên cả hai thiết bị cùng mạng; không dùng localhost ở thiết bị thứ hai. Giữ terminal Auto mở: nó cập nhật IP mỗi 2 giây. Nếu không có IPv4 LAN, localhost vẫn dùng được. TCP Haskell chỉ ở mạng container, không cần mở/publish cổng 4000 trên host.

**Đổi cổng web**, ví dụ public **8082 → container 8080**, chọn trước trận:

```powershell
# Localhost: helper in http://localhost:8082.
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Start-LanCompose.ps1 -Mode Localhost -PublicPort 8082 -EnvFile .env.example -ProjectName battleship -ConfigDir .docker-runtime/lan
# Hoặc LAN: helper in http://<IP-host-hiện-tại>:8082, tiếp tục cập nhật IP.
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Start-LanCompose.ps1 -Mode Auto -LanInterface 'Wi-Fi' -PublicPort 8082 -EnvFile .env.example -ProjectName battleship -ConfigDir .docker-runtime/lan
```

Chỉ chạy **một** lệnh start phù hợp. Trước khi chuyển chế độ/cổng của deployment đã chạy, kết thúc trận, Ctrl+C helper Auto rồi `down` bằng env-file ở mục 4; sau đó start cấu hình mới. Đổi mapping cổng tạo lại web và mất phiên. IP đổi trong Auto chỉ cập nhật file, không restart. Nếu cần origin cố định, dùng `-Mode Manual -PublicOrigin 'http://<IPv4-host>:8081'`; IP này phải do người vận hành cập nhật, không dùng để tự dò mạng.

### 3. Kết nối hai người và chơi

Mỗi người chọn **Vào phòng tác chiến → Cổ điển**, đặt đủ năm tàu CV/BB/CR/SB/DD dài 5/4/3/3/2 bằng click, rồi **Bắt đầu trận**. Người xác nhận và kết nối trước nhận P1, người tiếp theo P2; người thứ ba báo phòng đầy. P1 bắn trước; trượt đổi lượt, trúng/chìm giữ lượt. Không cần nhập lệnh TCP.

Demo có thể làm lại: P1 đặt ngang tại A1/A2/A3/A4/A5, P2 tại A6/A7/A8/A9/A10. Mỗi người bắn J10 trượt; P1 bắn A6, reload để kiểm tra giữ trận, rồi B6/C6/D6/E6, A7/B7/C7/D7, A8/B8/C8, A9/B9/C9, A10/B10 để thắng. Đây là đội tàu demo được thống nhất, không phải bot/stub. Khi đổi IP giữa trận, lưu mã phiên riêng, mở Player URL mới và nhập mã tại Khôi phục trận **trước hạn 5 phút**; không gửi mã cho đối thủ.

### 4. Trạng thái, log, trận mới và dừng

Mở terminal thứ hai tại root. **Cả localhost/LAN/cổng 8082 ở hướng dẫn này đều dùng đúng cùng env-file dưới đây**; không thay bằng `.env.example` vì helper đã thay mode/port/path:

```powershell
docker compose --env-file .docker-runtime/lan/compose.env -p battleship ps --all
docker compose --env-file .docker-runtime/lan/compose.env -p battleship logs --tail 100 haskell web
# Theo dõi trực tiếp; Ctrl+C chỉ dừng theo dõi log.
docker compose --env-file .docker-runtime/lan/compose.env -p battleship logs --follow --tail 30 haskell web
```

Haskell **Exited (0)** sau thắng/bỏ cuộc là bình thường; web healthy vẫn phục vụ kết quả, không chứng minh có trận mới. Sau GAME_OVER, đợi Haskell Exited rồi:

```powershell
docker compose --env-file .docker-runtime/lan/compose.env -p battleship start haskell
docker compose --env-file .docker-runtime/lan/compose.env -p battleship ps --all
```

Đợi Haskell **healthy**; mỗi người nhấn **Về trang đầu**, đặt tàu và Bắt đầu trận để nhận phiên mới. Không resume token trận cũ. Giữ helper Auto chạy nếu đang chơi LAN; không restart web để mở trận mới.

Để dừng, Ctrl+C helper Auto trước, rồi chọn `stop` (giữ container) hoặc `down` (dọn container/mạng):

```powershell
docker compose --env-file .docker-runtime/lan/compose.env -p battleship stop --timeout 10
docker compose --env-file .docker-runtime/lan/compose.env -p battleship down --timeout 10
```

Sau stop/down, chạy lại lệnh start chế độ đã chọn ở mục 2 để mở deployment/trận mới. Stop/restart/down mất dữ liệu RAM của trận. **Docker không giữ server hoạt động khi máy chủ tắt/ngủ hoặc Docker Engine dừng**; muốn phục vụ liên tục cần một máy chủ luôn bật. Thời hạn nối lại 5 phút chỉ được bảo đảm khi bridge và Haskell còn chạy.

### 5. Kết quả, giới hạn và xử lý lỗi

Đã chạy Linux amd64: 908 ví dụ Haskell, 36 frontend test, 19 test Compose; thêm Chrome/Edge hai tiến trình trên cùng Windows host đến thắng/thua và reload thành công. Log/ảnh tại [nghiệm thu DK-08](docs/dk08_acceptance.md), lệnh chuẩn và hồ sơ bàn giao tại [DK-09](docs/dk09_handover.md); [hợp đồng chung](docs/shared_contract.md#7-hợp-đồng-docker-và-bàn-giao-dk-09) còn chờ review nhóm. Hai thiết bị Wi-Fi thật, arm64, đổi Wi-Fi vật lý và phục hồi sau restart chưa được nghiệm thu.

| Triệu chứng | Kiểm tra/cách xử lý |
|---|---|
| Không kết nối Docker API | Mở Docker Desktop, chọn Linux containers, chờ `docker info` thành công rồi chạy lại |
| Port đang dùng | Down đúng project cũ hoặc chọn `-PublicPort` khác trước trận; không đổi `PORT` container chỉ để đổi URL |
| Conflicting shell / origin sai | Dùng terminal riêng, xóa các biến ở mục 1; giữ đúng env-file hiệu lực của helper cho mọi lệnh |
| LAN không mở được, localhost mở được | Kiểm tra adapter/IP mới, helper còn chạy, hai máy cùng mạng và mạng/firewall có cho phép cổng web; không dùng IP container |
| Web lên nhưng không vào trận | `ps --all`: Haskell đã Exited thì `start haskell`; chờ healthy, tạo phiên mới |
| Phiên cũ lỗi sau restart | Trạng thái/token đã mất; quay về trang đầu và mở trận mới, không thử phục hồi đội tàu cũ |

## Chơi bằng giao diện web

Nhánh `Connect_ui_backend` được rẽ từ `frontend-ui` (`a6ca31f`). Giao diện của nhóm đã kết nối với server Haskell qua cầu WebSocket–TCP. Hướng dẫn đầy đủ, kiến trúc và kết quả test: [docs/frontend_integration.md](docs/frontend_integration.md).

Cần Stack, Node.js 24 trở lên và pnpm 11.25.0. Từ thư mục gốc repository:

```sh
stack build
cd frontend
pnpm install --frozen-lockfile
pnpm build
cd ..
```

Mở hai terminal ở thư mục gốc:

```sh
# Terminal 1: server luật Haskell
stack exec battleship-server -- 4000
# Terminal 2: web server và cầu kết nối
node frontend/bridge.mjs
```

Mở link LAN được terminal cầu web tự in, hoặc `http://127.0.0.1:8080` ở **hai tab**. Chọn Cổ điển, đặt đủ năm tàu, nhấn Bắt đầu trận. Tab xác nhận trước là P1; chờ đủ hai người rồi bấm ô đối phương khi đến lượt. Trượt chuyển lượt; trúng/chìm giữ lượt. Nút Rời trận gửi QUIT để bỏ cuộc ngay; đóng tab/mất Wi-Fi được giữ phiên 5 phút. Người thứ ba nhận lỗi phòng đầy. Không cần nhập giao thức thô.

Server Haskell hiện phục vụ **một trận**. Sau khi thắng hoặc bỏ cuộc, chạy lại lệnh server ở Terminal 1 trước trận mới; cầu web ở Terminal 2 có thể giữ nguyên. Trinh sát chưa được hỗ trợ.

### Cấu hình listener Haskell — DK-02

Không đặt biến môi trường thì server vẫn bind `127.0.0.1:4000`. `BATTLESHIP_BIND_HOST` nhận IPv4 canonical hoặc `localhost`; `0.0.0.0` lắng nghe trên mọi giao diện IPv4, dùng khi bridge ở container khác. Không nhận URL, port kèm địa chỉ, chuỗi rỗng hoặc IPv4 sai. CLI `[PORT]` và port `0` cho test vẫn giữ nguyên.

Ví dụ PowerShell để kiểm tra listener và readiness trực tiếp:

```powershell
$env:BATTLESHIP_BIND_HOST = '0.0.0.0'
$env:BATTLESHIP_READY_FILE = Join-Path $env:TEMP 'battleship-ready'
stack exec battleship-server -- 4000
```

Linux/container dùng `BATTLESHIP_READY_FILE=/tmp/battleship-ready`. Biến này tùy chọn khi chạy native, phải là đường dẫn tuyệt đối đến file trong thư mục đã tồn tại và ghi được. Server xóa marker cũ trước bind, ghi nguyên tử đúng `ready\n` sau `listen`, trước log/callback và xóa khi thoát bình thường, lỗi hoặc hủy có cleanup. Healthcheck chỉ đọc marker, **không connect cổng 4000**. Linux xử lý `SIGTERM` để đóng socket/worker và xóa marker; kill cưỡng bức không chạy finalizer, marker cũ sẽ được xóa ở lần khởi động tiếp theo.

Sau khi thử, bỏ cấu hình để trở lại chế độ localhost:

```powershell
Remove-Item Env:BATTLESHIP_BIND_HOST, Env:BATTLESHIP_READY_FILE -ErrorAction SilentlyContinue
```

```sh
stack test --ghc-options=-Werror --test-arguments="--match DK-02"
```

Hợp đồng hai service, mapping cổng và cập nhật IP LAN: [docs/docker_deployment.md](docs/docker_deployment.md). DK-02..DK-06 đã triển khai listener, bridge, hai image và helper IP Windows. DK-07 có `compose.yaml` để build/chạy hai service; hướng dẫn ở bên dưới.

### Cấu hình bridge — DK-03

`BATTLESHIP_TCP_HOST` mặc định `127.0.0.1`, nhận IPv4 canonical hoặc tên DNS như `localhost`, `haskell`; không nhận URL, port kèm host hoặc chuỗi rỗng. `BATTLESHIP_TCP_PORT` mặc định `4000`. Lỗi DNS/kết nối được log cùng endpoint và đóng WebSocket với mã 1011; bridge tiếp tục chạy và nhận kết nối mới khi backend sẵn sàng.

`HOST`/`PORT` là listener của bridge. `WEB_PUBLIC_PORT` là cổng bên ngoài mà người chơi truy cập; `PUBLIC_ORIGIN` phải dùng cổng này nếu được khai báo. Ví dụ cấu hình dành cho mapping **host 8081 → container 8080**:

```dotenv
HOST=0.0.0.0
PORT=8080
WEB_PUBLIC_PORT=8081
PUBLIC_ORIGIN=http://localhost:8081
BATTLESHIP_TCP_HOST=haskell
BATTLESHIP_TCP_PORT=4000
```

Các biến này chỉ cấu hình ứng dụng; chúng **không tự publish/forward cổng**. `compose.yaml` tạo mapping `8081:8080` mặc định và mạng có service `haskell`. Chạy trực tiếp không có mapping thì bỏ `WEB_PUBLIC_PORT`, dùng `PUBLIC_ORIGIN` cùng cổng `PORT`, và để TCP host mặc định.

Bind `0.0.0.0` cho phép công bố localhost hoặc IP LAN cụ thể. Handshake vẫn yêu cầu Origin nằm trong danh sách cho phép và Host cùng authority với Origin. Khi đặt `WEB_PUBLIC_PORT`, origin nội bộ và origin Vite `:5173` không được tự cho phép. `GET /healthz` trả `{"status":"ok"}` mà không kết nối Haskell hoặc chiếm P1/P2; endpoint này chỉ kiểm tra bridge.

Để cập nhật IP host trong container, dùng `LAN_ORIGINS_FILE` thay cho `PUBLIC_ORIGIN`. Bridge đọc file trước khi listen và mỗi 2 giây; file lỗi/quá hạn sẽ bỏ origin LAN, giữ localhost và các phiên hiện có. Schema, giới hạn và TTL nằm trong hợp đồng Docker. Reader đã có ở DK-03; helper tạo/cập nhật file đã triển khai ở DK-06 bên dưới.

### Image Haskell — DK-04

Đã có `docker/haskell.Dockerfile` với stage build/test/runtime và `.dockerignore`. Ngày 2026-10-10, build Linux amd64 với lts-24.59 / GHC 9.10.3 thành công; toàn bộ `stack test --ghc-options=-Werror` qua **908 ví dụ, 0 lỗi**. Image runtime chạy bằng UID/GID 10001, không thiếu dependency động; **5/5 test runtime** qua với server thật, WELCOME, cấu hình, healthcheck marker và SIGTERM. Lệnh chạy và minh chứng nằm trong [docker/README.md](docker/README.md). Web image và Compose thuộc DK-05/DK-07.

### Image web — DK-05

`docker/web.Dockerfile` ghim Node 24.21.0 bằng digest và pnpm 11.25.0, cài bằng `pnpm-lock.yaml` với `--frozen-lockfile`. Stage test chạy TypeScript, Vite và 36 unit test; runtime chỉ chứa bridge, `dist` và dependency production, chạy user `node` (UID/GID 1000), bridge làm PID 1. Đã nghiệm thu Linux amd64: **36/36 unit test, 6/6 test runtime xanh**; HTML/JS/CSS/PNG hoạt động, cấu hình sai báo lỗi, SIGTERM/SIGINT dọn HTTP/WebSocket/TCP thật. Lệnh build/demo và test ở [docker/README.md](docker/README.md#image-web--dk-05). Helper cập nhật IP host có ở DK-06 bên dưới; Compose production thuộc DK-07.

### IP Windows tự cập nhật cho Docker — DK-06

Helper `scripts/Start-LanCompose.ps1` chạy trên Windows PowerShell 5.1+, lấy IPv4 host, ghi `origins.json` UTF-8 nguyên tử mỗi 2 giây và tạo env-file hiệu lực; không sửa `.env`. Giữ terminal helper mở trong trận. Có thể chọn adapter bằng `-LanInterface 'Wi-Fi'`, đổi cổng bằng `-PublicPort 8081`; không hardcode IP. Khi có nhiều IP host/VPN/virtual adapter, helper in các link và nhắc chọn adapter phù hợp.

```powershell
# Sau khi build image ở mục DK-07: chạy Compose và tiếp tục theo dõi IP.
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Start-LanCompose.ps1 -LanInterface 'Wi-Fi'
# Hai chế độ tĩnh vẫn có: chạy localhost hoặc origin thủ công.
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Start-LanCompose.ps1 -Mode Localhost
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Start-LanCompose.ps1 -Mode Manual -PublicOrigin 'http://<IPv4-host>:8081'
```

Mặc định dùng `.docker-runtime/lan/`, đã được Git/Docker ignore. Compose mount **cả thư mục** chỉ đọc vào web tại `/run/battleship-lan`; helper tạo env-file với `PUBLIC_ORIGIN=` và `LAN_ORIGINS_FILE=/run/battleship-lan/origins.json`, gọi Compose một lần rồi tiếp tục theo dõi. Reader bridge tự thay allowlist, giữ TCP/token/deadline 5 phút và không restart. Thêm `-WatchOnly` nếu chỉ muốn tạo cấu hình/theo dõi, chưa khởi chạy Compose.

Kiểm thử trên Windows host: `pnpm --dir frontend test:lan-helper`; kiểm thử mount/Compose parser/resume với hai image DK-04/05: `node --test docker/test/lan-runtime.test.mjs`. Hợp đồng, lựa chọn chế độ, ưu tiên cấu hình và phạm vi nghiệm thu tại [docs/docker_deployment.md](docs/docker_deployment.md#dk-06-helper-windows-đã-triển-khai).

### Chạy hai service bằng Compose — DK-07

Cần Docker Desktop đang chạy Linux containers. Từ gốc repo, chuẩn bị cấu hình rồi build:

```powershell
# Giữ .env đã có; tạo mới từ mẫu nếu chưa có.
if (-not (Test-Path .env)) { Copy-Item .env.example .env }
New-Item -ItemType Directory -Force .docker-runtime/lan | Out-Null
docker compose --env-file .env -p battleship config --quiet
docker compose --env-file .env -p battleship build
docker compose --env-file .env -p battleship up -d --no-build --wait --wait-timeout 60
```

Mẫu localhost dùng **http://localhost:8081**, mở bằng hai browser/profile riêng. Để chơi LAN tự nhận IP, sau build chạy helper ở mục DK-06; dùng URL helper in ra. Nếu sửa `WEB_PUBLIC_PORT`, sửa origin thủ công cùng cổng; dynamic mode lấy cổng từ helper. Thư mục `LAN_CONFIG_DIR` phải tồn tại trước `up`, cả ở chế độ localhost; mount không tự tạo sai đường dẫn.

Chỉ web được publish; Haskell nhận TCP nội bộ qua `haskell:4000`. Web chờ marker readiness của Haskell với `service_healthy`. Healthcheck Haskell đọc file, web gọi HTTP `/healthz`; cả hai không kết nối cổng chơi. `restart: "no"` giữ hành vi một trận/lần chạy, SIGTERM và grace 10 giây dành cho cleanup.

```powershell
# Các lệnh dưới dành cho deployment manual/localhost dùng .env ở trên.
docker compose --env-file .env -p battleship ps --all
# Sau GAME_OVER, chờ Haskell Exited rồi mở trận mới; web giữ kết quả/phiên cũ.
docker compose --env-file .env -p battleship start haskell
# Dừng toàn bộ dịch vụ và dọn mạng project.
docker compose --env-file .env -p battleship down
# Sau build: chạy bộ test cấu hình/readiness/vòng đời bằng project/cổng riêng.
node --test scripts/test-compose.mjs
```

**Nếu khởi chạy bằng helper**, thay `--env-file .env` bằng `--env-file .docker-runtime/lan/compose.env` (hoặc đường dẫn helper in) và giữ đúng `-p` project. Khi `down`, dừng helper bằng Ctrl+C để ngừng ghi file. Backend kết thúc sau trận là bình thường; `/healthz` của web vẫn khỏe để phục vụ kết quả, không chứng minh backend có trận đang mở. Không restart/recreate giữa trận để đổi IP; helper cập nhật file nóng. Chi tiết kiểm thử và vòng đời ở [docker/README.md](docker/README.md#compose--dk-07).

### Test hai container và nghiệm thu LAN — DK-08

`scripts/test-compose.mjs` mở rộng thành 19 ca: giữ 7 ca DK-07, thêm build từ source sạch, trận đầy đủ, riêng tư, resume/hết hạn đúng 5 phút, restart từng service, đồng thời, TCP không đọc và hai trình duyệt Chromium chơi UI thật. Trên Windows còn kiểm tra helper qua IPv4 LAN của host. Cài dependency và trình duyệt trước khi chạy:

```powershell
pnpm --dir frontend install --frozen-lockfile
pnpm --dir frontend exec playwright install chromium
node --test scripts/test-compose.mjs
```

Runner cần hai image `:local` đã build ở DK-07; dùng project/cổng riêng, log và ảnh tại `.stack-work/dk08/`. Một ca export source không chứa Git/cache/dependency Windows rồi build lại cả hai image, gồm `stack build`, `stack test --ghc-options=-Werror` và frontend test/build trên Linux. Fixture clock và client chậm chỉ phục vụ test, không thêm service hay cấu hình test vào production. Đã nghiệm thu thêm trận bằng **Chrome và Edge trong hai tiến trình riêng trên một máy** qua IP LAN: đặt tàu, chuyển lượt, reload sau A6, trúng/chìm/thắng và riêng tư đều qua. Báo cáo, log/ảnh và phạm vi **hai thiết bị thật chưa thực hiện** tại [docs/dk08_acceptance.md](docs/dk08_acceptance.md).

Test giao diện và tích hợp (chạy từ gốc repository sau khi build):

```sh
pnpm --dir frontend test
stack exec -- node --test frontend/test/integration.test.mjs
pnpm --dir frontend exec playwright install chromium
stack exec -- node --test frontend/test/browser.test.mjs
stack test --ghc-options=-Werror
```

Các test tích hợp tự mở port trống, dựng trận mới và dọn process/socket; không dùng trận đang chơi ở port 4000. Test trình duyệt tự thao tác giao diện, xuất ảnh vào `frontend/test-results/`.

### Tự nhận IP LAN và khôi phục trong 5 phút

Trên nhánh `Updata_Connecting_LAN`, cầu mặc định lắng nghe IPv4 tại `0.0.0.0`, tự đọc IP hiện tại của các giao diện mạng và in link. Không ghi cố định IP Wi-Fi vào mã nguồn. Khi Wi-Fi/IP thay đổi, cầu kiểm tra lại mỗi 2 giây, in link mới và chỉ cho WebSocket dùng origin của IP hiện tại, với Host trùng origin. Link cũ không được giữ trong danh sách cho phép. Kết nối Haskell vẫn là `127.0.0.1:4000`.

Nếu đã dùng cấu hình IP thủ công ở terminal trước, xóa nó trước khi chạy tự động:

```powershell
Remove-Item Env:HOST, Env:PUBLIC_ORIGIN, Env:WEB_PUBLIC_PORT, Env:LAN_ORIGINS_FILE -ErrorAction SilentlyContinue
$env:PORT = '8081'
node frontend/bridge.mjs
```

Terminal in các link lấy từ IP thực tế; hai thiết bị mở link của giao diện Wi-Fi/LAN chung. Nếu máy có cả VPN/máy ảo/Ethernet, có thể chọn đúng giao diện bằng `$env:LAN_INTERFACE = 'Wi-Fi'` (tên lấy từ máy thực tế). Không có IPv4 LAN thì cầu vẫn phục vụ localhost và chờ giao diện mạng xuất hiện.

**Đổi Wi-Fi trong trận:**

1. Lưu **Mã phiên của bạn** trên giao diện trước khi đổi mạng. Mỗi người có mã ngẫu nhiên riêng; không gửi cho đối thủ.
2. Cầu giữ nguyên TCP/P1/P2 và lõi Haskell khi mất WebSocket. Trận tạm dừng, người còn lại thấy thời gian còn lại; không gửi PLACE/FIRE trong lúc chờ.
3. Cầu bắt đầu hạn **300.000 ms** khi phát hiện mất kết nối. Ping mỗi 10 giây phát hiện kết nối im lặng trong khoảng tối đa 20 giây; đóng tab chủ động được phát hiện ngay khi nhận close. Hạn do máy chủ giữ, không bị đặt lại bởi tải trang hoặc thử kết nối thất bại.
4. Giao diện tự thử lại địa chỉ cũ mỗi 2 giây. Nếu IP máy chủ đổi, đọc link mới trên terminal; nhập vào **Địa chỉ máy chủ hiện tại → Kết nối địa chỉ mới**. Hoặc mở link mới rồi nhập mã ở **Khôi phục trận**. Dữ liệu trình duyệt thuộc từng origin, nên không thể trông chờ IP mới tự có mã của IP cũ.
5. Đúng mã và trước hạn: nhận lại chính P1/P2, đội tàu của mình, lịch sử đã lọc và lượt hiện tại; không gửi lại phát bắn cũ. Một mã không được dùng trên hai kết nối đang hoạt động.
6. Hết hạn: cầu gửi QUIT cho Haskell, người mất kết nối thua do bỏ cuộc; kết quả là GAME_OVER ... OPPONENT_LEFT. Có thể quay lại xem kết quả trong 5 phút sau khi phiên TCP kết thúc. Nếu cả hai cùng mất kết nối, phiên hết hạn trước bị xử QUIT trước.

Giữ cả process cầu web và server Haskell chạy khi đổi Wi-Fi. Khởi động lại process sẽ mất phiên đang giữ trong RAM. Hai thiết bị phải cùng mạng có thể liên lạc và firewall cho phép cổng web; tự nhận IP không vượt qua cô lập mạng khách. Chế độ client TCP terminal vẫn dùng luật EOF/QUIT tức thời; hạn khôi phục này áp dụng cho giao diện web qua cầu.

### Cấu hình IP thủ công — tùy chọn LAN-01

Nhánh `Updata_Connecting_LAN` bổ sung `HOST` và `PUBLIC_ORIGIN`. Sau khi build frontend, chạy Haskell server ở một terminal như trên. Trong terminal PowerShell thứ hai:

```powershell
$env:HOST = '192.168.1.10'  # Thay bằng IPv4 Wi-Fi/LAN của máy chạy server
$env:PORT = '8080'
$env:PUBLIC_ORIGIN = 'http://192.168.1.10:8080'
node frontend/bridge.mjs
```

Hai thiết bị cùng LAN mở đúng URL trong `PUBLIC_ORIGIN`; log khởi động cũng in URL này. TCP tới Haskell vẫn là `127.0.0.1:4000` mặc định. Có thể đặt `HOST='0.0.0.0'` để lắng nghe trên mọi giao diện IPv4, nhưng vẫn phải đặt `PUBLIC_ORIGIN` bằng IP LAN thật, không dùng `0.0.0.0` trong URL người chơi.

`HOST` nhận IPv4 hoặc `localhost`; `PUBLIC_ORIGIN` nhận HTTP với IPv4/localhost, có port trùng `PORT` khi không khai báo `WEB_PUBLIC_PORT`, không có đường dẫn/query/credentials. Cấu hình rõ `HOST='127.0.0.1'` để chỉ chạy localhost. Xóa HOST/PUBLIC_ORIGIN/WEB_PUBLIC_PORT/LAN_ORIGINS_FILE để dùng tự nhận LAN; đặt IP thủ công thì IP đó không tự đổi khi Wi-Fi đổi.

Thiết bị ngoài máy chủ cần được mạng Wi-Fi và firewall cho phép truy cập cổng web đã chọn. Quy tắc firewall và nghiệm thu hai thiết bị thật thuộc LAN-05/LAN-06.

Kiểm tra cầu qua IP LAN của chính máy chủ (sau `stack build`):

```powershell
$env:BATTLESHIP_LAN_TEST_HOST = '192.168.1.10' # Thay bằng IP LAN thật của máy
stack exec -- node --test frontend/test/lan.test.mjs
```

Test tự chọn cổng trống, chạy bridge CLI/server Haskell production, kiểm tra HTTP, `WELCOME` P1/P2, từ chối Origin/Host sai, tự tìm IP không truyền HOST/PUBLIC_ORIGIN và khôi phục từ localhost sang origin IP LAN. Test này chạy trên máy chủ qua IP LAN; không thay thế nghiệm thu từ hai thiết bị vật lý.

Test khôi phục phiên và giới hạn thời gian:

```sh
pnpm --dir frontend test
stack exec -- node --test frontend/test/integration.test.mjs frontend/test/reconnect.test.mjs
stack exec -- node --test frontend/test/browser.test.mjs
```

Test clock tăng tốc kiểm tra đúng mốc 299.999/300.000 ms với socket và Haskell thật; test ngắt kết nối dùng hạn ngắn được truyền vào fixture, không đổi hạn 5 phút của CLI production. Test trình duyệt kiểm tra tải lại, chuyển origin bằng mã, riêng tư, tiếp tục bắn và kết quả thua khi quay lại muộn.

**Trạng thái hiện tại:** đã có C-01, A-01, D-01, Board A-02/A-03/A-04/A-06, Rules B-01/B-02/B-04, View B-03/B-06, server C-02/C-05/C-07, codec/client D-02, Coordinator C-03/C-04/C-07 và client tương tác D-03/D-04/D-05. Server thực thi PLACE/FIRE/QUIT qua Rules thật; một TVar giữ GameState, STM commit trạng thái/phản hồi cùng lúc và hai writer gửi từ TBQueue riêng có giới hạn. Client hướng dẫn nhập/sửa năm tàu, nhập bắn theo lượt, cập nhật hai bàn từ dữ liệu riêng tư và hiển thị kết quả đến thắng/thua.

**S-01:** bản hợp đồng chung v2 cập nhật A-02 ở [docs/shared_contract.md](docs/shared_contract.md). Chưa khóa mốc vì còn chờ xác nhận A/B/C/D; việc ẩn constructor Fleet, chủ sở hữu file và quy trình thay đổi được ghi tại đó.

**S-02:** nghiệm thu kỹ thuật lõi thuần và kịch bản 25 lệnh ở [docs/report_final.md](docs/report_final.md); còn chờ A/B xác nhận. Fixture chơi hợp lệ trong test lõi được dựng qua `Rules.step` thật.

**S-03:** đã build sạch, chạy 794 test xanh và chơi trọn trận với hai terminal/lõi thật; [hồ sơ và log demo](docs/s03_acceptance.md). Còn chờ xác nhận A/B/C/D và R; một vấn đề trình bày nhỏ được ghi tại [task Đợt 9](docs/round9_fixes.md).

**S-04:** A-05/B-05/C-06/D-06 đã được kiểm tra kỹ thuật; [hồ sơ chốt tính năng](docs/s04_feature_freeze.md) ghi bản terminal dùng tại mốc đó. Nhánh hiện tại bổ sung GUI theo yêu cầu tích hợp `frontend-ui` ngày 2026-10-05. Việc nhóm xác nhận bản dùng để báo cáo vẫn cần ghi riêng.

## Build và test

### Nghiệm thu đầu cuối D-06 từ checkout sạch

Để dùng bản chốt S-04, clone repository vào thư mục mới và checkout SHA của commit chốt ghi trong [hồ sơ S-04](docs/s04_feature_freeze.md), rồi chạy `stack build` và `stack test`. Không lấy HEAD mới hơn làm bản báo cáo nếu nhóm chưa duyệt revision đó.

Bundle `docs/demo/d06/source.bundle` giữ nguyên snapshot được nghiệm thu D-06 trước khi tạo commit chốt; dùng nó để tái hiện đúng log lịch sử. Từ repository có file bundle, clone vào một thư mục mới (đích phải chưa tồn tại):

```sh
git clone docs/demo/d06/source.bundle .stack-work/d06-replay
cd .stack-work/d06-replay
git status --porcelain
stack build
stack test
stack test --ghc-options=-Werror --test-arguments="--match D-06"
```

`git status --porcelain` phải rỗng trước build; clone không mang `.stack-work` hoặc binary từ bản gốc. Snapshot dùng đúng cấu hình compiler/dependency bên dưới; cache GHC/dependency của Stack có thể được dùng lại. Bundle không phải chữ ký nhóm và SHA snapshot D-06 khác SHA commit chốt S-04.

Sau build, mở ba terminal **cùng tại thư mục checkout vừa tạo**, mỗi terminal chạy một lệnh:

```sh
# Terminal 1
stack exec battleship-server -- 4000
# Terminal 2: đặt tàu và GUI trước để được P1
stack exec battleship-client -- 4000
# Terminal 3
stack exec battleship-client -- --play 4000
```

Nếu port 4000 đang dùng, chọn port khác cho cả ba. Nhập từng tàu theo prompt, xem preview rồi `GUI`; client chưa kết nối khi chưa xác nhận. Chỉ bắn khi hiện lượt của mình. [Kịch bản D-06](docs/d06_demo.md) có đội tàu mới, lệnh lỗi, thắng và cách thử đóng client; có cả bước tự chọn input khác và quyết định từ phản hồi. Test D-06 chạy ba executable production, đọc prompt trước từng input, không nạp sẵn cả transcript vào stdin. Log thực tế và thông tin snapshot nằm ở `docs/demo/d06/`.

Cài Git và Stack (đã kiểm tra với Stack 3.11.1). Cấu hình dùng snapshot LTS 24.59, tương ứng GHC 9.10.3. Stack dùng GHC phù hợp có sẵn trên PATH hoặc cài compiler cần thiết. Lần chạy đầu cần Internet để tải compiler/phụ thuộc.

Từ thư mục gốc của repository, chạy:

```sh
stack build
stack test
```

`stack build` biên dịch thư viện và hai executable. `stack test` chạy Types/Board/Rules/View, Protocol/Client, hợp đồng S-01, Server C-02, Coordinator C-03/C-04, executable và smoke test C-01. Test TCP dùng port do OS cấp, gồm cả stub và Rules production; ProtocolSpec kiểm tra các transcript trong tài liệu. Windows Application Control chặn executable sẽ khiến smoke test thất bại.

Chạy riêng hợp đồng giao thức:

```sh
stack test --test-arguments="--match D-01"
stack test --ghc-options=-Werror --test-arguments="--match D-02"
```

Chạy riêng đối chiếu hợp đồng chung hoặc kiểm tra biên dịch không có warning:

```sh
stack test --test-arguments="--match S-01"
stack test --ghc-options=-Werror
```

Kiểm tra S-01 đọc file trong src/app/test và docs/shared_contract.md từ gốc repository để phát hiện định nghĩa Coord/Command trùng, API lệch tài liệu hoặc file thiếu người phụ trách. Nếu chạy test binary trực tiếp, đặt working directory ở gốc repo.

Chạy riêng A-02:

```sh
stack test --test-arguments="--match A-02"
```

Chạy riêng nghiệm thu đặt tàu A-03:

```sh
stack test --ghc-options=-Werror --test-arguments="--match A-03"
```

BoardSpec gồm test thuần cho đúng năm ID/17 ô, mép A1/J10, tàu dài 3 trùng ID, tàu chạm cạnh và không đặt lại qua Rules.step. Năm test biên dịch chạy GHC có sẵn trong môi trường Stack trên probe tạm: API public hợp lệ phải biên dịch, constructor/record update/coerce/import private phải bị từ chối đúng nguyên nhân. Probe chỉ dùng package đã build, được xóa sau test; không cần dependency mới.

Chạy riêng QuickCheck A-06/B-06 (mỗi property tối thiểu 1.000 trường hợp):

```sh
stack test --ghc-options=-Werror --test-arguments="--match=A-06"
stack test --ghc-options=-Werror --test-arguments="--match=B-06"
```

Hai bộ test dùng chung generator trong `test/TestSupport/Generators.hs`, độc lập với các hàm kiểm tra của Board. B-06 tạo trạng thái qua `step`, đối chiếu view với sự kiện quan sát được và so sánh hai trận có ô bí mật khác nhau nhưng cùng sự kiện công khai, kể cả Sunk và kết thúc. Khi lỗi, Hspec in phản ví dụ và lệnh chạy lại có seed; ví dụ thêm `--seed=20261009` vào `--test-arguments`. Giữ nguyên code và phiên bản dependency khi tái hiện seed. Test ngẫu nhiên không thay thế chứng minh bất biến.

Chạy riêng luật B-01/B-02:

```sh
stack test --ghc-options=-Werror --test-arguments="--match B-01"
stack test --ghc-options=-Werror --test-arguments="--match B-02"
```

`step :: Step` có đủ nhánh Command/Phase. FIRE kiểm tra readiness → lượt → tọa độ → bắn lặp; sai trả Left và không tiêu lượt. FIRE hợp lệ ghi đúng một tọa độ/kết quả vào `playerShots` của người bắn; `shotsReceived opponent state` đọc chính lịch sử đó cho bàn đối thủ, không lưu bản sao thứ hai. Miss đổi lượt; Hit/Sunk giữ lượt; trúng toàn bộ ô tàu trả Win và Finished. Sự kiện là ShotResolved rồi TurnReady hoặc GameEnded, không có TURN sau WIN. C-03 kiểm chứng Coordinator giữ state cũ khi Left qua unit test và TCP thật.

Chạy riêng nghiệm thu S-02 (26 test, không mở socket/server trong các test này):

```sh
stack test --ghc-options=-Werror --test-arguments="--match S-02"
```

Stack vẫn biên dịch các build-tools của package. Kịch bản gọi trực tiếp `step` từ trạng thái rỗng, kiểm tra đặt tàu/chờ/trượt/trúng/chìm/thắng và giữ trạng thái khi lệnh sai; bảng sự kiện cùng lệnh biên dịch riêng lõi chỉ với `base`/`containers` có trong báo cáo.

Chạy riêng góc nhìn và lọc bí mật B-03:

```sh
stack test --ghc-options=-Werror --test-arguments="--match B-03"
```

`View.viewFor` trả fleet của chính người nhận, lịch sử bắn ra/bắn vào, phase và readiness của đối thủ. Không trả fleet đối thủ hoặc tự lộ tàu khi kết thúc. Test kiểm tra P1/P2, 72 bố trí đối thủ, mọi tọa độ chưa bị bắn, cùng tọa độ trên hai bàn và toàn ván đến thắng. Wire v1 tiếp tục gửi sự kiện đã lọc qua Coordinator/Protocol, không gửi snapshot PlayerView hay serialize GameState.

Thử hàm thuần bằng `stack ghci battleship-haskell:lib`:

```haskell
import Battleship.Types
import Battleship.Board
let placements = [ShipPlacement ship (Coord 1 row) Horizontal | (ship, row) <- zip [Carrier, Battleship, Cruiser, Submarine, Destroyer] [1..5]]
placeFleet placements -- Right fleet hợp lệ, đủ 17 ô
placeFleet (take 4 placements) -- Left (InvalidFleetSize 4)
shipCells (ShipPlacement Carrier (Coord 9 10) Horizontal) -- Left (ShipOutOfBounds Carrier (Coord 11 10))
```

`Fleet(..)` và record update `fleet { fleetShips = ... }` không còn là API công khai. Tạo fixture/game fleet bằng `placeFleet`; đọc các ô qua `fleetShips fleet`. Module `Battleship.Internal.Fleet` chỉ dành cho Board/Types và không được expose cho executable/client.

Mô phỏng một ván thuần trong GHCi, từ đặt tàu đến P1 thắng (không cần server):

```haskell
import Battleship.Rules
import Battleship.Types
import Battleship.Board
import Control.Monad (foldM)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
let p1 = [ShipPlacement ship (Coord 1 row) Horizontal | (ship, row) <- zip [Carrier, Battleship, Cruiser, Submarine, Destroyer] [1..5]]
let p2 = [placement { placementStart = Coord 1 (coordRow (placementStart placement) + 5) } | placement <- p1]
let play (state, batches) (player, command) = do { (next, events) <- step player command state; pure (next, batches ++ [events]) }
let game = do { fleet <- placeFleet p2; foldM play (initialGameState, []) ([(P1, PlaceFleet p1), (P2, PlaceFleet p2)] ++ [(P1, Fire cell) | cell <- Set.toList (Set.unions (Map.elems (fleetShips fleet)))]) }
fmap (gamePhase . fst) game -- Right (Finished P1 AllShipsSunk)
fmap (Map.size . shotsReceived P2 . fst) game -- Right 17
fmap (take 1 . reverse . snd) game -- batch cuối gồm ShotResolved ... Win, GameEnded P1 AllShipsSunk
```

## Cập nhật nguyên tử C-04

```sh
stack test --ghc-options=-Werror --test-arguments="--match C-04"
```

Coordinator giữ một TVar GameState và hai TBQueue cho P1/P2. Mỗi submit đọc state, gọi step, encode/lọc, kiểm tra chỗ cho cả batch rồi ghi state + toàn bộ phản hồi trong cùng atomically. Lệnh lỗi chỉ xếp phản hồi actor-only và giữ state nếu queue đủ chỗ; quá tải áp dụng Quit như mục C-07. Writer riêng lấy frame từ queue và gửi socket ngoài giao dịch. GAME_OVER nằm trước marker kết thúc; server chờ mọi writer đã được admission dọn xong rồi đóng. MVar chỉ giữ registry/cleanup, không giữ bản sao GameState. Test C-04 gồm 250 cuộc đua có barrier, rollback lỗi/retry, FIFO và commit khi queue chưa được đọc.

## Hàng đợi giới hạn và client chậm C-07

Mỗi người có **128 phần tử** trong TBQueue: phản hồi thường tối đa **126**, dành **2 chỗ** cho `GAME_OVER` và marker kết thúc. Giới hạn áp dụng cho dữ liệu đang nằm trong queue; frame đang gửi và bộ đệm TCP của OS được tính riêng. Giới hạn dòng TCP vẫn là 256 byte payload.

Coordinator kiểm tra toàn bộ batch cho cả hai người trong STM trước khi ghi. Nếu không đủ chỗ, lệnh gây tràn không ghi nước bắn/đội tàu hoặc một phần phản hồi; coordinator gọi `Rules.step overloadedPlayer Quit oldState` và chốt bỏ cuộc. Người bị ngắt là **người nhận có queue quá tải**, có thể khác người gửi lệnh. Nếu cả hai quá tải trong cùng batch, P1 bỏ cuộc trước, cả hai socket được đóng. Sau Finished, EOF/QUIT không đổi người thắng.

Worker riêng đóng socket quá tải ngoài STM để đánh thức reader/writer; writer bỏ phần chưa gửi tới marker, không chờ client đó đọc. Đối thủ còn đọc nhận GAME_OVER đúng thứ tự. Watchdog gửi 2 giây và grace cleanup 200 ms giữ nguyên. Không có timeout nhập tàu/nước bắn mới. Khoảng nối lại **5 phút của phiên web** vẫn do bridge quản lý.

```sh
stack test --ghc-options=-Werror --test-arguments="--match=C-07"
stack build
stack test --ghc-options=-Werror
```

Test C-07 dùng queue 5/8 phần tử và cổng đồng bộ: kiểm tra giới hạn mặc định, thiếu một chỗ, rollback batch, đúng người quá tải, kết thúc khi đầy, 300 cuộc đua STM (100 lần/kịch bản), TCP không đọc và cleanup trong deadline 10 giây. Client đọc bình thường được thử gửi/đọc vượt 128 phản hồi theo thời gian; bộ test tích hợp vẫn chơi trọn trận.

API coordinator thêm `newCoordinatorWithCapacity` (tối thiểu 5), `queuedFrameCount`, `isSlowClient`; `submitTooLong` thêm `Step` để đường Quit quá tải dùng đúng lõi. Cần nhóm review thay đổi API trước hợp nhất; chi tiết tại [hợp đồng chung](docs/shared_contract.md#giới-hạn-và-chính-sách-client-chậm-c-07). Không đổi luật R-01 hoặc wire v1.

## Chạy và kiểm tra server C-02/C-03/C-04

Khởi chạy server trong terminal thứ nhất (mặc định port 4000):

```sh
stack exec battleship-server
stack exec battleship-server -- 4001
stack exec battleship-server -- --help
```

Chọn một lệnh khởi chạy. Server in `Battleship server listening on 127.0.0.1:4000` rồi tiếp tục lắng nghe. Port `0` cho phép OS chọn port trống; dòng startup ghi port thực tế. Port sai hoặc bind thất bại được báo ở stderr và thoát với exit code khác 0.

Mở hai terminal PowerShell khác và chạy đoạn sau ở mỗi terminal (sửa port nếu cần):

```powershell
$tcpDemo = [System.Net.Sockets.TcpClient]::new()
try {
    $tcpDemo.Connect('127.0.0.1', 4000)
    $tcpReader = [System.IO.StreamReader]::new($tcpDemo.GetStream())
    while ($null -ne ($tcpLine = $tcpReader.ReadLine())) { $tcpLine }
} finally {
    $tcpDemo.Dispose()
}
```

Terminal kết nối trước nhận `WELCOME 1 P1`, terminal sau nhận `WELCOME 1 P2`; cả hai giữ kết nối dù chưa gửi lệnh. Chạy lại đoạn đó trong terminal thứ ba: chỉ nhận `ERROR SERVER_FULL` rồi EOF. Đóng một terminal client để ngắt kết nối; người còn lại nhận `GAME_OVER <người còn lại> OPPONENT_LEFT`, server đóng session và dừng. Muốn thử trận mới, khởi chạy server lại. Nhấn Ctrl+C ở terminal server để dừng và cleanup.

C-03 nhận PLACE/FIRE/QUIT theo [giao thức v1](docs/protocol.md), parser từ chối cú pháp/tọa độ sai; Board/Rules quyết định lỗi nghiệp vụ và kết quả. FIRE trước khi đủ hai fleet trả `ERROR FLEETS_NOT_READY`. Dòng quá dài nhận `ERROR LINE_TOO_LONG` rồi kết thúc session theo D-01. Không tái sử dụng slot hay nhận người thay thế. Đoạn PowerShell trên chỉ giữ kết nối/đọc để thử slot; nghiệm thu đặt tàu/bắn dùng test TCP bên dưới.

Chạy các kiểm thử tự động tương ứng:

```sh
stack test --ghc-options=-Werror --test-arguments="--match C-02"
stack test --ghc-options=-Werror --test-arguments="--match C-03"
```

## Đặt tàu theo hướng dẫn D-03

Khởi chạy server, rồi mở hai terminal client. Dùng port đang hiển thị ở server:

```sh
stack exec battleship-client -- --place 4000
```

Không truyền đối số (`stack exec battleship-client`) cũng mở hướng dẫn, dùng port 4000. Nhập từng tàu theo prompt CV/BB/CR/SB/DD, độ dài cố định 5/4/3/3/2. Chỉ nhập tọa độ đầu và hướng: H ngang sang phải, V dọc xuống dưới. Client cho nhập chữ thường/khoảng trắng linh hoạt; wire vẫn theo v1.

Ví dụ đội tàu hợp lệ; nhập lần lượt mỗi dòng khi terminal hỏi:

```text
A1 H
A2 H
A3 H
A4 H
A5 H
```

Tọa độ nằm trong A1..J10. Tàu không được vượt mép/chồng lên nhau, được chạm cạnh. Sai input sẽ báo lỗi và hỏi lại chính tàu đó. Đủ năm tàu thì hiện bàn 10×10: CV/BB/CR/SB/DD là ô tàu của mình, dấu chấm là ô trống. `SUA CV` (hoặc BB/CR/SB/DD) sửa một tàu rồi xem lại; ví dụ đổi CV thành `A6 V`. `GUI` xác nhận và gửi **một** PLACE đã kiểm tra; `HUY` hoặc EOF trước GUI hủy mà không kết nối/gửi gì.

Client chỉ kết nối sau GUI; P1/P2 được gán theo thứ tự kết nối đó, không theo thứ tự mở terminal. Sau OK PLACE, giữ socket để nhận WAITING/START/TURN/INCOMING/GAME_OVER và chơi D-04 bên dưới. Nhập tại terminal và chờ đối thủ sau OK không chịu timeout 10 giây; connect/handshake/đợi OK vẫn có deadline. Ctrl+C rời trận và đóng socket. Bản xem trước chỉ lấy fleet của mình, không yêu cầu dữ liệu bí mật của đối thủ.

```sh
stack test --ghc-options=-Werror --test-arguments="--match D-03"
```

## Bắn và theo dõi lượt D-04

Dùng hai terminal `stack exec battleship-client -- --place 4000` như trên. Sau GUI, làm theo thông báo:

| Thông báo/giai đoạn | Việc tiếp theo |
|---|---|
| Đang chờ đối thủ đặt tàu | Giữ kết nối, chưa bắn; Ctrl+C để rời trận |
| Đến lượt bạn bắn | Nhập `A1` hoặc `FIRE A1`, rồi Enter; `QUIT` để rời trận |
| Lỗi tọa độ/cú pháp/bắn lặp | Nhập lại; lỗi địa phương không gửi lệnh và không mất lượt |
| Đã gửi phát bắn | Chờ server trả SHOT và TURN/GAME_OVER; không gửi phát thứ hai trước phản hồi |
| Trượt / lượt đối thủ | Chờ; INCOMING mô tả nước bắn vào bàn mình |
| Trúng / chìm | Đọc kết quả; chỉ nhập tiếp khi server thông báo đến lượt bạn |
| Bạn thắng / bạn thua | Trận đã kết thúc, client đóng kết nối; khởi động server lại để chơi ván mới |

Chấp nhận chữ thường/khoảng trắng: `fire j10` gửi `FIRE J10`; Backspace xóa ký tự nhập sai. Dòng ASCII quá 256 ký tự bị từ chối; client nhớ các ô đã bắn thành công để báo bắn lặp tại chỗ. Server vẫn quyết định luật/kết quả và kiểm tra tất cả lệnh. Khi đang nhập dở, thông báo kết thúc vẫn được đọc và hiển thị; không phải nhấn Enter mới biết đối thủ đã rời trận. EOF lúc được hỏi bắn gửi QUIT; lúc đang chờ, dùng Ctrl+C để rời trận.

```sh
stack test --ghc-options=-Werror --test-arguments="--match D-04"
```

## Chơi trọn trận và xem hai bàn D-05

Mở ba terminal: một server và hai người chơi.

```sh
# Terminal server
stack exec battleship-server -- 4000
# Terminal người chơi thứ nhất
stack exec battleship-client -- 4000
# Terminal người chơi thứ hai
stack exec battleship-client -- --play 4000
```

Mỗi người nhập năm tàu theo hướng dẫn (`A1 H`, ...), xem trước rồi chọn `GUI`. Khi được báo đến lượt, chỉ nhập tọa độ như `A6`; client tự tạo thông điệp giao thức. Không cần tự viết PLACE/FIRE hoặc mã P1/P2. `--place [PORT]` vẫn chơi đầy đủ như các ví dụ cũ; chạy client không tham số dùng cổng 4000.

Sau xác nhận đặt tàu, client in hai bàn cạnh nhau và cập nhật sau mỗi phát bắn đã nhận từ server:

| Ký hiệu | Ý nghĩa |
|---|---|
| CV/BB/CR/SB/DD | Ô tàu của mình chưa bị bắn |
| `.` | Nước trên bàn mình |
| `?` | Ô đối thủ chưa bắn, vẫn được giấu cả sau kết thúc |
| `o` | Phát bắn trượt |
| `X` | Phát bắn trúng |
| `#` | Phát bắn làm chìm một tàu |
| `*` | Phát bắn thắng trận |

`#` chỉ đánh dấu ô của phát bắn làm chìm; các ô trúng trước đó giữ `X`. Client không suy đoán các ô còn lại của tàu đối thủ từ mã SUNK. Kết quả thắng/thua được in cuối cùng sau hai bàn cuối. Hướng dẫn nhập, sửa sai, chờ lượt và rời trận ở phần D-03/D-04 vẫn áp dụng.

```sh
stack test --ghc-options=-Werror --test-arguments="--match D-05"
```

## Client một lệnh D-02

Trong terminal khác khi server đang chạy, chọn một lệnh:

```sh
stack exec battleship-client -- 4000 "QUIT"
stack exec battleship-client -- 4000 "FIRE A1"
stack exec battleship-client -- 4000 "PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H"
stack exec battleship-client -- --help
```

Có thể bỏ PORT để dùng 4000, ví dụ `stack exec battleship-client -- "QUIT"`. Chế độ một lệnh nhận WELCOME, gửi đúng một lệnh, hiển thị UTF-8 rồi đóng socket sau phản hồi, khiến session kết thúc. Dùng để kiểm tra nhanh; dùng `--place` ở trên để đặt tàu và chơi trọn ván theo hướng dẫn. Lệnh thiếu tham số/tọa độ sai bị từ chối trước khi kết nối.

`package.yaml` là nguồn cấu hình package; file `.cabal` được Stack/Hpack sinh tự động. Giữ `stack.yaml.lock` trong Git để chia sẻ cùng snapshot.

`Types` dùng `containers` cho `Map`/`Set`; C-02/D-02 dùng `network` cho TCP, `bytestring` cho framing/codec theo byte, `async` cho vòng đời worker và deadline. C-04/C-07 dùng `stm` cho TVar/TBQueue/atomically trong server và test; D-04 dùng TQueue cho Response đọc từ mạng. D-04 khai báo `Win32` chỉ khi `os(windows)`, dùng binding console sẵn trong GHC để nhận sự kiện khi đang nhập dở; CPP bỏ import/cài đặt Win32 trên nền tảng khác. Hai Main dùng PortNumber từ `network`; ClientMain dùng `bytestring` để đưa lệnh CLI vào parser. Test suite dùng Hspec, `network`/`async` để kiểm tra TCP thật, `process` để khởi chạy executable và `directory`/`filepath` để đối chiếu cây nguồn S-01 trên Windows/Linux. `docs/protocol.md` là data file để test đọc đúng tài liệu qua module Cabal tự sinh `Paths_battleship_haskell`. A-06/B-06 dùng QuickCheck trong test suite cho tính chất đội tàu và góc nhìn riêng; chưa cần thêm text.

Thành viên A/B/D lấy nhánh nền đã chứa C-01 bằng `git fetch origin` và checkout/pull nhánh được nhóm thống nhất, rồi chạy hai lệnh trên trước khi thêm mã của mình.

## Luật chính

- Bàn 10×10, tọa độ A1–J10; mỗi người đặt năm tàu dài 5, 4, 3, 3, 2.
- Player 1 bắn trước sau khi cả hai đã đặt tàu hợp lệ.
- **Bắn trúng được bắn tiếp**, kể cả khi làm chìm tàu. **Bắn hụt mới chuyển lượt**.
- Lệnh sai hoặc bắn lặp không làm đổi trạng thái và không mất lượt.
- Người bắn trúng toàn bộ 17 ô tàu của đối phương thắng ngay.

Luật đầy đủ ở [docs/game_spec.md](docs/game_spec.md). Sơ đồ hoạt động ở [docs/architecture.md](docs/architecture.md); giao thức v1 đã chốt ở [docs/protocol.md](docs/protocol.md).

## Phân công thư mục

| Thành viên | File phụ trách |
|---|---|
| A | `Types.hs`, `Board.hs`, `BoardSpec.hs` |
| B | `Rules.hs`, `View.hs`, test luật và góc nhìn |
| C | `Coordinator.hs`, `Server.hs`, `ServerMain.hs`, test đồng thời |
| D | `Protocol.hs`, `Client.hs`, `ClientMain.hs`, test giao thức và tích hợp |
| R | `docs/`, báo cáo, minh chứng kiểm thử và demo |

Trước khi tích hợp nghiệp vụ tiếp theo, cả nhóm review và ghi xác nhận S-01 v2 tại [docs/shared_contract.md](docs/shared_contract.md), gồm các cập nhật đến B-03/C-04. Phân công chi tiết gồm cả Main, test và YAML nằm ở đó. Board/Types, Rules/View, Coordinator/server STM, codec và client đặt tàu/bắn/render diễn biến trận đã có cài đặt; đối chiếu hồ sơ S-03 và các task sửa Đợt 9 trước khi chốt nghiệm thu nhóm.
