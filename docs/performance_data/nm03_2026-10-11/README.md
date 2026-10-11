# NM-03 — Dữ liệu baseline thật 2026-10-11

Đo trước NM-04..07, nhánh Update_NUMA. Kết quả và phạm vi chi tiết:
[performance_baseline.md](../../performance_baseline.md).

- `manifest.json`: source/binary hash, HEAD nền và thay đổi chưa commit,
  compiler, flags, topology VM/container, quota, seed và số vòng calibration.
- `fixtures.json`: transcript đúng người của ba seed; không chứa SESSION/token.
- `samples.jsonl`: 420 mẫu, gồm 60 warm-up và 360 measured; metric thiếu là null.
- `summary.json`: 12 nhóm × 30 mẫu; median/p95/CI, block và metric availability.
- `comparisons.json`: ratio median so N1 và paired bootstrap 95% (seed 20261011).
- `evidence.json`: phiên bản/image, gate chức năng, log excerpt và SHA-256 artifact.

Bốn layer: core, coordinator, tcp, web. Ba profile: N1, N2, default.
Mỗi profile/layer có 5 warm-up và 30 measured; default đo được 12 capability.
Không loại outlier. Tất cả nhóm có spread ba block dưới 10%.
Source chưa commit nên HEAD chỉ là nền; đối chiếu sourceHashes/binaryHashes
để biết phiên bản thực đo. Không gọi kết quả loopback là nghiệm thu Wi-Fi
hoặc NUMA nhiều node. RTS memory không phải RSS; GC accounting của core/STM
gồm final GC ngoài clock. Token và nội dung SESSION không được ghi vào artifact.

Để đọc lại summary: `node scripts/benchmark-runtime.mjs --smoke` chỉ là
kiểm tra harness; chạy formal theo tài liệu với output mới. Có thể dùng
`parseSample`, `parseRTS`, `summarize` export từ runner để soát dữ liệu.
