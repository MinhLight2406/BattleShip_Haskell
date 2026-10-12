# NM-07 — Bố trí CPU–RAM theo NUMA và kiểm chứng thực tế

Thực hiện ngày **2026-10-12**, nhánh **Update_NUMA**, nền `788f839` (NM-01..06).
C triển khai; R review, B chạy benchmark theo phân công. Kết quả công cụ không
thay xác nhận của thành viên. Phụ thuộc NM-02/NM-04/NM-05/NM-06.

## 1. Vấn đề và phạm vi

NM-04 đã giới hạn CPU bằng cpuset; NM-05 đã đưa xử lý trận về một worker;
NM-06 đã tạo Fleet bất biến có occupied/index tính sẵn. Các bước đó không tự
chứng minh RAM của worker được cấp trên NUMA node gần CPU đang xử lý.

NUMA là cấu trúc bộ nhớ có nhiều node: CPU có thể truy cập RAM gần node của
mình hoặc RAM ở node khác. Độ trễ/băng thông phụ thuộc topology và tải. NUMA
node không đồng nghĩa core, socket, capability GHC hay container. Một socket
có thể có nhiều node; VM cũng có thể che hoặc trình bày topology khác host.

NM-07 thêm cấu hình và phép kiểm chứng placement, giữ nguyên luật, PlayerView,
TCP framing, outbox/mailbox và resume của bridge. Không chia GameState thành
nhiều bản hoặc đưa IO vào step để thử bộ nhớ. Không sửa snapshot/compiler chỉ
để làm cho thí nghiệm báo thành công.

## 2. Kiến thức slide được áp dụng

Trang tính theo trang vật lý PDF từ 1, dựa trên đối chiếu NM-01 đã lưu.

| Kiến thức | Cách áp dụng | Bằng chứng cần có |
|---|---|---|
| Chap2 tr. 4, 9–12: local/remote RAM, topology NUMA | Ghép CPU node A với RAM A hoặc B; chọn ID từ topology Linux | CPU thực thi, allowed memory mask và resident pages khớp |
| Chap5 tr. 27–30: locality, pinning, capability | Worker NM-05 vẫn sở hữu xử lý trận; capability khác CPU vật lý | -N và worker capability khớp log; thread chạy trong CPU mask |
| Chap5 tr. 31, 39–41: giảm chia sẻ/mailbox | Một worker, một state, hai outbox; không tạo state riêng mỗi node | Luật/riêng tư và vòng đời trận giữ nguyên trong test container |
| Chap5 tr. 35–40 / Chap6: STM | Không đổi atomically state + toàn batch; IO cấu hình nằm ở script/wrapper | Thay cấu hình tài nguyên không thay giao dịch hoặc luật |
| Chap2 tr. 6, 12 / Chap4 tr. 7–8: cache/coherence | Fleet bất biến/index NM-06 tiếp tục được dùng; placement là bước riêng | Không suy cache miss từ page distribution hay elapsed time |
| Lập trình hàm, ADT và module | Board/Rules/View giữ hàm thuần, smart constructor và dữ liệu bất biến | Binary/lõi không đổi bởi NM-07; test transcript dùng server thật |

Docker CLI, procfs, numactl, RTS bitmap, Node orchestration là công cụ bổ sung
để thực hiện và đo các nguyên lý, không nhận mọi API này xuất hiện trong slide.

## 3. Thành phần mới và cấu hình

- `scripts/start-numa.mjs`: preflight, tạo hai container, áp dụng memory mask,
  khởi động theo readiness và xác minh CPU/RAM thực tế.
- `compose.numa.yaml`: entrypoint thí nghiệm và environment policy. Không có
  khóa Compose `cpuset_mems` chưa được hỗ trợ.
- `docker/numa-entrypoint.sh`: exec chương trình trực tiếp hoặc qua membind;
  không có nhánh tự đổi policy khi thất bại.
- `.env.numa.example`: cấu hình mẫu, được Git theo dõi; `.env.numa` cục bộ
  thuộc quy tắc ignore hiện có.
- `scripts/benchmark-numa.mjs`: phép đo lõi có xác nhận placement khi process
  đang chạy; tái dùng fixture, checksum, RTS parser và thống kê NM-03.
- `scripts/test/numa-config.test.mjs`, `scripts/test/numa-compose.test.mjs`:
  test cấu hình/mô hình quan sát và nghiệm thu container thật.

