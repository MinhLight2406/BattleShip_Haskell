-- | B-01/B-02: pure placement, shots, turn changes and terminal transitions.
module Battleship.Rules (step) where

import qualified Battleship.Board as Board
import Battleship.Types
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.List (find)
import qualified Data.Set as Set

-- | No state or successful events are returned on Left. The coordinator must
-- keep the original state. Every Command explicitly handles every Phase.
step :: Step
step actor command state = case command of
  PlaceFleet placements -> case gamePhase state of
    Placing -> case playerFleet actorState of
      Just _ -> Left FleetAlreadyPlaced
      Nothing -> do
        fleet <- Board.placeFleet placements
        let placed = setPlayerState actor (actorState { playerFleet = Just fleet }) state
        if fleetsReady placed
          then Right (placed { gamePhase = Turn P1 },
                      [FleetAccepted actor, GameStarted P1, TurnReady P1])
          else Right (placed, [FleetAccepted actor])
    Turn _
      | not (fleetsReady state) -> Left FleetsNotReady
      | otherwise -> Left FleetAlreadyPlaced
    Finished _ _ -> Left GameAlreadyFinished

  Fire coordinate -> case gamePhase state of
    Placing -> Left FleetsNotReady
    Turn current
      | not (fleetsReady state) -> Left FleetsNotReady
      | actor /= current -> Left (NotYourTurn current)
      | not (Board.inBounds coordinate) -> Left (InvalidCoordinate coordinate)
      | Map.member coordinate (playerShots actorState) -> Left (AlreadyFired coordinate)
      | otherwise -> case playerFleet (playerStateFor (otherPlayer actor) state) of
          Nothing -> Left FleetsNotReady
          Just fleet -> shoot coordinate fleet
    Finished _ _ -> Left GameAlreadyFinished

  Quit -> case gamePhase state of
    Placing -> finishQuit
    Turn _ -> finishQuit
    Finished _ _ -> Left GameAlreadyFinished
  where
    actorState = playerStateFor actor state
    shoot coordinate fleet =
      let outcome = resolveShot coordinate fleet (playerShots actorState)
          shooter = actorState { playerShots = Map.insert coordinate outcome (playerShots actorState) }
          recorded = setPlayerState actor shooter state
          (phase, nextEvent) = case outcome of
            Miss -> (Turn (otherPlayer actor), TurnReady (otherPlayer actor))
            Hit -> (Turn actor, TurnReady actor)
            Sunk _ -> (Turn actor, TurnReady actor)
            Win -> (Finished actor AllShipsSunk, GameEnded actor AllShipsSunk)
      in Right (recorded { gamePhase = phase }, [ShotResolved actor coordinate outcome, nextEvent])
    finishQuit =
      let winner = otherPlayer actor
      in Right (state { gamePhase = Finished winner OpponentLeft },
                [GameEnded winner OpponentLeft])

fleetsReady :: GameState -> Bool
fleetsReady state = isJust (playerFleet (gamePlayer1 state))
                && isJust (playerFleet (gamePlayer2 state))

-- Geometry determines hits; history keys determine which cells have been shot.
-- Win takes precedence over Sunk on the last cell of the last remaining ship.
resolveShot :: Coord -> Fleet -> Map.Map Coord Outcome -> Outcome
resolveShot coordinate fleet history =
  case find (Set.member coordinate . snd) (Map.toList ships) of
    Nothing -> Miss
    Just (ship, cells)
      | Set.unions (Map.elems ships) `Set.isSubsetOf` fired -> Win
      | cells `Set.isSubsetOf` fired -> Sunk ship
      | otherwise -> Hit
  where
    ships = fleetShips fleet
    fired = Set.insert coordinate (Map.keysSet history)
