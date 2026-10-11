module FleetIndexSpec (spec) where

import qualified Battleship.Board as Board
import Battleship.Types
import qualified Battleship.Rules as Rules
import Control.Monad (forM_)
import Data.List (find, sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import qualified Test.QuickCheck as QC
import TestSupport.Generators (genValidFleet, referenceCells, legalBoardCells)

spec :: Spec
spec = describe "NM-06 Fleet index" $ do
  it "maps A1 and J10, keeps the two length-three IDs distinct and leaves water empty" $ do
    let fleet = checked corners
    Board.shipAt (Coord 1 1) fleet `shouldBe` Right (Just Carrier)
    Board.shipAt (Coord 10 10) fleet `shouldBe` Right (Just Submarine)
    Board.shipAt (Coord 3 10) fleet `shouldBe` Right (Just Cruiser)
    Board.shipAt (Coord 10 8) fleet `shouldBe` Right (Just Submarine)
    Board.shipAt (Coord 5 5) fleet `shouldBe` Right Nothing
    Set.size (Board.fleetCells fleet) `shouldBe` 17

  it "checks all 100 cells in a fixed corner fleet against independent input geometry" $
    forM_ legalBoardCells $ \cell ->
      Board.shipAt cell (checked corners) `shouldBe` Right (referenceShip corners cell)

  it "rejects extreme and adjacent outside coordinates before any index arithmetic" $
    forM_ outside $ \cell -> Board.shipAt cell (checked corners) `shouldBe` Left (InvalidCoordinate cell)

  it "normalizes a reversed corner request including all derived metadata" $
    Board.placeFleet (reverse corners) `shouldBe` Board.placeFleet corners

  modifyMaxSuccess (max 1000) $ do
    it "matches the independent coordinate-to-ID model on every one of the 100 cells" $
      QC.forAll genValidFleet $ \placements ->
        let fleet = checked placements
        in QC.conjoin [QC.counterexample ("Coordinate: " ++ show cell) $
             Board.shipAt cell fleet QC.=== Right (referenceShip placements cell) | cell <- legalBoardCells]

    it "caches exactly the independent 17 cells and agrees with exposed geometry" $
      QC.forAll genValidFleet $ \placements ->
        let fleet = checked placements
            wanted = Set.fromList (concatMap referenceCells placements)
        in QC.conjoin [Board.fleetCells fleet QC.=== wanted, Set.size (Board.fleetCells fleet) QC.=== 17,
             Board.fleetCells fleet QC.=== Set.unions (Map.elems (fleetShips fleet)),
             QC.property (all (`elem` legalBoardCells) (Set.toList (Board.fleetCells fleet)))]

    it "keeps lookup and cached cells unchanged under a random placement permutation" $
      QC.forAll genValidFleet $ \placements -> QC.forAll (QC.shuffle placements) $ \permuted ->
        let first = checked placements; second = checked permuted
        in QC.conjoin [first QC.=== second, Board.fleetCells first QC.=== Board.fleetCells second,
             map (`Board.shipAt` first) legalBoardCells QC.=== map (`Board.shipAt` second) legalBoardCells]

    it "rejects independently generated outside coordinates on every generated fleet" $
      QC.forAll genValidFleet $ \placements -> QC.forAll (QC.elements outside) $ \cell ->
        Board.shipAt cell (checked placements) QC.=== Left (InvalidCoordinate cell)

    it "preserves the independently predicted MISS/HIT/SUNK/WIN transcript" $
      QC.forAll genValidFleet $ \placements ->
        let fleet = checked placements
            ready = placed P2 placements (placed P1 placements initialGameState)
            water = case find (\cell -> referenceShip placements cell == Nothing) legalBoardCells of
              Just cell -> cell
              Nothing -> error "Independent generator filled all 100 cells"
            misses = [(P1, water, Miss), (P2, water, Miss)]
            ships = sortOn placementShip placements
            shots = concat [ [(P1, cell, if lastShip && lastCell then Win
                      else if lastCell then Sunk (placementShip placement) else Hit)
                    | (cell, lastCell) <- zip (referenceCells placement) (replicate (length (referenceCells placement) - 1) False ++ [True])]
                 | (placement, lastShip) <- zip ships (replicate 4 False ++ [True])]
        in checkTranscript ready (misses ++ shots) QC..&&.
             Set.size (Board.fleetCells fleet) QC.=== 17

checked :: FleetPlacement -> Fleet
checked = either (error . show) id . Board.placeFleet

referenceShip :: FleetPlacement -> Coord -> Maybe ShipId
referenceShip placements cell = case [placementShip placement | placement <- placements, cell `elem` referenceCells placement] of
  [] -> Nothing
  [ship] -> Just ship
  _ -> error "Independent generator overlapped ships"

placed :: PlayerId -> FleetPlacement -> GameState -> GameState
placed player input state = either (error . show) fst (Rules.step player (PlaceFleet input) state)

checkTranscript :: GameState -> [(PlayerId, Coord, Outcome)] -> QC.Property
checkTranscript state [] = gamePhase state QC.=== Finished P1 AllShipsSunk
checkTranscript state ((player, cell, wanted) : rest) =
  QC.counterexample ("Expected " ++ show (player, cell, wanted)) $ case Rules.step player (Fire cell) state of
    Left fault -> QC.counterexample (show fault) False
    Right (next, events) -> QC.conjoin
      [ QC.property (ShotResolved player cell wanted `elem` events)
      , Map.lookup cell (playerShots (playerStateFor player next)) QC.=== Just wanted
      , checkTranscript next rest ]

outside :: [Coord]
outside = [Coord 0 1, Coord 1 0, Coord 11 10, Coord 10 11, Coord (-1) 5,
  Coord 5 (-1), Coord minBound 1, Coord maxBound 1, Coord 1 minBound, Coord 1 maxBound]

corners :: FleetPlacement
corners = [ShipPlacement Carrier (Coord 1 1) Horizontal,
  ShipPlacement Battleship (Coord 10 1) Vertical,
  ShipPlacement Cruiser (Coord 1 10) Horizontal,
  ShipPlacement Submarine (Coord 10 8) Vertical,
  ShipPlacement Destroyer (Coord 1 5) Vertical]
