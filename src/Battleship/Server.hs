-- | Two permanent TCP slots; STM owns the game and each socket has one writer.
module Battleship.Server (runServer, runServerWith) where

import Battleship.Coordinator
  ( Coordinator, newCoordinator, nextFrame, readGameState, submitCommand,
    submitPayload, submitTooLong, welcomePlayer )
import Battleship.Types
import Battleship.Protocol
import qualified Battleship.Rules as Rules
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (link, race_, wait, withAsync)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.MVar
  ( MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, readMVar,
    tryPutMVar )
import Control.Exception (AssertionFailed (..), IOException, SomeException, bracket, bracketOnError, catch, finally, throwIO)
import Control.Monad (forM_, forever, void, when)
import qualified Data.ByteString as BS
import Network.Socket
  ( Family (AF_INET), PortNumber, ShutdownCmd (ShutdownBoth, ShutdownSend), SockAddr (SockAddrInet), Socket,
    SocketOption (ReuseAddr), SocketType (Stream), accept, bind, close,
    defaultProtocol, listen, setSocketOption, shutdown, socket, socketPort,
    tupleToHostAddress, withSocketsDo )
import Network.Socket.ByteString (recv, sendAll)
import System.Info (os)
import System.Timeout (timeout)

data Lobby = Lobby
  { clients :: [(PlayerId, Socket)]
  , stopped :: Bool
  , drained :: [PlayerId]
  }

-- | Bind IPv4 loopback only. Port 0 lets the OS choose an unused port.
-- The callback runs after listen and receives the actual port (also for tests).
-- Return on QUIT/EOF/socket failure; exceptions/cancellation clean up all
-- sockets and workers. There is one session and no replacement player.
runServer :: PortNumber -> (PortNumber -> IO ()) -> IO ()
runServer = runServerWith Rules.step initialGameState

-- | C-03/Đợt 6 seam: replace only the supplied Step/initial state when working
-- with a stub. The default already uses the completed A/B core. CLI clients
-- cannot select a core or supply a state. No extra victory logic is needed.
runServerWith :: Step -> GameState -> PortNumber -> (PortNumber -> IO ()) -> IO ()
runServerWith core initial port onListening = withSocketsDo $
  bracket (openListener port) close $ \listener -> do
    coordinator <- atomically (newCoordinator initial)
    lobby <- newMVar (Lobby [] False [])
    finished <- newEmptyMVar
    socketPort listener >>= onListening
    withAsync (acceptClients core coordinator listener lobby finished [P1, P2]) $ \acceptor ->
      race_ (wait acceptor) (readMVar finished >>= either throwIO pure)
        `finally` modifyMVar_ lobby (\state -> do
          -- Windows blocking socket calls need shutdown/close before joining
          -- their workers. Shutdown first preserves the final response/FIN;
          -- closing first can reset the peer and lose GAME_OVER.
          close listener
          forM_ (clients state) (closeConnection . snd)
          pure state { stopped = True })

openListener :: PortNumber -> IO Socket
openListener port = bracketOnError (socket AF_INET Stream defaultProtocol) close $ \listener -> do
  -- On Windows SO_REUSEADDR permits another live listener on the same port.
  -- Keep exclusive binding there; Unix needs reuse for restart after TIME_WAIT.
  when (os /= "mingw32") (setSocketOption listener ReuseAddr 1)
  bind listener (SockAddrInet port (tupleToHostAddress (127, 0, 0, 1)))
  listen listener 8
  pure listener

-- Nested brackets/withAsync own the two sockets/readers for the whole session.
-- Rejected connections have a separate short bracket and never get a worker.
acceptClients :: Step -> Coordinator -> Socket -> MVar Lobby -> MVar (Either SomeException ()) -> [PlayerId] -> IO ()
acceptClients core coordinator listener lobby finished available = case available of
  [] -> forever $ bracket (fst <$> accept listener) close $ \connection ->
    void (sendResponse connection (Rejected ServerFull))
  actor : remaining -> bracket (fst <$> accept listener) close $ \connection -> do
    welcomed <- modifyMVar lobby $ \state ->
      if stopped state then pure (state, False)
      else do
        admitted <- atomically (welcomePlayer coordinator actor) >>= requireEncoded
        pure (if admitted then state { clients = clients state ++ [(actor, connection)] } else state, admitted)
    if not welcomed then do
      -- An admission can race a terminal transaction. Existing writers still
      -- own the final batch; don't unwind their brackets before they drain.
      admitted <- clients <$> readMVar lobby
      when (not (null admitted)) (readMVar finished >>= either throwIO pure)
    else do
      readerDone <- newEmptyMVar
      withAsync
        (writeFrames core coordinator lobby finished actor connection readerDone
          `catch` reportFailure lobby finished) $ \writer -> do
        link writer
        withAsync
          ((readFrames connection BS.empty (handleFrame core coordinator actor)
            `catch` ignoreIOException
            `catch` reportFailure lobby finished)
            `finally` ((clientLeft core coordinator lobby actor >> discardInput connection)
              `finally` void (tryPutMVar readerDone ()))) $ \reader -> do
          link reader
          acceptClients core coordinator listener lobby finished remaining

-- Readers do only framing and atomic submission. State and response batches
-- commit together; no MVar serializes gameplay and no socket IO occurs in STM.
handleFrame :: Step -> Coordinator -> PlayerId -> Maybe BS.ByteString -> IO Bool
handleFrame core coordinator actor frame = case frame of
  Nothing -> atomically (submitTooLong coordinator actor) >>= requireEncoded >> pure False
  Just payload -> atomically (submitPayload core coordinator actor payload) >>= requireEncoded

clientLeft :: Step -> Coordinator -> MVar Lobby -> PlayerId -> IO ()
clientLeft core coordinator lobby actor = do
  running <- not . stopped <$> readMVar lobby
  when running $ void (atomically (submitCommand core coordinator actor Quit) >>= requireEncoded)

-- Exactly one writer consumes each player's FIFO. A failed send submits Quit
-- for that socket's actor and drains/discards its queue until the end marker;
-- it cannot resign on behalf of the other player or block their writer.
writeFrames :: Step -> Coordinator -> MVar Lobby -> MVar (Either SomeException ()) -> PlayerId -> Socket -> MVar () -> IO ()
writeFrames core coordinator lobby finished actor connection readerDone = loop True
  where
    loop usable = do
      frame <- atomically (nextFrame coordinator actor)
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
          writerDrained coordinator lobby finished actor
        Just bytes -> do
          sent <- if usable then sendFrame connection bytes else pure False
          when (usable && not sent) $ do
            closeConnection connection
            clientLeft core coordinator lobby actor
          loop sent

-- Signal completion only after all admitted writers have drained their final
-- batches. The MVar protects socket ownership/drain bookkeeping, not GameState.
writerDrained :: Coordinator -> MVar Lobby -> MVar (Either SomeException ()) -> PlayerId -> IO ()
writerDrained coordinator lobby finished actor = modifyMVar_ lobby $ \state -> do
  current <- atomically (readGameState coordinator)
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
