-- | Two permanent TCP slots with one serialized shared game state.
module Battleship.Server (runServer, runServerWith) where

import Battleship.Coordinator (applyCommand, coordinate)
import Battleship.Types
import Battleship.Protocol
import qualified Battleship.Rules as Rules
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (link, race_, wait, withAsync)
import Control.Concurrent.MVar
  ( MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, readMVar,
    tryPutMVar )
import Control.Exception (AssertionFailed (..), IOException, SomeException, bracket, bracketOnError, catch, finally, throwIO)
import Control.Monad (forM_, forever, void, when)
import qualified Data.ByteString as BS
import Network.Socket
  ( Family (AF_INET), PortNumber, ShutdownCmd (ShutdownBoth), SockAddr (SockAddrInet), Socket,
    SocketOption (ReuseAddr), SocketType (Stream), accept, bind, close,
    defaultProtocol, listen, setSocketOption, shutdown, socket, socketPort,
    tupleToHostAddress, withSocketsDo )
import Network.Socket.ByteString (recv, sendAll)
import System.Info (os)
import System.Timeout (timeout)

data Lobby = Lobby
  { clients :: [(PlayerId, Socket)]
  , ended :: Bool
  , game :: GameState
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
    lobby <- newMVar (Lobby [] False initial)
    finished <- newEmptyMVar
    socketPort listener >>= onListening
    withAsync (acceptClients core listener lobby finished [P1, P2]) $ \acceptor ->
      race_ (wait acceptor) (readMVar finished >>= either throwIO pure)
        `finally` modifyMVar_ lobby (\state -> do
          -- Windows blocking socket calls need shutdown/close before joining
          -- their workers. Shutdown first preserves the final response/FIN;
          -- closing first can reset the peer and lose GAME_OVER.
          close listener
          forM_ (clients state) (closeConnection . snd)
          pure state { ended = True })

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
acceptClients :: Step -> Socket -> MVar Lobby -> MVar (Either SomeException ()) -> [PlayerId] -> IO ()
acceptClients core listener lobby finished available = case available of
  [] -> forever $ bracket (fst <$> accept listener) close $ \connection ->
    void (sendResponse connection (Rejected ServerFull))
  actor : remaining -> bracket (fst <$> accept listener) close $ \connection -> do
    welcomed <- modifyMVar lobby $ \state ->
      if ended state then pure (state, False)
      else do
        sent <- sendResponse connection (Welcome actor)
        pure (state { clients = clients state ++ [(actor, connection)] }, sent)
    if not welcomed then clientLeft core lobby finished actor
    else withAsync
      ((readFrames connection BS.empty (handleFrame core lobby finished actor connection)
          `catch` ignoreIOException
          `catch` reportFailure lobby finished)
        `finally` clientLeft core lobby finished actor) $ \reader -> do
      link reader
      acceptClients core listener lobby finished remaining

-- All writes to admitted sockets share this lock: a response cannot interleave
-- bytes with the final broadcast, or appear before that socket's WELCOME.
-- Parsing, step, state commit and ordered writes share the same lock. A
-- rejected command never consumes a turn. Only registered sockets receive
-- events; player identity always comes from acceptClients, never the payload.
-- ponytail: one MVar also covers writes for a two-client MVP; move writes to
-- per-client queues if slow peers need independent delivery in a later task.
handleFrame :: Step -> MVar Lobby -> MVar (Either SomeException ()) -> PlayerId -> Socket -> Maybe BS.ByteString -> IO Bool
handleFrame core lobby finished actor connection frame = modifyMVar lobby $ \state ->
  if ended state then pure (state, False)
  else case frame of
    Nothing -> sendResponse connection (Rejected TooLong) >> pure (state, False)
    Just payload -> do
      transition <- requireEncoded (coordinate core actor payload (game state))
      next <- publishTransition finished state transition
      pure (next, not (ended next))

clientLeft :: Step -> MVar Lobby -> MVar (Either SomeException ()) -> PlayerId -> IO ()
clientLeft core lobby finished actor = modifyMVar_ lobby $ \state ->
  if ended state then pure state
  else do
    transition <- requireEncoded (applyCommand core actor Quit (game state))
    publishTransition finished state transition

publishTransition :: MVar (Either SomeException ()) -> Lobby -> (GameState, [(PlayerId, BS.ByteString)]) -> IO Lobby
publishTransition finished state (next, frames) = do
  forM_ frames $ \(recipient, frame) -> forM_ (lookup recipient (clients state)) $ \connection -> do
    sent <- sendFrame connection frame
    -- Wake that socket's reader; its finalizer submits Quit for the correct
    -- player. A failed send must never make the other player resign.
    when (not sent) (closeConnection connection)
  let terminal = case gamePhase next of Finished _ _ -> True; _ -> False
  when terminal (void (tryPutMVar finished (Right ())))
  pure state { game = next, ended = terminal }

requireEncoded :: Either ProtocolError a -> IO a
requireEncoded = either (throwIO . AssertionFailed . ("Coordinator produced an unencodable response: " ++) . show) pure

-- Stop before the reader's Quit finalizer can announce normal completion.
-- Otherwise normal session shutdown can race and hide an internal core error.
reportFailure :: MVar Lobby -> MVar (Either SomeException ()) -> SomeException -> IO a
reportFailure lobby finished exception = do
  modifyMVar_ lobby (\state -> pure state { ended = True })
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

-- A peer that stops reading must not hold the lobby lock/shutdown forever.
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
