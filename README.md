# BattleShip Haskell

Dự án Battleship cho hai người chơi qua client terminal hoặc giao diện web. Server TCP giữ trạng thái trận đấu; luật chơi được triển khai bằng các hàm thuần Haskell.

## Chơi bằng giao diện web

Nhánh `Connect_ui_backend` được rẽ từ `frontend-ui` (`a6ca31f`). Giao diện của nhóm đã kết nối với server Haskell qua cầu WebSocket–TCP. Hướng dẫn đầy đủ, kiến trúc và kết quả test: [docs/frontend_integration.md](docs/frontend_integration.md).

Cần Stack, Node.js 24 trở lên và pnpm 11.25.0. Từ thư mục gốc repository:

```sh
stack build
cd frontend
pnpm install --frozen-lockfile
pnpm build
cd ..
```

Mở hai terminal ở thư mục gốc:

```sh
# Terminal 1: server luật Haskell
stack exec battleship-server -- 4000
# Terminal 2: web server và cầu kết nối
node frontend/bridge.mjs
```

Mở link LAN được terminal cầu web tự in, hoặc `http://127.0.0.1:8080` ở **hai tab**. Chọn Cổ điển, đặt đủ năm tàu, nhấn Bắt đầu trận. Tab xác nhận trước là P1; chờ đủ hai người rồi bấm ô đối phương khi đến lượt. Trượt chuyển lượt; trúng/chìm giữ lượt. Nút Rời trận gửi QUIT để bỏ cuộc ngay; đóng tab/mất Wi-Fi được giữ phiên 5 phút. Người thứ ba nhận lỗi phòng đầy. Không cần nhập giao thức thô.

Server Haskell hiện phục vụ **một trận**. Sau khi thắng hoặc bỏ cuộc, chạy lại lệnh server ở Terminal 1 trước trận mới; cầu web ở Terminal 2 có thể giữ nguyên. Trinh sát chưa được hỗ trợ.

Test giao diện và tích hợp (chạy từ gốc repository sau khi build):

```sh
pnpm --dir frontend test
stack exec -- node --test frontend/test/integration.test.mjs
pnpm --dir frontend exec playwright install chromium
stack exec -- node --test frontend/test/browser.test.mjs
stack test --ghc-options=-Werror
```

Các test tích hợp tự mở port trống, dựng trận mới và dọn process/socket; không dùng trận đang chơi ở port 4000. Test trình duyệt tự thao tác giao diện, xuất ảnh vào `frontend/test-results/`.

### Tự nhận IP LAN và khôi phục trong 5 phút

Trên nhánh `Updata_Connecting_LAN`, cầu mặc định lắng nghe IPv4 tại `0.0.0.0`, tự đọc IP hiện tại của các giao diện mạng và in link. Không ghi cố định IP Wi-Fi vào mã nguồn. Khi Wi-Fi/IP thay đổi, cầu kiểm tra lại mỗi 2 giây, in link mới và chỉ cho WebSocket dùng origin của IP hiện tại, với Host trùng origin. Link cũ không được giữ trong danh sách cho phép. Kết nối Haskell vẫn là `127.0.0.1:4000`.

Nếu đã dùng cấu hình IP thủ công ở terminal trước, xóa nó trước khi chạy tự động:

```powershell
Remove-Item Env:HOST, Env:PUBLIC_ORIGIN -ErrorAction SilentlyContinue
$env:PORT = '8081'
node frontend/bridge.mjs
```

Terminal in các link lấy từ IP thực tế; hai thiết bị mở link của giao diện Wi-Fi/LAN chung. Nếu máy có cả VPN/máy ảo/Ethernet, có thể chọn đúng giao diện bằng `$env:LAN_INTERFACE = 'Wi-Fi'` (tên lấy từ máy thực tế). Không có IPv4 LAN thì cầu vẫn phục vụ localhost và chờ giao diện mạng xuất hiện.

**Đổi Wi-Fi trong trận:**

