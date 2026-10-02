# Luật chơi Battleship

Tài liệu này là nguồn thống nhất cho phần cài đặt và kiểm thử. Phiên bản đầu có đúng **một trận giữa hai người**, mỗi người dùng một client terminal. Server quyết định mọi lệnh hợp lệ và giữ kín đội tàu của từng người.

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

**Bất biến bắt buộc:** lệnh không hợp lệ **không đổi bàn, số phát bắn, giai đoạn hay người đang có lượt**. Người gửi có thể sửa lệnh và thử lại.

## 5. Thông tin được phép thấy

- Người chơi thấy vị trí tàu của mình và các ô đối thủ đã bắn vào bàn mình.
- Trên bàn đối thủ, người chơi chỉ thấy các tọa độ mình đã bắn cùng kết quả trượt/trúng/chìm. Các ô tàu chưa bị bắn vẫn bí mật.
- Khi một tàu chìm, có thể thông báo tên tàu đã chìm; không tiết lộ vị trí các tàu còn lại.
- Server không gửi nguyên `GameState` hoặc toàn bộ đội tàu đối phương cho client.

## 6. Kết thúc bất thường và phạm vi

Nếu một client ngắt kết nối trong lúc chờ hoặc đang chơi, server kết thúc trận do người đó bỏ cuộc và thông báo cho người còn lại. Phiên bản đầu không có kết nối lại, chơi với máy, nhiều phòng hoặc lưu trận. Kết thúc hòa không xảy ra theo các luật trên.

## 7. Ca kiểm thử nghiệm thu

1. Đặt tàu sát mép hợp lệ; đặt vượt biên/chồng tàu/sai độ dài bị từ chối.
2. Chỉ đội tàu thứ nhất sẵn sàng thì trận vẫn ở giai đoạn chờ.
3. P1 bắn trúng hai lần liên tiếp vẫn giữ lượt; phát thứ ba bắn hụt thì P2 nhận lượt.
4. Bắn chìm một tàu nhưng chưa thắng vẫn được bắn tiếp.
5. Bắn trúng ô tàu cuối cùng của đối phương kết thúc trận ngay.
6. Bắn sai lượt, bắn lặp hoặc nhập sai tọa độ không đổi trạng thái/lượt.
7. Hai lệnh tới gần như đồng thời không cùng dùng một lượt cũ.
8. Phản hồi cho P1 không chứa tọa độ tàu P2 chưa bị bắn.
