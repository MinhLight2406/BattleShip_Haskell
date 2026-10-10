# Bàn giao Docker — DK-09

Ngày: **2026-10-10 (Asia/Saigon)**. Nhánh làm việc: `Test_2_container_va_LAN`, nền DK-07 `17928c0`. Bằng chứng DK-08/DK-09 được chạy trên working tree trước commit; tra SHA commit bàn giao bằng `git log -1 --format=%H` trên nhánh này. Phụ trách tài liệu: R; không ghi chữ ký thay nhóm.

**Trạng thái kỹ thuật: ĐẠT** — hướng dẫn/hợp đồng đã cập nhật và lệnh bàn giao chạy thành công. Nghiệm thu DK-08 đã đạt phạm vi một máy/hai trình duyệt theo yêu cầu người dùng. **Chưa chốt nghiệm thu nhóm**: review A/B/C/D/R còn chờ.

## 1. Tài liệu dùng để làm lại

- [README — hướng dẫn chuẩn DK-09](../README.md#chạy-bằng-docker--hướng-dẫn-chuẩn-dk-09): build, start localhost/LAN, chọn adapter, thay cổng, hai người chơi, xem log, mở trận mới, stop/down và xử lý lỗi.
- [Hợp đồng chung](shared_contract.md#7-hợp-đồng-docker-và-bàn-giao-dk-09): thay đổi API/cấu hình, chủ sở hữu và bảng review trước hợp nhất.
- [Hợp đồng Docker](docker_deployment.md): nguồn chuẩn biến môi trường, Origin/Host, schema LAN, health/readiness và vòng đời.
- [Dockerfile và test chuyên biệt](../docker/README.md): stage build/test/runtime, image nền ghim digest và non-root.
- [Nghiệm thu DK-08](dk08_acceptance.md): suite nền 19 ca, trận Chrome/Edge, log/ảnh và phạm vi chưa kiểm chứng.

Các lệnh hướng dẫn chạy từ root. `.env.example` được dùng làm đầu vào; helper tạo `.docker-runtime/lan/compose.env`. Sau start, mọi lệnh vận hành phải dùng **env-file hiệu lực và đúng project**. Đổi ConfigDir/ProjectName thì thay cả đường dẫn/project ở lệnh logs/ps/start/stop/down. Không dùng env-file mẫu để down project có cổng/origin động khác.

## 2. Môi trường và kết quả đã có

| Thành phần | Phiên bản/môi trường thực tế |
|---|---|
| Host | Windows x64, 25H2, build **26200.9457**; đọc registry build/display version, không suy từ IP container |
| Docker Desktop | **4.94.0.241994**, đọc ProductVersion/FileVersion của executable host ở DK-09 |
| Engine / Compose | **29.8.2 / 5.5.1**, Linux containers, x86_64 |
| Image Haskell | Debian Bookworm, GHC **9.10.3**, snapshot **lts-24.59** |
| Image web | Node **24.21.0**, pnpm **11.25.0**, lockfile frozen, non-root UID 1000 |
| Haskell runtime | Non-root UID 10001; chỉ executable và dependency hệ thống |
| Trình duyệt DK-08 | Chrome **155.0.8059.39**, Edge **155.0.4283.45**; hai tiến trình/profile riêng trên cùng host |

Kết quả đã chạy trước DK-09, không coi là lần chạy mới của DK-09:

| Gate | Kết quả | Bằng chứng |
|---|---|---|
| Linux source sạch DK-08 | stack build qua; stack test -Werror **908 ví dụ, 0 lỗi**; frontend **36/36**, TypeScript/Vite qua | `.stack-work/dk08/clean-build.log` (cục bộ) |
| Compose suite nền | **19/19**, 0 skip; readiness, giới hạn/đồng thời, riêng tư, resume/hết hạn, restart/new match, cleanup | [automated-results.txt](demo/dk08/automated-results.txt) |
| Hai trình duyệt theo yêu cầu thay thế | **1/1**, 0 skip; qua IP LAN host, reload sau A6 giữ trận, thắng/thua | [two-browsers-results.txt](demo/dk08/two-browsers-results.txt), ảnh ở hồ sơ DK-08 |

## 3. Gate bàn giao DK-09

| Kiểm tra | Kết quả |
|---|---|
| Docker/Compose và hệ điều hành thực tế | Engine 29.8.2, Compose 5.5.1, Linux x86_64; host Windows 25H2 build 26200.9457 |
| Config/build theo README | `config --quiet` exit 0; hai image runtime build lại từ source/tài liệu hiện tại; **908 ví dụ Haskell/0 lỗi** với -Werror, frontend **36/36**, TypeScript/Vite qua |
| Localhost và cổng public khác internal | Helper Localhost, HTTP 200, cả hai service healthy, public **8082 → internal 8080** |
| Hai client chơi đủ trận, mở trận mới | Hai WebSocket thật P1/P2, 17 ô trúng/chìm/WIN, core exit 0; `start haskell` tạo slot/token mới mà web giữ nguyên StartedAt; Quit đúng người |
| Helper Auto, chọn Wi-Fi và env-file hiệu lực | IP host hiện tại **192.168.1.126:8082**, file có origin/heartbeat, HTTP và P1/P2 qua LAN của cùng máy; Quit P2 → P1 thắng |
| Logs, stop/down và cleanup | Logs không chứa token/fleet; stop exit 0 dưới 10s; down dưới 10s, không còn container/network/worker helper của project test |
| Haskell S-01 kiểm tra nguồn/hợp đồng | `stack test --ghc-options=-Werror --test-arguments="--match S-01"`: **10 ví dụ, 0 lỗi** trên Windows |
| Frontend/bridge/Docker artifact test | `pnpm --dir frontend test`: **36/36, 0 skip**; gồm 6 ca đối chiếu .env.example với hợp đồng Docker |
| Whitespace/link/file được tài liệu tham chiếu | `git diff --check` qua; **64 link file tương đối** trong README/hợp đồng/hồ sơ Docker trỏ tới file tồn tại |

Đối chiếu lệnh runtime ngày 2026-10-10 khoảng **20:20 (Asia/Saigon)** dùng project/thư mục cấu hình riêng cho test, cùng helper và Compose production; không dừng project demo của người dùng. **8 kiểm tra vận hành qua**, không skip. Log cục bộ dưới `.stack-work/dk09/`: `build.log`, `frontend-test.log`, `shared-contract-test.log`, `runtime-handover.log`. Minh chứng lưu cùng Git: [kết quả tổng hợp](demo/dk09/results.txt) và [log vận hành](demo/dk09/runtime-handover.txt); không chứa token hoặc payload đội tàu.

DK-09 không chạy lại suite Compose 19 ca; đã chạy lại build/test toàn bộ Haskell/frontend trên Linux và kiểm tra luồng hướng dẫn 8 bước với helper/Compose thật. Trận UI Chrome/Edge giữ bằng chứng DK-08; hai client của kiểm tra vận hành DK-09 là WebSocket tự động trên cùng host, không phải xác nhận thêm hai thiết bị vật lý. Không có source/API runtime đổi trong DK-09.

## 4. Giới hạn bàn giao

- Một phòng, đúng hai người, một trận/lần chạy Haskell. P3 bị từ chối; muốn trận mới, chờ Haskell Exited rồi start haskell, đợi healthy và tạo phiên mới ở UI.
- Hai service production, chỉ cổng web publish. Healthcheck không kết nối vào TCP chơi hoặc tạo token; web healthy sau trận chỉ chứng minh HTTP phục vụ được.
- Queue 128/126/2 và kết thúc qua Quit giữ nguyên C-07; không lưu lịch sử/đội tàu/token xuống disk.
- Resume 300.000 ms chỉ khi web/core còn chạy. Thay IP bằng helper không restart; đổi cổng hoặc restart mất phiên. Host tắt/ngủ hoặc Docker Engine tắt làm dịch vụ ngừng; Docker không cung cấp máy chủ luôn bật.
- Nghiệm thu một máy/Chrome+Edge đã làm theo yêu cầu mới. **Chưa kiểm chứng** hai thiết bị vật lý, đổi Wi-Fi vật lý giữa trận, arm64, host Linux/macOS chạy helper, hoặc phục hồi sau restart. Không hứa auto-discovery IP tới thiết bị khách hoặc vượt cô lập mạng/router/firewall.

## 5. Review và commit chốt

Bảng xác nhận chính nằm ở [hợp đồng chung mục 7](shared_contract.md#7-hợp-đồng-docker-và-bàn-giao-dk-09). A review image/snapshot, B luật/riêng tư/test, C listener/queue/Compose/helper/cleanup, D bridge/UI/origin/resume, R hướng dẫn và bằng chứng. Mỗi xác nhận cần cùng SHA, tên, ngày và link review; nếu nội dung kỹ thuật đổi thì duyệt lại.

Chưa có xác nhận nhóm. Hướng dẫn/test đã hoàn tất về kỹ thuật; chỉ đánh dấu **chốt nghiệm thu nhóm** sau khi nhận đủ bằng chứng review cùng SHA commit bàn giao. Commit/push lưu mã và minh chứng, không thay xác nhận nhóm hoặc quyết định hợp nhất.
