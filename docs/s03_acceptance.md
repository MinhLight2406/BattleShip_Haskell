# S-03 — Nghiệm thu trận đầu cuối hai terminal

**Kỹ thuật: ĐẠT với một vấn đề trình bày P3 đã ghi Đợt 9. Xác nhận nhóm: CHỜ A/B/C/D và R.**

Ngày chạy 2026-10-05, Windows/PowerShell, Stack 3.11.1, snapshot lts-24.59, GHC 9.10.3. Codex thực hiện thao tác và lưu hồ sơ theo yêu cầu; kết quả tự động không thay xác nhận của người phụ trách.

## 1. Bản được chạy và build sạch

Nhánh `Luong_nhap_gui_dat_tau`, HEAD nền `4eea8b544a4da77995d451a137dd98b8f0a574c3`. Các thay đổi S-02 đến D-05 trong working tree chưa commit; không tuyên bố HEAD nền riêng lẻ có các kết quả này. [source_sha256.csv](demo/s03/source_sha256.csv) xác định 27 file nguồn/cấu hình/hợp đồng được chạy. Script kiểm chứng đã xác nhận hash không đổi sau demo.

| Lệnh thực tế | Kết quả và bằng chứng |
|---|---|
| `stack clean` | Exit 0; clean chỉ artifact package cục bộ, không xóa dependency/cache hoặc source. [clean.log](demo/s03/clean.log) rỗng vì lệnh không in output; trạng thái tại [commands.json](demo/s03/commands.json) |
| `stack build --ghc-options=-Werror` | Exit 0; biên dịch lại cả 9 module library và hai Main. [build.log](demo/s03/build.log) |
| `stack test --ghc-options=-Werror` | **794 examples, 0 failures**, 56.6764 giây Hspec. [test.log](demo/s03/test.log) |

Không mở executable trong khi Stack đang copy/build để tránh khóa file Windows. Sau khi cả build/test xong mới mở ba phiên PTY thật: server và hai client. ServerMain gọi `runServer`, production `runServer = runServerWith Rules.step initialGameState`; không chọn Step/fixture/stub và không dựng state thắng giả. Unit test khác trong suite có test double kiểm tra ranh giới; chúng không tham gia phiên demo này.

## 2. Log demo đã lưu

Port thực tế **58267**, do server nhận port 0 từ CLI. Các executable được chạy từ `.stack-work/install/f817aa4e/bin/` sau build sạch.

| Phiên | Log | Kết quả |
|---|---|---|
| Server | [server.log](demo/s03/server.log) | Listen localhost; exit 0 |
| Client P1 `[PORT]` | [player1.log](demo/s03/player1.log) | Đặt tàu, chờ, sửa lỗi, bắn, thắng; exit 0 |
| Client P2 `--play [PORT]` | [player2.log](demo/s03/player2.log) | Đặt tàu, bắn, chờ, thua; exit 0 |

[raw_console.json](demo/s03/raw_console.json) giữ nguyên từng chunk output PTY, timestamp UTC, input gửi, session id và exit code. Các `.log` chỉ nối output theo từng phiên, bỏ mã ANSI và chuẩn hóa xuống dòng; không viết lại transcript thành kết quả kỳ vọng. Đây là log console, không phải log byte TCP hoặc ảnh chụp màn hình. [scenario.json](demo/s03/scenario.json) là kịch bản/input và oracle dự kiến, được phân biệt với log đã thu.

## 3. Đội tàu mới và chuỗi chơi

Hai bên đặt ngang/dọc khác fixture S-02/D-05. Chỉ nhập vị trí đầu và H/V, chọn GUI; không gõ lệnh PLACE/FIRE hay tự khai P1/P2.

| Tàu | P1 | P2 |
|---|---|---|
| CV, 5 | J1 V → J1..J5 | E10 H → E10..I10 |
| BB, 4 | I7 V → I7..I10 | A7 V → A7..A10 |
| CR, 3 | A1 H → A1..C1 | B1 V → B1..B3 |
| SB, 3 | A3 V → A3..A5 | D4 H → D4..F4 |
| DD, 2 | H6 H → H6/I6 | I1 V → I1/I2 |

P1 thử J10 H cho Carrier, bị báo vượt biên và hỏi lại, rồi sửa J1 V. P1 gửi trước và nhận chờ; sau GUI của P2, cả hai nhận START/TURN P1. Bảng mục tiêu lúc chưa bắn có 100 dấu ?.

| Đoạn | Input và kết quả thật | Lượt sau đoạn |
|---:|---|---|
| 1 | P1 K1: lỗi địa phương, không phát bắn; J10 Miss | P2 |
| 2 | P2 J10 Miss | P1 |
| 3 | P1 B1 Hit, giữ lượt; B1 lặp: lỗi địa phương, không phát bắn; J9 Miss | P2 |
| 4 | P2 J1 Hit, giữ lượt; H10 Miss | P1 |
| 5 | P1 I1 Hit, giữ lượt; J8 Miss | P2 |
| 6 | P2 A1 Hit, giữ lượt; H9 Miss | P1 |
| 7 | P1 E10/F10/G10/H10 Hit, I10 Sunk CV; A7/A8/A9 Hit, A10 Sunk BB; B2 Hit, B3 Sunk CR; D4/E4 Hit, F4 Sunk SB; I2 Win | Finished P1 AllShipsSunk |

