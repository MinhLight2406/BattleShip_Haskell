# Task sửa phát hiện từ demo — Đợt 9

## R9-S03-01 — Rút gọn thông báo kết thúc trên terminal 80 cột

- **Ưu tiên:** P3, trình bày; không chặn ván hoặc làm sai winner.
- **Chủ xử lý:** D; C kiểm tra lại khi chạy demo.
- **Trạng thái:** TODO, chưa sửa trong S-03 vì đây là task được ghi cho Đợt 9.
- **File:** `src/Battleship/Client.hs`, `test/ClientSpec.hs`.
- **Bằng chứng thật:** cuối `docs/demo/s03/player1.log` có thông báo kết thúc rồi một dòng `c.` riêng. `raw_console.json`, lần collect cuối P1, có cập nhật cursor `ESC[23;80H` trước phần cuối này. Chuỗi render thắng P1 dài 81 ký tự trên console 80 cột, bị wrap/repaint làm log văn bản khó đọc. `Bạn thắng!`, winner P1 và exit 0 vẫn đầy đủ; không coi đây là lỗi gameplay/mất GAME_OVER.
- **Tái hiện:** mở console 80 cột, chạy hai client theo kịch bản `docs/demo/s03/scenario.json`, cho P1 thắng bằng I2; xem cuối output.
- **Việc sửa:** rút gọn hoặc chủ động chia thông báo kết thúc thành các dòng ngắn, đặt kết quả người chơi ở dòng cuối; giữ nội dung winner/lý do và không sửa wire v1.
- **Xong khi:** cả thắng/thua và bỏ cuộc hiển thị đủ nội dung dễ đọc trên terminal 80 cột, không có phần đuôi tách/ghi đè vì wrap; test nội dung renderer xanh và có log console chạy lại.

Không phát hiện lỗi luật, lộ tàu hoặc lỗi kết nối chặn hoàn thành ván trong lượt S-03 này. Lỗi mất GAME_OVER khi còn dữ liệu chưa đọc đã có hồi quy và được sửa tại C-05; không tạo task mở trùng cho lỗi đã sửa.
