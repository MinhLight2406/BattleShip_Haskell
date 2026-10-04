-- | Shared domain types and function contracts for A/B/C/D.
-- Business validation belongs to Board/Rules; socket identity belongs to Server.
module Battleship.Types
  ( PlayerId (..)
  , Coord (..)
  , ShipId (..)
  , Orientation (..)
  , ShipPlacement (..)
  , FleetPlacement
  , Fleet
  , fleetShips
  , Outcome (..)
  , PlayerState (..)
  , EndReason (..)
  , Phase (..)
  , GameState (..)
  , Command (..)
  , Event (..)
  , GameError (..)
  , PlayerView (..)
  , Step
  , PlaceFleetFn
  , ViewFor
  , boardSize
  , shipLength
  , otherPlayer
  , initialGameState
  , playerStateFor
  , setPlayerState
  ) where

import Data.Map.Strict (Map)
import qualified Battleship.Internal.Fleet as Internal
import qualified Data.Map.Strict as Map
import Data.Set (Set)

-- | Assigned by the server, never accepted from a client command.
data PlayerId = P1 | P2
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One-based column and row: A1 = Coord 1 1, J10 = Coord 10 10.
-- Raw values may be outside the board; Board/Rules must reject them.
data Coord = Coord
  { coordColumn :: Int
  , coordRow :: Int
  } deriving (Eq, Ord, Show)

-- | Protocol codes: CV, BB, CR, SB, DD respectively.
data ShipId = Carrier | Battleship | Cruiser | Submarine | Destroyer
  deriving (Eq, Ord, Show, Enum, Bounded)

data Orientation = Horizontal | Vertical
  deriving (Eq, Show)

-- | A request specifies the start and direction, never an arbitrary length.
-- Horizontal increases the column; Vertical increases the row.
data ShipPlacement = ShipPlacement
  { placementShip :: ShipId
  , placementStart :: Coord
  , placementOrientation :: Orientation
  } deriving (Eq, Show)

-- | Keep the request as a list so validation can detect duplicate/missing ships.
type FleetPlacement = [ShipPlacement]

-- | Normalized ship cells, produced by Board.placeFleet after validation.
-- Invariant: exactly five IDs, lengths 5/4/3/3/2, straight contiguous cells,
-- all in bounds and no overlap. Touching ships are permitted.
-- The constructor and record update are private. Use Board.placeFleet.
type Fleet = Internal.Fleet ShipId Coord

-- | The recorded outcome when a shot was made, not a mutable cell status.
data Outcome = Miss | Hit | Sunk ShipId | Win
  deriving (Eq, Show)

data PlayerState = PlayerState
  { playerFleet :: Maybe Fleet
    -- ^ Nothing means not placed, never "an empty but ready fleet".
  , playerShots :: Map Coord Outcome
    -- ^ Shots fired at the opponent. Incoming shots are the opponent's history.
  } deriving (Eq, Show)

data EndReason = AllShipsSunk | OpponentLeft
  deriving (Eq, Show)

-- | A finished game has a winner/reason and no current turn.
data Phase = Placing | Turn PlayerId | Finished PlayerId EndReason
  deriving (Eq, Show)

-- | Exactly two separate player states; no indexed list or optional player slot.
-- Invariant: Turn requires both fleets; Finished AllShipsSunk also requires both.
-- Finished OpponentLeft is valid even during placement.
data GameState = GameState
  { gamePlayer1 :: PlayerState
  , gamePlayer2 :: PlayerState
  , gamePhase :: Phase
  } deriving (Eq, Show)

-- | The actor is supplied separately to step from the server-assigned socket.
-- Coordinator maps an unexpected disconnect to Quit for that socket's player.
data Command = PlaceFleet FleetPlacement | Fire Coord | Quit
  deriving (Eq, Show)

-- | Internal successful events. They contain no fleet or unshot ship position.
-- Coordinator routes them to recipient-specific wire messages; see protocol.md.
data Event
  = FleetAccepted PlayerId
  | GameStarted PlayerId
  | ShotResolved PlayerId Coord Outcome
  | TurnReady PlayerId
  | GameEnded PlayerId EndReason
  deriving (Eq, Show)

data GameError
  = InvalidCommand String
  | InvalidCoordinate Coord
  | InvalidFleetSize Int
  | MissingShip ShipId
  | DuplicateShip ShipId
  | ShipOutOfBounds ShipId Coord
  | ShipsOverlap Coord
  | FleetAlreadyPlaced
  | FleetsNotReady
  | NotYourTurn PlayerId
    -- ^ Carries the player whose turn it currently is.
  | AlreadyFired Coord
  | GameAlreadyFinished
  deriving (Eq, Show)

-- | Public projection for a single player, not a serializable GameState.
-- ownFleetView MUST come from the requested player. No opponent fleet field.
data PlayerView = PlayerView
  { viewPlayer :: PlayerId
  , viewPhase :: Phase
  , ownFleetView :: Maybe Fleet
  , outgoingShotsView :: Map Coord Outcome
  , incomingShotsView :: Map Coord Outcome
  , opponentReady :: Bool
  } deriving (Eq, Show)

-- | Contract for Battleship.Rules.step (implementation belongs to B):
--
-- @step :: PlayerId -> Command -> GameState
--       -> Either GameError (GameState, [Event])@
--
-- Left returns no state/events: coordinator keeps the old state and reports
-- the error only to the actor. Miss switches turn; Hit/Sunk retain it;
-- Win emits GameEnded and no TurnReady. Both fleets start with Turn P1.
type Step = PlayerId -> Command -> GameState
  -> Either GameError (GameState, [Event])

-- | Contract for Battleship.Board.placeFleet (implementation belongs to A-02):
--
-- @placeFleet :: FleetPlacement -> Either GameError Fleet@
--
-- Validates the complete request atomically, without updating a PlayerState.
-- Rules checks phase/already-placed, then installs Right fleet into the actor.
type PlaceFleetFn = FleetPlacement -> Either GameError Fleet

-- | Contract for Battleship.View.viewFor (implementation belongs to B):
--
-- @viewFor :: PlayerId -> GameState -> PlayerView@
--
-- Includes the requested player's fleet, their shot history, the opponent's
-- fired shots and readiness. It never includes unshot opponent ship cells.
type ViewFor = PlayerId -> GameState -> PlayerView

boardSize :: Int
boardSize = 10

shipLength :: ShipId -> Int
shipLength Carrier = 5
shipLength Battleship = 4
shipLength Cruiser = 3
shipLength Submarine = 3
shipLength Destroyer = 2

otherPlayer :: PlayerId -> PlayerId
otherPlayer P1 = P2
otherPlayer P2 = P1

-- | Both players begin with no placed fleet, no shots and no active turn.
initialGameState :: GameState
initialGameState = GameState emptyPlayer emptyPlayer Placing
  where
    emptyPlayer = PlayerState Nothing Map.empty

playerStateFor :: PlayerId -> GameState -> PlayerState
playerStateFor P1 = gamePlayer1
playerStateFor P2 = gamePlayer2

-- | Pure record update; preserves the other player and the game's phase.
setPlayerState :: PlayerId -> PlayerState -> GameState -> GameState
setPlayerState P1 player state = state { gamePlayer1 = player }
setPlayerState P2 player state = state { gamePlayer2 = player }

-- | Read-only ship cells. Changing the returned immutable Map does not change
-- the Fleet; callers cannot use this function as a record-update field.
fleetShips :: Fleet -> Map ShipId (Set Coord)
fleetShips = Internal.fleetShips
