# NM-03 — Benchmark tái hiện và baseline trước tối ưu

**Hồ sơ lịch sử:** số liệu NM-03 bên dưới giữ nguyên source và bốn layer lúc đo.
Sau NM-05, runner hiện tại có thêm layer `worker`; kết quả mới và so sánh xem
[worker_locality.md](worker_locality.md). Không ghi đè dữ liệu baseline bằng mã mới.

Nhánh **`Update_NUMA`**, ngày thực hiện **2026-10-11**, Asia/Saigon.
Phụ thuộc [NM-01](numa_design.md), [NM-02](numa_environment.md), A-06/B-06.
Phụ trách B; A/C hỗ trợ. Xác nhận review thành viên nhóm chưa được cung cấp.

## 1. Mục đích và phạm vi

Baseline lưu cách hệ thống hiện hành chạy trước các thay đổi worker, affinity,
index Fleet và placement NUMA ở NM-04..07. Đo được cả kết quả tốt, xấu hoặc
không rõ khác biệt mới cho phép nhóm lựa chọn bằng chứng khi tối ưu.

Bốn workload được đo riêng: lõi thuần, coordinator STM, TCP server và
WebSocket qua bridge. Cùng seed giữ đội tàu, thứ tự lệnh và phản hồi cố định.
Đây là các phép đo có phạm vi khác nhau; không lấy chênh lệch giữa hai bảng
làm chi phí chính xác của một module nếu công việc bên trong khác nhau.

Không sửa luật, API domain, worker production, cấu hình Compose hoặc chính
sách resume. Build thí nghiệm dùng **`-O2` cho library/executable/benchmark**;
ba profile dùng cùng binary. Cấu hình build production không được đổi thành
`-O2` bởi task này. Các lần so sánh tối ưu sau phải giữ cùng build flags.

## 2. Những file được thêm và vai trò

| File | Công việc |
|---|---|
| [bench/Main.hs](../bench/Main.hs) | Benchmark component; monotonic clock, CPU time, RTS stats và checksum |
| [bench/Fixtures.hs](../bench/Fixtures.hs) | Seed/generator, transcript có kỳ vọng, replay thuần/STM, structural digest, xuất fixture |
| [bench/FixturesSpec.hs](../bench/FixturesSpec.hs) | 15 test: đội tàu, hoàn thành trận, coordinator, checksum cố định và lazy evaluation |
| [bench/fixtures-v1.json](../bench/fixtures-v1.json) | Ba transcript/checksum chốt trước tối ưu, dùng làm golden fixture |
| [scripts/benchmark-runtime.mjs](../scripts/benchmark-runtime.mjs) | Orchestrator, preflight topology, calibration, warm-up, nhiều mẫu, TCP/web và parser/summary |
| [scripts/test/benchmark.test.mjs](../scripts/test/benchmark.test.mjs) | Kiểm tra metric thiếu, parser RTS/JSON, p95, bootstrap và độ nhiễu |
| [docker/benchmark.Dockerfile](../docker/benchmark.Dockerfile) | Image kiểm thử Linux riêng, không phải service Compose production |
| [package.yaml](../package.yaml) | Component `battleship-benchmark` và suite riêng `battleship-benchmark-test` |

Benchmark dùng `TestSupport.Generators` của A-06 ở component test/benchmark,
không sao chép bộ sinh và không đưa QuickCheck vào dependency production.
S-01 được mở rộng để quét thư mục `bench`; bảng ownership ghi ba file Haskell
mới do B phụ trách. API `Coord`/`Command` và Fleet abstract giữ nguyên.

## 3. Kiến thức bài giảng áp dụng vào phép đo

Trang là trang vật lý PDF, từ 1.

