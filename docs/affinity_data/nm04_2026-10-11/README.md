# NM-04 — Bằng chứng affinity thật

Ngày 2026-10-11, nhánh Update_NUMA, source chưa commit.
Xem [phân tích và lệnh chạy lại](../../affinity_runtime.md).

- container.json: Haskell CPU11/N1, web CPU0; trận seed424242 đủ25 lệnh.
- rts.json: Haskell CPU0,1/N2/-qa, web CPU2; trận seed8675309 đủ25 lệnh.
- shutdown-restart.json: SIGTERM đóng hai peer đang kết nối, trận mới nhận P1.
- evidence.json: hash source/image/artifact, gate/log và phạm vi được kiểm tra.
- cached-verification.Dockerfile: route build dùng cache compiler/dependency
  DK-04 và full test source hiện tại; runtime stage giữ như Dockerfile gốc.

TID/CPU/port/container ID là dữ liệu lần chạy, không phải cấu hình ghi cứng.
Frame là game fixture tổng hợp; không ghi token hoặc metadata SESSION.
Snapshot /proc là CPU Linux trong Docker/WSL, không xác nhận CPU vật lý Windows.
Không đo tăng tốc, cache counter hoặc NUMA nhiều node từ gate chức năng.
