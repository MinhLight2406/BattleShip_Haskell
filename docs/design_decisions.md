# Quyết định thiết kế và căn cứ lựa chọn

Đối chiếu source nền `8bd7da9`, ngày 2026-10-10. Mỗi mục ghi yêu cầu → cách xử lý → lợi ích → đánh đổi/phương án khác → bằng chứng. Đây là lý do kỹ thuật cho cài đặt hiện có, không tuyên bố đã benchmark các phương án chưa thực hiện. Hằng số/API chuẩn ở [hợp đồng chung](shared_contract.md) và [hợp đồng Docker](docker_deployment.md).

## 1. Chốt YAML, kiểu và wire trước luật/IO

**Yêu cầu:** A/B/C/D kéo về build được và lập trình độc lập. `package.yaml` định nghĩa library, hai executable, test suite; `stack.yaml` chốt lts-24.59/GHC 9.10.3. Sau scaffold, chốt Types/chữ ký/protocol trước khi mỗi người triển khai.

**Hiệu quả:** lỗi compiler/dependency tách khỏi lỗi luật; library tái sử dụng cho server/client/test; Main chỉ cấu hình/khởi chạy. Hpack sinh `.cabal`, không sửa tay song song YAML. Snapshot/lockfile giảm lệch môi trường; không bảo đảm image bit-for-bit vì gói apt được cài từ repository theo thời điểm build.

**Phương án khác:** viết `.hs` trước vẫn phù hợp thử một hàm GHCi, nhưng dự án nhiều component cần gate build sớm. Cabal thuần dùng được; nhóm đã chọn Stack/Hpack theo workflow đang học, không cần thêm bộ cấu hình cạnh tranh. Test `SharedContractSpec` và C-01 kiểm tra component/hợp đồng.

`system-ghc: true` tận dụng GHC đã có khi đúng snapshot; Docker build thêm `--no-install-ghc` và kiểm tra numeric version để không âm thầm tải compiler khác. QuickCheck nằm trong dependency test, network/STM/async nằm lớp library cần chúng; conditional Win32/unix phục vụ console/signal từng OS. `-threaded/-rtsopts/-with-rtsopts=-N` cho runtime worker mạng, không chứng minh luật được tăng tốc song song. `-Wall`/gate `-Werror` bắt warning khi nghiệm thu.

`docs/protocol.md` là data-file cho test transcript khi package cài đặt; README/docs top-level là extra-source để đóng gói tài liệu. Fixture S-01 đọc source/contract từ root nên test image phải có đủ source/docs, không chỉ executable. Build option `ansi-terminal:hsc2hs --cross-compile` trong stack.yaml là workaround build probe Windows của dependency đã ghi khi môi trường chặn chạy probe; nó không cấp quyền mở socket hoặc thay chính sách hệ điều hành cho server. Docker vẫn kiểm chứng compiler/runtime Linux thật.

## 2. Lõi thuần, IO ở biên

`step :: PlayerId -> Command -> GameState -> Either GameError (GameState,[Event])` không có IO/STM/socket. Board/View/Protocol cũng thuần. Server/coordinator chỉ gọi lõi, định tuyến và giữ tài nguyên.

**Lợi ích:** cùng input cho cùng kết quả; mô phỏng cả ván không cần port; property test chạy nhiều dữ liệu; lỗi lượt/thắng có thể tái hiện độc lập timing mạng. `runServerWith` là seam tiêm Step cho test, production chọn `Rules.step initialGameState`, không có stub thắng/thua trong đường chạy mặc định.

**Đánh đổi:** phải truyền state/event tường minh, thêm lớp chuyển Event thành wire. Đặt luật trực tiếp trong socket handler ít file hơn ban đầu nhưng trộn timing, exception và nghiệp vụ; khó kiểm thử nhánh lỗi mà không mở mạng. Với MVP cần trình bày FP rõ ràng, tách lõi là phù hợp. S-02/RulesSpec kiểm chứng.

## 3. ADT thay chuỗi trạng thái và mã lỗi rời rạc

