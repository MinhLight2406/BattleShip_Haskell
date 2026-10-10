# Luật chơi Battleship

Tài liệu này là nguồn luật R-01 thống nhất cho cài đặt/kiểm thử. Bản hiện hành (đối chiếu `8bd7da9`, 2026-10-10) có đúng **một trận giữa hai người mỗi lần chạy Haskell**, qua terminal TCP hoặc giao diện web/bridge, native hoặc Docker. Server quyết định lệnh hợp lệ và giữ kín đội tàu. UI/LAN/Docker bổ sung sau không đổi quy tắc fleet/lượt/thắng dưới đây.

## 1. Bàn và đội tàu

- Mỗi người có một bàn **10×10**, cột `A` đến `J`, hàng `1` đến `10`. Ví dụ tọa độ hợp lệ: `A1`, `B7`, `J10`.
- Mỗi người phải đặt đúng năm tàu: Carrier (`CV`, 5 ô), Battleship (`BB`, 4 ô), Cruiser (`CR`, 3 ô), Submarine (`SB`, 3 ô), Destroyer (`DD`, 2 ô). Tổng cộng **17 ô tàu**.
- Mỗi tàu là một dải liên tiếp theo hàng (`H`) hoặc cột (`V`), có tọa độ bắt đầu. Tàu không được vượt mép bàn hoặc chồng lên tàu khác. Các tàu **được chạm cạnh hoặc chạm góc**.
- Một lệnh đặt tàu phải chứa đủ năm tàu và chỉ được chấp nhận nếu cả đội tàu hợp lệ. Nếu sai, server trả lỗi và cho người chơi nhập lại; không lưu một phần đội tàu.
- Sau khi đặt hợp lệ, người chơi không thể đổi vị trí tàu trong trận đó.

## 2. Bắt đầu trận và lượt chơi

1. Server gán Player 1 cho kết nối đầu tiên và Player 2 cho kết nối thứ hai. Client không tự khai danh tính người chơi.
2. Người đặt tàu xong trước nhận trạng thái **đang chờ**. Trận chỉ bắt đầu khi cả hai đội tàu hợp lệ; đây là điểm hẹn một lần.
3. Khi trận bắt đầu, **Player 1 bắn trước**. Chỉ người đang có lượt được gửi phát bắn hợp lệ.
4. Một phát bắn chọn đúng một tọa độ chưa từng bắn trên bàn đối thủ.

## 3. Kết quả phát bắn và chuyển lượt

| Kết quả | Điều kiện | Lượt tiếp theo |
|---|---|---|
| Trượt (`Miss`) | Ô không có tàu | Chuyển sang đối thủ |
| Trúng (`Hit`) | Ô có tàu nhưng tàu chưa chìm | **Người vừa bắn được bắn tiếp** |
| Chìm (`Sunk`) | Phát bắn trúng ô cuối của một tàu | **Người vừa bắn được bắn tiếp** |
| Thắng (`Win`) | Mọi ô của năm tàu đối thủ đã bị bắn trúng | Trận kết thúc ngay; không có lượt sau |

**Ví dụ:** P1 bắn `B7` trúng → P1 tiếp tục. P1 bắn `B8` trúng/chìm → P1 vẫn tiếp tục. P1 bắn `C8` trượt → P2 được bắn. Không giới hạn số phát bắn trúng liên tiếp, ngoài số ô tàu còn lại.

## 4. Lệnh không hợp lệ

Các trường hợp sau trả lỗi: tọa độ ngoài bàn hoặc sai cú pháp; bắn trước khi cả hai đã đặt tàu; bắn khi không phải lượt của mình; bắn lại một tọa độ đã bắn; đặt tàu lần hai; gửi lệnh sau khi trận kết thúc.

**Bất biến lõi:** lệnh không hợp lệ **không đổi bàn, số phát bắn, giai đoạn hay người đang có lượt**. Người gửi có thể sửa lệnh/thử lại. Coordinator giữ state khi đủ chỗ gửi lỗi; nếu outbox quá tải, C-07 xử lý bằng hành động Quit riêng của người nhận chậm từ state trước lệnh, không chấp nhận lệnh sai hoặc nước gây tràn.

## 5. Thông tin được phép thấy

- Người chơi thấy vị trí tàu của mình và các ô đối thủ đã bắn vào bàn mình.
- Trên bàn đối thủ, người chơi chỉ thấy các tọa độ mình đã bắn cùng kết quả trượt/trúng/chìm. Các ô tàu chưa bị bắn vẫn bí mật.
- Khi một tàu chìm, có thể thông báo tên tàu đã chìm; không tiết lộ vị trí các tàu còn lại.
- Server không gửi nguyên `GameState` hoặc toàn bộ đội tàu đối phương cho client.

## 6. Kết thúc bất thường và phạm vi

Lõi Haskell kết thúc khi nhận Quit hoặc TCP client EOF/lỗi socket trong lúc chờ/đang chơi: đối thủ thắng OPPONENT_LEFT. Không có người thay thế vào slot đã dùng. Finished không có lệnh làm đổi kết quả.

**Terminal/TCP trực tiếp:** ngắt kết nối thành Quit ngay, không có resume terminal. **Web:** bridge giữ TCP/phiên khi WebSocket mất, cho 300.000 ms nối lại đúng token; deadline bắt đầu khi bridge phát hiện mất kết nối. Trong khi thiếu người, bridge chặn PLACE/FIRE của các phiên web, QUIT vẫn được gửi. Resume dùng TCP cũ, không slot mới; hết hạn bridge gửi Quit đúng phiên để core xử lý. Rời trận chủ động khi kết nối gửi Quit ngay. Đây là policy transport, không thay luật step hoặc thêm Phase.

**Quá tải:** C-07 có thể Quit client có queue không đủ chỗ; không commit một phần nước/batch. Nếu hai queue cùng quá tải trong một batch, xử lý P1 trước và đánh dấu cả hai socket để đóng; sau Finished không kết thúc lần hai. Chi tiết capacity/chính sách ở shared_contract.

**Restart/mất host:** state/token trong RAM; restart core/bridge, dừng Docker hoặc máy chủ tắt không phục hồi ván. Trận mới cần chạy lại core rồi tạo phiên mới. Không có hòa, AI, nhiều phòng, lưu trận hoặc chế độ Trinh sát trong MVP. UI web/LAN/resume là các yêu cầu bổ sung đã triển khai; không giữ mô tả “không có kết nối lại” của bản terminal cũ làm hiện trạng web.

## 7. Ca kiểm thử nghiệm thu

1. Đặt tàu sát mép hợp lệ; đặt vượt biên/chồng tàu/sai độ dài bị từ chối.
2. Chỉ đội tàu thứ nhất sẵn sàng thì trận vẫn ở giai đoạn chờ.
3. P1 bắn trúng hai lần liên tiếp vẫn giữ lượt; phát thứ ba bắn hụt thì P2 nhận lượt.
4. Bắn chìm một tàu nhưng chưa thắng vẫn được bắn tiếp.
5. Bắn trúng ô tàu cuối cùng của đối phương kết thúc trận ngay.
6. Bắn sai lượt, bắn lặp hoặc nhập sai tọa độ không đổi trạng thái/lượt.
7. Hai lệnh tới gần như đồng thời không cùng dùng một lượt cũ.
8. Phản hồi cho P1 không chứa tọa độ tàu P2 chưa bị bắn.
