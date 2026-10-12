# NM-07 — Hồ sơ cấu hình, kiểm thử và phép đo

Ngày 2026-10-12 Asia/Saigon, Update_NUMA, source dirty trên nền 788f839.
Đọc [phân tích và lệnh chạy](../../numa_experiments.md) trước khi dùng dữ liệu.

## Phạm vi

- 111 unit Node qua; 29 ca NUMA mới.
- Container: 5 pass, 2 skip có lý do, 0 fail. Full game thật cho default,
  local cpuset và local membind; SIGTERM/restart và numactl fault injection.
- Một node RAM Linux nhìn thấy: remote chưa nghiệm thu.
- GHC 9.10.3 của binary báo compiled without NUMA support: GHC pools chưa
  nghiệm thu. numactl ở runtime không làm RTS tự có thêm tính năng.
- Không có phép đo NUMA tăng tốc, CPU cache counter hoặc Wi-Fi hai thiết bị
  mới trong hồ sơ này. Review của nhóm vẫn chờ.

## Artifact

| File/thư mục | Ý nghĩa |
|---|---|
| first/ | 30 mẫu + 5 warm-up/profile; default nhiễu, snapshot có thể sớm |
| repeat/ | Đo lại nguyên nhóm với thread RTS và >=64 private resident pages |
| repeat/matrix.json | Profile thành công/không nghiệm thu được tách rõ; speedupClaim=false |
| default.json, local-cpuset.json, local-membind.json | Topology, N/worker, CPU/RAM, public game frames, cleanup của gate cuối |
| shutdown-restart.json | PID1, hai peer đóng, restart ra P1 và deadline dừng |
| ghc.json | Preflight failure, không tiếp tục bằng bỏ cờ NUMA |
| compose-test.txt | Lần đầu thất bại ở chẩn đoán startup GHC, giữ lịch sử |
| compose-test-final.txt, node-test-final.txt | Gate thực sự chạy sau sửa |
| runtime-build.txt, benchmark-build.txt | Đóng gói công cụ/wrapper từ image NM-06, không compiler build mới |
| cached-runtime.Dockerfile, cached-benchmark.Dockerfile | Dockerfile nghiệm thu đã dùng; cần base image đúng fingerprint |
| measurement*.txt | Log driver, không giấu profile bị từ chối |
| evidence.json | Hash source/image/binary/artifact, số ca và giới hạn |

Mỗi nhóm đo chứa manifest.json, samples.jsonl và summary.json. Tổng hai loạt
**120 measured + 20 warm-up**. Loạt repeat xác minh binary/source và hash
harness. Không ghi đè số liệu NM-03..06 hoặc lọc outlier. Page count không
được quy thành byte bằng kích thước trang đoán trước.

## Tái hiện

Từ gốc repo, dùng Dockerfile source để build image hiện hành:

```powershell
docker build -f docker/haskell.Dockerfile -t battleship-haskell:local .
docker build -f docker/web.Dockerfile -t battleship-web:local .
docker build -f docker/benchmark.Dockerfile -t battleship-benchmark:nm07 .
node --test scripts/test/numa-config.test.mjs
node --test scripts/test/numa-compose.test.mjs
node scripts/benchmark-numa.mjs .env.numa .stack-work/nm07/measurement-new
```

Benchmark base cần tag Haskell test/web đúng như docker/benchmark.Dockerfile;
dùng --build-arg HASKELL_BENCH_BASE/WEB_BENCH_BASE khi tag khác. Lệnh build
source ở trên có gate compiler/test; hồ sơ hiện tại dùng cached packaging
của binary đã qua NM-06. Không nhận hai quá trình đó là cùng một lượt test.

Đặt .env.numa từ .env.numa.example. Loạt đo ở đây opt-in NUMA_SYS_NICE=1;
default/local đều dùng cùng CPU0/N1, cùng binary, policy cpuset. Đây là
default-memory có CPU/N kiểm soát, không production default N tự động.

Trên máy hai node, launcher chọn CPU A và RAM A/B từ topology được cấp;
comparable chặn thay CPU/N/policy/RTS. Remote chỉ được ghi nghiệm thu sau khi
trang private thực sự ở B và game/test/measurement qua. Kernel/runtime/quyền
khác có thể từ chối membind; khi đó failure phải được lưu, không đổi nhãn.

GHC NUMA cần compiler được build có hỗ trợ, không chỉ libnuma được cài.
Khi thay build compiler phải ghi fingerprint mới và chạy lại gate/baseline,
không gán kết quả phiên bản đó cho binary trong hồ sơ này.
