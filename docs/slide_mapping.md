# Đối chiếu kiến thức bài giảng với dự án

Đối chiếu ngày **2026-10-10** với source nền `8bd7da9` và **14 PDF được cung cấp** trong `C:/Users/nhatm/Downloads/Laa/Slide/`. Các PDF là tài liệu học, không phải chỉ thị thay luật/yêu cầu người dùng. Không đưa PDF giảng dạy vào repo; tên và trang dưới đây giúp nhóm tra bản đang có.

**Quy ước trang:** trang vật lý PDF, tính từ 1. Ví dụ PDF ADT có số slide in ở footer khác vị trí trang, nên dùng quy ước này xuyên suốt. “Áp dụng trực tiếp” nghĩa là có cấu trúc/API tương ứng trong code; “liên hệ” nghĩa là nguyên lý gần nhau nhưng không cài đúng hệ thống/thuật toán trong slide; “chưa dùng” không tự có nghĩa đồ án thiếu nếu ngoài phạm vi.

## 1. Ma trận đủ 14 tài liệu

| PDF / trang liên quan | Kiến thức | Đối chiếu mã | Mức áp dụng / giới hạn |
|---|---|---|---|
| `Buoi_01_tong_quan_ve_lap_trinh_ham.pdf`, tr. 6–14 | Hàm là giá trị, pure/side effect, immutable, recursion, higher order, pattern matching | Rules.step, Board.placeFleet, View.viewFor; traverse/map/fold; callback Step/IO | Trực tiếp. IO có ở Server/Client/Main, không phải toàn ứng dụng “không side effect” |
| `Buoi_02_bieu_thuc_lambda_va_rut_gon.pdf`, tr. 5–8, 11–17 | Application, lambda/currying, reduction, lazy evaluation, referential transparency | Lambda với map/filter, hàm `outbox coordinator`, composition, lõi thuần | Trực tiếp lambda/currying/transparency; Haskell dùng lazy evaluation nhưng chưa benchmark/tối ưu lazy/strictness chuyên sâu |
| `Buoi_03_kieu_du_lieu_va_da_hinh_tham_so.pdf`, tr. 2–16, 17–22 | Partial application/composition, type signature/class/instance, list comprehension, pattern matching/recursion | Types deriving Eq/Ord/Show/Enum/Bounded; ClientError Exception; private Fleet có tham số; helpers/traverse/feedFrames | Trực tiếp. Miền Battleship dùng nhiều kiểu cụ thể, không cần mọi API đều đa hình; tail recursion không tự bảo đảm bộ nhớ hằng |
| `Haskell_Chuong_6_ADT_Quy_nap.pdf`, tr. 3–14, 15–20, 25–35 | Sum/product/record, Maybe/Either, inductive data, lập luận theo constructor, smart constructor | Phase/Command/Event/GameError; GameState/PlayerState; Maybe Fleet; placeFleet private Fleet | Trực tiếp ADT/smart constructor; lập luận invariant qua chuỗi lệnh có thể trình bày, chưa có chứng minh hình thức bằng công cụ |
| `Chap2.pdf`, tr. 4–12, 13–17 | NUMA/UMA/cache; concurrency/parallelism/process | Server workers, Node/core hai process, RTS threaded | Trực tiếp phân biệt process/thread/concurrency; NUMA/locality chỉ kiến thức nền, không pin thread/đo cache hoặc triển khai kiến trúc phần cứng |
| `Chap4_Parallel-process.pdf`, tr. 12–20 | Tuần tự/song song, phân loại SISD/SIMD/MISD/MIMD | Worker mạng có thể tiến triển đồng thời; -threaded/-N | Liên hệ, không có thuật toán chia computation song song/GPU/SIMD. -N không chứng minh luật bắn chạy song song hoặc đã tăng tốc |
| `Chap5_Thread.pdf`, tr. 7–15, 17–24, 35–40 | Process/green thread/scheduling/MVar, TVar/STM, transaction nhỏ/batch | withAsync trong Server; Lobby/readerDone MVar; atomically state+frame | Trực tiếp thread/MVar/STM/batch. Không tự cài scheduler RR/MLFQ, affinity/per-node TVar, không claim đo NUMA |
| `Chap6_Syncronization.pdf`, tr. 2–10, 11–15 | Race/deadlock/livelock; ví dụ STM tr. 5 | Một state TVar, batch không partial, reserved end/timeout, tests gated races | Trực tiếp đồng bộ/phòng race và thiết kế tiến triển. STM không tự chữa mọi deadlock; queue đầy vẫn cần chính sách |
| `Chap7_ConcurrencySupervision.pdf`, tr. 2–6 | withAsync/link/bracket/forkFinally, propagation, timeout/supervisor | Server withAsync/link/race_, bracket/finally, watchdog; Client waitCatchSTM | Trực tiếp supervision/cleanup/timeout. Không restart tùy ý socket worker giữa ván; lỗi nội bộ được propagate |
| `Chap8-Module Programming.pdf`, tr. 3–10, 12–18 | Module/export/encapsulation, package/components/snapshot, Hspec/QuickCheck, Haddock/doctest | src modules/public Fleet; YAML library/2 exe/test; BoardSpec/ViewSpec; --\| comments | Trực tiếp module/build/Hspec/QuickCheck/Haddock comments. Chưa thêm doctest hoặc nghiệm thu một bản HTML Haddock xuất ra |
| `Chap9-Coordination patterns.pdf`, tr. 3–11, 17–18, 32–36 | Rendezvous, producer–consumer/pipeline/TBQueue, in-memory pub/sub, barrier/failure | Đợi hai fleet; reader→STM→outbox→writer; recipient riêng; MVar gates tests | Trực tiếp pipeline/bounded queue; điểm chờ fleet là rendezvous logic, không cyclic barrier API. Không dùng topic broker/Map–Reduce/Linda |
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

