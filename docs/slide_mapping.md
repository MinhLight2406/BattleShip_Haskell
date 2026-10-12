# Đối chiếu kiến thức bài giảng với dự án

Đối chiếu cập nhật **2026-10-12 (NM-09)** trên `Update_NUMA`, nền `788f839` và source/evidence của NM-03..08, với **14 PDF được cung cấp** trong `C:/Users/nhatm/Downloads/Laa/Slide/`. NM-07..09 còn thay đổi chưa commit; [numa_acceptance.md](numa_acceptance.md) ghi định danh từng phép đo và phần còn chờ. Các PDF là tài liệu học, không phải chỉ thị thay luật/yêu cầu người dùng. Không đưa PDF giảng dạy vào repo; tên và trang dưới đây giúp nhóm tra bản đang có.

**Quy ước trang:** trang vật lý PDF, tính từ 1. Ví dụ PDF ADT có số slide in ở footer khác vị trí trang, nên dùng quy ước này xuyên suốt. “Áp dụng trực tiếp” nghĩa là có cấu trúc/API tương ứng trong code; “liên hệ” nghĩa là nguyên lý gần nhau nhưng không cài đúng hệ thống/thuật toán trong slide; “chưa dùng” không tự có nghĩa đồ án thiếu nếu ngoài phạm vi.

## 1. Ma trận đủ 14 tài liệu

