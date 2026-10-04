module ServerSpec (spec, withServer, withClient, expectLine, expectClosed, readLine, await) where

import Battleship.Server (runServer)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, cancel, mapConcurrently, race, wait, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (IOException, bracket, bracketOnError, catch, try)
import Control.Monad (forM_, void)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.List (sort)
import Foreign.Marshal.Alloc (allocaBytes)
import Network.Socket
  ( Family (AF_INET), PortNumber, ShutdownCmd (ShutdownBoth, ShutdownSend),
    SockAddr (SockAddrInet), Socket, SocketOption (RecvBuffer), SocketType (Stream), close, connect,
    defaultProtocol, recvBufNoWait, setSocketOption, shutdown, socket, tupleToHostAddress, withSocketsDo )
import Network.Socket.ByteString (recv, sendAll)
import System.Timeout (timeout)
import Test.Hspec
  ( Expectation, Spec, describe, it, shouldBe, shouldSatisfy )

spec :: Spec
spec = do
  c02Spec
  c05Spec

c02Spec :: Spec
c02Spec = describe "C-02 TCP server" $ do
  it "welcomes an idle first client as P1 and the next as P2" $
    withServer $ \port _ -> withPair port $ \_ _ -> pure ()

  it "rejects repeated third connections and keeps the two players usable" $
    withServer $ \port server -> withPair port $ \first second -> do
      forM_ [1 :: Int .. 3] $ \_ -> withClient port $ \third -> do
        expectLine third "ERROR SERVER_FULL"
        expectClosed third
      forM_ [first, second] $ \client -> do
        sendText client "FIRE A1\n"
        expectLine client "ERROR FLEETS_NOT_READY"
      quitAndWait first [first, second] "P2" server

  it "assigns exactly two unique slots when three clients connect concurrently" $
    withServer $ \port _ -> withRawSockets 3 $ \connections -> do
      responses <- mapConcurrently (\connection -> do
        connect connection (loopback port)
        readLine connection) connections
      sort responses `shouldBe` map BSC.pack
        ["ERROR SERVER_FULL", "WELCOME 1 P1", "WELCOME 1 P2"]
      let rejected = [connection | (connection, response) <- zip connections responses,
                                   response == BSC.pack "ERROR SERVER_FULL"]
      mapM_ expectClosed rejected

  forM_ [("P1", "P2"), ("P2", "P1")] $ \(actor, winner) -> do
    it ("QUIT by " ++ actor ++ " broadcasts once, closes both clients and stops") $
      withServer $ \port server -> withPair port $ \first second ->
        quitAndWait (if actor == "P1" then first else second) [first, second] winner server

    it ("EOF by " ++ actor ++ " ends the session without reusing its slot") $
      withServer $ \port server -> withPair port $ \first second -> do
        shutdown (if actor == "P1" then first else second) ShutdownSend
        expectEnd [first, second] winner
        await "server exit after EOF" (wait server)
        expectListenerClosed port

  it "ends if P1 leaves before P2 connects, rather than replacing P1" $
    withServer $ \port server -> withClient port $ \first -> do
      expectLine first "WELCOME 1 P1"
      quitAndWait first [first] "P2" server
      expectListenerClosed port

  it "notifies P1 when P2 closes its socket outright" $
    withServer $ \port server -> withPair port $ \first second -> do
      close second
      expectEnd [first] "P1"
      await "server exit after disconnect" (wait server)

  it "serializes simultaneous QUITs into one consistent final broadcast" $ forM_ [1 :: Int .. 50] $ \_ ->
    withServer $ \port server -> withPair port $ \first second -> do
      -- Either send may race the other client's successful session shutdown.
      void $ mapConcurrently (\connection -> try (sendText connection "QUIT\n")
        :: IO (Either IOException ())) [first, second]
      response <- readLine first `catch` quitReadFailure "P1 GAME_OVER"
      response `shouldSatisfy` (`elem` map BSC.pack
        ["GAME_OVER P1 OPPONENT_LEFT", "GAME_OVER P2 OPPONENT_LEFT"])
      (readLine second `catch` quitReadFailure "P2 GAME_OVER") >>= (`shouldBe` response)
      expectClosed first `catch` quitReadFailure "P1 EOF"
      expectClosed second `catch` quitReadFailure "P2 EOF"
      await "server exit after simultaneous QUITs" (wait server)


  it "routes PLACE/FIRE through Rules and never forwards private payloads" $
    withServer $ \port server -> withPair port $ \first second -> do
      sendText first "PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H\n"
      expectLine first "OK PLACE"
      expectLine first "WAITING OPPONENT"
      sendText first "FIRE A1\n"
      expectLine first "ERROR FLEETS_NOT_READY"
      forM_ ["P2 FIRE A1", "", "quit", "QUIT P2", " QUIT", "QUIT ",
             "QUIT\rX", "QUIT\0"] $ \payload -> do
        sendText first (payload ++ "\n")
        expectLine first "ERROR INVALID_COMMAND"
      -- P2's next frame must be GAME_OVER: no error, PLACE or fake SHOT leaked.
      quitAndWait first [first, second] "P2" server

  it "accepts CRLF for QUIT and always emits LF" $
    withServer $ \port server -> withPair port $ \first second -> do
      sendText second "QUIT\r\n"
      expectEnd [first, second] "P1"
      await "server exit after CRLF QUIT" (wait server)

  it "waits for LF when QUIT is split between writes" $
    withServer $ \port server -> withClient port $ \first -> do
      expectLine first "WELCOME 1 P1"
      sendText first "QU"
      expectNoData first
      sendText first "IT\n"
      expectEnd [first] "P2"
      await "server exit after fragmented QUIT" (wait server)

  it "processes several frames in one write in order" $
    withServer $ \port server -> withClient port $ \first -> do
      expectLine first "WELCOME 1 P1"
      sendText first "UNKNOWN\nFIRE A1\nQUIT\nIGNORED\n"
      expectLine first "ERROR INVALID_COMMAND"
      expectLine first "ERROR FLEETS_NOT_READY"
      expectEnd [first] "P2"
      await "server exit after combined frames" (wait server)

  it "processes complete frames before EOF and drops an unfinished tail" $
    withServer $ \port server -> withClient port $ \first -> do
      expectLine first "WELCOME 1 P1"
      sendText first "UNKNOWN\nFIRE A1"
      shutdown first ShutdownSend
      expectLine first "ERROR INVALID_COMMAND"
      expectEnd [first] "P2"
      await "server exit after partial EOF" (wait server)

  forM_ ["\n", "\r\n"] $ \ending ->
    it ("accepts a 256-byte payload with " ++ show ending ++ " and keeps reading") $
      withServer $ \port server -> withClient port $ \first -> do
        expectLine first "WELCOME 1 P1"
        sendText first (replicate 256 'X' ++ ending ++ "NEXT\n")
        expectLine first "ERROR INVALID_COMMAND"
        expectLine first "ERROR INVALID_COMMAND"
        quitAndWait first [first] "P2" server

  it "allows a trailing CR after 256 bytes while waiting for LF" $
    withServer $ \port server -> withClient port $ \first -> do
      expectLine first "WELCOME 1 P1"
      sendText first (replicate 256 'X' ++ "\r")
      expectNoData first
      sendText first "\n"
      expectLine first "ERROR INVALID_COMMAND"
      quitAndWait first [first] "P2" server

  forM_ [replicate 257 'X', replicate 256 'X' ++ "\rX", replicate 257 'X' ++ "\n"] $
    \payload -> it ("rejects an overlong frame immediately: " ++ show (length payload) ++ " bytes") $
      withServer $ \port server -> withPair port $ \first second -> do
        sendText first payload
        expectLine first "ERROR LINE_TOO_LONG"
        expectEnd [first, second] "P2"
        await "server exit after LINE_TOO_LONG" (wait server)

  forM_ [0, 1, 2] $ \count ->
    it ("cancellation closes listener and " ++ show count ++ " connected sockets") $
      withServer $ \port server -> withClients port count $ \connections -> do
        forM_ (zip connections ["P1", "P2"]) $ \(connection, player) ->
          expectLine connection ("WELCOME 1 " ++ player)
        cancel server
        mapM_ expectClosed connections
        expectListenerClosed port
        expectCanRestart port

  it "releases the listener if the readiness callback throws" $ withSocketsDo $ do
    ready <- newEmptyMVar
    result <- try (runServer 0 (\port -> putMVar ready port >> ioError (userError "test startup failure")))
      :: IO (Either IOException ())
    result `shouldSatisfy` either (const True) (const False)
    port <- readMVar ready
    expectListenerClosed port
    expectCanRestart port

  it "reports a bind failure when another server is listening on that port" $
    withServer $ \port _ -> do
      result <- await "occupied port failure" (try (runServer port (const (pure ()))))
        :: IO (Either IOException ())
      result `shouldSatisfy` either (const True) (const False)