1. Lưu **Mã phiên của bạn** trên giao diện trước khi đổi mạng. Mỗi người có mã ngẫu nhiên riêng; không gửi cho đối thủ.
2. Cầu giữ nguyên TCP/P1/P2 và lõi Haskell khi mất WebSocket. Trận tạm dừng, người còn lại thấy thời gian còn lại; không gửi PLACE/FIRE trong lúc chờ.
3. Cầu bắt đầu hạn **300.000 ms** khi phát hiện mất kết nối. Ping mỗi 10 giây phát hiện kết nối im lặng trong khoảng tối đa 20 giây; đóng tab chủ động được phát hiện ngay khi nhận close. Hạn do máy chủ giữ, không bị đặt lại bởi tải trang hoặc thử kết nối thất bại.
4. Giao diện tự thử lại địa chỉ cũ mỗi 2 giây. Nếu IP máy chủ đổi, đọc link mới trên terminal; nhập vào **Địa chỉ máy chủ hiện tại → Kết nối địa chỉ mới**. Hoặc mở link mới rồi nhập mã ở **Khôi phục trận**. Dữ liệu trình duyệt thuộc từng origin, nên không thể trông chờ IP mới tự có mã của IP cũ.
5. Đúng mã và trước hạn: nhận lại chính P1/P2, đội tàu của mình, lịch sử đã lọc và lượt hiện tại; không gửi lại phát bắn cũ. Một mã không được dùng trên hai kết nối đang hoạt động.
6. Hết hạn: cầu gửi QUIT cho Haskell, người mất kết nối thua do bỏ cuộc; kết quả là GAME_OVER ... OPPONENT_LEFT. Có thể quay lại xem kết quả trong 5 phút sau khi phiên TCP kết thúc. Nếu cả hai cùng mất kết nối, phiên hết hạn trước bị xử QUIT trước.

Giữ cả process cầu web và server Haskell chạy khi đổi Wi-Fi. Khởi động lại process sẽ mất phiên đang giữ trong RAM. Hai thiết bị phải cùng mạng có thể liên lạc và firewall cho phép cổng web; tự nhận IP không vượt qua cô lập mạng khách. Chế độ client TCP terminal vẫn dùng luật EOF/QUIT tức thời; hạn khôi phục này áp dụng cho giao diện web qua cầu.

### Cấu hình IP thủ công — tùy chọn LAN-01

Nhánh `Updata_Connecting_LAN` bổ sung `HOST` và `PUBLIC_ORIGIN`. Sau khi build frontend, chạy Haskell server ở một terminal như trên. Trong terminal PowerShell thứ hai:

```powershell
$env:HOST = '192.168.1.10'  # Thay bằng IPv4 Wi-Fi/LAN của máy chạy server
$env:PORT = '8080'
$env:PUBLIC_ORIGIN = 'http://192.168.1.10:8080'
node frontend/bridge.mjs
```

Hai thiết bị cùng LAN mở đúng URL trong `PUBLIC_ORIGIN`; log khởi động cũng in URL này. TCP tới Haskell vẫn là `127.0.0.1:4000` mặc định. Có thể đặt `HOST='0.0.0.0'` để lắng nghe trên mọi giao diện IPv4, nhưng vẫn phải đặt `PUBLIC_ORIGIN` bằng IP LAN thật, không dùng `0.0.0.0` trong URL người chơi.

`HOST` nhận IPv4 hoặc `localhost`; `PUBLIC_ORIGIN` nhận HTTP với IPv4/localhost, có port trùng `PORT`, không có đường dẫn/query/credentials. Cấu hình rõ `HOST='127.0.0.1'` để chỉ chạy localhost. Xóa cả HOST/PUBLIC_ORIGIN để dùng tự nhận LAN; đặt IP thủ công thì IP đó không tự đổi khi Wi-Fi đổi.

Thiết bị ngoài máy chủ cần được mạng Wi-Fi và firewall cho phép truy cập cổng web đã chọn. Quy tắc firewall và nghiệm thu hai thiết bị thật thuộc LAN-05/LAN-06.

Kiểm tra cầu qua IP LAN của chính máy chủ (sau `stack build`):

```powershell
$env:BATTLESHIP_LAN_TEST_HOST = '192.168.1.10' # Thay bằng IP LAN thật của máy
stack exec -- node --test frontend/test/lan.test.mjs
```

Test tự chọn cổng trống, chạy bridge CLI/server Haskell production, kiểm tra HTTP, `WELCOME` P1/P2, từ chối Origin/Host sai, tự tìm IP không truyền HOST/PUBLIC_ORIGIN và khôi phục từ localhost sang origin IP LAN. Test này chạy trên máy chủ qua IP LAN; không thay thế nghiệm thu từ hai thiết bị vật lý.

