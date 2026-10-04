-- | D-02 one-shot transport and D-03 guided placement of the player's own fleet.
module Battleship.Client
  ( ClientError (..), runClient, runPlacementClient, promptFleet
  , parsePlacementInput, renderFleet, renderResponse, renderProtocolError
  ) where

import qualified Battleship.Board as Board
import Battleship.Protocol
import Battleship.Types
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Exception (Exception, IOException, bracket, catch, finally, throwIO)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (ord, toUpper)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Network.Socket
  ( AddrInfo (..), Family (AF_INET), HostName, PortNumber,
    ShutdownCmd (ShutdownBoth), SockAddr, Socket, SocketType (Stream), close, connect,
    defaultHints, getAddrInfo, shutdown, socket, withSocketsDo )
import Network.Socket.ByteString (recv, sendAll)
import System.Timeout (timeout)
import System.IO (Handle, hFlush, hGetLine, hIsEOF, hPutStr, hPutStrLn)

data ClientError
  = ClientProtocolError ProtocolError | UnexpectedResponse Response
  | UnexpectedEOF | RequestTimeout
  deriving (Eq, Show)

instance Exception ClientError

-- | Validate before connecting, wait for WELCOME v1, send exactly one command,
-- then deliver responses until its OK/SHOT/ERROR/GAME_OVER. SERVER_FULL before
-- WELCOME is delivered without sending anything. All exit paths close socket.
runClient :: HostName -> PortNumber -> Command -> (Response -> IO ()) -> IO ()
runClient host port command onResponse = do
  encoded <- fromProtocol (encodeCommand command)
  withSocketAddress host port $ \connection address ->
        withDeadline connection $ do
          connect connection address
          (first, buffer) <- readResponse connection ([], Right BS.empty)
          case first of
            Welcome _ -> do
              onResponse first
              sendAll connection encoded
              replies connection buffer
            Rejected ServerFull -> onResponse first >> drain buffer
            _ -> throwIO (UnexpectedResponse first)
  where
    replies connection buffer = do
      (response, next) <- readResponse connection buffer
      validateReply response
      onResponse response
      if complete response then drain next else replies connection next
    -- Validate/deliver complete frames already received with the reply; a bad
    -- trailing frame must not be silently ignored just because OK/SHOT arrived.
    drain ([], Left fault) = throwIO (ClientProtocolError fault)
    drain ([], Right _) = pure ()
    drain (payload : rest, pending) = do
      response <- fromProtocol (parseResponse payload)
      validateReply response
      onResponse response
      drain (rest, pending)
    validateReply response = case response of
      Welcome _ -> throwIO (UnexpectedResponse response)
      PlaceOK -> case command of PlaceFleet _ -> pure (); _ -> throwIO (UnexpectedResponse response)
      Shot coordinate _ -> case command of
        Fire expected | coordinate == expected -> pure ()
        _ -> throwIO (UnexpectedResponse response)
      _ -> pure ()
    complete (Rejected _) = True
    complete (GameOver _ _) = True
    complete PlaceOK = case command of PlaceFleet _ -> True; _ -> False
    complete (Shot _ _) = case command of Fire _ -> True; _ -> False
    complete _ = False

-- | Friendly local syntax; wire grammar remains unchanged. Validate geometry
-- with the same Board implementation used by the server, not copied rules.
parsePlacementInput :: ShipId -> String -> Either String ShipPlacement
parsePlacementInput ship input
  | not (all (\character -> ord character <= 127) input) = Left "Tọa độ/hướng dùng A1..J10 và H hoặc V."
  | otherwise = case words (map toUpper input) of
      [position, direction] -> do
        start <- either (Left . renderProtocolError) Right (parseCoord (BSC.pack position))
        orientation <- case direction of
          "H" -> Right Horizontal
          "V" -> Right Vertical
          _ -> Left "H = ngang, V = dọc. Ví dụ: A1 H."
        let placement = ShipPlacement ship start orientation
        _ <- either (Left . renderGameError) Right (Board.shipCells placement)
        pure placement
      _ -> Left "Nhập tọa độ đầu và hướng, ví dụ: A1 H."

-- | No opponent data is accepted by this renderer. Fleet is already checked.
renderFleet :: Fleet -> String
renderFleet fleet = unlines $
  "Bàn của bạn (. = ô trống):" : "    A  B  C  D  E  F  G  H  I  J" :
  [padRow row ++ " " ++ unwords [Map.findWithDefault " ." (Coord column row) cells |
                                 column <- [1 .. boardSize]] | row <- [1 .. boardSize]]
  where
    cells = Map.fromList [(position, shipCode ship) | (ship, positions) <- Map.toList (fleetShips fleet),
                                                   position <- Set.toList positions]
    padRow row = (if row < 10 then " " else "") ++ show row

