# Dàn ý trình bày đồ án

Gợi ý **12 slide / khoảng 15 phút**; đây là dàn ý nội dung, chưa tạo PPT/PDF. Dùng [báo cáo](report_final.md), [slide mapping](slide_mapping.md), [rationale](design_decisions.md), [demo](demo_script.md) làm nguồn. Điền tên nhóm/môn/giảng viên từ thông tin thật.

| Slide | Thời gian | Nội dung / hình nên dùng | Ý cần nói |
|---|---:|---|---|
| 1. Đề tài/mục tiêu | 0:45 | Battleship hai người, Haskell/core/web/LAN/Docker | Mục tiêu môn học và phạm vi một ván |
| 2. Luật/nghiệm thu | 1:00 | Bàn 10×10, năm tàu/17 ô; bảng MISS/HIT/SUNK/WIN | Trúng giữ lượt, sai không đổi state, bí mật riêng |
| 3. Quá trình thực hiện | 0:45 | Timeline package→core→STM/terminal→UI/LAN→QuickCheck/queue→Docker | UI/Docker là yêu cầu mở rộng sau S-04 |
| 4. ADT và Fleet | 1:15 | Phase/Command/GameState/Maybe Fleet; smart constructor boundary | Type cho hình dạng, Board bảo vệ invariant |
| 5. Lõi thuần | 1:15 | Chữ ký step + luồng FIRE/check/update/Event | Cùng input/cùng output, không IO trong luật |
| 6. Atomicity/queue | 1:45 | TVar + preflight batch + hai TBQueue/writer, 128/126/2 | State/frame cùng commit, chậm Quit đúng recipient |
| 7. Privacy/giao thức | 1:00 | SHOT/INCOMING riêng, target fleet rỗng, private-pair | Không chỉ CSS ẩn; không gửi GameState |
| 8. UI/resume/LAN | 1:15 | WS→bridge→TCP; token/replay; host helper→origin | Giữ TCP 5 phút, đổi IP không restart, URL mới vẫn cần người chơi |
| 9. Docker/vòng đời | 1:15 | Hai service/8081→8080/haskell:4000/health marker | Probe không slot; restart no; host tắt thì dừng |
| 10. Test/bằng chứng | 1:15 | Ma trận unit/property/race/TCP/browser/container; log có ngày | QuickCheck ≥1.000/coverage/seed, Linux 908, Compose 19, không cộng counts |
| 11. Demo | 2:30 | Lỗi đặt J10, hai player, MISS, HIT/reload, SUNK/kết quả | Dùng đoạn demo ngắn hoặc ảnh/log, đủ thời gian thì ván đầy đủ |
| 12. Đánh giá/giới hạn | 0:45 | Lợi ích/đánh đổi, physical test/review/80-cột TODO | Không nhận two-device/persistence/TLS đã xong |

## Chuẩn bị hình và lời nói

- Sơ đồ module/STM lấy từ architecture/report; diagram là mô tả hiện trạng, không ảnh minh họa hệ thống khác.
- Log/ảnh thật Chrome/Edge nằm ở DK-08; ảnh thắng/thua và trước reload nếu có. Không chèn token/private recovery code.
- Mỗi đoạn code tối đa vài dòng: chữ ký step, Phase, ví dụ Left; source đầy đủ dẫn trong tài liệu.
- Kiến thức: nói rõ Chap8 có Hspec/QuickCheck, Chap5/6 STM, Chap7 cleanup, Chap9 queue, Chap10/11 message/socket; phần React/Docker là mở rộng.
- Dự án DKurilo là tham khảo Haskell–web; không nói cùng Snap/MongoDB khi code hiện tại không dùng.

## Demo trực tiếp và dự phòng

Chạy build/test và mở deployment trước buổi bảo vệ; dùng URL đúng của mạng buổi đó. Hai browser/profile hoặc hai thiết bị tùy điều kiện, ghi đúng phương pháp. Theo demo_script đặt fleet/xác nhận/MISS/HIT/reload. Nếu chỉ 2:30 phút, trình diễn đến reload rồi dùng log/ảnh ván đầy đủ đã có để nói kết quả, không giả đang live toàn ván.

Nếu Docker/mạng không ready, dùng ảnh/log với ngày/phạm vi và giải thích hạn chế; không chỉnh browser state để giả thắng. Đóng demo và down đúng project sau buổi trình bày; cần trận mới start core như README.
