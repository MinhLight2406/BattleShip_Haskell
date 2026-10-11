-- | Private representation. Board is the only production module that constructs
-- a Fleet; the public Types module exposes its specialization and read access.
-- Parameters keep this module independent of Types, avoiding an import cycle.
module Battleship.Internal.Fleet (Fleet (..)) where

import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Array.Unboxed (UArray)
import Data.Word (Word8)

data Fleet ship coord = Fleet
  { fleetShips :: !(Map ship (Set coord))
  , fleetOccupied :: !(Set coord)
  , fleetIndex :: !(UArray Int Word8)
  } deriving (Eq)

-- Preserve the public diagnostic shape; derived metadata is not a second model.
instance (Show ship, Show coord) => Show (Fleet ship coord) where
  showsPrec precedence fleet = showParen (precedence > 10) $
    showString "Fleet {fleetShips = " . shows (fleetShips fleet) . showString "}"
