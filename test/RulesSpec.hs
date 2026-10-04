module RulesSpec (spec) where

import qualified Battleship.Board as Board
import Battleship.Rules (step)
import Battleship.Types
import Control.Monad (foldM, forM_)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.List (permutations)
import Data.Proxy (Proxy (..))
import Data.Typeable (typeRep)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)

spec :: Spec
spec = do
  b01Spec
  b02Spec

b01Spec :: Spec
b01Spec = describe "B-01 step contract" $ do
  it "implements the published Step signature" $
    typeRep (proxyOf step) `shouldBe` typeRep (Proxy :: Proxy Step)

  describe "all Command/Phase combinations" $ do
    forM_ [P1, P2] $ \actor -> do
      it (show actor ++ " places in Placing without changing the opponent or old state") $ do
        let expected = setPlayerState actor (PlayerState (Just (fleetFor actor)) Map.empty) initialGameState
        step actor (PlaceFleet (placementsFor actor)) initialGameState
          `shouldBe` Right (expected, [FleetAccepted actor])
        gamePlayer1 initialGameState `shouldBe` PlayerState Nothing Map.empty
        gamePlayer2 initialGameState `shouldBe` PlayerState Nothing Map.empty

      it (show actor ++ " cannot FIRE in Placing") $
        checkRejection actor (Fire (Coord 1 6)) initialGameState FleetsNotReady

      it (show actor ++ " can Quit in Placing") $
        checkQuit actor initialGameState

    forM_ [P1, P2] $ \current ->
      forM_ [P1, P2] $ \actor -> do
        let state = readyState { gamePhase = Turn current }
        it (show actor ++ " cannot PLACE in Turn " ++ show current) $
          checkRejection actor (PlaceFleet (placementsFor actor)) state FleetAlreadyPlaced

        it (show actor ++ " handles FIRE in Turn " ++ show current ++ " explicitly") $
          if actor == current
            then checkShot actor (Coord 10 10) Miss state
            else checkRejection actor (Fire (Coord 10 10)) state (NotYourTurn current)

        it (show actor ++ " can Quit in Turn " ++ show current) $
          checkQuit actor state

    forM_ [Finished winner reason | winner <- [P1, P2], reason <- [AllShipsSunk, OpponentLeft]] $
      \phase -> forM_ [P1, P2] $ \actor ->
        forM_ [("PLACE", PlaceFleet (placementsFor actor)), ("FIRE", Fire (Coord 10 10)), ("QUIT", Quit)] $
          \(name, command) -> it (show actor ++ " rejects " ++ name ++ " in " ++ show phase) $
            checkRejection actor command (readyState { gamePhase = phase }) GameAlreadyFinished

  describe "checked placement and one-time start" $ do
    forM_ [(P1, P2), (P2, P1)] $ \(first, second) ->
      it (show first ++ " can place first, but P1 always starts after " ++ show second) $ do
        case step first (PlaceFleet (placementsFor first)) initialGameState of
          Left gameError -> expectationFailure (show gameError)
          Right (waiting, events) -> do
            gamePhase waiting `shouldBe` Placing
            events `shouldBe` [FleetAccepted first]
            step second (PlaceFleet (placementsFor second)) waiting
              `shouldBe` Right (readyState, [FleetAccepted second, GameStarted P1, TurnReady P1])
            step first (PlaceFleet (placementsFor first)) waiting
              `shouldBe` Left FleetAlreadyPlaced

    forM_ [P1, P2] $ \actor ->
      forM_ badFleets $ \(name, placements, expectedError) ->
        it (show actor ++ " propagates Board rejection: " ++ name) $
          checkRejection actor (PlaceFleet placements) initialGameState expectedError

    forM_ [P1, P2] $ \actor ->
      it (show actor ++ " cannot replace a placed fleet even with a malformed request") $
        checkRejection actor (PlaceFleet []) (waitingFor actor) FleetAlreadyPlaced

    forM_ badFleets $ \(name, placements, expectedError) ->
      it ("a rejected second fleet preserves P1 and can be corrected: " ++ name) $ do
        let waiting = waitingFor P1
            (afterError, emitted) = applyAsCaller P2 (PlaceFleet placements) waiting
        checkRejection P2 (PlaceFleet placements) waiting expectedError
        afterError `shouldBe` waiting
        emitted `shouldBe` []
        step P2 (PlaceFleet (placementsFor P2)) afterError
          `shouldBe` Right (readyState, [FleetAccepted P2, GameStarted P1, TurnReady P1])

  describe "FIRE validation and error priority" $ do
    forM_ [P1, P2] $ \actor -> do
      let active = withHistories { gamePhase = Turn actor }
      forM_ invalidCoordinates $ \coordinate ->
        it (show actor ++ " rejects invalid coordinate " ++ show coordinate ++ " without losing state") $
          checkRejection actor (Fire coordinate) active (InvalidCoordinate coordinate)

      forM_ [Miss, Hit, Sunk Destroyer, Win] $ \outcome ->
        it (show actor ++ " rejects an already-recorded " ++ show outcome ++ " shot") $ do
          let player = playerStateFor actor active
              duplicate = Coord 2 6
              state = setPlayerState actor
                (player { playerShots = Map.insert duplicate outcome (playerShots player) }) active
          checkRejection actor (Fire duplicate) state (AlreadyFired duplicate)

      it (show actor ++ " checks the current turn before coordinate validity or duplicates") $ do
        let wrongTurn = active { gamePhase = Turn (otherPlayer actor) }
            recorded = if actor == P1 then Coord 1 6 else Coord 10 10
        checkRejection actor (Fire (Coord 0 0)) wrongTurn (NotYourTurn (otherPlayer actor))
        checkRejection actor (Fire recorded) wrongTurn (NotYourTurn (otherPlayer actor))

      it (show actor ++ " rejects out-of-bounds history entries as invalid coordinates first") $ do
        let player = playerStateFor actor active
            outside = Coord 0 1
            state = setPlayerState actor
              (player { playerShots = Map.insert outside Miss (playerShots player) }) active
        checkRejection actor (Fire outside) state (InvalidCoordinate outside)

      it (show actor ++ " rejects FIRE during placement even with an invalid coordinate") $
        checkRejection actor (Fire (Coord 0 0)) (waitingFor actor) FleetsNotReady

      it (show actor ++ " resolves an otherwise valid FIRE as Miss and records it") $
        checkShot actor (Coord 10 9) Miss active

    forM_ [P1, P2] $ \current ->
      forM_ [P1, P2] $ \actor ->
        forM_ [initialGameState, waitingFor P1, waitingFor P2] $ \unready ->
          it ("checks fleet readiness for actor " ++ show actor ++ " in raw Turn " ++ show current
              ++ " with readiness " ++ show (fmap (const True) (playerFleet (gamePlayer1 unready)),
                                             fmap (const True) (playerFleet (gamePlayer2 unready)))) $ do
            let state = unready { gamePhase = Turn current }
            checkRejection actor (Fire (Coord 10 10)) state FleetsNotReady
            checkRejection actor (PlaceFleet (placementsFor actor)) state FleetsNotReady

  describe "termination and immutable history" $ do
    forM_ [P1, P2] $ \actor ->
      it (show actor ++ " quits without changing either fleet/history and EOF cannot overwrite winner") $ do
        checkQuit actor withHistories
        case step actor Quit withHistories of
          Left gameError -> expectationFailure (show gameError)
          Right (finished, events) -> do
            events `shouldBe` [GameEnded (otherPlayer actor) OpponentLeft]
            checkRejection actor Quit finished GameAlreadyFinished
            checkRejection (otherPlayer actor) Quit finished GameAlreadyFinished

    it "Finished rejects malformed payloads before Board/coordinate validation" $ do
      let state = withHistories { gamePhase = Finished P1 AllShipsSunk }
      checkRejection P2 (PlaceFleet []) state GameAlreadyFinished
      checkRejection P2 (Fire (Coord minBound maxBound)) state GameAlreadyFinished

    it "a sequence of errors keeps all fields, emits no success events and still allows Quit" $ do
      let commands = [(P2, Fire (Coord 10 10)), (P1, Fire (Coord 0 1)),
                      (P1, Fire (Coord 1 6)), (P1, PlaceFleet []), (P1, Fire (Coord 1 6))]
          (after, events) = foldl (\(state, previous) (actor, command) ->
            let (next, emitted) = applyAsCaller actor command state
            in (next, previous ++ emitted)) (withHistories, []) commands
      after `shouldBe` withHistories
      events `shouldBe` []
      checkQuit P2 after

