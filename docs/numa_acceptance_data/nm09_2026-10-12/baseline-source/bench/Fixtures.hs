{-# LANGUAGE BangPatterns #-}
module Fixtures
  ( Fixture (..), Entry (..), Trace, seeds, fixture, replayPure, replayCoordinator
  , digestTrace, fixtureJSON, forceFixture, expectedFrames, jsonString, object
  ) where

import qualified Battleship.Coordinator as C
import Battleship.Protocol
import Battleship.Rules (step)
import Battleship.Types
import Battleship.View (viewFor)
import Control.Concurrent.STM
import Control.Monad (forM)
import Data.Bits (xor)
import qualified Data.ByteString.Char8 as BS
import Data.Char (ord)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word64)
import Numeric (showHex)
import Test.QuickCheck (shuffle)
import Test.QuickCheck.Gen (unGen)
import Test.QuickCheck.Random (mkQCGen)
import TestSupport.Generators (genValidFleet, legalBoardCells, referenceCells)

data Entry = Entry { actor :: PlayerId, command :: Command, expected :: Either GameError [Event] }
  deriving (Eq, Show)
data Fixture = Fixture { fixtureSeed :: Int, fleet1 :: FleetPlacement, fleet2 :: FleetPlacement, entries :: [Entry] }
  deriving (Eq, Show)
type Trace = [(GameState, Either GameError [Event], PlayerView, PlayerView)]

seeds :: [Int]
seeds = [424242, 8675309, 20261011]

fixture :: Int -> Fixture
fixture seed = Fixture seed first second (opening ++ attacks)
  where
    (first, second) = unGen ((,) <$> genValidFleet <*> genValidFleet) (mkQCGen seed) 30
    miss placements = case [cell | cell <- legalBoardCells, cell `notElem` concatMap referenceCells placements] of
      cell : _ -> cell
      [] -> error "Generator violated the 17-cell fleet invariant"
    miss1 = miss second
    miss2 = miss first
    opening =
      [ Entry P1 (Fire miss1) (Left FleetsNotReady)
      , Entry P1 (PlaceFleet first) (Right [FleetAccepted P1])
      , Entry P1 (PlaceFleet first) (Left FleetAlreadyPlaced)
      , Entry P2 (PlaceFleet second) (Right [FleetAccepted P2, GameStarted P1, TurnReady P1])
      , Entry P2 (Fire miss2) (Left (NotYourTurn P1))
      , Entry P1 (Fire miss1) (Right [ShotResolved P1 miss1 Miss, TurnReady P2])
      , Entry P2 (Fire miss2) (Right [ShotResolved P2 miss2 Miss, TurnReady P1])
      , Entry P1 (Fire miss1) (Left (AlreadyFired miss1)) ]
    orderedShips = unGen (shuffle second) (mkQCGen (seed + 1)) 30
    targetGroups = [(placementShip ship, unGen (shuffle (referenceCells ship)) (mkQCGen (seed + 2 + index)) 30)
                   | (index, ship) <- zip [0 ..] orderedShips]
    attacks = concat
      [ [let outcome = if shotIndex < length cells - 1 then Hit
                       else if shipIndex == 4 then Win else Sunk ship
             ending = if outcome == Win then GameEnded P1 AllShipsSunk else TurnReady P1
         in Entry P1 (Fire cell) (Right [ShotResolved P1 cell outcome, ending])
        | (shotIndex, cell) <- zip [0 ..] cells]
      | (shipIndex, (ship, cells)) <- zip [0 :: Int ..] targetGroups ]

