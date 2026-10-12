{-# LANGUAGE CPP #-}
-- | Terminal presentation and input; wire data stays in Protocol.
module Battleship.Client
  ( ClientError (..), runClient, runPlacementClient, promptFleet
  , parsePlacementInput, parseFireInput, renderFleet, renderBoards, updatePlayerView
  , renderResponse, renderResponseFor, renderProtocolError
  ) where

import qualified Battleship.Board as Board
import Battleship.Protocol
import Battleship.Types
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (waitCatchSTM, withAsync)
import Control.Concurrent.STM
  ( atomically, newTQueueIO, orElse, readTQueue, retry, throwSTM, writeTQueue )
import Control.Exception (Exception, IOException, bracket, catch, finally, throwIO)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (ord, toUpper)
import GHC.IO.Handle.Internals (withHandle_)
import GHC.IO.Handle.Types (haInputNL, haOutputNL)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Network.Socket
  ( AddrInfo (..), Family (AF_INET), HostName, PortNumber,
    ShutdownCmd (ShutdownBoth), SockAddr, Socket, SocketType (Stream), close, connect,
    defaultHints, getAddrInfo, shutdown, socket, withSocketsDo )
import Network.Socket.ByteString (recv, sendAll)
import System.Timeout (timeout)
import System.IO
  ( BufferMode (NoBuffering), Handle, NewlineMode (NewlineMode), hFlush, hGetBuffering, hGetChar, hGetEcho,
    hGetLine, hIsEOF, hIsTerminalDevice, hPutStr, hPutStrLn, hSetBuffering,
    hSetEcho, hSetNewlineMode, hWaitForInput, noNewlineTranslation )
import System.IO.Error (isEOFError)
#ifdef mingw32_HOST_OS
import Data.Bits ((.&.), (.|.), complement)
import System.Win32.Console (eNABLE_ECHO_INPUT, eNABLE_LINE_INPUT, getConsoleMode, setConsoleMode)
import System.Win32.File
  ( closeHandle, createFile, fILE_SHARE_READ, fILE_SHARE_WRITE, gENERIC_READ, gENERIC_WRITE, oPEN_EXISTING )
#endif

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
renderFleet fleet = unlines ("Bàn của bạn (. = ô trống):" :
  renderGrid (\position -> Map.findWithDefault " ." position (fleetCells fleet)))

fleetCells :: Fleet -> Map.Map Coord String
fleetCells fleet = Map.fromList
  [(position, shipCode ship) | (ship, positions) <- Map.toList (fleetShips fleet), position <- Set.toList positions]

renderGrid :: (Coord -> String) -> [String]
renderGrid cell = "    A  B  C  D  E  F  G  H  I  J" :
  [padRow row ++ " " ++ unwords [cell (Coord column row) | column <- [1 .. boardSize]] | row <- [1 .. boardSize]]
  where
    padRow row = (if row < 10 then " " else "") ++ show row

-- | Render only the public projection. Unknown opponent cells remain unknown,
-- including after SUNK/WIN: no opponent layout is accepted or inferred here.
renderBoards :: PlayerView -> String
renderBoards view = unlines (zipWith beside own target ++
  ["Ký hiệu: CV/BB/CR/SB/DD = tàu mình; . = nước; ? = chưa bắn đối thủ.",
   "o = trượt; X = trúng; # = phát làm chìm; * = phát thắng. Ô X cũ giữ nguyên."])
  where
    own = "Bàn của bạn:" : renderGrid (\position ->
      maybe (maybe " ?" (Map.findWithDefault " ." position . fleetCells) (ownFleetView view)) mark
        (Map.lookup position (incomingShotsView view)))
    target = "Mục tiêu đối thủ:" : renderGrid (\position ->
      maybe " ?" mark (Map.lookup position (outgoingShotsView view)))
    beside left right = left ++ replicate (max 2 (36 - length left)) ' ' ++ right
    mark Miss = " o"
    mark Hit = " X"
    mark (Sunk _) = " #"
    mark Win = " *"

-- | Fold filtered wire events into the client's public data. Fleet identity
-- stays local; rejected input cannot add a shot or consume a turn here.
updatePlayerView :: Response -> PlayerView -> PlayerView
updatePlayerView response view = case response of
  WaitingOpponent -> view { viewPhase = Placing }
  Start owner -> view { viewPhase = Turn owner, opponentReady = True }
  TurnOf owner -> view { viewPhase = Turn owner, opponentReady = True }
  Shot position outcome -> view { outgoingShotsView = Map.insert position outcome (outgoingShotsView view) }
  Incoming position outcome -> view { incomingShotsView = Map.insert position outcome (incomingShotsView view) }
  GameOver winner reason -> view { viewPhase = Finished winner reason }
  _ -> view

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

-- | Send one confirmed PLACE, then play using server-authorized turns.
-- The 10-second deadline covers connection/handshake/PLACE acknowledgment,
-- not human input or waiting for another player.
runPlacementClient :: HostName -> PortNumber -> Handle -> Handle -> IO ()
runPlacementClient host port input output = do
  draft <- promptFleet input output
  case draft of
    Nothing -> hPutStrLn output "Đã hủy đặt tàu; chưa gửi đội tàu."
    Just placements -> do
      fleet <- either (ioError . userError . renderGameError) pure (Board.placeFleet placements)
      encoded <- fromProtocol (encodeCommand (PlaceFleet placements))
      withSocketAddress host port $ \connection address -> do
        buffer <- withDeadline connection $ do
          connect connection address
          (greeting, pending) <- readResponse connection ([], Right BS.empty)
          case greeting of
            Welcome player -> do
              display greeting
              sendAll connection encoded
              (response, next) <- readResponse connection pending
              case response of
                PlaceOK -> display response >> pure (Just (player, next))
                Rejected _ -> display response >> pure Nothing
                GameOver _ _ -> hPutStrLn output (renderResponseFor player response) >> pure Nothing
                _ -> throwIO (UnexpectedResponse response)
            Rejected ServerFull -> display greeting >> pure Nothing
            _ -> throwIO (UnexpectedResponse greeting)
        case buffer of
          Nothing -> pure ()
          Just (player, pending) -> playSession connection player fleet pending input output
  where
    display = hPutStrLn output . renderResponse

-- | Friendly input only: no player ID or fleet data is supplied by the user.
parseFireInput :: String -> Either String Command
parseFireInput input
  | length input > maxLineBytes = Left (renderProtocolError LineTooLong)
  | not (all (\character -> ord character <= 127) input) = Left "Tọa độ phải nằm trong A1..J10."
  | otherwise = case words (map toUpper input) of
      ["QUIT"] -> Right Quit
      [position] -> fire position
      ["FIRE", position] -> fire position
      _ -> Left "Nhập A1..J10 hoặc FIRE A1; QUIT để rời trận."
  where
    fire = either (Left . renderProtocolError) (Right . Fire) . parseCoord . BSC.pack

-- These are UI states, not a second implementation of the game's rules.
-- In particular, a HIT/SUNK does not authorize input until TURN arrives.
data InputStage = Waiting | YourTurn | AwaitShot Coord | AwaitTurn | Leaving
  deriving (Eq)

playSession :: Socket -> PlayerId -> Fleet -> ReceiveBuffer -> Handle -> Handle -> IO ()
playSession connection player fleet pending input output = withKeyboard input $ \echoInput -> do
  inbox <- newTQueueIO
  let receive buffer = do
        (response, next) <- readResponse connection buffer
        atomically (writeTQueue inbox response)
        case response of GameOver _ _ -> pure (); _ -> receive next
  withAsync (receive pending) $ \reader -> do
    let nextResponse = (Just <$> readTQueue inbox) `orElse` do
          result <- waitCatchSTM reader
          either throwSTM (const retry) result
        display response = hPutStrLn output (renderResponseFor player response) >> hFlush output
        boards view = hPutStr output (renderBoards view) >> hFlush output
        prompt = hPutStrLn output "Nhập A1..J10 hoặc FIRE A1; QUIT để rời trận:" >> hFlush output
        send command = fromProtocol (encodeCommand command) >>= sendAll connection
        loop stage view typed = do
          message <- atomically (nextResponse `orElse` if stage == YourTurn then pure Nothing else retry)
          case message of
            Just response -> (if echoInput && not (null typed) then hPutStrLn output "" else pure ()) >>
              let next = updatePlayerView response view in case response of
              GameOver _ _ -> boards next >> display response
              WaitingOpponent -> display response >> loop Waiting next ""
              Start P1 -> display response >> loop stage next typed
              TurnOf owner -> do
                case stage of
                  AwaitShot _ -> throwIO (UnexpectedResponse response)
                  Leaving -> loop Leaving next ""
                  _ -> do
                    display response
                    if owner == player then prompt >> loop YourTurn next typed
                    else loop Waiting next ""
              Incoming _ _ -> display response >> boards next >> loop stage next typed
              Shot coordinate _ -> case stage of
                AwaitShot expected | coordinate == expected ->
                  display response >> boards next >> loop AwaitTurn next ""
                _ -> throwIO (UnexpectedResponse response)
              Rejected fault -> case stage of
                AwaitShot _ -> do
                  display response
                  case fault of
                    WrongTurn owner -> do
                      display (TurnOf owner)
                      let corrected = updatePlayerView (TurnOf owner) next
                      if owner == player then prompt >> loop YourTurn corrected "" else loop Waiting corrected ""
                    NotReady -> display WaitingOpponent >> loop Waiting (updatePlayerView WaitingOpponent next) ""
                    GameFinished -> hPutStrLn output "Chờ thông báo kết thúc trận." >> hFlush output >> loop AwaitTurn next ""
                    _ -> prompt >> loop YourTurn next ""
                _ -> throwIO (UnexpectedResponse response)
              _ -> throwIO (UnexpectedResponse response)
            Nothing -> do
              -- Poll characters with a bounded wait instead of blocking on a
              -- whole line: GAME_OVER must remain visible during partial input.
              character <- pollCharacter input
              case character of
                Nothing -> loop stage view typed
                Just Nothing | null typed -> leave view
                Just Nothing -> submit view typed
                Just (Just value) | value == '\n' || value == '\r' -> do
                  echo "\n"
                  submit view typed
                Just (Just value) | value == '\b' || value == '\DEL' -> do
                  if null typed then pure () else echo "\b \b"
                  loop stage view (take (max 0 (length typed - 1)) typed)
                Just (Just value) -> do
                  if length typed > maxLineBytes then echo "\BEL" >> loop stage view typed else do
                    echo [value]
                    loop stage view (typed ++ [value])
        echo text = if echoInput then hPutStr output text >> hFlush output else pure ()
        leave view = do
          hPutStrLn output "Đang rời trận; chờ kết quả từ server."
          hFlush output
          send Quit
          loop Leaving view ""
        submit view typed = case parseFireInput typed of
          Left message -> hPutStrLn output message >> prompt >> loop YourTurn view ""
          Right Quit -> leave view
          Right (Fire coordinate)
            | Map.member coordinate (outgoingShotsView view) -> do
                display (Rejected (RepeatedShot coordinate))
                prompt
                loop YourTurn view ""
            | otherwise -> do
                send (Fire coordinate)
                hPutStrLn output "Đã gửi phát bắn; chờ phản hồi từ server."
                hFlush output
                loop (AwaitShot coordinate) view ""
          Right _ -> ioError (userError "Client: unexpected local command")
    let initialView = PlayerView player Placing (Just fleet) Map.empty Map.empty False
    (boards initialView >> hPutStrLn output "Đã đặt tàu. Chờ server bắt đầu trận; Ctrl+C để rời trận." >>
      hFlush output >> loop Waiting initialView "") `finally` closeConnection connection

-- Windows console readiness can report a key before a complete cooked line;
-- hGetChar would then block until Enter. Read keys directly for this session,
-- echo them in the UI, and restore the caller's console modes on every exit.
-- Files/pipes retain their buffering and do not need manual echo.
withKeyboard :: Handle -> (Bool -> IO a) -> IO a
withKeyboard input action = do
  terminal <- hIsTerminalDevice input
  if not terminal then action False else withConsoleInput $
    bracket (hGetBuffering input) (hSetBuffering input) $ \_ ->
      bracket (hGetEcho input) (hSetEcho input) $ \_ ->
        -- System.IO has no newline-mode getter; use base's handle lock to
        -- preserve the caller's exact mode rather than assume native CRLF.
        bracket (withHandle_ "Client keyboard" input $ \handle ->
          pure (NewlineMode (haInputNL handle) (haOutputNL handle))) (hSetNewlineMode input) $ \_ -> do
            hSetBuffering input NoBuffering
            hSetEcho input False
            -- A raw Enter is CR on Windows, not a cooked CRLF pair. The
            -- CRLF decoder would wait for the following key inside hGetChar.
            hSetNewlineMode input noNewlineTranslation
            action True

-- Use the attached input console, without taking ownership of the supplied
-- Haskell Handle. Native Windows line input must also be disabled explicitly.
withConsoleInput :: IO a -> IO a
#ifdef mingw32_HOST_OS
withConsoleInput action = bracket
  (createFile "CONIN$" (gENERIC_READ .|. gENERIC_WRITE) (fILE_SHARE_READ .|. fILE_SHARE_WRITE)
    Nothing oPEN_EXISTING 0 Nothing) closeHandle $ \console ->
      bracket (getConsoleMode console) (setConsoleMode console) $ \mode -> do
        setConsoleMode console (mode .&. complement (eNABLE_LINE_INPUT .|. eNABLE_ECHO_INPUT))
        action
#else
withConsoleInput = id
#endif

-- Nothing = no character yet; Just Nothing = EOF; Just (Just c) = input.
pollCharacter :: Handle -> IO (Maybe (Maybe Char))
pollCharacter input = (do
  ready <- hWaitForInput input 100
  if ready then Just . Just <$> hGetChar input else pure Nothing) `catch` eof
  where
    eof :: IOException -> IO (Maybe (Maybe Char))
    eof exception = if isEOFError exception then pure (Just Nothing) else throwIO exception

-- | Identity-aware presentation used by the interactive client. Protocol
-- constructors and the legacy one-command renderer keep their wire meaning.
renderResponseFor :: PlayerId -> Response -> String
renderResponseFor viewer response = renderResponse response ++ case response of
  TurnOf owner | owner == viewer -> " Đến lượt bạn bắn."
               | otherwise -> " Hãy chờ đối thủ; chưa được bắn. Ctrl+C để rời trận."
  WaitingOpponent -> " Chờ đối thủ đặt đủ tàu; chưa được bắn. Ctrl+C để rời trận."
  GameOver winner _ | winner == viewer -> " Bạn thắng! Trận đấu đã kết thúc."
                   | otherwise -> " Bạn thua. Trận đấu đã kết thúc."
  _ -> ""

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
