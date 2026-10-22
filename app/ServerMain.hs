{-# LANGUAGE CPP #-}
module Main (main) where

import Battleship.Server (GameRuntimeConfig, ServerConfig, gameCapability, parseGameRuntimeConfig, parseServerConfig, runRoomServerWithRuntime, runServerWithRuntime, serverBindHost)
import qualified Battleship.Rules as Rules
import Battleship.Types (GameState, Step, initialGameState)
import Control.Concurrent (getNumCapabilities)
import Control.Exception (IOException, catch)
import Network.Socket (PortNumber)
import System.Environment (getArgs, getEnvironment)
import Data.Char (toUpper)
import System.Exit (exitFailure)
import System.IO (BufferMode (LineBuffering), hPutStrLn, hSetBuffering, stderr, stdout)
import Text.Read (readMaybe)
#ifndef mingw32_HOST_OS
import Control.Concurrent (myThreadId, throwTo)
import Control.Exception (bracket)
import Control.Monad (void)
import System.Exit (ExitCode (ExitSuccess))
import System.Posix.Signals (Handler (CatchOnce), installHandler, sigTERM)
#endif

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--help"] -> putStrLn usage
    [] -> start 4000
    ["--rooms", argument] -> case readMaybe argument :: Maybe Integer of
      Just port | port >= 0 && port <= 65535 -> startRooms (fromInteger port)
      _ -> failWith usage
    [argument] -> case readMaybe argument :: Maybe Integer of
      Just port | port >= 0 && port <= 65535 -> start (fromInteger port)
      _ -> failWith usage
    _ -> failWith usage

start :: PortNumber -> IO ()
start = startUsing runServerWithRuntime

startRooms :: PortNumber -> IO ()
startRooms = startUsing runRoomServerWithRuntime

startUsing :: (GameRuntimeConfig -> ServerConfig -> Step -> GameState -> PortNumber -> (PortNumber -> IO ()) -> IO ()) -> PortNumber -> IO ()
startUsing runSelectedServer port = do
  hSetBuffering stdout LineBuffering
  -- Enumeration preserves explicitly empty values on Windows too.
  environment <- getEnvironment
  let setting name = lookup name [(map toUpper key, value) | (key, value) <- environment]
  config <- either failWith pure (parseServerConfig (setting "BATTLESHIP_BIND_HOST") (setting "BATTLESHIP_READY_FILE"))
  capabilities <- getNumCapabilities
  runtime <- either failWith pure (parseGameRuntimeConfig capabilities (setting "BATTLESHIP_GAME_CAPABILITY"))
  withTermination $ runSelectedServer runtime config Rules.step initialGameState port
    (\actual -> do
      putStrLn ("Battleship server listening on " ++ serverBindHost config ++ ":" ++ show actual)
      putStrLn ("Battleship runtime capabilities: " ++ show capabilities)
      putStrLn ("Battleship game worker capability: " ++ show (gameCapability runtime)))
    `catch` reportIOException
  where
    reportIOException :: IOException -> IO ()
    reportIOException exception = failWith ("Battleship server: " ++ show exception)

-- Docker sends SIGTERM to PID 1. Raise it on the owner thread so brackets run.
withTermination :: IO () -> IO ()
#ifdef mingw32_HOST_OS
withTermination = id
#else
withTermination action = do
  owner <- myThreadId
  bracket (installHandler sigTERM (CatchOnce (throwTo owner ExitSuccess)) Nothing)
    (\previous -> void (installHandler sigTERM previous Nothing)) (const action)
#endif

usage :: String
usage = "Usage: battleship-server [PORT] | --rooms [PORT] (default PORT 4000; 0 selects a free port)"

failWith :: String -> IO a
failWith message = hPutStrLn stderr message >> exitFailure
