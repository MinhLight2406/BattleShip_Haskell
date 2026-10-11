# NM-06 — Hồ sơ kiểm thử và phép đo

Ngày 2026-10-12 Asia/Saigon, nhánh Update_NUMA, source dirty tại HEAD
94a7aaaf68860a55cb7528c76f7c30f8fc1b6023. Không dùng SHA HEAD một mình để
nhận diện binary; source/image/binary hash, gate và phạm vi ở evidence.json.

## Artifact

| File/thư mục | Ý nghĩa |
|---|---|
| before/ | Micro trước sửa Fleet: 30 mẫu mỗi mode, nhiễu, giữ nguyên |
| before-repeat/ | Cùng binary trước sửa, đo lại sau gate chức năng: ổn định |
| after/ | Micro sau sửa, cùng binary cho reference scan/union và optimized indexed/cached |
| after-repeat/ | Loạt micro sau đo lại: index và retain timing vẫn chưa ổn định |
| core-paired/ | Hai binary trước/sau, 3 profile, 30 cặp; nhiều nhóm timing nhiễu |
| core-paired-repeat/ | Đo lại nguyên loạt cặp: cả 6 nhóm core đạt ổn định |
| comparisons.json | CI bootstrap 2.000 draw theo cặp, điều kiện stability độc lập với CI |
| compare.mjs | Tạo lại comparisons từ raw JSONL và summary, không loại sample |
| paired-core.mjs | Driver chơi 25 command/game và kiểm tra checksum ở cả hai binary |
| paired.Dockerfile | Image thí nghiệm có hai binary; không thêm service production |
| before-source/ | Bảy file khác biệt cần phục hồi để build benchmark trước NM-06 |
| before-image-source-sha256.txt | Hash Haskell/build source được ghi bởi image baseline |
| prepare-before.py | Tạo context mới trong .stack-work, chép source chung rồi phục hồi bảy file; không sửa checkout |
| container.json, rts.json, shutdown-restart.json | Game/riêng tư/security/cleanup trên runtime thật sau NM-06 |
| evidence.json | Nguồn/gate/hash/số lượng và giới hạn nghiệm thu |
| verification.Dockerfile | Dockerfile gate Linux thực tế, tái dùng compiler/dependency cache DK-04 |
| google_docs_verification.json | Thẻ con NM-06: nội dung khớp, heading/list native và 11 thẻ cũ giữ nguyên |

Mỗi thư mục đo có manifest.json, samples.jsonl và summary.json. Manifest UTC,
cấu hình CPU/RTS, số replay, seed và source/binary hash; raw gồm warm-up. Tổng
**960 measured + 160 warm-up**. Giữ cả các loạt không ổn định. Baseline NM-03
và dữ liệu NM-05 không bị ghi đè.

Manifest micro before đầu được đối chiếu lại hai chỉnh sửa harness đã xảy ra
khi chụp context (import redundant và dòng Docker install); manifest-original.json
được giữ, manifest.json ghi correction. Tất cả hash Haskell trong image đã
khớp snapshot thật. Không thay production geometry khi sửa provenance.

## Chạy lại

