# NM-06 — Đội tàu tính sẵn và bảng tra cứu không boxing

Thực hiện ngày **2026-10-12**, nhánh **Update_NUMA**. A phụ trách, B review;
chưa ghi xác nhận thay thành viên. Phụ thuộc NM-01/NM-03 và A-03/A-04/A-06/B-06.
NM-05 là hiện trạng worker khi đo; không thay worker, luật hoặc giao thức.

## 1. Vấn đề được xử lý

Trước NM-06, Fleet chỉ giữ Map ShipId (Set Coord). Khi bắn, Rules tìm tàu bằng
`find (Set.member coordinate . snd) (Map.toList ships)`. Một ô nước có thể phải
kiểm tra cả năm tàu. Nếu trúng, Rules hợp nhất năm tập ô để kiểm tra thắng,
rồi kiểm tra tập ô của tàu vừa bắn để xác định chìm. Geometry không đổi sau
khi đặt xong, nhưng phép tìm và hợp nhất vẫn lặp lại.

Số tàu chỉ là năm và bàn chỉ 100 ô, nên không suy rằng bản cũ chậm nghiêm trọng.
NM-06 đo các chi phí này, thử representation mới và ghi cả chi phí tạo/bộ nhớ.
Lợi ích học thuật là áp dụng tái sử dụng dữ liệu bất biến, phân biệt tính sẵn
ở chương trình với cache CPU, và kiểm chứng bằng mô hình tham chiếu/benchmark.

## 2. Kiến thức bài giảng và cách áp dụng

Trang dưới đây tính theo trang vật lý PDF, bắt đầu từ 1; đã đọc lại slide.

| Nội dung | Cơ chế trong đồ án | Bằng chứng và giới hạn |
|---|---|---|
| Buổi 01–03: hàm thuần, kiểu, dữ liệu bất biến | Board tạo Fleet từ request; metadata là hàm của geometry, không có IO | Cùng input tạo cùng lookup; không cần đồng bộ metadata sau từng phát bắn |
| ADT/quy nạp: phân biệt constructor và pattern matching | Maybe ShipId phân biệt nước/tàu; Either GameError phân biệt lỗi; ShipId giữ Cruiser/Submarine riêng | Test đủ năm ID và các kết quả MISS/HIT/SUNK/WIN |
| Chap8: module/package và test | Constructor ở Internal.Fleet không expose; Board có hai helper đọc; array là dependency library | GHC probe hiện có chặn constructor/record update/coerce/import private; Hspec/QuickCheck chạy thật |
| Chap4, trang 7–8: bộ nhớ chính và cache CPU | Thử bảng 100 số nguyên nhỏ nằm trong buffer thay vì 100 phần tử boxed | Đây là thử bố trí dữ liệu; không tự điều khiển cache phần cứng |
| Chap2, trang 6 và 12: coherence, các cấp cache và chia sẻ | Metadata bất biến, chia sẻ cùng Fleet; không ghi lại bảng theo lịch sử bắn | Không cài giao thức snoop hay chứng minh giảm coherence traffic |
| Chap5, trang 27–29: locality và ghép nơi thực thi với dữ liệu | Metadata được tính trong step ở worker NM-05; benchmark micro dùng một CPU được cấp | Capability/cpuset không chứng minh RAM nằm trên NUMA node mong muốn |
| Chap5, trang 35–40 / Chap6: giao dịch STM | Coordinator giữ state + batch như cũ; Fleet mới là giá trị bất biến trong state | Các test atomicity, rollback, slow client và shutdown vẫn là gate |

UArray, Word8, strict field, RTS accounting và bootstrap là công cụ kỹ thuật
bổ sung để triển khai/đo các nguyên lý; không nhận rằng mọi API này xuất hiện
nguyên văn trong slide. Mô hình L1/L2/L3 ở slide cần đối chiếu topology thực
tế của máy; topology VM không mô tả đầy đủ máy vật lý.

## 3. Representation và quyền tạo dữ liệu

```text
Fleet private
  geometry: Map ShipId (Set Coord)
  occupied: Set Coord, hợp nhất một lần từ geometry
  index: UArray Int Word8, bounds 0..99
```

Board vẫn kiểm tra đúng năm ID, chiều dài 5/4/3/3/2, trong bàn và không chồng.
Thứ tự lỗi placement giữ nguyên. Chỉ sau foldM thành công mới tạo occupied và
index từ Map đã chuẩn hóa. Không dựng metadata từ input chưa được kiểm tra,
không xuất Fleet từng phần và không thêm setter metadata.

