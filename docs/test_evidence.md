# Minh chứng kiểm thử

## C-01 và A-01 — 2026-10-04

Môi trường: Windows, Stack 3.11.1, snapshot LTS 24.59, GHC 9.10.3.

```text
stack build
  Thành công: library, battleship-server, battleship-client.

stack test
  39 examples, 0 failures
  Test suite battleship-test passed

stack test --ghc-options=-Werror
  39 examples, 0 failures
  Test suite battleship-test passed
```

| Nhóm | Số test | Nội dung |
|---|---:|---|
| Hằng số R-01 | 8 | Bàn 10×10, năm ID/độ dài tàu, tổng 17 ô |
| PlayerId | 4 | Hai danh tính, chọn đối thủ, tính chất đổi hai lần |
| Khởi tạo | 3 | Placing, hai fleet vắng mặt tường minh, chưa có phát bắn |
| PlayerState độc lập | 19 | Chọn đúng người, một người sẵn sàng, cập nhật giữ đối thủ/phase/giá trị cũ, hai cập nhật độc lập giao hoán |
| Hợp đồng kiểu | 3 | Chữ ký Step/PlaceFleetFn/ViewFor bằng typeRep; không gọi hàm nghiệp vụ chưa triển khai |
| Smoke C-01 | 2 | Khởi chạy cả hai executable, kiểm tra exit code/stdout/stderr |

Các fixture với phase kết thúc chỉ kiểm tra helper cập nhật record, không chứng minh điều kiện thắng hoặc chuyển lượt. Kiểm tra đặt tàu hợp lệ, Hit/Sunk giữ lượt, Miss đổi lượt, thắng/bỏ cuộc, rollback lệnh lỗi và bí mật của `viewFor` cần cài đặt A-02/B/C/D trước khi ghi kết quả nghiệm thu.

A-01 còn chờ B/C/D review hợp đồng trong `Types.hs`, `architecture.md` và ánh xạ sự kiện trong `protocol.md`.

## D-01 — 2026-10-04

Cùng môi trường Windows, Stack 3.11.1, LTS 24.59, GHC 9.10.3. Nhánh thực hiện: `Minh-Giao_thuc_lenh_va_event`, tách từ `Minh-Dinh_nghia_kieu_ham` tại commit `96c1e48401fe22403f5a1c9c55489f4aba8780fb`.

```text
stack build
  Thành công: library, battleship-server, battleship-client.

stack test
  152 examples, 0 failures
  Test suite battleship-test passed

stack test --ghc-options=-Werror --test-arguments="--match D-01"
  113 examples, 0 failures
  Test suite battleship-test passed
```

| Nhóm D-01 | Số test | Nội dung |
|---|---:|---|
| Tọa độ | 11 | Toàn bộ 100 tọa độ hợp lệ trong một test; 10 dạng sai |
| Lệnh | 33 | PLACE/FIRE/QUIT, thứ tự tàu, giữ duplicate, cú pháp lỗi, phân loại lỗi tọa độ |
| Phản hồi/lỗi/định tuyến | 43 | 23 dạng phản hồi sai, 12 GameError A-01, 8 tổ hợp người bắn/kết quả |
| Framing byte | 15 | Chunk tách/gộp, từng vị trí cắt stream, LF/CRLF, 256/257 byte, UTF-8, control byte, dòng lỗi rồi dòng hợp lệ |
| Fixture tài liệu | 11 | Ví dụ lệnh/phản hồi và 8 transcript đọc trực tiếp từ protocol.md; khóa thứ tự và người nhận |

Đã bổ sung `bytestring` ở test component, đóng gói `docs/protocol.md` bằng `data-files` và khai báo module Cabal tự sinh `Paths_battleship_haskell`. Lượt chạy nghiêm ngặt ban đầu phát hiện thiếu module này trong cấu hình; sau sửa đã biên dịch và chạy thành công.

Các hàm tham chiếu trong `ProtocolSpec` chỉ kiểm tra hợp đồng D-01. Transcript là fixture đã chốt, không phải log một trận TCP thật. Chưa có parser/encoder production, Rules, server TCP hoặc client tương tác; kiểm tra tích hợp socket và chuyển trạng thái thực tế thuộc các task triển khai tiếp theo. R-01 và kiểu A-01 không thay đổi.

## S-01 — Đối chiếu kỹ thuật, chờ xác nhận — 2026-10-04

Nhánh `Minh-Connect_Type_and_Main`, tách từ `Minh-Giao_thuc_lenh_va_event` tại `62ef6018a9d6167bda9909b04fce4a3c370ed936`. Môi trường Windows, Stack 3.11.1, LTS 24.59, GHC 9.10.3.

```text
stack build
  Thành công: library, battleship-server, battleship-client.

stack test
  161 examples, 0 failures

stack test --ghc-options=-Werror
  161 examples, 0 failures

stack test --ghc-options=-Werror --test-arguments="--match S-01"
  9 examples, 0 failures
```

| Kiểm tra S-01 mới | Số test | Kết quả |
|---|---:|---|
| Nhận diện khai báo | 4 | data/newtype/alias nhiều dòng và family; bỏ comment lồng/literal; không nhầm tên dài, chữ ký hay tham chiếu |
| API so với bản hợp đồng | 1 | Constructor, trường, kiểu trường, deriving và ba alias khớp bản chụp |
| Coord/Command duy nhất | 2 | Quét 19 file Haskell trong src/app/test; mỗi kiểu chỉ khai báo một lần tại src/Battleship/Types.hs |
| Chủ sở hữu | 1 | 19 file Haskell và hai YAML đều có đúng một vai trò phụ trách trong bản hợp đồng |
| Hai Main | 1 | Hai file Main riêng, xuất main và có chữ ký main :: IO (); hai smoke test C-01 vẫn xanh |

SharedContractSpec dùng `directory`/`filepath` ở test component để đọc cây nguồn. Checker xét token và các dạng khai báo nêu trên, không thay thế compiler Haskell; GHC và TypesSpec vẫn kiểm tra kiểu/import. Chạy từ gốc repo để đối chiếu đúng file nguồn.

Trước S-01 không có định nghĩa Coord/Command trùng để phải xóa; còn thiếu bản hợp đồng tập trung, bảng người phụ trách đủ app/test/YAML, kiểm tra tự động API lệch tài liệu và bằng chứng A/B/C/D duyệt. Đã bổ sung các phần kỹ thuật tại [shared_contract.md](shared_contract.md), tái dùng 113 test D-01, 37 test A-01 và hai smoke test C-01.

**Chưa đủ nghiệm thu S-01:** chưa nhận được bốn xác nhận thật trên cùng nội dung. Bảng A/B/C/D đang CHỜ XÁC NHẬN; không ghi ĐÃ KHÓA chỉ vì build/test xanh. Không có thử nghiệm TCP thật hoặc cài đặt nghiệp vụ trong S-01.
