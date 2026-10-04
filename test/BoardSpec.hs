module BoardSpec (spec) where

import Battleship.Board (inBounds, placeFleet, shipCells)
import Battleship.Rules (step)
import Battleship.Types
import Control.Exception (bracket)
import Control.Monad (foldM, forM_)
import Data.List (isInfixOf, permutations, sort)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import System.Directory (getTemporaryDirectory, removeFile)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (hClose, hPutStr, openTempFile)
import System.Process (readProcessWithExitCode)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = do
  a02Spec
  a03Spec

a02Spec :: Spec
a02Spec = describe "A-02 board and checked fleet" $ do
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

a03Spec :: Spec
a03Spec = describe "A-03 complete MVP placement" $ do
  describe "corners, IDs and contact" $ do
    forM_ [Horizontal, Vertical] $ \direction -> do
      it ("every ship starts at A1 with " ++ show direction) $
        forM_ shipSizes $ \(ship, size) ->
          shipCells (ShipPlacement ship (Coord 1 1) direction) `shouldBe`
            Right (Set.fromList [case direction of
              Horizontal -> Coord offset 1
              Vertical -> Coord 1 offset | offset <- [1 .. size]])
      it ("every ship starting at J10 exceeds the board with " ++ show direction) $
        forM_ shipSizes $ \(ship, _) ->
          shipCells (ShipPlacement ship (Coord 10 10) direction) `shouldBe`
            Left (ShipOutOfBounds ship (case direction of
              Horizontal -> Coord 11 10
              Vertical -> Coord 10 11))

    it "accepts a horizontal fleet containing both A1 and J10" $
      checkFleet cornerFleet (Map.fromList
        [(Carrier, Set.fromList [Coord column 1 | column <- [1 .. 5]]),
         (Battleship, Set.fromList [Coord column 2 | column <- [7 .. 10]]),
         (Cruiser, Set.fromList [Coord column 3 | column <- [8 .. 10]]),
         (Submarine, Set.fromList [Coord column 4 | column <- [8 .. 10]]),
         (Destroyer, Set.fromList [Coord column 10 | column <- [9 .. 10]])])

    it "accepts a vertical fleet containing both A1 and J10" $
      checkFleet verticalCornerFleet (Map.fromList
        [(Carrier, Set.fromList [Coord 1 row | row <- [1 .. 5]]),
         (Battleship, Set.fromList [Coord 2 row | row <- [7 .. 10]]),
         (Cruiser, Set.fromList [Coord 3 row | row <- [8 .. 10]]),
         (Submarine, Set.fromList [Coord 4 row | row <- [8 .. 10]]),
         (Destroyer, Set.fromList [Coord 10 row | row <- [9 .. 10]])])

    it "accepts both distinct length-three ships: Cruiser and Submarine" $
      checkFleet horizontalFleet expectedHorizontal

    forM_ [(Cruiser, Submarine), (Submarine, Cruiser)] $ \(duplicate, missing) ->
      it ("rejects repeated length-three ID " ++ show duplicate ++ " even with five ships and 17 cells") $ do
        let placements = [if placementShip placement == missing
                            then placement { placementShip = duplicate } else placement |
                          placement <- horizontalFleet]
        length placements `shouldBe` 5
        sum (map (shipLength . placementShip) placements) `shouldBe` 17
        placeFleet placements `shouldBe` Left (DuplicateShip duplicate)

    it "accepts end-to-end edge contact at E1/F1 without sharing cells" $
      checkFleet (replaceShip Battleship (Coord 6 1) Horizontal horizontalFleet)
        (Map.insert Battleship (Set.fromList [Coord column 1 | column <- [6 .. 9]]) expectedHorizontal)

    it "accepts parallel edge contact along Carrier and Battleship" $
      checkFleet horizontalFleet expectedHorizontal

    it "checks all 3125 five-ID assignments: only the 120 permutations form a fleet" $
      forM_ (sequence (replicate 5 (map fst shipSizes))) $ \ids -> do
        let placements = zipWith (\ship row -> ShipPlacement ship (Coord 1 row) Horizontal) ids [1 .. 5]
        case placeFleet placements of
          Right fleet -> do
            sort ids `shouldBe` map fst shipSizes
            checkInvariants fleet
          Left (DuplicateShip _) -> sort ids `shouldSatisfy` (/= map fst shipSizes)
          Left fault -> expectationFailure ("Unexpected ID validation error: " ++ show fault)

  describe "confirmation through the public Rules API" $ do
    forM_ [P1, P2] $ \actor -> do
      it (show actor ++ " cannot replace a confirmed fleet while waiting, even with another valid fleet") $
        case step actor (PlaceFleet horizontalFleet) initialGameState of
          Left fault -> expectationFailure (show fault)
          Right (waiting, events) -> do
            events `shouldBe` [FleetAccepted actor]
            retained <- foldM (rejectPlacement actor FleetAlreadyPlaced) waiting replacementRequests
            retained `shouldBe` waiting
            gamePhase retained `shouldBe` Placing
            case step (otherPlayer actor) (PlaceFleet cornerFleet) retained of
              Left fault -> expectationFailure (show fault)
              Right (ready, started) -> do
                playerStateFor actor ready `shouldBe` playerStateFor actor waiting
                gamePhase ready `shouldBe` Turn P1
                started `shouldBe` [FleetAccepted (otherPlayer actor), GameStarted P1, TurnReady P1]

      it (show actor ++ " can correct rejected fleets before confirmation without retaining partial ships") $
        forM_ badPlacementRequests $ \(placements, expectedError) -> do
          rejected <- rejectPlacement actor expectedError initialGameState placements
          rejected `shouldBe` initialGameState
          step actor (PlaceFleet horizontalFleet) rejected `shouldBe`
            fmap (\fleet -> (setPlayerState actor (PlayerState (Just fleet) Map.empty) initialGameState,
                            [FleetAccepted actor])) (placeFleet horizontalFleet)

      forM_ [P1, P2] $ \current ->
        it (show actor ++ " cannot replace fleet in Turn " ++ show current) $
          case (placeFleet horizontalFleet, placeFleet cornerFleet) of
            (Right first, Right second) -> do
              let ready = GameState (PlayerState (Just first) Map.empty)
                                    (PlayerState (Just second) Map.empty) (Turn current)
              foldM (rejectPlacement actor FleetAlreadyPlaced) ready replacementRequests
                >>= (`shouldBe` ready)
            _ -> expectationFailure "Invalid ready-state fixture"

    it "rejects placement after termination without overwriting fleet or winner" $
      forM_ [P1, P2] $ \actor -> forM_ [P1, P2] $ \winner ->
        forM_ [AllShipsSunk, OpponentLeft] $ \reason ->
          case placeFleet horizontalFleet of
            Left fault -> expectationFailure (show fault)
            Right fleet -> do
              let finished = GameState (PlayerState (Just fleet) Map.empty)
                                       (PlayerState (Just fleet) Map.empty) (Finished winner reason)
              foldM (rejectPlacement actor GameAlreadyFinished) finished replacementRequests
                >>= (`shouldBe` finished)

  describe "Fleet abstraction checked by GHC against the installed public package" $ do
    it "allows checked construction and read access through public imports" $
      compileProbe (unlines
        ["import Battleship.Board (placeFleet)", "import Battleship.Types",
         "probe :: Either GameError Fleet", "probe = placeFleet []",
         "inspect :: Fleet -> Int", "inspect = length . fleetShips"])
        >>= (\(code, _, errors) -> (code, errors) `shouldBe` (ExitSuccess, ""))

    forM_ [("raw constructor", "probe = Fleet Map.empty", "term-level"),
           ("record update", "probe fleet = fleet { fleetShips = Map.empty }", "record field"),
           ("coerce from an empty map", "probe = coerce (Map.empty :: Map.Map ShipId (Set.Set Coord)) :: Fleet", "representation"),
           ("private module import", "import Battleship.Internal.Fleet\nprobe = Fleet Map.empty", "hidden module")] $ \(name, body, diagnostic) ->
      it ("prevents invalid construction by " ++ name) $ do
        (code, _, errors) <- compileProbe (unlines
          ["import Battleship.Types", "import qualified Data.Map.Strict as Map",
           "import qualified Data.Set as Set", "import Data.Coerce (coerce)", body])
        code `shouldBe` ExitFailure 1
        errors `shouldSatisfy` isInfixOf diagnostic