c05Spec :: Spec
c05Spec = describe "C-05 private delivery and disconnect cleanup" $ do
  forM_ ["P1", "P2"] $ \earlier ->
    it (earlier ++ " alone receives placement acknowledgement/waiting; both receive START exactly once") $
      withServer $ \port server -> withPair port $ \first second -> do
        let (early, late) = if earlier == "P1" then (first, second) else (second, first)
        placeAndWait early (if earlier == "P1" then 1 else 6)
        expectNoData late
        sendText early "FIRE J10\n"
        expectLine early "ERROR FLEETS_NOT_READY"
        expectNoData late
        sendText late (placementLine (if earlier == "P1" then 6 else 1))
        expectLine late "OK PLACE"
        forM_ [first, second] $ \connection -> do
          expectLine connection "START P1"
          expectLine connection "TURN P1"
        -- The next frame proves no private PLACE/error or duplicate START
        -- was queued ahead of this public shot result.
        sendText first "FIRE A6\n"
        expectLine first "SHOT A6 HIT"
        expectLine second "INCOMING A6 HIT"
        forM_ [first, second] $ \connection -> expectLine connection "TURN P1"
        quitAndWait first [first, second] "P2" server

  forM_ ["P1", "P2"] $ \actor ->
    forM_ ["unplaced", "waiting", "playing"] $ \stage ->
      forM_ ["EOF", "close", "partial EOF"] $ \ending ->
        it (actor ++ " leaving via " ++ ending ++ " during " ++ stage ++ " announces the right winner and releases the port") $
          withServer $ \port server -> withPair port $ \first second -> do
            let (departing, survivor, winner) = if actor == "P1" then (first, second, "P2") else (second, first, "P1")
            case stage of
              "waiting" -> placeAndWait survivor (if winner == "P1" then 1 else 6)
              "playing" -> do
                placeAndWait first 1
                sendText second (placementLine 6)
                expectLine second "OK PLACE"
                forM_ [first, second] $ \connection -> do
                  expectLine connection "START P1"
                  expectLine connection "TURN P1"
                sendText first "FIRE A6\n"
                expectLine first "SHOT A6 HIT"
                expectLine second "INCOMING A6 HIT"
                forM_ [first, second] $ \connection -> expectLine connection "TURN P1"
              _ -> pure ()
            case ending of
              "close" -> close departing
              "partial EOF" -> sendText departing "FIRE A" >> shutdown departing ShutdownSend
              _ -> shutdown departing ShutdownSend
            expectEnd [survivor] winner
            if ending == "close" then pure () else expectEnd [departing] winner
            await "C-05 server exits after disconnect" (wait server)
            expectCanRestart port

  forM_ [False, True] $ \placed ->
    it ("EOF before P2 connects does not leave accept blocked; fleet placed = " ++ show placed) $
      withServer $ \port server -> withClient port $ \first -> do
        expectLine first "WELCOME 1 P1"
        if placed then placeAndWait first 1 else pure ()
        shutdown first ShutdownSend
        expectEnd [first] "P2"
        await "C-05 exit while waiting for second connection" (wait server)
        expectCanRestart port

  it "stops and releases the listener when both sockets disappear together (20 races)" $
    forM_ [1 :: Int .. 20] $ \_ ->
      withServer $ \port server -> withPair port $ \first second -> do
        void (mapConcurrently close [first, second])
        await "C-05 simultaneous disconnect exit" (wait server)
        expectCanRestart port

  it "disconnects a client that stops reading without blocking the opponent or server shutdown" $
    withServer $ \port server -> withPair port $ \first second -> do
      -- Keep P1's socket open, stop receiving after WELCOME and force its send
      -- window to fill with actor-only errors. No Quit/EOF is sent by the test:
      -- the server's failed-send watchdog must end this session itself.
      setSocketOption first RecvBuffer 4096
      void (awaitSocket "C-05 slow reader flood" first
        (try (sendText first (concat (replicate 50000 "UNKNOWN\n"))) :: IO (Either IOException ())))
      expectEnd [second] "P2"
      await "C-05 exit after stalled writer" (wait server)
      expectCanRestart port

  it "delivers GAME_OVER before EOF even with unread commands following Quit (10 sessions)" $
    forM_ [1 :: Int .. 10] $ \_ ->
      withServer $ \port server -> withPair port $ \first second -> do
        -- Much more than one recv chunk: closing with the remainder unread
        -- can reset TCP and discard the final response on Windows.
        void (try (sendText first (concat (replicate 2000 "QUIT\n"))) :: IO (Either IOException ()))
        expectEnd [first, second] "P2"
        await "C-05 exit after pipelined terminal command" (wait server)