Test khôi phục phiên và giới hạn thời gian:

```sh
pnpm --dir frontend test
stack exec -- node --test frontend/test/integration.test.mjs frontend/test/reconnect.test.mjs
stack exec -- node --test frontend/test/browser.test.mjs
```

Test clock tăng tốc kiểm tra đúng mốc 299.999/300.000 ms với socket và Haskell thật; test ngắt kết nối dùng hạn ngắn được truyền vào fixture, không đổi hạn 5 phút của CLI production. Test trình duyệt kiểm tra tải lại, chuyển origin bằng mã, riêng tư, tiếp tục bắn và kết quả thua khi quay lại muộn.

**Trạng thái hiện tại:** đã có C-01, A-01, D-01, Board A-02/A-03/A-04, Rules B-01/B-02/B-04, View B-03, server C-02/C-05, codec/client D-02, Coordinator C-03/C-04 và client tương tác D-03/D-04/D-05. Server thực thi PLACE/FIRE/QUIT qua Rules thật; một TVar giữ GameState, STM commit trạng thái/phản hồi cùng lúc và hai writer gửi từ TQueue riêng. Client hướng dẫn nhập/sửa năm tàu, nhập bắn theo lượt, cập nhật hai bàn từ dữ liệu riêng tư và hiển thị kết quả đến thắng/thua.

**S-01:** bản hợp đồng chung v2 cập nhật A-02 ở [docs/shared_contract.md](docs/shared_contract.md). Chưa khóa mốc vì còn chờ xác nhận A/B/C/D; việc ẩn constructor Fleet, chủ sở hữu file và quy trình thay đổi được ghi tại đó.

**S-02:** nghiệm thu kỹ thuật lõi thuần và kịch bản 25 lệnh ở [docs/report_final.md](docs/report_final.md); còn chờ A/B xác nhận. Fixture chơi hợp lệ trong test lõi được dựng qua `Rules.step` thật.

**S-03:** đã build sạch, chạy 794 test xanh và chơi trọn trận với hai terminal/lõi thật; [hồ sơ và log demo](docs/s03_acceptance.md). Còn chờ xác nhận A/B/C/D và R; một vấn đề trình bày nhỏ được ghi tại [task Đợt 9](docs/round9_fixes.md).

**S-04:** A-05/B-05/C-06/D-06 đã được kiểm tra kỹ thuật; [hồ sơ chốt tính năng](docs/s04_feature_freeze.md) ghi bản terminal dùng tại mốc đó. Nhánh hiện tại bổ sung GUI theo yêu cầu tích hợp `frontend-ui` ngày 2026-10-05. Việc nhóm xác nhận bản dùng để báo cáo vẫn cần ghi riêng.

## Build và test

### Nghiệm thu đầu cuối D-06 từ checkout sạch

Để dùng bản chốt S-04, clone repository vào thư mục mới và checkout SHA của commit chốt ghi trong [hồ sơ S-04](docs/s04_feature_freeze.md), rồi chạy `stack build` và `stack test`. Không lấy HEAD mới hơn làm bản báo cáo nếu nhóm chưa duyệt revision đó.

Bundle `docs/demo/d06/source.bundle` giữ nguyên snapshot được nghiệm thu D-06 trước khi tạo commit chốt; dùng nó để tái hiện đúng log lịch sử. Từ repository có file bundle, clone vào một thư mục mới (đích phải chưa tồn tại):

```sh
git clone docs/demo/d06/source.bundle .stack-work/d06-replay
cd .stack-work/d06-replay
git status --porcelain
stack build
stack test
stack test --ghc-options=-Werror --test-arguments="--match D-06"
```

`git status --porcelain` phải rỗng trước build; clone không mang `.stack-work` hoặc binary từ bản gốc. Snapshot dùng đúng cấu hình compiler/dependency bên dưới; cache GHC/dependency của Stack có thể được dùng lại. Bundle không phải chữ ký nhóm và SHA snapshot D-06 khác SHA commit chốt S-04.

Sau build, mở ba terminal **cùng tại thư mục checkout vừa tạo**, mỗi terminal chạy một lệnh:

```sh
# Terminal 1
stack exec battleship-server -- 4000
# Terminal 2: đặt tàu và GUI trước để được P1
stack exec battleship-client -- 4000
# Terminal 3
stack exec battleship-client -- --play 4000
```