| Kiến thức | Cơ chế trong NM-03 | Ý nghĩa |
|---|---|---|
| Buổi 01–03: hàm thuần, kiểu/chữ ký, tính toán theo biểu thức | Replay cùng `step` và `viewFor`, seed/fixture tách khỏi vùng đo | Tái hiện input, biết chính xác công việc nào đang đo |
| ADT/quy nạp: phase, command, event, lỗi và chuỗi chuyển trạng thái | 25 lệnh; kỳ vọng cụ thể cho đặt tàu/lượt/lỗi/kết thúc | Workload không chỉ bắn một ô hoặc dừng giữa trận |
| Chap8: module/package, Hspec/QuickCheck | Component benchmark riêng, generator A-06, suite Hspec riêng | Kiểm thử bộ đo và cô lập dependency thử nghiệm |
| Chap5 tr. 35–40 và Chap6: STM/transaction | `newCoordinator`, `submitCommand`, outbox và drain batch thật | Đo đường commit/lọc phản hồi; không thay coordinator bằng stub |
| Chap5 tr. 27–30, 43–44: capability, locality và profiling | Ba RTS profile N1/N2/default; CPU/GC/allocation và topology NM-02 | Số capability lớn hơn chưa tự chứng minh xử lý nhanh hơn |
| Chap10/11: process, message passing, TCP/client–server | Hai peer thật, readiness callback, framing, response và đóng socket | Đo đường mạng ngoài STM; startup và latency có phạm vi riêng |
| Chap2/Chap4: NUMA/cache | Lưu CPU/node/cache trước đo; ghi thiếu PMU | Một node VM không thành kết quả local/remote nhiều node |

GHC RTS API/flags, Node monotonic clock/`node:test`, SHA-256 và bootstrap là
chi tiết kỹ thuật bổ sung để hiện thực và kiểm chứng nguyên lý đã học. Không
tự cài cache coherence hoặc chứng minh false sharing từ một số latency.

## 4. Thiết kế workload và căn cứ lựa chọn

Ba seed **424242, 8675309, 20261011** theo NM-01. Generator hữu hạn của A-06
sinh hai fleet 5/4/3/3/2, khác danh tính và không chồng lấn. Chỉ `step` qua
smart constructor mới lắp Fleet vào state; không tự dựng Fleet private hoặc
GameState có lịch sử bắn giả. B-06 là gate hồi quy cho tính chất góc nhìn.

Mỗi trận có **25 lệnh**, gồm:

1. Bắn trước khi đặt tàu: `FleetsNotReady`.
2. P1 đặt hợp lệ; đặt lại bị `FleetAlreadyPlaced`.
3. P2 đặt; bắt đầu lượt P1. P2 bắn sai lượt bị `NotYourTurn P1`.
4. P1 và P2 mỗi người bắn trượt một lần, chuyển lượt đúng.
5. P1 bắn lại ô trượt: `AlreadyFired`, không tiêu lượt.
6. P1 bắn đủ 17 ô tàu đối thủ: **12 Hit, 4 Sunk, 1 Win**; kết thúc
   `Finished P1 AllShipsSunk`. Trúng/chìm giữ lượt theo luật hiện hành.

Tọa độ miss chọn từ ô trống theo geometry tham chiếu của generator. Thứ tự
tàu và ô được shuffle theo seed; kết quả mỗi phát bắn ghi tường minh trong
Entry. Workload không chọn lại seed sau khi thấy phép đo thuận lợi.

Checksum semantic cố định:

| Seed | Checksum Word64 dạng chuỗi | Lệnh |
|---|---|---|
| 424242 | `3724987551376790105` | 25 |
| 8675309 | `18305205042670867969` | 25 |
| 20261011 | `658854099022739308` | 25 |

Fixture JSON canonical có SHA-256
`24dfad3f17a6f75cf20b20d15faf9b2d637d73139607331bc004d1cd8bd64a53`.
File pretty-printed có checksum file riêng, khác canonical hash theo cách
định dạng. Runner so fixture sinh với `fixtures-v1.json`, không tự cập nhật
golden khi output thay đổi. Test semantic đối chiếu hằng checksum chốt.

## 5. Đánh giá đầy đủ trong Haskell và tránh chia sẻ kết quả đã tính

Haskell có lazy evaluation. Chỉ gọi `step` hoặc đánh giá constructor `Right`
không chứng minh các map, set, fleet và view bên trong đã tính hết. Một vòng
lặp còn có thể dùng lại thunk đã được ép trước đó và báo thời gian quá nhỏ.

