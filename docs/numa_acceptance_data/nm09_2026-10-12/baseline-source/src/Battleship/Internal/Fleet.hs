-- | Private representation. Board is the only production module that constructs
-- a Fleet; the public Types module exposes its specialization and read access.
-- Parameters keep this module independent of Types, avoiding an import cycle.
module Battleship.Internal.Fleet (Fleet (..)) where

import Data.Map.Strict (Map)
import Data.Set (Set)

newtype Fleet ship coord = Fleet
  { fleetShips :: Map ship (Set coord)
  } deriving (Eq, Show)