| Biến | Ý nghĩa |
|---|---|
| NUMA_PROFILE | default, local, remote hoặc ghc |
| NUMA_CPU_NODE | auto chọn node CPU/RAM được cấp đầu tiên, hoặc một ID thật |
| NUMA_MEMORY_NODE | auto chọn A cho local/ghc, B khác A cho remote; default chỉ nhận auto |
| HASKELL_CPUSET | auto chọn N CPU thuộc A, hoặc mask được kiểm tra trong node A |
| WEB_CPUSET | auto theo NM-04, ưu tiên core khác; không thay trong so local/remote |
| HASKELL_CAPABILITIES | N dương, không vượt CPU mask; không phải CPU ID |
| NUMA_MEMORY_POLICY | cpuset hoặc membind; default dùng cpuset nhưng không hạn chế RAM node |
| NUMA_SYS_NICE | 0 mặc định; 1 là opt-in CAP_SYS_NICE cho thí nghiệm syscall NUMA |
| NUMA_MIN_FREE_MIB | MemFree tối thiểu trên node RAM khi preflight; mặc định 64 MiB |

Launcher dùng lại resolveAffinity, rtsCommand, parseTasks, verifyRuntime và
validateResources của NM-02/NM-04. Không gắn ID CPU/node cố định vào source.
CPU ID không liên tiếp và hai CPU SMT cùng core vẫn là các CPU logic khác.
Mask giới hạn nơi chạy, không dành độc quyền CPU hay đặt quota CPU.

Remote cần CPU được cấp trên A và RAM được cấp trên B; không cần được chạy
CPU của B. Vì vậy launcher kiểm tra hai RAM node trực tiếp, không dùng riêng
nhãn multiNodeNuma của NM-02 (nhãn đó yêu cầu hai node đều có CPU được cấp).
B có thể là node chỉ có RAM. Có unit test cho trường hợp này; chưa chạy trên
phần cứng thật ở đây.

## 4. Vì sao áp dụng RAM trước khi process chạy

Luồng start có thứ tự:

1. Đọc topology trong container probe cùng Docker daemon, kiểm tra CPU/node
   online và được cấp. Probe không mở cổng chơi hay tạo player slot.
2. Resolve profile, CPU mask, N, worker capability, RAM node và policy. Sai
   cấu hình dừng trước listener.
3. Render `docker compose config --quiet`; xác nhận đúng haskell/web và cổng
   Haskell không publish. Command RTS là mảng tham số, không dựng shell string.
4. Kiểm tra MemFree trên node đích. Với GHC, thử --numa trước --info để kiểm
   tra hỗ trợ mà không gọi Main/listen. Với policy cần syscall, thử numactl.
5. `compose create --no-build`. Xác nhận Haskell chưa chạy.
6. `docker update --cpuset-mems <node> <container>` và inspect để kiểm tra
   HostConfig.CpusetMems đúng. Tập CPU được cấu hình qua override NM-04.
7. `compose start --wait` Haskell, sau đó web; start giữ nguyên container đã
   được cấu hình. Không gọi up để tạo lại container khác giữa các bước.
8. Đọc status/stat/numa_maps, log N/worker và health; chỉ lúc này ghi bằng
   chứng placement thành công.

Tạo xong mới áp dụng mask vì Compose không có trường memory-node tương ứng
với cpuset CPU đang dùng. Docker update là API được hỗ trợ. Áp dụng trước
exec tránh dùng thay đổi mask giữa trận để giả rằng các trang cũ đã được bố
trí đúng. Một profile mới phải mở trận mới; không thay CPU/RAM của trận đang
chơi rồi so nó với một profile khởi tạo từ đầu.

`cpuset-mems` chỉ giới hạn node cấp phát, không phải số byte RAM. MemFree là
kiểm tra bảo thủ tại một thời điểm; không phải reservation và không bảo đảm
không OOM khi tải khác tăng. Nó có thể từ chối một node dù còn page cache có
thể thu hồi. Nếu process chết, lỗi gốc/log và OOMKilled được ghi trước cleanup.

## 5. cpuset, membind và GHC là ba cơ chế khác nhau

### 5.1. cpuset-mems

Cgroup giới hạn tập RAM node được phép. Local chỉ cho A; remote chỉ cho B.
Policy của VMA có thể vẫn ghi default trong numa_maps. Do đó yêu cầu resident
private anonymous pages nằm ở node được chọn, không bắt policy phải ghi bind
trong chế độ cpuset. Mask được inspect trước start và đọc lại ở từng thread.