Nếu port 4000 đang dùng, chọn port khác cho cả ba. Nhập từng tàu theo prompt, xem preview rồi `GUI`; client chưa kết nối khi chưa xác nhận. Chỉ bắn khi hiện lượt của mình. [Kịch bản D-06](docs/d06_demo.md) có đội tàu mới, lệnh lỗi, thắng và cách thử đóng client; có cả bước tự chọn input khác và quyết định từ phản hồi. Test D-06 chạy ba executable production, đọc prompt trước từng input, không nạp sẵn cả transcript vào stdin. Log thực tế và thông tin snapshot nằm ở `docs/demo/d06/`.

Cài Git và Stack (đã kiểm tra với Stack 3.11.1). Cấu hình dùng snapshot LTS 24.59, tương ứng GHC 9.10.3. Stack dùng GHC phù hợp có sẵn trên PATH hoặc cài compiler cần thiết. Lần chạy đầu cần Internet để tải compiler/phụ thuộc.

Từ thư mục gốc của repository, chạy:

```sh
stack build
stack test
```

`stack build` biên dịch thư viện và hai executable. `stack test` chạy Types/Board/Rules/View, Protocol/Client, hợp đồng S-01, Server C-02, Coordinator C-03/C-04, executable và smoke test C-01. Test TCP dùng port do OS cấp, gồm cả stub và Rules production; ProtocolSpec kiểm tra các transcript trong tài liệu. Windows Application Control chặn executable sẽ khiến smoke test thất bại.

Chạy riêng hợp đồng giao thức:

```sh
stack test --test-arguments="--match D-01"
stack test --ghc-options=-Werror --test-arguments="--match D-02"
```

Chạy riêng đối chiếu hợp đồng chung hoặc kiểm tra biên dịch không có warning:

```sh
stack test --test-arguments="--match S-01"
stack test --ghc-options=-Werror
```

Kiểm tra S-01 đọc file trong src/app/test và docs/shared_contract.md từ gốc repository để phát hiện định nghĩa Coord/Command trùng, API lệch tài liệu hoặc file thiếu người phụ trách. Nếu chạy test binary trực tiếp, đặt working directory ở gốc repo.

Chạy riêng A-02:

```sh
stack test --test-arguments="--match A-02"
```

Chạy riêng nghiệm thu đặt tàu A-03:

```sh
stack test --ghc-options=-Werror --test-arguments="--match A-03"
```

BoardSpec gồm test thuần cho đúng năm ID/17 ô, mép A1/J10, tàu dài 3 trùng ID, tàu chạm cạnh và không đặt lại qua Rules.step. Năm test biên dịch chạy GHC có sẵn trong môi trường Stack trên probe tạm: API public hợp lệ phải biên dịch, constructor/record update/coerce/import private phải bị từ chối đúng nguyên nhân. Probe chỉ dùng package đã build, được xóa sau test; không cần dependency mới.

Chạy riêng QuickCheck A-06/B-06 (mỗi property tối thiểu 1.000 trường hợp):

```sh
stack test --ghc-options=-Werror --test-arguments="--match=A-06"
stack test --ghc-options=-Werror --test-arguments="--match=B-06"
```

Hai bộ test dùng chung generator trong `test/TestSupport/Generators.hs`, độc lập với các hàm kiểm tra của Board. B-06 tạo trạng thái qua `step`, đối chiếu view với sự kiện quan sát được và so sánh hai trận có ô bí mật khác nhau nhưng cùng sự kiện công khai, kể cả Sunk và kết thúc. Khi lỗi, Hspec in phản ví dụ và lệnh chạy lại có seed; ví dụ thêm `--seed=20261009` vào `--test-arguments`. Giữ nguyên code và phiên bản dependency khi tái hiện seed. Test ngẫu nhiên không thay thế chứng minh bất biến.

Chạy riêng luật B-01/B-02:

```sh
stack test --ghc-options=-Werror --test-arguments="--match B-01"
stack test --ghc-options=-Werror --test-arguments="--match B-02"
```