Private Fleet chuyển từ newtype một field sang data ba field strict. Tham số
ship/coord vẫn tránh import cycle Types ↔ Board. Types chỉ xuất type alias
Fleet và fleetShips; module Internal vẫn ở other-modules. Board là nơi duy
nhất trong production gọi constructor. Tests và benchmark cũng dùng placeFleet.

Map/Set cũ vẫn phục vụ render đội tàu mình và lấy các ô của một tàu để kiểm tra
chìm. Occupied/index là dữ liệu dẫn xuất bất biến, không phải một nguồn luật
khác. Hai tàu dài ba có mã khác nhau vì mã theo ShipId, không theo độ dài.

Eq kiểm tra geometry và cả hai metadata, nên permutation test so cùng dữ liệu
thực sự. Show giữ dạng diagnostic cũ chỉ có fleetShips, giúp tránh phình output
bởi bảng dẫn xuất. Không dùng Show để serialize GameState ra mạng.

## 4. Chỉ số, mã ô và validation

Chỉ số row-major: `(row - 1) * 10 + column - 1`, với Coord one-based.
A1 → 0, J1 → 9, A2 → 10, A10 → 90, J10 → 99.

| Mã Word8 private | Ý nghĩa |
|---|---|
| 0 | Nước |
| 1 | Carrier |
| 2 | Battleship |
| 3 | Cruiser |
| 4 | Submarine |
| 5 | Destroyer |

Bounds và mã thuộc implementation, không phải giao thức TCP. Word8 chứa đủ
0..5 và payload 100 ô là 100 byte; còn có header/alignment, Map/Set và wrapper.
Không gọi 100 byte là tổng kích thước Fleet hoặc RSS process.

`shipAt :: Coord -> Fleet -> Either GameError (Maybe ShipId)` kiểm tra inBounds
trước phép trừ/nhân/cộng và trước truy cập array. Ngoài bàn trả InvalidCoordinate,
bao gồm minBound/maxBound Int. Điều này cũng ngăn tọa độ như K1 bị biến thành
chỉ số của một ô khác. Nước trả Right Nothing; tàu trả Right (Just ship).
`fleetCells :: Fleet -> Set Coord` chỉ đọc tập ô tính sẵn. Người gọi có thể
tạo Set khác từ kết quả, nhưng không sửa Fleet bất biến.

UArray có phần tử không boxing và strict: khi Fleet được đánh giá, bảng được
xây với các mã số đã tính. Strict fields buộc cả occupied/index khi constructor
được đánh giá; không để writer nhận trách nhiệm tính bảng. Coordinator NM-05
buộc geometry trước publication nên cũng buộc Fleet và các field strict mới.
Việc lookup vẫn trả Maybe ShipId ở API Haskell, không cam kết mọi thao tác có
allocation bằng 0.

## 5. Luật sử dụng dữ liệu mới thế nào

Rules vẫn kiểm tra phase, hai fleet sẵn sàng, lượt, tọa độ và bắn lặp theo
thứ tự cũ. Sau đó dùng shipAt để xác định nước/tàu. Nếu nước → Miss; nếu tàu:

1. Lấy các key lịch sử của shooter và thêm tọa độ vừa bắn.
2. Nếu fleetCells là tập con của các ô đã bắn → Win.
3. Nếu các ô của ShipId vừa bắn là tập con → Sunk ship.
4. Nếu chưa đủ → Hit.

Win vẫn ưu tiên hơn Sunk ở ô cuối cùng của tàu cuối. Miss chuyển lượt, Hit/Sunk
giữ lượt, Win kết thúc; không sửa quyết định từ R-01. History vẫn chỉ là một
Map Coord Outcome cho mỗi shooter, incoming lấy từ lịch sử của đối thủ. Không
tạo hit-counter, mutable cell status hoặc bản sao shotsReceived cần cập nhật.

Core vẫn thuần. Worker/mailbox, nguyên tử state + event batch, giới hạn outbox,
framing, Origin/Host và resume 300.000 ms không đổi bởi task này. PlayerView chỉ
chứa Fleet của người đang xem; metadata không được thêm vào event công khai.

## 6. Vì sao chọn cách này

Tính sẵn occupied tránh union lại geometry mỗi phát trúng. Cấu trúc Set giữ
nguyên cách kiểm tra subset đã kiểm thử; không viết lại luật thắng bằng bit
operations trong cùng thay đổi representation.