placementLine :: Int -> String
placementLine row = "PLACE " ++ concat
  [ (if offset == 0 then "" else ";") ++ ship ++ "=A" ++ show (row + offset) ++ ":H"
  | (ship, offset) <- zip ["CV", "BB", "CR", "SB", "DD"] [0 :: Int ..] ] ++ "\n"

placeAndWait :: Socket -> Int -> IO ()
placeAndWait connection row = do
  sendText connection (placementLine row)
  expectLine connection "OK PLACE"
  expectLine connection "WAITING OPPONENT"

quitReadFailure :: String -> IOException -> IO a
quitReadFailure stage exception = ioError (userError ("C-02 simultaneous QUIT " ++ stage ++ ": " ++ show exception))

withServer :: (PortNumber -> Async () -> IO a) -> IO a
withServer action = withSocketsDo $ do
  ready <- newEmptyMVar
  withAsync (runServer 0 (putMVar ready)) $ \server -> do
    startup <- await "server startup" (race (readMVar ready) (wait server))
    case startup of
      Left port -> action port server
      Right () -> ioError (userError "C-02 server stopped before announcing its port")

withClient :: PortNumber -> (Socket -> IO a) -> IO a
withClient port = bracket acquire close
  where
    acquire = bracketOnError (socket AF_INET Stream defaultProtocol) close $ \connection -> do
      connect connection (loopback port)
      pure connection

