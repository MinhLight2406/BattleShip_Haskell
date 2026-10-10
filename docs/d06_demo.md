# D-06 — Tái hiện build sạch và trận đầu cuối

**Kịch bản terminal lịch sử 2026-10-05.** Dùng để tái hiện snapshot/bundle D-06; hướng dẫn sản phẩm hiện hành ở [README](../README.md) và [demo_script.md](demo_script.md). Không dùng số test/địa chỉ/môi trường cũ để nhận là đã chạy lại bản Docker mới.

## 1. Checkout và kiểm tra tự động

Theo lệnh clone bundle/build/test trong README. Bundle là snapshot độc lập chứa mã chưa commit đang được nghiệm thu, không phải HEAD nền cũ và không phải chữ ký nhóm. Báo cáo kết quả/log ở `demo/d06/`; không dùng log S-03 để chứng minh bản mới.

```sh
git status --porcelain
stack build
stack test
stack test --ghc-options=-Werror --test-arguments="--match D-06"
```

Status trước build phải rỗng. Bốn test D-06 gồm một trận với ba executable thật và P2 thắng, client đầu rời khi còn chờ người thứ hai, P1/P2 đóng giữa trận. Input được gửi sau prompt/phản hồi quan sát được; lỗi nhập được sửa trước khi tiếp tục. Test đồng thời và disconnect khi cả hai đã kết nối nhưng chưa đặt đủ nằm trong C-06/C-05 và được chạy bởi `stack test`.

## 2. Trận mới trên ba terminal

Chạy server `stack exec battleship-server -- 4000`; hai client lần lượt `stack exec battleship-client -- 4000` và `stack exec battleship-client -- --play 4000`. Đợi server báo đang nghe. Đặt và gửi GUI ở client đầu trước khi GUI ở client sau; số P1/P2 được gán lúc kết nối, không theo lúc mở terminal.

Ví dụ đội tàu khác demo S-03, nhập theo thứ tự CV/BB/CR/SB/DD:

| Tàu | P1 | P2 |
|---|---|---|
| CV | C2 V | F1 H |
| BB | F7 H | A6 V |
| CR | J8 V | C10 H |
| SB | A1 H | F4 V |
| DD | H3 V | J9 V |

1. P1 thử CV `J10 V`, đọc lỗi vượt mép và nhập lại `C2 V`; đặt các tàu còn lại, xem preview rồi GUI. P1 phải biết mình là Người chơi 1 và hiện chờ.
2. P2 đặt đội tàu theo bảng, GUI. Cả hai thấy bắt đầu, P1 được nhập bắn; mỗi bảng mục tiêu có 100 dấu ?.
3. P1 nhập `K1`: lỗi tọa độ, vẫn cùng lượt. Bắn `F1`: Hit và được bắn tiếp; bắn `J6`: Miss, P2 được nhập.
4. P2 thử `A01`: lỗi token; bắn `C2`: Hit, thử `C2` lần nữa: lỗi bắn lặp. Bắn `I10`: Miss, P1 được nhập. P1 bắn `I6`: Miss, trở lại P2.
5. P2 bắn C3/C4/C5/C6, F7/G7/H7/I7, J8/J9/J10, A1/B1/C1, H3/H4. Các ô cuối tàu có SUNK, H4 là WIN. Hit/Sunk giữ lượt; không nhập bước kế tiếp trước TURN/prompt. P2 thắng, P1 thua; cả ba process tự thoát.
6. Bảng mục tiêu P1 chỉ biết F1 trúng, J6/I6 trượt: 97 ô còn ? và 16 ô tàu P2 chưa bắn tiếp tục bị giấu cả sau thua. P2 có 18 ô đã bắn, 82 ô còn ?; không có mã tàu trong bảng mục tiêu.

**Chạy thêm với lựa chọn tại chỗ:** tự chọn đội tàu khác từ preview, thử một input sai do mình chọn rồi sửa theo lỗi, dùng một ô nước khác để chuyển lượt. Người quan sát dùng preview của người nhận để xác nhận kết quả bắn; không coi danh sách input ví dụ là kết quả đã xảy ra. Ghi lại input/phản hồi thực tế và vị trí làm chìm/thắng của đội tàu mới. Việc hai người chia sẻ vị trí cho demo chỉ phục vụ kiểm chứng; client vẫn không nhận fleet đối thủ.

## 3. Ngắt kết nối

Mỗi ca khởi động server mới vì một server chỉ phục vụ một trận:

- **Đang chờ người thứ hai:** chỉ client đầu đặt tàu/GUI, đợi chờ đối thủ; Ctrl+C hoặc đóng terminal client. Server phải thoát, không chờ accept mãi. Khi chưa có P2 kết nối, không có đối thủ để nhận thông báo.
- **Giữa trận:** mở đủ hai client, GUI cả hai, bắn ít nhất một ô. Ctrl+C hoặc đóng terminal một client, gồm lúc client còn đang chờ lượt hoặc đang nhập dở một tọa độ. Client còn lại phải báo thắng do đối thủ rời trận và tự thoát; server cũng thoát. Không dùng Ctrl+C tại server để giả lập ngắt client.
- **Cùng cổng:** khởi động lại server trên port vừa dùng; phải nghe được. C-05 cũng kiểm tra điều này tự động.

PowerShell: xem `$LASTEXITCODE` ngay sau mỗi lệnh kết thúc. Trận thắng bình thường và process còn lại sau đối thủ rời phải exit 0; process bị Ctrl+C/đóng cưỡng bức có thể exit khác 0. Thông báo kết thúc dài trên console 80 cột vẫn có task trình bày R9-S03-01; không nhầm wrap với mất kết quả. Nếu phát hiện lỗi mới, giữ log thực tế, input, port và snapshot SHA để tái hiện.
