# Hồ sơ demo S-03

Ngày: 2026-10-05 (Asia/Saigon). **Đã chạy xong kỹ thuật; xác nhận nhóm còn chờ.**

Build sạch, 794 test xanh, một trận production qua ba phiên PTY thật trên port 58267; P1 thắng, cả hai client và server exit 0. Hồ sơ tổng hợp: [s03_acceptance.md](../../s03_acceptance.md); một vấn đề trình bày P3: [round9_fixes.md](../../round9_fixes.md).

- `build.log`, `test.log`, `commands.json`: lệnh/kết quả thật; `clean.log` rỗng vì Stack clean không in output.
- `player1.log`, `player2.log`, `server.log`: output console thực tế đã bỏ ANSI, không viết lại thành transcript kỳ vọng.
- `raw_console.json`: input/output thô từng chunk, timestamp UTC, session id, exit code. Ngày UTC có thể là 2026-10-04 vì múi giờ địa phương UTC+7.
- `scenario.json`: input và kết quả dự kiến, không phải log thu được.
- `source_sha256.csv`, `base-head.log`, `git-status-before.log`: xác định bộ source trong working tree chưa commit.
- `verification.json`, `verify_demo.ps1`: đối chiếu 27 source hash, thứ tự/lượt của 25 phát bắn và 54 snapshot hai bàn, tổng 10.800 ô.

Từ gốc repo: `& docs/demo/s03/verify_demo.ps1`. Script chỉ đọc và kiểm chứng log/source, không mở mạng hoặc sửa source. Nếu mã đã thay đổi sau demo, kiểm tra hash sẽ báo lỗi để tránh gán bằng chứng cũ cho bản mới. Thư mục log này được Git theo dõi bình thường, không nằm trong .stack-work bị ignore. Dùng log để review, không có ảnh chụp màn hình trong hồ sơ này.
