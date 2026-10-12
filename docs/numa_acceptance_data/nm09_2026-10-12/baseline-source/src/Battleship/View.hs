-- | A player's public view. Opponent geometry is never copied into the result,
-- even after termination; wire v1 sends filtered events rather than snapshots.
module Battleship.View (viewFor) where

import Battleship.Types
import Data.Maybe (isJust)

viewFor :: PlayerId -> GameState -> PlayerView
viewFor player state = PlayerView
  { viewPlayer = player
  , viewPhase = gamePhase state
  , ownFleetView = playerFleet (playerStateFor player state)
  , outgoingShotsView = playerShots (playerStateFor player state)
  , incomingShotsView = shotsReceived player state
  , opponentReady = isJust (playerFleet (playerStateFor (otherPlayer player) state))
  }
