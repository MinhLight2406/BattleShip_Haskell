-- | Session-local ownership. Only this worker submits coordinator mutations.
module Battleship.GameWorker
  ( GameWorker, GameRequest (..), withGameWorker, withGameWorkerWithCapacity
  , submitRequest, enqueueRequest, disconnectPlayer, stopGameWorker
  , readWorkerState, nextWorkerFrame, isWorkerSlow, workerQueuedFrames
  , mailboxSize, workerThreadId, workerCapability
  ) where

import qualified Battleship.Coordinator as C
import Battleship.Protocol (ProtocolError)
import Battleship.Types
import Control.Concurrent (ThreadId, getNumCapabilities, myThreadId, threadCapability)
import Control.Concurrent.Async (race, waitCatchSTM, withAsyncOn)
import Control.Concurrent.STM
import Control.Exception (AssertionFailed (..), SomeException, finally, mask, throwIO, try)
import Control.Monad (forM_, void, when)
import qualified Data.ByteString as BS
import qualified Data.Set as Set
import Numeric.Natural (Natural)

data GameRequest
  = Admit PlayerId
  | Payload PlayerId BS.ByteString
  | OversizedInput PlayerId
  | CommandRequest PlayerId Command

type Result = Either ProtocolError Bool
data Envelope = Envelope GameRequest (TMVar Result)

data GameWorker = GameWorker
  { coordinator :: C.Coordinator
  , mailbox :: TBQueue Envelope
  , disconnected :: TVar (Set.Set PlayerId)
  , stopping :: TVar Bool
  , completion :: TMVar (Either SomeException ())
  , workerThreadId :: ThreadId
  , workerCapability :: Int
  }

withGameWorker :: Int -> Step -> GameState -> (GameWorker -> IO a) -> IO a
withGameWorker capability = withGameWorkerWithCapacity capability 32 128

-- Small capacities support deterministic tests; production uses 32/128.
withGameWorkerWithCapacity :: Int -> Natural -> Natural -> Step -> GameState
  -> (GameWorker -> IO a) -> IO a
withGameWorkerWithCapacity capability capacity outboxCapacity core initial action = do
  count <- getNumCapabilities
  when (capability < 0 || capability >= count) $
    ioError (userError "Game worker capability must be in [0, runtime capabilities)")
  when (capacity < 1) $ ioError (userError "Game mailbox capacity must be at least 1")
  ready <- newEmptyTMVarIO
  done <- newEmptyTMVarIO
  withAsyncOn capability (mask $ \restore -> do
    outcome <- try $ restore $ do
      owner <- myThreadId
      (actual, pinned) <- threadCapability owner
      when (actual /= capability || not pinned) $
        throwIO (AssertionFailed "Game worker capability does not match requested placement")
      worker <- atomically $ GameWorker <$> C.newCoordinatorWithCapacity outboxCapacity initial
        <*> newTBQueue capacity <*> newTVar Set.empty <*> newTVar False
        <*> pure done <*> pure owner <*> pure actual
      atomically (putTMVar ready worker)
      run worker
    -- Publish shutdown and discard pending envelopes together: no producer
    -- can slip a new request between flushing the queue and announcing exit.
    atomically $ do
      known <- tryReadTMVar ready
      forM_ known $ \worker -> stopGameWorker worker >> void (flushTBQueue (mailbox worker))
      putTMVar done outcome
    either throwIO pure outcome) $ \workerAsync -> do
      worker <- atomically $ readTMVar ready `orElse` (waitCatchSTM workerAsync >>= either throwSTM
        (const (throwSTM (AssertionFailed "Game worker exited before initialization"))))
      -- A scoped failure watcher avoids a detached link notification arriving
      -- after the callback has already returned or handled the same failure.
      (race (action worker) (atomically $ waitCatchSTM workerAsync >>= either throwSTM (const retry))
        >>= either pure (const (throwIO (AssertionFailed "Worker failure watcher returned"))))
        `finally` atomically (stopGameWorker worker)
  where
    run worker = do
      selection <- atomically $ do
        stop <- readTVar (stopping worker)
        departures <- readTVar (disconnected worker)
        if stop then pure Nothing
        else case Set.minView departures of
          Just (player, rest) -> writeTVar (disconnected worker) rest >> pure (Just (Left player))
          Nothing -> Just . Right <$> readTBQueue (mailbox worker)
      case selection of
        Nothing -> pure ()
        Just request -> do
          keepRunning <- atomically $ case request of
            Left player -> checked =<< C.submitCommand core (coordinator worker) player Quit
            Right (Envelope message ack) -> do
              result <- case message of
                Admit player -> C.welcomePlayer (coordinator worker) player
                Payload player bytes -> C.submitPayload core (coordinator worker) player bytes
                OversizedInput player -> C.submitTooLong core (coordinator worker) player
                CommandRequest player command -> C.submitCommand core (coordinator worker) player command
              keep <- checked result
              putTMVar ack result
              pure keep
          when keepRunning (run worker)
    checked (Left fault) = throwSTM (AssertionFailed
      ("Coordinator produced an unencodable response: " ++ show fault))
    checked (Right keep) = pure keep

-- Queue admission and ack waiting both observe shutdown. A full mailbox never
-- hides cancellation or worker failure; each reader waits before its next frame.
enqueueRequest :: GameWorker -> GameRequest -> STM (STM Result)
enqueueRequest worker message = do
  ended <- tryReadTMVar (completion worker)
  stop <- readTVar (stopping worker)
  case ended of
    Just result -> pure (endResult result)
    Nothing | stop -> pure (pure (Right False))
    Nothing -> do
      ack <- newEmptyTMVar
      writeTBQueue (mailbox worker) (Envelope message ack)
      pure (readTMVar ack `orElse` (readTMVar (completion worker) >>= endResult))
  where
    endResult = either throwSTM (const (pure (Right False)))

submitRequest :: GameWorker -> GameRequest -> IO Result
submitRequest worker message = atomically (enqueueRequest worker message) >>= atomically

-- Idempotent, finite control state (at most P1/P2), independent of FIFO space.
disconnectPlayer :: GameWorker -> PlayerId -> STM ()
disconnectPlayer worker player = modifyTVar' (disconnected worker) (Set.insert player)

stopGameWorker :: GameWorker -> STM ()
stopGameWorker worker = writeTVar (stopping worker) True

mailboxSize :: GameWorker -> STM Natural
mailboxSize = lengthTBQueue . mailbox

readWorkerState :: GameWorker -> STM GameState
readWorkerState = C.readGameState . coordinator

nextWorkerFrame :: GameWorker -> PlayerId -> STM (Maybe BS.ByteString)
nextWorkerFrame = C.nextFrame . coordinator

isWorkerSlow :: GameWorker -> PlayerId -> STM Bool
isWorkerSlow = C.isSlowClient . coordinator

workerQueuedFrames :: GameWorker -> PlayerId -> STM Natural
workerQueuedFrames = C.queuedFrameCount . coordinator
