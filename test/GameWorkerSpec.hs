module GameWorkerSpec (spec) where

import Battleship.GameWorker
import Battleship.Server
import Battleship.Types
import qualified Battleship.Rules as Rules
import Control.Concurrent (getNumCapabilities, threadCapability, throwTo)
import Control.Concurrent.Async (mapConcurrently, wait, withAsync)
import Control.Concurrent.STM
import Control.Exception (AsyncException (ThreadKilled), SomeException, try)
import Control.Monad (forM_, replicateM, void)
import qualified Data.ByteString.Char8 as B
import qualified Data.Map.Strict as Map
import Data.Either (isLeft)
import Data.List (isInfixOf)
import qualified Network.Socket.ByteString
import ServerSpec (await, expectClosed, expectLine, withClient)
import Test.Hspec

spec :: Spec
spec = describe "NM-05 game worker locality and bounded mailbox" $ do
  it "defaults to capability zero and validates against runtime count" $ do
    parseGameRuntimeConfig 1 Nothing `shouldBe` Right defaultGameRuntimeConfig
    parseGameRuntimeConfig 3 (Just "2") `shouldSatisfy` either (const False) ((== 2) . gameCapability)
  forM_ ["", "-1", "01", "+1", " 1", "1 ", "1.0", "2", "99999999999999999999999999"] $ \input ->
    it ("rejects invalid capability " ++ show input) $
      parseGameRuntimeConfig 2 (Just input) `shouldSatisfy` isLeft
  it "rejects a runtime with no capabilities" $
    parseGameRuntimeConfig 0 Nothing `shouldSatisfy` isLeft

  it "runs and initializes on every requested available capability" $ do
    count <- getNumCapabilities
    forM_ [0 .. count - 1] $ \capability ->
      withGameWorker capability Rules.step initialGameState $ \worker -> do
        workerCapability worker `shouldBe` capability
        threadCapability (workerThreadId worker) `shouldReturn` (capability, True)
        atomically (readWorkerState worker) `shouldReturn` initialGameState
  it "rejects invalid mailbox/worker configuration before calling the consumer" $ do
    let consumer _ = expectationFailure "invalid worker became ready"
    withGameWorker (-1) Rules.step initialGameState consumer `shouldThrow` anyIOException
    withGameWorkerWithCapacity 0 0 128 Rules.step initialGameState consumer `shouldThrow` anyIOException
    withGameWorkerWithCapacity 0 1 4 Rules.step initialGameState consumer `shouldThrow` anyIOException

  it "routes admission, parser errors, oversized input and wire Quit through one owner" $
    withGameWorker 0 Rules.step initialGameState $ \worker -> do
      submitRequest worker (Admit P1) `shouldReturn` Right True
      submitRequest worker (Payload P1 (B.pack "FIRE K1")) `shouldReturn` Right True
      submitRequest worker (OversizedInput P1) `shouldReturn` Right True
      atomically (readWorkerState worker) `shouldReturn` initialGameState
      submitRequest worker (Payload P1 (B.pack "QUIT")) `shouldReturn` Right False
      drain worker P1 `shouldReturn` (map (Just . B.pack)
        ["WELCOME 1 P1\n", "ERROR INVALID_COORDINATE\n", "ERROR LINE_TOO_LONG\n", "GAME_OVER P2 OPPONENT_LEFT\n"] ++ [Nothing])
      drain worker P2 `shouldReturn` [Just (B.pack "GAME_OVER P2 OPPONENT_LEFT\n"), Nothing]

  it "processes concurrent readers exactly once, preserving each reader's FIFO (100 rounds)" $
    forM_ [1 :: Int .. 100] $ \_ -> withGameWorker 0 counting initialGameState $ \worker -> do
      let send player = forM_ [1 .. 10] $ \row ->
            submitRequest worker (CommandRequest player (Fire (Coord 1 row))) `shouldReturn` Right True
      void (mapConcurrently send [P1, P2])
      state <- atomically (readWorkerState worker)
      map (Map.size . playerShots . (`playerStateFor` state)) [P1, P2] `shouldBe` [10, 10]
      forM_ [P1, P2] $ \player -> do
        frames <- drain worker player
        let own = [frame | Just frame <- frames, B.pack "SHOT " `B.isPrefixOf` frame]
            incoming = [frame | Just frame <- frames, B.pack "INCOMING " `B.isPrefixOf` frame]
        length frames `shouldBe` 20
        own `shouldBe` [B.pack ("SHOT A" ++ show row ++ " MISS\n") | row <- [1 :: Int .. 10]]
        incoming `shouldBe` [B.pack ("INCOMING A" ++ show row ++ " MISS\n") | row <- [1 :: Int .. 10]]

  it "gives disconnect priority over a full mailbox without invoking queued gameplay" $
    withGameWorkerWithCapacity 0 2 128 Rules.step initialGameState $ \worker -> do
      tickets <- atomically $ do
        queued <- replicateM 2 (enqueueRequest worker (Payload P1 (B.pack "UNKNOWN")))
        mailboxSize worker >>= (\size -> if size == 2 then pure () else error "mailbox not full")
        forM_ [1 :: Int .. 100] $ \_ -> disconnectPlayer worker P2
        pure queued
      mapM_ (\ticket -> await "full mailbox disconnect ack" (atomically ticket) `shouldReturn` Right False) tickets
      atomically (readWorkerState worker) `shouldReturn` initialGameState { gamePhase = Finished P1 OpponentLeft }
      drain worker P1 `shouldReturn` [Just (B.pack "GAME_OVER P1 OPPONENT_LEFT\n"), Nothing]
  it "selects P1 first when both disconnect controls commit together" $
    withGameWorker 0 Rules.step initialGameState $ \worker -> do
      atomically (disconnectPlayer worker P2 >> disconnectPlayer worker P1)
      await "disconnect state" (atomically $ do
        state <- readWorkerState worker
        check (gamePhase state /= Placing)
        pure (gamePhase state)) `shouldReturn` Finished P2 OpponentLeft
  it "stop proceeds at full capacity, releases tickets and backpressured producers" $
    withGameWorkerWithCapacity 0 1 128 Rules.step initialGameState $ \worker -> do
      ticket <- atomically $ do
        first <- enqueueRequest worker (Payload P1 (B.pack "UNKNOWN"))
        -- Trying a second admission proves the queue would block before stop.
        blocked <- (enqueueRequest worker (Admit P2) >> pure False) `orElse` pure True
        if blocked then pure () else error "capacity not enforced"
        stopGameWorker worker
        pure first
      await "stop releases ack" (atomically ticket) `shouldReturn` Right False
      await "stop releases producer" (submitRequest worker (Admit P2)) `shouldReturn` Right False
      atomically (readWorkerState worker) `shouldReturn` initialGameState
      drain worker P1 `shouldReturn` []
  it "outbox overflow still resigns the recipient and keeps reserved terminal slots" $
    withGameWorkerWithCapacity 0 2 5 Rules.step initialGameState $ \worker -> do
      replicateM 3 (submitRequest worker (Payload P2 (B.pack "UNKNOWN"))) `shouldReturn` replicate 3 (Right True)
      submitRequest worker (Payload P2 (B.pack "UNKNOWN")) `shouldReturn` Right False
      atomically (workerQueuedFrames worker P2) `shouldReturn` 5
      atomically (isWorkerSlow worker P2) `shouldReturn` True
      drain worker P2 `shouldReturn` (replicate 3 (Just (B.pack "ERROR INVALID_COMMAND\n"))
        ++ [Just (B.pack "GAME_OVER P1 OPPONENT_LEFT\n"), Nothing])
      drain worker P1 `shouldReturn` [Just (B.pack "GAME_OVER P1 OPPONENT_LEFT\n"), Nothing]
      submitRequest worker (CommandRequest P1 Quit) `shouldReturn` Right False
  it "does not publish a state or frame with a deferred crashing state field" $ do
    saved <- newEmptyTMVarIO
    let bad _ _ state = Right (state { gamePlayer1 = PlayerState Nothing
          (Map.singleton (Coord (error "deferred coordinate evaluated by worker") 1) Miss) }, [])
    outcome <- try $ withGameWorker 0 bad initialGameState $ \worker -> do
      atomically (putTMVar saved worker)
      void (submitRequest worker (CommandRequest P1 (Fire (Coord 1 1))))
    (outcome :: Either SomeException ()) `shouldSatisfy` either (isInfixOf "deferred coordinate" . show) (const False)
    worker <- atomically (readTMVar saved)
    atomically (readWorkerState worker) `shouldReturn` initialGameState
    drain worker P1 `shouldReturn` []
    submitRequest worker (Admit P2) `shouldThrow` anyException
  it "overload resigns the recipient instead of the sender and rolls back the proposed shot" $
    let core player command state = case command of
          Fire _ -> counting player command state
          _ -> Rules.step player command state
    in withGameWorkerWithCapacity 0 2 5 core initialGameState $ \worker -> do
      void (replicateM 3 (submitRequest worker (Payload P2 (B.pack "UNKNOWN"))))
      submitRequest worker (CommandRequest P1 (Fire (Coord 1 1))) `shouldReturn` Right False
      atomically (readWorkerState worker) `shouldReturn` initialGameState { gamePhase = Finished P1 OpponentLeft }
      atomically (isWorkerSlow worker P2) `shouldReturn` True
      atomically (isWorkerSlow worker P1) `shouldReturn` False
      drain worker P1 `shouldReturn` [Just (B.pack "GAME_OVER P1 OPPONENT_LEFT\n"), Nothing]
  it "failure releases every queued ack, including requests the worker never processed" $ do
    saved <- newEmptyTMVarIO
    let crash _ _ _ = error "crash with queued readers"
    outcome <- try $ withGameWorkerWithCapacity 0 2 128 crash initialGameState $ \worker -> do
      tickets <- atomically $ do
        queued <- replicateM 2 (enqueueRequest worker (CommandRequest P1 Quit))
        putTMVar saved (worker, queued)
        pure queued
      mapM_ (void . atomically) tickets
    (outcome :: Either SomeException ()) `shouldSatisfy` isLeft
    (worker, tickets) <- atomically (readTMVar saved)
    mapM_ (\ticket -> await "failure releases queued ack" (atomically ticket) `shouldThrow` anyException) tickets
    atomically (mailboxSize worker) `shouldReturn` 0
    atomically (readWorkerState worker) `shouldReturn` initialGameState
    drain worker P1 `shouldReturn` []
  it "cancellation wakes producers and propagates failure without a late notification" $ do
    saved <- newEmptyTMVarIO
    outcome <- try $ withGameWorker 0 Rules.step initialGameState $ \worker -> do
      atomically (putTMVar saved worker)
      throwTo (workerThreadId worker) ThreadKilled
      void (submitRequest worker (Admit P1))
    (outcome :: Either SomeException ()) `shouldSatisfy` isLeft
    worker <- atomically (readTMVar saved)
    await "cancel waiter released" (submitRequest worker (Admit P2)) `shouldThrow` anyException
  it "propagates initialization failure instead of announcing readiness" $
    withGameWorker 0 Rules.step (error "invalid initialization") (const (pure ())) `shouldThrow` anyException

  it "runs the real TCP server on a chosen capability and cleans sockets on worker failure" $ do
    count <- getNumCapabilities
    runtime <- either (ioError . userError) pure (parseGameRuntimeConfig count (Just (show (count - 1))))
    ready <- newEmptyTMVarIO
    let crash _ _ _ = error "NM-05 core failure"
    withAsync (runServerWithRuntime runtime defaultServerConfig crash initialGameState 0 (atomically . putTMVar ready)) $ \server -> do
      port <- await "worker server readiness" (atomically (readTMVar ready))
      withClient port $ \first -> withClient port $ \second -> do
        expectLine first "WELCOME 1 P1"
        expectLine second "WELCOME 1 P2"
        -- A real command reaches the failing worker, and both sockets close.
        Network.Socket.ByteString.sendAll first (B.pack "FIRE A1\n")
        mapM_ expectClosed [first, second]
        await "worker failure server exit" (wait server) `shouldThrow`
          (\exception -> "NM-05 core failure" `isInfixOf` show (exception :: SomeException))

counting :: Step
counting player (Fire cell) state =
  let previous = playerStateFor player state
      updated = previous { playerShots = Map.insert cell Miss (playerShots previous) }
  in Right (setPlayerState player updated state, [ShotResolved player cell Miss])
counting _ _ _ = error "unexpected test command"

drain :: GameWorker -> PlayerId -> IO [Maybe B.ByteString]
drain worker player = atomically $ do
  count <- workerQueuedFrames worker player
  replicateM (fromIntegral count) (nextWorkerFrame worker player)
