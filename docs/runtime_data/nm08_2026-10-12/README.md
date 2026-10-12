# Bằng chứng NM-08 — 2026-10-12

Nhánh Update_NUMA, nền 788f839 và working tree NM-07/NM-08. Phân tích tại
[runtime_regression.md](../../runtime_regression.md). Đây là hồ sơ của một
host Windows và Docker Linux/WSL; hai browser process không phải hai thiết
bị vật lý.

## Đọc kết quả

- `report.json`: các lệnh, exit, source hash, image ID, topology và trạng thái
  từng profile. `unaccepted` tách khỏi pass. Probe GHC không có NUMA support
  được đánh dấu `expectedUnsupported`; nó không phải một functional test pass.
- `acceptance.json`: đối chiếu số example, tổng ca Compose và checksum transcript;
  phiên bản compiler/Node/OS, hash binary và harness khi lưu hồ sơ.
- `native-N1.txt`, `native-N2.txt`: hai suite Haskell native, có cả example count.
- `<profile>-linux.txt`: hai suite Haskell Linux với Werror và RTS/mask tương ứng.
- `<profile>-compose.txt`: 13 kịch bản thực tế của từng cấu hình được nghiệm thu.
- `<profile>-transcript.json`: ba seed, phản hồi P1/P2 và bằng chứng mask/pages;
  không chứa SESSION token. `<profile>-ui-0/1.png`: browser desktop/mobile,
  token đã được mask.
- `frontend-unit.txt`, `frontend-integration.txt`, `frontend-types.txt`,
  `frontend-build.txt`, `scripts-unit.txt`: các gate frontend và script.
- `cached-*.Dockerfile`, `linux-build.txt`, `runtime-build.txt`: đường build
  lần này dùng cache compiler Linux và đóng gói binary vừa build. Lệnh chạy
  từ source bằng Dockerfile production nằm trong tài liệu NM-08.
- `google-verification.json`: kết quả readback thẻ con NM-08 và bảo toàn các
  thẻ cũ; chỉ thêm sau khi cập nhật Google Docs.
- `manifest.json`: size/SHA-256 của artifact, không tự băm chính manifest.

## Lịch sử lỗi và gate dùng lại

Các file `attempt1-*`, `attempt2-*`, `attempt3-*` giữ lỗi cũ để có thể kiểm
tra quá trình sửa. Chúng không phải danh sách lỗi còn mở của lần chốt:

1. Harness chưa truyền đường dẫn executable vào các test LAN, gây ENOENT.
2. Verifier đọc cả log của trận trước trên container được mở lại, thấy hai
   dòng capability. Sửa phạm vi bằng thời điểm StartedAt.
3. Browser assertion chạy trước khi WebSocket nhận WELCOME. Sửa bằng chờ
   START/TURN và điều kiện nhận danh tính, không thêm sleep.

Các gate native/Linux xanh có thể được dùng lại trong cùng phiên làm việc
khi source/argv và image identity cần thiết khớp. Report lưu provenance;
các attempt trước giữ chuỗi lần chạy. Các kịch bản Compose được chạy lại
để kiểm tra sửa lỗi harness. Không gộp lỗi lịch sử thành pass, không xóa
dữ liệu cũ để làm báo cáo trông xanh.

Không dùng elapsed time của run functional có nhiều fixture đồng thời để
kết luận performance. Remote cần ít nhất hai RAM node Linux được cấp; GHC
NUMA cần binary được build có support. Hai điều kiện thiếu được ghi riêng.
