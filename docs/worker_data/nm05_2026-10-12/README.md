# NM-05 — Hồ sơ kiểm chứng worker

Kết quả trên nhánh `Update_NUMA`, source chưa commit tại HEAD
`94a7aaaf68860a55cb7528c76f7c30f8fc1b6023`. Các source hash và image ID ở
[evidence.json](evidence.json) xác định phiên bản thực sự được chạy. Thời gian
JSON là UTC; lần chạy thuộc ngày 2026-10-12 theo Asia/Saigon.

## Nội dung

| Artifact | Ý nghĩa |
|---|---|
| `evidence.json` | Số test, source/image/log hash, giới hạn và các gate từng thất bại rồi sửa |
| `first/manifest.json` | Topology/cgroup, source, binary, compiler, seed, RTS và số vòng replay |
| `first/fixtures.json` | Transcript thử nghiệm với kỳ vọng; không phải trận của người dùng |
| `first/samples.jsonl` | 525 dòng: 75 warm-up + 450 mẫu đo của 5 layer × 3 profile |
| `first/summary.json` | Median, CI, p95, block spread, allocation/CPU/GC/heap theo nhóm |
| `repeat/manifest.json` | Nguồn loạt đầu, hash script/binary/source và lý do phải đo lại |
| `repeat/samples.jsonl` | 105 dòng: 15 warm-up + 90 mẫu đo lại nguyên layer worker |
| `repeat/summary.json` | Cả ba nhóm worker vẫn vượt ngưỡng nhiễu 10% |
| `comparisons.json` | Số liệu quan sát so baseline và allocation coordinator/worker; không gán quan hệ nhân quả |
| `container.json`, `rts.json` | CPU mask, capability, log, game/riêng tư/security và cleanup thực của Compose |
| `shutdown-restart.json` | Stop khi hai peer còn kết nối, khởi động lại nhận P1, giải phóng cổng |
| `cached-verification.Dockerfile` | Gate Linux bằng cache DK-04 + source hiện tại, runtime stage production |
| `repeat-worker.mjs` | Script đo lại đúng binary/workload; kiểm tra provenance trước khi chạy |

Loạt đầu: **00:29:47–00:46:39**, loạt lặp: **00:47:58–00:52:55** theo giờ
Việt Nam. Tổng cộng 540 mẫu đo và 90 warm-up; không loại outlier. Giữ nguyên
baseline NM-03 ở `docs/performance_data/nm03_2026-10-11/`.

## Tái chạy

Lệnh build/test chức năng, benchmark 5 layer và điều kiện image nền:
[worker_locality.md](../../worker_locality.md#85-chạy-lại-và-bằng-chứng),
[performance_baseline.md](../../performance_baseline.md#8-chạy-lại-từ-source).
Benchmark chính mặc định 30 mẫu/5 warm-up mỗi nhóm. Chạy xong tạo một thư mục
artifact mới để giữ lịch sử phép đo cũ.

Nếu loạt worker đầu vượt ngưỡng, giữ nguyên image/binary/source rồi đo lại
nguyên layer bằng script này. PowerShell tại gốc repository, ví dụ thư mục
loạt đầu là `.stack-work/nm05/reproduce`:

```powershell
$nm05Root = (Get-Location).Path
$nm05First = Join-Path $nm05Root '.stack-work/nm05/reproduce'
$nm05Repeat = Join-Path $nm05Root '.stack-work/nm05/reproduce-repeat'
New-Item -ItemType Directory -Force -Path $nm05Repeat | Out-Null
docker run --rm --network none --read-only --tmpfs /tmp --mount "type=bind,source=$nm05Root,target=/probe,readonly" --mount "type=bind,source=$nm05First,target=/first,readonly" --mount "type=bind,source=$nm05Repeat,target=/repeat" --entrypoint node battleship-benchmark:nm05 /probe/docs/worker_data/nm05_2026-10-12/repeat-worker.mjs /first /repeat
```

Script từ chối source/binary/tập CPU khác loạt đầu. Đây là kiểm soát thí nghiệm,
không yêu cầu binary build ở máy khác luôn có cùng SHA với máy nghiệm thu.
Nếu đổi source hoặc môi trường, cần một loạt đầu và manifest mới.

Log gate lớn ở `.stack-work/nm05/` của máy kiểm thử và không đưa vào Git;
evidence lưu hash và dòng tổng kết để tra cứu. Dữ liệu benchmark/Compose đủ
nhỏ được giữ trong docs để nhóm review lại. Linux gate dùng cache compiler và
dependency, không nhận là fresh no-cache build. Các JSON Compose có mã phiên
thử nghiệm của harness; không ghi phiên/token của người chơi thật.

## Giới hạn diễn giải

- Functional gate xanh: Windows 934 + 18, Linux 935 + 18; worker có 25 ví dụ;
  Node 80, frontend 36, Compose 3. Ca Linux bổ sung là SIGTERM.
- Worker timing đầu/lặp đều chưa ổn định; không dùng các median này để tuyên
  bố tăng tốc hoặc chọn cấu hình tối ưu. Allocation quan sát tăng khoảng
  5,6–5,7% so coordinator cùng source.
- Thời gian worker gồm vòng đời worker mỗi trận 25 lệnh, không phải thân step.
  TCP/web khoảng 33,6 ms/lệnh; thay đổi so NM-03 dưới 1%.
- Bộ nhớ RTS không phải peak RSS hoặc NUMA residency. Không có PMU/context
  switch/migration/cache counter, không có nhiều node NUMA được cấp.
- Không nghiệm thu hai thiết bị Wi-Fi vật lý trong task này, không ghi xác
  nhận A/B/C/D thay thành viên. Review tradeoff/default còn thuộc NM-09.
