# NM-09 — Hồ sơ tổng hợp và phép đo kết hợp

Nhánh Update_NUMA, nền788f839 + working tree. Kết luận và phạm vi:
[numa_acceptance.md](../../numa_acceptance.md).

| Artifact | Nội dung |
|---|---|
| `combined/manifest.json` | Compiler/flags, source/binary hash, topology, cgroup, seed, calibration, timestamp |
| `combined/samples.jsonl` | 450 measured +75 warm-up; giữ toàn bộ dữ liệu |
| `combined/summary.json` | 15 nhóm, mỗi nhóm30mẫu; tất cả stable theo spread≤10% |
| `combined/fixtures.json` | Ba seed/25command, cùng fixture v1 trước tối ưu |
| `analysis.json` | Tính lại summary từ raw; cross-batch NM-03→NM-09, bootstrap và stability |
| `snapshot.json` | Expected/actual hash của25file cachebaseline, 24khớp; một harness khác |
| `baseline-source/` | Snapshot nguyên trạng; không gọi exact historical harness |
| `prepare-baseline.py`, `baseline.Dockerfile` | Context mới/sourcegame lịch sử, runner re-measure mới có hash/nhãn riêng |
| `baseline-smoke/` | Smoke re-measure thành công12nhóm, không phải benchmark formal mới |
| `logs/` | Loạt mới, unit/S-01/build/smoke, giữ cả smoke đầu thất bại |
| `evidence.json` | Hash/phiên bản/ảnh Docker, số ca, giới hạn và checks mới |
| `google_docs_verification.json` | Thẻ NM-09 dưới Update NUMA, readback nội dung và bảo tồn14thẻ cũ |

Series đo kết hợp: UTC04:04:56→04:24:58 ngày2026-10-12
(Việt Nam11:04:56→11:24:58), 5layers×3profiles×(5warm+30measured).
Default auto-N thực đo12capability; N1/N2 có argv riêng. `-O2` cho cùng
benchmarkbinary NM-06, không dùng thời gian fullsuite làm timing.

## Đọc và tính lại

Từ gốc repo:

```powershell
node --test scripts/test/benchmark.test.mjs
node --test docs/numa_acceptance_data/nm09_2026-10-12/analyze.test.mjs
node --test docs/numa_acceptance_data/nm09_2026-10-12/report-profile.test.mjs
node docs/numa_acceptance_data/nm09_2026-10-12/analyze.mjs
```

Test profile dùng Docker Compose config/read-only, không start container.
Nếu Docker CLI không có trong PATH, đặt BATTLESHIP_DOCKER_CLI thành path
thực tế. Analyzer đọc raw/summary cũ, assert30mẫu, index0..29, seeds/flags,
tính lại summary và xác minh hashcache. Nó ghi **analysis/snapshot và block
bảng tổng hợp NM-09**, không sửa raw/summary/manifest NM-03 hoặc NM-09.
Các manual nhận xét sau block không bị ghi đè. Bootstrap paired-by-index
chỉ mô tả bất định cross-batch, không tạo ablation nhân quả.

## Giới hạn

Không có PMU/cache-miss/migration/context counters hoặc remoteNUMA đã đo.
Một Linux guest/Windows host, không hai thiết bị Wi-Fi. N1 không pin là đề
xuất opt-in cho một trận, chưa đổi base mặc định và chưa thay review nhóm.
Benchmark worker gồm vòng đời/ack, micro metadata không phải cacheCPU.

Snapshotcache harness khác manifest lịch sử; smoke đầu thất bại ở setup
bridgePORT0. Recipe final dùng runner hiện tại qua file mới
`scripts/remeasure-baseline.mjs --baseline`. Archive lỗi được giữ nguyên;
smoke final qua fixture/core/STM/TCP/WS, không khẳng định phục hồi exact
harness đo ngày11 hoặc binary build bitwise giống. Source historical Haskell
được đối chiếu hash; sourceaux từ Git94a7aaa, flags/GHC cố định.