UArray Word8 phù hợp miền hữu hạn 100 ô: phép đổi Coord đã kiểm tra thành
index có chi phí nhỏ, không cần hash hay tìm đường trong cây cho mỗi ô. Các
byte của bảng nằm trong một buffer; đây là bố trí có khả năng thuận lợi cho
spatial locality, cần phép đo phần cứng nếu muốn kết luận cache miss giảm.

Map Coord ShipId cũng có thể tính sẵn, nhưng vẫn có node/key/pointer và lookup
trong cây. HashMap cần dependency và hàm hash cho một miền rất nhỏ. Array boxed
lưu giá trị/indirection riêng cho phần tử; UArray bỏ dạng lưu trữ đó ở buffer.
Không coi một trong các phương án này luôn nhanh hơn trên mọi workload.

Giữ geometry Map/Set giúp không phá fleetShips và code render/view đã có.
Thay toàn bộ geometry bằng bitboard có thể gọn hơn, nhưng cần chuyển representation
ở nhiều caller và chứng minh lại các phép Sunk/Win; NM-06 không cần thay API
đó. Đánh đổi của cách giữ cả geometry lẫn dữ liệu dẫn xuất là thêm bộ nhớ và
thời gian đặt tàu, được đo riêng ở phần sau.

Metadata gắn với Fleet thay vì cache global theo request/seed: không phải quản
lý key, eviction hoặc trạng thái stale. Fleet không đổi sau xác nhận, nên
không có cache invalidation theo phát bắn. Một trận kết thúc sớm hoặc người
chỉ xem trước placement vẫn phải trả chi phí tính sẵn; cần đánh giá toàn ván
để xem chi phí đó có được bù lại.

## 7. Kiểm thử độc lập và phạm vi nghiệm thu

FleetIndexSpec có 4 ví dụ cụ thể và 5 tính chất mới, mỗi tính chất chạy ít
nhất 1.000 trường hợp. Tái dùng generator hữu hạn A-06 và referenceCells
theo R-01 trong TestSupport.Generators; không dùng production placeFleet,
shipCells hay shipAt để quyết định input sinh có hợp lệ không.

Lookup tham chiếu tìm Coord trong các ô mở rộng từ từng ShipPlacement của
input, không dùng array, công thức index hoặc metadata của Fleet. Mỗi input
ngẫu nhiên đối chiếu đủ 100 ô, bao gồm nước. Occupied đối chiếu tập ô độc lập,
17 ô, geometry public và giới hạn bàn. Permutation đối chiếu toàn Fleet và
lookup; ngoài bàn đối chiếu InvalidCoordinate, không chấp nhận exception.

Tính chất transcript đặt hai fleet bằng step rồi bắn một miss mỗi bên và toàn
bộ 17 ô đối thủ. Kỳ vọng Hit/Sunk/Win lấy từ ID và thứ tự ô tham chiếu, không
từ resolveShot. Trạng thái kết thúc phải Finished P1 AllShipsSunk. Fixture
benchmark hiện có cũng kiểm tra checksum cố định và view hai người.

Các ví dụ cụ thể gồm A1/J10, Cruiser khác Submarine dù cùng dài ba, ô nước,
17 ô và các Int ngoài bàn. Các probe public abstraction ở BoardSpec giữ nguyên.
Không phát hiện lỗi geometry/index runtime trong loạt này; không tạo phản ví
dụ giả rồi gọi đó là lỗi đã sửa. Khi property thất bại, Hspec/QuickCheck in
seed và input/coordinate để tái hiện bằng --seed; sau đó bổ sung regression
Hspec cho phản ví dụ thật.

## 8. Phép đo và kết quả

### 8.1. Gate chức năng

Windows 11 build 26200; Linux amd64 kernel WSL2/Docker. GHC 9.10.3,
lts-24.59, array 0.5.8.0. Docker Engine **29.8.2**, Compose **5.5.1**.

| Gate thực sự chạy | Kết quả |
|---|---|
| Windows stack build và stack test --ghc-options=-Werror | 943 ca chức năng + 18 fixture, 0 lỗi |
| Linux stack build/test -Werror | 944 ca chức năng + 18 fixture, 0 lỗi |
| FleetIndexSpec trong suite trên | 9 ví dụ; mỗi trong 5 property chạy 1.000 trường hợp |
| Node topology/benchmark/affinity/fleet parser | 82/82 |
| Hai container/affinity/stop-restart | 3/3 |
| Build benchmark Linux -O2 -Werror | Thành công, gồm component fleet mới |

