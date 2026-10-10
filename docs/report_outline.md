# Dàn ý báo cáo đồ án

Đây là cấu trúc biên soạn/bảo vệ cho hệ thống hiện hành, không phải file giữ kết quả test mới. Nội dung kỹ thuật đã viết ở [report_final.md](report_final.md), căn cứ ở [design_decisions.md](design_decisions.md), [slide_mapping.md](slide_mapping.md), [testing.md](testing.md).

| Chương | Nội dung cần trình bày | Tài liệu / minh chứng |
|---|---|---|
| 1. Giới thiệu | Bài toán Battleship, mục tiêu môn học, tham khảo DKurilo, phạm vi hai người/một ván | Báo cáo mục 1/9, game_spec |
| 2. Cơ sở học thuật | Pure/immutable/ADT, module/test, thread/STM/supervision, message passing/TCP | Slide mapping đủ 14 PDF, code tương ứng; phân biệt ngoài slide |
| 3. Phân tích yêu cầu | Fleet/turn/win/errors/privacy, terminal rồi UI/LAN/resume/Docker | game_spec, development_history, scope mới sau S-04 |
| 4. Hợp đồng và dữ liệu | Coord/ShipId/Fleet/Phase/GameState/Command/Event/View, wire v1, ownership | Types/shared_contract/protocol; smart-constructor compile probes |
| 5. Thiết kế và xử lý | Module dependency, placement/fire/Quit; TVar/batch/queue/worker; frontend/bridge | architecture + diagrams + rationale/alternatives |
| 6. Triển khai | Snapshot/components, compiler; two image/stages/non-root; LAN host IP/origin/ports/health/lifecycle | YAML/Docker/Compose/helper, docker_deployment |
| 7. Kiểm thử | Hspec examples, QuickCheck oracle/coverage/seed, race/nonreader, browser/Compose | testing, test_evidence, DK-08/09/log/ảnh có ngày |
| 8. Kết quả/đánh giá | Ván chạy thật, lợi ích/đánh đổi, lỗi đã sửa, giới hạn/chưa xác nhận | Báo cáo mục 7/10, round9_fixes, DK-08 physical checklist |
| 9. Kết luận/hướng phát triển | Mức áp dụng kiến thức; phần hoàn tất kỹ thuật; task có điều kiện | Report kết luận; không biến AI/persistence thành tính năng đã có |
| Phụ lục | Lệnh chạy, transcript, task/commit, contract review, phiên bản môi trường | README/protocol/history/shared_contract/DK-09 |

## Cách viết mỗi phần kỹ thuật

Theo mẫu **vấn đề → yêu cầu → cách xử lý trong code → lý do chọn → lợi ích → đánh đổi/cách khác → test/bằng chứng → giới hạn**. Ví dụ queue: client không đọc → giới hạn RAM và kết thúc → TBQueue/preflight/126+2/Quit → tránh retry giữ cả trận → riêng writer → mất trận client chậm → STM capacity/race + TCP deadline → không giới hạn toàn RAM/kernel buffer.

Không chép toàn bộ source vào báo cáo. Dùng chữ ký/đoạn nhỏ/sơ đồ và dẫn file; mỗi đoạn giải thích invariant hoặc đường lỗi. Với slide, dùng filename/trang PDF verified, không chỉ nhắc “đã dùng STM”.

## Thông tin hành chính cần nhóm cung cấp

Tên trường/môn/giảng viên, nhóm/thành viên/mã sinh viên, phân công thực tế, ngày nộp và SHA dùng báo cáo chưa được cung cấp đầy đủ. Để trống ở bản xuất nộp đến khi nhóm điền; không suy từ Git author. Review cùng SHA ghi trong shared_contract, không ký hộ.