| PDF / trang liên quan | Kiến thức | Đối chiếu mã | Mức áp dụng / giới hạn |
|---|---|---|---|
| `Buoi_01_tong_quan_ve_lap_trinh_ham.pdf`, tr. 6–14 | Hàm là giá trị, pure/side effect, immutable, recursion, higher order, pattern matching | Rules.step, Board.placeFleet, View.viewFor; traverse/map/fold; callback Step/IO | Trực tiếp. IO có ở Server/Client/Main, không phải toàn ứng dụng “không side effect” |
| `Buoi_02_bieu_thuc_lambda_va_rut_gon.pdf`, tr. 5–8, 11–17 | Application, lambda/currying, reduction, lazy evaluation, referential transparency | Lambda/map/filter/composition; digest benchmark và ép state trên worker; Fleet metadata strict | Trực tiếp; evaluation được kiểm tra bằng kết quả/checksum. Strict field không bảo đảm toàn graph deep evaluated; chưa chứng minh mọi thunk/heap tối ưu |
| `Buoi_03_kieu_du_lieu_va_da_hinh_tham_so.pdf`, tr. 2–16, 17–22 | Partial application/composition, type signature/class/instance, list comprehension, pattern matching/recursion | Types deriving Eq/Ord/Show/Enum/Bounded; ClientError Exception; private Fleet có tham số; helpers/traverse/feedFrames | Trực tiếp. Miền Battleship dùng nhiều kiểu cụ thể, không cần mọi API đều đa hình; tail recursion không tự bảo đảm bộ nhớ hằng |
| `Haskell_Chuong_6_ADT_Quy_nap.pdf`, tr. 3–14, 15–20, 25–35 | Sum/product/record, Maybe/Either, inductive data, lập luận theo constructor, smart constructor | Phase/Command/Event/GameError; GameState/PlayerState; Maybe Fleet; placeFleet private Fleet | Trực tiếp ADT/smart constructor; lập luận invariant qua chuỗi lệnh có thể trình bày, chưa có chứng minh hình thức bằng công cụ |
| `Chap2.pdf`, tr. 4–12, 13–17 | NUMA/UMA/cache; concurrency/parallelism/process | inspect-topology; cpuset/cpuset-mems/membind; GameWorker; Fleet occupied/UArray; Node/core hai process | Có triển khai và kiểm chứng CPU/RAM node0 theo Linux guest, affinity và metadata. Remote/GHC NUMA/PMU chưa nghiệm thu; một node guest không suy ra host vật lý |
| `Chap4_Parallel-process.pdf`, tr. 7–8, 12–20 | Cache/coherence; tuần tự/song song, SISD/SIMD/MISD/MIMD | Metadata immutable dùng lại, UArray 100 ô thử spatial locality; -threaded/-N, worker mạng | Có bố trí dữ liệu/đo allocation; không cài hardware cache coherence hoặc chứng minh cache hit-rate. Không GPU/SIMD/chia thuật toán luật song song |
| `Chap5_Thread.pdf`, tr. 7–15, 17–24, 27–31, 35–40, 43–44 | Green thread/scheduling/MVar, forkOn/capability, STM/batch, profiling | GameWorker withAsyncOn/capability; Lobby/readerDone MVar; state+frame STM; RTS/benchmark | Trực tiếp capability placement, affinity có verify task, STM/profiling. Capability ≠ CPU/core/node; không tự cài RR/MLFQ/per-node TVar; GHC NUMA pools chưa chạy được |
| `Chap6_Syncronization.pdf`, tr. 2–10, 11–15 | Race/deadlock/livelock; ví dụ STM tr. 5 | Một state TVar, batch không partial, reserved end/timeout, tests gated races | Trực tiếp đồng bộ/phòng race và thiết kế tiến triển. STM không tự chữa mọi deadlock; queue đầy vẫn cần chính sách |
| `Chap7_ConcurrencySupervision.pdf`, tr. 2–6 | withAsync/link/bracket/forkFinally, propagation, timeout/supervisor | Server scoped async/bracket/watchdog; GameWorker withAsyncOn/mask/finally, ack wake; Client waitCatchSTM | Trực tiếp supervision/cleanup/timeout; 100 vòng cancel/stop/full-mailbox và SIGTERM/down có gate. Không restart worker rồi giả phục hồi trận |
| `Chap8-Module Programming.pdf`, tr. 3–10, 12–18 | Module/export/encapsulation, package/components/snapshot, Hspec/QuickCheck, Haddock/doctest | src modules/public Fleet; YAML library/2 exe/test; BoardSpec/ViewSpec; --\| comments | Trực tiếp module/build/Hspec/QuickCheck/Haddock comments. Chưa thêm doctest hoặc nghiệm thu một bản HTML Haddock xuất ra |
| `Chap9-Coordination patterns.pdf`, tr. 3–11, 17–18, 32–36 | Rendezvous, producer–consumer/pipeline/TBQueue, in-memory pub/sub, barrier/failure | Reader→mailbox 32→GameWorker→STM→outbox 128→writer; ack/backpressure; control riêng; TMVar gates | Trực tiếp bounded pipeline có đường kết thúc; đợi hai fleet là rendezvous logic, không cyclic barrier API. Không topic broker/Map–Reduce/Linda |
| `Chap10-SharingDataInMPA.pdf`, tr. 2–5, 9–13 | Message passing vs shared memory, file passing, TCP/framing | Haskell↔Node TCP; Windows helper→JSON mount→bridge | Trực tiếp message passing/file passing. Không shared TVar giữa hai container, không mmap/shmem hoặc Kafka/RPC framework |
| `Chap11-Networking.pdf`, tr. 5–7, 12–18 | IP/port/socket, TCP/UDP, client–server, half-close, firewall, bracket | network sockets, framing, bind config, sendAll/recv/shutdown, strict URL | Trực tiếp TCP/client–server/resource handling. IPv4 MVP; không UDP/P2P/TLS transport thực tế; browser WebSocket là mở rộng |
| `Chap12-NETWORKED FILE SYSTEMS.pdf`, tr. 2–18, 20–35, 37–44 | NFS/RPC/cache consistency/lease/lock/replication/security/RDMA | TTL LAN và file helper có liên hệ thời hạn/nhất quán; đọc static HTTP | Chưa cài NFS/DFS. Docker bind mount không phải triển khai NFS; RAM token/TTL không phải NFS lease; không replication/consensus/RDMA |

Tên file Chap8 thực tế có dấu gạch ngang và khoảng trắng như bảng; không dùng tên viết nhầm để trích dẫn.

## 2. Minh họa áp dụng vào xử lý

### 2.1 Pure function, immutable và type signature

```haskell
step :: PlayerId -> Command -> GameState
     -> Either GameError (GameState, [Event])
viewFor :: PlayerId -> GameState -> PlayerView
placeFleet :: FleetPlacement -> Either GameError Fleet
```

