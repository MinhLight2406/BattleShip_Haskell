-- | Pure boundary between wire v1 and the shared Rules contract. No game
-- rules live here. Supply a Step stub in tests, or Rules.step in production.
module Battleship.Coordinator (coordinate, applyCommand) where

import Battleship.Protocol
import Battleship.Types
import qualified Data.ByteString as BS

-- | Payload has already had LF/CRLF removed by Protocol.feedFrames.
-- Parser/rule errors preserve state and go only to the socket's actor.
coordinate :: Step -> PlayerId -> BS.ByteString -> GameState
  -> Either ProtocolError (GameState, [(PlayerId, BS.ByteString)])
coordinate core actor payload state = case parseCommand payload of
  Right command -> applyCommand core actor command state
  Left fault -> reject actor state $ case fault of
    LineTooLong -> TooLong
    InvalidCoordinateToken -> BadCoordinate
    InvalidMessage -> BadCommand
    UnsupportedVersion -> BadCommand

-- | Also used for EOF/socket failure -> Quit. Encode the whole event batch
-- before exposing the new state: an unencodable core event is an internal
-- failure, never a partly committed transition or a fake client error.
applyCommand :: Step -> PlayerId -> Command -> GameState
  -> Either ProtocolError (GameState, [(PlayerId, BS.ByteString)])
applyCommand core actor command state = case core actor command state of
  Left fault -> reject actor state (wireError fault)
  Right (next, events) -> do
    frames <- concat <$> traverse (encodeEvent (gamePhase next)) events
    pure (next, frames)

reject :: PlayerId -> GameState -> WireError
  -> Either ProtocolError (GameState, [(PlayerId, BS.ByteString)])
reject actor state fault = do
  frame <- encodeResponse (Rejected fault)
  pure (state, [(actor, frame)])