PlayerId, ShipId, Orientation, Phase, Command, Event, GameError là sum type; Coord/PlayerState/GameState/PlayerView là record/product. `Maybe Fleet` biểu diễn chưa đặt; `Either` mang lỗi cụ thể.

**Lợi ích:** pattern matching thể hiện nhánh đặt/bắn/Quit và placing/turn/finished; tránh typo chuỗi như `playing`/`playng` trong lõi; chữ ký khiến caller phải xử lý khả năng lỗi. Không dùng sentinel PlayerId/đội tàu trống để diễn tả thiếu dữ liệu.

**Giới hạn:** ADT không tự chứng minh mọi invariant. Coord raw ngoài bàn và GameState tự ghép vẫn biểu diễn được; kiểm tra nằm ở Board/Rules. GADT/type-level phase có thể siết thêm state nhưng tăng độ khó/API, chưa cần cho môn học và quy mô này. TypesSpec/SharedContractSpec phát hiện lệch contract hoặc trùng Coord/Command.

## 4. FleetPlacement là list, Fleet là Map/Set private

Input phải giữ được tàu trùng ID để báo lỗi. Nếu parse trực tiếp vào Map, mục thứ hai có thể ghi đè mục trước và che mất lỗi. Sau kiểm tra, Fleet lưu `Map ShipId (Set Coord)`: danh tính riêng, đọc ô/đếm/giao nhau rõ ràng.

`placeFleet` là smart constructor công khai; constructor thật ở `Internal.Fleet` ẩn trong package. Chỉ Board/Types truy cập biểu diễn private. Fleet bên trong có tham số kiểu để không tạo vòng import với Types.

**Đánh đổi:** getter không phải record selector update công khai; cần một module private. Export constructor sẽ đơn giản cho fixture nhưng cho Rules nhận fleet 0 ô/chồng lấn. Ma trận array 100 ô cũng được, song vẫn cần ánh xạ ShipId và chứng minh chiều dài/hình dạng; Map/Set đủ nhỏ cho 17 ô, không có tuyên bố nhanh hơn array đã đo. BoardSpec có compile probe và thử ID/biên/tiếp xúc.

## 5. Nháp ở client, xác nhận cả fleet một lần

Server nhận một PLACE đủ năm tàu; không có lệnh đặt từng tàu/di chuyển từng ô. Client sửa nháp, xem trước rồi xác nhận.

**Lợi ích:** server không lưu nửa fleet hay rollback nhiều lần nhập; PLACE sai không lưu phần hợp lệ; người mới nhận hướng dẫn rõ. Khi OK, vị trí khóa trong suốt ván.

**Phương án khác:** API đặt từng tàu phù hợp editor server nhiều người hoặc lưu nháp, nhưng thêm trạng thái xác nhận/hủy/resume nháp. MVP không yêu cầu nên giữ atomic PLACE. BoardSpec/ClientSpec và browser test kiểm tra sửa input, xác nhận/khóa.

## 6. Lịch sử bắn lưu một lần

`playerShots` của người bắn là nguồn history; `shotsReceived actor state` lấy history của đối thủ. Không có outgoing/incoming map độc lập trong GameState.

**Lợi ích:** một update duy nhất cho một phát, hai góc nhìn luôn dùng cùng dữ liệu; không cần sửa hai map và xử lý lệch khi quên một bên. MISS đổi phase; HIT/SUNK giữ; WIN kết thúc. Outcome lưu kết quả tại thời điểm bắn, không tô lại HIT cũ.

**Đánh đổi:** tên shotsReceived là hàm suy ra, không field để record update. Hai map cache có thể hợp lý với dữ liệu lớn/nhu cầu truy vấn khác nhưng phải có cơ chế nhất quán; 100 ô không cần. RulesSpec/ViewSpec kiểm tra cả hai history và kết thúc.

## 7. Chìm theo ShipId, WIN trước SUNK