Một FIRE hợp lệ tạo GameState mới với history/phase mới, không sửa bản cũ. Hspec giữ `before`, gọi step rồi so sánh; lỗi phải Left. Server ghi kết quả mới vào TVar là side effect nằm ở lớp STM, không làm step trở thành IO. Từ cùng input có thể tái hiện test không cần socket.

Hàm bậc cao xuất hiện khi Server nhận Step/callback, khi dùng traverse để encode frame và foldM kiểm tra input. Điều này gắn với Buổi 01 tr. 6/13, Buổi 02 tr. 6–8 và Buổi 03 tr. 2–5, không chỉ “vì dùng Haskell nên có FP”.

### 2.2 ADT và constructor kiểm tra

`Phase = Placing | Turn PlayerId | Finished PlayerId EndReason` mô hình sum-of-products: mỗi phase một lựa chọn, Turn/Finished có dữ liệu riêng. Maybe Fleet giải thích rõ “chưa đặt”, Either GameError Fleet giải thích “thành công hoặc lỗi cụ thể” (PDF ADT tr. 12–14).

Fleet private và Board.placeFleet thực hiện smart constructor theo tr. 35: năm ID riêng, đúng độ dài, trong bàn, không chồng rồi mới trả Right. Coord raw vẫn cho phép giá trị ngoài bàn để Rules/Board trả lỗi; không nói ADT tự ngăn mọi sai nghiệp vụ.

### 2.3 Lập luận bất biến theo chuỗi lệnh

Có thể giải thích invariant của đường chơi hợp lệ theo ý tưởng quy nạp trên list lệnh (PDF ADT tr. 25–30):

1. Cơ sở: initialGameState có hai người chưa đặt, history rỗng, Placing.
2. Bước PLACE: Right chỉ chứa fleet qua smart constructor; lỗi giữ state trước. Không thay fleet đã xác nhận.
3. Bước FIRE: cần hai fleet/lượt/tọa độ/chưa bắn; chỉ thêm một ô vào history actor, giữ fleet; phase đúng theo kết quả.
4. Bước QUIT: giữ dữ liệu bàn/history, chuyển Finished đúng đối thủ; mọi lệnh sau Finished bị từ chối.
5. Do đó chuỗi bắt đầu hợp lệ và chỉ đi qua Right step bảo toàn các invariant trên; trường hợp Left dùng lại state cũ.

Đây là lập luận thiết kế cần đối chiếu code từng nhánh, không coi số test QuickCheck là chứng minh cho mọi giá trị tự dựng của GameState. Kiểm thử là bằng chứng bổ sung, đặc biệt với lỗi implementation.

### 2.4 STM, queue và race

Chap5 tr. 35/39–40 và Chap6 tr. 5 dùng TVar/atomically. Dự án mở rộng giao dịch từ “đọc/ghi một biến” sang state **và các outbox**: tính step + encode + capacity + publish cùng lúc. Gửi socket ngoài STM vì giao dịch có thể retry.

Chap9 tr. 11 dạy TBQueue đầy sẽ chờ. MVP đã chọn khác chính sách chờ: preflight cả batch, dành chỗ kết thúc, Quit receiver chậm. Đây là áp dụng bounded buffer kèm yêu cầu tiến triển, không thay TBQueue tự retry thành giải pháp an toàn tuyệt đối. Chap9 tr. 35 cũng nhắc failure có thể làm barrier chờ mãi; dự án dùng finally/timeout/marker để kết thúc.

NM-05 thêm mailbox 32 **trước** coordinator: reader đợi ack, EOF/stop có control riêng không phải đợi slot thường. Worker chạy trên capability chọn và là nơi submit state của đường mạng. Một worker không làm STM thừa: state/outbox vẫn phải commit cùng transaction và writers/cleanup có thể tiến triển đồng thời. NM-08 dùng TMVar gate, 100 vòng cho các ca quan trọng; không dùng một lần race thuận lợi làm bằng chứng chung.

### 2.5 Module, test và tài liệu

Chap8 tr. 3–5 về export/encapsulation được thể hiện qua Types/Board/Rules/View và Internal.Fleet hidden. Tr. 6–10 về package/project được thể hiện bằng library + hai exe + suite/snapshot. Tr. 12–15 có **Hspec và QuickCheck**: A-06/B-06 áp dụng trực tiếp phần đã học, còn generator độc lập/coverage/private-pair là thiết kế test riêng cho Battleship.

