# Giao thức Battleship v1 — D-01

Đây là hợp đồng wire đã chốt cho một server, hai client, một trận theo R-01 và kiểu A-01. C/D triển khai theo grammar, thứ tự phản hồi và transcript dưới đây. Thay đổi không tương thích phải tăng phiên bản và cập nhật cả hai phía cùng test. Văn bản hiển thị tiếng Việt do client ánh xạ từ mã; wire không chứa câu thông báo tự do.

Đối chiếu với Types, Board A-02, hai Main, chủ sở hữu file và trạng thái xác nhận của cả nhóm tại [shared_contract.md](shared_contract.md), S-01 v2. Các xác nhận còn thiếu được ghi ở đó; wire vẫn là v1.

## 1. Kết nối và framing

- Dùng TCP; host/port cấu hình ở hai phía, cùng giá trị khi chạy demo. Giao thức không phụ thuộc số port.
- Server gán kết nối được nhận đầu tiên là P1, kết nối thứ hai là P2. Thông điệp đầu tiên cho mỗi slot là `WELCOME 1 P1` hoặc `WELCOME 1 P2`; client chờ WELCOME trước khi gửi lệnh. Không có handshake hay trường danh tính do client tự gửi.
- Client gặp phiên bản khác 1 phải báo không tương thích và đóng kết nối. Khi cả hai slot đã được gán, kết nối thứ ba chỉ nhận `ERROR SERVER_FULL` rồi bị đóng; không làm thay đổi trận của P1/P2. Không tái sử dụng slot đã ngắt kết nối.
- Mỗi frame chứa đúng một payload và kết thúc bằng LF (byte 0x0A). Encoder luôn phát LF. Receiver chấp nhận CRLF bằng cách bỏ đúng một CR (0x0D) ngay trước LF.
- **MAX_LINE_BYTES = 256**, tính trên byte payload trước LF và trước CR cuối nếu có. Cả lệnh và phản hồi chịu cùng giới hạn. Wire dùng UTF-8 nhưng grammar v1 chỉ gồm ASCII in được (0x20..0x7E); vì thế không cần đo số ký tự Unicode.
- Trong payload không có BOM, tab, NUL, CR, LF, chữ thường hoặc khoảng trắng đầu/cuối. Giữa token là đúng một space ASCII; không có space quanh `=`, `:`, `;`. Dòng rỗng là lệnh sai.
- TCP là byte stream: một lần recv có thể chỉ chứa một phần frame hoặc nhiều frame. Giữ phần chưa có LF, tách hết frame hoàn chỉnh theo thứ tự; không coi một recv là một lệnh. Trong lúc đọc, chỉ giữ tối đa 256 byte payload cộng một CR cuối có thể thuộc CRLF. Nếu byte tiếp theo khiến vượt giới hạn, xử lý LINE_TOO_LONG ngay, không đợi LF và không tiếp tục gom dòng quá dài.
- Với lệnh có LF nhưng sai grammar/ASCII, gửi `ERROR INVALID_COMMAND` (hoặc INVALID_COORDINATE theo mục 3), bỏ dòng đó và tiếp tục đọc dòng sau. Không gửi lệnh sai vào Rules.
- Với dòng quá dài: gửi `ERROR LINE_TOO_LONG` nếu còn gửi được rồi đóng socket vi phạm. Nếu nó thuộc P1/P2 và trận chưa kết thúc, việc đóng được xử lý riêng như bỏ cuộc; người còn lại nhận GAME_OVER OPPONENT_LEFT. Bộ đệm không được tăng vô hạn.
- EOF/lỗi socket: xử lý các frame đã nhận đủ LF trước EOF; phần cuối thiếu LF bị bỏ, không phải lệnh. Sau đó xử lý Quit của slot đó nếu trận chưa kết thúc. EOF sau một phát bắn thắng không được đổi người thắng/lý do đã lưu.
- Mỗi kết nối có một writer; queue của người nhận giữ thứ tự frame, không xen byte giữa hai thông điệp. Hai socket không có thứ tự thời gian chung. Coordinator tuần tự hóa/giao dịch hóa từng lệnh và tạo toàn bộ batch thông báo trước khi xử lý lệnh tiếp theo.
- Client có tối đa một lệnh chưa được phản hồi. PLACE hoàn tất ở OK PLACE hoặc ERROR; FIRE ở SHOT hoặc ERROR; QUIT ở GAME_OVER/EOF. GAME_OVER hoặc EOF kết thúc mọi lệnh đang chờ; client không đợi OK/SHOT sau đó. Client vẫn phải nhận thông báo bất đồng bộ trong lúc chờ. V1 không có request ID và không tự gửi lại FIRE khi chưa biết kết quả.

