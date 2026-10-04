module BoardSpec (spec) where

import Battleship.Board (inBounds, placeFleet, shipCells)
import Battleship.Types
import Control.Monad (forM_)
import Data.List (permutations)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "A-02 board and checked fleet" $ do
  describe "inBounds" $ do
    it "accepts every cell in A1..J10" $
      forM_ [Coord column row | column <- [1 .. 10], row <- [1 .. 10]] $ \coordinate ->
        inBounds coordinate `shouldBe` True

    forM_ invalidStarts $ \coordinate ->
      it ("rejects " ++ show coordinate) $ inBounds coordinate `shouldBe` False

  describe "shipCells" $ do
    forM_ shipSizes $ \(ship, size) -> do
      it ("expands " ++ show ship ++ " horizontally with its fixed length") $
        shipCells (ShipPlacement ship (Coord 2 3) Horizontal) `shouldBe`
          Right (Set.fromList [Coord column 3 | column <- [2 .. size + 1]])

      it ("expands " ++ show ship ++ " vertically with its fixed length") $
        shipCells (ShipPlacement ship (Coord 3 2) Vertical) `shouldBe`
          Right (Set.fromList [Coord 3 row | row <- [2 .. size + 1]])

      it (show ship ++ " can end exactly at column J") $
        shipCells (ShipPlacement ship (Coord (11 - size) 10) Horizontal) `shouldBe`
          Right (Set.fromList [Coord column 10 | column <- [11 - size .. 10]])

      it (show ship ++ " can end exactly at row 10") $
        shipCells (ShipPlacement ship (Coord 10 (11 - size)) Vertical) `shouldBe`
          Right (Set.fromList [Coord 10 row | row <- [11 - size .. 10]])

      it (show ship ++ " rejects one column beyond J with the first outside cell") $
        shipCells (ShipPlacement ship (Coord (12 - size) 10) Horizontal) `shouldBe`
          Left (ShipOutOfBounds ship (Coord 11 10))

      it (show ship ++ " rejects one row beyond 10 with the first outside cell") $
        shipCells (ShipPlacement ship (Coord 10 (12 - size)) Vertical) `shouldBe`
          Left (ShipOutOfBounds ship (Coord 10 11))

    forM_ invalidStarts $ \coordinate ->
      it ("rejects raw start before arithmetic: " ++ show coordinate) $
        forM_ [Horizontal, Vertical] $ \direction ->
          shipCells (ShipPlacement Carrier coordinate direction) `shouldBe`
            Left (InvalidCoordinate coordinate)

    it "checks all 1000 ship/start/direction combinations independently of IO" $
      forM_ [(ship, size, Coord column row, direction) |
             (ship, size) <- shipSizes, column <- [1 .. 10], row <- [1 .. 10],
             direction <- [Horizontal, Vertical]] $ \(ship, size, start, direction) -> do
        let available = case direction of
              Horizontal -> 11 - coordColumn start
              Vertical -> 11 - coordRow start
        case shipCells (ShipPlacement ship start direction) of
          Right cells -> do
            (size <= available) `shouldBe` True
            Set.size cells `shouldBe` size
            Set.member start cells `shouldBe` True
            Set.toList cells `shouldSatisfy` all inBounds
          Left (ShipOutOfBounds actualShip coordinate) -> do
            (size > available) `shouldBe` True
            actualShip `shouldBe` ship
            inBounds coordinate `shouldBe` False
          Left gameError -> expectationFailure ("Unexpected geometry error: " ++ show gameError)

  describe "placeFleet" $ do
    it "accepts the P1 transcript fleet with exactly the expected cells" $
      checkFleet horizontalFleet expectedHorizontal

    it "accepts the P2 transcript fleet including DD on row 10" $
      checkFleet (map (moveStart 0 5) horizontalFleet)
        (Map.map (Set.map (\(Coord column row) -> Coord column (row + 5))) expectedHorizontal)

    it "accepts all 120 input permutations as the same normalized Fleet" $
      forM_ (permutations horizontalFleet) $ \placements ->
        fmap fleetShips (placeFleet placements) `shouldBe` Right expectedHorizontal

    it "accepts a vertical fleet and edge-adjacent ships" $
      checkFleet
        [ShipPlacement ship (Coord column 1) Vertical | (column, (ship, _)) <- zip [1 ..] shipSizes]
        (Map.fromList [(ship, Set.fromList [Coord column row | row <- [1 .. size]]) |
                      (column, (ship, size)) <- zip [1 ..] shipSizes])

    it "accepts corner contact without overlap" $
      case placeFleet (replaceShip Destroyer (Coord 4 5) Vertical horizontalFleet) of
        Right fleet -> checkInvariants fleet
        Left gameError -> expectationFailure (show gameError)

    it "accepts all five ships ending at the right edge" $
      checkFleet
        [ShipPlacement ship (Coord (11 - size) row) Horizontal |
         (row, (ship, size)) <- zip [1 ..] shipSizes]
        (Map.fromList [(ship, Set.fromList [Coord column row | column <- [11 - size .. 10]]) |
                      (row, (ship, size)) <- zip [1 ..] shipSizes])

    it "accepts all five ships ending at the bottom edge" $
      checkFleet
        [ShipPlacement ship (Coord column (11 - size)) Vertical |
         (column, (ship, size)) <- zip [1 ..] shipSizes]
        (Map.fromList [(ship, Set.fromList [Coord column row | row <- [11 - size .. 10]]) |
                      (column, (ship, size)) <- zip [1 ..] shipSizes])

    forM_ [0, 1, 2, 3, 4, 6, 7, 8] $ \count ->
      it ("rejects " ++ show count ++ " placements before checking IDs/geometry") $
        placeFleet (take count (cycle horizontalFleet)) `shouldBe` Left (InvalidFleetSize count)

    forM_ (map fst shipSizes) $ \duplicate ->
      it ("rejects duplicate " ++ show duplicate ++ " without Map overwriting it") $ do
        let replaced = if duplicate == Destroyer then Carrier else Destroyer
            placements = [if placementShip placement == replaced
                            then placement { placementShip = duplicate } else placement |
                          placement <- horizontalFleet]
        placeFleet placements `shouldBe` Left (DuplicateShip duplicate)

    it "rejects shared cells between parallel ships and reports the least Coord" $
      placeFleet (replaceShip Battleship (Coord 1 1) Horizontal horizontalFleet)
        `shouldBe` Left (ShipsOverlap (Coord 1 1))

    it "rejects crossing horizontal and vertical ships" $
      placeFleet (replaceShip Cruiser (Coord 3 1) Vertical horizontalFleet)
        `shouldBe` Left (ShipsOverlap (Coord 3 1))

    it "rejects a valid start whose ship extends out of bounds" $
      placeFleet (replaceShip Destroyer (Coord 10 10) Horizontal horizontalFleet)
        `shouldBe` Left (ShipOutOfBounds Destroyer (Coord 11 10))

    it "rejects an invalid raw coordinate in the last placement" $
      placeFleet (replaceShip Destroyer (Coord 1 0) Vertical horizontalFleet)
        `shouldBe` Left (InvalidCoordinate (Coord 1 0))

    it "returns only Left for an invalid fleet, then accepts a corrected request" $ do
      let bad = replaceShip Destroyer (Coord 1 1) Horizontal horizontalFleet
      placeFleet bad `shouldBe` Left (ShipsOverlap (Coord 1 1))
      fmap fleetShips (placeFleet horizontalFleet) `shouldBe` Right expectedHorizontal

    it "uses input order to choose the first failing placement" $ do
      let bad = replaceShip Destroyer (Coord 10 10) Horizontal
              $ replaceShip Carrier (Coord 0 1) Horizontal horizontalFleet
      placeFleet bad `shouldBe` Left (InvalidCoordinate (Coord 0 1))
      placeFleet (reverse bad) `shouldBe` Left (ShipOutOfBounds Destroyer (Coord 11 10))