b02Spec :: Spec
b02Spec = describe "B-02 shot resolution and pure games" $ do
  forM_ [P1, P2] $ \actor -> do
    let active = readyState { gamePhase = Turn actor }
        target = expectedShipCells (otherPlayer actor)
        occupied = concatMap snd target
        carrierStart = Coord 1 (if actor == P1 then 6 else 1)

    it (show actor ++ " records Miss once and gives the opponent the turn") $
      checkShot actor (Coord 10 9) Miss (withHistories { gamePhase = Turn actor })

    it (show actor ++ " hits the opponent's fleet and keeps the turn") $
      checkShot actor carrierStart Hit active

    it (show actor ++ " resolves all 100 first-shot coordinates against the opponent's board") $
      forM_ [Coord column row | column <- [1 .. 10], row <- [1 .. 10]] $ \coordinate ->
        checkShot actor coordinate (if coordinate `elem` occupied then Hit else Miss) active

    forM_ target $ \(ship, cells) -> do
      it (show actor ++ " sinks " ++ show ship ++ " in every cell order without changing old Hit outcomes") $
        forM_ (permutations cells) $ \order -> do
          sunk <- foldM (\state (index, coordinate) -> do
            let expected = if index == length cells then Sunk ship else Hit
            checkShot actor coordinate expected state
            case step actor (Fire coordinate) state of
              Right (next, _) -> pure next
              Left fault -> expectationFailure (show fault) >> pure state)
            active (zip [1 ..] order)
          forM_ order $ \coordinate ->
            checkRejection actor (Fire coordinate) sunk (AlreadyFired coordinate)

      it (show actor ++ " wins with any last cell of " ++ show ship ++ ", with no extra Sunk or TURN") $
        forM_ cells $ \lastCell -> do
          let prior = Map.insert (Coord 10 10) Miss (Map.fromList [(cell, Hit) | cell <- occupied, cell /= lastCell])
              before = setPlayerState actor ((playerStateFor actor active) { playerShots = prior }) active
          checkShot actor lastCell Win before
          case step actor (Fire lastCell) before of
            Left fault -> expectationFailure (show fault)
            Right (finished, _) -> forM_ [P1, P2] $ \sender ->
              forM_ [Fire lastCell, Fire (Coord 0 0), PlaceFleet [], Quit] $ \command ->
                checkRejection sender command finished GameAlreadyFinished

    it (show actor ++ " does not win merely by recording 17 shots including water misses") $ do
      let water = take 16 [Coord column row | column <- [1 .. 10], row <- [1 .. 10],
                                             Coord column row `notElem` occupied]
          player = (playerStateFor actor active) { playerShots = Map.fromList [(cell, Miss) | cell <- water] }
      checkShot actor carrierStart Hit (setPlayerState actor player active)

    it (show actor ++ " sinks all ship IDs in a vertical fleet, including touching length-three ships") $
      case Board.placeFleet verticalPlacements of
        Left fault -> expectationFailure (show fault)
        Right fleet -> do
          let opponent = otherPlayer actor
              vertical = setPlayerState opponent ((playerStateFor opponent active) { playerFleet = Just fleet }) active
          forM_ (zip [1 ..] shipSizes) $ \(column, (ship, size)) -> do
            let prior = Map.fromList [(Coord column row, Hit) | row <- [1 .. size - 1]]
                before = setPlayerState actor ((playerStateFor actor vertical) { playerShots = prior }) vertical
            checkShot actor (Coord column size) (Sunk ship) before

    it (show actor ++ " rejects wrong-turn/outside/repeated shots without consuming its retained Hit turn") $ do
      let state = setPlayerState actor ((playerStateFor actor active) {
                    playerShots = Map.singleton carrierStart Hit }) active
      checkRejection (otherPlayer actor) (Fire carrierStart) state (NotYourTurn actor)
      checkRejection actor (Fire (Coord 0 1)) state (InvalidCoordinate (Coord 0 1))
      checkRejection actor (Fire carrierStart) state (AlreadyFired carrierStart)
      checkRejection actor (PlaceFleet []) state FleetAlreadyPlaced
      checkShot actor (Coord 2 (coordRow carrierStart)) Hit state

    it (show actor ++ " cannot repeat an actual Miss after the opponent returns the turn") $ do
      case step actor (Fire (Coord 10 9)) active of
        Left fault -> expectationFailure (show fault)
        Right (afterMiss, _) -> do
          checkRejection actor (Fire (Coord 10 9)) afterMiss (NotYourTurn (otherPlayer actor))
          case step (otherPlayer actor) (Fire (Coord 10 9)) afterMiss of
            Left fault -> expectationFailure (show fault)
            Right (returned, _) -> do
              checkRejection actor (Fire (Coord 10 9)) returned (AlreadyFired (Coord 10 9))
              checkShot actor carrierStart Hit returned

  it "allows both players to shoot the same coordinate on separate boards and exposes shotsReceived correctly" $
    case step P1 (Fire (Coord 10 10)) readyState >>= \(afterFirst, _) -> step P2 (Fire (Coord 10 10)) afterFirst of
      Left fault -> expectationFailure (show fault)
      Right (afterBoth, _) -> do
        shotsReceived P1 afterBoth `shouldBe` Map.singleton (Coord 10 10) Miss
        shotsReceived P2 afterBoth `shouldBe` Map.singleton (Coord 10 10) Miss
        gamePhase afterBoth `shouldBe` Turn P1
        shotsReceived P1 initialGameState `shouldBe` Map.empty
        shotsReceived P2 initialGameState `shouldBe` Map.empty

  forM_ [P1, P2] $ \winner ->
    it ("simulates a complete pure game from empty state until " ++ show winner ++ " wins") $ do
      let first = otherPlayer winner
          placements = [(first, PlaceFleet (placementsFor first)), (winner, PlaceFleet (placementsFor winner))]
          opening = if winner == P1 then [(P1, Fire (Coord 10 10)), (P2, Fire (Coord 10 10))]
                    else [(P1, Fire (Coord 10 10))]
          target = expectedShipCells (otherPlayer winner)
          attacks = [(cell, if ship == Destroyer && index == length cells then Win
                           else if index == length cells then Sunk ship else Hit) |
                     (ship, cells) <- target, (index, cell) <- zip [1 ..] cells]
          commands = placements ++ opening ++ [(winner, Fire cell) | (cell, _) <- attacks]
          expectedOpening = if winner == P1
            then [[ShotResolved P1 (Coord 10 10) Miss, TurnReady P2],
                  [ShotResolved P2 (Coord 10 10) Miss, TurnReady P1]]
            else [[ShotResolved P1 (Coord 10 10) Miss, TurnReady P2]]
          expectedShots = [[ShotResolved winner cell outcome,
                            if outcome == Win then GameEnded winner AllShipsSunk else TurnReady winner] |
                           (cell, outcome) <- attacks]
      case simulate commands of
        Left fault -> expectationFailure (show fault)
        Right (finished, batches) -> do
          gamePhase finished `shouldBe` Finished winner AllShipsSunk
          batches `shouldBe` [[FleetAccepted first], [FleetAccepted winner, GameStarted P1, TurnReady P1]]
                            ++ expectedOpening ++ expectedShots
          playerFleet (gamePlayer1 finished) `shouldBe` Just (fleetFor P1)
          playerFleet (gamePlayer2 finished) `shouldBe` Just (fleetFor P2)
          let expectedWinnerShots = Map.fromList attacks
                `Map.union` (if winner == P1 then Map.singleton (Coord 10 10) Miss else Map.empty)
          playerShots (playerStateFor winner finished) `shouldBe` expectedWinnerShots
          shotsReceived (otherPlayer winner) finished `shouldBe` expectedWinnerShots
          shotsReceived winner finished `shouldBe` Map.singleton (Coord 10 10) Miss
          Set.size (Map.keysSet expectedWinnerShots `Set.intersection`
                    Set.fromList (concatMap snd target)) `shouldBe` 17
          checkRejection winner (Fire (Coord 10 9)) finished GameAlreadyFinished
          checkRejection (otherPlayer winner) Quit finished GameAlreadyFinished

