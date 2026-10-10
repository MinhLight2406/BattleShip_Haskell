# Image Haskell — DK-04

Nhánh `Dong_goi_kiem_thu`, nền `c8f02e5`. Chỉ đóng gói server Haskell; web image và Compose thuộc DK-05/DK-07. Không đổi luật hoặc cơ chế một trận/process.

## Cấu trúc image

| Stage | Nội dung |
|---|---|
| `build` | Haskell official image `9.10.3-bookworm`, kiểm tra GHC đúng 9.10.3, `stack build` dùng `stack.yaml` lts-24.59 và cấm tự cài compiler khác |
| `test` | Kế thừa build, chạy toàn bộ `stack test --ghc-options=-Werror`, gồm A-06/B-06/C-07 và test SIGTERM chỉ có trên Unix; xuất binary server sau khi test thành công |
| `runtime` | Debian Bookworm slim, chỉ nhận binary từ test, cài thư viện hệ thống và kiểm tra `ldd`, chạy UID/GID 10001 |

Runtime mặc định bind `0.0.0.0:4000`, marker `/tmp/battleship-ready`; chạy trực tiếp ngoài container vẫn giữ mặc định DK-02 là `127.0.0.1`. `ENTRYPOINT` gọi server trực tiếp làm PID 1, `CMD` là port 4000, `STOPSIGNAL` là SIGTERM. Marker nằm trong `/tmp` ghi được bởi non-root. Không có source, GHC, Stack hoặc dependency cache trong runtime. Server không cần file giao thức tại runtime; test stage có đầy đủ `src`, `app`, `test`, `README.md` và `docs/*.md`.

`.dockerignore` loại Git, cấu hình cá nhân, `.env` thật, cache Stack/Cabal, artifact Windows, node_modules, frontend dist/test-results, log và bundle demo. Giữ `.env.example`, source, test và tài liệu hợp đồng. Build stage kiểm tra context đã được Docker lọc **trước** khi Stack tạo `.stack-work`/cabal mới; nếu file bị loại cần kiểm thử xuất hiện trong context, build phải thất bại.

### Chọn image nền

- Build: `haskell:9.10.3-bookworm@sha256:17443f2fb34af566b9a8bc4a4cfa131dde1b0ab47c3358c8de2137e9873e0b27`.
- Runtime: `debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587`.

