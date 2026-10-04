-- | D-01 wire v1. Parsers take payloads WITHOUT LF/CRLF; encoders return
-- complete LF frames. Socket readers use feedFrames before either parser.
module Battleship.Protocol
  ( ProtocolError (..), WireError (..), Response (..)
  , protocolVersion, maxLineBytes, parseCoord, encodeCoord
  , parseCommand, encodeCommand, parseResponse, encodeResponse
  , wireError, routeEvent, encodeEvent, feedFrames
  ) where

import Battleship.Types
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (chr, ord)
import Data.List (sortOn)

data ProtocolError = LineTooLong | InvalidMessage | InvalidCoordinateToken | UnsupportedVersion
  deriving (Eq, Show)

-- Wire errors carry only fields present in the grammar. In particular, a bad
-- coordinate/out-of-bounds error cannot recover the original Coord from wire.
data WireError
  = BadCommand | BadCoordinate | FleetSize Int | Missing ShipId | Duplicate ShipId
  | OutOfBounds ShipId | Overlap Coord | AlreadyPlaced | NotReady
  | WrongTurn PlayerId | RepeatedShot Coord | GameFinished | TooLong | ServerFull
  deriving (Eq, Show)

data Response
  = Welcome PlayerId | PlaceOK | WaitingOpponent | Start PlayerId | TurnOf PlayerId
  | Shot Coord Outcome | Incoming Coord Outcome | GameOver PlayerId EndReason
  | Rejected WireError
  deriving (Eq, Show)

protocolVersion :: Int
protocolVersion = 1

maxLineBytes :: Int
maxLineBytes = 256

parseCoord :: BS.ByteString -> Either ProtocolError Coord
parseCoord token = case BSC.unpack token of
  column : row | column >= 'A' && column <= 'J' -> do
    number <- require InvalidCoordinateToken (lookup row [(show n, n) | n <- [1 .. 10]])
    pure (Coord (ord column - ord 'A' + 1) number)
  _ -> Left InvalidCoordinateToken

encodeCoord :: Coord -> Either ProtocolError BS.ByteString
encodeCoord (Coord column row)
  | column >= 1 && column <= boardSize && row >= 1 && row <= boardSize =
      Right (BSC.pack ([chr (ord 'A' + column - 1)] ++ show row))
  | otherwise = Left InvalidCoordinateToken

parseCommand :: BS.ByteString -> Either ProtocolError Command
parseCommand payload = do
  validatePayload payload
  case BSC.split ' ' payload of
    [name] | name == b "QUIT" -> Right Quit
    [name, coordinate] | name == b "FIRE" && not (BS.null coordinate) ->
      Fire <$> parseCoord coordinate
    [name, entries] | name == b "PLACE" && not (BS.null entries) ->
      PlaceFleet <$> traverse parsePlacement (BSC.split ';' entries)
    _ -> Left InvalidMessage
  where
    parsePlacement entry = case BSC.split '=' entry of
      [code, position] -> case BSC.split ':' position of
        [coordinate, direction] -> do
          ship <- parseShip code
          start <- parseCoord coordinate
          orientation <- require InvalidMessage (lookup direction [(b "H", Horizontal), (b "V", Vertical)])
          pure (ShipPlacement ship start orientation)
        _ -> Left InvalidMessage
      _ -> Left InvalidMessage

-- Canonical ship order; duplicates and incomplete fleets are preserved for
-- Board/Rules to validate. Empty PLACE is not representable in wire v1.
encodeCommand :: Command -> Either ProtocolError BS.ByteString
encodeCommand command = case command of
  Quit -> frame (b "QUIT")
  Fire coordinate -> encodeCoord coordinate >>= frame . (b "FIRE " <>)
  PlaceFleet [] -> Left InvalidMessage
  PlaceFleet placements -> do
    entries <- traverse encodePlacement (sortOn placementShip placements)
    frame (b "PLACE " <> BSC.intercalate (b ";") entries)
  where
    encodePlacement (ShipPlacement ship start orientation) = do
      coordinate <- encodeCoord start
      pure (shipToken ship <> b "=" <> coordinate <> b ":" <>
        b (case orientation of Horizontal -> "H"; Vertical -> "V"))

