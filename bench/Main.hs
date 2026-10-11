{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
module Main (main) where

import Battleship.Types (GameState, initialGameState)
import Control.Concurrent (getNumCapabilities)
import Control.Exception (evaluate)
import Control.Monad (foldM)
import Data.Bits (xor)
import Data.IORef (IORef, newIORef, readIORef)
import Data.Version (showVersion)
import Data.Word (Word64)
import Fixtures
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats
import System.CPUTime (getCPUTime)
import System.Environment (getArgs)
import System.Info (compilerName, compilerVersion)
import System.Mem (performGC)
import Text.Read (readMaybe)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["fixture", seed] | Just number <- readMaybe seed -> putStrLn (fixtureJSON (fixture number))
    [mode, repetitions] | mode `elem` ["core", "coordinator", "worker"], Just count <- readMaybe repetitions,
                          count > 0 && count <= 100000 -> benchmark mode count
    _ -> ioError (userError "Usage: battleship-benchmark fixture SEED | core|coordinator|worker REPETITIONS (+RTS -T -N1/-N2 -RTS)")

benchmark :: String -> Int -> IO ()
benchmark mode repetitions = do
  statsEnabled <- getRTSStatsEnabled
  if not statsEnabled then ioError (userError "Benchmark requires +RTS -T -RTS") else pure ()
  let workloads = map fixture seeds
  mapM_ (evaluate . forceFixture) workloads
  prepared <- mapM (\value -> do
    expectedDigest <- evaluate (digestTrace (replayPure initialGameState (entries value)))
    ref <- newIORef value
    pure (ref, expectedDigest)) workloads
  initialRef <- newIORef initialGameState
  capabilities <- getNumCapabilities
  performGC
  before <- getRTSStats
  cpuStart <- getCPUTime
  start <- getMonotonicTimeNSec
  checksum <- foldM (\ !aggregate _ -> foldM (runOne initialRef mode) aggregate prepared) 0 [1 .. repetitions]
  end <- getMonotonicTimeNSec
  cpuEnd <- getCPUTime
  -- Final GC accounts for the last nursery; outside elapsed/cpu timing.
  performGC
  after <- getRTSStats
  let games = repetitions * length workloads
      commands = repetitions * sum (map (length . entries) workloads)
  putStrLn $ object
    [ ("schemaVersion", "1"), ("mode", jsonString mode)
    , ("compiler", jsonString (compilerName ++ " " ++ showVersion compilerVersion ++ "." ++ show (__GLASGOW_HASKELL_PATCHLEVEL1__ :: Int)))
    , ("capabilities", show capabilities), ("repetitions", show repetitions)
    , ("games", show games), ("commands", show commands), ("checksum", jsonString (show checksum))
    , ("elapsedNs", show (end - start)), ("cpuSeconds", show (fromIntegral (cpuEnd - cpuStart) / 1e12 :: Double))
    , ("allocatedBytes", show (allocated_bytes after - allocated_bytes before))
    , ("gcCpuSecondsAccounting", show (fromIntegral (gc_cpu_ns after - gc_cpu_ns before) / 1e9 :: Double))
    , ("gcElapsedSecondsAccounting", show (fromIntegral (gc_elapsed_ns after - gc_elapsed_ns before) / 1e9 :: Double))
    , ("maxLiveBytesProcess", show (max_live_bytes after)), ("maxMemoryBytesProcess", show (max_mem_in_use_bytes after))
    ]

runOne :: IORef GameState -> String -> Word64 -> (IORef Fixture, Word64) -> IO Word64
runOne initialRef mode aggregate (ref, wanted) = do
  value <- readIORef ref
  initial <- readIORef initialRef
  actual <- if mode == "core" then evaluate (digestTrace (replayPure initial (entries value)))
    else (if mode == "worker" then replayWorker else replayCoordinator) (entries value) >>= evaluate . digestTrace
  if actual /= wanted then ioError (userError "Benchmark semantic checksum changed")
    else pure $! (aggregate `xor` actual) * 1099511628211