### 5.2. numactl --membind

Wrapper exec numactl để yêu cầu chính sách bind trước exec executable. Nó
không chỉ gợi ý preferred node. Khi node thiếu RAM hoặc syscall bị từ chối,
không fallback sang node khác với nhãn local/remote thành công.

Default Docker seccomp có thể chặn get_mempolicy/set_mempolicy/mbind. Mẫu để
NUMA_SYS_NICE=0; thí nghiệm đã chạy với opt-in SYS_NICE=1 khi cần syscall.
Không dùng privileged hoặc tắt toàn bộ seccomp. Tùy kernel/runtime, quyền
này vẫn có thể chưa đủ; kết quả thực tế quyết định, không suy từ cap_add.

Trong chế độ membind, ngoài trang nhớ/mask còn phải quan sát ít nhất một VMA
private có policy bind đúng node. Test giả lập numactl exit 77 chứng minh
chương trình đích không được gọi; đây là test fault injection, không phải
bằng chứng placement vật lý.

### 5.3. GHC --numa

GHC có thể tạo memory pool theo node, ghép capability và node, bind worker và
cấp nursery/GC theo node khi compiler/runtime được build hỗ trợ. Node mask
là bitmap: node 2 dùng --numa=4, không phải --numa=2. Launcher chủ động giới
hạn thử bitmap cho node ID 0..31; đây là giới hạn của launcher thí nghiệm.

GHC profile chỉ ghép CPU/RAM ở A và dùng --numa=<bitmap>; không bật --numa
trong cặp local/remote, vì RTS có thể thay mapping capability/node và chiến
lược cấp phát. Không trộn phép đo đó vào kết luận chỉ đổi node RAM.

**Kết quả thật trên image hiện tại:** runtime GHC 9.10.3 trả lỗi
`This GHC build was compiled without NUMA support.` và exit 1 khi thử
--numa=1. Cài libnuma1/numactl ở runtime không bổ sung tính năng mà RTS chưa
được biên dịch. Ca này được ghi chưa nghiệm thu; không tự bỏ cờ và chạy tiếp.
Muốn nghiệm thu GHC pools cần image GHC cùng phiên bản được build có NUMA
support, kiểm tra lại compiler/binary/test và ghi như một môi trường mới.

## 6. Kiểm chứng thực tế, không chỉ tham số

HostConfig.CpusetCpus/CpusetMems và command cho biết yêu cầu Docker nhận.
`/proc/<pid>/task/<tid>/status` cho biết CPU/memory mask của từng thread.
`stat` field 39 cho biết CPU logic mà thread chạy gần nhất; parser xử lý tên
thread có khoảng trắng và không nhầm field. Không gọi đó là lịch sử mọi lần
migration hoặc bằng chứng thread luôn chiếm CPU đó.

`/proc/<pid>/numa_maps` cho biết policy và resident pages theo node của từng
VMA. Tổng N0/N1... được ghi cho private anonymous mappings; các mapping có
file= được giữ trong dữ liệu nhưng không dùng để bắt buộc nằm trên node mới.
Page cache của file/thư viện có thể được chia sẻ và đã tồn tại trước process.
Không coi trang file ở B là lỗi heap local ở A.

Không đổi page count thành byte bằng một kích thước trang đoán trước; hệ
thống có thể có nhiều page size. Parser không coi thiếu dữ liệu như zero.
Không xác nhận placement nếu không thấy private anonymous resident pages.
Chế độ bind còn phải có bound private pages với node mask đúng.

Server được kiểm tra sau readiness và giữa trận. Benchmark lấy snapshot lúc
Haskell child đang chạy, xác nhận exe thật thay vì đọc trang của shell/Node
harness. Loạt lặp yêu cầu thread ghc_worker đã xuất hiện và ít nhất 64 private
resident pages, để không dùng riêng trang stack đầu khi exec làm bằng chứng.
N/checksum/compile version được kiểm tra từ kết quả runtime.

Đây là snapshot của resident pages và CPU gần nhất. OS, GC, automatic NUMA
balancing, swap, memory pressure và VM còn ảnh hưởng. Nó không chứng minh mọi
object Fleet hay mọi trang tương lai nằm ở vị trí vật lý host đã chọn. Local
trong báo cáo luôn chỉ node Linux/VM đang nhìn thấy, trừ khi có bằng chứng
bare metal riêng.

