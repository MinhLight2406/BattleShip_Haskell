module ClientSpec (spec) where

import Battleship.Client
import qualified Battleship.Board as Board
import Battleship.Protocol
import Battleship.Types
import qualified Battleship.View as View
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, wait, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (IOException, bracket, catch, finally, try)
import Control.Monad (foldM, forM_, void)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Foreign.Marshal.Alloc (allocaBytes)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import RulesSpec (b04Cases, b04Trace)
import Network.Socket
  ( Family (AF_INET), PortNumber, ShutdownCmd (ShutdownBoth), SockAddr (SockAddrInet),
    Socket, SocketType (Stream), accept, bind, close, defaultProtocol,
    listen, recvBufNoWait, shutdown, socket, socketPort, tupleToHostAddress, withSocketsDo )
import Network.Socket.ByteString (sendAll)
import ServerSpec (await, expectClosed, expectLine, withClient, withServer)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (Handle, SeekMode (AbsoluteSeek), hClose, hFlush, hGetContents', hPutStr, hSeek, hSetEncoding, openTempFile, utf8)
import Test.Hspec (Spec, anyIOException, describe, it, shouldBe, shouldSatisfy, shouldThrow)

spec :: Spec
spec = do
  oneShotSpec
  placementSpec
  firingSpec
  boardsSpec

oneShotSpec :: Spec
oneShotSpec = describe "D-02 client" $ do
  it "sends QUIT after WELCOME P1 and reads GAME_OVER from C-02" $
    withServer $ \port server -> do
      collect port Quit `shouldReturnResponses` [Welcome P1, GameOver P2 OpponentLeft]
      await "C-02 exit" (wait server)

  it "uses its assigned P2 identity without sending a client-supplied player ID" $
    withServer $ \port server -> withClient port $ \first -> do
      expectLine first "WELCOME 1 P1"
      collect port Quit `shouldReturnResponses` [Welcome P2, GameOver P1 OpponentLeft]
      expectLine first "GAME_OVER P1 OPPONENT_LEFT"
      expectClosed first
      await "C-02 exit" (wait server)

  forM_ [(Fire (Coord 1 1), NotReady),
         (PlaceFleet [ShipPlacement Carrier (Coord 1 1) Horizontal], FleetSize 1)] $ \(command, fault) ->
    it ("reads the Rules error through the integrated server for " ++ show command) $
      withServer $ \port server -> do
        collect port command `shouldReturnResponses` [Welcome P1, Rejected fault]
        await "C-02 exit after one-shot client closes" (wait server)

  it "handles SERVER_FULL before WELCOME without sending a command" $
    withServer $ \port _ -> withClient port $ \first -> do
      expectLine first "WELCOME 1 P1"
      withClient port $ \second -> do
        expectLine second "WELCOME 1 P2"
        collect port Quit `shouldReturnResponses` [Rejected ServerFull]
        sendAll first (BSC.pack "FIRE A1\n")
        expectLine first "ERROR FLEETS_NOT_READY"

  it "validates an unencodable command before opening a connection" $
    runClient "127.0.0.1" 1 (Fire (Coord 0 1)) (const (pure ()))
      `shouldThrow` (== ClientProtocolError InvalidCoordinateToken)

  it "closes its socket when the display callback throws" $
    withServer $ \port server -> do
      runClient "127.0.0.1" port Quit (\_ -> ioError (userError "test callback failure"))
        `shouldThrow` anyIOException
      await "C-02 exit after callback failure" (wait server)

  it "waits for a fragmented CRLF WELCOME before sending its one LF command" $
    withMock (\connection -> do
      sendAll connection (BSC.pack "WELCOME 1 P1\r")
      threadDelay 100000
      allocaBytes 1 (\pointer -> recvBufNoWait connection pointer 1) >>= (`shouldBe` (-1))
      sendAll connection (BSC.pack "\n")
      expectLine connection "FIRE J10"
      forM_ (map BSC.pack ["TURN P1\nINCOM", "ING B1 MISS\r", "\nSHOT J10 MI", "SS\n"]) $
        sendAll connection
      expectClosed connection) $ \port ->
        collect port (Fire (Coord 10 10)) `shouldReturnResponses`
          [Welcome P1, TurnOf P1, Incoming (Coord 2 1) Miss, Shot (Coord 10 10) Miss]

  it "sends canonical PLACE and finishes on its OK response" $
    withMock (\connection -> do
      sendAll connection (BSC.pack "WELCOME 1 P2\n")
      expectLine connection "PLACE CV=A1:H;DD=J9:V"
      sendAll connection (BSC.pack "OK PLACE\n")
      expectClosed connection) $ \port ->
        collect port (PlaceFleet [ShipPlacement Destroyer (Coord 10 9) Vertical,
                                 ShipPlacement Carrier (Coord 1 1) Horizontal])
          `shouldReturnResponses` [Welcome P2, PlaceOK]

  it "ends a pending FIRE on GAME_OVER without waiting for SHOT" $
    withMock (\connection -> do
      sendAll connection (BSC.pack "WELCOME 1 P1\n")
      expectLine connection "FIRE A1"
      sendAll connection (BSC.pack "GAME_OVER P1 OPPONENT_LEFT\n")
      expectClosed connection) $ \port ->
        collect port (Fire (Coord 1 1)) `shouldReturnResponses` [Welcome P1, GameOver P1 OpponentLeft]

  forM_ [(BSC.pack "ERROR UNKNOWN\n", InvalidMessage),
           (BSC.pack "SHOT K1 HIT\n", InvalidMessage),
           (BSC.pack "SHOT A1 SUNK\n", InvalidMessage),
           (BS.pack [0xc3, 0xa9, 10], InvalidMessage),
           (BS.replicate 257 65, LineTooLong)] $ \(badResponse, fault) ->
    it ("rejects malformed server data and closes: " ++ show fault ++ "/" ++ show (BS.length badResponse)) $
      withMock (\connection -> do
        sendAll connection (BSC.pack "WELCOME 1 P1\n")
        expectLine connection "FIRE A1"
        sendAll connection badResponse
        expectClosed connection) $ \port ->
          collect port (Fire (Coord 1 1)) `shouldThrow` (== ClientProtocolError fault)

  forM_ [("WELCOME 2 P1\n", ClientProtocolError UnsupportedVersion),
           ("TURN P1\n", UnexpectedResponse (TurnOf P1)),
           ("ERROR INVALID_COMMAND\n", UnexpectedResponse (Rejected BadCommand))] $ \(greeting, fault) ->
    it ("rejects a wrong handshake without sending: " ++ show greeting) $
      withMock (\connection -> sendAll connection (BSC.pack greeting) >> expectClosed connection) $ \port ->
        collect port Quit `shouldThrow` (== fault)

  it "rejects a SHOT for another coordinate than the pending FIRE" $
    withMock (\connection -> do
      sendAll connection (BSC.pack "WELCOME 1 P1\n")
      expectLine connection "FIRE A1"
      sendAll connection (BSC.pack "SHOT B1 MISS\n")
      expectClosed connection) $ \port ->
        collect port (Fire (Coord 1 1)) `shouldThrow` (== UnexpectedResponse (Shot (Coord 2 1) Miss))

  it "reports EOF during handshake" $
    withMock (const (pure ())) $ \port -> collect port Quit `shouldThrow` (== UnexpectedEOF)

  it "does not parse a truncated response at EOF" $
    withMock (\connection -> do
      sendAll connection (BSC.pack "WELCOME 1 P1\n")
      expectLine connection "QUIT"
      sendAll connection (BSC.pack "GAME_OVER P2 OPPONENT_LEFT")) $ \port ->
        collect port Quit `shouldThrow` (== UnexpectedEOF)

  it "renders stable messages in Vietnamese at the client" $ do
    renderResponse (Welcome P2) `shouldBe` "Bạn là Người chơi 2."
    renderResponse (Rejected ServerFull) `shouldBe` "Lỗi: server đã đủ hai người chơi."
    renderResponse (Shot (Coord 10 10) (Sunk Destroyer)) `shouldBe` "Bạn bắn J10: chìm tàu khu trục."
    renderProtocolError UnsupportedVersion `shouldBe` "Phiên bản giao thức không tương thích."

placementSpec :: Spec
placementSpec = describe "D-03 guided placement" $ do
  describe "local parser and own preview" $ do
    forM_ [("A1 H", Coord 1 1, Horizontal), ("j9 v", Coord 10 9, Vertical),
           ("  a10   h  ", Coord 1 10, Horizontal), ("\tA1\tV\t", Coord 1 1, Vertical)] $ \(input, start, orientation) ->
      it ("accepts friendly input " ++ show input) $
        parsePlacementInput Destroyer input `shouldBe` Right (ShipPlacement Destroyer start orientation)
    forM_ ["", "A1", "A1 H EXTRA", "A1 X", "K1 H", "A0 H", "A01 H", "A11 H",
           "Ł1 H", "Ａ1 H", "A1 \0H"] $ \input ->
      it ("rejects malformed/unsafe input " ++ show input) $
        parsePlacementInput Carrier input `shouldSatisfy` either (not . null) (const False)
    forM_ [minBound .. maxBound] $ \ship -> do
      forM_ [Horizontal, Vertical] $ \orientation ->
        it ("accepts " ++ show ship ++ " ending at J10 in " ++ show orientation) $ do
          let start = case orientation of
                Horizontal -> Coord (11 - shipLength ship) 10
                Vertical -> Coord 10 (11 - shipLength ship)
              text = either (const "invalid fixture") BSC.unpack (encodeCoord start)
                ++ case orientation of Horizontal -> " H"; Vertical -> " V"
          parsePlacementInput ship text `shouldBe` Right (ShipPlacement ship start orientation)
      it ("rejects " ++ show ship ++ " extending from J10") $
        parsePlacementInput ship "J10 H" `shouldSatisfy` either (isInfixOf "vượt mép bàn") (const False)
    it "renders exactly the player's 10x10 fleet with readable IDs and empty cells" $
      case Board.placeFleet guidedFleet of
        Left fault -> ioError (userError (show fault))
        Right fleet -> renderFleet fleet `shouldBe` ownPreview

  describe "terminal draft and editing" $ do
    it "guides all five ships, shows preview and requires explicit GUI" $ do
      (draft, output) <- withTerminal (guidedInput ++ "GUI\n") promptFleet
      draft `shouldBe` Just guidedFleet
      forM_ ["A1..J10", "H = ngang", "V = dọc", "CV=5, BB=4, CR=3, SB=3, DD=2",
             "SUA CV/BB/CR/SB/DD", ownPreview] $ \message -> output `shouldSatisfy` isInfixOf message
    it "retries coordinate, direction, extent and overlap errors at the same ship" $ do
      (draft, output) <- withTerminal
        ("K1 H\nA1 X\nJ10 H\nA1 H\nA1 H\nA2 H\nA3 H\nA4 H\nA5 H\nGUI\n") promptFleet
      draft `shouldBe` Just guidedFleet
      forM_ ["Tọa độ", "H = ngang", "vượt mép bàn", "chồng lên nhau tại A1"] $ \message ->
        output `shouldSatisfy` isInfixOf message
    it "edits one ship, preserving the other four, and previews the replacement" $ do
      (draft, output) <- withTerminal (guidedInput ++ "SUA CV\nA2 H\nA6 V\nGUI\n") promptFleet
      let expected = ShipPlacement Carrier (Coord 1 6) Vertical : drop 1 guidedFleet
      draft `shouldBe` Just expected
      output `shouldSatisfy` isInfixOf "chồng lên nhau tại A2"
      case Board.placeFleet expected of
        Left fault -> ioError (userError (show fault))
        Right fleet -> output `shouldSatisfy` isInfixOf (renderFleet fleet)
    it "allows lower case confirmation/editing and repeated edits" $ do
      (draft, _) <- withTerminal (guidedInput ++ "sua dd\nJ9 V\nsua dd\nA5 H\ngui\n") promptFleet
      draft `shouldBe` Just guidedFleet
    it "rejects unknown review choices without silently sending or losing the draft" $ do
      (draft, output) <- withTerminal (guidedInput ++ "yes\nSUA XX\nGUI EXTRA\n\nGUI\n") promptFleet
      draft `shouldBe` Just guidedFleet
      output `shouldSatisfy` isInfixOf "Mã tàu phải là CV, BB, CR, SB hoặc DD."
    forM_ [("first ship", "HUY\n"), ("third ship", "A1 H\nA2 H\nHUY\n"),
           ("review", guidedInput ++ "HUY\n"), ("edit", guidedInput ++ "SUA CV\nHUY\n")] $ \(stage, input) ->
      it ("cancels at " ++ stage) $ do
        (draft, _) <- withTerminal input promptFleet
        draft `shouldBe` Nothing
    forM_ [("before input", ""), ("partial fleet", "A1 H\nA2 H\n"),
           ("before confirmation", guidedInput), ("during edit", guidedInput ++ "SUA BB\n")] $ \(stage, input) ->
      it ("treats EOF " ++ stage ++ " as cancellation") $ do
        (draft, _) <- withTerminal input promptFleet
        draft `shouldBe` Nothing
    it "does not connect or send if the player cancels" $ do
      (_, output) <- withTerminal "HUY\n" (runPlacementClient "127.0.0.1" 1)
      output `shouldSatisfy` isInfixOf "Đã hủy đặt tàu; chưa gửi đội tàu."

  describe "TCP placement session" $ do
    it "sends one canonical PLACE and retains the connection after OK" $
      withMock (\connection -> do
        sendAll connection (BSC.pack "WELCOME 1 P2\r\n")
        expectLine connection guidedWire
        sendAll connection (BSC.pack "OK PL")
        sendAll connection (BSC.pack "ACE\nWAITING OPPONENT\n")
        threadDelay 100000
        allocaBytes 1 (\pointer -> recvBufNoWait connection pointer 1) >>= (`shouldBe` (-1))
        sendAll connection (BSC.pack "START P1\nTURN P1\nINCOMING A1 HIT\nTURN P1\nGAME_OVER P2 OPPONENT_LEFT\n")
        expectClosed connection) $ \port -> do
          (_, output) <- withTerminal (guidedInput ++ "GUI\n") (runPlacementClient "127.0.0.1" port)
          forM_ ["Bạn là Người chơi 2.", "Đã nhận đội tàu.", "Đang chờ đối thủ.",
                 "Đối thủ bắn A1: trúng.", "Người chơi 2 thắng"] $ \message ->
            output `shouldSatisfy` isInfixOf message
    it "keeps waiting beyond the one-shot 10-second deadline after OK PLACE" $
      withMock (\connection -> do
        sendAll connection (BSC.pack "WELCOME 1 P1\n")
        expectLine connection guidedWire
        sendAll connection (BSC.pack "OK PLACE\nWAITING OPPONENT\n")
        threadDelay 11000000
        allocaBytes 1 (\pointer -> recvBufNoWait connection pointer 1) >>= (`shouldBe` (-1))
        sendAll connection (BSC.pack "GAME_OVER P1 OPPONENT_LEFT\n")
        expectClosed connection) $ \port -> do
          (_, output) <- withTerminal (guidedInput ++ "GUI\n") (runPlacementClient "127.0.0.1" port)
          output `shouldSatisfy` isInfixOf "Người chơi 1 thắng"
    it "closes the socket when the placement listener is canceled while idle" $ do
      acknowledged <- newEmptyMVar
      withMock (\connection -> do
        sendAll connection (BSC.pack "WELCOME 1 P1\n")
        expectLine connection guidedWire
        sendAll connection (BSC.pack "OK PLACE\nWAITING OPPONENT\n")
        putMVar acknowledged ()
        expectClosed connection) $ \port ->
          void $ withTerminal (guidedInput ++ "GUI\n") $ \input output ->
            withAsync (runPlacementClient "127.0.0.1" port input output) $ \client -> do
              await "placement acknowledged" (readMVar acknowledged)
              threadDelay 100000
              await "cancel placement listener" (cancel client)
    it "honors SERVER_FULL before WELCOME without sending PLACE" $
      withMock (\connection -> sendAll connection (BSC.pack "ERROR SERVER_FULL\n") >> expectClosed connection) $ \port -> do
        (_, output) <- withTerminal (guidedInput ++ "GUI\n") (runPlacementClient "127.0.0.1" port)
        output `shouldSatisfy` isInfixOf "server đã đủ hai người chơi"
    forM_ ["ERROR FLEET_ALREADY_PLACED\n", "GAME_OVER P2 OPPONENT_LEFT\n"] $ \reply ->
      it ("ends cleanly instead of waiting for OK after " ++ show reply) $
        withMock (\connection -> do
          sendAll connection (BSC.pack "WELCOME 1 P1\n")
          expectLine connection guidedWire
          sendAll connection (BSC.pack reply)
          expectClosed connection) $ \port ->
            void (withTerminal (guidedInput ++ "GUI\n") (runPlacementClient "127.0.0.1" port))
    forM_ [("WELCOME 2 P1\n", ClientProtocolError UnsupportedVersion),
           ("TURN P1\n", UnexpectedResponse (TurnOf P1))] $ \(greeting, fault) ->
      it ("rejects an invalid handshake before sending PLACE: " ++ show greeting) $
        withMock (\connection -> sendAll connection (BSC.pack greeting) >> expectClosed connection) $ \port ->
          withTerminal (guidedInput ++ "GUI\n") (runPlacementClient "127.0.0.1" port) `shouldThrow` (== fault)
    forM_ [("OK PLACE\nOK PLACE\n", UnexpectedResponse PlaceOK),
           ("OK PLACE\nSHOT A1 HIT\n", UnexpectedResponse (Shot (Coord 1 1) Hit)),
           ("OK PLACE\nINCOMING K1 HIT\n", ClientProtocolError InvalidMessage),
           ("OK PLACE\n" ++ replicate 257 'X', ClientProtocolError LineTooLong)] $ \(reply, fault) ->
      it ("rejects unexpected/malformed data after placement: " ++ take 40 (show reply)) $
        withMock (\connection -> do
          sendAll connection (BSC.pack "WELCOME 1 P1\n")
          expectLine connection guidedWire
          sendAll connection (BSC.pack reply)
          expectClosed connection) $ \port ->
            withTerminal (guidedInput ++ "GUI\n") (runPlacementClient "127.0.0.1" port) `shouldThrow` (== fault)
    it "reports EOF before the acknowledgment" $
      withMock (\connection -> sendAll connection (BSC.pack "WELCOME 1 P1\n") >> expectLine connection guidedWire) $ \port ->
        withTerminal (guidedInput ++ "GUI\n") (runPlacementClient "127.0.0.1" port) `shouldThrow` (== UnexpectedEOF)
    it "places as P2 against the real server and stays available to receive a shot" $
      withServer $ \port server -> withClient port $ \first -> do
        expectLine first "WELCOME 1 P1"
        sendAll first (BSC.pack "PLACE CV=A6:H;BB=A7:H;CR=A8:H;SB=A9:H;DD=A10:H\n")
        expectLine first "OK PLACE"
        expectLine first "WAITING OPPONENT"
        (_, output) <- withTerminal (guidedInput ++ "GUI\n") $ \input terminal ->
          withAsync (runPlacementClient "127.0.0.1" port input terminal) $ \client -> do
            expectLine first "START P1"
            expectLine first "TURN P1"
            sendAll first (BSC.pack "FIRE A1\n")
            expectLine first "SHOT A1 HIT"
            expectLine first "TURN P1"
            sendAll first (BSC.pack "QUIT\n")
            expectLine first "GAME_OVER P2 OPPONENT_LEFT"
            await "D-03 client finish" (wait client)
        output `shouldSatisfy` isInfixOf ownPreview
        output `shouldSatisfy` isInfixOf "Đối thủ bắn A1: trúng."
        output `shouldSatisfy` isInfixOf "Người chơi 2 thắng"
        await "D-03 server finish" (wait server)

firingSpec :: Spec
firingSpec = describe "D-04 firing and turn display" $ do
  describe "friendly input and presentation" $ do
    forM_ [("A1", Fire (Coord 1 1)), ("j10", Fire (Coord 10 10)),
           (" fire\tB2 ", Fire (Coord 2 2)), (" quit ", Quit)] $ \(input, command) ->
      it ("parses " ++ show input) $ parseFireInput input `shouldBe` Right command
    forM_ ["", "FIRE", "FIRE A1 EXTRA", "A1 H", "K1", "A0", "A01", "J11",
           "Ａ1", "Ł1", "A\0\&1", replicate 257 'A'] $ \input ->
      it ("rejects invalid firing input " ++ take 35 (show input)) $
        parseFireInput input `shouldSatisfy` either (not . null) (const False)
    forM_ [P1, P2] $ \viewer -> do
      it ("distinguishes own turn and opponent turn for " ++ show viewer) $ do
        renderResponseFor viewer (TurnOf viewer) `shouldSatisfy` isInfixOf "Đến lượt bạn bắn."
        renderResponseFor viewer (TurnOf (otherPlayer viewer)) `shouldSatisfy` isInfixOf "chưa được bắn"
        renderResponseFor viewer WaitingOpponent `shouldSatisfy` isInfixOf "Chờ đối thủ đặt đủ tàu"
      forM_ [AllShipsSunk, OpponentLeft] $ \reason ->
        it ("distinguishes victory/defeat for " ++ show (viewer, reason)) $ do
          renderResponseFor viewer (GameOver viewer reason) `shouldSatisfy` isInfixOf "Bạn thắng!"
          renderResponseFor viewer (GameOver (otherPlayer viewer) reason) `shouldSatisfy` isInfixOf "Bạn thua."
    forM_ [(Miss, "trượt"), (Hit, "trúng"), (Sunk Cruiser, "chìm tàu tuần dương"), (Win, "thắng")] $
      \(outcome, message) -> it ("displays both directions for " ++ show outcome) $ do
        renderResponseFor P1 (Shot (Coord 1 1) outcome) `shouldSatisfy` isInfixOf ("Bạn bắn A1: " ++ message)
        renderResponseFor P1 (Incoming (Coord 1 1) outcome) `shouldSatisfy` isInfixOf ("Đối thủ bắn A1: " ++ message)

  describe "TCP input gated by server events" $ do
    it "waits before TURN, allows retry, waits after SHOT, and never fires a coordinate twice" $
      withMock (\connection -> do
        begin connection P1
        sendAll connection (BSC.pack "WAITING OPPONENT\n")
        assertIdle connection
        sendAll connection (BSC.pack "START P1\nTURN P1\n")
        expectLine connection "FIRE A1"
        assertIdle connection
        sendAll connection (BSC.pack "ERROR INVALID_COMMAND\n")
        expectLine connection "FIRE A1"
        sendAll connection (BSC.pack "SHOT A1 HIT\n")
        assertIdle connection
        sendAll connection (BSC.pack "TURN P1\n")
        expectLine connection "FIRE B1"
        sendAll connection (BSC.pack "SHOT B1 SUNK DD\nTURN P1\n")
        expectLine connection "FIRE J10"
        sendAll connection (BSC.pack "SHOT J10 MISS\nTURN P2\n")
        assertIdle connection
        sendAll connection (BSC.pack "INCOMING A1 MISS\nTURN P1\n")
        expectLine connection "QUIT"
        sendAll connection (BSC.pack "GAME_OVER P2 OPPONENT_LEFT\n")
        expectClosed connection) $ \port -> do
          (_, output) <- withTerminal (guidedInput ++ "GUI\nK1\n" ++ replicate 300 'A' ++ "\nA2\b1\nA2\DEL1\nA1\nb1\nFIRE j10\nQUIT\n")
            (runPlacementClient "127.0.0.1" port)
          forM_ ["Tọa độ phải nằm", "Dòng vượt quá giới hạn 256 byte", "Đến lượt bạn bắn", "chưa được bắn", "lệnh không hợp lệ",
                 "đã bắn A1", "Bạn bắn A1: trúng", "Bạn bắn B1: chìm", "Bạn bắn J10: trượt",
                 "Đối thủ bắn A1: trượt", "Bạn thua."] $ \message ->
            output `shouldSatisfy` isInfixOf message
    it "obeys a WRONG_TURN error and resumes only on the subsequent own TURN" $
      withMock (\connection -> do
        begin connection P2
        sendAll connection (BSC.pack "START P1\nTURN P2\n")
        expectLine connection "FIRE A1"
        sendAll connection (BSC.pack "ERROR NOT_YOUR_TURN P1\n")
        assertIdle connection
        sendAll connection (BSC.pack "INCOMING J10 MISS\nTURN P2\n")
        expectLine connection "FIRE A1"
        sendAll connection (BSC.pack "SHOT A1 WIN\nGAME_OVER P2 ALL_SHIPS_SUNK\n")
        expectClosed connection) $ \port -> do
          (_, output) <- withTerminal (guidedInput ++ "GUI\nA1\nA1\nB1\n") (runPlacementClient "127.0.0.1" port)
          output `shouldSatisfy` isInfixOf "Bạn thắng!"
    forM_ ["", "QUIT\n", "quit"] $ \ending ->
      it ("sends exactly one QUIT for own-turn EOF/quit " ++ show ending) $
        withMock (\connection -> do
          begin connection P1
          sendAll connection (BSC.pack "START P1\nTURN P1\n")
          expectLine connection "QUIT"
          assertIdle connection
          sendAll connection (BSC.pack "GAME_OVER P2 OPPONENT_LEFT\n")
          expectClosed connection) $ \port -> do
            (_, output) <- withTerminal (guidedInput ++ "GUI\n" ++ ending) (runPlacementClient "127.0.0.1" port)
            output `shouldSatisfy` isInfixOf "Bạn thua."
    it "accepts a final firing line without a newline and handles WIN without asking for another shot" $
      withMock (\connection -> do
        begin connection P1
        sendAll connection (BSC.pack "START P1\nTURN P1\n")
        expectLine connection "FIRE J10"
        sendAll connection (BSC.pack "SHOT J10 WIN\nGAME_OVER P1 ALL_SHIPS_SUNK\n")
        expectClosed connection) $ \port -> do
          (_, output) <- withTerminal (guidedInput ++ "GUI\nJ10") (runPlacementClient "127.0.0.1" port)
          output `shouldSatisfy` isInfixOf "Bạn thắng!"
    it "reports server EOF while a firing response is pending" $
      withMock (\connection -> do
        begin connection P1
        sendAll connection (BSC.pack "START P1\nTURN P1\n")
        expectLine connection "FIRE A1") $ \port ->
          withTerminal (guidedInput ++ "GUI\nA1\n") (runPlacementClient "127.0.0.1" port)
            `shouldThrow` (== UnexpectedEOF)
    forM_ [("SHOT B1 HIT\n", UnexpectedResponse (Shot (Coord 2 1) Hit)),
           ("TURN P1\n", UnexpectedResponse (TurnOf P1)),
           ("WELCOME 1 P1\n", UnexpectedResponse (Welcome P1)),
           ("OK PLACE\n", UnexpectedResponse PlaceOK),
           ("SHOT K1 HIT\n", ClientProtocolError InvalidMessage),
           (replicate 257 'X', ClientProtocolError LineTooLong)] $ \(reply, fault) ->
      it ("rejects invalid data during pending FIRE " ++ take 35 (show reply)) $
        withMock (\connection -> do
          begin connection P1
          sendAll connection (BSC.pack "START P1\nTURN P1\n")
          expectLine connection "FIRE A1"
          sendAll connection (BSC.pack reply)
          expectClosed connection) $ \port ->
            withTerminal (guidedInput ++ "GUI\nA1\n") (runPlacementClient "127.0.0.1" port)
              `shouldThrow` (== fault)
  where
    begin connection player = do
      sendAll connection (BSC.pack (if player == P1 then "WELCOME 1 P1\n" else "WELCOME 1 P2\n"))
      expectLine connection guidedWire
      sendAll connection (BSC.pack "OK PLACE\n")
    assertIdle connection = do
      threadDelay 150000
      allocaBytes 1 (\pointer -> recvBufNoWait connection pointer 1) >>= (`shouldBe` (-1))

boardsSpec :: Spec
boardsSpec = describe "D-05 public boards" $ do
  it "shows a 10x10 unknown target and only the confirmed local fleet initially" $ do
    let rows = boardRows (renderBoards initialView)
    length rows `shouldBe` 10
    map (drop 36) rows `shouldBe`
      [" 1  ?  ?  ?  ?  ?  ?  ?  ?  ?  ?", " 2  ?  ?  ?  ?  ?  ?  ?  ?  ?  ?",
       " 3  ?  ?  ?  ?  ?  ?  ?  ?  ?  ?", " 4  ?  ?  ?  ?  ?  ?  ?  ?  ?  ?",
       " 5  ?  ?  ?  ?  ?  ?  ?  ?  ?  ?", " 6  ?  ?  ?  ?  ?  ?  ?  ?  ?  ?",
       " 7  ?  ?  ?  ?  ?  ?  ?  ?  ?  ?", " 8  ?  ?  ?  ?  ?  ?  ?  ?  ?  ?",
       " 9  ?  ?  ?  ?  ?  ?  ?  ?  ?  ?", "10  ?  ?  ?  ?  ?  ?  ?  ?  ?  ?"]
    take 32 (headRow rows) `shouldBe` " 1 CV CV CV CV CV  .  .  .  .  ."

  forM_ [(Miss, 'o'), (Hit, 'X'), (Sunk Carrier, '#'), (Win, '*')] $ \(outcome, symbol) ->
    forM_ [False, True] $ \incoming ->
      it ("marks only the received J10 cell for " ++ show (incoming, outcome)) $ do
        let response = if incoming then Incoming (Coord 10 10) outcome else Shot (Coord 10 10) outcome
            updated = updatePlayerView response initialView
            rows = boardRows (renderBoards updated)
            row10 = rows !! 9
            cellColumn = if incoming then 31 else 67
            target = concatMap (drop 36) rows
        row10 !! cellColumn `shouldBe` symbol
        ownFleetView updated `shouldBe` ownFleetView initialView
        viewPhase updated `shouldBe` Placing
        length (filter (== '?') target) `shouldBe` if incoming then 100 else 99
        (if incoming then outgoingShotsView updated else incomingShotsView updated) `shouldBe` Map.empty

  it "leaves both boards unchanged on every wire error" $
    forM_ [BadCommand, BadCoordinate, FleetSize 4, Missing Destroyer, Duplicate Cruiser,
           OutOfBounds Carrier, Overlap (Coord 1 1), AlreadyPlaced, NotReady, WrongTurn P2,
           RepeatedShot (Coord 1 1), GameFinished, TooLong, ServerFull] $ \fault -> do
      let previous = updatePlayerView (Shot (Coord 1 1) Hit) initialView
          next = updatePlayerView (Rejected fault) previous
      next `shouldBe` previous
      renderBoards next `shouldBe` renderBoards previous

  forM_ [P1, P2] $ \winner -> forM_ [P1, P2] $ \viewer ->
    it ("matches viewFor after every filtered success/error for " ++ show (winner, viewer)) $ do
      let playing = [((actor, expected), before, after, result)
            | ((actor, _, expected), (before, after, result)) <- zip (b04Cases winner) (b04Trace winner),
              gamePhase before /= Placing]
      case playing of
        [] -> ioError (userError "D-05 missing real game trace")
        (_, first, _, _) : _ -> do
          final <- foldM (\view ((actor, _), _, after, result) -> do
            let routed = case result of
                  Left fault -> [(actor, Rejected (wireError fault))]
                  Right events -> concatMap (routeEvent (gamePhase after)) events
                next = foldl (flip updatePlayerView) view [response | (recipient, response) <- routed, recipient == viewer]
            next `shouldBe` View.viewFor viewer after
            let target = concatMap (drop 36) (boardRows (renderBoards next))
            length (filter (== '?') target) `shouldBe` 100 - Map.size (outgoingShotsView next)
            forM_ ["CV", "BB", "CR", "SB", "DD"] $ \code ->
              (code `isInfixOf` target) `shouldBe` False
            pure next) (View.viewFor viewer first) playing
          viewPhase final `shouldBe` Finished winner AllShipsSunk
  where
    initialView = PlayerView P1 Placing (Just checkedFleet) Map.empty Map.empty False
    checkedFleet = either (error . show) id (Board.placeFleet guidedFleet)
    boardRows = take 10 . drop 2 . lines
    headRow rows = case rows of row : _ -> row; [] -> error "D-05 empty board"

guidedInput, guidedWire, ownPreview :: String
guidedInput = "A1 H\nA2 H\nA3 H\nA4 H\nA5 H\n"
guidedWire = "PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H"
ownPreview = unlines
  ["Bàn của bạn (. = ô trống):", "    A  B  C  D  E  F  G  H  I  J",
   " 1 CV CV CV CV CV  .  .  .  .  .", " 2 BB BB BB BB  .  .  .  .  .  .",
   " 3 CR CR CR  .  .  .  .  .  .  .", " 4 SB SB SB  .  .  .  .  .  .  .",
   " 5 DD DD  .  .  .  .  .  .  .  .", " 6  .  .  .  .  .  .  .  .  .  .",
   " 7  .  .  .  .  .  .  .  .  .  .", " 8  .  .  .  .  .  .  .  .  .  .",
   " 9  .  .  .  .  .  .  .  .  .  .", "10  .  .  .  .  .  .  .  .  .  ."]

guidedFleet :: FleetPlacement
guidedFleet = zipWith (\ship row -> ShipPlacement ship (Coord 1 row) Horizontal)
  [Carrier, Battleship, Cruiser, Submarine, Destroyer] [1 .. 5]

-- Real UTF-8 handles test exactly the terminal API; temporary files are closed
-- and removed even on failure, with no stdin replacement/global redirection.
withTerminal :: String -> (Handle -> Handle -> IO a) -> IO (a, String)
withTerminal script action = withTranscript "input" $ \input -> withTranscript "output" $ \output -> do
  hPutStr input script
  hSeek input AbsoluteSeek 0
  result <- action input output
  hFlush output
  hSeek output AbsoluteSeek 0
  transcript <- hGetContents' output
  pure (result, transcript)

withTranscript :: String -> (Handle -> IO a) -> IO a
withTranscript label action = bracket acquire release (action . snd)
  where
    acquire = do
      temporary <- getTemporaryDirectory
      (path, handle) <- openTempFile temporary ("battleship-D03-" ++ label)
      hSetEncoding handle utf8
      pure (path, handle)
    release (path, handle) = hClose handle `finally` removeFile path

collect :: PortNumber -> Command -> IO [Response]
collect port command = do
  observed <- newIORef []
  runClient "127.0.0.1" port command (\response -> modifyIORef' observed (++ [response]))
  readIORef observed

shouldReturnResponses :: IO [Response] -> [Response] -> IO ()
shouldReturnResponses action expected = action >>= (`shouldBe` expected)

-- A scripted TCP peer tests client behavior independently of C-02's stubs.
-- Readiness comes from listen/socketPort, and cleanup wakes Windows IO first.
withMock :: (Socket -> IO ()) -> (PortNumber -> IO a) -> IO a
withMock script action = withSocketsDo $ bracket open close $ \listener -> do
  port <- socketPort listener
  active <- newIORef Nothing
  withAsync (bracket (fst <$> accept listener) closeConnection $ \connection -> do
    writeIORef active (Just connection)
    script connection) $ \worker ->
      (do result <- action port
          await "scripted server exit" (wait worker)
          pure result)
        `finally` (close listener >> readIORef active >>= mapM_ closeConnection)
  where
    open = do
      listener <- socket AF_INET Stream defaultProtocol
      (bind listener (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1))) >> listen listener 1 >> pure listener)
        `catch` failedOpen listener
    failedOpen :: Socket -> IOException -> IO Socket
    failedOpen listener exception = close listener >> ioError exception

closeConnection :: Socket -> IO ()
closeConnection connection = do
  void (try (shutdown connection ShutdownBoth) :: IO (Either IOException ()))
  close connection
