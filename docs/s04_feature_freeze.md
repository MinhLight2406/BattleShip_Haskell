# S-04 — Khóa tính năng và chốt mã

Ngày: 2026-10-05. Nhánh: `Luong_nhap_gui_dat_tau`. Chủ trì: R.

## 1. Bản mã và hiệu lực

Commit đầu tiên thêm tài liệu này là **commit chốt tính năng S-04**. Lấy SHA đầy đủ và nội dung commit bằng lệnh sau tại repository:

```sh
git log --diff-filter=A --format="%H %s" -- docs/s04_feature_freeze.md
```

HEAD nền trước commit chốt là `4eea8b544a4da77995d451a137dd98b8f0a574c3`; HEAD nền chưa chứa các thay đổi nghiệm thu S-02 đến D-06. Snapshot D-06 `68418d6d00368ce5f182f4a1e11289ffcdf03311` là bản tái hiện log riêng, không phải commit chốt trên nhánh này. Cần dùng SHA commit chốt khi review/chọn bản báo cáo.

**Trạng thái:** chốt kỹ thuật, build/test xanh; kết quả chạy lại ghi ở mục 3. Việc cả nhóm thống nhất bản báo cáo còn chờ xác nhận thật ở mục 5, nên chưa tuyên bố S-04 đạt toàn bộ tiêu chí xong.

Từ commit chốt, chỉ nhận **sửa lỗi, bổ sung/sửa test và tài liệu**. Không thêm GUI, AI, nhiều phòng hoặc lưu trận ở Đợt 9. Thay đổi contract chung vẫn cần A/B/C/D đồng ý theo [shared_contract.md](shared_contract.md); test xanh không thay chữ ký nhóm. Mọi sửa lỗi sau chốt phải có nguyên nhân, regression test phù hợp và chạy lại kiểm tra bắt buộc; R ghi SHA mới nếu đề nghị nhóm dùng revision khác để báo cáo.

## 2. Phạm vi đã nghiệm thu

- Hai client terminal trên localhost, gán P1/P2 theo kết nối, từ chối người thứ ba; một server phục vụ một trận.
- Đặt đúng năm tàu 5/4/3/3/2 qua constructor kiểm tra; sửa input/xem trước trước khi xác nhận, không chồng/vượt biên hoặc đặt lại.
- Lõi thuần `step`: chờ, bắt đầu, lượt, Miss/Hit/Sunk/Win, bắn lặp/sai lượt/sai tọa độ, bỏ cuộc; lệnh sai không đổi trạng thái hoặc mất lượt.
- `PlayerView`/sự kiện riêng tư, không truyền `GameState` thô và không lộ ô tàu đối thủ chưa bắn, kể cả sau kết thúc.
- Một `TVar GameState`, ghi trạng thái và xếp thông báo trong cùng STM; hai kênh/writer riêng, không IO mạng trong giao dịch.
- Client nhập lệnh dễ nhớ, hiển thị hai bàn và lượt/kết quả; ngắt kết nối kết thúc đối thủ/server, thu hồi socket/worker.

| Phụ thuộc | Kết quả kỹ thuật | Bằng chứng |
|---|---|---|
| A-05 | Không có lỗi đặt tàu mở từ S-03; một regression I10 H hợp lệ/J10 cuối và I10 V vượt mép | `BoardSpec`, mục A-05 trong [test_evidence.md](test_evidence.md) |
| B-05 | Event/PlayerView nhất quán qua ván; hai layout bí mật cho kết quả quan sát giống nhau | `ViewSpec`, mục B-05 trong test_evidence |
| C-06 | Race STM/TCP lặp lại, chỉ một lệnh Hit từ người đến lượt hợp lệ; EOF/đóng socket khi chờ và chơi không treo | `CoordinatorSpec`, mục C-06 trong test_evidence |
| D-06 | Checkout sạch build/test; ba executable thật, lệnh lỗi, P2 thắng và ngắt kết nối | `IntegrationSpec`, [kịch bản](d06_demo.md), [log/bundle](demo/d06/README.md) |

Các xác nhận con người S-01/S-02/S-03 còn thiếu vẫn là mục đang chờ; S-04 không ký thay hoặc tự đóng các mốc đó.

