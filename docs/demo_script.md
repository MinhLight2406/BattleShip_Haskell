# Kịch bản trình diễn và ghi nghiệm thu

Áp dụng bản hiện hành nền `8bd7da9`. Lệnh deploy chuẩn ở [README](../README.md); luồng vận hành đã nghiệm thu ở [DK-09](dk09_handover.md). Mục đích: người khác chơi lại một ván, nhìn được luật/riêng tư/reload/kết thúc và ghi kết quả đúng phạm vi.

## 1. Chuẩn bị

1. Docker Desktop Linux containers chạy, source/config/image theo README. Chọn Localhost hoặc Auto LAN, chọn adapter/cổng **trước trận**.
2. Dùng đúng project/env-file helper in ra cho ps/log/start/stop/down. Giữ helper Auto mở; localhost/manual không cần vòng theo dõi liên tục.
3. Hai trình duyệt/profile độc lập, ví dụ Chrome P1/Edge P2. Nếu có hai thiết bị thật, dùng URL LAN trên mỗi thiết bị; localhost trên máy khách là máy khách, không server.
4. Đợi core/web healthy. Không kiểm tra core bằng telnet/netcat/port scan 4000: kết nối này có thể chiếm slot rồi bỏ cuộc.
5. Mở URL chỉ tải HTML chưa tạo player; vào Cổ điển/đặt tàu/Bắt đầu trận mới nối WS/TCP. Không giữ tab trận cũ đang auto-resume khi muốn vào trận mới.

Ghi `git rev-parse HEAD`, OS, Docker/Compose/browser versions và URL/cổng (không ghi token). Nếu working tree khác commit, lưu diff/phạm vi. Không giả định IP của buổi trước vẫn đúng.

## 2. Kịch bản chính — hai browser/thiết bị

### Bố trí

Mỗi người Vào phòng tác chiến → Cổ điển. Tất cả tàu demo **ngang**, chọn đúng tên rồi click ô đầu:

| Ship | Dài | P1 đầu | P2 đầu |
|---|---:|---|---|
| CV | 5 | A1 | A6 |
| BB | 4 | A2 | A7 |
| CR | 3 | A3 | A8 |
| SB | 3 | A4 | A9 |
| DD | 2 | A5 | A10 |

Đây là fleet thống nhất cho demo, không phải stub hoặc UI biết bí mật đối thủ. Trước đặt CV ở P1 thử J10: UI báo vượt biên, không thêm ô tàu; sửa về A1. Mỗi bàn đủ 17 ô rồi xác nhận. P1 Bắt đầu trước → nhận P1/chờ đối thủ. P2 xác nhận → P2, bắt đầu/TURN P1.

### Lượt và kết quả

| Bước | Thao tác | Kỳ vọng |
|---|---|---|
| 1 | P2 thử click mục tiêu trước lượt | Disabled; không gửi FIRE |
| 2 | P1 bắn J10 | MISS, P2 đến lượt |
| 3 | P2 bắn J10 | MISS, P1 đến lượt |
| 4 | P1 bắn A6 | HIT, P1 giữ lượt, P2 nhận INCOMING |
| 5 | Reload P1 | Cùng P1/token, own fleet 17 ô và SHOT/INCOMING khôi phục, không bắn lại A6 |
| 6 | P1 B6/C6/D6/E6 | Ba HIT rồi SUNK CV, P1 giữ lượt |
| 7 | P1 A7/B7/C7/D7 | Ba HIT rồi SUNK BB |
| 8 | P1 A8/B8/C8 | Hai HIT rồi SUNK CR |
| 9 | P1 A9/B9/C9 | Hai HIT rồi SUNK SB |
| 10 | P1 A10/B10 | HIT rồi WIN; cả hai GAME_OVER P1 ALL_SHIPS_SUNK |

Tổng P1 18 phát (1 MISS +17 ô tàu), P2 1 MISS. B10 là WIN, không SUNK DD rồi lượt tiếp. Sau kết quả, mọi mục tiêu disabled, P1 thắng/P2 thua; core Exited 0, web còn phục vụ kết quả. Mỗi bàn đối thủ chỉ hiển thị các ô đã bắn, không các ship segment chưa bắn; own fleet P1 vẫn có 17 ô chưa bị P2 bắn trúng.