Tàu được chạm cạnh. Dò vùng liên thông sẽ có thể gộp hai tàu riêng thành một; Rules tìm đúng ShipId có ô bị bắn và xét tập ô tàu đó. Xét hết fleet trước để phát cuối là WIN, không SUNK rồi phát lượt nữa.

**Tác dụng:** giữ luật R-01 và thông tin chìm chính xác; không cần đánh dấu từng ô tàu mutable hoặc duplicate counter có thể sai. Counter số hit có thể nhanh ở game lớn nhưng phải kiểm soát bắn lặp và đồng bộ; tập tọa độ hiện có đủ. Test B-02/S-02/B-04 mô phỏng ván và ưu tiên kết quả cuối.

## 8. Actor gắn socket, không nhận PlayerId trong lệnh

Server gán P1/P2 theo admission. PLACE/FIRE/QUIT không mang danh tính tự khai; coordinator nhận actor từ worker sở hữu socket.

**Lợi ích:** client không thể gửi FIRE với P1 để mượn lượt P1. Hai slot không thay người giữa ván, người thứ ba nhận SERVER_FULL. Resume web nối lại TCP cũ, không accept lại.

**Giới hạn:** đây là danh tính trong một trận, không tài khoản/xác thực Internet; TCP native ai kết nối trước giữ slot. Room ID/login phù hợp nhiều phòng/public service nhưng ngoài MVP. ServerSpec/IntegrationSpec kiểm tra admission/phòng đầy.

## 9. TCP có framing tường minh

TCP là luồng byte, một recv không tương ứng một lệnh. `feedFrames` giữ phần dở, tách LF/CRLF, bảo toàn frame hoàn chỉnh trước lỗi ở frame sau. Payload ASCII in được ≤256 byte, không gồm delimiter; parser không tự trim/case-fold wire. UI terminal có thể chuẩn hóa nhập thân thiện riêng.

**Lợi ích:** test/dò bằng transcript được, đơn giản hơn schema binary, giới hạn pending buffer; tách lỗi syntax khỏi fleet/turn. Không cần UTF-8 tiếng Việt trong wire, câu chữ ở client.

**Phương án khác:** JSON cả hai tầng hữu ích khi nhiều trường/version phức tạp; framing length-prefix tốt cho payload binary. Chúng vẫn phải có size limit/parser/compatibility. Protocol dòng đủ cho ba lệnh và vài response MVP; protocol v1 không nên tự đổi khi ghép UI. ProtocolSpec/bridge.test kiểm tra chia/gộp chunk, CRLF, oversize và transcript.

## 10. Event/góc nhìn riêng thay broadcast GameState

`viewFor` chiếu ownFleet/history/readiness/phase. Đường TCP thực tế gửi Event đã lọc: SHOT chỉ người bắn, INCOMING chỉ người nhận, OK/lỗi riêng actor. Không serialize GameState hoặc fleet đối thủ.

**Lợi ích:** bí mật bị loại trước biên mạng, không dựa vào CSS ẩn; tránh client tải JSON đầy đủ rồi xem DevTools. Client dựng bàn từ dữ liệu mình biết và response.

**Đánh đổi:** cần fold/replay event phía client. Snapshot PlayerView có thể tiện khi history dài, nhưng phải thiết kế wire mới và test privacy; không gửi snapshot raw hiện tại. Không tự reveal sau SUNK/WIN. ViewSpec/B-06/browser test kiểm tra cả dữ liệu và DOM.

## 11. Một TVar GameState và commit batch cùng STM

Một submit đọc state → parse/step → encode toàn batch → kiểm tra chỗ → ghi state/queues trong cùng `atomically`. Parser/rule lỗi không ghi GameState; encode lỗi không ghi state/queue. Hai giao dịch xung đột revalidate trên state mới.

**Hiệu quả:** không lost update hoặc state đã bắn nhưng thiếu thông báo; TVar là một nguồn sự thật. Không IO trong STM vì transaction có thể chạy lại; send/log trong đó có thể lặp hoặc không rollback được.