`digestTrace` duyệt có thứ tự toàn bộ state của từng bước, `Either` lỗi/event,
hai PlayerView, mọi ô Fleet và mọi history outcome. Fold accumulator strict
Word64 buộc tất cả giá trị tham gia phép tính; digest thành số chỉ sau khi
duyệt hết. Dữ liệu được gắn tag/size để phân biệt constructor và collection.
Không dùng riêng Show của cả trạng thái để đại diện chi phí lõi game.

Main đọc fixture và initial state qua IORef mỗi lần, gọi `replayPure` có
`NOINLINE`, rồi evaluate checksum. Cách này ngăn vòng đo chỉ dùng một biểu
thức thuần đã tính và chia sẻ giữa các lần. Bộ sinh, fixture và digest kỳ
vọng được chuẩn bị trước đồng hồ; state mới được tạo qua step trong vùng đo.

Hai test cố ý đặt `error` vào fleet của view P2 và ShipId lồng trong `Sunk`.
Nếu digest chỉ tính lớp ngoài, các test sẽ không thấy lỗi; hiện cả hai phát
hiện lỗi như kỳ vọng. Hspec so toàn trace STM với trace thuần và kiểm tra
count/final state, bổ sung cho checksum. Hash không được coi là chứng minh
toán học về tính đúng đắn hoặc cơ chế bảo mật.