## 2. Token và tọa độ

Grammar dưới đây mô tả payload, không gồm LF; chữ trong dấu nháy là literal, `|` là lựa chọn, `{ ... }` là lặp từ 0 lần, các thành phần liền nhau là nối byte. Trong các bảng, `<...>` là chỗ thay token, `[...]` chỉ phần tùy trường hợp; không gửi dấu ngoặc trên wire. Không có token tiếng Việt.

```text
player      = "P1" | "P2"
ship        = "CV" | "BB" | "CR" | "SB" | "DD"
orientation = "H" | "V"
column      = "A" | "B" | "C" | "D" | "E" | "F" | "G" | "H" | "I" | "J"
row         = "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "10"
coord       = column row
placement   = ship "=" coord ":" orientation
placements  = placement { ";" placement }
digit       = "0" | nonzero-digit
nonzero-digit = "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9"
count       = "0" | nonzero-digit { digit }
outcome     = "MISS" | "HIT" | "SUNK" SP ship | "WIN"
reason      = "ALL_SHIPS_SUNK" | "OPPONENT_LEFT"
SP          = byte 0x20
```

- `A1 = Coord 1 1`, `J10 = Coord 10 10`. Không nhận A01, A0, A11, K1, a1, số âm hoặc dấu +.
- CV/BB/CR/SB/DD tương ứng Carrier/Battleship/Cruiser/Submarine/Destroyer và độ dài 5/4/3/3/2.
- H tăng cột, V tăng hàng. Không có trường độ dài tự chọn.
- count là số thập phân không dấu/không số 0 thừa, từ 0 đến 256; biểu diễn số placement thực tế của lỗi INVALID_FLEET_SIZE.

## 3. Client → server

| Payload | Command A-01 | Kết quả hợp lệ |
|---|---|---|
| `PLACE <placements>` | PlaceFleet [ShipPlacement] | OK PLACE, sau đó WAITING hoặc START/TURN |
| `FIRE <coord>` | Fire Coord | SHOT, INCOMING cho đối thủ, rồi TURN hoặc GAME_OVER |
| `QUIT` | Quit | GAME_OVER với người còn lại thắng, rồi đóng socket |

Parser chấp nhận thứ tự tàu bất kỳ và giữ nguyên danh sách, kể cả khi thiếu/trùng tàu. Không chuyển thành Map trước khi kiểm tra. A-02/Rules kiểm tra đúng năm ID, vượt biên/chồng tàu và giai đoạn; chấp nhận cả đội tàu hoặc từ chối toàn bộ. Encoder client chuẩn phát theo thứ tự CV;BB;CR;SB;DD.

Lỗi parser được chọn theo thứ tự:
1. Kiểm tra framing/byte limit trước.
2. Payload không thuộc ASCII in được hoặc sai tên lệnh/số token: INVALID_COMMAND.
3. PLACE phải có ít nhất một entry; entry phải có đúng một `=` và một `:`, ID/hướng hợp lệ. Duyệt entry trái sang phải, kiểm tra cấu trúc và ID, rồi tọa độ, rồi hướng. Lỗi cấu trúc/ID/hướng là INVALID_COMMAND; tọa độ sai là INVALID_COORDINATE.
4. FIRE có đúng một token tọa độ nhưng token đó sai quy ước A1..J10: INVALID_COORDINATE.