-- Independently specified R-01 lengths, not derived from the implementation.
shipSizes :: [(ShipId, Int)]
shipSizes = [(Carrier, 5), (Battleship, 4), (Cruiser, 3), (Submarine, 3), (Destroyer, 2)]

horizontalFleet :: FleetPlacement
horizontalFleet =
  [ShipPlacement ship (Coord 1 row) Horizontal | (row, (ship, _)) <- zip [1 ..] shipSizes]

expectedHorizontal :: Map.Map ShipId (Set.Set Coord)
expectedHorizontal = Map.fromList
  [(ship, Set.fromList [Coord column row | column <- [1 .. size]]) |
   (row, (ship, size)) <- zip [1 ..] shipSizes]

checkFleet :: FleetPlacement -> Map.Map ShipId (Set.Set Coord) -> IO ()
checkFleet placements expected = case placeFleet placements of
  Left gameError -> expectationFailure ("Unexpected rejection: " ++ show gameError)
  Right fleet -> do
    fleetShips fleet `shouldBe` expected
    checkInvariants fleet

checkInvariants :: Fleet -> IO ()
checkInvariants fleet = do
  let ships = fleetShips fleet
  Map.keys ships `shouldBe` map fst shipSizes
  Map.map Set.size ships `shouldBe` Map.fromList shipSizes
  Set.size (Set.unions (Map.elems ships)) `shouldBe` 17
  concatMap Set.toList (Map.elems ships) `shouldSatisfy` all inBounds

replaceShip :: ShipId -> Coord -> Orientation -> FleetPlacement -> FleetPlacement
replaceShip ship start direction = map $ \placement ->
  if placementShip placement == ship then ShipPlacement ship start direction else placement

moveStart :: Int -> Int -> ShipPlacement -> ShipPlacement
moveStart columns rows placement = placement
  { placementStart = Coord (coordColumn start + columns) (coordRow start + rows) }
  where start = placementStart placement

invalidStarts :: [Coord]
invalidStarts = [Coord 0 1, Coord 1 0, Coord 11 1, Coord 1 11, Coord (-1) 5, Coord 5 (-1),
                 Coord minBound 1, Coord maxBound 1, Coord 1 minBound, Coord 1 maxBound]
