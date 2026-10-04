-- | Pure wire boundary and STM ownership of the one authoritative game.
-- No socket IO or duplicate gameplay rules belong here.
module Battleship.Coordinator
  ( coordinate, applyCommand
  , Coordinator, newCoordinator, readGameState, nextFrame
  , submitPayload, submitCommand, submitTooLong, welcomePlayer
  ) where

import Battleship.Protocol
import Battleship.Types
import Control.Concurrent.STM
import Control.Monad (forM_, void)
import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe)

-- End markers share the FIFO with frames, so writers drain GAME_OVER first.
-- ponytail: unbounded queues suit the two-client MVP; use bounded queues with
-- a slow-client disconnect policy if sustained command floods become relevant.
data Coordinator = Coordinator
  { gameState :: TVar GameState
  , player1Frames :: TQueue (Maybe BS.ByteString)
  , player2Frames :: TQueue (Maybe BS.ByteString)
  }

newCoordinator :: GameState -> STM Coordinator
newCoordinator initial = Coordinator <$> newTVar initial <*> newTQueue <*> newTQueue

readGameState :: Coordinator -> STM GameState
readGameState = readTVar . gameState

outbox :: Coordinator -> PlayerId -> TQueue (Maybe BS.ByteString)
outbox coordinator P1 = player1Frames coordinator
outbox coordinator P2 = player2Frames coordinator

nextFrame :: Coordinator -> PlayerId -> STM (Maybe BS.ByteString)
nextFrame coordinator = readTQueue . outbox coordinator

-- Called only at admission. Drop frames for an absent socket and put WELCOME
-- first, atomically with the phase check. No later event can precede it.
welcomePlayer :: Coordinator -> PlayerId -> STM (Either ProtocolError Bool)
welcomePlayer coordinator actor = do
  state <- readGameState coordinator
  if terminal state then pure (Right False)
  else case encodeResponse (Welcome actor) of
    Left fault -> pure (Left fault)
    Right frame -> do
      void (flushTQueue (outbox coordinator actor))
      writeTQueue (outbox coordinator actor) (Just frame)
      pure (Right True)

submitPayload :: Step -> Coordinator -> PlayerId -> BS.ByteString -> STM (Either ProtocolError Bool)
submitPayload core coordinator actor payload = transact coordinator (preparePayload core actor payload)

submitCommand :: Step -> Coordinator -> PlayerId -> Command -> STM (Either ProtocolError Bool)
submitCommand core coordinator actor command = transact coordinator (prepareCommand core actor command)

submitTooLong :: Coordinator -> PlayerId -> STM (Either ProtocolError Bool)
submitTooLong coordinator actor = transact coordinator (const (rejection actor TooLong))

-- Read, validate/step, commit and enqueue every filtered frame in one STM
-- action. The caller runs atomically. Encoding failure changes neither state
-- nor queues; rule/parser rejection enqueues an actor-only error without a
-- writeTVar. Finished is also the sole gameplay termination flag.
transact :: Coordinator
  -> (GameState -> Either ProtocolError (Maybe GameState, [(PlayerId, BS.ByteString)]))
  -> STM (Either ProtocolError Bool)
transact coordinator prepare = do
  previous <- readGameState coordinator
  if terminal previous then pure (Right False)
  else case prepare previous of
    Left fault -> pure (Left fault)
    Right (accepted, frames) -> do
      forM_ accepted (writeTVar (gameState coordinator))
      forM_ frames $ \(recipient, frame) -> writeTQueue (outbox coordinator recipient) (Just frame)
      let finished = maybe False terminal accepted
      if finished then forM_ [P1, P2] $ \recipient -> writeTQueue (outbox coordinator recipient) Nothing
      else pure ()
      pure (Right (not finished))

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