-- Expected geometry is independent of Board.shipCells and Types.shipLength.
shipSizes :: [(ShipId, Int)]
shipSizes = [(Carrier, 5), (Battleship, 4), (Cruiser, 3), (Submarine, 3), (Destroyer, 2)]

expectedShipCells :: PlayerId -> [(ShipId, [Coord])]
expectedShipCells player =
  [(ship, [Coord column row | column <- [1 .. size]]) |
   ((ship, size), row) <- zip shipSizes [if player == P1 then 1 else 6 ..]]

verticalPlacements :: FleetPlacement
verticalPlacements = [ShipPlacement ship (Coord column 1) Vertical | (column, (ship, _)) <- zip [1 ..] shipSizes]

checkShot :: PlayerId -> Coord -> Outcome -> GameState -> IO ()
checkShot actor coordinate outcome original = do
  let oldPlayer = playerStateFor actor original
      history = Map.insert coordinate outcome (playerShots oldPlayer)
      recorded = setPlayerState actor (oldPlayer { playerShots = history }) original
      expectedPhase = case outcome of
        Miss -> Turn (otherPlayer actor)
        Win -> Finished actor AllShipsSunk
        _ -> Turn actor
      nextEvent = case outcome of
        Miss -> TurnReady (otherPlayer actor)
        Win -> GameEnded actor AllShipsSunk
        _ -> TurnReady actor
  step actor (Fire coordinate) original `shouldBe`
    Right (recorded { gamePhase = expectedPhase }, [ShotResolved actor coordinate outcome, nextEvent])
  shotsReceived (otherPlayer actor) recorded `shouldBe` history
  shotsReceived actor recorded `shouldBe` shotsReceived actor original
  Map.size history `shouldBe` Map.size (playerShots oldPlayer) + 1

