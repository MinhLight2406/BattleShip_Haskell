# NM-04 — Affinity của container và GHC runtime

Nhánh `Update_NUMA`, ngày thực hiện 2026-10-11. Phụ trách C; D review.
Phụ thuộc [NM-02](numa_environment.md), [NM-03](performance_baseline.md),
tuân thủ [NM-01](numa_design.md). Xác nhận review nhóm chưa được cung cấp.

## 1. Mục đích và phạm vi

NM-04 biến CPU mask thành cấu hình được Linux thi hành, rồi đối chiếu cấu
hình với process thật. Đây là bước triển khai/kiểm chứng affinity trước khi
thêm worker ở NM-05. Không lấy việc cấu hình thành công làm bằng chứng tăng
tốc, giảm cache miss hoặc đặt RAM đúng NUMA node.

Chế độ mặc định vẫn dùng `compose.yaml`. Chế độ affinity thêm override và
launcher; không thay luật, parser, STM, outbox 128/126/2, privacy hoặc resume
5 phút. Đổi profile yêu cầu dừng project và mở trận mới vì state ở RAM.

## 2. Kiến thức và các tầng tài nguyên

| Kiến thức | Cơ chế áp dụng | Bằng chứng/giới hạn |
|---|---|---|
| Chap5 tr. 27–30: pinning/locality, capability | Container cpuset, RTS -N và thử -qa | Docker config + /proc task mask + số capability từ runtime |
| Chap2/Chap4: CPU, cache, locality | Dùng CPU/core/socket/SMT NM-02 để chọn CPU; web auto ưu tiên core khác | CPU logic cùng core có thể chia sẻ tài nguyên; không đo cache hit/miss ở task này |
| Chap5/6: concurrency và STM | Giữ coordinator/state/batch; thử trận thật dưới mask | Affinity không thay synchronization hoặc tạo song song luật |
| Chap7: vòng đời/supervision | Preflight, readiness, rollback project lỗi, SIGTERM và down có deadline | Không chiếm slot P1/P2 để probe readiness |
| Chap8: module/test/hợp đồng | Tách resolve/verify thuần khỏi Docker IO, unit test và container gate | Không thêm dependency production để kiểm tra affinity |
| Chap10/11: process/TCP và tách giao tiếp | Hai service, DNS haskell:4000, HTTP/WS qua public port | Origin/Host, framing, filtering và port mapping giữ nguyên |

CPU logic là ID Linux nhìn thấy, capability là bộ thực thi Haskell trong
GHC; một capability có thể sử dụng nhiều OS thread theo thời điểm. Cả hai
khác core vật lý và NUMA node. Cpuset chỉ hạn chế nơi được chạy; CPU quota
hạn chế lượng thời gian CPU. Task này không đổi quota hoặc memory policy.

Affinity không dành độc quyền CPU: tiến trình khác vẫn có thể chạy trên
cùng CPU/cache. Docker/WSL CPU ID cũng không xác nhận Windows physical CPU
placement. CPU mask không bảo đảm tiến trình luôn chạy hoặc tăng tốc.

## 3. Sản phẩm và lý do thiết kế

| File | Công việc và lý do |
|---|---|
| `compose.affinity.yaml` | Chỉ override cpuset Haskell/web, command RTS list và GHCRTS rỗng; giữ base Compose làm nguồn cổng/security/lifecycle |
| `.env.performance.example` | Chỉ bốn cấu hình tài nguyên; auto đọc topology, không cố định IP hoặc CPU máy tác giả |
| `scripts/start-affinity.mjs` | Launcher preflight → resolve → create → kiểm tra thực → readiness → xác nhận process; fail thì dọn project riêng |
| `scripts/test/affinity.test.mjs` | Unit test mask/capability/mapping/actual mismatch/CLI và proc parser |
| `scripts/test/affinity-compose.test.mjs` | Gate Docker thật: hai profile, golden game, security và stop/restart |
| `app/ServerMain.hs` | Sau thông báo listen, ghi số `getNumCapabilities` thật; không mở endpoint hoặc thêm IO vào Rules |
| `test/SharedContractSpec.hs` | Chuẩn hóa CR cuối dòng để cùng marker LF/CRLF đọc được trên Linux; thêm regression test |
| `.gitignore` | Share mẫu performance; `.env.performance` riêng của máy vẫn được ignore |

