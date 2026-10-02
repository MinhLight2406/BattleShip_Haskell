# Hợp đồng giao tiếp client server

Đây là **bản đề xuất cho mốc S-01**. D phụ trách chốt cú pháp với A/B/C trước khi viết parser; mọi thay đổi sau S-01 phải được cả bốn người lập trình xác nhận.

## Ranh giới

- Một kết nối TCP tương ứng một người chơi; server gán `P1` hoặc `P2`.
- Mỗi thông điệp là một dòng UTF-8 kết thúc bằng newline. Giới hạn độ dài dòng để từ chối input bất thường.
- Client gửi lệnh; server trả thông báo cho đúng người nhận. Không có trường `PlayerId` do client tự khai.
- Parser kiểm tra cú pháp; `Rules.step` kiểm tra luật. Lỗi ở hai lớp đều không tiêu lượt.

## Lệnh từ client

| Lệnh logic | Nội dung | Chỉ hợp lệ khi |
|---|---|---|
| `PlaceFleet` | Năm vị trí tàu gồm mã tàu, tọa độ đầu và hướng `H`/`V` | Người chơi chưa đặt tàu và trận đang chờ đặt |
| `Fire Coord` | Một tọa độ `A1`–`J10` | Cả hai đã sẵn sàng, đúng lượt, tọa độ chưa bắn |
| `Quit` | Yêu cầu rời trận | Kết nối còn hoạt động |

Ví dụ cú pháp dòng để nhóm xem xét: `FIRE B7` và `PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H`. Ví dụ `PLACE` đặt đủ năm tàu, không chồng nhau. Có thể thay cú pháp này tại S-01 nhưng không thay các quy tắc trong `game_spec.md`.

## Thông báo từ server

| Loại logic | Người nhận | Ý nghĩa |
|---|---|---|
| `Welcome PlayerId` | Client vừa kết nối | Danh tính do server gán |
| `Waiting` | Người đặt xong trước | Chờ người còn lại đặt tàu |
| `Start PlayerId` | Cả hai | Trận bắt đầu; P1 đi trước |
| `ShotResult Coord Outcome` | Người bắn | Trượt, trúng, chìm hoặc thắng |
| `IncomingShot Coord Outcome` | Người bị bắn | Ô nào trên bàn mình vừa bị bắn |
| `Turn PlayerId` | Cả hai | Ai được bắn tiếp |
| `Error GameError` | Chỉ người gửi lệnh sai | Lý do từ chối; trạng thái giữ nguyên |
| `GameOver Winner Reason` | Cả hai nếu còn kết nối | Thắng do bắn hết tàu hoặc đối thủ bỏ cuộc |

Sau `Hit` hoặc `Sunk`, `Turn` vẫn là **người vừa bắn**. Sau `Miss`, `Turn` là **đối thủ**. Nếu `Win`, gửi `GameOver` và không phát thêm `Turn`.

Server chỉ gửi sự kiện và góc nhìn riêng `viewFor`; không serialize nguyên `GameState` ra TCP. C và D cần chốt cách encode các thông báo trên trong S-01 và lưu một transcript mẫu để test hai phía.