Ví dụ PLACE có bốn tàu đúng cú pháp vẫn parse được và bị luật từ chối bằng INVALID_FLEET_SIZE. Nhiều lỗi nghiệp vụ cùng lúc có thể được Rules chọn một lỗi; client phải xử lý tất cả mã ở mục 5, không phụ thuộc ưu tiên kiểm tra nghiệp vụ.

<!-- contract:commands -->
```text
PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H
PLACE DD=A5:H;SB=A4:H;CR=A3:H;BB=A2:H;CV=A1:H
FIRE A1
FIRE J10
QUIT
```

## 4. Server → client

| Payload | Người nhận / ý nghĩa |
|---|---|
| `WELCOME 1 <player>` | Slot mới: phiên bản và danh tính server gán |
| `OK PLACE` | Chỉ người đặt: đã lưu toàn bộ đội tàu, không được đặt lại |
| `WAITING OPPONENT` | Chỉ người vừa đặt xong nếu đối thủ chưa đặt, kể cả chưa kết nối |
| `START P1` | Cả hai: hai đội tàu hợp lệ, trận bắt đầu đúng một lần |
| `TURN <player>` | Cả hai: ai được bắn tiếp |
| `SHOT <coord> <outcome>` | Chỉ người bắn: phản hồi FIRE thành công |
| `INCOMING <coord> <outcome>` | Chỉ người bị bắn: cập nhật bàn của mình |
| `GAME_OVER <player> <reason>` | Các socket còn gửi được: người thắng và lý do kết thúc |
| `ERROR <code> [argument]` | Chỉ người gửi lệnh lỗi; transport error theo mục 1 |

SUNK bắt buộc kèm đúng một mã tàu; MISS/HIT/WIN không có mã tàu. START chỉ nhận P1. Không gửi nguyên Event bằng Show: ShotResolved phải được tách thành hai thông điệp cho hai người nhận.

<!-- contract:responses -->
```text
WELCOME 1 P1
WELCOME 1 P2
OK PLACE
WAITING OPPONENT
START P1
TURN P1
TURN P2
SHOT A6 HIT
SHOT J10 MISS
SHOT B10 SUNK DD
SHOT B10 WIN
INCOMING A6 HIT
INCOMING J10 MISS
INCOMING B10 SUNK DD
INCOMING B10 WIN
GAME_OVER P1 ALL_SHIPS_SUNK
GAME_OVER P2 OPPONENT_LEFT
ERROR INVALID_COMMAND
ERROR INVALID_COORDINATE
ERROR INVALID_FLEET_SIZE 4
ERROR MISSING_SHIP DD
ERROR DUPLICATE_SHIP CV
ERROR SHIP_OUT_OF_BOUNDS CV
ERROR SHIPS_OVERLAP A1
ERROR FLEET_ALREADY_PLACED
ERROR FLEETS_NOT_READY
ERROR NOT_YOUR_TURN P1
ERROR ALREADY_FIRED A6
ERROR GAME_FINISHED
ERROR LINE_TOO_LONG
ERROR SERVER_FULL
```

## 5. Mã lỗi cố định

| GameError / nguồn | Payload đầy đủ | Argument |
|---|---|---|
| InvalidCommand _ | `ERROR INVALID_COMMAND` | Không echo chuỗi lệnh thô |
| InvalidCoordinate _ | `ERROR INVALID_COORDINATE` | Không echo tọa độ ngoài grammar |
| InvalidFleetSize n | `ERROR INVALID_FLEET_SIZE <count>` | Số entry đã nhận |
| MissingShip ship | `ERROR MISSING_SHIP <ship>` | ID thiếu |
| DuplicateShip ship | `ERROR DUPLICATE_SHIP <ship>` | ID trùng |
| ShipOutOfBounds ship _ | `ERROR SHIP_OUT_OF_BOUNDS <ship>` | Chỉ ID; không gửi tọa độ vượt biên |
| ShipsOverlap coord | `ERROR SHIPS_OVERLAP <coord>` | Ô chồng trên đội tàu của người gửi |
| FleetAlreadyPlaced | `ERROR FLEET_ALREADY_PLACED` | Không |
| FleetsNotReady | `ERROR FLEETS_NOT_READY` | Không |
| NotYourTurn player | `ERROR NOT_YOUR_TURN <player>` | Người đang có lượt |
| AlreadyFired coord | `ERROR ALREADY_FIRED <coord>` | Ô người gửi đã bắn |
| GameAlreadyFinished | `ERROR GAME_FINISHED` | Không |
| Framer vượt giới hạn | `ERROR LINE_TOO_LONG` | Đóng socket vi phạm |
| Listener đã có hai slot | `ERROR SERVER_FULL` | Đóng socket thứ ba |