## 7. Vì sao không thay lõi game

Quyền sở hữu xử lý vẫn ở GameWorker; step/Board/View vẫn thuần. Geometry và
metadata Fleet được tạo qua smart constructor, không có bản sao history cần
đồng bộ. Coordinator giữ một GameState và commit state + batch trong STM.
Reader/writer vẫn tách IO khỏi luật. Không gán một GameState cho từng node,
vì một trận tuần tự theo lượt không cần state bị nhân bản để tạo vẻ song song.

Healthcheck không mở TCP cổng 4000. Gán P1/P2, từ chối client thứ ba, Origin/
Host, port mapping và resume bridge giữ contract hiện có. NUMA thay đổi tài
nguyên thực thi, không thay thông điệp wire, bí mật đối thủ hoặc thời hạn.

Wrapper dùng exec: sh/numactl thay bằng executable, Haskell vẫn là PID 1.
SIGTERM đến server, worker/socket được dọn theo cơ chế NM-05/C-07/DK-07.
Launcher lưu failure trước down; lỗi NUMA không để container giữ cổng. Restart
vẫn mất trận và token/phiên theo hợp đồng Docker, không phục hồi state cũ.

## 8. Test và bằng chứng

29 ca unit mới gồm node hợp lệ/sai/ngoài mask, một node không remote, ID không
liên tiếp, CPU sai node, incomplete mapping, N vượt mask, RAM thiếu, parser
page/cpu, mask đúng nhưng trang sai, policy không thực thi và so sánh bị đổi
CPU/N/RTS. Bộ Node tổng gồm các test NM-02/03/04/06 chạy **111/111**.

Container gate dùng runtime thật, không stub luật: full fixture 25 command
có đặt tàu, lỗi, MISS/HIT/SUNK/WIN; frames từng người phải khớp đúng golden
transcript và thứ tự, không có geometry bí mật. Healthcheck lặp trước kết
nối vẫn nhận P1/P2, người thứ ba ERROR SERVER_FULL. Stop/restart xác nhận PID1,
hai peer đóng, lần mới bắt đầu P1, container bị xóa và cổng dùng lại được.

| Gate thực sự chạy | Kết quả |
|---|---|
| Unit Node tổng | 111/111, gồm 29 ca NUMA |
| Container default-memory | Full game/health/P1/P2/third/frames/cleanup qua; stop 904 ms |
| Container local cpuset | Full game và private pages ở node 0 qua; stop 1.103 ms |
| Container local membind, SYS_NICE opt-in | Full game, policy bind và 152 bound private pages quan sát lúc ready; stop 1.227 ms |
| SIGTERM khi hai peer đang kết nối | PID1 là server, đóng hai peer và restart ra P1 mới; stop 1.127 ms |
| numactl giả lập exit 77 | Không gọi chương trình đích, không fallback |
| Remote trên môi trường này | Skip với lý do thiếu RAM node thứ hai; chưa nghiệm thu |
| GHC --numa trên binary này | Preflight exit 1, compiled without NUMA support; chưa nghiệm thu |

Container suite có **5 pass, 2 skip, 0 fail**. Không ghi 7/7 đã nghiệm thu.
Giới hạn stop test là 10 giây; thời gian trên là quan sát, không SLA cho mọi
máy. Các project thử NM-07 đã được dọn, project khác có container stopped
từ trước được giữ nguyên. Runtime non-root UID/GID 10001 vẫn đúng.

Hồ sơ [numa_data/nm07_2026-10-12](numa_data/nm07_2026-10-12/README.md) chứa
raw samples, topology, config, game frames, fingerprint và log. Lần container
đầu có một lỗi chẩn đoán: startup failure của GHC chỉ hiện container exited.
Đã thêm lưu log gốc/OOMKilled và preflight --numa trước --info; lần gate sau
phân loại đúng thiếu compiler support. Giữ cả log lần đầu và kết quả sau sửa.

Đã đối chiếu SHA của **33 file Haskell/package/snapshot** với gate NM-06:
nội dung không đổi. NM-07 không chạy lại toàn stack test; kết quả 943/944
ca chức năng + 18 fixture trước đây vẫn thuộc lần NM-06, không là số đếm
lần này. Node/container nêu trên là các gate mới thực sự chạy.

