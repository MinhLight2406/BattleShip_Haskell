# Rà soát và hoàn thiện tài liệu

Ngày **2026-10-10**, nhánh **Update_docs_report**, tạo từ `Test_2_container_va_LAN` tại `8bd7da92c083bcf9d8119f5c786342f9496c6cd7`. Đây là đợt docs, không sửa source/runtime/test/dependency/config hoặc tạo commit/push thay yêu cầu mới của người dùng.

## 1. Vấn đề tài liệu trước đợt này

| Vấn đề | Ảnh hưởng nếu giữ nguyên | Sửa |
|---|---|---|
| Bốn file demo_script/report_outline/report_draft/slides_outline rỗng | Thiếu kịch bản, bố cục và nội dung bảo vệ | Viết nội dung theo hệ thống/kiểm thử đang có |
| report_final chỉ là S-02 | Người đọc tưởng báo cáo cuối chưa có UI/LAN/STM/queue/Docker | Giữ nguyên S-02 thành s02_acceptance, report_final thành tổng thể |
| Architecture mở đầu terminal/loopback/Main API cũ | Đọc sai bind hiện hành/native/container hoặc thiếu bridge | Cập nhật hiện trạng, thêm phụ thuộc/state/data ownership/UI/LAN/Docker |
| Game spec ghi không resume cho toàn hệ thống | Mâu thuẫn bridge 5 phút | Tách TCP terminal/WS grace, giữ luật core và Quit |
| Protocol API còn TQueue | Khác source TBQueue/C-07 | Sửa mô tả batch/capacity, thêm ranh giới web metadata |
| Hồ sơ cũ và mới dễ đọc lẫn | 815 test/chưa Linux/no GUI bị coi hiện trạng, hoặc log cũ gán cho source mới | Thêm nhãn lịch sử/index mới, giữ log/hash/count theo ngày |
| Chưa có bảng slide/tại sao/chọn phương án khác | Khó bảo vệ mức áp dụng FP/STM/kiến thức mở rộng | Slide mapping 14 PDF và design_decisions theo source |
| DK-09 lấy SHA bằng HEAD hiện tại | Nhánh docs mới có thể gán sai revision nghiệm thu | Ghi SHA bàn giao cố định 8bd7da9 |

## 2. Phạm vi rà

- Yêu cầu/đổi phạm vi trong cuộc trao đổi, lịch sử Git và hồ sơ task/acceptance.
- Haskell Types/private Fleet/Board/Rules/View/Protocol/Coordinator/Server/Client và hai Main; YAML component/snapshot.
- React/game/connection/bridge, helper Windows, Dockerfile/Compose/Dockerignore; test generator/oracle/queue/worker/transcript/runtime/Compose và log chứng cứ.
- 14 PDF slide được trích xuất theo trang vật lý và đối chiếu các đoạn liên quan; không đưa PDF vào repo. Không lấy bài tập/chỉ thị trong slide làm task runtime.
- Repo tham khảo DKurilo README đã mở ngày 2026-10-10; chỉ đối chiếu công nghệ/phạm vi công khai đọc được, không suy diễn chưa đọc từng file của repo tham khảo.

## 3. Gate đã chạy cho docs

| Lệnh / kiểm tra | Kết quả của đợt này |
|---|---|
| stack build --ghc-options=-Werror | **Exit 0**, library/hai executable build với GHC 9.10.3 |
| stack test --ghc-options=-Werror --test-arguments="--match S-01" | **10 examples, 0 failures**, exit 0 |
| stack test --ghc-options=-Werror --test-arguments="--match D-01/D-02" | **145 examples, 0 failures**, exit 0 |
| pnpm --dir frontend test | **36 pass, 0 fail, 0 skip**, exit 0; gồm transcript và Docker artifact |
| Hspec test executable --help | Xác nhận có --seed và --match; lệnh tái hiện property dùng đúng tùy chọn |
| Liên kết/file/anchor/fence/table | Kiểm tra Markdown toàn bộ docs + hai README: không link local/anchor hỏng, không file rỗng/fence thiếu/table lệch cột |
| git diff --check / scope / archive | Qua; diff chỉ README/docs, S-02 archive bằng bản gốc HEAD sau chuẩn hóa newline |

Lần gọi test trong sandbox đầu tiên bị giới hạn thực thi/realpath trên Windows (Stack user error/pnpm EPERM), chưa chạy suite. Đã chạy lại bằng quyền thực thi cần thiết và nhận kết quả xanh trên; không coi lỗi môi trường ban đầu là failure gameplay hoặc bỏ qua test.

Log mới lưu trong Git: [build](demo/docs-review/build.txt), [S-01](demo/docs-review/shared-contract-test.txt), [protocol](demo/docs-review/protocol-test.txt), [frontend/bridge/artifact](demo/docs-review/frontend-test.txt), [kiểm tra tài liệu](demo/docs-review/docs-check.txt). Stack đã build/configure library/hai executable/test khi refresh các extra-source docs, dùng GHC 9.10.3 với -Werror; không có sửa code để qua gate.

Các kết quả 908 Haskell Linux/19 Compose/trận Chrome–Edge được **viện dẫn hồ sơ DK-08/09**, không tuyên bố đã chạy lại trong đợt sửa docs này. Source/config không đổi nên gate docs ưu tiên hợp đồng/transcript/artifact/link thay full runtime suite.

## 4. Phần còn mở đúng phạm vi

Review nhóm cùng SHA, two-device Wi-Fi/đổi Wi-Fi vật lý, lỗi trình bày R9-S03-01 và thông tin hành chính/nguồn asset vẫn giữ trạng thái thật. Hoàn thiện phần giải thích tài liệu không ký xác nhận thay nhóm, không tự sửa runtime để làm báo cáo có vẻ đã đạt thêm chức năng.