Hai mã transport cuối không thuộc GameError A-01. Client hiển thị câu tiếng Việt theo code/argument; không tách hoặc đoán ý nghĩa từ câu văn. ERROR nghiệp vụ/cú pháp không thay đổi trạng thái, không mất lượt và không broadcast cho đối thủ. Đóng socket do LINE_TOO_LONG là một sự kiện bỏ cuộc riêng sau lỗi transport.

Client nhận phản hồi sai grammar, dài quá mức hoặc mã lạ phải báo lỗi giao thức và đóng kết nối; không tự suy diễn hay tiếp tục dùng trạng thái không đáng tin cậy.

## 6. Thứ tự sự kiện, kết thúc và bí mật

| Event A-01 | Định tuyến wire |
|---|---|
| FleetAccepted p | OK PLACE cho p; thêm WAITING OPPONENT nếu phase mới vẫn Placing |
| GameStarted P1 | START P1 cho cả hai |
| ShotResolved p coord outcome | SHOT cho p; INCOMING cho otherPlayer p |
| TurnReady p | TURN p cho cả hai, kể cả khi lượt được giữ nguyên |
| GameEnded winner reason | GAME_OVER cho các kết nối còn gửi được |

Danh sách Event thành công của `step` có thứ tự: PLACE chưa đủ hai fleet trả `[FleetAccepted p]`; PLACE bắt đầu trận trả `[FleetAccepted p, GameStarted P1, TurnReady P1]`; FIRE chưa thắng trả `[ShotResolved p coord outcome, TurnReady nextPlayer]`; FIRE thắng trả `[ShotResolved p coord Win, GameEnded p AllShipsSunk]`; QUIT trước Finished trả `[GameEnded (otherPlayer p) OpponentLeft]`. WELCOME và ERROR do lớp kết nối/điều phối tạo, không nằm trong danh sách Event thành công.

- PLACE đầu tiên: người đặt nhận OK PLACE rồi WAITING OPPONENT. Người đặt thứ hai: nhận OK PLACE trước START; cả hai nhận START P1 rồi TURN P1. Không phát WAITING cho người thứ hai khi phase mới đã Turn.
- FIRE chưa thắng: người bắn nhận SHOT trước TURN; người bị bắn nhận INCOMING trước TURN. MISS chuyển sang đối thủ; HIT/SUNK giữ người bắn.
- FIRE thắng: SHOT/INCOMING WIN trước GAME_OVER ALL_SHIPS_SUNK; không phát TURN sau đó.
- QUIT/EOF/lỗi socket trước khi kết thúc: winner = otherPlayer người rời trận, reason = OPPONENT_LEFT. QUIT không có OK QUIT. Server có thể gửi GAME_OVER cả cho người chủ động QUIT nếu socket còn gửi được. Nếu P1 rời trước khi P2 kết nối, trận cũng kết thúc, winner logic là P2 và không nhận người thay thế.
- Khi đã Finished, không đổi winner/reason hoặc phát GAME_OVER lần hai vì các EOF tiếp theo. Lệnh đã nhận nhưng được xét sau Finished trả ERROR GAME_FINISHED nếu socket còn mở. Sau khi đẩy hết thông báo kết thúc, server đóng hai socket và dừng trận; client không chờ phản hồi sau EOF.
- V1 không có VIEW, reconnect hoặc truy vấn snapshot. Client giữ đội tàu đã được OK PLACE, outgoing/incoming shot history và phase từ các event để dựng bàn. PlayerView của A-01 vẫn là hợp đồng lọc dữ liệu phía server; không gửi Show GameState/Fleet đối thủ trên wire.
- Chỉ vị trí đã bắn được gửi trong SHOT/INCOMING; chỉ ID tàu đã chìm được gửi trong SUNK. Lỗi đặt tàu chỉ trả cho người đặt. Không chuyển tiếp payload PLACE cho đối thủ.
- Cần bảo toàn thứ tự theo từng người nhận, không cần hai client nhìn thấy broadcast cùng một thời điểm.

