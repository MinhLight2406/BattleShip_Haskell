# Images Docker — DK-04 / DK-05

## Image Haskell — DK-04

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

## Image web — DK-05

Nhánh `Dong_goi_kiem_thu_web`, nền `23f9fc5`. Dockerfile: `docker/web.Dockerfile`; runtime runner: `docker/test/web-runtime.test.mjs`. Không đổi frontend, API bridge, luật hoặc thời hạn reconnect 5 phút.

### Toolchain và stage

- Image chính thức [Node](https://hub.docker.com/_/node): `node:24.21.0-bookworm-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20`, xác minh registry ngày 2026-10-10. Node 24 đáp ứng `engines.node >=24` và chạy các test TypeScript hiện có.
- Stage `toolchain` cài chính xác `pnpm@11.25.0` và kiểm tra version Node/pnpm, khớp `packageManager`. Dependency frontend giữ nguyên theo lockfile; không cập nhật package hoặc lockfile.
- Stage `production` chạy `pnpm install --prod --frozen-lockfile`; stage `test` cài cả dev dependency bằng `--frozen-lockfile`, chạy `pnpm build` (TypeScript + Vite) rồi `pnpm test`. Lockfile lệch package sẽ làm build thất bại. Stage test có `.env.example` và `docs/` vì các test đọc hợp đồng Docker và transcript giao thức.
- Stage `runtime` bắt đầu lại từ Node base, lấy `dist`/bridge từ stage test và `node_modules` từ stage production. Không copy source React/TypeScript, test, tài liệu, pnpm hoặc cache build từ toolchain. `/app` chỉ có `bridge.mjs`, `dist`, `node_modules`.
- Dependency thực sự được cài ở runtime: `react@19.3.0`, `react-dom@19.3.0`, `scheduler@0.28.0`, `ws@8.22.0`. React được bundle vào JS để browser chạy; bridge sử dụng `ws`. Không có TypeScript, Vite, Playwright hoặc các package `@types` trong cây dependency runtime.
- `.dockerignore` bổ sung `.pnpm-store`, `.vite`, `coverage`; giữ các loại trừ Git, `.env`, node_modules, dist, log/cache Windows từ DK-04. Build phải tạo lại dist và dependency Linux.

`USER node` (UID/GID 1000) có quyền đọc các file ứng dụng. `ENTRYPOINT ["node", "bridge.mjs"]` chạy bridge trực tiếp làm PID 1; không thông qua npm/pnpm/shell. `STOPSIGNAL SIGTERM` gọi handler shutdown bridge hiện có, đóng HTTP/WS/TCP và hủy timer. Healthcheck dùng Node gọi `/healthz`, có timeout; không mở TCP tới Haskell và không tạo player slot.

Mặc định image: `HOST=0.0.0.0`, `PORT=8080`, `WEB_PUBLIC_PORT=8081`, `PUBLIC_ORIGIN=http://localhost:8081`, `BATTLESHIP_TCP_HOST=haskell`, `BATTLESHIP_TCP_PORT=4000`. Cổng nội bộ khác cổng public; giữ kiểm tra Origin/Host DK-03. Image không tự biết IP Wi-Fi của host. Với origin file động, phải override `PUBLIC_ORIGIN` bằng chuỗi rỗng và cấu hình `LAN_ORIGINS_FILE`/mount đúng hợp đồng; helper ghi file thuộc DK-06.

### Build và test

Từ root repository, Docker Engine Linux đang chạy:

```sh
docker build --platform linux/amd64 --progress=plain -f docker/web.Dockerfile --target runtime -t battleship-web:dk05 .
pnpm --dir frontend install --frozen-lockfile
node --test docker/test/web-runtime.test.mjs
```

Build runtime bắt buộc đi qua stage test. Có thể build riêng `--target test -t battleship-web-test:dk05`; image test chứa toolchain/source để kiểm tra, không dùng phục vụ production. Runner trên host cần Node >=24, dependency frontend đã cài và hai image `battleship-web:dk05` / `battleship-haskell:dk04` (build Haskell theo DK-04). **Build/unit của web không cần Haskell image**; runner dùng Haskell thật để kiểm chứng cleanup TCP. Nhận các biến test tùy chọn `BATTLESHIP_DOCKER_CLI`, `BATTLESHIP_WEB_IMAGE`, `BATTLESHIP_HASKELL_IMAGE`. Trên Windows per-user, đặt Docker CLI như hướng dẫn DK-04.

Sáu test runtime kiểm tra:

1. Node đúng version, non-root, entrypoint trực tiếp, không có source build/dev dependency.
2. HTML tham chiếu JS/CSS đã build; tải đúng MIME/nosniff và ảnh PNG thật từ CSS; source/package không được public.
3. Port, bind host, TCP host và public origin sai: exit 1, báo tên cấu hình, chưa log listen.
4. DNS backend không tồn tại: WebSocket đóng 1011, log lỗi rõ, HTTP/health vẫn dùng được.
5. SIGTERM: hai player nhận WELCOME qua DNS `haskell`, 100 health probe không chiếm slot; P1 mất WS rồi resume cùng token, deadline 300.000 ms; bridge PID 1 đóng HTTP keep-alive/WS và TCP tới Haskell, cả hai container exit 0.
6. SIGINT: cùng đường dọn HTTP/WS/TCP thật, exit 0 trong deadline.

Runner tạo network riêng bằng UUID, Haskell chỉ trên mạng nội bộ, web publish cổng ngẫu nhiên ở loopback. Health tối đa 20 giây, thao tác mạng/thoát tối đa 10 giây và Docker command tối đa 30 giây. Dọn đúng container/network của test, không prune resource khác. Thiếu Engine/image là lỗi thật, không skip.

### Demo local hai image, chưa dùng Compose

```sh
docker network create battleship-dk05-demo
docker run -d --name battleship-haskell-demo --network battleship-dk05-demo --network-alias haskell battleship-haskell:dk04
docker run --rm --name battleship-web-demo --network battleship-dk05-demo -p 127.0.0.1:8081:8080 battleship-web:dk05
```

Sau Haskell healthy, mở `http://localhost:8081` trong hai browser/profile độc lập. Ctrl+C ở terminal web gửi tín hiệu dừng bridge. Một trận kết thúc thì Haskell Exited theo hợp đồng; `docker start battleship-haskell-demo` tạo trận mới, dùng phiên mới. Cleanup sau demo: dừng web, `docker rm -f battleship-haskell-demo`, rồi `docker network rm battleship-dk05-demo`.

Demo trên chỉ publish loopback. Muốn truy cập LAN, publish `8081:8080` và override `PUBLIC_ORIGIN=http://<IPv4-host>:8081`; giữ `WEB_PUBLIC_PORT=8081`. Không sử dụng IP container làm URL cho người chơi. Compose/helper IP/LAN hai thiết bị thuộc DK-06..DK-08.

### Kết quả nghiệm thu DK-05

Ngày **2026-10-10**, Docker Desktop 4.94.0 / Engine 29.8.2, Linux amd64:

| Gate | Kết quả |
|---|---|
| Frozen install production + development | Qua; dependency và lockfile không đổi |
| `pnpm build` trong Linux | TypeScript qua; Vite tạo HTML, JS, CSS, PNG |
| `pnpm test` trong stage test | **36/36 qua, 0 skip** |
| `node --test docker/test/web-runtime.test.mjs` | **6/6 qua, 0 skip**, khoảng 46 giây |
| Runtime production/non-root | `/app` chỉ có dist/bridge/node_modules; UID/GID 1000; không có dev dependency |
| Tín hiệu/vòng đời | SIGTERM và SIGINT tới Node PID 1, HTTP/WS/TCP thật được dọn; backend Haskell exit 0 |
| Cleanup | Không còn container/network tiền tố `battleship-dk05-` sau test |

Log ignored ở `.stack-work/dk05/linux-web-build.log` và `web-runtime-test.log`. Lần build đầu phát hiện stage test thiếu `docs/protocol.md`; đã bổ sung `docs/` và build/test lại xanh. Không cần sửa logic bridge để chạy trong container. Chưa chạy browser automation hoặc nghiệm thu gameplay/LAN đầy đủ DK-08; chưa nghiệm thu arm64 hoặc Compose. Cần D review trước hợp nhất, không ghi xác nhận thay thành viên.