Compose `cpuset` được chọn vì Linux/cgroup thi hành giới hạn cho cả process
và các thread, phù hợp hai container đang có. `cpus` hoặc `cpu_quota` không
thay được nó: quota không nói tiến trình chạy ở CPU nào. Không thêm privileged
hoặc SYS_NICE chỉ để pin trong phạm vi CPU đã cấp.

RTS truyền bằng danh sách argv, ví dụ `["4000","+RTS","-N2","-qa","-RTS"]`.
Không ghép shell command hoặc nhét cả câu vào một biến env. Container nhận
`GHCRTS=""` để tránh flags ngoài hợp đồng lẫn vào lần chạy. Mode `container`
không gửi `-qa`; launcher ghi JSON override nhỏ vào `.stack-work/nm04/` để
thêm flag chỉ ở mode `rts`, không gửi một argument rỗng để giả tùy chọn.

## 4. Chọn CPU và kiểm tra trước khởi động

Launcher chạy inspector NM-02 bằng Node của image web trong container probe
tạm: network none, source mount read-only, không mở cổng chơi. Kết quả là
topology của Docker Linux daemon/VM hiện tại, không phải CPU mask Node Windows.
Probe không phải service production thứ ba. Cần image `battleship-web:local`
đã build và Docker local đọc được workspace mount.

- Haskell auto chọn N ID đầu trong tập effective (container mode). Ví dụ N=1
  chọn một CPU logic có thật; không ghi cứng CPU0 vào launcher.
- Web auto ưu tiên CPU ngoài mask Haskell, ở core/socket khác CPU Haskell
  đầu tiên nếu có thông tin. Sau đó ưu tiên CPU ngoài mask; nếu chỉ có một
  CPU thì hai service chia sẻ. Không tự khẳng định hai mask tách nhau hoàn toàn
  nếu người dùng cấu hình nhiều CPU hoặc mask chồng nhau.
- Mask thủ công hỗ trợ danh sách/range; normalize, bỏ trùng và sắp tăng dần.
  CPU offline, ngoài mask được phép hoặc dữ liệu topology không đủ bị từ chối.
- Capability phải là integer dương, không vượt số CPU trong mask Haskell.
  Điều kiện này chặn oversubscription theo logical CPU; không bảo đảm không
  bị quota hoặc SMT làm giảm tài nguyên thực.
- Cấu hình `.env` base vẫn quyết định host/origin/public port/LAN mount.
  Performance file không được dùng thay `.env` triển khai.

### Vì sao hạn chế -qa ở mapping cụ thể?

Tài liệu GHC mô tả -qa dùng OS affinity. Mã GHC 9.10.3 Linux
`setThreadAffinity(n,m)` dùng CPU ID từ n, bước m, tới số processor nhìn thấy;
không chuyển n thành phần tử thứ n của một cpuset rời rạc. Với `4,6`, thử
pin vào 0/1 có thể không được kernel chấp nhận; chỉ nhìn flag không chứng minh
pin đã có hiệu lực. Khi N nhỏ hơn CPU count, thuật toán còn có thể tạo mask
dạng sọc, không phải mỗi capability một CPU singleton.

Vì vậy mode rts trong launcher chỉ nhận **mask 0..N-1, N đúng bằng số CPU**,
và các ID đó phải online/allowed. Đây là hạn chế để nghiệm thu mapping của
GHC 9.10.3, không phải một quy tắc chung rằng CPU phải liên tiếp. Mask bất kỳ
vẫn dùng được bằng cpuset trong mode container.

Sau startup, validator yêu cầu thấy `ghc_worker` với singleton mask cho mỗi
CPU chọn. Main/ticker hoặc thread phụ có thể giữ mask rộng của container.
Snapshot chứng minh mask OS thread quan sát được; không suy thread ID cố định
ứng với một capability mãi mãi, worker game `forkOn` hoặc RAM placement.

## 5. Trình tự start và xác nhận thực tế