Môi trường: Docker Engine **29.8.2**, Compose **5.5.1**, kernel WSL2
**6.18.40.1-microsoft-standard-WSL2**, GHC **9.10.3**, lts-24.59,
numactl/libnuma1 Debian **2.0.16-1**. Docker thấy CPU 0..11, RAM node 0.

Runtime/benchmark thí nghiệm được bổ sung numactl/wrapper từ image đã kiểm
thử NM-06; binary Haskell giữ nguyên. Dockerfile production cũng được cập
nhật các lệnh đóng gói tương ứng. Không nhận rằng compiler có NUMA support
chỉ vì package hệ thống được cài. Không gọi lần đóng gói này là build source
no-cache hoặc lượt chạy lại toàn suite Haskell trên Linux.

## 9. Phương pháp benchmark

Workload NM-03: ba seed 424242/8675309/20261011, mỗi replay đặt hai fleet,
bắn hợp lệ/lỗi, trượt/trúng/chìm/thắng và đánh giá view cả hai người.
Core thuần đã ép kết quả/checksum, không đo việc tạo thunk chưa tính.

Mỗi profile dùng cùng binary, 1.024 replay/sample, 3.072 ván/76.800 command,
5 warm-up và 30 mẫu. Ghi compiler, SHA binary/source build, seed, cấu hình,
CPU/RAM snapshot, allocation/GC/heap và elapsed. Không bỏ sample gây nhiễu.
Ngưỡng spread block median 10% và CI/bootstrap tái dùng NM-03; nhóm không
ổn định không được dùng chốt mức tăng tốc.

Default trong phép đo là **policy RAM mặc định với CPU/N được kiểm soát**,
không phải benchmark của production mặc định dùng toàn CPU và N tự động.
Local/remote chỉ khác memory node A/B; hàm comparable chặn thay CPU/N/policy/
SYS_NICE/RTS. GHC là profile riêng. Node harness và snapshot có chi phí chung;
đây là elapsed/RTS của core, không phải latency mạng/browser hoặc băng thông
RAM của một bài streaming lớn.

Các profile được chạy theo nhóm; nếu cần kết luận local/remote trên máy hai
node, cần kiểm tra nhiễu/drift rồi lặp hoặc xen kẽ toàn nhóm theo NM-01. Không
lấy khác biệt nhỏ trong VM một node làm NUMA speedup. PMU/cache miss thiếu
được báo N/A; thời gian nhanh hơn không tự chứng minh cache miss giảm.

### 9.1. Số liệu thực tế trên môi trường một node

Loạt đầu có default spread **59,04%**, không đủ ổn định. Snapshot đầu có
thể còn sớm ở giai đoạn exec/stack. Đã giữ nguyên raw rồi đo lại đủ 30 mẫu
mỗi nhóm với điều kiện heap/RTS nêu ở mục 6; không chọn xóa sample. Loạt lặp
có default/local ổn định, nhưng cả hai vẫn chỉ dùng RAM node 0.

| Profile loạt lặp | Median µs/command bình quân sample | Spread | Allocation byte/command | Private pages quan sát |
|---|---:|---:|---:|---|
| Default-memory, CPU0/N1 | 5,227 | 0,62% | 51.082,04 | 71–1.138, toàn node 0 |
| Local cpuset CPU0/RAM0/N1 | 5,437 | 4,12% | 51.082,04 | 71–1.136, toàn node 0 |
| Remote CPU0/RAM B | N/A | N/A | N/A | Thiếu node B; không chạy |
| GHC --numa | N/A | N/A | N/A | Binary thiếu NUMA support; không chạy workload |

Cùng checksum **14460186044478640128**, cùng binary SHA **6d1e7b25…**,
max live heap median **83.368 byte**, max RTS memory **6 MiB**. GC CPU/sample
median default/local là **0,00818 / 0,00856 giây**; CPU time/sample
**0,40134 / 0,41733 giây**. RTS heap không phải RSS hoặc kích thước Fleet.

Local không nhanh hơn default trong loạt này. Không diễn giải chênh 4,02%
là tác động NUMA: hai profile ở cùng RAM node và chạy theo nhóm, chịu drift/
thermal/cache/scheduler của VM. Không so trực tiếp 5,227 µs ở đây với timing
NM-06 để nhận là một tối ưu mới: binary lõi giữ nguyên, điều kiện chạy khác.