Mở browser/profile thứ ba khi cả hai đã nhận WELCOME: xác nhận fleet hợp lệ → ERROR SERVER_FULL, không nhận P1/P2. Không dùng profile đang có token của P1/P2 để thử người thứ ba.

UI chặn input sai lượt/tọa độ/lặp trước khi gửi; không giả rằng chỉ thao tác disabled đã chứng minh server validation. Các ca **gửi lệnh sai thật** (K1/sai lượt/lặp) có trong integration/Compose. Khi trình bày phân biệt kiểm tra UI và kiểm tra Haskell.

## 3. Demo resume/IP/bỏ cuộc — dùng ván mới

- **Reload:** bước 5 ở trên đã đủ kiểm tra resume cùng origin, server giữ TCP. Có thể đóng browser rồi quay lại mã riêng trước hạn; không chia mã/log token.
- **Đổi IP thật:** chỉ làm khi có điều kiện và hai thiết bị; lưu mã riêng trước, giữ Auto helper, đổi mạng máy chủ, đợi URL mới, cả hai cùng mạng mới và mở URL/resume. Hạn tính từ bridge phát hiện WS mất. Nếu router cô lập client hoặc firewall chặn cổng thì cần ghi failure thật, không gọi là lỗi luật.
- **Origin đổi fixture:** test tự động thay allowlist/clock không phải physical Wi-Fi change; ghi đúng tên phương pháp.
- **Bỏ cuộc ngay:** ván mới, P1 nhấn Rời trận khi đang nối → P2 thắng OPPONENT_LEFT, core thoát. Không đợi 5 phút.
- **Hết hạn:** ván mới, ngắt WS P1 giữ backend, quá deadline → Quit P1/P2 thắng. Ca 5 phút trong automated dùng clock kiểm soát; nếu demo thời gian thực, ghi thời điểm phát hiện/deadline/kết thúc.
- **Restart:** ván mới đang chơi, restart core hoặc web → phiên cũ đóng rõ, không giả hồi phục; quay đầu, core ready rồi tạo game/token mới theo hướng dẫn. Không restart deployment người khác trong lúc demo.

## 4. Trận mới và dừng

Chờ core Exited, dùng lệnh `start haskell` với env-file/project hiệu lực của README, đợi healthy. Hai người Về trang đầu, đặt lại và Bắt đầu trận để nhận token mới; web không cần restart. Kết thúc demo: Ctrl+C helper Auto, stop/down đúng project, kiểm tra không còn container/network/cổng của deployment đó.

## 5. Mẫu ghi nghiệm thu

| Mục | Ghi nhận thực tế |
|---|---|
| Ngày/giờ/timezone | Điền lúc chạy |
| SHA / working-tree diff | Điền SHA thực, không lấy mặc định từ báo cáo |
| OS/CPU architecture/Docker/Compose | Phiên bản lệnh thực tế |
| Browser/thiết bị | Hai process cùng host hoặc hai thiết bị thật; ghi rõ |
| Mạng/IP/cổng/mode/interface | Public URL đúng buổi chạy, không token |
| Placement/lỗi UI/P1P2/P3 | PASS/FAIL + lý do/bằng chứng |
| MISS/HIT/SUNK/WIN/turn/privacy | PASS/FAIL + log/ảnh |
| Reload/đổi IP/expiry/restart | Chỉ PASS nếu đã chạy ca; chưa chạy ghi CHƯA KIỂM CHỨNG |
| Core exit/web state/stop/down | Exit code/deadline và tài nguyên còn lại |
| Người thao tác/reviewer | Tên/lời xác nhận thật + cùng SHA |

Ảnh trận có thể chứa **own fleet** nhưng không lưu token; crop/redact mã riêng trước commit. Không sửa log cũ để gán cho lần chạy mới. Hồ sơ đã có của một máy/Chrome+Edge tại [DK-08](dk08_acceptance.md); checklist hai thiết bị vẫn chưa được điền bằng kết quả thật.
