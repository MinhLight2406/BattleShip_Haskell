-- | Pure wire boundary and STM ownership of the one authoritative game.
-- No socket IO or duplicate gameplay rules belong here.
module Battleship.Coordinator
  ( coordinate, applyCommand
  , Coordinator, newCoordinator, newCoordinatorWithCapacity, readGameState, nextFrame
  , queuedFrameCount, isSlowClient
  , submitPayload, submitCommand, submitTooLong, welcomePlayer
  ) where

import Battleship.Protocol
import Battleship.Types
import Control.Concurrent.STM
import Control.Monad (filterM, forM_, void)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Numeric.Natural (Natural)

-- End markers share the FIFO with frames, so writers drain GAME_OVER first.
-- Two slots are reserved for GAME_OVER and Nothing; normal batches never retry
-- waiting for a socket writer. Slow flags are transport signals, not game state.
data Coordinator = Coordinator
  { gameState :: TVar GameState
  , player1Frames :: TBQueue (Maybe BS.ByteString)
  , player2Frames :: TBQueue (Maybe BS.ByteString)
  , frameCapacity :: Natural
  , slowClients :: TVar [PlayerId]
  }

newCoordinator :: GameState -> STM Coordinator
newCoordinator = newCoordinatorWithCapacity 128

-- | At least three normal slots are needed for OK PLACE/START/TURN, plus two
-- terminal slots. A smaller capacity is a configuration error, not a game error.
newCoordinatorWithCapacity :: Natural -> GameState -> STM Coordinator
newCoordinatorWithCapacity capacity initial
  | capacity < 5 = throwSTM (userError "Outbox capacity must be at least 5")
  | otherwise = forceState initial `seq` (Coordinator <$> newTVar initial <*> newTBQueue capacity
      <*> newTBQueue capacity <*> pure capacity <*> newTVar []
      )

readGameState :: Coordinator -> STM GameState
readGameState = readTVar . gameState

outbox :: Coordinator -> PlayerId -> TBQueue (Maybe BS.ByteString)
outbox coordinator P1 = player1Frames coordinator
outbox coordinator P2 = player2Frames coordinator

nextFrame :: Coordinator -> PlayerId -> STM (Maybe BS.ByteString)
nextFrame coordinator = readTBQueue . outbox coordinator

-- | Read-only diagnostics; the queue and its constructor remain private.
queuedFrameCount :: Coordinator -> PlayerId -> STM Natural
queuedFrameCount coordinator = lengthTBQueue . outbox coordinator

-- | Server watches this signal and closes the affected socket outside STM.
isSlowClient :: Coordinator -> PlayerId -> STM Bool
isSlowClient coordinator actor = elem actor <$> readTVar (slowClients coordinator)

-- Called only at admission. Drop frames for an absent socket and put WELCOME
-- first, atomically with the phase check. No later event can precede it.
welcomePlayer :: Coordinator -> PlayerId -> STM (Either ProtocolError Bool)
welcomePlayer coordinator actor = do
  state <- readGameState coordinator
  if terminal state then pure (Right False)
  else case encodeResponse (Welcome actor) of
    Left fault -> pure (Left fault)
    Right frame -> do
      void (flushTBQueue (outbox coordinator actor))
      writeTBQueue (outbox coordinator actor) (Just frame)
      pure (Right True)

submitPayload :: Step -> Coordinator -> PlayerId -> BS.ByteString -> STM (Either ProtocolError Bool)
submitPayload core coordinator actor payload = transact core coordinator (preparePayload core actor payload)

submitCommand :: Step -> Coordinator -> PlayerId -> Command -> STM (Either ProtocolError Bool)
submitCommand core coordinator actor command = transact core coordinator (prepareCommand core actor command)

submitTooLong :: Step -> Coordinator -> PlayerId -> STM (Either ProtocolError Bool)
submitTooLong core coordinator actor = transact core coordinator (const (rejection actor TooLong))

-- Read, validate/step, commit and enqueue every filtered frame in one STM
-- action. Encoding failure changes neither state nor queues. A full normal
-- outbox aborts this batch and applies Quit to the OLD state for the recipient,
-- not the command sender. Ties use P1 then P2; both overflowing sockets close.
transact :: Step -> Coordinator
  -> (GameState -> Either ProtocolError (Maybe GameState, [(PlayerId, BS.ByteString)]))
  -> STM (Either ProtocolError Bool)
transact core coordinator prepare = do
  previous <- readGameState coordinator
  if terminal previous then pure (Right False)
  else case prepare previous of
    Left fault -> pure (Left fault)
    Right batch@(accepted, frames) -> case validateBatch accepted frames of
      Left fault -> pure (Left fault)
      Right () -> do
        overflowing <- filterM (wouldOverflow coordinator frames) [P1, P2]
        case overflowing of
          [] -> commitBatch coordinator batch
          departing : _ -> case prepareCommand core departing Quit previous of
            Left fault -> pure (Left fault)
            Right ending@(next, finalFrames)
              | maybe False terminal next && all (isGameOver . snd) finalFrames ->
                  case validateBatch next finalFrames of
                    Left fault -> pure (Left fault)
                    Right () -> do
                      writeTVar (slowClients coordinator) overflowing
                      commitBatch coordinator ending
              | otherwise -> pure (Left InvalidMessage)