parseResponse :: BS.ByteString -> Either ProtocolError Response
parseResponse payload = do
  validatePayload payload
  case map BSC.unpack (BSC.split ' ' payload) of
    ["WELCOME", version, player] -> do
      identity <- parsePlayer player
      if version == show protocolVersion then Right (Welcome identity) else Left UnsupportedVersion
    ["OK", "PLACE"] -> Right PlaceOK
    ["WAITING", "OPPONENT"] -> Right WaitingOpponent
    ["START", "P1"] -> Right (Start P1)
    ["TURN", player] -> TurnOf <$> parsePlayer player
    kind : coordinate : outcome | kind `elem` ["SHOT", "INCOMING"] -> do
      position <- responseCoord coordinate
      result <- parseOutcome outcome
      pure ((if kind == "SHOT" then Shot else Incoming) position result)
    ["GAME_OVER", player, reason] -> GameOver <$> parsePlayer player <*> parseReason reason
    "ERROR" : tokens -> Rejected <$> parseError tokens
    _ -> Left InvalidMessage
  where
    parseOutcome ["MISS"] = Right Miss
    parseOutcome ["HIT"] = Right Hit
    parseOutcome ["WIN"] = Right Win
    parseOutcome ["SUNK", ship] = Sunk <$> parseShip (b ship)
    parseOutcome _ = Left InvalidMessage
    parseReason "ALL_SHIPS_SUNK" = Right AllShipsSunk
    parseReason "OPPONENT_LEFT" = Right OpponentLeft
    parseReason _ = Left InvalidMessage
    parseError [code] = require InvalidMessage (lookup code
      [("INVALID_COMMAND", BadCommand), ("INVALID_COORDINATE", BadCoordinate),
       ("FLEET_ALREADY_PLACED", AlreadyPlaced), ("FLEETS_NOT_READY", NotReady),
       ("GAME_FINISHED", GameFinished), ("LINE_TOO_LONG", TooLong), ("SERVER_FULL", ServerFull)])
    parseError ["INVALID_FLEET_SIZE", count] = FleetSize <$> require InvalidMessage
      (lookup count [(show n, n) | n <- [0 .. maxLineBytes]])
    parseError ["MISSING_SHIP", ship] = Missing <$> parseShip (b ship)
    parseError ["DUPLICATE_SHIP", ship] = Duplicate <$> parseShip (b ship)
    parseError ["SHIP_OUT_OF_BOUNDS", ship] = OutOfBounds <$> parseShip (b ship)
    parseError ["SHIPS_OVERLAP", coordinate] = Overlap <$> responseCoord coordinate
    parseError ["ALREADY_FIRED", coordinate] = RepeatedShot <$> responseCoord coordinate
    parseError ["NOT_YOUR_TURN", player] = WrongTurn <$> parsePlayer player
    parseError _ = Left InvalidMessage

encodeResponse :: Response -> Either ProtocolError BS.ByteString
encodeResponse response = render response >>= frame
  where
    render (Welcome player) = Right (b ("WELCOME 1 " ++ playerToken player))
    render PlaceOK = Right (b "OK PLACE")
    render WaitingOpponent = Right (b "WAITING OPPONENT")
    render (Start P1) = Right (b "START P1")
    render (Start P2) = Left InvalidMessage
    render (TurnOf player) = Right (b ("TURN " ++ playerToken player))
    render (Shot coordinate outcome) = renderShot "SHOT " coordinate outcome
    render (Incoming coordinate outcome) = renderShot "INCOMING " coordinate outcome
    render (GameOver player reason) = Right (b ("GAME_OVER " ++ playerToken player ++ " " ++
      case reason of AllShipsSunk -> "ALL_SHIPS_SUNK"; OpponentLeft -> "OPPONENT_LEFT"))
    render (Rejected err) = (b "ERROR " <>) <$> renderError err
    renderShot prefix coordinate outcome = do
      position <- encodeCoord coordinate
      let result = case outcome of
            Miss -> b "MISS"
            Hit -> b "HIT"
            Sunk ship -> b "SUNK " <> shipToken ship
            Win -> b "WIN"
      pure (b prefix <> position <> b " " <> result)
    renderError err = case err of
      BadCommand -> literal "INVALID_COMMAND"
      BadCoordinate -> literal "INVALID_COORDINATE"
      FleetSize count | count >= 0 && count <= maxLineBytes -> literal ("INVALID_FLEET_SIZE " ++ show count)
                      | otherwise -> Left InvalidMessage
      Missing ship -> Right (b "MISSING_SHIP " <> shipToken ship)
      Duplicate ship -> Right (b "DUPLICATE_SHIP " <> shipToken ship)
      OutOfBounds ship -> Right (b "SHIP_OUT_OF_BOUNDS " <> shipToken ship)
      Overlap coordinate -> (b "SHIPS_OVERLAP " <>) <$> encodeCoord coordinate
      AlreadyPlaced -> literal "FLEET_ALREADY_PLACED"
      NotReady -> literal "FLEETS_NOT_READY"
      WrongTurn player -> literal ("NOT_YOUR_TURN " ++ playerToken player)
      RepeatedShot coordinate -> (b "ALREADY_FIRED " <>) <$> encodeCoord coordinate
      GameFinished -> literal "GAME_FINISHED"
      TooLong -> literal "LINE_TOO_LONG"
      ServerFull -> literal "SERVER_FULL"
    literal = Right . b