Chi phí structural traversal/digest và kiểm tra kỳ vọng là **một phần workload**.
Không gọi số này là thời gian chỉ của một invocation `step`. Cách giữ công
việc quan sát cố định giúp so bản trước/sau mà không sửa API production hoặc
thêm orphan NFData vào domain. Nguyên lý ép sâu tương ứng khác biệt giữa
WHNF và normal form. [deepseq](https://hackage-content.haskell.org/package/deepseq-1.5.1.0/docs/Control-DeepSeq.html).

## 6. Phạm vi từng lớp và vòng đời

| Lớp | Vùng đo | Ngoài vùng đo/giới hạn |
|---|---|---|
| `core` | Nhiều trận mới tuần tự: step, lỗi/event, view P1/P2, structural digest | Generator và chuẩn bị kỳ vọng ngoài clock; không IO mạng/STM |
| `coordinator` | Tạo coordinator mới, submitCommand STM, encode/check batch, drain hai outbox, view/digest | Không writer/socket; đọc/drain theo cách harness, không mô phỏng tranh chấp |
| `tcp` | Hai peer TCP thật, gửi từng lệnh, đợi toàn batch mong đợi của cả hai người | Startup/listen/WELCOME và shutdown không tính vào latency command |
| `web` | Hai peer WebSocket → bridge thật → TCP Haskell → phản hồi đủ batch | Cùng process Node có bridge và peer harness; không render React, không mạng Wi-Fi thật |

Core/coordinator mỗi sample chạy đủ ba seed nhiều vòng. TCP/web mỗi sample
chạy một trận mới, xoay ba seed để 30 mẫu gồm 10 trận/seed/profile. Không bắn
tiếp trên state Finished, không thêm nhiều phòng production để benchmark.

Server mới được khởi động mỗi trận, port 0 và readiness từ output sau listen;
không mở TCP chơi để probe readiness. Hai peer nhận đúng WELCOME P1/P2.
Harness nhận frame FIFO đúng người, kiểm tra mọi frame, từ chối frame dư và
so checksum transcript với fixture. Bridge SESSION/CONNECTION được nhận để
tiếp tục phiên nhưng token/nội dung SESSION không lưu vào artifact.

Web bridge dùng validator cấu hình hiện hành, listener HTTP được hệ điều hành
chọn port trống. Không sửa validator để chấp nhận PORT=0 hoặc nới Origin/Host
chỉ để chạy benchmark. HTTP healthcheck không cần thiết cho phép đo loopback.

Mọi thao tác mạng/cleanup có deadline **10 giây**. Đóng hai peer, bridge và
child server sau từng sample; executable Haskell có thể chạy tối đa **120 giây**
trong harness core/coordinator. Đúng/sai transcript là gate, latency không
được dùng làm assertion CI vì chịu scheduler và tải nền.

## 7. Protocol phép đo và cách đọc metric

- **5 warm-up + 30 measured samples/profile/layer**, 3 block mỗi block 10.
  Có 12 nhóm: 4 layer × 3 profile. Thứ tự profile xoay theo sample; mọi
  profile ở cùng sample index dùng cùng seed.
- N1 calibration tăng số vòng core/coordinator để mẫu đạt khoảng >=1 giây;
  nhắm 1,25 giây có khoảng đệm. Số vòng sau calibration được cố định cho N1,
  N2 và default, không hiệu chỉnh lại cho profile có kết quả khác.
- Mỗi sample là process Haskell mới; warm-up làm nóng điều kiện chung như
  code/page cache của chuỗi chạy. Không khẳng định heap được giữ nóng xuyên
  các process. Trong core/coordinator, nhiều vòng trong cùng sample chiếm
  phần thời gian chính.
- Runtime flags N1 `+RTS -N1 -T`, N2 `+RTS -N2 -T`, default `+RTS -T` dùng
  `-with-rtsopts=-N` hiện hành. Runner bỏ GHCRTS từ môi trường và kiểm tra số
  capability báo thật. `-N` không đặt CPU affinity hay RAM node.
- Summary có median thời gian/command, p95 của sample mean, p95 response
  command cho TCP/web; **hai p95 khác nhau**. Bootstrap median 2.000 lần,
  seed 20261011, khoảng 95%; không xem các command trong một game là sample
  độc lập khi tính CI median.
- Độ nhiễu theo NM-01: `(max(blockMedian)-min(blockMedian))/medianAll <=10%`.
  Vượt ngưỡng đánh dấu unstable; giữ số liệu, điều tra và chạy lại nguyên
  loạt. Không chỉ loại những sample xấu. Chưa đủ bằng chứng thì không chốt
  cấu hình nhanh hơn hoặc thay mặc định.

### Phạm vi metric

| Metric | Ý nghĩa và giới hạn |
|---|---|
| `elapsedNs`, `responseUs` | Monotonic clock; không trộn thời gian chờ người nhập |
| Core/STM `cpuSeconds` | CPU time trong vùng workload; khác wall clock |
| Core/STM `allocatedBytes` | Delta RTS sau collection cuối để hạch toán nursery còn lại; không gồm chuẩn bị fixture |
| `gc*Accounting` | GC delta có collection cuối ở ngoài wall/CPU clock; không chia làm phần trăm elapsed rồi khẳng định GC trong interval |
| `maxLiveBytesProcess` | Max live RTS quan sát theo GC trong process, gồm chuẩn bị; không phải RSS |
| `maxMemoryBytesProcess` | Peak RAM RTS lấy từ OS trong process; không phải chỉ dung lượng fleet hoặc RSS |
| TCP/web RTS stats | Toàn process Haskell, gồm startup/shutdown; allocation/CPU/GC không chỉ là latency 25 lệnh |
| Node CPU/RSS | Bridge và peer harness cùng process; không gọi đó là metric riêng của bridge |
| Context switch/migration/PMU hoặc peak RSS không đo được | null/N/A kèm lý do, không thay bằng số 0 |

`-T`, `-t --machine-readable` và API RTS là nguồn metric thực của GHC.
[GHC 9.10.3 RTS statistics](https://downloads.haskell.org/ghc/9.10.3/docs/users_guide/runtime_control.html#rts-options-to-produce-runtime-statistics).
Không tăng quyền production để đọc PMU. Timing build không dùng eventlog hoặc
cost-centre profiling; overhead của traversal và thống kê RTS được ghi rõ.

## 8. Chạy lại từ source

### Build và gate chức năng

```sh
stack build
stack test --ghc-options=-Werror
stack build --bench --no-run-benchmarks --ghc-options="-O2 -Werror"
node --test scripts/test/topology.test.mjs scripts/test/benchmark.test.mjs
```

Benchmark component riêng không bắt `stack build`/production chạy phép đo.
`stack bench --benchmark-arguments="core 100 +RTS -N1 -T -RTS"` có thể dùng
để thử một workload; baseline 12 nhóm dùng runner dưới đây. Không dùng input
của main CLI server để cài luật mới.

### Linux native/WSL

Build bằng compiler Linux, dùng đường dẫn executable thực tế:

```sh
node scripts/benchmark-runtime.mjs --prepare .stack-work/nm03/provenance.json
node scripts/benchmark-runtime.mjs \
  --bench "$(stack path --dist-dir)/build/battleship-benchmark/battleship-benchmark" \
  --server "$(stack path --local-install-root)/bin/battleship-server" \
  --provenance .stack-work/nm03/provenance.json \
  --build-flags="-O2 -Werror" --output .stack-work/nm03/baseline
```

Bridge cần dependency `ws` production: cài frontend bằng lockfile theo DK-05.
Thêm `--smoke` để chỉ chạy 1 mẫu/nhóm, không warm-up; output có smoke=true và
không được dùng thay baseline 30 mẫu. Chuẩn bị provenance **sau** sửa source,
build/test xong **trước** đo; source thay đổi thì runner từ chối.

### Docker Linux trên Windows

Từ checkout có các source/fixture NM-03, tạo hai image nền theo Dockerfile đã
chốt để không phụ thuộc image local của tác giả. Docker benchmark dành Linux
amd64, copy libgmp theo kiến trúc này; chưa nghiệm thu arm64.

```powershell
docker build --platform linux/amd64 --target test -f docker/haskell.Dockerfile -t battleship-haskell-test:nm03 .
docker build --platform linux/amd64 -f docker/web.Dockerfile -t battleship-web:nm03 .
docker build --platform linux/amd64 -f docker/benchmark.Dockerfile --build-arg HASKELL_BENCH_BASE=battleship-haskell-test:nm03 --build-arg WEB_BENCH_BASE=battleship-web:nm03 -t battleship-benchmark:nm03 .
node scripts/benchmark-runtime.mjs --prepare .stack-work/nm03/provenance.json
New-Item -ItemType Directory -Force .stack-work/nm03/baseline | Out-Null
$nm03Root = (Get-Location).Path
$nm03Out = (Resolve-Path .stack-work/nm03/baseline).Path
docker run --rm --network none --read-only --tmpfs /tmp --mount "type=bind,source=$nm03Root,target=/probe,readonly" --mount "type=bind,source=$nm03Out,target=/results" battleship-benchmark:nm03 --bench /usr/local/bin/battleship-benchmark --server /usr/local/bin/battleship-server --bridge-module /app/bridge.mjs --build-manifest /usr/local/bin/build-source-sha256.txt --provenance /probe/.stack-work/nm03/provenance.json --build-flags=-O2 --output /results
```

Nếu docker/node chưa có PATH, dùng đường dẫn cài đặt theo README/DK-09. Image
thí nghiệm chỉ chạy non-root, loopback trong container; không publish cổng
và không thêm service production. `--network none` vẫn có loopback cho peer.
Binary-source manifest so checksum source đã build với source đang mount;
bridge từ image cũng phải có hash trùng `frontend/bridge.mjs` đang đo.

Artifact mỗi lần chạy: `manifest.json`, `fixtures.json`, `samples.jsonl`,
`summary.json`. Dùng output directory mới hoặc sao lưu cả lần chạy cũ trước
rerun: runner bắt đầu bằng một loạt mới trong thư mục output, không append
loạt mới thành một tập sample đã có.

## 9. Bằng chứng chức năng và môi trường

Gate ngày 2026-10-11:

- Windows: `stack build --bench --no-run-benchmarks --ghc-options=-Werror`
  xanh; suite chức năng **907 examples, 0 failures**; suite benchmark **15/15**.
- Linux GHC 9.10.3: build `-O2`; `stack test --ghc-options="-O2 -Werror"`
  xanh: suite chức năng **908/908**, suite benchmark **15/15**.
- Node test topology + parser/summary: **54/54**; frontend unit/bridge/Docker
  contract **36/36**. Smoke thật 12 nhóm core/STM/TCP/web đều qua.

Linux baseline chạy trong Docker/WSL2 trên Windows 11, không chứng minh NUMA
vật lý Windows. Source đang có thay đổi chưa commit: HEAD nền và hash từng
file trong manifest là định danh thực của lần chạy, không gọi HEAD là commit
đã chứa benchmark. Fixture dùng dữ liệu game nhân tạo; artifact không chứa
resume token hoặc trận người chơi thật.

## 10. Kết quả baseline và diễn giải

### 10.1. Hồ sơ phiên đo

- Bắt đầu **22:18:18**, kết thúc **22:28:30 ngày 2026-10-11** (Asia/Saigon),
  tương ứng `15:18:18.912Z` → `15:28:30.018Z`. Exit code 0.
- **420 mẫu thô = 60 warm-up + 360 measured**; 12 nhóm đều đủ 30 mẫu đo.
  Không loại outlier. Cả 12 nhóm đạt spread block <=10%, nên không cần rerun.
- Core: **1.789 vòng/sample = 5.367 trận = 134.175 lệnh**.
  Coordinator: **1.347 vòng/sample = 4.041 trận = 101.025 lệnh**.
  TCP/web: 1 trận/25 lệnh/sample; 10 trận/seed/profile.
- GHC **9.10.3**, snapshot **lts-24.59**, Linux amd64, `-O2`.
  Node **24.21.0**; Docker Desktop **4.94.0 (241994)** / Engine **29.8.2**.
- Windows 11 build 26200, kernel VM `6.18.40.1-microsoft-standard-WSL2`.
  Linux công bố CPU model `13th Gen Intel(R) Core(TM) i7-1355U`, CPU online/
  allowed **0–11**, 6 core ID/1 socket/2 sibling mỗi core theo VM, node RAM **0**,
  19 nhóm cache. Không xác nhận các giá trị này là topology vật lý Windows.
- Cgroup v2 namespace root đã kiểm tra: `cpu.max=max 100000`,
  `memory.max=max`, `memory.swap.max=max`. Đây là không áp quota ở cgroup này,
  không có nghĩa VM/host cấp tài nguyên vô hạn. RAM node Linux công bố ~7,61 GiB.
- Default thực tế **12 capability**. Không ghim CPU/RAM; không chạy build/test
  nặng song song trong vùng đo. Các ứng dụng Windows/WSL khác có thể gây tải nền.

HEAD nền: `94a7aaaf68860a55cb7528c76f7c30f8fc1b6023`; nhánh `Update_NUMA`.
Source chưa commit: hash từng source trong manifest xác định phiên bản thực.
Image thí nghiệm `battleship-benchmark:nm03`:

```text
sha256:99462ab80cbbe8f8c1bdbd10cf73030f11f413b4a06f037d464268289a37509c
benchmark binary: 24b5e6a5a74638482398df81bb61536dc13ebcbcc78c9be0c78936543096408a
server binary: f8c656436d26d3705a9a0564462c07e47575945cdfa1719aa59cad2f280da0c5
```

[Dữ liệu phiên đo](performance_data/nm03_2026-10-11/README.md) gồm manifest,
fixture, 420 dòng raw samples, summary, comparisons và evidence. Evidence ghi
image nền/hash artifact/log gate. Container tạm đã thoát và được `--rm` dọn.
Các image test/cache vẫn có thể dùng để tái hiện; không thay service production.

### 10.2. Thời gian và độ ổn định

Mọi thời gian ở bảng này là **µs**. Median là elapsed/sample chia số lệnh;
core/STM không đo latency riêng từng lệnh. P95 response chỉ có ở TCP/web,
đợi đủ batch của cả người nhận, khác p95 của sample mean.

| Lớp | RTS/capability | Median/lệnh | 95% CI median | P95 sample/lệnh | P95 response | Spread block |
|---|---|---:|---|---:|---:|---:|
| core | N1 / 1 | 8.201 | [8.162; 8.356] | 9.532 | N/A | 2.77% |
| core | N2 / 2 | 11.048 | [10.859; 11.170] | 11.793 | N/A | 3.19% |
| core | default / 12 | 25.029 | [24.729; 25.236] | 28.812 | N/A | 2.02% |
| coordinator | N1 / 1 | 12.167 | [12.054; 12.318] | 12.699 | N/A | 1.17% |
| coordinator | N2 / 2 | 15.771 | [15.565; 16.026] | 16.615 | N/A | 0.75% |
| coordinator | default / 12 | 31.837 | [31.185; 31.968] | 32.748 | N/A | 1.00% |
| tcp | N1 / 1 | 33,592.727 | [33,556.193; 33,658.188] | 33,730.294 | 44,421.75 | 0.28% |
| tcp | N2 / 2 | 33,631.557 | [33,601.213; 33,719.379] | 33,883.244 | 45,110.08 | 0.20% |
| tcp | default / 12 | 33,638.212 | [33,572.479; 33,708.017] | 33,958.490 | 44,590.88 | 0.57% |
| web | N1 / 1 | 33,585.198 | [33,540.784; 33,627.924] | 33,760.784 | 44,433.34 | 0.30% |
| web | N2 / 2 | 33,655.897 | [33,579.004; 33,680.298] | 33,911.680 | 44,501.23 | 0.04% |
| web | default / 12 | 33,724.988 | [33,627.069; 33,772.435] | 33,914.138 | 44,619.76 | 0.40% |

### 10.3. CPU, allocation, GC và bộ nhớ

Các cột là median của 30 sample. MiB = 1.048.576 byte. Allocation/lệnh là
normalization theo số lệnh; TCP/web bao gồm startup/shutdown Haskell nên
không so trực tiếp allocation của chúng với core/STM. CPU và GC ở đơn vị giây.
GC core/STM là accounting có final GC ngoài clock; TCP/web là cả process.
Live và memory là RTS peak trong process, không phải peak RSS.

| Lớp/profile | Byte/lệnh | CPU s/sample | GC CPU s | GC elapsed s | Max live MiB | Max RTS memory MiB |
|---|---:|---:|---:|---:|---:|---:|
| core/N1 | 52,835.74 | 1.103712 | 0.020239 | 0.020407 | 0.0779 | 6.0 |
| core/N2 | 52,835.74 | 1.430591 | 0.103391 | 0.116027 | 0.0868 | 11.0 |
| core/default | 52,835.74 | 5.095678 | 1.676674 | 0.812776 | 0.1771 | 53.0 |
| coordinator/N1 | 61,115.41 | 1.233166 | 0.031728 | 0.031844 | 0.0781 | 6.0 |
| coordinator/N2 | 61,115.58 | 1.536371 | 0.115291 | 0.119340 | 0.0870 | 11.0 |
| coordinator/default | 61,115.36 | 4.759464 | 1.495575 | 0.711304 | 0.1773 | 53.0 |
| tcp/N1 | 41,997.76 | 0.038935 | 0.000371 | 0.000373 | 0.0577 | 6.0 |
| tcp/N2 | 42,555.68 | 0.043793 | 0.000000 | 0.000439 | 0.0702 | 11.0 |
| tcp/default | 48,018.88 | 0.063608 | 0.000000 | 0.000521 | 0.1632 | 62.0 |
| web/N1 | 41,877.60 | 0.037028 | 0.000371 | 0.000373 | 0.0577 | 6.0 |
| web/N2 | 42,409.28 | 0.041402 | 0.000000 | 0.000399 | 0.0701 | 11.0 |
| web/default | 47,996.32 | 0.060978 | 0.000000 | 0.000526 | 0.1632 | 62.0 |

GC CPU=0.000000 ở một số profile mạng là giá trị RTS đã đọc, không phải
điền số 0 khi không hỗ trợ. Có thể phản ánh độ phân giải/đường báo cáo của
counter; GC elapsed tương ứng vẫn có giá trị. Context switch, migration,
cache misses/cycles/instructions và peak RSS chưa đo được → N/A, lý do trong
manifest/topology. Không suy cache hit rate từ allocation.

Node snapshot cuối sample gồm bridge + peer harness trong một orchestrator
sống xuyên nhiều sample. Đây không phải peak RSS riêng của mỗi bridge.

| Web profile | Node CPU s/sample | Node RSS snapshot MiB |
|---|---:|---:|
| N1 | 0.032329 | 88.76 |
| N2 | 0.030651 | 88.76 |
| default | 0.030155 | 88.76 |

### 10.4. Diễn giải so sánh và giới hạn kết luận

So với N1, thay đổi median dưới đây là **dương = chậm hơn**. Khoảng 95%
bootstrap lấy lại 30 cặp cùng sampleIndex, 2.000 lần, seed 20261011; ratio
của median profile và median N1. Tất cả mẫu trong cặp cùng workload/seed.
Bảng là so sánh profile của cùng phiên bản; không phải tốc độ sau NM-04.

| Lớp | Profile so N1 | Median thay đổi | 95% CI thay đổi |
|---|---|---:|---|
| core | N2 | +34.72% | [+31.18%; +36.28%] |
| core | default | +205.20% | [+197.13%; +208.87%] |
| coordinator | N2 | +29.63% | [+27.49%; +32.17%] |
| coordinator | default | +161.67% | [+155.61%; +164.31%] |
| tcp | N2 | +0.12% | [-0.12%; +0.44%] |
| tcp | default | +0.14% | [-0.19%; +0.36%] |
| web | N2 | +0.21% | [-0.12%; +0.38%] |
| web | default | +0.42% | [+0.05%; +0.64%] |

1. **Lõi thuần/STM:** N1 có thời gian thấp hơn trong workload tuần tự này;
   allocation gần như không đổi giữa các profile, còn CPU/GC và memory
   tăng với capability. Workload không tạo song song tính toán của các trận.
   GHC -N thay đổi runtime/parallel GC; dữ liệu gợi ý overhead runtime/GC
   cần được xét. Chưa tách từng nguyên nhân scheduler/GC/cache bằng profiler
   nên không khẳng định GC là nguyên nhân duy nhất hoặc NUMA gây chậm.
2. **TCP/web:** median khoảng **33,6 ms/lệnh**, p95 response khoảng
   **44–45 ms**. Chênh lệch profile thấp hơn ngưỡng 5% NM-01; không có căn cứ
   chọn profile nhanh hơn cho game thực chỉ bằng các số này. Tính toán lõi
   ở cỡ µs/lệnh trong harness, còn đường phản hồi gồm socket/scheduler và
   nhiều frame. Hai phạm vi khác nhau nên không trừ để suy chi phí bridge.
3. Nhiều command mạng có batch gồm hai frame liên tiếp. Server hiện chưa
   đặt TCP_NODELAY; Nagle/delayed ACK là giả thuyết cần packet capture hoặc
   phép thử một biến để xác nhận. NM-03 giữ nguyên đường gửi làm baseline,
   không sửa networking rồi ghi kết quả đó thành baseline trước tối ưu.
4. Khoảng chênh nhỏ TCP/web không chứng minh bridge có overhead bằng 0.
   WS, TCP và peer harness có cách gửi khác; jitter và buffering có thể
   che chi phí. Cần workload/đo chuyên biệt nếu muốn phân rã overhead.
5. Một trận hai người là workload nhỏ, mang tính tuần tự; không khẳng định
   cấu hình này tối ưu cho nhiều phòng, tải đồng thời hoặc CPU khác. Các
   test C-07/concurrency vẫn kiểm tra tính đúng, baseline không thay chúng.
6. Đây là loopback một container trên WSL, không phải độ trễ giữa hai thiết
   bị Wi-Fi, không có rendering React, NUMA nhiều node hoặc PMU. Affinity/
   local-remote ở NM-04/NM-07 cần manifest và phép đo riêng trên môi trường đủ.

**Kết luận NM-03:** đã có baseline trước tối ưu, tái hiện được và đủ mẫu/
độ ổn định theo NM-01. Lõi, STM và mạng đều chạy đúng transcript/checksum.
Không tự đổi RTS production theo kết quả; nhóm B/A/C/R review phạm vi và
cách dùng số liệu trước hợp nhất. Chưa có chữ ký review thay thành viên.

## 11. Cách dùng baseline ở các task sau

Giữ nguyên fixture v1, compiler/snapshot, build flags, metric scope và protocol
đo; lưu hash phiên bản mới. Đổi một yếu tố mỗi phép so: capability, affinity,
worker hoặc Fleet index. Không chọn lại seed/chỉ giữ sample thuận lợi.

Hiệu năng cần xét median/p95, allocation/GC/RAM và tính đúng đắn cùng nhau.
Chỉ xem cải thiện khi đủ điều kiện ổn định và ngưỡng/CI theo NM-01; số capability
nhiều, byte allocation ít hoặc dùng Docker đều không tự chứng minh nhanh hơn.
Các quyết định đổi mặc định production cần nhóm review; baseline này cung
cấp căn cứ và không thay xác nhận của A/B/C/D/R.