1. Kiểm tra Engine Linux, đọc topology, resolve mask/N và validate.
2. Render `compose config --quiet` và model: đúng hai service, Haskell không
   publish cổng, command RTS đúng. Project đã có container thì start từ chối;
   dùng verify hoặc stop, tránh đổi profile làm mất trận đang chơi.
3. Build image nếu không chọn `--no-build`; create container và đối chiếu
   `HostConfig.CpusetCpus` trước khi chạy.
4. Khởi động Haskell riêng, chờ health marker sau listen; không connect cổng
   chơi để probe. Đọc log capability và `/proc/1/task/*/status` của binary thật.
5. Mọi task phải ở trong mask yêu cầu; container mode mọi task giữ đúng mask.
   Mode rts thêm bằng chứng singleton ghc_worker. Config.Cmd phải khớp argv.
6. Sau Haskell được xác nhận, khởi động web và kiểm tra process/thread mask.
   Ghi verification JSON/image ID/model/topology và in URL/cổng public.

Mọi lỗi sau create khiến launcher down đúng project đã chọn. Tên project CLI
giới hạn namespace `battleship-affinity[-suffix]`; không prune Docker. Nếu
cleanup lỗi, thông báo giữ cả nguyên nhân gốc và lỗi dọn. Docker command có
timeout; startup tối đa 60 giây/service sau build. Build có deadline 20 phút.
Stop đi thẳng tới down, không đọc docker info/topology/performance file trước
khi gửi lệnh dừng. Stop wrapper deadline 15 giây; container vẫn có grace 10 giây từ DK-07;
integration gate yêu cầu down/cleanup thực tế dưới 10 giây.

`verify` dùng kiểm tra mask/command/capability trên project đang chạy; không
restart dịch vụ. Haskell đã Finished và thoát thì verify báo không chạy, không
gọi đó là lỗi NUMA hoặc tự khởi động lại một trận.

## 6. Lệnh chạy lại và chuyển chế độ

Node >=24, Docker Desktop ở Linux containers; dùng Docker CLI path nếu chưa
có PATH. Những lệnh dưới chạy tại thư mục repository.

```powershell
Copy-Item .env.example .env
Copy-Item .env.performance.example .env.performance
docker compose --env-file .env build
node scripts/start-affinity.mjs inspect
node scripts/start-affinity.mjs start
node scripts/start-affinity.mjs verify
node scripts/start-affinity.mjs stop
```

Không chép đè `.env` đang cấu hình LAN; nếu file đã có, dùng file đó. Lần start
mặc định build lại source. `--no-build` chỉ dùng khi image hiện tại đã được
build đúng source; log capability thiếu sẽ bị từ chối và rollback.

Container một CPU được chọn: đặt `HASKELL_CPUSET=<ID online/allowed>`,
`HASKELL_CAPABILITIES=1`, `HASKELL_AFFINITY=container`, `WEB_CPUSET=auto`.
RTS experiment: nếu inspector xác nhận CPU0/CPU1, đặt `HASKELL_CPUSET=0,1`,
`HASKELL_CAPABILITIES=2`, `HASKELL_AFFINITY=rts`. Stop rồi start khi đổi.
Không dùng -qa trên `4,6` bằng cách bỏ qua validator.

```powershell
node scripts/start-affinity.mjs start --env-file .env --performance-file .env.performance --project battleship-affinity-demo --no-build
node scripts/start-affinity.mjs verify --project battleship-affinity-demo
node scripts/start-affinity.mjs stop --project battleship-affinity-demo
# Sau stop affinity, chạy lại chế độ mặc định:
docker compose --env-file .env up -d --no-build --wait
```

Chọn localhost/LAN, adapter và cổng theo DK-06/DK-09 trong `.env`; affinity
không biết IP host. Mở terminal riêng chạy helper `-WatchOnly` trước khi start
affinity và giữ nó mở trong trận. Chế độ này chuẩn bị env/origin, theo dõi IP
và không chạy base Compose đè cấu hình CPU. Dùng env file helper vừa in ra:

