module IntegrationSpec (spec) where

import Control.Monad (forM_)
import qualified Control.Concurrent.Async
import Data.List (isPrefixOf, stripPrefix)
import qualified Data.ByteString.Char8 as BSC
import Network.Socket (PortNumber, withSocketsDo)
import Network.Socket.ByteString (sendAll)
import ServerSpec (await, expectClosed, expectLine, withClient, withServer)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (hGetContents, hGetContents', hGetLine, hSetEncoding, utf8)
import System.Process
  ( CreateProcess (std_err, std_out), StdStream (CreatePipe), proc,
    readProcessWithExitCode, waitForProcess, withCreateProcess )
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldSatisfy)
import Text.Read (readMaybe)

spec :: Spec
spec = do
  describe "C-01 executable smoke tests" $ do
    it "server --help starts and exits successfully" $
      checkExecutable "battleship-server" ["--help"]
        "Usage: battleship-server [PORT] (default 4000; 0 selects a free port)"
    it "client --help starts and exits successfully" $
      checkExecutable "battleship-client" ["--help"]
        "Usage: battleship-client [PORT] \"COMMAND\" (default 4000; example: \"FIRE A1\")"

  describe "D-02 client executable" $ do
    forM_ [[], ["0", "QUIT"], ["65536", "QUIT"], ["abc", "QUIT"],
           ["4000", "QUIT", "EXTRA"], ["4000", "FIRE"], ["4000", "FIRE K1"],
           ["4000", "BẮN A1"]] $ \arguments ->
      it ("rejects bad arguments/command before connecting: " ++ show arguments) $ do
        (code, output, errors) <- await "invalid client arguments"
          (readClientProcess arguments)
        code `shouldBe` ExitFailure 1
        output `shouldBe` ""
        errors `shouldSatisfy` (not . null)

    forM_ [("QUIT", ["Bạn là Người chơi 1.", "Người chơi 2 thắng: đối thủ đã rời trận."]),
           ("FIRE A1", ["Bạn là Người chơi 1.", "Lỗi: lệnh không hợp lệ."])] $ \(command, expected) ->
      it ("client executable talks to C-02 with " ++ command) $
        withServer $ \port server -> do
          (code, output, errors) <- await "client executable request"
            (readClientProcess [show port, command])
          (code, lines output, errors) `shouldBe` (ExitSuccess, expected, "")
          -- Client closes after its one response, ending the C-02 session.
          await "server exit after client executable" (Control.Concurrent.Async.wait server)

  describe "C-02 server executable" $ do
    forM_ [["-1"], ["65536"], ["abc"], ["4000", "4001"]] $ \arguments ->
      it ("rejects invalid port arguments " ++ show arguments) $ do
        (code, output, errors) <- await "invalid CLI arguments"
          (readProcessWithExitCode "battleship-server" arguments "")
        code `shouldBe` ExitFailure 1
        output `shouldBe` ""
        errors `shouldSatisfy` isPrefixOf "Usage: battleship-server"

    it "reports an occupied port and exits with failure" $
      withServer $ \port _ -> do
        (code, output, errors) <- await "occupied port"
          (readProcessWithExitCode "battleship-server" [show port] "")
        code `shouldBe` ExitFailure 1
        output `shouldBe` ""
        errors `shouldSatisfy` isPrefixOf "Battleship server: "

    it "runs the built executable with two clients, rejects the third and exits after QUIT" $
      withSocketsDo $ withCreateProcess
        (proc "battleship-server" ["0"]) { std_out = CreatePipe, std_err = CreatePipe } $
        \_ output errors process -> case (output, errors) of
          (Just stdoutHandle, Just stderrHandle) -> do
            announcement <- await "executable startup" (hGetLine stdoutHandle)
            port <- case stripPrefix "Battleship server listening on 127.0.0.1:" announcement
                         >>= readMaybe :: Maybe PortNumber of
              Just actual | actual > 0 -> pure actual
              _ -> ioError (userError "C-02 invalid startup announcement")
            withClient port $ \first -> do
              expectLine first "WELCOME 1 P1"
              withClient port $ \second -> do
                expectLine second "WELCOME 1 P2"
                withClient port $ \third -> do
                  expectLine third "ERROR SERVER_FULL"
                  expectClosed third
                sendAll first (BSC.pack "QUIT\n")
                forM_ [first, second] $ \connection -> do
                  expectLine connection "GAME_OVER P2 OPPONENT_LEFT"
                  expectClosed connection
            await "executable exit" (waitForProcess process) >>= (`shouldBe` ExitSuccess)
            hGetContents stderrHandle >>= (`shouldBe` "")
          _ -> ioError (userError "C-02 missing process pipes")

checkExecutable :: FilePath -> [String] -> String -> Expectation
checkExecutable executable arguments expectedMessage = do
  (exitCode, stdoutText, stderrText) <- await "executable smoke test"
    (readProcessWithExitCode executable arguments "")
  exitCode `shouldBe` ExitSuccess
  lines stdoutText `shouldBe` [expectedMessage]
  stderrText `shouldBe` ""

-- The client emits UTF-8 Vietnamese regardless of the Windows locale.
readClientProcess :: [String] -> IO (ExitCode, String, String)
readClientProcess arguments = withCreateProcess
  (proc "battleship-client" arguments) { std_out = CreatePipe, std_err = CreatePipe } $
  \_ output errors process -> case (output, errors) of
    (Just stdoutHandle, Just stderrHandle) -> do
      hSetEncoding stdoutHandle utf8
      hSetEncoding stderrHandle utf8
      (stdoutText, stderrText) <- Control.Concurrent.Async.concurrently
        (hGetContents' stdoutHandle) (hGetContents' stderrHandle)
      exitCode <- waitForProcess process
      pure (exitCode, stdoutText, stderrText)
    _ -> ioError (userError "D-02 missing client process pipes")
