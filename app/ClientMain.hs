module Main (main) where

import Battleship.Client (ClientError (..), renderProtocolError, renderResponse, runClient)
import Battleship.Protocol (parseCommand)
import Control.Exception (IOException, catches, Handler (Handler))
import qualified Data.ByteString.Char8 as BSC
import Data.Char (ord)
import Network.Socket (PortNumber)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (BufferMode (LineBuffering), hPutStrLn, hSetBuffering, hSetEncoding, stderr, stdout, utf8)
import Text.Read (readMaybe)

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  arguments <- getArgs
  case arguments of
    ["--help"] -> putStrLn usage
    [command] -> start 4000 command
    [port, command] -> case readMaybe port :: Maybe Integer of
      Just number | number >= 1 && number <= 65535 -> start (fromInteger number) command
      _ -> failWith usage
    _ -> failWith usage

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
usage = "Usage: battleship-client [PORT] \"COMMAND\" (default 4000; example: \"FIRE A1\")"

failWith :: String -> IO a
failWith message = hPutStrLn stderr message >> exitFailure