```powershell
powershell -NoProfile -File scripts/Start-LanCompose.ps1 -WatchOnly -LanInterface "Wi-Fi"
# Terminal khác, thay đường dẫn bằng Compose env mà helper vừa in:
node scripts/start-affinity.mjs start --env-file .docker-runtime/lan/compose.env
```

Không đổi profile giữa trận. Bridge theo dõi nguyên tử origin JSON như DK-06;
đổi IP không cần restart Haskell/web hoặc thay CPU mask.

## 7. Test và bằng chứng nghiệm thu

```powershell
node --test scripts/test/topology.test.mjs scripts/test/benchmark.test.mjs scripts/test/affinity.test.mjs
node --test scripts/test/affinity-compose.test.mjs
stack build
stack test --ghc-options=-Werror
pnpm --dir frontend test
```

Suite unit không cần Docker. Suite container bắt buộc có hai image source hiện
tại và dependency frontend `ws`; thiếu điều kiện làm fail rõ, không skip xanh.
Nếu CPU0/CPU1 không được cấp, ca rts không được nghiệm thu ở máy đó; unit vẫn
kiểm tra lý do từ chối. Dùng phần cứng phù hợp để chạy đủ gate thí nghiệm.

Các test dùng project/cổng riêng, readiness condition và deadline, không sleep
để đoán race. Fixture v1 NM-03 đối chiếu mọi wire frame của hai người; SESSION
kiểm tra chỉ chứa fleet của đúng chủ và không ghi token vào acceptance log.
Suite kiểm tra Origin sai, Origin đúng/Host sai, phòng đầy, healthcheck không
mất P1/P2, toàn trận 25 lệnh và close/stop/restart giữa phiên.

### Kết quả thực tế

Lần chạy ngày **2026-10-11**, Windows 11 build 26200, Docker Engine Linux
29.8.2 / WSL kernel `6.18.40.1-microsoft-standard-WSL2`, Node container
24.21.0. Linux công bố CPU online/allowed 0–11, node 0; một node nhìn thấy
không chứng minh máy vật lý Windows chỉ có một node. GHC 9.10.3/lts-24.59.

| Gate hiện tại | Kết quả |
|---|---|
| Unit riêng affinity | 25/25, 0 fail |
| Topology + benchmark parser + affinity unit | 79/79, 0 fail |
| Frontend/bridge/Docker contract | 36/36, 0 fail |
| Linux build/test -Werror | 909 test chức năng + 15 fixture benchmark, 0 fail |
| Docker/Compose affinity integration | 3/3, 0 fail, 0 skip; khoảng 101,8 giây toàn suite |

Image Haskell hiện tại: `sha256:00c5918e05f2329a010698f1656a9de1939a2a737c57c2f27248dc659d1cc57a`.
Route kiểm chứng dùng cache compiler/dependency Linux DK-04, copy source
hiện tại, chạy lại toàn bộ build/test -Werror rồi lấy runtime stage cùng
Dockerfile production. Không gọi đây là build không cache từ Linux trắng.
Image web DK-05/DK-08 giữ source bridge hiện tại, không cần rebuild vì không
sửa bridge/React; image ID trong evidence. Default start vẫn hỗ trợ build
hai Dockerfile production từ source qua Compose.

| Ca thật | Haskell mask/N | Web mask | Bằng chứng và kết quả | Down |
|---|---|---|---|---:|
| Chọn một CPU logic | 11 / N1 | 0 | PID1 và mọi task Haskell đều [11], web đều [0]; game seed424242 đủ25 lệnh | 900 ms |
| GHC runtime -qa | 0,1 / N2 | 2 | ghc_worker có [0]/[1]; main/ticker [0,1]; web [2]; game seed8675309 đủ25 lệnh | 848 ms |
| Dừng giữa phiên rồi mở trận mới | 0 / N1 | 2 | Hai WS đóng sau SIGTERM; start lại nhận WELCOME 1 P1 | 951 ms |

Các CPU/port/TID/container ID ở bảng là số liệu lần chạy, không phải mặc định
ghi cứng. CPU0/1 được Linux VM báo cùng core/sibling; ca qa này nghiệm thu
mapping/affinity, không gọi đó là hai physical core độc lập. PID1 không cần
singleton ở qa vì thread thực thi/RTS phụ có vai trò khác nhau.