**Phương án khác:** một MVar khóa game có thể đúng nếu state và queue/error cùng được xử lý exception-safe; STM thuận tiện ghép nhiều queue/kiểm tra. Single coordinator worker nhận command queue cũng phù hợp; thêm command buffer/supervisor nhưng giảm tranh STM. Hai TVar độc lập cho hai người vẫn cần transaction chung để xét lượt; MVP chọn một state nhỏ. CoordinatorSpec có race/state/frame checks.

## 12. MVar vẫn có vai trò vòng đời IO

Lobby MVar giữ socket registry, stopped/drained; readerDone/finished báo hoàn tất. Không giữ luật GameState trong MVar. `withAsync/link/race_`, bracket/finally quản lý child và propagate lỗi.

**Lợi ích:** ownership socket rõ, parent không thoát trước GAME_OVER drain; exception không để worker mồ côi. Windows blocking foreign socket cần shutdown/close để đánh thức trước join, chỉ timeout/cancel không luôn đủ.

**Đánh đổi:** có nhiều tín hiệu lifecycle phải test race. `forkIO` trần + ignore exception ít code nhưng dễ leak/đánh mất failure. Tự restart worker chưa phù hợp socket/trận đã đổi state: replay có thể lặp lệnh. Giám sát ở đây cleanup/propagate, không restart mọi lỗi như ví dụ supervisor loop. ServerSpec/C-05/C-06 kiểm tra kết thúc/ngoại lệ/cổng.

## 13. Một writer mỗi người, queue hữu hạn

Mỗi client có FIFO riêng, một writer gửi ngoài STM. Default TBQueue 128 phần tử, 126 chỗ thường, hai chỗ GAME_OVER và marker `Nothing`; capacity seam test tối thiểu 5 để chứa batch OK/START/TURN và terminal. Queue tính phần tử, không phải byte.

**Lợi ích:** byte không xen từ nhiều thread; client chậm không chặn writer đối thủ; queue dài không tăng vô hạn. 126 payload đầy cỡ 257 byte là khoảng 32.382 byte dữ liệu wire thường mỗi queue, chưa gồm overhead heap/socket/kernel. Đây không phải giới hạn toàn bộ RAM tiến trình.

**Phương án khác:** Chan/TQueue unbounded có thể OOM dưới flood; đổi writeTQueue sang writeTBQueue đơn thuần sẽ retry khi đầy, chặn commit/kết thúc. Thả frame âm thầm làm client mất state; đợi vô hạn không đáp ứng cleanup. MVP chọn kiểm tra batch trước và Quit client chậm. 128 là budget lựa chọn cho MVP, không kết quả benchmark throughput tối ưu.

## 14. Batch thiếu chỗ thì Quit đúng người nhận

Nếu một lệnh tạo frame cho cả hai mà queue P2 đầy, Quit P2 dù người gửi là P1. Nước gây tràn và frame gốc không commit. Lõi `step departing Quit previous` quyết định winner; terminal dùng phần chỗ dự phòng, slow flag đánh thức worker đóng socket ngoài STM.

Nếu cùng một batch khiến cả hai đầy, ưu tiên P1 rồi P2, cả hai socket bị đánh dấu chậm; P2 thắng theo Quit P1. Nếu hai transaction cạnh tranh, transaction commit kết thúc trước quyết định kết quả. Không mô tả quy tắc này là công bằng tuyệt đối; nó tạo hành vi xác định cho một trận hai người.

**Lợi ích:** không partial batch, không winner thứ hai khi EOF/finalizer đến sau Finished; không đợi drain socket hỏng để kết thúc. Test queue nhỏ/cổng đồng bộ/race 100 lần và TCP không đọc thật ở C-07/DK-08 kiểm chứng.

## 15. Client đợi TURN, không suy lượt từ HIT

Terminal InputStage và UI pending/ref chỉ quản lý thao tác. Kể cả nhận HIT/SUNK, quyền gửi phát tiếp theo theo TURN từ server. ERROR không thêm history; GAME_OVER vẫn hiển thị sau socket close. UI ref khóa click đồng bộ trước React render để tránh hai click nhanh.

