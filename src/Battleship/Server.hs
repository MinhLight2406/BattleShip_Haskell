-- | Two permanent TCP slots; STM owns the game and each socket has one writer.
module Battleship.Server
  ( ServerConfig, defaultServerConfig, parseServerConfig, serverBindHost, serverReadyFile
  , runServer, runServerWith, runServerConfigured
  , GameRuntimeConfig, defaultGameRuntimeConfig, parseGameRuntimeConfig, gameCapability, runServerWithRuntime
  , runRoomServerWithRuntime
  ) where

import Battleship.GameWorker
import Battleship.Types
import Battleship.Protocol
import qualified Battleship.Rules as Rules
import Control.Concurrent (getNumCapabilities, threadDelay)
import Control.Concurrent.Async (Async, async, cancel, link, poll, race_, wait, withAsync)
import Control.Concurrent.STM (atomically, check)
import Control.Concurrent.MVar
  ( MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar,
    tryPutMVar, tryReadMVar )
import Control.Exception (AssertionFailed (..), IOException, SomeException, bracket, bracket_, bracketOnError, catch, finally, throwIO)
import Control.Monad (filterM, forM_, forever, void, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Bits (complement)
import qualified Data.Map.Strict as Map
import Network.Socket
  ( Family (AF_INET), HostAddress, PortNumber, ShutdownCmd (ShutdownBoth, ShutdownSend), SockAddr (SockAddrInet), Socket,
    SocketOption (SockOpt, ReuseAddr, SendBuffer), SocketType (Stream), accept, bind, close,
    defaultProtocol, listen, setSocketOption, shutdown, socket, socketPort,
    tupleToHostAddress, withSocketsDo )
import Network.Socket.ByteString (recv, sendAll)
import System.Directory (removeFile, renameFile)
import System.FilePath (isAbsolute, takeDirectory, takeFileName)
import System.IO (hClose, openBinaryTempFile)
import System.IO.Error (isDoesNotExistError)
import System.Info (os)
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- The constructor is private: invalid configuration cannot reach socket IO.
data ServerConfig = ServerConfig String HostAddress (Maybe FilePath) deriving (Eq, Show)

serverBindHost :: ServerConfig -> String
serverBindHost (ServerConfig host _ _) = host

serverReadyFile :: ServerConfig -> Maybe FilePath
serverReadyFile (ServerConfig _ _ path) = path

bindAddress :: ServerConfig -> HostAddress
bindAddress (ServerConfig _ address _) = address

defaultServerConfig :: ServerConfig
defaultServerConfig = ServerConfig "127.0.0.1" (tupleToHostAddress (127, 0, 0, 1)) Nothing

newtype GameRuntimeConfig = GameRuntimeConfig Int deriving (Eq, Show)

defaultGameRuntimeConfig :: GameRuntimeConfig
defaultGameRuntimeConfig = GameRuntimeConfig 0

gameCapability :: GameRuntimeConfig -> Int
gameCapability (GameRuntimeConfig capability) = capability

parseGameRuntimeConfig :: Int -> Maybe String -> Either String GameRuntimeConfig
parseGameRuntimeConfig count setting = case readMaybe value :: Maybe Integer of
  Just capability | count > 0 && capability >= 0 && capability < toInteger count
    && show capability == value -> Right (GameRuntimeConfig (fromInteger capability))
  _ -> Left "BATTLESHIP_GAME_CAPABILITY must be a canonical integer in [0, runtime capabilities)"
  where value = maybe "0" id setting

-- | Missing env values keep native defaults; explicitly empty values are errors.
-- Only canonical IPv4 and the localhost alias are accepted, without DNS lookup.
parseServerConfig :: Maybe String -> Maybe FilePath -> Either String ServerConfig
parseServerConfig hostSetting readySetting = do
  let host = maybe "127.0.0.1" id hostSetting
  address <- case host of
    "localhost" -> Right (tupleToHostAddress (127, 0, 0, 1))
    _ -> case traverse octet (splitDots host) of
      Just [a, b, c, d] -> Right (tupleToHostAddress (a, b, c, d))
      _ -> Left "BATTLESHIP_BIND_HOST must be a canonical IPv4 address or localhost (no URL or port)"
  case readySetting of
    Just path | not (isAbsolute path) || '\0' `elem` path ->
      Left "BATTLESHIP_READY_FILE must be a nonempty absolute file path"
    _ -> Right (ServerConfig host address readySetting)
  where
    splitDots value = case break (== '.') value of
      (part, []) -> [part]
      (part, _ : rest) -> part : splitDots rest
    octet value = case readMaybe value :: Maybe Integer of
      Just number | number >= 0 && number <= 255 && show number == value -> Just (fromInteger number)
      _ -> Nothing

data Lobby = Lobby
  { clients :: [(PlayerId, Socket)]
  , stopped :: Bool
  , drained :: [PlayerId]
  }

-- Each room owns an independent coordinator, worker and pair of TCP seats.
-- The bridge supplies a short opaque room key before the normal game frames.
data RoomSession = RoomSession
  { roomWorker :: GameWorker
  , roomLobby :: MVar Lobby
  , roomFinished :: MVar (Either SomeException ())
  , roomSeats :: MVar [PlayerId]
  , roomTask :: Async ()
  }

type RoomRegistry = MVar (Map.Map String RoomSession)
type ConnectionTasks = MVar [Async ()]

-- | Bind IPv4 loopback only. Port 0 lets the OS choose an unused port.
-- The callback runs after listen and receives the actual port (also for tests).
-- Return on QUIT/EOF/socket failure; exceptions/cancellation clean up all
-- sockets and workers. There is one session and no replacement player.
runServer :: PortNumber -> (PortNumber -> IO ()) -> IO ()
runServer = runServerWith Rules.step initialGameState

-- | Docker/native configuration; the same Rules and initial state as runServer.
-- The marker is written after listen, before the callback; all exits remove it.
runServerConfigured :: ServerConfig -> PortNumber -> (PortNumber -> IO ()) -> IO ()
runServerConfigured config = runServerWithConfig config Rules.step initialGameState

-- | C-03/Đợt 6 seam: replace only the supplied Step/initial state when working
-- with a stub. The default already uses the completed A/B core. CLI clients
-- cannot select a core or supply a state. No extra victory logic is needed.
runServerWith :: Step -> GameState -> PortNumber -> (PortNumber -> IO ()) -> IO ()
runServerWith = runServerWithConfig defaultServerConfig

runServerWithConfig :: ServerConfig -> Step -> GameState -> PortNumber -> (PortNumber -> IO ()) -> IO ()
runServerWithConfig = runServerWithRuntime defaultGameRuntimeConfig

runServerWithRuntime :: GameRuntimeConfig -> ServerConfig -> Step -> GameState
  -> PortNumber -> (PortNumber -> IO ()) -> IO ()
runServerWithRuntime runtime config core initial port onListening = withSocketsDo $ do
  count <- getNumCapabilities
  _ <- either (ioError . userError) pure (parseGameRuntimeConfig count (Just (show (gameCapability runtime))))
  bracket_ clearMarker clearMarker $
   withGameWorker (gameCapability runtime) core initial $ \worker ->
    bracket (openListener config port) close $ \listener -> do
      lobby <- newMVar (Lobby [] False [])
      finished <- newEmptyMVar
      actual <- socketPort listener
      forM_ (serverReadyFile config) writeReadyMarker
      onListening actual
      withAsync (acceptClients worker listener lobby finished [P1, P2]) $ \acceptor ->
        race_ (wait acceptor) (readMVar finished >>= either throwIO pure)
          `finally` modifyMVar_ lobby (\state -> do
            -- Windows blocking socket calls need shutdown/close before joining
            -- their workers. Shutdown first preserves the final response/FIN;
            -- closing first can reset the peer and lose GAME_OVER.
            close listener
            forM_ (clients state) (closeConnection . snd)
            pure state { stopped = True })
  where
    clearMarker = forM_ (serverReadyFile config) removeIfPresent

-- | Internet-room transport mode. Every TCP peer starts with "ROOM <key> P1\n"
-- or "ROOM <key> P2\n";
-- all subsequent frames use the unchanged D-01 game protocol. Workers are
-- created lazily and isolated by room key, so different pairs never share a
-- GameState or coordinator.
runRoomServerWithRuntime :: GameRuntimeConfig -> ServerConfig -> Step -> GameState
  -> PortNumber -> (PortNumber -> IO ()) -> IO ()
runRoomServerWithRuntime runtime config core initial port onListening = withSocketsDo $ do
  count <- getNumCapabilities
  _ <- either (ioError . userError) pure (parseGameRuntimeConfig count (Just (show (gameCapability runtime))))
  bracket_ clearMarker clearMarker $ do
    rooms <- newMVar Map.empty
    tasks <- newMVar []
    bracket (openListener config port) close $ \listener -> do
      actual <- socketPort listener
      forM_ (serverReadyFile config) writeReadyMarker
      onListening actual
      withAsync (acceptRoomConnections runtime core initial rooms tasks listener) $ \acceptor ->
        withAsync (forever (threadDelay 30000000 >> pruneRooms rooms)) $ \sweeper ->
          (race_ (wait acceptor) (wait sweeper)) `finally` (do
            close listener
            cancel sweeper
            cancel acceptor
            roomEntries <- modifyMVar rooms (\current -> pure (Map.empty, Map.elems current))
            forM_ roomEntries $ \room -> do
              modifyMVar_ (roomLobby room) $ \state -> do
                forM_ (clients state) (closeConnection . snd)
                pure state { stopped = True }
              cancel (roomTask room)
            connectionEntries <- modifyMVar tasks (\current -> pure ([], current))
            mapM_ cancel connectionEntries)
  where
    clearMarker = forM_ (serverReadyFile config) removeIfPresent

acceptRoomConnections :: GameRuntimeConfig -> Step -> GameState -> RoomRegistry -> ConnectionTasks -> Socket -> IO ()
acceptRoomConnections runtime core initial rooms tasks listener = forever $ do
  (connection, _) <- accept listener
  setSocketOption connection SendBuffer 65536
  modifyMVar_ tasks $ \current -> do
    active <- filterM (fmap (maybe True (const False)) . poll) current
    task <- async (handleRoomConnection runtime core initial rooms connection `catch` ignoreIOException)
    pure (task : active)

handleRoomConnection :: GameRuntimeConfig -> Step -> GameState -> RoomRegistry -> Socket -> IO ()
handleRoomConnection runtime core initial rooms connection = bracket_ (pure ()) (closeConnection connection) $ do
  handshake <- timeout 10000000 (readRoomHandshake connection)
  case handshake of
    Just (Just (key, player)) -> do
      room <- getOrCreateRoom runtime core initial rooms key
      case room of
        Nothing -> reject
        Just session -> do
          actor <- modifyMVar (roomSeats session) $ \seats ->
            if player `elem` seats then pure (seats, Nothing)
            else pure (player : seats, Just player)
          case actor of
            Nothing -> reject
            Just admittedPlayer -> do
              admitted <- submitRequest (roomWorker session) (Admit admittedPlayer) >>= requireEncoded
              if not admitted then reject else do
                modifyMVar_ (roomLobby session) $ \state ->
                  pure state { clients = clients state ++ [(admittedPlayer, connection)] }
                serveRoomClient (roomWorker session) (roomLobby session) (roomFinished session) admittedPlayer connection
    _ -> reject
  where
    reject = void (sendResponse connection (Rejected ServerFull))

readRoomHandshake :: Socket -> IO (Maybe (String, PlayerId))
readRoomHandshake connection = go BS.empty
  where
    go pending = do
      chunk <- recv connection 1
      if BS.null chunk then pure Nothing
      else if chunk == BS.singleton 10 then pure (parseKey (stripCR pending))
      else if BS.length pending >= 72 then pure Nothing
      else go (pending <> chunk)
    stripCR bytes = if not (BS.null bytes) && BS.last bytes == 13 then BS.init bytes else bytes
    parseKey bytes = case words (BSC.unpack bytes) of
      ["ROOM", key, "P1"] | validKey key -> Just (key, P1)
      ["ROOM", key, "P2"] | validKey key -> Just (key, P2)
      _ -> Nothing
    validKey key = not (null key) && length key <= 64 && all validKeyChar key
    validKeyChar char = char `elem` ['a'..'z'] || char `elem` ['A'..'Z'] ||
      char `elem` ['0'..'9'] || char == '-' || char == '_'

getOrCreateRoom :: GameRuntimeConfig -> Step -> GameState -> RoomRegistry -> String -> IO (Maybe RoomSession)
getOrCreateRoom runtime core initial registry key = do
  pruneRooms registry
  modifyMVar registry $ \rooms -> case Map.lookup key rooms of
    Just room -> pure (rooms, Just room)
    Nothing | Map.size rooms >= 512 -> pure (rooms, Nothing)
    Nothing -> do
      room <- startRoom runtime core initial
      pure (Map.insert key room rooms, Just room)

startRoom :: GameRuntimeConfig -> Step -> GameState -> IO RoomSession
startRoom runtime core initial = do
  ready <- newEmptyMVar
  finished <- newEmptyMVar
  task <- async $ withGameWorker (gameCapability runtime) core initial $ \worker -> do
    putMVar ready worker
    readMVar finished >>= either throwIO pure
  worker <- readMVar ready
  RoomSession worker <$> newMVar (Lobby [] False []) <*> pure finished <*> newMVar [] <*> pure task

pruneRooms :: RoomRegistry -> IO ()
pruneRooms registry = modifyMVar_ registry $ \rooms -> do
  live <- filterM (fmap (maybe True (const False)) . tryReadMVar . roomFinished . snd) (Map.toList rooms)
  let retained = Map.fromList live
      expired = Map.elems (Map.difference rooms retained)
  forM_ expired (cancel . roomTask)
  pure retained

serveRoomClient :: GameWorker -> MVar Lobby -> MVar (Either SomeException ()) -> PlayerId -> Socket -> IO ()
serveRoomClient worker lobby finished actor connection = do
  readerDone <- newEmptyMVar
  withAsync (closeSlowClient worker actor connection) $ \_ -> withAsync
    (writeFrames worker lobby finished actor connection readerDone
      `catch` reportFailure lobby finished) $ \writer -> do
    link writer
    withAsync
      ((readFrames connection BS.empty (handleFrame worker actor)
        `catch` ignoreIOException
        `catch` reportFailure lobby finished)
        `finally` ((clientLeft worker lobby actor >> discardInput connection)
          `finally` void (tryPutMVar readerDone ()))) $ \reader -> do
      link reader
      wait reader

openListener :: ServerConfig -> PortNumber -> IO Socket
openListener config port = open `catch` report
  where
    report :: IOException -> IO Socket
    report exception = ioError (userError ("Cannot listen on " ++ serverBindHost config ++ ":" ++ show port ++ ": " ++ show exception))
    open = bracketOnError (socket AF_INET Stream defaultProtocol) close $ \listener -> do
      -- Winsock requires SO_EXCLUSIVEADDRUSE, including wildcard/specific clashes.
      -- Its value is ~SO_REUSEADDR; reuse on Unix permits restart after TIME_WAIT.
      if os == "mingw32" then case ReuseAddr of
        SockOpt level option -> setSocketOption listener (SockOpt level (complement option)) 1
      else setSocketOption listener ReuseAddr 1
      bind listener (SockAddrInet port (bindAddress config))
      listen listener 8
      pure listener

-- Publish a complete marker by rename in the same directory, including Windows.
writeReadyMarker :: FilePath -> IO ()
writeReadyMarker destination = bracket
  (openBinaryTempFile (takeDirectory destination) (takeFileName destination ++ ".tmp"))
  (\(temporary, handle) -> hClose handle `finally` removeIfPresent temporary)
  (\(temporary, handle) -> do
    BS.hPut handle (BSC.pack "ready\n")
    hClose handle
    renameFile temporary destination)

removeIfPresent :: FilePath -> IO ()
removeIfPresent path = removeFile path `catch` \exception ->
  if isDoesNotExistError exception then pure () else throwIO (exception :: IOException)

-- Nested brackets/withAsync own the two sockets/readers for the whole session.
-- Rejected connections have a separate short bracket and never get a worker.
acceptClients :: GameWorker -> Socket -> MVar Lobby -> MVar (Either SomeException ()) -> [PlayerId] -> IO ()
acceptClients worker listener lobby finished available = case available of
  [] -> forever $ bracket (fst <$> accept listener) close $ \connection ->
    void (sendResponse connection (Rejected ServerFull))
  actor : remaining -> bracket (fst <$> accept listener) close $ \connection -> do
    -- Bound kernel buffering too: a large auto-tuned buffer can hide a
    -- nonreading peer long after the bounded application queue has drained.
    setSocketOption connection SendBuffer 65536
    welcomed <- modifyMVar lobby $ \state ->
      if stopped state then pure (state, False)
      else do
        admitted <- submitRequest worker (Admit actor) >>= requireEncoded
        pure (if admitted then state { clients = clients state ++ [(actor, connection)] } else state, admitted)
    if not welcomed then do
      -- An admission can race a terminal transaction. Existing writers still
      -- own the final batch; don't unwind their brackets before they drain.
      admitted <- clients <$> readMVar lobby
      when (not (null admitted)) (readMVar finished >>= either throwIO pure)
    else do
      readerDone <- newEmptyMVar
      withAsync (closeSlowClient worker actor connection) $ \_ -> withAsync
        (writeFrames worker lobby finished actor connection readerDone
          `catch` reportFailure lobby finished) $ \writer -> do
        link writer
        withAsync
          ((readFrames connection BS.empty (handleFrame worker actor)
            `catch` ignoreIOException
            `catch` reportFailure lobby finished)
            `finally` ((clientLeft worker lobby actor >> discardInput connection)
              `finally` void (tryPutMVar readerDone ()))) $ \reader -> do
          link reader
          acceptClients worker listener lobby finished remaining

-- Readers do only framing and mailbox submission. State and response batches
-- commit together; no MVar serializes gameplay and no socket IO occurs in STM.
handleFrame :: GameWorker -> PlayerId -> Maybe BS.ByteString -> IO Bool
handleFrame worker actor frame = case frame of
  Nothing -> submitRequest worker (OversizedInput actor) >>= requireEncoded >> pure False
  Just payload -> submitRequest worker (Payload actor payload) >>= requireEncoded

clientLeft :: GameWorker -> MVar Lobby -> PlayerId -> IO ()
clientLeft worker lobby actor = do
  running <- not . stopped <$> readMVar lobby
  when running $ atomically (disconnectPlayer worker actor)

-- The STM signal is independent of the FIFO, so a full queue or blocked send
-- cannot delay closure. Existing reader/writer finalizers drain the bounded
-- queue and acknowledge cleanup; their later Quit cannot overwrite Finished.
closeSlowClient :: GameWorker -> PlayerId -> Socket -> IO ()
closeSlowClient worker actor connection = do
  atomically (isWorkerSlow worker actor >>= check)
  closeConnection connection `catch` ignoreIOException

-- Exactly one writer consumes each player's FIFO. A failed send submits Quit
-- for that socket's actor and drains/discards its queue until the end marker;
-- it cannot resign on behalf of the other player or block their writer.
writeFrames :: GameWorker -> MVar Lobby -> MVar (Either SomeException ()) -> PlayerId -> Socket -> MVar () -> IO ()
writeFrames worker lobby finished actor connection readerDone = loop True
  where
    loop usable = do
      frame <- atomically (nextWorkerFrame worker actor)
      case frame of
        Nothing -> do
          -- Deliver the final batch and FIN before closing the receive side.
          -- Closing with unread pipelined commands can reset TCP and discard
          -- GAME_OVER. Only the existing reader drains them, without step.
          shutdown connection ShutdownSend `catch` ignoreIOException
          -- Clients may keep sending or wait for server exit before closing.
          -- The bounded grace then forces their recv to unblock on Windows.
          void (timeout 200000 (readMVar readerDone))
          closeConnection connection
          writerDrained worker lobby finished actor
        Just bytes -> do
          sent <- if usable then sendFrame connection bytes else pure False
          when (usable && not sent) $ do
            closeConnection connection
            clientLeft worker lobby actor
          loop sent

-- Signal completion only after all admitted writers have drained their final
-- batches. The MVar protects socket ownership/drain bookkeeping, not GameState.
writerDrained :: GameWorker -> MVar Lobby -> MVar (Either SomeException ()) -> PlayerId -> IO ()
writerDrained worker lobby finished actor = modifyMVar_ lobby $ \state -> do
  current <- atomically (readWorkerState worker)
  let next = state { drained = actor : drained state }
      terminal = case gamePhase current of Finished _ _ -> True; _ -> False
  when (not (stopped next) && terminal && all ((`elem` drained next) . fst) (clients next)) $
    void (tryPutMVar finished (Right ()))
  pure next

requireEncoded :: Either ProtocolError a -> IO a
requireEncoded = either (throwIO . AssertionFailed . ("Coordinator produced an unencodable response: " ++) . show) pure

-- Stop before the reader's Quit finalizer can announce normal completion.
-- Otherwise normal session shutdown can race and hide an internal core error.
reportFailure :: MVar Lobby -> MVar (Either SomeException ()) -> SomeException -> IO a
reportFailure lobby finished exception = do
  modifyMVar_ lobby (\state -> pure state { stopped = True })
  void (tryPutMVar finished (Left exception))
  throwIO exception

sendResponse :: Socket -> Response -> IO Bool
sendResponse connection response = requireEncoded (encodeResponse response) >>= sendFrame connection

-- Reuse D-02 framing. EOF drops an unfinished tail, then the reader's finalizer
-- submits Quit unless a terminal transition has already ended the session.
readFrames :: Socket -> BS.ByteString -> (Maybe BS.ByteString -> IO Bool) -> IO ()
readFrames connection pending handle = do
  chunk <- recv connection (maxLineBytes + 2 - BS.length pending)
  when (not (BS.null chunk)) $ consume (feedFrames pending chunk)
  where
    consume (payload : rest, next) = do
      keepReading <- handle (Just payload)
      when keepReading $ consume (rest, next)
    consume ([], Left _) = void (handle Nothing)
    consume ([], Right next) = readFrames connection next handle

-- The session has ended. Drop remaining bytes with a fixed-size buffer; never
-- parse commands or change gameplay here. The writer bounds this drain by
-- closing the socket after its grace period, including blocking Windows recv.
discardInput :: Socket -> IO ()
discardInput connection = drain `catch` ignoreIOException
  where
    drain = do
      chunk <- recv connection 4096
      when (not (BS.null chunk)) drain

-- A peer that stops reading must not hold its writer/shutdown forever.
-- Only expected socket IO failures are absorbed; cancellation still propagates.
sendFrame :: Socket -> BS.ByteString -> IO Bool
sendFrame connection frame =
  (withAsync (threadDelay 2000000 >> closeConnection connection) $ \_ ->
    -- A timeout alone cannot interrupt a Windows blocking foreign send.
    -- Its independent watchdog closes the socket to release that call.
    fmap (== Just ()) $ timeout 2000000 $ sendAll connection frame)
    `catch` failedSend
  where
    failedSend :: IOException -> IO Bool
    failedSend _ = pure False

closeConnection :: Socket -> IO ()
closeConnection connection = do
  shutdown connection ShutdownBoth `catch` ignoreIOException
  close connection

ignoreIOException :: IOException -> IO ()
ignoreIOException _ = pure ()
