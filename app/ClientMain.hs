module Main (main) where

import Battleship.Client (ClientError (..), renderProtocolError, renderResponse, runClient, runPlacementClient)
import Battleship.Protocol (parseCommand)
import Control.Exception (IOException, catches, Handler (Handler))
import qualified Data.ByteString.Char8 as BSC
import Data.Char (ord)
import Network.Socket (PortNumber)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (BufferMode (LineBuffering), hPutStrLn, hSetBuffering, hSetEncoding, stderr, stdin, stdout, utf8)
import Text.Read (readMaybe)

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hSetEncoding stdin utf8
  hSetBuffering stdout LineBuffering
  arguments <- getArgs
  case arguments of
    ["--help"] -> putStrLn usage
    [] -> play 4000
    [mode] | mode `elem` ["--play", "--place"] -> play 4000
    [mode, port] | mode `elem` ["--play", "--place"] -> case readMaybe port :: Maybe Integer of
      Just number | number >= 1 && number <= 65535 -> play (fromInteger number)
      _ -> failWith usage
    [argument] -> case readMaybe argument :: Maybe Integer of
      Just number | number >= 1 && number <= 65535 -> play (fromInteger number)
      Just _ -> failWith usage
      Nothing -> start 4000 argument
    [port, command] -> case readMaybe port :: Maybe Integer of
      Just number | number >= 1 && number <= 65535 -> start (fromInteger number) command
      _ -> failWith usage
    _ -> failWith usage

play :: PortNumber -> IO ()
play port = runPlacementClient "127.0.0.1" port stdin stdout
  `catches` [Handler reportClientError, Handler reportIOException]

start :: PortNumber -> String -> IO ()
start port commandLine
  | not (all (\character -> ord character <= 127) commandLine) = failWith "Lệnh chỉ dùng ký tự ASCII."
  | otherwise = case parseCommand (BSC.pack commandLine) of
      Left fault -> failWith (renderProtocolError fault)
      Right command -> do
        hSetBuffering stdout LineBuffering
        runClient "127.0.0.1" port command (putStrLn . renderResponse)
          `catches` [Handler reportClientError, Handler reportIOException]

reportClientError :: ClientError -> IO ()
reportClientError (ClientProtocolError fault) = failWith (renderProtocolError fault)
reportClientError (UnexpectedResponse _) = failWith "Server gửi thông điệp không đúng giai đoạn kết nối."
reportClientError UnexpectedEOF = failWith "Kết nối đã đóng trước khi nhận đủ phản hồi."
reportClientError RequestTimeout = failWith "Hết thời gian chờ server."

reportIOException :: IOException -> IO ()
reportIOException exception = failWith ("Lỗi kết nối: " ++ show exception)

usage :: String
usage = "Usage: battleship-client [PORT] | --play [PORT] | --place [PORT] | [PORT] \"COMMAND\" (default 4000; no arguments: guided placement and play)"

failWith :: String -> IO a
failWith message = hPutStrLn stderr message >> exitFailure
