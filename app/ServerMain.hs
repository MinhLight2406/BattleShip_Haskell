module Main (main) where

import Battleship.Server (runServer)
import Control.Exception (IOException, catch)
import Network.Socket (PortNumber)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (BufferMode (LineBuffering), hPutStrLn, hSetBuffering, stderr, stdout)
import Text.Read (readMaybe)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--help"] -> putStrLn usage
    [] -> start 4000
    [argument] -> case readMaybe argument :: Maybe Integer of
      Just port | port >= 0 && port <= 65535 -> start (fromInteger port)
      _ -> failWith usage
    _ -> failWith usage

start :: PortNumber -> IO ()
start port = do
  hSetBuffering stdout LineBuffering
  runServer port (\actual -> putStrLn ("Battleship server listening on 127.0.0.1:" ++ show actual))
    `catch` reportIOException
  where
    reportIOException :: IOException -> IO ()
    reportIOException exception = failWith ("Battleship server: " ++ show exception)

usage :: String
usage = "Usage: battleship-server [PORT] (default 4000; 0 selects a free port)"

failWith :: String -> IO a
failWith message = hPutStrLn stderr message >> exitFailure