Hai ca full game kiểm tra HTML/health, lặp healthcheck năm lần rồi vẫn nhận
P1/P2, người thứ ba ERROR SERVER_FULL, lỗi trước đặt/lượt/bắn lặp, hai miss,
hit/sunk/win, đúng wire frame và SESSION chỉ giữ đội tàu của chủ. Origin sai
và Origin đúng/Host sai bị từ chối **HTTP 401** theo bridge hiện hành. Public
port ngẫu nhiên khác container8080; Haskell4000 không publish. Test chủ động
đổi cpuset web trong project cô lập: verify từ chối mismatch, khôi phục mask
rồi verify/play xanh. Sau down không còn container của project và bind lại
được public port; kiểm tra cuối không còn container test affinity.

### Các lỗi đã phát hiện và sửa trong quá trình kiểm chứng

1. Lần Linux đầu có 908 test/2 lỗi S-01: tài liệu CRLF từ Windows khiến
   marker không khớp khi đọc nguyên dòng trên Linux. Chuẩn hóa riêng CR cuối
   dòng và thêm regression LF/CRLF; lần cuối 909 test xanh, không nới API/owner.
2. Lần Compose đầu 2/3 qua; game qa đúng nhưng cleanup wrapper 13,2 giây
   vượt gate10 giây. Wrapper gọi docker info trước down, thêm chi phí không
   cần cho shutdown. Đã bỏ bước đó ở action stop, giữ deadline gate10 giây
   và chạy lại toàn bộ ba ca. Các down cuối 848–951 ms; không tăng timeout
   để đánh dấu xanh. Không suy mọi daemon luôn có cùng thời gian dừng.
3. Lệnh pnpm đầu bị EPERM realpath từ giới hạn môi trường thực thi; chạy lại
   test frontend bằng runtime đã cấu hình với quyền thực thi phù hợp, 36/36.
   Không sửa validator frontend để né gate.

Bằng chứng đi cùng source tại [affinity_data/nm04_2026-10-11](affinity_data/nm04_2026-10-11/README.md):
snapshot task/config, transcript game synthetic, source/image hash và log
excerpts. Không ghi token/SESSION. HEAD nền
`94a7aaaf68860a55cb7528c76f7c30f8fc1b6023`; source còn chưa commit, hash file
là định danh thực, không gọi HEAD đã chứa các thay đổi. Native Windows
Haskell không chạy lại trong NM-04; gate Haskell mới là Linux/container.

## 8. Hiệu quả, chi phí và điều còn cần đo

Lợi ích đã có thể nghiệm thu là cấu hình được kiểm tra và có bằng chứng:
mask sai không khởi động trận, capability thật được đối chiếu, GHC -qa không
được công nhận chỉ từ một flag, hai service giữ hợp đồng mạng. Test tách logic
khỏi IO giúp bao phủ CPU ID rời rạc mà không cần đổi phần cứng.

Chi phí là launcher/verification thêm, giới hạn cấu hình -qa và nhu cầu build
image đúng source. Cpuset hẹp có thể làm giảm throughput hoặc tăng latency;
web/Haskell tách CPU cũng chưa chắc nhanh hơn. Baseline NM-03 giữ nguyên như
bằng chứng trước thay đổi; so sánh tốc độ cần cùng workload/flags/quota và
30 mẫu/profile ở task đo sau, không lấy thời gian test chức năng để kết luận.

NM-04 chưa pin game worker tới capability riêng, chưa thay Fleet index,
chưa bố trí RAM NUMA và chưa nghiệm thu local/remote nhiều node. C/D review
CLI/config/log mới trước hợp nhất; test xanh không thay xác nhận thành viên.

Nguồn đối chiếu: [Compose cpuset/command](https://docs.docker.com/reference/compose-file/services/),
[GHC -N/-qa](https://downloads.haskell.org/ghc/9.10.3/docs/users_guide/using-concurrent.html),
[mã GHC 9.10.3 Linux](https://github.com/ghc/ghc/blob/ghc-9.10.3-release/rts/posix/OSThreads.c).