`step :: Step` có đủ nhánh Command/Phase. FIRE kiểm tra readiness → lượt → tọa độ → bắn lặp; sai trả Left và không tiêu lượt. FIRE hợp lệ ghi đúng một tọa độ/kết quả vào `playerShots` của người bắn; `shotsReceived opponent state` đọc chính lịch sử đó cho bàn đối thủ, không lưu bản sao thứ hai. Miss đổi lượt; Hit/Sunk giữ lượt; trúng toàn bộ ô tàu trả Win và Finished. Sự kiện là ShotResolved rồi TurnReady hoặc GameEnded, không có TURN sau WIN. C-03 kiểm chứng Coordinator giữ state cũ khi Left qua unit test và TCP thật.

Chạy riêng nghiệm thu S-02 (26 test, không mở socket/server trong các test này):

```sh
stack test --ghc-options=-Werror --test-arguments="--match S-02"
```

Stack vẫn biên dịch các build-tools của package. Kịch bản gọi trực tiếp `step` từ trạng thái rỗng, kiểm tra đặt tàu/chờ/trượt/trúng/chìm/thắng và giữ trạng thái khi lệnh sai; bảng sự kiện cùng lệnh biên dịch riêng lõi chỉ với `base`/`containers` có trong báo cáo.

Chạy riêng góc nhìn và lọc bí mật B-03:

```sh
stack test --ghc-options=-Werror --test-arguments="--match B-03"
```

`View.viewFor` trả fleet của chính người nhận, lịch sử bắn ra/bắn vào, phase và readiness của đối thủ. Không trả fleet đối thủ hoặc tự lộ tàu khi kết thúc. Test kiểm tra P1/P2, 72 bố trí đối thủ, mọi tọa độ chưa bị bắn, cùng tọa độ trên hai bàn và toàn ván đến thắng. Wire v1 tiếp tục gửi sự kiện đã lọc qua Coordinator/Protocol, không gửi snapshot PlayerView hay serialize GameState.

Thử hàm thuần bằng `stack ghci battleship-haskell:lib`:

```haskell
import Battleship.Types
import Battleship.Board
let placements = [ShipPlacement ship (Coord 1 row) Horizontal | (ship, row) <- zip [Carrier, Battleship, Cruiser, Submarine, Destroyer] [1..5]]
placeFleet placements -- Right fleet hợp lệ, đủ 17 ô
placeFleet (take 4 placements) -- Left (InvalidFleetSize 4)
shipCells (ShipPlacement Carrier (Coord 9 10) Horizontal) -- Left (ShipOutOfBounds Carrier (Coord 11 10))
```

`Fleet(..)` và record update `fleet { fleetShips = ... }` không còn là API công khai. Tạo fixture/game fleet bằng `placeFleet`; đọc các ô qua `fleetShips fleet`. Module `Battleship.Internal.Fleet` chỉ dành cho Board/Types và không được expose cho executable/client.

Mô phỏng một ván thuần trong GHCi, từ đặt tàu đến P1 thắng (không cần server):

```haskell
import Battleship.Rules
import Battleship.Types
import Battleship.Board
import Control.Monad (foldM)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
let p1 = [ShipPlacement ship (Coord 1 row) Horizontal | (ship, row) <- zip [Carrier, Battleship, Cruiser, Submarine, Destroyer] [1..5]]
let p2 = [placement { placementStart = Coord 1 (coordRow (placementStart placement) + 5) } | placement <- p1]
let play (state, batches) (player, command) = do { (next, events) <- step player command state; pure (next, batches ++ [events]) }
let game = do { fleet <- placeFleet p2; foldM play (initialGameState, []) ([(P1, PlaceFleet p1), (P2, PlaceFleet p2)] ++ [(P1, Fire cell) | cell <- Set.toList (Set.unions (Map.elems (fleetShips fleet)))]) }
fmap (gamePhase . fst) game -- Right (Finished P1 AllShipsSunk)
fmap (Map.size . shotsReceived P2 . fst) game -- Right 17
fmap (take 1 . reverse . snd) game -- batch cuối gồm ShotResolved ... Win, GameEnded P1 AllShipsSunk
```

## Cập nhật nguyên tử C-04

```sh
stack test --ghc-options=-Werror --test-arguments="--match C-04"
```

Coordinator giữ một TVar GameState và hai TQueue cho P1/P2. Mỗi submit đọc state, gọi step, encode/lọc và ghi state + toàn bộ batch vào queue trong cùng atomically; lệnh lỗi chỉ xếp phản hồi actor-only, không ghi state. Writer riêng lấy frame từ queue và gửi socket ngoài giao dịch. GAME_OVER nằm trước marker kết thúc; server chờ mọi writer đã được admission drain xong rồi đóng. MVar chỉ giữ registry/cleanup, không giữ bản sao GameState. Test gồm 250 cuộc đua có barrier, rollback lỗi/retry, FIFO và commit khi queue chưa được đọc.

