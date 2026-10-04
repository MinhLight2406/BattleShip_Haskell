-- | B-01: pure command/phase dispatch, placement and quit transitions.
-- Successful shot resolution (Miss/Hit/Sunk/Win) belongs to the next rules task.
module Battleship.Rules (step) where

import qualified Battleship.Board as Board
import Battleship.Types
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)

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
      -- ponytail: B-01 validates FIRE only; replace this explicit Left with
      -- shot resolution and ShotResolved/TurnReady/GameEnded in the next task.
      | otherwise -> Left (InvalidCommand "B-01: shot resolution is not implemented")
    Finished _ _ -> Left GameAlreadyFinished

  Quit -> case gamePhase state of
    Placing -> finishQuit
    Turn _ -> finishQuit
    Finished _ _ -> Left GameAlreadyFinished
  where
    actorState = playerStateFor actor state
    finishQuit =
      let winner = otherPlayer actor
      in Right (state { gamePhase = Finished winner OpponentLeft },
                [GameEnded winner OpponentLeft])

fleetsReady :: GameState -> Bool
fleetsReady state = isJust (playerFleet (gamePlayer1 state))
                && isJust (playerFleet (gamePlayer2 state))