Đã xác nhận tag/digest và manifest Linux amd64/arm64 trực tiếp qua Docker Hub Registry ngày **2026-10-10**. Nguồn [official Haskell image](https://hub.docker.com/_/haskell) và [Dockerfile upstream](https://github.com/haskell/docker-haskell/blob/master/9.10/bookworm/Dockerfile) xác định GHC 9.10.3 trên Debian 12; runtime dùng cùng Bookworm để tránh đổi glibc giữa build và chạy. Digest cố định nội dung image nền; muốn cập nhật image phải đổi digest và chạy lại cả gate. Các package apt vẫn lấy từ repository Bookworm tại lúc build, không cam kết image tái tạo giống nhau từng byte.

Runtime cài `libgmp10`, `libnuma1`, `libffi8`, `libtinfo6`, `zlib1g`; `libc6`/loader thuộc Debian base. Trên image amd64 đã build, `ldd` liệt kê `libm.so.6`, `libgmp.so.10`, `libc.so.6` và loader, không có `not found`; runtime test cũng khởi chạy binary thật. Kết quả này áp dụng cho image nghiệm thu dưới đây.

## Lệnh nghiệm thu

Cần Docker Engine **Linux** đang chạy và Node.js 24 trở lên cho test runner trên host. Từ gốc repository, tốt nhất dùng checkout mới của revision cần nghiệm thu và kiểm tra `git status --porcelain` rỗng trước build. Không mount cache/binary Windows vào container.

```sh
docker info --format '{{.OSType}}'
docker build --platform linux/amd64 --progress=plain -f docker/haskell.Dockerfile --target test -t battleship-haskell-test:dk04 .
docker build --platform linux/amd64 --progress=plain -f docker/haskell.Dockerfile --target runtime -t battleship-haskell:dk04 .
node --test docker/test/haskell-runtime.test.mjs
```

Hai lệnh build dùng chung cache layer Linux của Docker; runtime vẫn phụ thuộc stage test, không thể bỏ test bằng cách chỉ build target runtime. Để kiểm tra dependency/source sạch không dựa vào build cache, thêm `--no-cache` vào lệnh build test. Lần đầu cần tải image/package từ Internet và đủ bộ nhớ cho GHC. Gate ban đầu dùng linux/amd64; chưa nghiệm thu arm64 chỉ vì manifest có kiến trúc đó.

Nếu docker CLI chưa có trong PATH trên Windows:

```powershell
$env:BATTLESHIP_DOCKER_CLI = Join-Path $env:LOCALAPPDATA 'Programs/DockerDesktop/resources/bin/docker.exe'
& $env:BATTLESHIP_DOCKER_CLI info --format '{{.OSType}}'
& $env:BATTLESHIP_DOCKER_CLI build --platform linux/amd64 --progress=plain -f docker/haskell.Dockerfile --target test -t battleship-haskell-test:dk04 .
& $env:BATTLESHIP_DOCKER_CLI build --platform linux/amd64 --progress=plain -f docker/haskell.Dockerfile --target runtime -t battleship-haskell:dk04 .
node --test docker/test/haskell-runtime.test.mjs
```

Đường dẫn trên dành cho bản Docker Desktop per-user; bản all-users dùng `C:/Program Files/Docker/Docker/resources/bin/docker.exe`. Test runner nhận `BATTLESHIP_DOCKER_CLI` và `BATTLESHIP_HASKELL_IMAGE` tùy chọn, mặc định CLI `docker` và tag `battleship-haskell:dk04`. Đây là cấu hình test trên host, không phải biến giao thức/server.

### Bộ test runtime

Năm test thật, không dùng stub Rules/server:

1. Inspect image Linux/User/Entrypoint/Cmd; chạy `id`, `ldd`, `--help` với user mặc định; runtime không có GHC/Stack.
2. Bind host sai phải thoát code 1, có lỗi BATTLESHIP_BIND_HOST và không có log listen.
3. Chạy port mặc định 4000, đọc marker 100 lần không kết nối cổng chơi; P1/P2 nhận WELCOME, P3 bị SERVER_FULL; Quit trả đúng GAME_OVER rồi server thoát 0, marker bị xóa.
4. Lặp luồng trên với CLI port 4500 và marker khác, chứng minh runtime nhận cấu hình thật.
5. SIGTERM tới PID 1 khi đã có hai client: EOF cả hai, exit 0 và marker bị xóa trong deadline.

Các container test dùng tên UUID, publish cổng do OS cấp **chỉ ở loopback**, được xóa riêng sau test. Không prune Docker hoặc đụng deployment đang demo. Chờ readiness bằng Docker health/marker, không connect 4000. Mỗi command có timeout 30 giây; readiness tối đa 20 giây, frame/thoát server tối đa 10 giây. Sau container stop, test dùng `docker cp` kiểm tra marker không tồn tại trong filesystem của container đã dừng. Thiếu Docker/image làm test **thất bại rõ**, không skip và không đánh dấu xanh.

Chạy server để thử bằng terminal TCP (chưa phải deployment web):

```sh
docker run --rm --name battleship-haskell-demo -p 127.0.0.1:4000:4000 battleship-haskell:dk04
```

Hai client terminal trên host dùng port 4000 như README gốc. Sau thắng/bỏ cuộc container kết thúc bình thường; bắt đầu lại lệnh để tạo trận mới. Cổng loopback trên chỉ dành demo local; Compose sẽ không publish cổng Haskell.

## Trạng thái kiểm chứng tại workspace

Ngày **2026-10-10**, sau restart: Docker Desktop **4.94.0**, CLI/Engine **29.8.2**, context `desktop-linux`, Engine `linux x86_64`; WSL **3.0.1**. **Các gate kỹ thuật DK-04 đã qua trên Linux amd64.** C review vẫn cần được nhóm ghi nhận trước hợp nhất.

| Kiểm tra đã chạy | Kết quả |
|---|---|
| Build target `test`, gồm `stack build` | Exit 0; GHC 9.10.3, lts-24.59, dependency được build trong Linux, không dùng cache Windows |
| `stack test --ghc-options=-Werror` trong stage `test` | **908 ví dụ, 0 lỗi**, khoảng 102 giây; gồm A-06/B-06/C-07 và SIGTERM Unix |
| QuickCheck A-06/B-06 | Mỗi tính chất ít nhất 1.000 trường hợp; kiểm tra coverage qua |
| Build target `runtime` từ bản nguồn sạch | Exit 0; context 3,31 MB, không có Git database/cache/artifact Windows |
| Runner `node --test docker/test/haskell-runtime.test.mjs` | **5/5 qua, 0 skip**, khoảng 24 giây; TCP thật với image runtime |
| User/dependency/runtime contents | UID/GID `10001:10001`; `ldd` không thiếu thư viện; không có GHC/Stack hoặc `/build` |
| WELCOME/admission/cấu hình | Port 4000 và 4500 nhận P1/P2; P3 nhận `ERROR SERVER_FULL`; cấu hình bind sai thoát code 1 |
| Healthcheck/kết thúc | Đọc marker 100 lần không chiếm slot; Quit và SIGTERM thoát 0, EOF hai client và xóa marker trong deadline |
| Cleanup runner | Không còn container mang tiền tố `battleship-dk04-` sau khi test |
| Kiểm tra artifact sau cập nhật tài liệu | `node --check` qua; test hợp đồng DK-01 **6/6 qua**; `git diff --check` qua |

Bản nguồn sạch nằm tại `.stack-work/dk04/source-clean/`: sao chép 108 file tracked và file mới không bị Git ignore, kiểm tra SHA256 từng file khớp workspace, không sao chép `.git` hoặc cache bị ignore. Đây là bản nguồn độc lập để kiểm tra build context; **không phải một commit Git đã chốt**. Docker áp dụng `.dockerignore` vào bản này rồi build runtime; các layer build/test khớp và được tái sử dụng từ lần chạy Linux đã xanh ngay trước đó. Lần build test đầu tiên đã thực sự biên dịch/chạy suite, không lấy kết quả test từ cache có sẵn.

Image runtime local `battleship-haskell:dk04`: `sha256:3081db4544dc3a540c5f935b245e96e6b5b373af2597ae7a7560e641ae9c0e56`, kích thước Docker inspect **118.264.983 byte** (khoảng 113 MiB). Image test: `battleship-haskell-test:dk04`. Đây là image local, chưa publish registry.

Log thật trong `.stack-work/dk04/` (ignored): `linux-test-build.log`, `linux-runtime-build.log`, `runtime-test.log`. Các log `linux-build-attempt.log`/`runtime-preflight.log` là lần thử trước reboot khi daemon chưa chạy, không phải kết quả nghiệm thu hiện tại. Không phát hiện lỗi Haskell/Linux cần sửa; thay đổi lần kiểm tra này cập nhật minh chứng và trạng thái tài liệu. Có cảnh báo Cabal cũ về `build-tools` đã deprecated trong cấu hình test, nhưng không có warning GHC hoặc test thất bại dưới `-Werror`.

Phạm vi đã kiểm chứng là **server Haskell trong container Linux amd64**. Chưa kiểm chứng arm64, web image hoặc deployment Compose hai service; các bước đó thuộc task tiếp theo.

Nguồn cơ chế stage/context: [Docker multi-stage build](https://docs.docker.com/build/building/multi-stage/), [.dockerignore và build context](https://docs.docker.com/build/concepts/context/#dockerignore-files).