## Chạy và kiểm tra server C-02/C-03/C-04

Khởi chạy server trong terminal thứ nhất (mặc định port 4000):

```sh
stack exec battleship-server
stack exec battleship-server -- 4001
stack exec battleship-server -- --help
```

Chọn một lệnh khởi chạy. Server in `Battleship server listening on 127.0.0.1:4000` rồi tiếp tục lắng nghe. Port `0` cho phép OS chọn port trống; dòng startup ghi port thực tế. Port sai hoặc bind thất bại được báo ở stderr và thoát với exit code khác 0.

Mở hai terminal PowerShell khác và chạy đoạn sau ở mỗi terminal (sửa port nếu cần):

```powershell
$tcpDemo = [System.Net.Sockets.TcpClient]::new()
try {
    $tcpDemo.Connect('127.0.0.1', 4000)
    $tcpReader = [System.IO.StreamReader]::new($tcpDemo.GetStream())
    while ($null -ne ($tcpLine = $tcpReader.ReadLine())) { $tcpLine }
} finally {
    $tcpDemo.Dispose()
}
```

Terminal kết nối trước nhận `WELCOME 1 P1`, terminal sau nhận `WELCOME 1 P2`; cả hai giữ kết nối dù chưa gửi lệnh. Chạy lại đoạn đó trong terminal thứ ba: chỉ nhận `ERROR SERVER_FULL` rồi EOF. Đóng một terminal client để ngắt kết nối; người còn lại nhận `GAME_OVER <người còn lại> OPPONENT_LEFT`, server đóng session và dừng. Muốn thử trận mới, khởi chạy server lại. Nhấn Ctrl+C ở terminal server để dừng và cleanup.

C-03 nhận PLACE/FIRE/QUIT theo [giao thức v1](docs/protocol.md), parser từ chối cú pháp/tọa độ sai; Board/Rules quyết định lỗi nghiệp vụ và kết quả. FIRE trước khi đủ hai fleet trả `ERROR FLEETS_NOT_READY`. Dòng quá dài nhận `ERROR LINE_TOO_LONG` rồi kết thúc session theo D-01. Không tái sử dụng slot hay nhận người thay thế. Đoạn PowerShell trên chỉ giữ kết nối/đọc để thử slot; nghiệm thu đặt tàu/bắn dùng test TCP bên dưới.

Chạy các kiểm thử tự động tương ứng:

```sh
stack test --ghc-options=-Werror --test-arguments="--match C-02"
stack test --ghc-options=-Werror --test-arguments="--match C-03"
```

## Đặt tàu theo hướng dẫn D-03

Khởi chạy server, rồi mở hai terminal client. Dùng port đang hiển thị ở server:

```sh
stack exec battleship-client -- --place 4000
```

Không truyền đối số (`stack exec battleship-client`) cũng mở hướng dẫn, dùng port 4000. Nhập từng tàu theo prompt CV/BB/CR/SB/DD, độ dài cố định 5/4/3/3/2. Chỉ nhập tọa độ đầu và hướng: H ngang sang phải, V dọc xuống dưới. Client cho nhập chữ thường/khoảng trắng linh hoạt; wire vẫn theo v1.

Ví dụ đội tàu hợp lệ; nhập lần lượt mỗi dòng khi terminal hỏi:

```text
A1 H
A2 H
A3 H
A4 H
A5 H
```

Tọa độ nằm trong A1..J10. Tàu không được vượt mép/chồng lên nhau, được chạm cạnh. Sai input sẽ báo lỗi và hỏi lại chính tàu đó. Đủ năm tàu thì hiện bàn 10×10: CV/BB/CR/SB/DD là ô tàu của mình, dấu chấm là ô trống. `SUA CV` (hoặc BB/CR/SB/DD) sửa một tàu rồi xem lại; ví dụ đổi CV thành `A6 V`. `GUI` xác nhận và gửi **một** PLACE đã kiểm tra; `HUY` hoặc EOF trước GUI hủy mà không kết nối/gửi gì.