-- | Build/edit a draft offline. EOF/HUY cancels without opening a socket;
-- only explicit GUI after preview returns a complete Board-validated request.
promptFleet :: Handle -> Handle -> IO (Maybe FleetPlacement)
promptFleet input output = do
  hPutStrLn output "ĐẶT ĐỘI TÀU CỦA BẠN — bàn 10×10 (A1..J10)."
  hPutStrLn output "Nhập từng tàu bằng: tọa độ đầu H/V, ví dụ A1 H."
  hPutStrLn output "H = ngang sang phải; V = dọc xuống dưới. Không chồng/vượt biên; được chạm cạnh."
  hPutStrLn output "Năm tàu: CV=5, BB=4, CR=3, SB=3, DD=2 ô. HUY hoặc hết input để hủy."
  collect [] [minBound .. maxBound]
  where
    ask message = do
      hPutStr output message
      hFlush output
      eof <- hIsEOF input
      if eof then pure Nothing else do
        line <- hGetLine input
        pure (if words (map toUpper line) == ["HUY"] then Nothing else Just line)
    choose draft ship = do
      answer <- ask (shipCode ship ++ " — " ++ shipName ship ++ " (" ++ show (shipLength ship) ++ " ô), nhập A1 H: ")
      case answer of
        Nothing -> pure Nothing
        Just line -> case do
          placement <- parsePlacementInput ship line
          positions <- either (Left . renderGameError) Right (Board.shipCells placement)
          previous <- either (Left . renderGameError) Right (traverse Board.shipCells draft)
          case Set.lookupMin (Set.intersection positions (Set.unions previous)) of
            Just position -> Left (renderGameError (ShipsOverlap position))
            Nothing -> Right placement of
              Left message -> hPutStrLn output message >> choose draft ship
              Right placement -> pure (Just placement)
    collect draft [] = review draft
    collect draft (ship : rest) = do
      selected <- choose draft ship
      case selected of
        Nothing -> pure Nothing
        Just placement -> collect (draft ++ [placement]) rest
    review draft = case Board.placeFleet draft of
      Left fault -> hPutStrLn output (renderGameError fault) >> collect [] [minBound .. maxBound]
      Right fleet -> do
        hPutStr output (renderFleet fleet)
        answer <- ask "GUI để gửi; SUA CV/BB/CR/SB/DD để sửa một tàu; HUY để hủy: "
        case fmap (words . map toUpper) answer of
          Nothing -> pure Nothing
          Just ["GUI"] -> pure (Just draft)
          Just ["SUA", code] -> case lookup code [(shipCode ship, ship) | ship <- [minBound .. maxBound]] of
            Just ship -> do
              selected <- choose (filter ((/= ship) . placementShip) draft) ship
              case selected of
                Nothing -> pure Nothing
                Just placement -> review (map (\old -> if placementShip old == ship then placement else old) draft)
            Nothing -> hPutStrLn output "Mã tàu phải là CV, BB, CR, SB hoặc DD." >> review draft
          _ -> hPutStrLn output "Chọn GUI, SUA <mã tàu> hoặc HUY." >> review draft

-- | Send one confirmed PLACE, then retain the socket for asynchronous events.
-- The 10-second deadline covers connection/handshake/PLACE acknowledgment,
-- not human input or waiting for another player. Firing input belongs to D-04.
runPlacementClient :: HostName -> PortNumber -> Handle -> Handle -> IO ()
runPlacementClient host port input output = do
  draft <- promptFleet input output
  case draft of
    Nothing -> hPutStrLn output "Đã hủy đặt tàu; chưa gửi đội tàu."
    Just placements -> do
      encoded <- fromProtocol (encodeCommand (PlaceFleet placements))
      withSocketAddress host port $ \connection address -> do
        buffer <- withDeadline connection $ do
          connect connection address
          (greeting, pending) <- readResponse connection ([], Right BS.empty)
          case greeting of
            Welcome _ -> do
              display greeting
              sendAll connection encoded
              (response, next) <- readResponse connection pending
              case response of
                PlaceOK -> display response >> pure (Just next)
                Rejected _ -> display response >> pure Nothing
                GameOver _ _ -> display response >> pure Nothing
                _ -> throwIO (UnexpectedResponse response)
            Rejected ServerFull -> display greeting >> pure Nothing
            _ -> throwIO (UnexpectedResponse greeting)
        case buffer of
          Nothing -> pure ()
          Just pending -> do
            hPutStrLn output "Đã đặt tàu. Giữ kết nối để nhận thông báo; Ctrl+C để rời trận."
            -- Wait in a supervisor: cancellation closes the socket before
            -- withAsync joins its reader, waking blocking Windows recv.
            withAsync (listenForEnd connection pending) $ \reader ->
              wait reader `finally` closeConnection connection
  where
    display = hPutStrLn output . renderResponse
    listenForEnd connection buffer = do
      (response, next) <- readResponse connection buffer
      case response of
        GameOver _ _ -> display response
        WaitingOpponent -> continue response next
        Start P1 -> continue response next
        TurnOf _ -> continue response next
        Incoming _ _ -> continue response next
        _ -> throwIO (UnexpectedResponse response)
      where continue response next = display response >> listenForEnd connection next