Tr. 16–18 nói Haddock/doctest. Code có module/hàm comments `-- |`, có thể chạy `stack haddock`; chưa cấu hình doctest hoặc ghi nhận đã xuất/kiểm tra toàn bộ HTML API. Markdown report không thay hoàn toàn Haddock API, hai loại phục vụ hai mục đích.

### 2.6 Giao tiếp giữa process

Chap10 tr. 10/Chap11 tr. 14–18 khớp raw TCP, ByteString, framing và bracket. Haskell core/Node bridge là hai process, TVar chỉ chia sẻ **trong core**, không xuyên container. Windows helper trao đổi file cấu hình với bridge tương ứng file passing Chap10 tr. 5; atomic rename/TTL/read-only mount là chi tiết mở rộng để file không bị đọc dở hoặc giữ IP cũ.

### 2.7 Capability, locality và evaluation

Chap5 tr. 27–30 đặt thực thi lên capability (`forkOn`); GameWorker áp dụng scoped async tương ứng bằng `withAsyncOn`. Coordinator được khởi tạo tại worker; command/state/batch cần dùng được ép tại đường xử lý để tránh chỉ đặt nơi tạo thunk. Digest benchmark duyệt kết quả game/view/event và checksum ổn định. Đây gắn Buổi 02 lazy evaluation với việc đo thật, không chỉ liệt kê Haskell vốn lazy.

Capability index 0 không phải CPU0. NM-04 dùng cpuset và kiểm chứng thread runtime để nối hai mức; không suy RAM placement từ pin thread. Lợi ích worker là ownership/đường kết thúc đã kiểm tra. Timing worker NM-05 chưa stable; allocation tăng khoảng 5,6–5,7%. [worker_locality.md](worker_locality.md) ghi chi phí, không tuyên bố tăng tốc.

### 2.8 Metadata chương trình, cache CPU và NUMA

Chap2 tr. 6/12 và Chap4 tr. 7–8 giải thích locality/cache. NM-06 thử dữ liệu bất biến tính sẵn và UArray 100 ô; smart constructor tạo metadata từ geometry hợp lệ. Test đối chiếu 100 ô độc lập và ≥1.000 trường hợp/property; phép đo ghép cặp lõi giảm median khoảng 7,4–7,7%, allocation 3,32%, nhưng retained fixture tăng khoảng 900 byte/Fleet. Đây là lợi ích của package metadata trong workload đã đo, không có cache-miss counter để kết luận L1/L2/L3 tăng hit-rate.

Chap2 tr. 4/9–12 giải thích NUMA local/remote. NM-07 đọc topology, giới hạn RAM node trước process, kiểm chứng private resident pages. Node0/membind đã qua gate guest; remote thiếu node B, GHC build không hỗ trợ NUMA và PMU không khả dụng nên **chưa nghiệm thu**, không phải pass. Local một node không nhanh hơn default-memory trong phép đo repeat; không gán NUMA một tỷ lệ tăng tốc chưa chứng minh.

Tổng hợp cơ chế, số liệu, fingerprint và lệnh tái hiện: [numa_acceptance.md](numa_acceptance.md). Default đề xuất N1 opt-in không pin tài nguyên; package/base Compose vẫn auto-N cho tới review cùng revision.

## 3. Kiến thức/công cụ mở rộng ngoài slide