Client chỉ kết nối sau GUI; P1/P2 được gán theo thứ tự kết nối đó, không theo thứ tự mở terminal. Sau OK PLACE, giữ socket để nhận WAITING/START/TURN/INCOMING/GAME_OVER và chơi D-04 bên dưới. Nhập tại terminal và chờ đối thủ sau OK không chịu timeout 10 giây; connect/handshake/đợi OK vẫn có deadline. Ctrl+C rời trận và đóng socket. Bản xem trước chỉ lấy fleet của mình, không yêu cầu dữ liệu bí mật của đối thủ.

```sh
stack test --ghc-options=-Werror --test-arguments="--match D-03"
```

## Bắn và theo dõi lượt D-04

Dùng hai terminal `stack exec battleship-client -- --place 4000` như trên. Sau GUI, làm theo thông báo:

| Thông báo/giai đoạn | Việc tiếp theo |
|---|---|
| Đang chờ đối thủ đặt tàu | Giữ kết nối, chưa bắn; Ctrl+C để rời trận |
| Đến lượt bạn bắn | Nhập `A1` hoặc `FIRE A1`, rồi Enter; `QUIT` để rời trận |
| Lỗi tọa độ/cú pháp/bắn lặp | Nhập lại; lỗi địa phương không gửi lệnh và không mất lượt |
| Đã gửi phát bắn | Chờ server trả SHOT và TURN/GAME_OVER; không gửi phát thứ hai trước phản hồi |
| Trượt / lượt đối thủ | Chờ; INCOMING mô tả nước bắn vào bàn mình |
| Trúng / chìm | Đọc kết quả; chỉ nhập tiếp khi server thông báo đến lượt bạn |
| Bạn thắng / bạn thua | Trận đã kết thúc, client đóng kết nối; khởi động server lại để chơi ván mới |

Chấp nhận chữ thường/khoảng trắng: `fire j10` gửi `FIRE J10`; Backspace xóa ký tự nhập sai. Dòng ASCII quá 256 ký tự bị từ chối; client nhớ các ô đã bắn thành công để báo bắn lặp tại chỗ. Server vẫn quyết định luật/kết quả và kiểm tra tất cả lệnh. Khi đang nhập dở, thông báo kết thúc vẫn được đọc và hiển thị; không phải nhấn Enter mới biết đối thủ đã rời trận. EOF lúc được hỏi bắn gửi QUIT; lúc đang chờ, dùng Ctrl+C để rời trận.

```sh
stack test --ghc-options=-Werror --test-arguments="--match D-04"
```

## Chơi trọn trận và xem hai bàn D-05

Mở ba terminal: một server và hai người chơi.

```sh
# Terminal server
stack exec battleship-server -- 4000
# Terminal người chơi thứ nhất
stack exec battleship-client -- 4000
# Terminal người chơi thứ hai
stack exec battleship-client -- --play 4000
```

Mỗi người nhập năm tàu theo hướng dẫn (`A1 H`, ...), xem trước rồi chọn `GUI`. Khi được báo đến lượt, chỉ nhập tọa độ như `A6`; client tự tạo thông điệp giao thức. Không cần tự viết PLACE/FIRE hoặc mã P1/P2. `--place [PORT]` vẫn chơi đầy đủ như các ví dụ cũ; chạy client không tham số dùng cổng 4000.

Sau xác nhận đặt tàu, client in hai bàn cạnh nhau và cập nhật sau mỗi phát bắn đã nhận từ server:

| Ký hiệu | Ý nghĩa |
|---|---|
| CV/BB/CR/SB/DD | Ô tàu của mình chưa bị bắn |
| `.` | Nước trên bàn mình |
| `?` | Ô đối thủ chưa bắn, vẫn được giấu cả sau kết thúc |
| `o` | Phát bắn trượt |
| `X` | Phát bắn trúng |
| `#` | Phát bắn làm chìm một tàu |
| `*` | Phát bắn thắng trận |

`#` chỉ đánh dấu ô của phát bắn làm chìm; các ô trúng trước đó giữ `X`. Client không suy đoán các ô còn lại của tàu đối thủ từ mã SUNK. Kết quả thắng/thua được in cuối cùng sau hai bàn cuối. Hướng dẫn nhập, sửa sai, chờ lượt và rời trận ở phần D-03/D-04 vẫn áp dụng.

```sh
stack test --ghc-options=-Werror --test-arguments="--match D-05"
```