## 7. Transcript nghiệm thu

Các prefix `C1 -> S:`, `S -> C1:` là chú thích hướng truyền, không phải byte gửi. C1 mang P1, C2 mang P2; mỗi payload dưới đây thực sự có LF ở cuối. Không có chuỗi "[CONNECT]" trên wire.

### 7.1. Kết nối → đặt tàu → phát bắn đầu tiên

C1 kết nối trước; C2 kết nối sau khi C1 đã đặt. P1 đặt tàu ở hàng 1..5; P2 đặt tàu ở hàng 6..10. A6 nằm trên CV của P2 nên phát bắn đầu tiên là HIT và P1 giữ lượt.

<!-- transcript:connect-first-shot -->
```text
S -> C1: WELCOME 1 P1
C1 -> S: PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H
S -> C1: OK PLACE
S -> C1: WAITING OPPONENT
S -> C2: WELCOME 1 P2
C2 -> S: PLACE CV=A6:H;BB=A7:H;CR=A8:H;SB=A9:H;DD=A10:H
S -> C2: OK PLACE
S -> C1: START P1
S -> C2: START P1
S -> C1: TURN P1
S -> C2: TURN P1
C1 -> S: FIRE A6
S -> C1: SHOT A6 HIT
S -> C2: INCOMING A6 HIT
S -> C1: TURN P1
S -> C2: TURN P1
```

### 7.2. Lệnh lỗi không mất lượt

Tiếp nối 7.1: P1 đang có lượt, A6 đã bắn. P2 sai lượt; P1 sai tọa độ, bắn lặp và sai mã lệnh rồi thử lại B6 hợp lệ. Mỗi lỗi chỉ phản hồi người gửi.

<!-- transcript:errors-and-retry -->
```text
C2 -> S: FIRE J10
S -> C2: ERROR NOT_YOUR_TURN P1
C1 -> S: FIRE K1
S -> C1: ERROR INVALID_COORDINATE
C1 -> S: FIRE A6
S -> C1: ERROR ALREADY_FIRED A6
C1 -> S: fire B6
S -> C1: ERROR INVALID_COMMAND
C1 -> S: FIRE B6
S -> C1: SHOT B6 HIT
S -> C2: INCOMING B6 HIT
S -> C1: TURN P1
S -> C2: TURN P1
```

### 7.3. MISS đổi lượt

Tiếp nối trạng thái P1 có lượt ở 7.1/7.2; J10 không có tàu P2.

<!-- transcript:miss -->
```text
C1 -> S: FIRE J10
S -> C1: SHOT J10 MISS
S -> C2: INCOMING J10 MISS
S -> C1: TURN P2
S -> C2: TURN P2
```

### 7.4. SUNK vẫn giữ lượt

Fixture riêng: P1 có lượt, DD của P2 ở A10/B10 đã bị trúng A10, chưa bắn B10, còn tàu khác chưa chìm.

<!-- transcript:sunk -->
```text
C1 -> S: FIRE B10
S -> C1: SHOT B10 SUNK DD
S -> C2: INCOMING B10 SUNK DD
S -> C1: TURN P1
S -> C2: TURN P1
```

### 7.5. WIN không có lượt tiếp theo

Fixture riêng: P1 có lượt, đã trúng 16 ô tàu P2, chỉ B10 còn lại.

