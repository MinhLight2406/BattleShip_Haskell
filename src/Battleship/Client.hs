-- | D-02: one command per connection; no board rendering or interactive loop.
module Battleship.Client (ClientError (..), runClient, renderResponse, renderProtocolError) where

import Battleship.Protocol
import Battleship.Types
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Exception (Exception, IOException, bracket, catch, throwIO)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Network.Socket
  ( AddrInfo (..), Family (AF_INET), HostName, PortNumber,
    ShutdownCmd (ShutdownBoth), Socket, SocketType (Stream), close, connect,
    defaultHints, getAddrInfo, shutdown, socket, withSocketsDo )
import Network.Socket.ByteString (recv, sendAll)
import System.Timeout (timeout)

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
  withSocketsDo $ do
    addresses <- getAddrInfo (Just defaultHints { addrFamily = AF_INET, addrSocketType = Stream })
      (Just host) (Just (show port))
    case addresses of
      [] -> ioError (userError "D-02: no IPv4 address")
      address : _ -> bracket (socket (addrFamily address) Stream (addrProtocol address)) closeConnection $ \connection ->
        withDeadline connection $ do
          connect connection (addrAddress address)
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
  -- ponytail: one-shot demo deadline is 10 seconds. Make it configurable when
  -- the interactive client must wait for another player's placement/turn.
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
    shipName Carrier = "tàu sân bay"
    shipName Battleship = "thiết giáp hạm"
    shipName Cruiser = "tàu tuần dương"
    shipName Submarine = "tàu ngầm"
    shipName Destroyer = "tàu khu trục"