wireError :: GameError -> WireError
wireError err = case err of
  InvalidCommand _ -> BadCommand
  InvalidCoordinate _ -> BadCoordinate
  InvalidFleetSize count -> FleetSize count
  MissingShip ship -> Missing ship
  DuplicateShip ship -> Duplicate ship
  ShipOutOfBounds ship _ -> OutOfBounds ship
  ShipsOverlap coordinate -> Overlap coordinate
  FleetAlreadyPlaced -> AlreadyPlaced
  FleetsNotReady -> NotReady
  NotYourTurn player -> WrongTurn player
  AlreadyFired coordinate -> RepeatedShot coordinate
  GameAlreadyFinished -> GameFinished

-- Logical recipients; Coordinator enqueues each frame in its recipient's
-- private outbox, consumed only by that socket's writer. No fleet or state is
-- serialized. Phase is needed only for WAITING after FleetAccepted.
routeEvent :: Phase -> Event -> [(PlayerId, Response)]
routeEvent phase event = case event of
  FleetAccepted player -> (player, PlaceOK) : [(player, WaitingOpponent) | phase == Placing]
  GameStarted player -> broadcast (Start player)
  ShotResolved player coordinate outcome ->
    [(player, Shot coordinate outcome), (otherPlayer player, Incoming coordinate outcome)]
  TurnReady player -> broadcast (TurnOf player)
  GameEnded winner reason -> broadcast (GameOver winner reason)
  where broadcast response = [(P1, response), (P2, response)]

encodeEvent :: Phase -> Event -> Either ProtocolError [(PlayerId, BS.ByteString)]
encodeEvent phase = traverse encodeRecipient . routeEvent phase
  where encodeRecipient (player, response) = do
          bytes <- encodeResponse response
          pure (player, bytes)

-- Complete frames survive an overlong later frame in the same chunk. The
-- pending buffer never exceeds 257 bytes; only a final CR permits byte 257.
-- Payload validation happens later so one malformed frame cannot eat the next.
feedFrames :: BS.ByteString -> BS.ByteString -> ([BS.ByteString], Either ProtocolError BS.ByteString)
feedFrames pending chunk
  | BS.length pending > maxLineBytes && not (BS.length pending == maxLineBytes + 1 && BS.last pending == 13) =
      ([], Left LineTooLong)
  | BS.elem 10 pending = ([], Left InvalidMessage)
  | otherwise = consume [] pending chunk
  where
    consume complete buffer bytes = case BS.uncons bytes of
      Nothing -> (reverse complete, Right buffer)
      Just (byte, rest)
        | byte == 10 ->
            let payload = if not (BS.null buffer) && BS.last buffer == 13 then BS.init buffer else buffer
            in if BS.length payload > maxLineBytes then (reverse complete, Left LineTooLong)
               else consume (payload : complete) BS.empty rest
        | BS.length buffer < maxLineBytes || (BS.length buffer == maxLineBytes && byte == 13) ->
            consume complete (BS.snoc buffer byte) rest
        | otherwise -> (reverse complete, Left LineTooLong)

validatePayload :: BS.ByteString -> Either ProtocolError ()
validatePayload payload
  | BS.length payload > maxLineBytes = Left LineTooLong
  | BS.all (\byte -> byte >= 32 && byte <= 126) payload = Right ()
  | otherwise = Left InvalidMessage

frame :: BS.ByteString -> Either ProtocolError BS.ByteString
frame payload = validatePayload payload >> pure (payload <> b "\n")

require :: ProtocolError -> Maybe a -> Either ProtocolError a
require fault = maybe (Left fault) Right

responseCoord :: String -> Either ProtocolError Coord
responseCoord token = case parseCoord (b token) of
  Right coordinate -> Right coordinate
  Left _ -> Left InvalidMessage

parsePlayer :: String -> Either ProtocolError PlayerId
parsePlayer token = require InvalidMessage (lookup token [("P1", P1), ("P2", P2)])

parseShip :: BS.ByteString -> Either ProtocolError ShipId
parseShip token = require InvalidMessage (lookup token [(shipToken ship, ship) | ship <- [minBound .. maxBound]])

shipToken :: ShipId -> BS.ByteString
shipToken Carrier = b "CV"
shipToken Battleship = b "BB"
shipToken Cruiser = b "CR"
shipToken Submarine = b "SB"
shipToken Destroyer = b "DD"

playerToken :: PlayerId -> String
playerToken P1 = "P1"
playerToken P2 = "P2"

b :: String -> BS.ByteString
b = BSC.pack
