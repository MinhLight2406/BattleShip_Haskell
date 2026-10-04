module IntegrationSpec (spec) where

import Control.Monad (forM_)
import qualified Control.Concurrent.Async
import Data.List (isInfixOf, isPrefixOf, stripPrefix)
import qualified Data.ByteString.Char8 as BSC
import Network.Socket (PortNumber, withSocketsDo)
import Network.Socket.ByteString (sendAll)
import ServerSpec (await, expectClosed, expectLine, withClient, withServer)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (hClose, hGetContents, hGetContents', hGetLine, hPutStr, hSetEncoding, utf8)
import System.Process
  ( CreateProcess (std_err, std_in, std_out), StdStream (CreatePipe), proc,
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
        "Usage: battleship-client --place [PORT] | [PORT] \"COMMAND\" (default 4000; no arguments: guided placement)"

  describe "D-02 client executable" $ do
    forM_ [["0", "QUIT"], ["65536", "QUIT"], ["abc", "QUIT"],
           ["4000", "QUIT", "EXTRA"], ["4000", "FIRE"], ["4000", "FIRE K1"],
           ["4000", "BẮN A1"]] $ \arguments ->
      it ("rejects bad arguments/command before connecting: " ++ show arguments) $ do
        (code, output, errors) <- await "invalid client arguments"
          (readClientProcess arguments)
        code `shouldBe` ExitFailure 1
        output `shouldBe` ""
        errors `shouldSatisfy` (not . null)

    forM_ [("QUIT", ["Bạn là Người chơi 1.", "Người chơi 2 thắng: đối thủ đã rời trận."]),
           ("FIRE A1", ["Bạn là Người chơi 1.", "Lỗi: hai đội tàu chưa sẵn sàng."])] $ \(command, expected) ->
      it ("client executable talks to the integrated server with " ++ command) $
        withServer $ \port server -> do
          (code, output, errors) <- await "client executable request"
            (readClientProcess [show port, command])
          (code, lines output, errors) `shouldBe` (ExitSuccess, expected, "")
          -- Client closes after its one response, ending the C-02 session.
          await "server exit after client executable" (Control.Concurrent.Async.wait server)

  describe "D-03 placement executable" $ do
    it "guides placement by default and cancels before connecting" $ do
      (code, output, errors) <- await "default guided CLI" (readClientProcessWithInput [] "HUY\n")
      (code, errors) `shouldBe` (ExitSuccess, "")
      forM_ ["A1..J10", "CV=5, BB=4, CR=3, SB=3, DD=2", "Đã hủy đặt tàu"] $ \message ->
        output `shouldSatisfy` isInfixOf message
    it "does not send a complete draft at EOF without GUI" $ do
      (code, output, errors) <- await "unconfirmed draft EOF"
        (readClientProcessWithInput ["--place", "1"] "A1 H\nA2 H\nA3 H\nA4 H\nA5 H\n")
      (code, errors) `shouldBe` (ExitSuccess, "")
      output `shouldSatisfy` isInfixOf "Bàn của bạn"
      output `shouldSatisfy` isInfixOf "Đã hủy đặt tàu"
    forM_ [["--place", "0"], ["--place", "65536"], ["--place", "abc"],
           ["--place", "4000", "extra"]] $ \arguments ->
      it ("rejects bad guided CLI arguments " ++ show arguments) $ do
        (code, output, errors) <- await "invalid placement CLI" (readClientProcess arguments)
        (code, output) `shouldBe` (ExitFailure 1, "")
        errors `shouldSatisfy` isPrefixOf "Usage: battleship-client"
    it "lets a novice repair/edit the draft, place as P2, receive a shot and keep the session alive" $
      withServer $ \port server -> withClient port $ \first -> do
        expectLine first "WELCOME 1 P1"
        sendAll first (BSC.pack "PLACE CV=A6:H;BB=A7:H;CR=A8:H;SB=A9:H;DD=A10:H\n")
        expectLine first "OK PLACE"
        expectLine first "WAITING OPPONENT"
        Control.Concurrent.Async.withAsync
          (readClientProcessWithInput ["--place", show port]
            "J10 H\nA1 H\nA1 H\nA2 H\nA3 H\nA4 H\nA5 H\nSUA CV\nA6 V\nGUI\n") $ \client -> do
            expectLine first "START P1"
            expectLine first "TURN P1"
            sendAll first (BSC.pack "FIRE A6\n")
            expectLine first "SHOT A6 HIT"
            expectLine first "TURN P1"
            sendAll first (BSC.pack "QUIT\n")
            expectLine first "GAME_OVER P2 OPPONENT_LEFT"
            (code, output, errors) <- await "guided client exit" (Control.Concurrent.Async.wait client)
            (code, errors) `shouldBe` (ExitSuccess, "")
            forM_ ["vượt mép bàn", "chồng lên nhau tại A1", "Bàn của bạn", "Bạn là Người chơi 2.",
                   "Đã nhận đội tàu.", "Đối thủ bắn A6: trúng.", "Người chơi 2 thắng"] $ \message ->
              output `shouldSatisfy` isInfixOf message
        await "guided session server exit" (Control.Concurrent.Async.wait server)

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

    it "runs the executable with two clients, rejects a third, calls Rules for PLACE/FIRE and exits after QUIT" $
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
                sendAll first (BSC.pack "PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H\n")
                expectLine first "OK PLACE"
                expectLine first "WAITING OPPONENT"
                sendAll second (BSC.pack "PLACE CV=A6:H;BB=A7:H;CR=A8:H;SB=A9:H;DD=A10:H\n")
                expectLine second "OK PLACE"
                forM_ [first, second] $ \connection -> do
                  expectLine connection "START P1"
                  expectLine connection "TURN P1"
                sendAll first (BSC.pack "FIRE A6\n")
                expectLine first "SHOT A6 HIT"
                expectLine second "INCOMING A6 HIT"
                forM_ [first, second] $ \connection -> expectLine connection "TURN P1"
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
readClientProcess arguments = readClientProcessWithInput arguments ""

readClientProcessWithInput :: [String] -> String -> IO (ExitCode, String, String)
readClientProcessWithInput arguments script = withCreateProcess
  (proc "battleship-client" arguments) { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe } $
  \input output errors process -> case (input, output, errors) of
    (Just stdinHandle, Just stdoutHandle, Just stderrHandle) -> do
      hSetEncoding stdinHandle utf8
      hPutStr stdinHandle script
      hClose stdinHandle
      hSetEncoding stdoutHandle utf8
      hSetEncoding stderrHandle utf8
      (stdoutText, stderrText) <- Control.Concurrent.Async.concurrently
        (hGetContents' stdoutHandle) (hGetContents' stderrHandle)
      exitCode <- waitForProcess process
      pure (exitCode, stdoutText, stderrText)
    _ -> ioError (userError "D-02 missing client process pipes")