-- A Left carries neither an updated state nor success events. This test caller
-- keeps the old state and continues the sequence, just as Coordinator must.
rejectPlacement :: PlayerId -> GameError -> GameState -> FleetPlacement -> IO GameState
rejectPlacement actor expected state placements = case step actor (PlaceFleet placements) state of
  Left fault -> (fault `shouldBe` expected) >> pure state
  Right (changed, _) -> expectationFailure "Rejected placement unexpectedly succeeded" >> pure changed

cornerFleet :: FleetPlacement
cornerFleet = [ShipPlacement Carrier (Coord 1 1) Horizontal,
               ShipPlacement Battleship (Coord 7 2) Horizontal,
               ShipPlacement Cruiser (Coord 8 3) Horizontal,
               ShipPlacement Submarine (Coord 8 4) Horizontal,
               ShipPlacement Destroyer (Coord 9 10) Horizontal]

verticalCornerFleet :: FleetPlacement
verticalCornerFleet = [ShipPlacement Carrier (Coord 1 1) Vertical,
                       ShipPlacement Battleship (Coord 2 7) Vertical,
                       ShipPlacement Cruiser (Coord 3 8) Vertical,
                       ShipPlacement Submarine (Coord 4 8) Vertical,
                       ShipPlacement Destroyer (Coord 10 9) Vertical]

badPlacementRequests :: [(FleetPlacement, GameError)]
badPlacementRequests =
  [([], InvalidFleetSize 0),
   (take 4 horizontalFleet, InvalidFleetSize 4),
   (horizontalFleet ++ take 1 horizontalFleet, InvalidFleetSize 6),
   (map (\placement -> if placementShip placement == Submarine
                        then placement { placementShip = Cruiser } else placement) horizontalFleet,
    DuplicateShip Cruiser),
   (replaceShip Destroyer (Coord 1 1) Horizontal horizontalFleet, ShipsOverlap (Coord 1 1)),
   (replaceShip Destroyer (Coord 10 10) Vertical horizontalFleet, ShipOutOfBounds Destroyer (Coord 10 11)),
   (replaceShip Carrier (Coord 0 1) Horizontal horizontalFleet, InvalidCoordinate (Coord 0 1))]

replacementRequests :: [FleetPlacement]
replacementRequests = [horizontalFleet, cornerFleet, verticalCornerFleet] ++ map fst badPlacementRequests

-- Compile only against the built package: clearing -i prevents source imports
-- from bypassing Cabal's hidden-module boundary. Temporary probes are removed.
compileProbe :: String -> IO (ExitCode, String, String)
compileProbe body = do
  directory <- getTemporaryDirectory
  bracket (openTempFile directory "battleship-a03.hs")
    (\(path, handle) -> hClose handle >> removeFile path) $ \(path, handle) -> do
      hPutStr handle ("module Probe where\n" ++ body)
      hClose handle
      readProcessWithExitCode "ghc"
        ["-fno-code", "-fforce-recomp", "-hide-all-packages", "-package", "base",
         "-package", "containers", "-package", "battleship-haskell", "-i", path] ""

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
