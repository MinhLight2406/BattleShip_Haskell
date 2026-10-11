{-# LANGUAGE CPP #-}
module IntegrationSpec (spec) where

import Control.Monad (forM_, forever, when)
import Control.Concurrent (threadDelay)
import qualified Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception (IOException, catch, finally, throwIO)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Char (toUpper)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, stripPrefix, tails)
import qualified Data.ByteString.Char8 as BSC
import Network.Socket (PortNumber, withSocketsDo)
import Network.Socket.ByteString (sendAll)
import ServerSpec (await, expectClosed, expectLine, withClient, withServer, withReadyFile)
import System.Directory (doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (Handle, hClose, hFlush, hGetChar, hGetContents, hGetContents', hGetLine, hPutStr, hPutStrLn, hSetEncoding, utf8)
import System.IO.Error (isEOFError)
import System.Process
  ( CreateProcess (env, std_err, std_in, std_out), ProcessHandle, StdStream (CreatePipe), proc,
    getProcessExitCode, readProcessWithExitCode, terminateProcess, waitForProcess, withCreateProcess )
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldSatisfy)
import Text.Read (readMaybe)

spec :: Spec
spec = do
  dk02ExecutableSpec
  describe "NM-05 executable capability configuration" $
    it "rejects a capability outside -N before listening or touching readiness" $ withReadyFile $ \marker -> do
      writeFile marker "untouched"
      inherited <- serverEnvironment Nothing (Just marker)
      let environment = ("BATTLESHIP_GAME_CAPABILITY", "1") : inherited
      (code, output, errors) <- readServerProcess environment ["0", "+RTS", "-N1", "-RTS"]
      (code, output) `shouldBe` (ExitFailure 1, "")
      errors `shouldSatisfy` isPrefixOf "BATTLESHIP_GAME_CAPABILITY"
      BSC.readFile marker >>= (`shouldBe` BSC.pack "untouched")
  describe "C-01 executable smoke tests" $ do
    it "server --help starts and exits successfully" $
      checkExecutable "battleship-server" ["--help"]
        "Usage: battleship-server [PORT] (default 4000; 0 selects a free port)"
    it "client --help starts and exits successfully" $
      checkExecutable "battleship-client" ["--help"]
        "Usage: battleship-client [PORT] | --play [PORT] | --place [PORT] | [PORT] \"COMMAND\" (default 4000; no arguments: guided placement and play)"

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

  describe "D-04 interactive executable" $ do
    it "plays through a miss, opponent turn, hit, repeated input, all sunk ships and victory against real Rules" $
      withServer $ \port server -> withClient port $ \first -> do
        expectLine first "WELCOME 1 P1"
        sendAll first (BSC.pack "PLACE CV=A6:H;BB=A7:H;CR=A8:H;SB=A9:H;DD=A10:H\n")
        expectLine first "OK PLACE"
        expectLine first "WAITING OPPONENT"
        let shots = [("A6", "HIT"), ("B6", "HIT"), ("C6", "HIT"), ("D6", "HIT"), ("E6", "SUNK CV"),
                     ("A7", "HIT"), ("B7", "HIT"), ("C7", "HIT"), ("D7", "SUNK BB"),
                     ("A8", "HIT"), ("B8", "HIT"), ("C8", "SUNK CR"),
                     ("A9", "HIT"), ("B9", "HIT"), ("C9", "SUNK SB"), ("A10", "HIT"), ("B10", "WIN")]
            script = "A1 H\nA2 H\nA3 H\nA4 H\nA5 H\nGUI\nK1\nJ10\nA6\nA6\n" ++
              unlines (map (("fire " ++) . fst) (drop 1 shots))
        Control.Concurrent.Async.withAsync
          (readClientProcessWithInput ["--place", show port] script) $ \client -> do
            expectLine first "START P1"
            expectLine first "TURN P1"
            sendAll first (BSC.pack "FIRE J10\n")
            expectLine first "SHOT J10 MISS"
            expectLine first "TURN P2"
            expectLine first "INCOMING J10 MISS"
            expectLine first "TURN P1"
            sendAll first (BSC.pack "FIRE I10\n")
            expectLine first "SHOT I10 MISS"
            expectLine first "TURN P2"
            forM_ shots $ \(coordinate, outcome) -> do
              expectLine first ("INCOMING " ++ coordinate ++ " " ++ outcome)
              if outcome == "WIN" then pure () else expectLine first "TURN P2"
            expectLine first "GAME_OVER P2 ALL_SHIPS_SUNK"
            expectClosed first
            (code, output, errors) <- await "D-04 full game CLI" (Control.Concurrent.Async.wait client)
            (code, errors) `shouldBe` (ExitSuccess, "")
            forM_ ["Tọa độ phải nằm", "đã bắn A6", "Đến lượt bạn bắn", "chưa được bắn",
                   "Bạn bắn J10: trượt", "Bạn bắn A6: trúng", "Đối thủ bắn J10: trượt",
                   "chìm tàu sân bay", "chìm thiết giáp hạm", "chìm tàu tuần dương", "chìm tàu ngầm",
                   "Bạn bắn B10: thắng", "Bạn thắng!"] $ \message ->
              output `shouldSatisfy` isInfixOf message
        await "D-04 full game server exit" (Control.Concurrent.Async.wait server)

    forM_ ["", "A"] $ \partial ->
      it ("receives GAME_OVER with stdin still open and incomplete input " ++ show partial) $
        withServer $ \port server -> withClient port $ \first -> do
          expectLine first "WELCOME 1 P1"
          sendAll first (BSC.pack "PLACE CV=A6:H;BB=A7:H;CR=A8:H;SB=A9:H;DD=A10:H\n")
          expectLine first "OK PLACE"
          expectLine first "WAITING OPPONENT"
          withCreateProcess
            (proc "battleship-client" ["--place", show port])
              { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe } $
            \input output errors process -> case (input, output, errors) of
              (Just stdinHandle, Just stdoutHandle, Just stderrHandle) -> do
                forM_ [stdinHandle, stdoutHandle, stderrHandle] (`hSetEncoding` utf8)
                hPutStr stdinHandle "A1 H\nA2 H\nA3 H\nA4 H\nA5 H\nGUI\n"
                hFlush stdinHandle
                expectLine first "START P1"
                expectLine first "TURN P1"
                sendAll first (BSC.pack "FIRE J10\n")
                expectLine first "SHOT J10 MISS"
                expectLine first "TURN P2"
                let readUntilPrompt = do
                      line <- hGetLine stdoutHandle
                      if "Nhập A1..J10 hoặc FIRE A1; QUIT để rời trận:" `isInfixOf` line
                        then pure () else readUntilPrompt
                await "D-04 own input prompt" readUntilPrompt
                hPutStr stdinHandle partial
                hFlush stdinHandle
                -- Keep stdin open: an hGetLine-based client would hang here.
                threadDelay 150000
                sendAll first (BSC.pack "QUIT\n")
                expectLine first "GAME_OVER P2 OPPONENT_LEFT"
                await "D-04 exit while entering input" (waitForProcess process) >>= (`shouldBe` ExitSuccess)
                transcript <- hGetContents' stdoutHandle
                transcript `shouldSatisfy` isInfixOf "Bạn thắng!"
                hGetContents' stderrHandle >>= (`shouldBe` "")
              _ -> ioError (userError "D-04 missing process pipes")
          await "D-04 interrupted input server exit" (Control.Concurrent.Async.wait server)

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

  describe "D-05 two interactive executables" $ do
    forM_ [["--play", "0"], ["--play", "65536"], ["--play", "abc"], ["0"], ["65536"]] $ \arguments ->
      it ("rejects invalid friendly port arguments " ++ show arguments) $ do
        (code, output, errors) <- readClientProcess arguments
        (code, output) `shouldBe` (ExitFailure 1, "")
        errors `shouldSatisfy` isPrefixOf "Usage: battleship-client"

    it "plays placement, repair, miss, hit, sunk and win with coordinates only; both clients show private boards" $
      withServer $ \port server -> do
        let attacks = ["A6", "B6", "C6", "D6", "E6", "A7", "B7", "C7", "D7",
                       "A8", "B8", "C8", "A9", "B9", "C9", "A10", "B10"]
            script1 = "J10 H\nA1 H\nA2 H\nA3 H\nA4 H\nA5 H\nGUI\nK1\nJ10\nA6\nA6\n" ++ unlines (drop 1 attacks)
            script2 = "A6 H\nA7 H\nA8 H\nA9 H\nA10 H\nGUI\nJ10\n"
        withCreateProcess (proc "battleship-client" [show port])
          { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe } $
          \input output errors process -> case (input, output, errors) of
            (Just stdinHandle, Just stdoutHandle, Just stderrHandle) -> do
              forM_ [stdinHandle, stdoutHandle, stderrHandle] (`hSetEncoding` utf8)
              hPutStr stdinHandle script1
              hClose stdinHandle
              let welcome = do
                    line <- hGetLine stdoutHandle
                    if "Bạn là Người chơi 1." `isInfixOf` line then pure (line ++ "\n")
                    else ((line ++ "\n") ++) <$> welcome
              prefix <- await "D-05 first client admitted before launching second" welcome
              -- Drain output throughout the game: board redraws must not fill
              -- either process pipe and make this test hang artificially.
              Control.Concurrent.Async.withAsync (do
                (remaining, errors1) <- Control.Concurrent.Async.concurrently
                  (hGetContents' stdoutHandle) (hGetContents' stderrHandle)
                code1 <- waitForProcess process
                pure (code1, prefix ++ remaining, errors1)) $ \first -> do
                  (code2, output2, errors2) <- await "D-05 second client full game"
                    (readClientProcessWithInput ["--play", show port] script2)
                  (code1, output1, errors1) <- await "D-05 first client full game" (Control.Concurrent.Async.wait first)
                  (code1, code2, errors1, errors2) `shouldBe` (ExitSuccess, ExitSuccess, "", "")
                  forM_ [output1, output2] $ \transcript -> do
                    transcript `shouldSatisfy` isInfixOf "Mục tiêu đối thủ:"
                    transcript `shouldSatisfy` isInfixOf "? = chưa bắn đối thủ"
                    transcript `shouldSatisfy` isInfixOf "Đối thủ bắn J10: trượt"
                  forM_ ["vượt mép bàn", "Tọa độ phải nằm", "đã bắn A6", "Bạn thắng!"] $ \message ->
                    output1 `shouldSatisfy` isInfixOf message
                  output2 `shouldSatisfy` isInfixOf "Bạn thua."
                  rows1 <- finalBoardRows output1
                  rows2 <- finalBoardRows output2
                  map (drop 36) (drop 5 rows1) `shouldBe`
                    [" 6  X  X  X  X  #  ?  ?  ?  ?  ?", " 7  X  X  X  #  ?  ?  ?  ?  ?  ?",
                     " 8  X  X  #  ?  ?  ?  ?  ?  ?  ?", " 9  X  X  #  ?  ?  ?  ?  ?  ?  ?",
                     "10  X  *  ?  ?  ?  ?  ?  ?  ?  o"]
                  take 1 (map (drop 36) rows2) `shouldBe` [" 1  ?  ?  ?  ?  ?  ?  ?  ?  ?  ?"]
                  take 1 (map (take 32) (drop 5 rows2)) `shouldBe` [" 6  X  X  X  X  #  .  .  .  .  ."]
            _ -> ioError (userError "D-05 missing client process pipes")
        await "D-05 both clients and server exit" (Control.Concurrent.Async.wait server)

  d06Spec

d06Spec :: Spec
d06Spec = describe "D-06 three production executables driven by output" $ do
  it "repairs errors, changes turns and lets P2 win a new mixed fleet game without an input script" $
    withServerExecutable $ \port server ->
      withLiveClient [show port] $ \first -> do
        enterFleet first ["C2 V", "F7 H", "J8 V", "A1 H", "H3 V"] True
        cliAwait first "Bạn là Người chơi 1."
        cliAwait first "Đã nhận đội tàu."
        withLiveClient ["--play", show port] $ \second -> do
          enterFleet second ["F1 H", "A6 V", "C10 H", "F4 V", "J9 V"] False
          cliAwait second "Bạn là Người chơi 2."
          cliAwait first firePrompt
          typeLine first "K1"
          cliAwait first "Tọa độ phải nằm"
          fire first second "F1" "trúng."
          fire first second "J6" "trượt."
          cliAwait second firePrompt
          typeLine second "A01"
          cliAwait second "Tọa độ phải nằm"
          fire second first "C2" "trúng."
          cliAwait second firePrompt
          typeLine second "C2"
          cliAwait second "đã bắn C2"
          fire second first "I10" "trượt."
          fire first second "I6" "trượt."
          forM_ [("C3", "trúng."), ("C4", "trúng."), ("C5", "trúng."), ("C6", "chìm tàu sân bay."),
                 ("F7", "trúng."), ("G7", "trúng."), ("H7", "trúng."), ("I7", "chìm thiết giáp hạm."),
                 ("J8", "trúng."), ("J9", "trúng."), ("J10", "chìm tàu tuần dương."),
                 ("A1", "trúng."), ("B1", "trúng."), ("C1", "chìm tàu ngầm."),
                 ("H3", "trúng."), ("H4", "thắng.")] $ \(position, outcome) ->
            fire second first position outcome
          (code1, output1, errors1) <- cliFinish first
          (code2, output2, errors2) <- cliFinish second
          (code1, code2, errors1, errors2) `shouldBe` (ExitSuccess, ExitSuccess, "", "")
          output1 `shouldSatisfy` isInfixOf "Bạn thua."
          output2 `shouldSatisfy` isInfixOf "Bạn thắng!"
          rows1 <- finalBoardRows output1
          rows2 <- finalBoardRows output2
          let target1 = map (drop 36) rows1
              target2 = map (drop 36) rows2
          length (filter (== '?') (concat target1)) `shouldBe` 97
          length (filter (== '?') (concat target2)) `shouldBe` 82
          take 1 target1 `shouldBe` [" 1  ?  ?  ?  ?  ?  X  ?  ?  ?  ?"]
          target1 !! 5 `shouldBe` " 6  ?  ?  ?  ?  ?  ?  ?  ?  o  o"
          target2 !! 3 `shouldBe` " 4  ?  ?  X  ?  ?  ?  ?  *  ?  ?"
          forM_ ["CV", "BB", "CR", "SB", "DD"] $ \ship ->
            forM_ [target1, target2] $ \rows -> (ship `isInfixOf` concat rows) `shouldBe` False
        await "D-06 server exits after P2 victory" (waitForProcess server) >>= (`shouldBe` ExitSuccess)

  it "stops the server when the first real client closes while waiting for the second" $
    withServerExecutable $ \port server -> withLiveClient [show port] $ \first -> do
      enterFleet first ["C2 V", "F7 H", "J8 V", "A1 H", "H3 V"] False
      cliAwait first "Đang chờ đối thủ."
      terminateProcess (cliProcess first)
      (code, _, _) <- cliFinish first
      code `shouldSatisfy` (/= ExitSuccess)
      await "D-06 no blocked accept after client closes" (waitForProcess server) >>= (`shouldBe` ExitSuccess)

  forM_ [True, False] $ \firstLeaves ->
    it ((if firstLeaves then "P1" else "P2") ++ " closes midgame; the other interactive process sees victory and exits") $
      withServerExecutable $ \port server -> withLiveClient [show port] $ \first -> do
        enterFleet first ["C2 V", "F7 H", "J8 V", "A1 H", "H3 V"] False
        cliAwait first "Bạn là Người chơi 1."
        withLiveClient ["--play", show port] $ \second -> do
          enterFleet second ["F1 H", "A6 V", "C10 H", "F4 V", "J9 V"] False
          fire first second "F1" "trúng."
          cliAwait first firePrompt
          -- Leave both input pipes open, including a partially typed own-turn
          -- command. GAME_OVER must interrupt input rather than wait for Enter.
          hPutStr (cliInput first) "J"
          hFlush (cliInput first)
          let (leaver, survivor) = if firstLeaves then (first, second) else (second, first)
          terminateProcess (cliProcess leaver)
          (leaverCode, _, _) <- cliFinish leaver
          leaverCode `shouldSatisfy` (/= ExitSuccess)
          (survivorCode, output, errors) <- cliFinish survivor
          (survivorCode, errors) `shouldBe` (ExitSuccess, "")
          output `shouldSatisfy` isInfixOf "đối thủ đã rời trận."
          output `shouldSatisfy` isInfixOf "Bạn thắng!"
          await "D-06 server exits after process disconnect" (waitForProcess server) >>= (`shouldBe` ExitSuccess)

firePrompt :: String
firePrompt = "Nhập A1..J10 hoặc FIRE A1; QUIT để rời trận:"

dk02ExecutableSpec :: Spec
dk02ExecutableSpec = describe "DK-02 server executable configuration" $ do
  forM_ [Nothing, Just "localhost", Just "127.0.0.1", Just "0.0.0.0"] $ \host ->
    it ("uses bind env " ++ show host ++ " with readiness and unchanged TCP protocol") $ withReadyFile $ \marker -> do
      withServerExecutableConfig host (Just marker) $ \port server -> do
        BSC.readFile marker >>= (`shouldBe` BSC.pack "ready\n")
        withClient port $ \first -> do
          expectLine first "WELCOME 1 P1"
          withClient port $ \second -> do
            expectLine second "WELCOME 1 P2"
            withClient port $ \third -> expectLine third "ERROR SERVER_FULL" >> expectClosed third
            sendAll first (BSC.pack "FIRE A1\n")
            expectLine first "ERROR FLEETS_NOT_READY"
            sendAll second (BSC.pack "QUIT\n")
            forM_ [first, second] $ \connection -> do
              expectLine connection "GAME_OVER P1 OPPONENT_LEFT"
              expectClosed connection
        await "DK-02 configured executable exit" (waitForProcess server) >>= (`shouldBe` ExitSuccess)
      doesFileExist marker >>= (`shouldBe` False)

  forM_ ["", "256.1.1.1", "127.0.0", "127.00.0.1", " 127.0.0.1", "127.0.0.1:4000",
         "http://127.0.0.1:4000", "::1", "haskell"] $ \host ->
    it ("rejects bad env before bind or readiness IO: " ++ show host) $ withReadyFile $ \marker ->
      withServer $ \occupiedPort _ -> do
        -- If validation ran after bind, this would report the occupied port.
        writeFile marker "untouched"
        environment <- serverEnvironment (Just host) (Just marker)
        (code, output, errors) <- readServerProcess environment [show occupiedPort]
        (code, output) `shouldBe` (ExitFailure 1, "")
        errors `shouldSatisfy` isPrefixOf "BATTLESHIP_BIND_HOST"
        BSC.readFile marker >>= (`shouldBe` BSC.pack "untouched")

  forM_ ["", "relative-ready"] $ \path ->
    it ("rejects invalid readiness env before listen: " ++ show path) $ do
      environment <- serverEnvironment Nothing (Just path)
      (code, output, errors) <- readServerProcess environment ["0"]
      (code, output) `shouldBe` (ExitFailure 1, "")
      errors `shouldSatisfy` isPrefixOf "BATTLESHIP_READY_FILE"

  it "reports the configured endpoint on bind failure and clears an old marker" $ withReadyFile $ \marker ->
    withServer $ \port _ -> do
      writeFile marker "stale"
      environment <- serverEnvironment (Just "0.0.0.0") (Just marker)
      (code, output, errors) <- readServerProcess environment [show port]
      (code, output) `shouldBe` (ExitFailure 1, "")
      errors `shouldSatisfy` isInfixOf ("Cannot listen on 0.0.0.0:" ++ show port)
      doesFileExist marker >>= (`shouldBe` False)

#ifndef mingw32_HOST_OS
  it "handles SIGTERM by removing readiness and closing both clients before exit" $ withReadyFile $ \marker ->
    withServerExecutableConfig (Just "0.0.0.0") (Just marker) $ \port server ->
      withClient port $ \first -> do
        expectLine first "WELCOME 1 P1"
        withClient port $ \second -> do
          expectLine second "WELCOME 1 P2"
          terminateProcess server
          await "DK-02 SIGTERM clean exit" (waitForProcess server) >>= (`shouldBe` ExitSuccess)
          doesFileExist marker >>= (`shouldBe` False)
          mapM_ expectClosed [first, second]
#endif

-- Each line is sent only after the corresponding observed prompt/response.
-- In particular, placement prompts have no LF, so read characters, not lines.
data LiveCLI = LiveCLI
  { cliInput :: Handle
  , cliProcess :: ProcessHandle
  , cliAwait :: String -> IO ()
  , cliFinish :: IO (ExitCode, String, String)
  }

withLiveClient :: [String] -> (LiveCLI -> IO a) -> IO a
withLiveClient arguments action = withCreateProcess
  (proc "battleship-client" arguments) { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe } $
  \input output errors process -> case (input, output, errors) of
    (Just stdinHandle, Just stdoutHandle, Just stderrHandle) -> do
      forM_ [stdinHandle, stdoutHandle, stderrHandle] (`hSetEncoding` utf8)
      messages <- newTQueueIO
      recorded <- newIORef []
      let collect = (forever $ do
            character <- hGetChar stdoutHandle
            modifyIORef' recorded (character :)
            atomically (writeTQueue messages (Just character)))
              `catch` (\exception -> if isEOFError exception then pure () else throwIO (exception :: IOException))
              `finally` atomically (writeTQueue messages Nothing)
          observe message = await "D-06 expected client output" (loop "")
            where
              loop previous = do
                next <- atomically (readTQueue messages)
                case next of
                  Nothing -> ioError (userError ("D-06 EOF before expected output: " ++ show message))
                  Just character -> do
                    let suffix = previous ++ [character]
                    if message `isSuffixOf` suffix then pure ()
                    else loop (drop (max 0 (length suffix - length message)) suffix)
      Control.Concurrent.Async.withAsync collect $ \reader ->
        Control.Concurrent.Async.withAsync (hGetContents' stderrHandle) $ \errorReader -> do
          let finish = do
                code <- await "D-06 client process exit" (waitForProcess process)
                await "D-06 stdout drained" (Control.Concurrent.Async.wait reader)
                transcript <- reverse <$> readIORef recorded
                diagnostic <- await "D-06 stderr drained" (Control.Concurrent.Async.wait errorReader)
                pure (code, transcript, diagnostic)
          action (LiveCLI stdinHandle process observe finish) `finally` stopProcess process
    _ -> ioError (userError "D-06 missing interactive client pipes")

typeLine :: LiveCLI -> String -> IO ()
typeLine client text = hPutStrLn (cliInput client) text >> hFlush (cliInput client)

enterFleet :: LiveCLI -> [String] -> Bool -> IO ()
enterFleet client inputs repair = do
  cliAwait client "CV —"
  when repair $ do
    typeLine client "J10 V"
    cliAwait client "vượt mép bàn"
    cliAwait client "CV —"
  forM_ (zip ["CV", "BB", "CR", "SB", "DD"] inputs) $ \(ship, input) -> do
    if ship == "CV" then pure () else cliAwait client (ship ++ " —")
    typeLine client input
  cliAwait client "GUI để gửi"
  typeLine client "GUI"

fire :: LiveCLI -> LiveCLI -> String -> String -> IO ()
fire shooter opponent position outcome = do
  cliAwait shooter firePrompt
  typeLine shooter position
  cliAwait shooter ("Bạn bắn " ++ position ++ ": " ++ outcome)
  cliAwait opponent ("Đối thủ bắn " ++ position ++ ": " ++ outcome)

withServerExecutable :: (PortNumber -> ProcessHandle -> IO a) -> IO a
withServerExecutable = withServerExecutableConfig Nothing Nothing

withServerExecutableConfig :: Maybe String -> Maybe FilePath -> (PortNumber -> ProcessHandle -> IO a) -> IO a
withServerExecutableConfig host marker action = withSocketsDo $ do
  environment <- serverEnvironment host marker
  withCreateProcess
    (proc "battleship-server" ["0"]) { env = Just environment, std_out = CreatePipe, std_err = CreatePipe } $
    \_ output errors process -> case (output, errors) of
      (Just stdoutHandle, Just stderrHandle) ->
        Control.Concurrent.Async.withAsync (hGetContents' stderrHandle) $ \errorReader ->
          (do
            announcement <- await "D-06 executable listen" (hGetLine stdoutHandle)
            let expected = "Battleship server listening on " ++ maybe "127.0.0.1" id host ++ ":"
            port <- case stripPrefix expected announcement >>= readMaybe of
              Just actual | actual > 0 -> pure actual
              _ -> ioError (userError "D-06 invalid server port")
            result <- action port process
            await "D-06 server stderr" (Control.Concurrent.Async.wait errorReader) >>= (`shouldBe` "")
            pure result) `finally` stopProcess process
      _ -> ioError (userError "D-06 missing server pipes")

-- Keep executable cases independent of Docker env exported by the developer.
serverEnvironment :: Maybe String -> Maybe FilePath -> IO [(String, String)]
serverEnvironment host marker = do
  inherited <- getEnvironment
  pure (filter (\(name, _) -> map toUpper name `notElem` ["BATTLESHIP_BIND_HOST", "BATTLESHIP_READY_FILE", "BATTLESHIP_GAME_CAPABILITY"]) inherited
    ++ [("BATTLESHIP_BIND_HOST", value) | Just value <- [host]]
    ++ [("BATTLESHIP_READY_FILE", value) | Just value <- [marker]])

-- Closing pipes can block on Windows; a process watchdog makes failures bounded.
readServerProcess :: [(String, String)] -> [String] -> IO (ExitCode, String, String)
readServerProcess environment arguments = withCreateProcess
  (proc "battleship-server" arguments) { env = Just environment, std_out = CreatePipe, std_err = CreatePipe } $
  \_ output errors process -> case (output, errors) of
    (Just stdoutHandle, Just stderrHandle) ->
      Control.Concurrent.Async.withAsync (threadDelay 5000000 >> terminateProcess process) $ \_ ->
        (do
          (stdoutText, stderrText) <- Control.Concurrent.Async.concurrently
            (hGetContents' stdoutHandle) (hGetContents' stderrHandle)
          code <- await "DK-02 diagnostic process exit" (waitForProcess process)
          pure (code, stdoutText, stderrText)) `finally` stopProcess process
    _ -> ioError (userError "DK-02 missing diagnostic pipes")

stopProcess :: ProcessHandle -> IO ()
stopProcess process = do
  running <- getProcessExitCode process
  when (running == Nothing) (terminateProcess process)
  _ <- await "D-06 process cleanup" (waitForProcess process)
  pure ()

finalBoardRows :: String -> IO [String]
finalBoardRows transcript = case reverse
  [take 10 (drop 2 rest) | rest@(heading : _) <- tails (lines transcript), "Bàn của bạn:" `isPrefixOf` heading] of
    rows : _ -> pure rows
    [] -> ioError (userError "D-05 no public board redraw")

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