## Client một lệnh D-02

Trong terminal khác khi server đang chạy, chọn một lệnh:

```sh
stack exec battleship-client -- 4000 "QUIT"
stack exec battleship-client -- 4000 "FIRE A1"
stack exec battleship-client -- 4000 "PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H"
stack exec battleship-client -- --help
```

Có thể bỏ PORT để dùng 4000, ví dụ `stack exec battleship-client -- "QUIT"`. Chế độ một lệnh nhận WELCOME, gửi đúng một lệnh, hiển thị UTF-8 rồi đóng socket sau phản hồi, khiến session kết thúc. Dùng để kiểm tra nhanh; dùng `--place` ở trên để đặt tàu và chơi trọn ván theo hướng dẫn. Lệnh thiếu tham số/tọa độ sai bị từ chối trước khi kết nối.

`package.yaml` là nguồn cấu hình package; file `.cabal` được Stack/Hpack sinh tự động. Giữ `stack.yaml.lock` trong Git để chia sẻ cùng snapshot.

`Types` dùng `containers` cho `Map`/`Set`; C-02/D-02 dùng `network` cho TCP, `bytestring` cho framing/codec theo byte, `async` cho vòng đời worker và deadline. C-04 dùng `stm` cho TVar/TQueue/atomically trong library và test; D-04 dùng queue cho Response đọc từ mạng. D-04 khai báo `Win32` chỉ khi `os(windows)`, dùng binding console sẵn trong GHC để nhận sự kiện khi đang nhập dở; CPP bỏ import/cài đặt Win32 trên nền tảng khác. Hai Main dùng PortNumber từ `network`; ClientMain dùng `bytestring` để đưa lệnh CLI vào parser. Test suite dùng Hspec, `network`/`async` để kiểm tra TCP thật, `process` để khởi chạy executable và `directory`/`filepath` để đối chiếu cây nguồn S-01 trên Windows/Linux. `docs/protocol.md` là data file để test đọc đúng tài liệu qua module Cabal tự sinh `Paths_battleship_haskell`. A-06/B-06 dùng QuickCheck trong test suite cho tính chất đội tàu và góc nhìn riêng; chưa cần thêm text.

Thành viên A/B/D lấy nhánh nền đã chứa C-01 bằng `git fetch origin` và checkout/pull nhánh được nhóm thống nhất, rồi chạy hai lệnh trên trước khi thêm mã của mình.

## Luật chính

- Bàn 10×10, tọa độ A1–J10; mỗi người đặt năm tàu dài 5, 4, 3, 3, 2.
- Player 1 bắn trước sau khi cả hai đã đặt tàu hợp lệ.
- **Bắn trúng được bắn tiếp**, kể cả khi làm chìm tàu. **Bắn hụt mới chuyển lượt**.
- Lệnh sai hoặc bắn lặp không làm đổi trạng thái và không mất lượt.
- Người bắn trúng toàn bộ 17 ô tàu của đối phương thắng ngay.

Luật đầy đủ ở [docs/game_spec.md](docs/game_spec.md). Sơ đồ hoạt động ở [docs/architecture.md](docs/architecture.md); giao thức v1 đã chốt ở [docs/protocol.md](docs/protocol.md).

## Phân công thư mục

| Thành viên | File phụ trách |
|---|---|
| A | `Types.hs`, `Board.hs`, `BoardSpec.hs` |
| B | `Rules.hs`, `View.hs`, test luật và góc nhìn |
| C | `Coordinator.hs`, `Server.hs`, `ServerMain.hs`, test đồng thời |
| D | `Protocol.hs`, `Client.hs`, `ClientMain.hs`, test giao thức và tích hợp |
| R | `docs/`, báo cáo, minh chứng kiểm thử và demo |

Trước khi tích hợp nghiệp vụ tiếp theo, cả nhóm review và ghi xác nhận S-01 v2 tại [docs/shared_contract.md](docs/shared_contract.md), gồm các cập nhật đến B-03/C-04. Phân công chi tiết gồm cả Main, test và YAML nằm ở đó. Board/Types, Rules/View, Coordinator/server STM, codec và client đặt tàu/bắn/render diễn biến trận đã có cài đặt; đối chiếu hồ sơ S-03 và các task sửa Đợt 9 trước khi chốt nghiệm thu nhóm.