Ca thêm trên Linux là SIGTERM conditional, không phải một property Fleet mới.
Suites thắng/chìm, A-06/B-06, C-07, worker/control/concurrency và server thật
đều chạy lại. Linux dùng cache compiler/dependency DK-04 và toàn source hiện
tại; không nhận đây là build no-cache từ đầu.

Compose dùng server thật, bridge và fixture ba seed, kiểm tra game đủ đặt tàu,
lệnh lỗi, miss/hit/sunk/win, riêng tư, hai player/slot thứ ba, Origin/Host,
healthcheck và port mapping. Cleanup các ca CPU11/N1/worker0, CPU0,1/N2/-qa/
worker1 và stop-restart lần lượt **962 / 1.007 / 969 ms**. Đây là quan sát test
trong gate 10 giây, không bảo đảm thời gian cố định cho mọi môi trường.
Không chạy lại hai thiết bị Wi-Fi thật hoặc rendering browser trong NM-06.

### 8.2. Phương pháp và dữ liệu được lưu

Đã chụp source trước sửa Fleet và build binary Linux riêng. Source của binary
được đối chiếu SHA-256 do build tạo, không lấy SHA HEAD làm bằng chứng cho source
dirty. HEAD lúc đo `94a7aaaf68860a55cb7528c76f7c30f8fc1b6023`, chưa commit.
Dữ liệu NM-03/NM-05 giữ nguyên, không ghi đè bằng source mới.

Microbenchmark dùng sáu fleet của ba seed **424242 / 8675309 / 20261011**.
Lookup đối chiếu cả 100 ô với input geometry độc lập; union/cached đều duyệt
đủ 17 tọa độ và tạo cùng digest. IORef + NOINLINE giữ input là giá trị đọc ở
runtime; không đo một biểu thức hằng đã tính ngoài vòng lặp. Constructor mode
gồm placeFleet và digest geometry để ép tính đầy đủ. Strict fields làm phần
metadata mới được tính trong phép đo constructor.

Các mode scan/indexed đo trung bình trên một query trong batch 100 ô; union/
cached đo một lần tạo/đọc rồi duyệt tập ô; construct đo một Fleet đã kiểm tra
và digest. Không trừ các mode khác phạm vi để suy thời gian chính xác của thân
một hàm. Harness, đọc IORef và kiểm tra digest cũng có chi phí chung.

Mode retain giữ **12.000 Fleet** qua GC rồi đọc số Fleet sau lấy RTS stats để
chúng còn reachable. Heap delta / số Fleet có overhead list/reference và hiệu
ứng các đối tượng nền sống/chết qua GC. Đây là số thực nghiệm trên dataset,
không phải kích thước object riêng tuyệt đối hoặc peak RSS.

Micro dùng CPU logic được cấp **0**, N1, cùng image/runtime và rts -T. Đây là
cấu hình thí nghiệm trên máy đã inspect, không cố định CPU0 trong code startup.
Ván lõi dùng bộ mask 0–11 được VM cung cấp và ba profile N1/N2/default12,
hai binary trong cùng container, thứ tự before/after đảo mỗi sample. Workload
25 command/game gồm placement/lỗi/miss/hit/sunk/win/view/checksum như NM-03.
Đây là đo lõi, không phải latency TCP/web hay rendering UI.

Mỗi nhóm có **5 warm-up + 30 sample**, xoay thứ tự mode/profile. Nhóm nhiễu
được đo lại nguyên loạt theo NM-01, giữ mọi sample, không loại outlier hoặc
chọn lại seed. Hai binary đều -O2; binary sau thêm -Werror là gate diagnostic,
không đổi mức tối ưu runtime. Metadata/default game không được sửa giữa các
loạt đo. Xem raw data và manifest tại
[fleet_data/nm06_2026-10-12](fleet_data/nm06_2026-10-12/README.md).

### 8.3. Lookup, union và chi phí bộ nhớ

Đơn vị µs/operation; đây là thời gian batch chuẩn hóa. Bảng dùng loạt sau đo
lại, hai nhánh reference/optimized cùng binary. Nhiễu tính theo spread median
của ba block 10 sample, chia median nhóm; ngưỡng ≤10% của NM-01.