Luân phiên bằng Miss theo R-01; không đổi luật để ép chuyển lượt sau Hit/Sunk. Sáu lần chuyển lượt, 25 phát bắn hợp lệ. P1: 20 phát = 3 Miss + 12 Hit + 4 Sunk + 1 Win; P2: 5 phát = 3 Miss + 2 Hit. Hai lỗi bắn cố ý không thêm lịch sử hoặc tiêu lượt; không coi chúng là lỗi cần sửa. Sau Win không hỏi phát mới; hai client và server tự thoát.

## 4. Đối chiếu luật và bí mật

Chạy lại được từ gốc repo:

```powershell
& docs/demo/s03/verify_demo.ps1
```

[verification.json](demo/s03/verification.json) là output thật: Passed true, 27 source hash khớp, 25 kết quả bắn, 6 chuyển lượt, winner P1, **54 lần in hai bàn**, **10.800 ô** được đối chiếu.

Script dùng danh sách tọa độ và kết quả dự kiến ghi tường minh cho đội tàu mới, không gọi/copy luật trúng/chìm/thắng. Đối chiếu thứ tự SHOT/INCOMING hiển thị ở hai client; mỗi dòng bàn phải có đủ 10 ô, mọi ô bàn mình bằng fleet mình cộng các phát đã nhận, mọi ô mục tiêu bằng kết quả đã được nhận trước đó hoặc ?. Không chỉ đếm số dấu ? ở bàn cuối. Đây là kiểm chứng log/routing/render; bất biến toàn GameState và tính thuần có kiểm thử S-02/B-04/C-04 riêng trong suite.

Bàn cuối P1 có 80 ô đối thủ chưa bắn (toàn nước); P2 có 95 ô chưa bắn, gồm **15 ô tàu P1 chưa lộ** vẫn ?. P2 chỉ được thấy hai ô đã bắn trúng A1/J1 và ba Miss J10/H10/H9. SUNK không làm lộ ô chưa bắn hoặc hình tàu còn lại. Bản oracle/hồ sơ của R có cả hai đội tàu để review; điều cần giữ bí mật là dữ liệu mỗi client nhận/hiển thị, không phải dữ liệu kiểm chứng của người nghiệm thu.

## 5. Lỗi ghi Đợt 9

[R9-S03-01](round9_fixes.md): thông báo thắng P1 dài 81 ký tự trên console 80 cột, wrap/repaint làm phần đuôi `c.` tách trong log văn bản. Ưu tiên P3, D xử lý/C kiểm tra lại; không chặn kết thúc hoặc sai winner. Đã lưu đoạn console thô làm bằng chứng. S-03 ghi task theo yêu cầu, chưa sửa phần trình bày này.

Không phát hiện lỗi gameplay, lộ tàu hoặc ngắt kết nối chặn ván ở lượt chạy này. Kết quả một ván không phải khẳng định không còn lỗi trong mọi tình huống; runtime được chạy trên Windows.

## 6. Xác nhận từng người — chưa được cung cấp

| Vai trò | Phần cần quan sát/xác nhận | Trạng thái |
|---|---|---|
| A | Hai fleet đủ 17 ô, mép/hướng/chạm hợp lệ, đặt sai sửa được và không đặt lại | CHỜ XÁC NHẬN |
| B | Miss đổi lượt, Hit/Sunk giữ lượt, hai lỗi không tiêu lượt, Win đúng và góc nhìn giữ bí mật | CHỜ XÁC NHẬN |
| C | Cùng server/lõi thật, sự kiện đúng kênh, trận kết thúc/dọn worker/socket/listener | CHỜ XÁC NHẬN |
| D | Hai terminal nhập thân thiện, hai bàn/ký hiệu/lượt/lỗi/kết quả đúng, tiếp nhận task trình bày P3 | CHỜ XÁC NHẬN |
| R | Duyệt bộ log/hash, tổng kết và phân công Đợt 9 | CHỜ XÁC NHẬN |

Mẫu: `<vai trò> — <tên/GitHub>, <ngày>: đã xem hồ sơ S-03 và bộ source SHA-256 kèm theo; xác nhận <phần phụ trách>; nhận xét/lỗi: <nội dung>.` Khi chốt trên commit cần ghi SHA thực sự chứa bộ mã đã duyệt; SHA nền riêng lẻ không đủ. Chỉ ghi xác nhận được chính thành viên cung cấp, không suy ra từ test xanh hoặc tác giả commit.

S-02 còn chờ A/B trong `report_final.md`; S-01 còn chờ các chữ ký hợp đồng chung. **S-03 chưa đạt toàn bộ tiêu chí xong vì thiếu xác nhận người phụ trách**, dù build sạch, ván production và hồ sơ kỹ thuật đã hoàn tất.
