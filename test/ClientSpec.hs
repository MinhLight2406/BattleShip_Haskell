module ClientSpec (spec) where

import Battleship.Client
import Battleship.Protocol
import Battleship.Types
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Exception (IOException, bracket, catch, finally, try)
import Control.Monad (forM_, void)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Foreign.Marshal.Alloc (allocaBytes)
import Network.Socket
  ( Family (AF_INET), PortNumber, ShutdownCmd (ShutdownBoth), SockAddr (SockAddrInet),
    Socket, SocketType (Stream), accept, bind, close, defaultProtocol,
    listen, recvBufNoWait, shutdown, socket, socketPort, tupleToHostAddress, withSocketsDo )
import Network.Socket.ByteString (sendAll)
import ServerSpec (await, expectClosed, expectLine, withClient, withServer)
import Test.Hspec (Spec, anyIOException, describe, it, shouldBe, shouldThrow)

spec :: Spec
spec = describe "D-02 client" $ do
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

  forM_ [Fire (Coord 1 1), PlaceFleet [ShipPlacement Carrier (Coord 1 1) Horizontal]] $ \command ->
    it ("reads the C-02 sample error for " ++ show command) $
      withServer $ \port server -> do
        collect port command `shouldReturnResponses` [Welcome P1, Rejected BadCommand]
        await "C-02 exit after one-shot client closes" (wait server)

  it "handles SERVER_FULL before WELCOME without sending a command" $
    withServer $ \port _ -> withClient port $ \first -> do
      expectLine first "WELCOME 1 P1"
      withClient port $ \second -> do
        expectLine second "WELCOME 1 P2"
        collect port Quit `shouldReturnResponses` [Rejected ServerFull]
        sendAll first (BSC.pack "FIRE A1\n")
        expectLine first "ERROR INVALID_COMMAND"

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