Lưu tổng **120 measured + 20 warm-up**, gồm hai profile × hai loạt. Mỗi
snapshot loạt lặp có working private pages và thread RTS; compiler, source,
harness hash, CPU và RAM đã được ghi. Không có số liệu local/remote phần cứng
hoặc CPU cache miss; các ô N/A không được đổi thành 0.

## 10. Lệnh chạy lại

Từ gốc repository, Docker Linux và Node tương thích dự án:

```powershell
Copy-Item .env.example .env
Copy-Item .env.numa.example .env.numa
node scripts/start-numa.mjs inspect
node scripts/start-numa.mjs start
node scripts/start-numa.mjs verify
node scripts/start-numa.mjs stop
```

Build mặc định dùng Dockerfile source của hai service. Nếu đã có image hiện
hành, thêm --no-build. Mở URL từ PUBLIC_ORIGIN hoặc LAN helper đã cấu hình;
thay cổng người chơi qua .env, không thay cổng TCP nội bộ vì NUMA. Auto IP
Windows và mount origin read-only vẫn theo DK-06, không lấy IP container.

Chọn NUMA_PROFILE=remote chỉ trên máy có ít nhất hai node CPU/RAM được cấp.
Auto giữ CPU ở A và chọn RAM B; hoặc dùng ID/mask được inspect xác nhận.
Đặt NUMA_MEMORY_POLICY=membind và NUMA_SYS_NICE=1 cho thí nghiệm strict bind
khi policy/permissions được review. Profile ghc yêu cầu runtime thật hỗ trợ.
Mọi thay profile phải stop và mở trận mới.

```powershell
node --test scripts/test/topology.test.mjs scripts/test/benchmark.test.mjs scripts/test/affinity.test.mjs scripts/test/fleet-benchmark.test.mjs scripts/test/numa-config.test.mjs
node --test scripts/test/numa-compose.test.mjs
docker build -f docker/benchmark.Dockerfile -t battleship-benchmark:nm07 .
node scripts/benchmark-numa.mjs .env.numa .stack-work/nm07/measurement-new
```

Build benchmark cần HASKELL_BENCH_BASE/WEB_BENCH_BASE theo Dockerfile NM-03;
có thể truyền --build-arg cho tag test/web đã build hiện hành. Output phải mới/
trống; driver không ghi đè loạt cũ. CLI nhận thêm đường dẫn Docker và image
làm argument thứ 3/4 khi không dùng PATH/tag mặc định.

## 11. Nghiệm thu và giới hạn

Máy hiện tại chỉ trình bày một node Linux (0) cho Docker/WSL2. Không suy rằng
máy vật lý chỉ có một node. Local node 0 xác nhận cấu hình/placement và game;
remote không thể nghiệm thu trên môi trường này. GHC NUMA cũng chưa nghiệm
thu do RTS của binary hiện tại không được build hỗ trợ.

Trên máy có hai node, chạy lại full game/placement và benchmark cùng CPU A,
RAM A/B. Lưu đủ 30 mẫu/profile, compiler/source/flags/topology, page distribution
và cả các ca lỗi. Chỉ kết luận local/remote khi kết quả ổn định và bằng chứng
placement phù hợp; không sao chép timing một node sang báo cáo hai node.

Test cấu hình qua và các ca môi trường một node được ghi rõ chưa nghiệm thu
là điều kiện được phép của NM-07. Phần nghiệm thu local/remote vật lý và GHC
pools vẫn mở; A/B/C/D/R cần review cấu hình/quyền và cùng revision trước hợp
nhất. Không tuyên bố NUMA tăng tốc từ số liệu không chứng minh.

## 12. Nguồn chính thức

- [Docker cpuset CPU/RAM](https://docs.docker.com/engine/containers/run/#cpuset-constraint).
- [Docker update --cpuset-mems](https://docs.docker.com/reference/cli/docker/container/update/).
- [GHC 9.10.3 NUMA RTS](https://downloads.haskell.org/ghc/9.10.3/docs/users_guide/runtime_control.html#rts-options-for-numa-support).
- [numactl manual](https://github.com/numactl/numactl/blob/master/numactl.8).
- [Linux NUMA memory policy](https://docs.kernel.org/admin-guide/mm/numa_memory_policy.html).
- [Docker default seccomp](https://docs.docker.com/engine/security/seccomp/).