-- Each invocation receives a state read through IORef by the harness. Keeping
-- this call opaque prevents the loop measuring one shared, already forced thunk.
{-# NOINLINE replayPure #-}
replayPure :: GameState -> [Entry] -> Trace
replayPure _ [] = []
replayPure previous (entry : rest) =
  let result = step (actor entry) (command entry) previous
      (next, observation) = case result of
        Left fault -> (previous, Left fault)
        Right (state, events) -> (state, Right events)
  in if observation /= expected entry then error ("Benchmark core mismatch: " ++ show entry)
     else (next, observation, viewFor P1 next, viewFor P2 next) : replayPure next rest

expectedFrames :: Entry -> [(PlayerId, BS.ByteString)]
expectedFrames entry = either (error . show) id $ case expected entry of
  Left fault -> do
    frame <- encodeResponse (Rejected (wireError fault))
    pure [(actor entry, frame)]
  Right events -> concat <$> traverse (encodeEvent phase) events
    where phase = if any isEnding events then Finished P1 AllShipsSunk
                  else if any isStarted events then Turn P1 else Placing
          isEnding (GameEnded _ _) = True
          isEnding _ = False
          isStarted (GameStarted _) = True
          isStarted _ = False

replayCoordinator :: [Entry] -> IO Trace
replayCoordinator workload = do
  coordinator <- atomically (C.newCoordinator initialGameState)
  forM workload $ \entry -> do
    (state, frames) <- atomically $ do
      accepted <- C.submitCommand step coordinator (actor entry) (command entry)
      case accepted of Left fault -> error (show fault); Right _ -> pure ()
      state <- C.readGameState coordinator
      frames <- concat <$> mapM (drain coordinator) [P1, P2]
      pure (state, frames)
    let wanted = expectedFrames entry
        ordered xs = [(player, frame) | player <- [P1, P2], (recipient, frame) <- xs, recipient == player]
    if frames /= ordered wanted then error ("Benchmark coordinator frames mismatch: " ++ show entry)
      else pure (state, expected entry, viewFor P1 state, viewFor P2 state)
  where
    drain coordinator player = do
      count <- C.queuedFrameCount coordinator player
      frames <- sequence [C.nextFrame coordinator player | _ <- [1 .. count]]
      pure [(player, frame) | Just frame <- frames]

-- Strict structural traversal forces every state/result/event and BOTH views,
-- including every Fleet cell and every historical outcome. No orphan NFData or
-- production type/API changes are needed. Digest work is part of the workload.
digestTrace :: Trace -> Word64
digestTrace = foldl' (\ !hash value -> (hash `xor` fromIntegral value) * 1099511628211) 14695981039346656037
  . concatMap (\(state, result, first, second) -> stateNumbers state ++ resultNumbers result ++ viewNumbers first ++ viewNumbers second)
  where
    stateNumbers state = phaseNumbers (gamePhase state) ++ playerNumbers (gamePlayer1 state) ++ playerNumbers (gamePlayer2 state)
    playerNumbers player = fleetNumbers (playerFleet player) ++ shotsNumbers (playerShots player)
    viewNumbers view = fromEnum (viewPlayer view) : phaseNumbers (viewPhase view) ++ fleetNumbers (ownFleetView view)
      ++ shotsNumbers (outgoingShotsView view) ++ shotsNumbers (incomingShotsView view) ++ [fromEnum (opponentReady view)]
    resultNumbers (Left fault) = let text = show fault in 0 : length text : map ord text
    resultNumbers (Right events) = 1 : length events : concatMap eventNumbers events
    eventNumbers event = case event of
      FleetAccepted player -> [0, fromEnum player]
      GameStarted player -> [1, fromEnum player]
      ShotResolved player coordinate outcome -> [2, fromEnum player] ++ coordNumbers coordinate ++ outcomeNumbers outcome
      TurnReady player -> [3, fromEnum player]
      GameEnded player reason -> [4, fromEnum player, reasonNumber reason]
    phaseNumbers Placing = [0]
    phaseNumbers (Turn player) = [1, fromEnum player]
    phaseNumbers (Finished player reason) = [2, fromEnum player, reasonNumber reason]
    reasonNumber AllShipsSunk = 0
    reasonNumber OpponentLeft = 1
    fleetNumbers Nothing = [0]
    fleetNumbers (Just fleet) = 1 : Map.size (fleetShips fleet) : concat
      [fromEnum ship : Set.size cells : concatMap coordNumbers (Set.toAscList cells) | (ship, cells) <- Map.toAscList (fleetShips fleet)]
    shotsNumbers shots = Map.size shots : concat [coordNumbers cell ++ outcomeNumbers outcome | (cell, outcome) <- Map.toAscList shots]
    coordNumbers (Coord column row) = [column, row]
    outcomeNumbers Miss = [0]
    outcomeNumbers Hit = [1]
    outcomeNumbers (Sunk ship) = [2, fromEnum ship]
    outcomeNumbers Win = [3]

forceFixture :: Fixture -> ()
forceFixture value = length (fixtureJSON value) `seq` ()

fixtureJSON :: Fixture -> String
fixtureJSON value = object
  [ ("seed", show (fixtureSeed value)), ("commandCount", show (length (entries value)))
  , ("checksum", jsonString (show (digestTrace (replayPure initialGameState (entries value)))))
  , ("commands", "[" ++ comma [object
      [("actor", jsonString (show (actor entry))), ("command", jsonString (line (either (error . show) id (encodeCommand (command entry)))))
      , ("responses", object [(show player, "[" ++ comma [jsonString (line frame) | (recipient, frame) <- expectedFrames entry, recipient == player] ++ "]") | player <- [P1, P2]])]
      | entry <- entries value] ++ "]") ]
  where line = BS.unpack . BS.takeWhile (/= '\n')

comma :: [String] -> String
comma = foldr (\item rest -> item ++ if null rest then "" else ',' : rest) ""

object :: [(String, String)] -> String
object fields = "{" ++ comma [jsonString key ++ ":" ++ value | (key, value) <- fields] ++ "}"

jsonString :: String -> String
jsonString text = '"' : concatMap escape text ++ "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape character | ord character < 32 = "\\u" ++ replicate (4 - length hex) '0' ++ hex
      where hex = showHex (ord character) ""
    escape character = [character]
