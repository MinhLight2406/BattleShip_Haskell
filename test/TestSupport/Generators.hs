-- | Independent R-01 input generation for Board/View property tests.
module TestSupport.Generators
  ( genValidFleet
  , genFleetKeepingCarrier
  , referenceCells
  , legalBoardCells
  , mixedDirections
  , validGeneratedFleet
  , shipSizes
  ) where

import Battleship.Types
import Data.List (sort)
import qualified Data.Set as Set
import qualified Test.QuickCheck as QC

-- Independently specified R-01 lengths, not derived from the implementation.
shipSizes :: [(ShipId, Int)]
shipSizes = [(Carrier, 5), (Battleship, 4), (Cruiser, 3), (Submarine, 3), (Destroyer, 2)]

genValidFleet :: QC.Gen FleetPlacement
genValidFleet = genFleet [] []

-- Keep observations of Carrier identical; put Destroyer outside the original
-- occupied cells so that hidden coordinates genuinely change.
genFleetKeepingCarrier :: FleetPlacement -> QC.Gen FleetPlacement
genFleetKeepingCarrier original = genFleet
  [placement | placement <- original, placementShip placement == Carrier]
  (concatMap referenceCells original)

-- Enumerate finite candidates using the test's R-01 lengths and grid, never
-- Board.shipCells/placeFleet/inBounds. Longest-first packing always has room:
-- disjoint length-L segments outnumber already occupied cells (20/30/30/50
-- segments versus 5/9/12/15 cells for the remaining ships). When keeping a
-- Carrier, Destroyer avoids at most 15 + 17 cells, still fewer than 50 segments.
genFleet :: FleetPlacement -> [Coord] -> QC.Gen FleetPlacement
genFleet fixed oldCells = do
  carrierDirection <- case fixed of
    [carrier] -> pure (placementOrientation carrier)
    _ -> QC.elements [Horizontal, Vertical]
  placements <- pack carrierDirection (concatMap referenceCells fixed)
    [(ship, size) | (ship, size) <- shipSizes, ship `notElem` map placementShip fixed]
  QC.shuffle (fixed ++ placements)
  where
    pack _ _ [] = pure []
    pack carrierDirection occupied ((ship, _) : remaining) = do
      direction <- case ship of
        Carrier -> pure carrierDirection
        Destroyer -> pure (case carrierDirection of
          Horizontal -> Vertical
          Vertical -> Horizontal)
        _ -> QC.elements [Horizontal, Vertical]
      let candidates =
            [ placement
            | start <- legalBoardCells
            , let placement = ShipPlacement ship start direction
                  cells = referenceCells placement
            , ship /= Destroyer || all (`notElem` oldCells) cells
            , all (`elem` legalBoardCells) cells
            , all (`notElem` occupied) cells ]
      placement <- QC.elements candidates
      rest <- pack carrierDirection (referenceCells placement ++ occupied) remaining
      pure (placement : rest)

-- Walk from the start rather than calling production geometry or shipLength.
referenceCells :: ShipPlacement -> [Coord]
referenceCells placement = take size (iterate advance (placementStart placement))
  where
    size = case lookup (placementShip placement) shipSizes of
      Just value -> value
      Nothing -> error "Test's R-01 ship size table is incomplete"
    advance (Coord column row) = case placementOrientation placement of
      Horizontal -> Coord (succ column) row
      Vertical -> Coord column (succ row)

legalBoardCells :: [Coord]
legalBoardCells = [Coord column row | column <- [1 .. 10], row <- [1 .. 10]]

mixedDirections :: FleetPlacement -> Bool
mixedDirections placements = all (`elem` map placementOrientation placements) [Horizontal, Vertical]

validGeneratedFleet :: FleetPlacement -> Bool
validGeneratedFleet placements =
  sort (map placementShip placements) == map fst shipSizes
    && mixedDirections placements
    && all (`elem` legalBoardCells) cells
    && length cells == 17
    && Set.size (Set.fromList cells) == 17
  where cells = concatMap referenceCells placements