**Lợi ích:** hiển thị nhất quán với lỗi/timeout/pause; không tự tiêu lượt. Optimistic shot update có thể làm UI nhanh ở game latency cao nhưng cần rollback/reconcile; ở Battleship lượt chậm không cần độ phức tạp đó. Unit/browser test có double-click, lỗi, hết trận và khóa bàn.

## 16. Bridge WebSocket–TCP giữ backend đã nghiệm thu

Trình duyệt dùng WebSocket, bridge dùng Node HTTP/net/ws và serve Vite dist cùng origin. Haskell vẫn TCP v1; một WS session giữ một TCP. Không đưa luật sang Node.

**Lợi ích:** tái sử dụng backend/terminal/test đã có; UI nhóm dùng React mà không viết lại Haskell thành HTTP framework. Đánh đổi thêm process, framing/metadata/lifecycle riêng. Haskell WebSocket trực tiếp là phương án hợp lệ khi thay transport từ đầu, nhưng đợt UI cần nối hợp đồng đang có và về sau user chốt Compose hai service. Không cần Nginx thứ ba cho HTTP nội bộ MVP.

## 17. Token/replay 5 phút thay nối lại như người mới

Token 32 byte random/64 hex gắn phiên TCP, không phải PlayerId tự khai. Bridge lưu PLACE **được OK** và frame chỉ của phiên, replay tối đa 4096 frame. Resume gắn WS mới, không gửi lại FIRE; timer cũ được hủy. Không ghi secret/token vào log.

**Lợi ích:** reload giữ danh tính/lịch sử; origin đổi dùng mã/fragment rồi UI xóa fragment. sessionStorage mỗi tab/origin giảm nhầm hai người cùng trình duyệt. Bridge chặn PLACE/FIRE khi có người mất WS; hết 5 phút gửi Quit lõi thật.

**Giới hạn:** token là quyền chiếm phiên, cần giữ riêng; fragment tránh gửi token trong HTTP tải trang nhưng WS query vẫn mang token, nên proxy logs phải bảo vệ nếu thêm proxy. HTTP LAN không mã hóa. RAM/session mất sau restart; lưu token/file/database và recovery state là thiết kế khác chưa có. Grace giữ TCP nên core không tự nhận biết WS mất; client TCP trực tiếp không được chính sách pause này.

## 18. Auto IP host, origin có TTL và file nguyên tử

Native bridge có thể tự đọc interface của host. Trong Docker, interface trong container không phải địa chỉ người chơi truy cập, nên PowerShell chạy trên Windows host chọn adapter và ghi origins v1. File 8 KiB/16 origin tối đa, poll 2 giây; TTL 10 giây, dung sai clock tương lai 2 giây. Dữ liệu sai/quá hạn bỏ allowlist LAN; localhost/phiên đang giữ không mất.

**Lợi ích:** chuyển Wi-Fi giữa trận không restart process; writer temp→flush→rename cùng thư mục tránh JSON nửa file. Mount **thư mục** read-only nhìn thấy rename, lock ngăn hai helper cùng ghi. Các lần retry Windows rename hữu hạn.

**Phương án khác:** IP cố định/Manual dễ vận hành mạng tĩnh nhưng trái yêu cầu tự lấy; restart bridge để đổi env mất token; dùng IP Docker gateway không phục vụ thiết bị LAN. mDNS/DNS là hướng giúp client không nhập IP mới, song cần router/client/platform hỗ trợ và task riêng. Auto chưa tự phân biệt VPN với Wi-Fi nếu không chọn interface; người vận hành chọn đúng adapter.

## 19. Phân biệt bind/internal/public và kiểm tra Origin/Host

`HOST/PORT` là listener web container, `WEB_PUBLIC_PORT/PUBLIC_ORIGIN` là URL host; `BATTLESHIP_TCP_HOST` DNS `haskell`. Allowlist nhận chính xác HTTP localhost/IPv4 và port public. Origin phải được phép và Host authority trùng Origin; reject trước TCP allocation. Không wildcard hoặc tin forwarded host chưa kiểm chứng.