| Đường | Median µs/op | Nhiễu | Timing đủ ổn định | Allocation byte/op |
|---|---:|---:|---|---:|
| Scan năm tàu | 0,10734 | 8,52% | Có | 289,16 |
| Lookup UArray qua shipAt | 0,01828 | 11,40% | Chưa | 63,48 |
| Union geometry rồi duyệt 17 ô | 1,59895 | 9,83% | Có | 4.597,37 |
| Đọc occupied tính sẵn rồi duyệt 17 ô | 0,42412 | 2,76% | Có | 1.684,02 |

Union/cached đều ổn định trong cùng loạt: median cached thấp hơn **73,47%**;
bootstrap CI 95% theo cặp **[-75,11%; -72,44%]**. Đây là bằng chứng giảm
chi phí hợp nhất lại dữ liệu trong workload, không phải cache miss CPU giảm.
Timing lookup UArray còn nhiễu sau lần lặp; dù median thấp hơn, chưa dùng nó
để chốt mức tăng tốc. Allocation lookup quan sát giảm **78,05%**, union/cached
giảm **63,37%**; không gọi đó là giảm RAM resident cùng tỷ lệ.

| Chi phí tạo/giữ Fleet | Trước | Sau | Thay đổi quan sát |
|---|---:|---:|---:|
| Allocation placeFleet + digest, byte/Fleet | 15.736,13 | 20.585,60 | +30,82% |
| Heap delta/Fleet được giữ qua GC, byte | 1.352,66 | 2.252,66 | +900,00 byte, +66,54% |

Phần tăng gồm wrapper ba field, occupied Set và UArray cùng overhead liên
quan; không chỉ payload 100 byte. Set có thể chia sẻ subtree/Coord với geometry,
nên số heap này thuộc sáu fleet thử nghiệm, không áp cho mọi bố trí.

Median constructor ở loạt before lặp là 2,718 µs/Fleet, after lặp 7,919 µs/Fleet.
Không gán toàn bộ chênh này cho metadata: cùng binary sau nhưng scan/union ở
loạt đầu và loạt lặp cũng thay đổi gần hai lần. Ổn định bên trong một nhóm
không bảo đảm điều kiện hiệu năng máy giống nhau giữa hai loạt. So sánh ván
theo cặp ở mục tiếp theo kiểm soát vấn đề này tốt hơn.

### 8.4. Ván đầy đủ và kết luận

Loạt đầu có 5/6 nhóm core vượt ngưỡng nhiễu; giữ toàn bộ dữ liệu rồi lặp lại
nguyên 30 cặp/profile. Loạt lặp có cả sáu nhóm ổn định, spread **0,19–4,84%**.
Cùng 1.024 vòng replay/sample, mỗi sample 3.072 ván và 76.800 command, cùng
checksum ở cả hai binary/profiles. Default trong VM là 12 capability.

| Profile | Before µs/command | After µs/command | Median thay đổi | CI 95% theo cặp |
|---|---:|---:|---:|---|
| N1 | 9,058 | 8,357 | -7,74% | [-8,56%; -6,44%] |
| N2 | 11,942 | 11,061 | -7,38% | [-8,83%; -5,60%] |
| Default N12 | 24,959 | 23,028 | -7,73% | [-9,65%; -4,59%] |

Median vượt ngưỡng cải thiện 5% và CI không gồm 0 theo NM-01. CI default cũng
cho thấy độ cải thiện thực có thể dưới 5%; không chỉ báo một số đẹp. Đây là
bằng chứng lợi ích của **gói metadata/lookup/strict representation NM-06** ở
workload lõi đã chốt. Chưa có ablation tách riêng occupied và UArray trong
toàn ván để quy mọi lợi ích cho một field, và không gọi mức giảm này là hiệu
quả cache CPU hoặc latency TCP/UI. Lõi N1 vẫn ít thời gian hơn N2/N12 cho
workload tuần tự này; không tự đổi RTS production theo bảng.

Allocation của cả ba profile: **52.835,75 → 51.082,04 byte/command**, giảm
**3,32%**. Metadata có chi phí khởi tạo, nhưng trong transcript nhiều lượt
bắn/đánh giá view, việc tái sử dụng lookup/occupied bù chi phí đó. Kết luận
này không áp tự động cho trận chỉ đặt tàu rồi Quit hoặc workload khác.