### 2.5 Module, test và tài liệu

Chap8 tr. 3–5 về export/encapsulation được thể hiện qua Types/Board/Rules/View và Internal.Fleet hidden. Tr. 6–10 về package/project được thể hiện bằng library + hai exe + suite/snapshot. Tr. 12–15 có **Hspec và QuickCheck**: A-06/B-06 áp dụng trực tiếp phần đã học, còn generator độc lập/coverage/private-pair là thiết kế test riêng cho Battleship.

Tr. 16–18 nói Haddock/doctest. Code có module/hàm comments `-- |`, có thể chạy `stack haddock`; chưa cấu hình doctest hoặc ghi nhận đã xuất/kiểm tra toàn bộ HTML API. Markdown report không thay hoàn toàn Haddock API, hai loại phục vụ hai mục đích.

### 2.6 Giao tiếp giữa process

Chap10 tr. 10/Chap11 tr. 14–18 khớp raw TCP, ByteString, framing và bracket. Haskell core/Node bridge là hai process, TVar chỉ chia sẻ **trong core**, không xuyên container. Windows helper trao đổi file cấu hình với bridge tương ứng file passing Chap10 tr. 5; atomic rename/TTL/read-only mount là chi tiết mở rộng để file không bị đọc dở hoặc giữ IP cũ.

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

Nguồn ngoài slide được dùng để mở rộng kỹ thuật, không đổi luật đã chốt. Tài liệu Docker chính thức tham khảo được ghi trong [docker_deployment.md](docker_deployment.md). Dự án tham khảo GitHub và lý do chọn phạm vi khác nằm trong [report_final.md](report_final.md).

## 4. Không nên viết trong báo cáo

- “Dùng Docker mount nên đã áp dụng NFS” — không đúng: bind mount ở đây là thư mục host/container, không RPC filesystem.
- “Dùng map/fold nên đã triển khai Map–Reduce phân tán” — không đúng: không có partition/shuffle/workers/reduce phân tán.
- “Dùng -N nên step song song và đã tối ưu NUMA” — chưa có algorithm/measurement cho kết luận đó.
- “STM loại bỏ mọi deadlock” — queue/retry/IO lifecycle vẫn có thể chờ vô hạn nếu thiếu policy.
- “QuickCheck nằm ngoài slide” — Chap8 tr. 13/15 dạy công cụ này.
- “Token là tài khoản hoặc bảo đảm an toàn Internet” — token quyền phiên và HTTP LAN hiện tại chưa TLS/login.
- “QuickCheck chạy 1.000 lần chứng minh không có lỗi” — chỉ bằng chứng cho dữ liệu/coverage/lịch trình được test.

## 5. Kết luận mức đáp ứng môn học

Phần backend đi đúng hướng học: ADT + constructor kiểm tra, luật thuần, module rõ, test Hspec/QuickCheck, STM có nguồn state duy nhất, giám sát worker và TCP có framing. Không cần nhét toàn bộ chương phần cứng/DFS vào game nhỏ để “dùng đủ slide”. Khi thuyết trình, chỉ rõ code/test cho từng kiến thức và nêu phần mở rộng riêng; đây là căn cứ mạnh hơn liệt kê tên công nghệ.