withSocketAddress :: HostName -> PortNumber -> (Socket -> SockAddr -> IO a) -> IO a
withSocketAddress host port action = withSocketsDo $ do
  addresses <- getAddrInfo (Just defaultHints { addrFamily = AF_INET, addrSocketType = Stream })
    (Just host) (Just (show port))
  case addresses of
    [] -> ioError (userError "Client: no IPv4 address")
    address : _ -> bracket (socket (addrFamily address) Stream (addrProtocol address)) closeConnection $ \connection ->
      action connection (addrAddress address)

renderGameError :: GameError -> String
renderGameError = renderResponse . Rejected . wireError

shipCode :: ShipId -> String
shipCode Carrier = "CV"
shipCode Battleship = "BB"
shipCode Cruiser = "CR"
shipCode Submarine = "SB"
shipCode Destroyer = "DD"

shipName :: ShipId -> String
shipName Carrier = "tàu sân bay"
shipName Battleship = "thiết giáp hạm"
shipName Cruiser = "tàu tuần dương"
shipName Submarine = "tàu ngầm"
shipName Destroyer = "tàu khu trục"

type ReceiveBuffer = ([BS.ByteString], Either ProtocolError BS.ByteString)

readResponse :: Socket -> ReceiveBuffer -> IO (Response, ReceiveBuffer)
readResponse _ (payload : rest, pending) = do
  response <- fromProtocol (parseResponse payload)
  pure (response, (rest, pending))
readResponse _ ([], Left fault) = throwIO (ClientProtocolError fault)
readResponse connection ([], Right pending) = do
  chunk <- recv connection (maxLineBytes + 2 - BS.length pending)
  if BS.null chunk then throwIO UnexpectedEOF
  else readResponse connection (feedFrames pending chunk)

fromProtocol :: Either ProtocolError a -> IO a
fromProtocol = either (throwIO . ClientProtocolError) pure

withDeadline :: Socket -> IO a -> IO a
withDeadline connection action =
  -- Used only for bounded network requests, never for human input or the
  -- D-03 listener after OK PLACE, which must allow the opponent to take time.
  withAsync (threadDelay 10000000 >> closeConnection connection) $ \_ -> do
    result <- timeout 10000000 action
    maybe (throwIO RequestTimeout) pure result

closeConnection :: Socket -> IO ()
closeConnection connection = do
  shutdown connection ShutdownBoth `catch` ignoreIOException
  close connection
  where
    ignoreIOException :: IOException -> IO ()
    ignoreIOException _ = pure ()

renderProtocolError :: ProtocolError -> String
renderProtocolError LineTooLong = "Dòng vượt quá giới hạn 256 byte."
renderProtocolError InvalidMessage = "Thông điệp sai định dạng giao thức."
renderProtocolError InvalidCoordinateToken = "Tọa độ phải nằm trong A1..J10."
renderProtocolError UnsupportedVersion = "Phiên bản giao thức không tương thích."

renderResponse :: Response -> String
renderResponse response = case response of
  Welcome player -> "Bạn là " ++ playerName player ++ "."
  PlaceOK -> "Đã nhận đội tàu."
  WaitingOpponent -> "Đang chờ đối thủ."
  Start player -> "Trận đấu bắt đầu; " ++ playerName player ++ " bắn trước."
  TurnOf player -> "Lượt của " ++ playerName player ++ "."
  Shot coordinate outcome -> "Bạn bắn " ++ coordinateName coordinate ++ ": " ++ outcomeName outcome ++ "."
  Incoming coordinate outcome -> "Đối thủ bắn " ++ coordinateName coordinate ++ ": " ++ outcomeName outcome ++ "."
  GameOver player reason -> playerName player ++ " thắng: " ++
    case reason of AllShipsSunk -> "đã chìm toàn bộ tàu đối thủ."; OpponentLeft -> "đối thủ đã rời trận."
  Rejected err -> "Lỗi: " ++ case err of
    BadCommand -> "lệnh không hợp lệ."
    BadCoordinate -> "tọa độ không hợp lệ."
    FleetSize count -> "cần đúng năm tàu, đã nhận " ++ show count ++ "."
    Missing ship -> "thiếu " ++ shipName ship ++ "."
    Duplicate ship -> "trùng " ++ shipName ship ++ "."
    OutOfBounds ship -> shipName ship ++ " vượt mép bàn."
    Overlap coordinate -> "tàu chồng lên nhau tại " ++ coordinateName coordinate ++ "."
    AlreadyPlaced -> "đội tàu đã được đặt."
    NotReady -> "hai đội tàu chưa sẵn sàng."
    WrongTurn player -> "đang là lượt của " ++ playerName player ++ "."
    RepeatedShot coordinate -> "đã bắn " ++ coordinateName coordinate ++ "."
    GameFinished -> "trận đấu đã kết thúc."
    TooLong -> "dòng vượt quá giới hạn 256 byte."
    ServerFull -> "server đã đủ hai người chơi."
  where
    playerName P1 = "Người chơi 1"
    playerName P2 = "Người chơi 2"
    coordinateName = either (const "?") BSC.unpack . encodeCoord
    outcomeName Miss = "trượt"
    outcomeName Hit = "trúng"
    outcomeName (Sunk ship) = "chìm " ++ shipName ship
    outcomeName Win = "thắng"