simulate :: [(PlayerId, Command)] -> Either GameError (GameState, [[Event]])
simulate = foldM (\(state, batches) (actor, command) -> do
  (next, events) <- step actor command state
  pure (next, batches ++ [events])) (initialGameState, [])

-- This adapter expresses the coordinator contract; it is not a test of STM or
-- the future Coordinator implementation. On Left it retains the full old state.
applyAsCaller :: PlayerId -> Command -> GameState -> (GameState, [Event])
applyAsCaller actor command state = either (const (state, [])) id (step actor command state)

checkRejection :: PlayerId -> Command -> GameState -> GameError -> IO ()
checkRejection actor command original expectedError = do
  step actor command original `shouldBe` Left expectedError
  applyAsCaller actor command original `shouldBe` (original, [])

checkQuit :: PlayerId -> GameState -> IO ()
checkQuit actor original = step actor Quit original `shouldBe`
  Right (original { gamePhase = Finished (otherPlayer actor) OpponentLeft },
         [GameEnded (otherPlayer actor) OpponentLeft])

proxyOf :: a -> Proxy a
proxyOf _ = Proxy

placementsFor :: PlayerId -> FleetPlacement
placementsFor player =
  [ShipPlacement ship (Coord 1 row) Horizontal |
   (ship, row) <- zip [Carrier, Battleship, Cruiser, Submarine, Destroyer] [startRow ..]]
  where startRow = if player == P1 then 1 else 6