| Phần bổ sung | Tại sao cần | Kiến thức slide làm nền |
|---|---|---|
| React/TypeScript/Vite, DOM/CSS responsive/accessibility | Dùng UI nhóm, click/kéo/xoay/hiển thị tiếng Việt, build production | Tách trách nhiệm/kiểu dữ liệu; không phải API Haskell trong slide |
| Node HTTP/WebSocket/ws, envelope SESSION/CONNECTION/RESUME_ERROR | Browser client và nối lại/replay TCP player | Client–server/message passing/codec |
| Token random 256 bit, sessionStorage, fragment chuyển origin | Giữ quyền phiên và danh tính qua reload/đổi IP | State/lifecycle; chi tiết resume không có trong slide |
| Origin/Host allowlist, bounded message/file size, IPv4 canonical | Chặn handshake sai, nguồn cấu hình không mở wildcard | Networking/resource validation |
| Dockerfile multi-stage/digest/non-root/ldd/Dockerignore | Build Linux và runtime gọn có test gate | Package/process/resource ownership |
| Compose DNS/port mapping/health dependency/SIGTERM/grace | Hai service chạy đúng thứ tự/cổng, stop sạch | Networking/supervision; syntax Compose là mới |
| PowerShell/.NET adapter API/MoveFileExW/TTL JSON | Lấy IP Windows host và đổi allowlist không restart | File passing/concurrency; hệ điều hành cụ thể là mới |
| Node test runner, Playwright, container fixtures/clock kiểm soát | Test giao diện/bridge/timer/stop/restart thật | Unit test và supervision; framework/cách fixture là mới |
| Compile probes/coverage/mutation/race gates | Ngăn Fleet sai và đo khả năng bắt lỗi | Hspec/QuickCheck/encapsulation; kỹ thuật kiểm chứng sâu hơn ví dụ slide |
| sysfs/procfs/cgroup, Docker cpuset/numactl, argv/exec và task/page verification | Chuyển nguyên lý CPU/RAM placement thành cấu hình có kiểm chứng trên Linux | NUMA/locality/affinity trong Chap2/4/5; API Linux/Docker cụ thể là phần mở rộng |
| Bootstrap CI, stability blocks, paired benchmarks và source/binary hashes | Phân biệt lợi ích đã đo với nhiễu/missing metric, tái hiện đúng phiên bản | Profiling/measurement làm nền; protocol định lượng là thiết kế thực nghiệm của nhóm |

Nguồn ngoài slide được dùng để mở rộng kỹ thuật, không đổi luật đã chốt. Tài liệu Docker chính thức tham khảo được ghi trong [docker_deployment.md](docker_deployment.md). Dự án tham khảo GitHub và lý do chọn phạm vi khác nằm trong [report_final.md](report_final.md).

## 4. Không nên viết trong báo cáo

- “Dùng Docker mount nên đã áp dụng NFS” — không đúng: bind mount ở đây là thư mục host/container, không RPC filesystem.
- “Dùng map/fold nên đã triển khai Map–Reduce phân tán” — không đúng: không có partition/shuffle/workers/reduce phân tán.
- “Dùng -N nên step song song và đã tối ưu NUMA” — chưa có algorithm/measurement cho kết luận đó.
- “UArray hoặc occupied Set chính là cache CPU” — metadata chương trình và L1/L2/L3 là hai khái niệm; allocation không phải cache-miss.
- “CPU0/capability0/node0 luôn là cùng phần cứng” — cần topology/task/page evidence; VM chỉ báo phần được cấp.
- “Local node0 xanh nên remote/GHC NUMA cũng xanh” — hai ca đó đang unaccepted, không được tính pass.
- “STM loại bỏ mọi deadlock” — queue/retry/IO lifecycle vẫn có thể chờ vô hạn nếu thiếu policy.
- “QuickCheck nằm ngoài slide” — Chap8 tr. 13/15 dạy công cụ này.
- “Token là tài khoản hoặc bảo đảm an toàn Internet” — token quyền phiên và HTTP LAN hiện tại chưa TLS/login.
- “QuickCheck chạy 1.000 lần chứng minh không có lỗi” — chỉ bằng chứng cho dữ liệu/coverage/lịch trình được test.

## 5. Kết luận mức đáp ứng môn học

Phần backend đi đúng hướng học: ADT/smart constructor, luật thuần, module, Hspec/QuickCheck, STM, supervision và TCP có framing. NM-02..08 đã thêm topology/affinity/worker/locality/metadata và CPU–RAM placement có test/evidence. Không phải toàn bộ nội dung phần cứng/DFS đã được triển khai; remote/GHCNUMA/PMU và review nhóm còn chờ. Khi thuyết trình, dùng code/test/phạm vi số liệu ở NM-09; kết quả không tăng tốc vẫn cần trình bày để chứng minh hiểu đánh đổi.
