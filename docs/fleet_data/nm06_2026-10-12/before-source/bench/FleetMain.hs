{-# LANGUAGE BangPatterns #-}
module Main (main) where

import qualified Battleship.Board as Board
import Battleship.Types
import Control.Concurrent (getNumCapabilities)
import Control.Exception (evaluate)
import Control.Monad (foldM)
import Data.IORef
import Data.List (find, foldl')
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Fixtures (fleet1, fleet2, fixture, seeds, object, jsonString)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats
import System.CPUTime (getCPUTime)
import System.Environment (getArgs)
import System.Mem (performGC)
import TestSupport.Generators (legalBoardCells, referenceCells)
import Text.Read (readMaybe)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [mode, amount] | mode `elem` ["scan", "union", "construct", "retain"],
                    Just count <- readMaybe amount, count > 0, count <= 1000000 -> measure mode count
    _ -> ioError (userError "Usage: battleship-fleet-benchmark scan|union|construct|retain REPETITIONS +RTS -T -RTS")

measure :: String -> Int -> IO ()
measure mode count = do
  enabled <- getRTSStatsEnabled
  if enabled then pure () else ioError (userError "Benchmark requires +RTS -T")
  let placements = concatMap (\seed -> let value = fixture seed in [fleet1 value, fleet2 value]) seeds
  refs <- mapM prepare placements
  capabilities <- getNumCapabilities
  performGC
  before <- getRTSStats
  startCpu <- getCPUTime
  start <- getMonotonicTimeNSec
  retained <- newIORef ([] :: [Fleet])
  checksum <- foldM (\ !total _ -> foldM (runOne mode retained) total refs) 0 [1 .. count]
  end <- getMonotonicTimeNSec
  endCpu <- getCPUTime
  performGC
  after <- getRTSStats
  -- Keep retained fleets reachable across the accounting GC.
  held <- readIORef retained
  heldCount <- evaluate (length held)
  let operations = count * length refs * if mode == "scan" then 100 else 1
      retainedBytes = toInteger (gcdetails_live_bytes (gc after)) - toInteger (gcdetails_live_bytes (gc before))
  putStrLn $ object
    [("schemaVersion", "1"), ("mode", jsonString mode), ("capabilities", show capabilities)
    ,("games", show (count * length refs)), ("commands", show operations), ("checksum", jsonString (show checksum))
    ,("elapsedNs", show (end - start)), ("cpuSeconds", show (fromIntegral (endCpu - startCpu) / 1e12 :: Double))
    ,("allocatedBytes", show (allocated_bytes after - allocated_bytes before))
    ,("gcCpuSecondsAccounting", show (fromIntegral (gc_cpu_ns after - gc_cpu_ns before) / 1e9 :: Double))
    ,("maxLiveBytesProcess", show (max_live_bytes after)), ("maxMemoryBytesProcess", show (max_mem_in_use_bytes after))
    ,("retainedFleets", show heldCount), ("retainedHeapDeltaBytes", show retainedBytes)]
  where
    prepare input = do
      fleet <- evaluate (checked input)
      _ <- evaluate (geometryDigest fleet)
      ref <- newIORef (input, fleet)
      let pairs = [(cell, ship) | placement <- input, cell <- referenceCells placement, let ship = placementShip placement]
          lookupDigest = sum [maybe 0 ((+ 1) . fromEnum) (lookup cell pairs) | cell <- legalBoardCells]
          cellsDigest = sum [coordColumn cell + 10 * coordRow cell | (cell, _) <- pairs]
      pure (ref, lookupDigest, cellsDigest)

{-# NOINLINE runOne #-}
runOne :: String -> IORef [Fleet] -> Int -> (IORef (FleetPlacement, Fleet), Int, Int) -> IO Int
runOne mode retained total (ref, wantedLookup, wantedCells) = do
  (input, fleet) <- readIORef ref
  actual <- case mode of
    "scan" -> evaluate (sum [maybe 0 ((+ 1) . fromEnum . fst)
      (find (Set.member cell . snd) (Map.toList (fleetShips fleet))) | cell <- legalBoardCells])
    "union" -> evaluate (cellsDigest (Set.unions (Map.elems (fleetShips fleet))))
    _ -> do
      built <- evaluate (checked input)
      value <- evaluate (geometryDigest built)
      if mode == "retain" then modifyIORef' retained (built :) else pure ()
      pure value
  let wanted = if mode == "scan" then wantedLookup else wantedCells
  if actual /= wanted then ioError (userError "Fleet benchmark differs from independent geometry")
    else pure $! total + actual

checked :: FleetPlacement -> Fleet
checked = either (error . show) id . Board.placeFleet

geometryDigest :: Fleet -> Int
geometryDigest = cellsDigest . Set.unions . Map.elems . fleetShips

cellsDigest :: Set.Set Coord -> Int
cellsDigest = foldl' (\ !total cell -> total + coordColumn cell + 10 * coordRow cell) 0 . Set.toList