<!-- transcript:win -->
```text
C1 -> S: FIRE B10
S -> C1: SHOT B10 WIN
S -> C2: INCOMING B10 WIN
S -> C1: GAME_OVER P1 ALL_SHIPS_SUNK
S -> C2: GAME_OVER P1 ALL_SHIPS_SUNK
```

### 7.6. Chủ động rời trận, ngắt kết nối và kết nối thứ ba

QUIT ở phase chưa kết thúc:

<!-- transcript:quit -->
```text
C2 -> S: QUIT
S -> C1: GAME_OVER P1 OPPONENT_LEFT
S -> C2: GAME_OVER P1 OPPONENT_LEFT
```

Nếu C2 mất kết nối bất thường, chỉ còn thông điệp dưới đây cho C1:

<!-- transcript:disconnect -->
```text
S -> C1: GAME_OVER P1 OPPONENT_LEFT
```

C3 kết nối khi hai slot đã được gán; C3 không nhận WELCOME và không được cấp PlayerId:

<!-- transcript:server-full -->
```text
S -> C3: ERROR SERVER_FULL
```

## 8. Kiểm tra hợp đồng D-01 và codec D-02

`test/ProtocolSpec.hs` gọi API production trong `Battleship.Protocol` để kiểm tra grammar/framing, tọa độ, ánh xạ mã lỗi A-01, định tuyến Event và các block transcript ngay trong tài liệu này. Các golden vectors độc lập với encoder; round-trip kiểm tra thêm mọi loại phản hồi và lệnh hợp lệ. `ClientSpec` dùng TCP thật với C-02 và peer có kịch bản; `IntegrationSpec` chạy executable client để xác nhận giao tiếp và output tiếng Việt UTF-8.

```sh
stack test --test-arguments="--match D-01"
stack test --ghc-options=-Werror --test-arguments="--match D-02"
```

Giữ các marker HTML để test tìm đúng block; thay đổi transcript/grammar phải cập nhật test và phiên bản nếu không tương thích. Coordinator C-03 đã nối server vào Rules thật. CoordinatorSpec kiểm tra TCP từ kết nối → đặt tàu → bắn đầu, lỗi/retry, Miss/chuyển lượt, Sunk/Win, EOF sau thắng và lệnh đồng thời. Test codec và test TCP là hai lớp nghiệm thu riêng; client D-02 vẫn chỉ gửi một lệnh rồi đóng.

```sh
stack test --ghc-options=-Werror --test-arguments="--match C-03"
```

## 9. API production D-02

`Battleship.Protocol` dùng `ByteString` nghiêm ngặt. Parser nhận payload **không có LF/CRLF**; encoder trả frame hoàn chỉnh **có LF**. Reader TCP phải gọi `feedFrames` trước parser, không đưa nguyên một chunk `recv` vào parser.

```haskell
parseCommand :: ByteString -> Either ProtocolError Command
encodeCommand :: Command -> Either ProtocolError ByteString
parseResponse :: ByteString -> Either ProtocolError Response
encodeResponse :: Response -> Either ProtocolError ByteString
feedFrames :: ByteString -> ByteString
           -> ([ByteString], Either ProtocolError ByteString)
wireError :: GameError -> WireError
routeEvent :: Phase -> Event -> [(PlayerId, Response)]
encodeEvent :: Phase -> Event -> Either ProtocolError [(PlayerId, ByteString)]
```

