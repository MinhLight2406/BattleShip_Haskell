-- | Pure board geometry and checked fleet construction (A-02).
module Battleship.Board (inBounds, shipCells, placeFleet) where

import Battleship.Types
import qualified Battleship.Internal.Fleet as Internal
import Control.Monad (foldM)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set

-- | One-based board coordinates; safe even for extreme raw Int values.
inBounds :: Coord -> Bool
inBounds (Coord column row) =
  column >= 1 && column <= boardSize && row >= 1 && row <= boardSize

-- | Expand the fixed length of the ship ID, increasing columns (H) or rows (V).
-- Invalid starts are rejected before arithmetic; extending beyond the board
-- reports the first out-of-bounds cell along the ship.
shipCells :: ShipPlacement -> Either GameError (Set Coord)
shipCells (ShipPlacement ship start@(Coord column row) orientation)
  | not (inBounds start) = Left (InvalidCoordinate start)
  | otherwise = case find (not . inBounds) cells of
      Just coordinate -> Left (ShipOutOfBounds ship coordinate)
      Nothing -> Right (Set.fromList cells)
  where
    cells = [case orientation of
               Horizontal -> Coord (column + offset) row
               Vertical -> Coord column (row + offset)
            | offset <- [0 .. shipLength ship - 1]]

-- | The public smart constructor. No partial Fleet is returned on failure.
-- Five unique IDs exhaust ShipId, so a separate missing-ID branch is unnecessary.
-- Error order: count, then left-to-right duplicate/start/extent/overlap checks.
-- For multiple shared cells, report the least Coord under its Ord instance.
placeFleet :: PlaceFleetFn
placeFleet placements
  | count /= length ([minBound .. maxBound] :: [ShipId]) = Left (InvalidFleetSize count)
  | otherwise = Internal.Fleet <$> foldM insertShip Map.empty placements
  where
    count = length placements
    insertShip ships placement
      | Map.member ship ships = Left (DuplicateShip ship)
      | otherwise = do
          cells <- shipCells placement
          let occupied = Set.unions (Map.elems ships)
          case Set.lookupMin (Set.intersection cells occupied) of
            Just coordinate -> Left (ShipsOverlap coordinate)
            Nothing -> Right (Map.insert ship cells ships)
      where ship = placementShip placement
