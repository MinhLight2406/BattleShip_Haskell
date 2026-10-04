module RulesSpec (spec) where

import qualified Battleship.Board as Board
import Battleship.Rules (step)
import Battleship.Types
import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import Data.Typeable (typeRep)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)

spec :: Spec
spec = describe "B-01 step contract" $ do
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
          checkRejection actor (Fire (Coord 10 10)) state
            (if actor == current then pendingFire else NotYourTurn current)

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

      it (show actor ++ " leaves an otherwise valid FIRE explicitly pending without recording a result") $
        checkRejection actor (Fire (Coord 10 9)) active pendingFire

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
                      (P1, Fire (Coord 1 6)), (P1, PlaceFleet []), (P1, Fire (Coord 10 9))]
          (after, events) = foldl (\(state, previous) (actor, command) ->
            let (next, emitted) = applyAsCaller actor command state
            in (next, previous ++ emitted)) (withHistories, []) commands
      after `shouldBe` withHistories
      events `shouldBe` []
      checkQuit P2 after

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

pendingFire :: GameError
pendingFire = InvalidCommand "B-01: shot resolution is not implemented"

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