## 3. Kiểm tra bản chốt

Windows, Stack 3.11.1, LTS 24.59 / GHC 9.10.3. Chạy tại gốc repository:

```sh
stack build --ghc-options=-Werror
stack test --ghc-options=-Werror
```

Kết quả thực tế: **build exit 0; test 815 examples, 0 failures, 74.5740 giây, exit 0**. Build biên dịch lại 9 module thư viện và hai Main. Log được lưu tại [build.log](demo/s04/build.log), [test.log](demo/s04/test.log), thông tin lệnh/thời điểm/exit code trong [commands.json](demo/s04/commands.json). Không thêm dependency hoặc thay mã luật để thực hiện mốc khóa.

Đối chiếu 27 file code/config/contract đang tracked với checkout D-06: nội dung giống nhau khi chuẩn hóa CRLF/LF của Git; [danh sách đối chiếu](demo/s04/d06-source-comparison.json). Không sửa lại log/hash D-06 để gán demo lịch sử cho commit mới. Demo D-06 đã hoàn tất 25 phát, 5 đổi lượt, P2 thắng, ba process exit 0; validator soát 54 snapshot bàn / 10.800 ô và giữ giấu 14 ô tàu P2 chưa bị P1 bắn. Full-suite S-04 chạy lại cả bốn test D-06 với executable thật, cùng các test lõi/riêng tư/STM/TCP bắt buộc.

Chưa kiểm tra runtime Linux/macOS. Build sạch D-06 dùng cache compiler/dependency của Stack, không phải cài toolchain từ máy trống. Đây là giới hạn bằng chứng, không phải lỗi gameplay đã phát hiện.

## 4. Lỗi còn lại

| Mã | Mức độ | Ảnh hưởng | Chủ xử lý / trạng thái |
|---|---|---|---|
| R9-S03-01 | P3, trình bày | Thông báo kết thúc 81 ký tự bị wrap/repaint ở terminal 80 cột; log có đuôi `c.` riêng. Winner/GAME_OVER và exit vẫn đúng; không chặn hoàn thành ván | D sửa, C chạy lại; TODO |

Chi tiết tái hiện và tiêu chí sửa: [round9_fixes.md](round9_fixes.md). D-06 tái hiện cùng lỗi ở P2 thắng, không phải lỗi mới. Không có lỗi luật/đặt tàu/riêng tư/kết nối đang mở được ghi nhận trong các lượt nghiệm thu trên. Nếu nhóm phát hiện lỗi mới, bổ sung bằng chứng và regression, không mở rộng tính năng.

## 5. Xác nhận cùng revision để báo cáo

R ghi tên/GitHub, SHA đã duyệt, ngày và lời xác nhận/link review thật. Các thành viên cần xem phạm vi khóa, lỗi còn lại, build/test và demo tại **cùng SHA commit chốt**. Không lấy tên tác giả Git, output test hoặc lời xác nhận cho SHA cũ làm chữ ký cho bản này.

| Vai trò | Người/GitHub | SHA đã duyệt | Ngày / bằng chứng | Trạng thái |
|---|---|---|---|---|
| A | — | — | — | CHỜ XÁC NHẬN |
| B | — | — | — | CHỜ XÁC NHẬN |
| C | — | — | — | CHỜ XÁC NHẬN |
| D | — | — | — | CHỜ XÁC NHẬN |
| R | — | — | — | CHỜ XÁC NHẬN |

Mẫu: `<vai trò> — <tên/GitHub>: xác nhận S-04 tại <SHA>; đã xem build/test, demo và R9-S03-01; đồng ý dùng revision này cho báo cáo và chỉ sửa lỗi/test/tài liệu sau mốc khóa.`

Chỉ chuyển sang **S-04 HOÀN THÀNH / NHÓM ĐÃ THỐNG NHẤT** khi build/test xanh và có đủ xác nhận thật. R có thể tổng hợp bằng chứng các mốc trước nếu lời xác nhận nói rõ nội dung/SHA được duyệt; không suy diễn xác nhận chỉ từ việc chạy được ván.