- `ProtocolError` phân biệt quá dài, sai cấu trúc, tọa độ lệnh sai và phiên bản không hỗ trợ. Kiểm tra độ dài trước grammar; chỉ nhận ASCII có thể in. `parseCoord`/`encodeCoord` dùng A1..J10, không có terminator.
- `feedFrames pending chunk` trả các payload hoàn chỉnh theo thứ tự và buffer còn lại hoặc lỗi. Nếu frame sau quá dài, các frame trước vẫn được trả để xử lý trước lỗi. Buffer giữ tối đa 256 byte, hoặc 257 khi byte cuối là CR chờ LF. EOF không tạo frame cho phần thiếu LF.
- Parser PLACE giữ nguyên danh sách/thứ tự/trùng ID; Board/Rules chịu trách nhiệm count, chiều dài, vượt biên và chồng lấn. Encoder sắp theo CV/BB/CR/SB/DD, giữ các entry trùng/thiếu; PLACE rỗng không có biểu diễn wire hợp lệ. Vì có chuẩn hóa thứ tự, round-trip PLACE so với danh sách đã sắp xếp.
- `Response` mô tả thông điệp trên wire, khác `Event` nội bộ: một ShotResolved tạo SHOT và INCOMING. `WireError` chỉ chứa tham số thực sự truyền, không dựng Coord giả cho lỗi không gửi tọa độ và không echo debug string của GameError. Không encode GameState/Fleet đối thủ.
- `routeEvent` nhận **phase mới sau step** để chỉ thêm WAITING khi còn Placing. Broadcast liệt kê hai người nhận logic; Coordinator giữ thứ tự Event, Server lọc theo registry và đóng socket nếu send thất bại. Encoder từ chối tọa độ raw ngoài bàn hoặc START P2.

`Battleship.Client.runClient :: HostName -> PortNumber -> Command -> (Response -> IO ()) -> IO ()` kiểm tra lệnh trước khi kết nối, chờ WELCOME v1 rồi gửi một frame. ERROR SERVER_FULL trước WELCOME được hiển thị mà không gửi lệnh. Callback nhận các response hợp lệ; kết thúc trên OK PLACE/SHOT tương ứng lệnh, ERROR hoặc GAME_OVER. Các frame hoàn chỉnh đã nhận cùng chunk được kiểm tra/hiển thị tiếp; client không chờ thêm frame sau phản hồi kết thúc một lệnh. EOF trước phản hồi, sai handshake, SHOT khác tọa độ và dữ liệu sai là lỗi; bracket đóng socket ở mọi đường thoát.

Client có deadline 10 giây cho connect/handshake/gửi/đọc; watchdog đóng socket để đánh thức I/O Windows. Đây là khung một lệnh, chưa dùng cho chờ đối thủ trong trận tương tác lâu. CLI dùng localhost, port mặc định 4000, hiển thị tiếng Việt UTF-8; không gửi văn bản tiếng Việt qua TCP.

## 10. Client đặt tàu D-03 — wire vẫn v1

`Client.runPlacementClient :: HostName -> PortNumber -> Handle -> Handle -> IO ()` dùng promptFleet nhập/sửa/xem trước offline; chỉ sau GUI mới kết nối. `parsePlacementInput :: ShipId -> String -> Either String ShipPlacement` nhận cú pháp thân thiện A1 H/V, kiểm tra qua API Board public; `renderFleet :: Fleet -> String` chỉ in fleet của mình. Không gửi câu tiếng Việt, GUI/SUA/HUY hoặc preview lên TCP.

Sau WELCOME, gửi đúng một PLACE đã được Board.placeFleet kiểm tra và Protocol.encodeCommand encode. OK PLACE hoàn tất request nhưng không đóng socket: client tiếp tục nhận các thông báo bất đồng bộ cho đến GAME_OVER, Ctrl+C hoặc lỗi/EOF. Connect/handshake/chờ OK có deadline 10 giây; thời gian nhập và chờ đối thủ sau OK không bị giới hạn đó. SERVER_FULL trước WELCOME không gửi PLACE. ERROR/GAME_OVER trong lúc chờ OK kết thúc request; malformed/ACK lặp/SHOT khi chưa gửi FIRE bị từ chối. D-02 runClient vẫn là API một lệnh rồi đóng.

ClientMain hỗ trợ mặc định hoặc `--place [PORT]` cho D-03, `[PORT] "COMMAND"` cho D-02. D-03 chưa nhập FIRE; không cần đổi grammar, mã lỗi, kiểu miền hoặc version. ClientSpec/IntegrationSpec kiểm tra tương tác qua handle UTF-8, TCP thật/scripted peer và executable với stdin pipe.
