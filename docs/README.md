# Bộ tài liệu BattleShip Haskell

Cập nhật **2026-10-10**, nhánh `Update_docs_report`, từ `Test_2_container_va_LAN` tại commit `8bd7da92c083bcf9d8119f5c786342f9496c6cd7`. Mô tả hiện hành được đối chiếu với mã ở commit này. Nhánh tài liệu không tự thay luật, API hoặc xác nhận nghiệm thu của nhóm.

Phần NUMA NM-01..NM-09 được cập nhật **2026-10-12** trên `Update_NUMA`;
xem các hồ sơ riêng bên dưới để đọc trạng thái runtime và gate mới. Các
hồ sơ cũ giữ ngày và phạm vi nghiệm thu của từng mốc.

Báo cáo và slide được nhóm quản lý riêng. Repo giữ tài liệu hợp đồng, kiến trúc, xử lý, vận hành và kiểm thử.

## Đọc theo mục đích

| Mục đích | Thứ tự đọc |
|---|---|
| Chạy và chơi | [README gốc](../README.md) → [kịch bản demo](demo_script.md) |
| Hiểu xử lý | [Kiến trúc](architecture.md) → [luật](game_spec.md) → [giao thức](protocol.md) |
| Phát triển module | [Hợp đồng chung](shared_contract.md) → source liên kết trong kiến trúc → test tương ứng |
| Docker/LAN | [Hợp đồng triển khai](docker_deployment.md) → [Dockerfile và runtime test](../docker/README.md) → [DK-09](dk09_handover.md) |
| NUMA/locality/affinity | [Hợp đồng NM-01](numa_design.md) → [Topology, preflight và bằng chứng NM-02](numa_environment.md) |
| Baseline trước tối ưu | [Benchmark NM-03, số liệu và lệnh tái hiện](performance_baseline.md) |
| Chạy CPU affinity | [NM-04: cpuset, RTS, kiểm chứng process và chuyển chế độ](affinity_runtime.md) |
| Worker và locality hiện hành | [NM-05: mailbox, quyền sở hữu, strictness, supervision và số đo](worker_locality.md) |
| Fleet tính sẵn và thử bố trí cache | [NM-06: metadata bất biến, bảng 100 ô, test độc lập và đánh đổi hiệu năng/bộ nhớ](fleet_index.md) |
| Bố trí CPU–RAM theo NUMA | [NM-07: cpuset-mems, membind, kiểm chứng trang nhớ và giới hạn môi trường](numa_experiments.md) |
| Hồi quy các cấu hình runtime | [NM-08: ma trận N1/N2, affinity/NUMA, transcript, hàng đợi và cleanup](runtime_regression.md) |
| Kết luận kiến thức và cấu hình báo cáo | [NM-09: cơ chế, đánh đổi, số liệu riêng/kết hợp, tái hiện và phần chưa nghiệm thu](numa_acceptance.md) |
| Kiểm chứng kết quả | [Hướng dẫn test](testing.md) → [chỉ mục bằng chứng](test_evidence.md) → log/ảnh từng mốc |
| Kiểm tra đợt sửa docs này | [Hồ sơ rà tài liệu](docs_review.md): thay đổi, gate mới chạy và giới hạn |
| Quá trình thực hiện | [Lịch sử phát triển](development_history.md) → [hồ sơ tích hợp UI](frontend_integration.md) |

## Nguồn chuẩn và hồ sơ lịch sử

Báo cáo, dàn ý và đối chiếu slide được nhóm quản lý riêng, không nằm trong các file được Git theo dõi. Tài liệu trong repo tập trung vào hợp đồng, kiến trúc, xử lý, vận hành và kiểm thử.

Các file Word `.docx` và báo cáo có tên bắt đầu bằng `Bao_cao_`/`bao_cao_` được giữ cục bộ, không đưa vào Git. Bản chuyên sâu biên soạn ngày **2026-10-11** thuộc nhóm file cục bộ này. Các kết quả runtime trong báo cáo được dẫn từ hồ sơ nghiệm thu theo đúng ngày và revision; lần biên soạn này không chạy lại hoặc ghi thêm xác nhận nghiệm thu của nhóm.

- **Luật:** `game_spec.md`. **Wire TCP v1:** `protocol.md`. **Kiểu/chữ ký/chủ sở hữu:** `shared_contract.md`. **Cấu hình Docker:** `docker_deployment.md`. Báo cáo giải thích, không định nghĩa một bộ luật khác.
- **Hồ sơ theo thời điểm:** [S-02](s02_acceptance.md), [S-03](s03_acceptance.md), [S-04](s04_feature_freeze.md), [D-06](d06_demo.md), [DK-08](dk08_acceptance.md), [DK-09](dk09_handover.md). Số test/phạm vi thuộc lần chạy được ghi, không cộng thành số test hiện tại.
- **Vấn đề đã ghi nhận:** [round9_fixes.md](round9_fixes.md). Không đổi TODO thành hoàn thành khi chưa có log chạy lại.
- **Log/ảnh trong Git:** `docs/demo/`. Log local trong `.stack-work/` không bảo đảm người clone nhận được.

## Quy tắc cập nhật

1. Đổi luật/API/cấu hình: cập nhật nguồn chuẩn, code và test liên quan; nhóm review contract cùng SHA trước hợp nhất.
2. Kết quả mới: ghi ngày, môi trường, lệnh, exit code, phạm vi và log; giữ hồ sơ cũ với nhãn lịch sử.
3. Sửa docs: kiểm tra link, ví dụ wire, S-01 và Docker artifact test khi liên quan; không gán kết quả runtime cũ thành lần chạy mới.
4. Chỉ ghi xác nhận A/B/C/D/R khi có lời xác nhận thật. Commit/push và test xanh không thay chữ ký nhóm.

Hiện đã có nghiệm thu Linux/container và một máy dùng Chrome/Edge. Hai thiết bị Wi-Fi thật, đổi Wi-Fi vật lý giữa trận và xác nhận nhóm chưa được cung cấp; xem DK-08/DK-09.