| RTS metric, median/sample | Before N1/N2/N12 | After N1/N2/N12 |
|---|---|---|
| CPU time s | 0,698 / 0,886 / 2,934 | 0,644 / 0,814 / 2,746 |
| GC CPU accounting s | 0,0125 / 0,0638 / 0,9452 | 0,0143 / 0,0628 / 0,8956 |
| Max live heap byte | 81.720 / 91.056 / 185.808 | 83.368 / 92.328 / 187.744 |
| Max RTS memory MiB | 6 / 11 / 52 | 6 / 11 / 52 |

GC N1 tăng dù allocation giảm: không suy một metric từ metric khác. Các total
CPU/GC trong bảng có cùng số replay ở hai variant; final GC accounting nằm
ngoài elapsed timing theo harness NM-03. RTS memory không phải RSS, kích
thước riêng của Fleet hoặc vị trí trang RAM trên NUMA node.

Tổng lưu **960 measured sample + 160 warm-up**: micro before 120×2, after
180×2 và core paired 180×2; các raw JSONL gồm cả warm-up. CI bootstrap 2.000
draw theo cặp sampleIndex, seed 20261011. Không đổi seed theo kết quả và không
lọc sample để đạt ổn định. Lookup micro còn chưa đạt sau repeat, được đánh dấu
inconclusive dù CI ratio không gồm 0; điều kiện stability vẫn có hiệu lực.

**Kết luận NM-06:** metadata nhất quán qua smart constructor, toàn bộ gate
chức năng xanh; phép đo core cho thấy lợi ích giới hạn trong workload, cùng
chi phí heap/khởi tạo. Giữ khả năng đánh giá lại ở NM-09. Chưa kết luận CPU
cache miss/local-remote RAM. Probe NM-02 trong container không có lệnh perf;
PMU devices được thấy không có CPU PMU. Cache-references/cache-misses báo N/A,
không coi đó là đã đo được số 0.

### 8.5. Lệnh chạy và review

Từ gốc repository:

```powershell
stack build --ghc-options=-Werror
stack test --ghc-options=-Werror
stack test --ghc-options=-Werror --test-arguments="--match NM-06"
stack test --ghc-options=-Werror --test-arguments="--match NM-06 --seed <seed-thất-bại>"
node --test scripts/test/topology.test.mjs scripts/test/benchmark.test.mjs scripts/test/affinity.test.mjs scripts/test/fleet-benchmark.test.mjs
node --test scripts/test/affinity-compose.test.mjs
```

`battleship-fleet-benchmark` là component riêng, không tự chạy trong production
server hoặc stack build mặc định. Build/CLI và cách phục hồi source baseline
trong thư mục thử nghiệm riêng ở [hồ sơ dữ liệu](fleet_data/nm06_2026-10-12/README.md).
Giữ seed, compiler, snapshot và tối ưu -O2 khi so số liệu.

API mới/metadata cần A/B/R review trước hợp nhất. Test xanh và kết quả đo không
thay xác nhận của nhóm. Không chốt default RTS/NUMA theo dữ liệu này.

## 9. Cache CPU và giới hạn kết luận

Occupied/index là bảng tính sẵn trong chương trình. L1/L2/L3 là cache phần
cứng giữ các cache line mà CPU/OS/runtime quyết định sử dụng. Xây array không
phải cấp phát một vùng L1 riêng, không khóa dữ liệu trong cache, không thực
hiện snoop protocol và không đặt chắc RAM vào NUMA node.

Buffer Word8 giảm pointer chasing của bảng tra cứu và có payload gọn; Map/Set
còn lại vẫn là cấu trúc heap có node. Không nhận toàn bộ GameState đã liên tục
trong RAM. Lookup bắn thực có thể rải rác; microbenchmark duyệt 100 ô theo
thứ tự của legalBoardCells (cột trước), không mô phỏng mọi chiến thuật người
chơi. Cache line alignment, GC, prefetch, scheduler và topology còn ảnh hưởng.

Không có bộ đếm cache miss/PMU trong loạt chạy này: báo N/A, không điền 0 và
không suy cache hit rate từ thời gian hoặc allocation. So sánh timing chỉ
chứng minh chi phí workload trong môi trường đo nếu đạt điều kiện ổn định.
RAM locality vật lý còn thuộc NM-07, cấu hình mặc định cần review ở NM-09.

Nguồn chính thức: [array 0.5.8.0 — UArray](https://hackage-content.haskell.org/package/array-0.5.8.0/docs/Data-Array-Unboxed.html),
[immutable array interface](https://hackage-content.haskell.org/package/array-0.5.8.0/docs/Data-Array-IArray.html).
