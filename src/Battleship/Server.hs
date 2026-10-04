-- | C-02 transport demo: two permanent slots, no placement/shot rules yet.
module Battleship.Server (runServer) where

import Battleship.Types (PlayerId (P1, P2), otherPlayer)
import Battleship.Protocol (feedFrames, maxLineBytes)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (link, race_, wait, withAsync)
import Control.Concurrent.MVar
  ( MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, readMVar,
    tryPutMVar, withMVar )
import Control.Exception (IOException, bracket, bracketOnError, catch, finally)
import Control.Monad (forM_, forever, void, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
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
  }

-- | Bind IPv4 loopback only. Port 0 lets the OS choose an unused port.
-- The callback runs after listen and receives the actual port (also for tests).
-- Return on QUIT/EOF/socket failure; exceptions/cancellation clean up all
-- sockets and workers. There is one session and no replacement player.
runServer :: PortNumber -> (PortNumber -> IO ()) -> IO ()
runServer port onListening = withSocketsDo $
  bracket (openListener port) close $ \listener -> do
    lobby <- newMVar (Lobby [] False)
    finished <- newEmptyMVar
    socketPort listener >>= onListening
    withAsync (acceptClients listener lobby finished [P1, P2]) $ \acceptor ->
      race_ (wait acceptor) (readMVar finished)
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
acceptClients :: Socket -> MVar Lobby -> MVar () -> [PlayerId] -> IO ()
acceptClients listener lobby finished available = case available of
  [] -> forever $ bracket (fst <$> accept listener) close $ \connection ->
    void (sendFrame connection "ERROR SERVER_FULL")
  actor : remaining -> bracket (fst <$> accept listener) close $ \connection -> do
    welcomed <- modifyMVar lobby $ \state ->
      if ended state then pure (state, False)
      else do
        sent <- sendFrame connection ("WELCOME 1 " ++ playerToken actor)
        pure (state { clients = clients state ++ [(actor, connection)] }, sent)
    if not welcomed then clientLeft lobby finished actor
    else withAsync
      ((readFrames connection BS.empty (handleFrame lobby connection)
          `catch` ignoreIOException)
        `finally` clientLeft lobby finished actor) $ \reader -> do
      link reader
      acceptClients listener lobby finished remaining

-- All writes to admitted sockets share this lock: a response cannot interleave
-- bytes with the final broadcast, or appear before that socket's WELCOME.
handleFrame :: MVar Lobby -> Socket -> Maybe BS.ByteString -> IO Bool
handleFrame lobby connection frame = withMVar lobby $ \state ->
  if ended state then pure False
  else case frame of
    Nothing -> sendFrame connection "ERROR LINE_TOO_LONG" >> pure False
    Just payload
      | payload == BSC.pack "QUIT" -> pure False
      -- ponytail: C-02 sample response only. Route PLACE/FIRE through the
      -- production Protocol/Coordinator in their tasks; never fake OK/SHOT.
      | otherwise -> sendFrame connection "ERROR INVALID_COMMAND"

clientLeft :: MVar Lobby -> MVar () -> PlayerId -> IO ()
clientLeft lobby finished actor = modifyMVar_ lobby $ \state ->
  if ended state then pure state
  else do
    let response = "GAME_OVER " ++ playerToken (otherPlayer actor) ++ " OPPONENT_LEFT"
    forM_ (clients state) $ \(_, connection) -> void (sendFrame connection response)
    void (tryPutMVar finished ())
    pure state { ended = True }

-- Reuse D-02 framing; C-02 keeps its sample command responses until Coordinator.
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
sendFrame :: Socket -> String -> IO Bool
sendFrame connection payload =
  (withAsync (threadDelay 2000000 >> closeConnection connection) $ \_ ->
    -- A timeout alone cannot interrupt a Windows blocking foreign send.
    -- Its independent watchdog closes the socket to release that call.
    fmap (== Just ()) $ timeout 2000000 $ sendAll connection (BSC.pack (payload ++ "\n")))
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

playerToken :: PlayerId -> String
playerToken P1 = "P1"
playerToken P2 = "P2"