withPair :: PortNumber -> (Socket -> Socket -> IO a) -> IO a
withPair port action = withClient port $ \first -> do
  expectLine first "WELCOME 1 P1"
  withClient port $ \second -> do
    expectLine second "WELCOME 1 P2"
    action first second

withClients :: PortNumber -> Int -> ([Socket] -> IO a) -> IO a
withClients _ 0 action = action []
withClients port count action = withClient port $ \connection ->
  withClients port (count - 1) (action . (connection :))

withRawSockets :: Int -> ([Socket] -> IO a) -> IO a
withRawSockets 0 action = action []
withRawSockets count action = bracket (socket AF_INET Stream defaultProtocol) close $ \connection ->
  withRawSockets (count - 1) (action . (connection :))

loopback :: PortNumber -> SockAddr
loopback port = SockAddrInet port (tupleToHostAddress (127, 0, 0, 1))

sendText :: Socket -> String -> IO ()
sendText connection = sendAll connection . BSC.pack

readLine :: Socket -> IO BS.ByteString
readLine connection = awaitSocket "TCP response" connection (go BS.empty)
  where
    go buffer = do
      byte <- recv connection 1
      if byte == BSC.pack "\n" then pure buffer
      else if BS.null byte || BS.length buffer >= 256
        then ioError (userError "C-02 response missing LF or too long")
        else go (buffer <> byte)

expectLine :: Socket -> String -> Expectation
expectLine connection expected = readLine connection >>= (`shouldBe` BSC.pack expected)

expectClosed :: Socket -> Expectation
expectClosed connection = awaitSocket "socket EOF" connection (recv connection 1) >>= (`shouldBe` BS.empty)

expectNoData :: Socket -> Expectation
expectNoData connection = do
  threadDelay 100000
  -- Windows blocking recv cannot be interrupted by a timeout while no data
  -- arrives. This public nonblocking probe observes the incomplete frame.
  allocaBytes 1 (\buffer -> recvBufNoWait connection buffer 1) >>= (`shouldBe` (-1))

expectListenerClosed :: PortNumber -> Expectation
expectListenerClosed port = do
  result <- try (withClient port (const (pure ()))) :: IO (Either IOException ())
  result `shouldSatisfy` either (const True) (const False)

expectCanRestart :: PortNumber -> Expectation
expectCanRestart port = do
  ready <- newEmptyMVar
  withAsync (runServer port (putMVar ready)) $ \server -> do
    startup <- await "restart on the same port" (race (readMVar ready) (wait server))
    startup `shouldBe` Left port

expectEnd :: [Socket] -> String -> Expectation
expectEnd connections winner = forM_ connections $ \connection -> do
  expectLine connection ("GAME_OVER " ++ winner ++ " OPPONENT_LEFT")
  expectClosed connection

quitAndWait :: Socket -> [Socket] -> String -> Async () -> Expectation
quitAndWait actor connections winner server = do
  sendText actor "QUIT\n"
  expectEnd connections winner
  await "server exit after QUIT" (wait server)

await :: String -> IO a -> IO a
await label action = do
  result <- timeout 10000000 action
  maybe (ioError (userError ("C-02 timeout: " ++ label))) pure result

awaitSocket :: String -> Socket -> IO a -> IO a
awaitSocket label connection action =
  withAsync (threadDelay 10000000 >> release) $ \_ -> await label action
  where
    release = do
      void (try (shutdown connection ShutdownBoth) :: IO (Either IOException ()))
      close connection