Gate chức năng ở [fleet_index.md](../../fleet_index.md#85-lệnh-chạy-và-review).
Build benchmark cần image compiler/test và image web Linux. Từ gốc repo:

```powershell
docker build --target test -f docker/haskell.Dockerfile -t battleship-haskell-test:nm06 .
docker build -f docker/web.Dockerfile -t battleship-web:nm06 .
docker build -f docker/benchmark.Dockerfile --build-arg HASKELL_BENCH_BASE=battleship-haskell-test:nm06 --build-arg WEB_BENCH_BASE=battleship-web:nm06 -t battleship-benchmark:nm06 .
```

Các tag image local là kết quả build, không thay pin của base image trong
Dockerfile. Benchmark build -O2 -Werror; production build/test vẫn dùng cấu
hình package của dự án. Snapshot/GHC kiểm tra trong Dockerfile.

Để dựng binary before bằng source đã lưu, Python 3 cần có trên PATH:

```powershell
python docs/fleet_data/nm06_2026-10-12/prepare-before.py .stack-work/nm06/reproduce-before
docker build -f .stack-work/nm06/reproduce-before/docker/benchmark.Dockerfile --build-arg HASKELL_BENCH_BASE=battleship-haskell-test:nm06 --build-arg WEB_BENCH_BASE=battleship-web:nm06 -t battleship-fleet-before:nm06 .stack-work/nm06/reproduce-before
docker build -f docs/fleet_data/nm06_2026-10-12/paired.Dockerfile -t battleship-fleet-paired:nm06 .
```

Helper từ chối nếu common module không còn khớp baseline; dùng checkout đúng
source hash của hồ sơ nếu dự án đã thay đổi tiếp. Context before chỉ dùng đo
benchmark cũ; không chạy suite API NM-06 mới trên API cũ. Giữ runtime/GHC/-O2
cùng nhau; -Werror của binary after là diagnostic gate. Rebuild ở máy khác
không bắt buộc có binary SHA giống máy nghiệm thu, nhưng phải ghi hash mới.

Micro cần một CPU nằm trong effective mask. Inspect topology và chọn CPU đó;
ví dụ máy nghiệm thu chọn 0, không hiểu đó là CPU bắt buộc trên mọi máy:

```powershell
node scripts/start-affinity.mjs inspect
$nm06Root = (Get-Location).Path
$nm06Output = Join-Path $nm06Root '.stack-work/nm06/reproduce-results'
$nm06Context = Join-Path $nm06Root '.stack-work/nm06/reproduce-before'
$nm06Cpu = '0'
New-Item -ItemType Directory -Force -Path $nm06Output | Out-Null
node scripts/benchmark-runtime.mjs --prepare .stack-work/nm06/reproduce-results/current-provenance.json
```

Driver micro nhận JSON object đường dẫn → SHA, không nhận nguyên provenance.
Tạo source-hashes.json từ trường sourceHashes của current-provenance; baseline
dùng source-hashes.json của context trước. Node:

```powershell
node --input-type=module -e "import fs from 'node:fs'; const p='.stack-work/nm06/reproduce-results/'; const d=JSON.parse(fs.readFileSync(p+'current-provenance.json','utf8')); fs.writeFileSync(p+'source-hashes.json',JSON.stringify(d.sourceHashes,null,2))"
docker run --rm --network none --read-only --tmpfs /tmp --cpuset-cpus $nm06Cpu --mount "type=bind,source=$nm06Root,target=/probe,readonly" --mount "type=bind,source=$nm06Output,target=/results" --mount "type=bind,source=$nm06Context,target=/before,readonly" --entrypoint node battleship-fleet-before:nm06 /probe/scripts/benchmark-fleet.mjs before /results/before /before/source-hashes.json
docker run --rm --network none --read-only --tmpfs /tmp --cpuset-cpus $nm06Cpu --mount "type=bind,source=$nm06Root,target=/probe,readonly" --mount "type=bind,source=$nm06Output,target=/results" --entrypoint node battleship-benchmark:nm06 /probe/scripts/benchmark-fleet.mjs after /results/after /results/source-hashes.json
docker run --rm --network none --read-only --tmpfs /tmp --mount "type=bind,source=$nm06Root,target=/probe,readonly" --mount "type=bind,source=$nm06Output,target=/results" --entrypoint node battleship-fleet-paired:nm06 /probe/docs/fleet_data/nm06_2026-10-12/paired-core.mjs /results/core /results/source-hashes.json
```

Không chạy build/test hoặc workload nặng song song với đo. Nếu không đạt ngưỡng
nhiễu, chạy lại nguyên driver vào thư mục mới, không ghi đè hoặc chọn bỏ sample.
Mode retain có số Fleet cố định để kiểm tra live heap, không tối ưu throughput.
30 mẫu/5 warm-up là mặc định. Binary nhận count có giới hạn và checksum được
đối chiếu mỗi vòng. Node parser test kiểm tra metric không có không bị đổi thành 0.

## Kết luận và giới hạn

Đọc bảng đầy đủ tại [fleet_index.md](../../fleet_index.md). Trong loạt core lặp
ổn định, median giảm khoảng 7,4–7,7%, allocation giảm 3,32%; mỗi Fleet giữ qua
GC tăng khoảng 900 byte trên sáu fleet dataset. Đây là đánh đổi đã đo, không
phải khẳng định cùng tỷ lệ cho mọi trận hoặc máy.

CPU-cache references/misses, cycles/instructions, migration/context switch,
peak RSS không có phép đo ở đây. Probe không có perf/CPU PMU trong container,
báo N/A. RTS heap khác RSS và NUMA residency. Một node VM được nhìn thấy không
chứng minh máy vật lý có một node. Không có trận Wi-Fi hai thiết bị thật hoặc
xác nhận A/B/R mới trong hồ sơ này.
