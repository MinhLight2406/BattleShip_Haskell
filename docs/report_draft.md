# Ghi chú biên soạn và phần chờ nhóm chốt

Ngày 2026-10-10, source nền `8bd7da9`. Bản nội dung kỹ thuật hoàn chỉnh ở [report_final.md](report_final.md); file này giữ phần **biên tập/nghiệm thu chưa có thông tin thật**, không tạo một báo cáo kỹ thuật cạnh tranh hoặc coi todo hành chính là thiếu implementation.

## 1. Nội dung đã có căn cứ

| Nội dung | Chỗ dùng trong bản báo cáo |
|---|---|
| Luật/phạm vi/dữ liệu và module | report_final, game_spec, architecture, shared_contract |
| Quá trình yêu cầu/commit, nguyên nhân mở UI/LAN/Docker | development_history |
| Lý do thiết kế, lợi ích/đánh đổi/phương án khác | design_decisions |
| Slide/mức áp dụng/kiến thức mở rộng | slide_mapping |
| Test oracle/coverage/seed/race/deadline và kết quả | testing, test_evidence, DK-08/DK-09 |
| Demo có thể làm lại | demo_script, README |

## 2. Phần còn chờ dữ liệu hoặc xác nhận

| Việc | Cần dữ liệu gì | Ai cập nhật / điều kiện |
|---|---|---|
| Trang bìa/danh sách nhóm | Trường/lớp/môn/giảng viên/mã SV/phân công thực tế | R nhận thông tin từ nhóm |
| Revision nộp cuối | SHA được cả nhóm duyệt | A/B/C/D/R review cùng SHA trong shared_contract |
| Hai thiết bị Wi-Fi thật | Thiết bị/browser/mạng/URL/log/ảnh và ván hoàn tất | B/C/D chạy checklist DK-08; không đổi nhãn test một máy |
| Đổi Wi-Fi vật lý giữa ván | Trước/sau IP, phát hiện/deadline, resume đúng người | C/D thực hiện khi có điều kiện; không lấy fixture thay cho chứng cứ vật lý |
| R9-S03-01 | Diff renderer/regression và log console 80 cột | D sửa/C chạy lại; hiện TODO |
| Nguồn tài nguyên UI | Tác giả/nguồn/quyền sử dụng ảnh/asset ngoài | Nhóm kiểm kê nguồn thật, không tự nhận mọi ảnh có license |
| Bản xuất Word/PDF/slides nếu môn yêu cầu | Template/độ dài/format/chữ ký/đề cương | Task xuất artifact riêng; hiện sản phẩm yêu cầu là Markdown docs |

## 3. Câu hỏi bảo vệ và câu trả lời kỹ thuật ngắn

- **Vì sao không viết luật trong Main?** Main lo cấu hình/IO; step thuần dễ test và dùng chung, không trộn socket/timing với gameplay.
- **Hai lệnh có thể cùng dùng lượt cũ?** TVar và state/event batch trong STM được revalidate khi conflict; race HIT kiểm tra chỉ actor đúng có update.
- **Client có thể đoán/lấy đội tàu?** Server không serialize fleet đối thủ; Event định tuyến riêng; view/private-pair test và DOM target fleet rỗng. HTTP LAN chưa chống nghe lén như TLS.
- **Queue đầy thì STM tự xử lý đúng không?** writeTBQueue tự chờ; dự án preflight + chỗ terminal + Quit tránh chặn cả trận.
- **Resume có chạy lại lệnh không?** Replay frame riêng dựng view, nối TCP cũ; không replay FIRE. QUIT hết hạn vẫn đi lõi thật.
- **Docker có giữ server khi tắt máy?** Không; RAM mất/process dừng. Hai service đóng gói môi trường, không phải host luôn bật hoặc persistence.
- **Đã dùng mọi slide chưa?** Có các phần phù hợp game; chưa NUMA optimization/Map–Reduce/NFS, ghi rõ slide_mapping.
- **Đã nghiệm thu hai máy chưa?** Chưa. Đã hai process Chrome/Edge trên một máy theo yêu cầu thay thế; physical checklist còn mở.

Không ghi câu trả lời hứa chức năng chưa có. Khi nhóm chốt dữ liệu, cập nhật bản nộp và bảng review, giữ hồ sơ/test lịch sử nguyên vẹn.
