# Bằng chứng D-06

Ngày 2026-10-05, Windows, Stack 3.11.1, LTS 24.59/GHC 9.10.3. **Build từ checkout sạch thành công, 815 test xanh, một trận mới P2 thắng qua hai console thật, cả ba process exit 0.** Hướng dẫn: [d06_demo.md](../../d06_demo.md). Báo cáo chi tiết: [test_evidence.md](../../test_evidence.md#d-06--2026-10-05).

## Tái hiện

Từ repository có bundle, chọn đích clone mới chưa tồn tại:

```powershell
git clone docs/demo/d06/source.bundle .stack-work/d06-replay
Set-Location .stack-work/d06-replay
git status --porcelain
stack build
stack test
stack test --ghc-options=-Werror --test-arguments="--match D-06"
```

Status trước build phải rỗng. Snapshot commit **68418d6d00368ce5f182f4a1e11289ffcdf03311** chứa 57 file source/config/hướng dẫn hiện tại trước khi thêm báo cáo/log cuối D-06. Repository gốc còn thay đổi chưa commit, nên clone HEAD gốc cũ sẽ không có D-06. Commit snapshot chỉ nằm trong repository tạm/bundle; không thay lịch sử repository gốc. Có thể dùng compiler/dependency cache Stack, nhưng clone không chứa binary hoặc .stack-work đã build.

Mở ba terminal tại checkout vừa tạo và chạy lệnh server/client trong README để thử tự chọn fleet và input khác. Tests D-06 gửi từng dòng theo prompt/phản hồi, không nạp trước toàn kịch bản; trận PTY đã chạy dùng fleet khác test và sửa input tại console, không input file/pipe.

## Artifact thật

- `source.bundle`, `checkout.json`, `source_sha256.csv`: source snapshot, path đã chạy, SHA snapshot/bundle và hash 57 file checkout.
- `status-before.log`, `status-after.log`: status rỗng trước build và sau demo. `NoBuildArtifacts: true` trong checkout.json được kiểm tra trước build.
- `build.log`, `test.log`, `targeted.log`, `commands.json`: output/lệnh/exit thực tế. Build/test dùng đúng `stack build`/`stack test`; lọc D-06 với -Werror cũng được chạy tại checkout đó.
- `raw_console.json`: output tool nguyên gốc của server/P1/P2, input, timestamp UTC, session và exit code. Ngày UTC 2026-10-04 tương ứng 2026-10-05 tại UTC+7.
- `server.log`, `player1.log`, `player2.log`: các output thật nối theo từng process, chỉ bỏ ANSI và chuẩn hóa newline; không viết lại thành transcript kỳ vọng.
- `verify_demo.ps1`, `verification.json`: validator đọc log cùng oracle literal riêng, không gọi Board/Rules; output Passed true, 25 phát/5 đổi lượt/P2 thắng, 54 bảng và 10.800 ô đã kiểm tra. P1 không thấy 14 ô tàu P2 chưa bắn cả sau kết thúc.

Ở repository gốc, đối chiếu demo với checkout đã chạy còn giữ trong .stack-work:

```powershell
& docs/demo/d06/verify_demo.ps1
# Hoặc chỉ định checkout snapshot có sẵn:
& docs/demo/d06/verify_demo.ps1 -Checkout .stack-work/d06-replay
```

Validator kiểm tra hash theo bytes của checkout Windows đã ghi nhận; cấu hình chuyển LF/CRLF khác có thể khác hash dù cùng commit. Muốn đối chiếu bằng bytes như lượt này, clone với `git -c core.autocrlf=true clone docs/demo/d06/source.bundle .stack-work/d06-replay` (thư mục đích chưa tồn tại). Build/test không yêu cầu chế độ newline này. Nếu source sửa sau demo, giữ báo lỗi hash; không ghi hash mới để biến bằng chứng cũ thành bằng chứng cho mã mới.

Không có ảnh chụp màn hình; log console thô được giữ. R9-S03-01 vẫn là lỗi trình bày đã ghi: dòng thắng dài wrap trên console 80 cột. Không dùng kết quả tự động để thay xác nhận nhóm còn chờ ở S-03.