**Lợi ích:** mapping 8081→8080 không bị validator từ chối; website origin khác không tùy ý dùng slot/resume. `0.0.0.0` là bind, không URL người chơi. Kiểm tra này không phải authentication/TLS hoặc firewall: client native có thể tự đặt header, static HTTP không dùng allowlist để xác thực tải trang. TLS/domain/IPv6 chưa được public-origin contract hỗ trợ; reverse proxy cần task thiết kế lại có chủ đích.

## 20. Multi-stage image, pin và non-root

Haskell build/test/runtime cùng Debian Bookworm; GHC 9.10.3/snapshot chốt. Web Node 24.21.0/pnpm 11.25.0, frozen lockfile. Runtime copy từ test stage để build không bỏ gate; Haskell UID 10001, web UID 1000. Dockerignore loại Git/env/log/Windows cache; docs/test cần cho contract vẫn có trong stage test.

**Hiệu quả:** không dùng binary Windows trên Linux; runtime chỉ binary + thư viện hệ thống hoặc bridge/dist/production dependency. `ldd` bắt thiếu thư viện động. Pin tag+digest giảm nền thay đổi, lockfile chốt dependency; vẫn cần chủ động cập nhật/security test về sau.

**Phương án khác:** single-stage dễ viết nhưng mang compiler/dev/cache vào runtime; scratch cần binary static và thư viện tương thích, chưa kiểm chứng. Một container cho hai process đòi supervisor khác và trái hợp đồng hai service. Docker cache làm build nhanh hơn nhưng không thay kiểm thử source sạch; không tuyên bố bit-for-bit reproducible.

## 21. Healthcheck không vào cổng chơi; restart no

Core marker xuất hiện sau listen và được dọn khi thoát; web GET /healthz không TCP. `depends_on: service_healthy` gate start; stop SIGTERM/grace 10 giây. Core thoát 0 sau trận, web giữ giao diện kết quả; mở trận mới start core, tạo token mới.

**Lợi ích:** probe không nhận P1/P2 rồi gây bỏ cuộc, không restart vô hạn sau ván thắng, shutdown có cleanup. Restart always phù hợp server phục vụ liên tục với lobby nhiều ván, nhưng MVP một ván cần người vận hành mở trận mới rõ ràng. Health file là readiness của listener, không chứng minh worker luôn khỏe; HTTP healthy không chứng minh core còn trận. Test nhiều probe trước pair chứng minh slot không mất.

## 22. Hspec + QuickCheck + integration thay chỉ demo tay

Hspec ghi expectation cụ thể. Generator độc lập enumerates finite candidate/length/grid, không lọc bằng placeFleet; property fleet kiểm tra 17 ô/ID/biên/không giao/permutation và coverage. View scripts qua step, oracle từ Event; private pair giữ kết quả công khai cả SUNK nhưng đổi thật hidden cells.

**Lợi ích:** lỗi biên không bị generator giấu, phản ví dụ có input/seed, lỗi timing có gate/deadline; test UI/container không bỏ qua luồng wire. Đánh đổi suite mạng/build chậm hơn unit; chọn gate theo phần đổi. Unit không thay browser/LAN test; demo tay không bao hết race/biên. QuickCheck không chứng minh toán học và generator không exhaust mọi fleet; regression cụ thể giữ lỗi tìm được.

## 23. Báo cáo theo bằng chứng, không gộp mốc

S-02/S-04 giữ lịch sử, report_final tổng hợp hiện tại. DK-08 ghi một máy/hai browser theo yêu cầu thay thế; không đổi thành hai thiết bị. Review nhóm cần cùng SHA, không lấy author Git hoặc số test làm xác nhận.

**Lợi ích:** người bảo vệ biết điều gì đã chạy/điều gì chưa; tránh đọc con số 815 cũ rồi tưởng suite hiện tại chỉ có 815, hoặc “web healthy” thành “trận đang mở”. Log/source SHA/phạm vi là căn cứ; không sửa log lịch sử khi docs đổi.