fleetFor :: PlayerId -> Fleet
fleetFor player = case Board.placeFleet (placementsFor player) of
  Right fleet -> fleet
  Left gameError -> error ("Invalid RulesSpec fixture: " ++ show gameError)

waitingFor :: PlayerId -> GameState
waitingFor player = setPlayerState player (PlayerState (Just (fleetFor player)) Map.empty) initialGameState

readyState :: GameState
readyState = GameState (PlayerState (Just (fleetFor P1)) Map.empty)
                      (PlayerState (Just (fleetFor P2)) Map.empty) (Turn P1)

withHistories :: GameState
withHistories = readyState
  { gamePlayer1 = (gamePlayer1 readyState) { playerShots = Map.singleton (Coord 1 6) Hit }
  , gamePlayer2 = (gamePlayer2 readyState) { playerShots = Map.singleton (Coord 10 10) Miss }
  }

invalidCoordinates :: [Coord]
invalidCoordinates = [Coord 0 1, Coord 1 0, Coord 11 1, Coord 1 11, Coord (-1) 5, Coord 5 (-1),
                      Coord minBound 1, Coord maxBound 1, Coord 1 minBound, Coord 1 maxBound]

badFleets :: [(String, FleetPlacement, GameError)]
badFleets =
  [("wrong count", take 4 canonical, InvalidFleetSize 4),
   ("duplicate ID", take 4 canonical ++ [ShipPlacement Carrier (Coord 1 5) Horizontal], DuplicateShip Carrier),
   ("invalid start", replaceLast (Coord 0 1), InvalidCoordinate (Coord 0 1)),
   ("out of bounds", replaceLast (Coord 10 10), ShipOutOfBounds Destroyer (Coord 11 10)),
   ("overlap", replaceLast (Coord 1 1), ShipsOverlap (Coord 1 1))]
  where
    canonical = placementsFor P1
    replaceLast coordinate = take 4 canonical ++ [ShipPlacement Destroyer coordinate Horizontal]