-- A terminal batch must end in exactly one canonical GAME_OVER per player.
-- Reject malformed injected cores before touching state/queues; they cannot
-- consume reserved slots or block the fallback Quit transaction.
validateBatch :: Maybe GameState -> [(PlayerId, BS.ByteString)] -> Either ProtocolError ()
validateBatch accepted frames = case accepted of
  Just state | Finished winner reason <- gamePhase state -> do
    expected <- encodeResponse (GameOver winner reason)
    forM_ [P1, P2] $ \recipient ->
      let own = [frame | (player, frame) <- frames, player == recipient]
      in case reverse own of
        lastFrame : earlier
          | lastFrame == expected && not (any isGameOver earlier) -> Right ()
        _ -> Left InvalidMessage
  _ | any (isGameOver . snd) frames -> Left InvalidMessage
    | otherwise -> Right ()

isGameOver :: BS.ByteString -> Bool
isGameOver = BS.isPrefixOf (BSC.pack "GAME_OVER ")

wouldOverflow :: Coordinator -> [(PlayerId, BS.ByteString)] -> PlayerId -> STM Bool
wouldOverflow coordinator frames recipient = do
  queued <- queuedFrameCount coordinator recipient
  let ordinary = length [() | (player, frame) <- frames, player == recipient, not (isGameOver frame)]
  pure (queued + fromIntegral ordinary > frameCapacity coordinator - 2)

-- All capacity checks precede these writes in the same transaction; concurrent
-- submissions/readers trigger STM revalidation, never a partial publication.
commitBatch :: Coordinator -> (Maybe GameState, [(PlayerId, BS.ByteString)]) -> STM (Either ProtocolError Bool)
commitBatch coordinator (accepted, frames) = do
  -- Traverse state and strict frame buffers before publication. The worker
  -- evaluates these thunks; writers do not inherit deferred rule computation.
  let forced = maybe () forceState accepted `seq`
        foldr (\(_, bytes) rest -> BS.length bytes `seq` rest) () frames
  forced `seq` pure ()
  forM_ accepted (writeTVar (gameState coordinator))
  forM_ frames $ \(recipient, frame) -> writeTBQueue (outbox coordinator recipient) (Just frame)
  let finished = maybe False terminal accepted
  if finished then forM_ [P1, P2] $ \recipient -> writeTBQueue (outbox coordinator recipient) Nothing
  else pure ()
  pure (Right (not finished))

forceState :: GameState -> ()
forceState state = phase (gamePhase state) `seq` player (gamePlayer1 state) `seq` player (gamePlayer2 state)
  where
    phase Placing = ()
    phase (Turn actor) = actor `seq` ()
    phase (Finished actor reason) = actor `seq` reason `seq` ()
    player value = fleet (playerFleet value) `seq`
      Map.foldrWithKey (\cell outcome rest -> coord cell `seq` result outcome `seq` rest) () (playerShots value)
    fleet Nothing = ()
    fleet (Just value) = Map.foldrWithKey (\ship cells rest -> ship `seq`
      Set.foldr (\cell remaining -> coord cell `seq` remaining) () cells `seq` rest) () (fleetShips value)
    coord (Coord column row) = column `seq` row `seq` ()
    result (Sunk ship) = ship `seq` ()
    result outcome = outcome `seq` ()

terminal :: GameState -> Bool
terminal state = case gamePhase state of
  Finished _ _ -> True
  _ -> False

-- | Payload has already had LF/CRLF removed by Protocol.feedFrames.
-- Parser/rule errors preserve state and go only to the socket's actor.
coordinate :: Step -> PlayerId -> BS.ByteString -> GameState
  -> Either ProtocolError (GameState, [(PlayerId, BS.ByteString)])
coordinate core actor payload state = materialize state <$> preparePayload core actor payload state

preparePayload :: Step -> PlayerId -> BS.ByteString -> GameState
  -> Either ProtocolError (Maybe GameState, [(PlayerId, BS.ByteString)])
preparePayload core actor payload state = case parseCommand payload of
  Right command -> prepareCommand core actor command state
  Left fault -> rejection actor $ case fault of
    LineTooLong -> TooLong
    InvalidCoordinateToken -> BadCoordinate
    InvalidMessage -> BadCommand
    UnsupportedVersion -> BadCommand

-- | Also used for EOF/socket failure -> Quit. Encode the whole event batch
-- before exposing the new state: an unencodable core event is an internal
-- failure, never a partly committed transition or a fake client error.
applyCommand :: Step -> PlayerId -> Command -> GameState
  -> Either ProtocolError (GameState, [(PlayerId, BS.ByteString)])
applyCommand core actor command state = materialize state <$> prepareCommand core actor command state

prepareCommand :: Step -> PlayerId -> Command -> GameState
  -> Either ProtocolError (Maybe GameState, [(PlayerId, BS.ByteString)])
prepareCommand core actor command state = case core actor command state of
  Left fault -> rejection actor (wireError fault)
  Right (next, events) -> do
    frames <- concat <$> traverse (encodeEvent (gamePhase next)) events
    pure (Just next, frames)

rejection :: PlayerId -> WireError
  -> Either ProtocolError (Maybe GameState, [(PlayerId, BS.ByteString)])
rejection actor fault = do
  frame <- encodeResponse (Rejected fault)
  pure (Nothing, [(actor, frame)])

materialize :: GameState -> (Maybe GameState, [(PlayerId, BS.ByteString)])
  -> (GameState, [(PlayerId, BS.ByteString)])
materialize previous (accepted, frames) = (fromMaybe previous accepted, frames)
