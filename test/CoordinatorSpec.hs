module CoordinatorSpec (spec) where

import Battleship.Coordinator
import Battleship.Protocol
import qualified Battleship.Rules as Rules
import Battleship.Server (runServerWith)
import Battleship.Types
import Control.Concurrent.Async (Async, mapConcurrently, mapConcurrently_, race, wait, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM
import Control.Exception (AssertionFailed (..), SomeException)
import Control.Monad (foldM, forM_)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map.Strict as Map
import Data.List (isInfixOf, sort)
import Network.Socket (PortNumber, ShutdownCmd (ShutdownSend), Socket, close, shutdown, withSocketsDo)
import Network.Socket.ByteString (sendAll)
import ServerSpec (await, expectClosed, expectLine, readLine, withClient, withServer)
import Test.Hspec (Spec, anyException, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy, shouldThrow)

spec :: Spec
spec = do
  c03Spec
  c04Spec
  c05Spec
  c06Spec
  c07Spec

c03Spec :: Spec
c03Spec = describe "C-03 Coordinator" $ do
  describe "pure command boundary" $ do
    forM_ [("UNKNOWN", BadCommand), ("", BadCommand), ("P2 FIRE A1", BadCommand),
           ("FIRE", BadCommand), ("FIRE K1", BadCoordinate), ("FIRE A01", BadCoordinate),
           ("PLACE CV=J11:H", BadCoordinate), (replicate 257 'X', TooLong)] $ \(payload, fault) ->
      it ("rejects without calling step or changing state: " ++ take 30 payload) $
        coordinate unusedCore P2 (b payload) initialGameState `shouldBe`
          Right (initialGameState, [(P2, frame (Rejected fault))])

    forM_ [P1, P2] $ \actor ->
      forM_ [("QUIT", Quit), ("FIRE J10", Fire (Coord 10 10)),
             ("PLACE DD=A5:H;CV=A1:H", PlaceFleet
                [ShipPlacement Destroyer (Coord 1 5) Horizontal,
                 ShipPlacement Carrier (Coord 1 1) Horizontal])] $ \(payload, command) ->
        it ("passes the socket actor, parsed command and exact old state: " ++ show (actor, command)) $ do
          let core actualActor actualCommand actualState
                | (actualActor, actualCommand, actualState) == (actor, command, initialGameState) =
                    Right (initialGameState { gamePhase = Finished actor OpponentLeft },
                           [GameEnded actor OpponentLeft])
                | otherwise = Left (InvalidCommand "wrong core arguments")
          coordinate core actor (b payload) initialGameState `shouldBe`
            Right (initialGameState { gamePhase = Finished actor OpponentLeft },
                   [(P1, frame (GameOver actor OpponentLeft)), (P2, frame (GameOver actor OpponentLeft))])

    forM_ [InvalidCommand "private debug", InvalidCoordinate (Coord 11 1),
           InvalidFleetSize 4, MissingShip Destroyer, DuplicateShip Cruiser,
           ShipOutOfBounds Carrier (Coord 11 1), ShipsOverlap (Coord 1 1),
           FleetAlreadyPlaced, FleetsNotReady, NotYourTurn P1,
           AlreadyFired (Coord 10 10), GameAlreadyFinished] $ \fault ->
      it ("preserves all state and routes only to the actor on " ++ show fault) $
        coordinate (\_ _ _ -> Left fault) P2 (b "FIRE J10") readyState `shouldBe`
          Right (readyState, [(P2, frame (Rejected (wireError fault)))])

    it "uses the resulting phase and preserves order of the entire event batch" $ do
      let events = [FleetAccepted P2, GameStarted P1, TurnReady P1]
      coordinate (\_ _ _ -> Right (readyState, events)) P2 (b place2) initialGameState `shouldBe`
        Right (readyState, [(P2, b "OK PLACE\n"), (P1, b "START P1\n"),
               (P2, b "START P1\n"), (P1, b "TURN P1\n"), (P2, b "TURN P1\n")])

    it "keeps WAITING actor-only when the resulting phase is still Placing" $
      coordinate (\_ _ state -> Right (state, [FleetAccepted P1])) P1 (b place1) initialGameState
        `shouldBe` Right (initialGameState, [(P1, b "OK PLACE\n"), (P1, b "WAITING OPPONENT\n")])

    it "rejects an unencodable event batch instead of returning partial frames/state" $
      applyCommand (\_ _ state -> Right (state { gamePhase = Turn P2 },
        [TurnReady P2, ShotResolved P1 (Coord 11 1) Hit])) P1 Quit readyState
        `shouldBe` Left InvalidCoordinateToken

    it "rejects an unencodable rule error as an internal failure" $
      applyCommand (\_ _ _ -> Left (InvalidFleetSize 257)) P1 Quit initialGameState
        `shouldBe` Left InvalidMessage

    it "keeps production state on parser/rule errors, then accepts the next valid shot" $ do
      forM_ [(P2, "FIRE J10", "ERROR NOT_YOUR_TURN P1\n"),
             (P1, "FIRE K1", "ERROR INVALID_COORDINATE\n"),
             (P1, "fire A6", "ERROR INVALID_COMMAND\n"),
             (P1, place1, "ERROR FLEET_ALREADY_PLACED\n")] $ \(actor, payload, reply) ->
        coordinate Rules.step actor (b payload) readyState `shouldBe` Right (readyState, [(actor, b reply)])
      case coordinate Rules.step P1 (b "FIRE A6") readyState of
        Left fault -> expectationFailure (show fault)
        Right (next, frames) -> do
          frames `shouldBe` [(P1, b "SHOT A6 HIT\n"), (P2, b "INCOMING A6 HIT\n"),
                            (P1, b "TURN P1\n"), (P2, b "TURN P1\n")]
          playerShots (gamePlayer1 next) `shouldBe` Map.singleton (Coord 1 6) Hit
          coordinate Rules.step P1 (b "FIRE A6") next `shouldBe`
            Right (next, [(P1, b "ERROR ALREADY_FIRED A6\n")])

  describe "real TCP integration" $ do
    it "calls the injected Step with P2 and retains its state for the next command" $
      withCore countingStub readyState $ \port server -> withPair port $ \first second -> do
        send second "FIRE J10\n"
        expectLine second "SHOT J10 HIT"
        expectLine first "INCOMING J10 HIT"
        expectTurns first second "P2"
        send second "FIRE J10\n"
        expectLine second "SHOT J10 WIN"
        expectLine first "INCOMING J10 WIN"
        expectFinal first second "P2" "ALL_SHIPS_SUNK" server

    it "executes the connect -> PLACE -> first shot transcript with the real core" $
      withServer $ \port server -> withClient port $ \first -> do
        expectLine first "WELCOME 1 P1"
        send first (place1 ++ "\n")
        expectLine first "OK PLACE"
        expectLine first "WAITING OPPONENT"
        withClient port $ \second -> do
          expectLine second "WELCOME 1 P2"
          send second (place2 ++ "\n")
          expectLine second "OK PLACE"
          forM_ [first, second] $ \connection -> do
            expectLine connection "START P1"
            expectLine connection "TURN P1"
          send first "FIRE A6\n"
          expectLine first "SHOT A6 HIT"
          expectLine second "INCOMING A6 HIT"
          expectTurns first second "P1"
          -- The next valid event proves errors never leak to the opponent,
          -- cause a second START, or consume a turn.
          send second "FIRE J10\n"
          expectLine second "ERROR NOT_YOUR_TURN P1"
          send first "FIRE K1\nFIRE A6\nfire B6\nFIRE B6\n"
          mapM_ (expectLine first) ["ERROR INVALID_COORDINATE", "ERROR ALREADY_FIRED A6",
                                   "ERROR INVALID_COMMAND", "SHOT B6 HIT"]
          expectLine second "INCOMING B6 HIT"
          expectTurns first second "P1"
          send first "FIRE J10\n"
          expectLine first "SHOT J10 MISS"
          expectLine second "INCOMING J10 MISS"
          expectTurns first second "P2"
          send second "FIRE A1\n"
          expectLine second "SHOT A1 HIT"
          expectLine first "INCOMING A1 HIT"
          expectTurns first second "P2"
          send second "QUIT\n"
          expectFinal first second "P1" "OPPONENT_LEFT" server

    it "does not install a partial invalid fleet before a corrected PLACE" $
      withServer $ \port server -> withPair port $ \first second -> do
        send first "PLACE CV=J10:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H\n"
        expectLine first "ERROR SHIP_OUT_OF_BOUNDS CV"
        send first (place1 ++ "\n" ++ place1 ++ "\n")
        mapM_ (expectLine first) ["OK PLACE", "WAITING OPPONENT", "ERROR FLEET_ALREADY_PLACED"]
        send second "QUIT\n"
        expectFinal first second "P1" "OPPONENT_LEFT" server

    it "serializes simultaneous PLACE requests into one START and one shared turn" $
      withServer $ \port server -> withPair port $ \first second -> do
        mapConcurrently_ (uncurry send) [(first, place1 ++ "\n"), (second, place2 ++ "\n")]
        mapConcurrently_ placementStarted [first, second]
        send first "FIRE A6\n"
        expectLine first "SHOT A6 HIT"
        expectLine second "INCOMING A6 HIT"
        expectTurns first second "P1"
        send first "QUIT\n"
        expectFinal first second "P2" "OPPONENT_LEFT" server

    it "serializes simultaneous FIRE requests against one shared state" $
      withCore Rules.step readyState $ \port server -> withPair port $ \first second -> do
        mapConcurrently_ (\connection -> send connection "FIRE A6\n") [first, second]
        expectLine first "SHOT A6 HIT"
        expectLine first "TURN P1"
        replies <- sequence [readLine second, readLine second, readLine second]
        sort replies `shouldBe` sort (map b ["ERROR NOT_YOUR_TURN P1", "INCOMING A6 HIT", "TURN P1"])
        send first "FIRE A6\nQUIT\n"
        expectLine first "ERROR ALREADY_FIRED A6"
        expectFinal first second "P2" "OPPONENT_LEFT" server

    it "fails visibly on a bad core event without publishing partial frames/state" $
      withCore badEventStub readyState $ \port server -> withPair port $ \first second -> do
        send first "FIRE A6\n"
        mapM_ expectClosed [first, second]
        await "bad core event exits" (wait server) `shouldThrow`
          (\exception -> "Coordinator produced an unencodable response" `isInfixOf` show (exception :: SomeException))

    forM_ [P1, P2] $ \actor ->
      it ("delivers real SUNK/WIN and preserves the winner at EOF: " ++ show actor) $
        withCore Rules.step (nearWin actor) $ \port server -> withPair port $ \first second -> do
          let (shooter, target) = if actor == P1 then (first, second) else (second, first)
              token = show actor
          send shooter "FIRE B10\n"
          expectLine shooter "SHOT B10 SUNK DD"
          expectLine target "INCOMING B10 SUNK DD"
          expectTurns first second token
          send shooter "FIRE E6\nQUIT\n"
          shutdown shooter ShutdownSend
          expectLine shooter "SHOT E6 WIN"
          expectLine target "INCOMING E6 WIN"
          expectFinal first second token "ALL_SHIPS_SUNK" server

    it "submits EOF as Quit to the injected core, rather than inventing a result" $
      withCore eofStub readyState $ \port server -> withPair port $ \first second -> do
        shutdown second ShutdownSend
        expectFinal first second "P2" "ALL_SHIPS_SUNK" server

c04Spec :: Spec
c04Spec = describe "C-04 atomic STM coordinator" $ do
  it "starts with one authoritative state and two empty independent outboxes" $ do
    coordinator <- atomically (newCoordinator readyState)
    atomically (snapshot coordinator) `shouldReturn` (readyState, [], [])

  it "rejects malformed input without calling step, changing state or notifying the opponent" $
    forM_ [("UNKNOWN", "ERROR INVALID_COMMAND\n"), ("FIRE K1", "ERROR INVALID_COORDINATE\n"),
           (replicate 257 'X', "ERROR LINE_TOO_LONG\n")] $ \(payload, reply) -> do
      coordinator <- atomically (newCoordinator readyState)
      atomically (submitPayload unusedCore coordinator P2 (b payload)) `shouldReturn` Right True
      atomically (snapshot coordinator) `shouldReturn` (readyState, [], [Just (b reply)])

  forM_ [P1, P2] $ \actor ->
    it ("keeps all state and emits only " ++ show actor ++ "'s error on rule rejection") $ do
      coordinator <- atomically (newCoordinator readyState)
      let command = if actor == P1 then Fire (Coord 0 1) else Fire (Coord 10 10)
          reply = Just (b (if actor == P1 then "ERROR INVALID_COORDINATE\n" else "ERROR NOT_YOUR_TURN P1\n"))
      atomically (submitCommand Rules.step coordinator actor command) `shouldReturn` Right True
      atomically (snapshot coordinator) `shouldReturn`
        (readyState, [reply | actor == P1], [reply | actor == P2])

  it "commits simultaneous placements with exactly one START and one waiting reply" $ do
    coordinator <- atomically (newCoordinator initialGameState)
    concurrentlySubmit coordinator [(P1, PlaceFleet (placements 1)), (P2, PlaceFleet (placements 6))]
      `shouldReturn` [Right True, Right True]
    (state, first, second) <- atomically (snapshot coordinator)
    state `shouldBe` readyState
    forM_ [first, second] $ \frames -> do
      length (filter (== Just (b "OK PLACE\n")) frames) `shouldBe` 1
      length (filter (== Just (b "START P1\n")) frames) `shouldBe` 1
      length (filter (== Just (b "TURN P1\n")) frames) `shouldBe` 1
    length (filter (== Just (b "WAITING OPPONENT\n")) (first ++ second)) `shouldBe` 1
    take 1 first `shouldBe` [Just (b "OK PLACE\n")]
    take 1 second `shouldBe` [Just (b "OK PLACE\n")]

  it "never accepts two distinct Miss shots against the same old P1 turn (50 races)" $
    forM_ [1 :: Int .. 50] $ \_ -> do
      coordinator <- atomically (newCoordinator readyState)
      concurrentlySubmit coordinator [(P1, Fire (Coord 10 10)), (P1, Fire (Coord 10 9))]
        `shouldReturn` [Right True, Right True]
      actual@(state, first, _) <- atomically (snapshot coordinator)
      Map.size (playerShots (gamePlayer1 state)) `shouldBe` 1
      gamePhase state `shouldBe` Turn P2
      last first `shouldBe` Just (b "ERROR NOT_YOUR_TURN P2\n")
      actual `shouldSatisfy` (`elem` serialSnapshots [(P1, Fire (Coord 10 10)), (P1, Fire (Coord 10 9))])

  it "serializes competing P1/P2 misses according to the newly committed turn (50 races)" $
    forM_ [1 :: Int .. 50] $ \_ -> do
      coordinator <- atomically (newCoordinator readyState)
      let commands = [(P1, Fire (Coord 10 10)), (P2, Fire (Coord 10 9))]
      concurrentlySubmit coordinator commands `shouldReturn` [Right True, Right True]
      actual <- atomically (snapshot coordinator)
      actual `shouldSatisfy` (`elem` serialSnapshots commands)

  it "keeps both hits on a retained turn without losing state or interleaving event batches (50 races)" $
    forM_ [1 :: Int .. 50] $ \_ -> do
      coordinator <- atomically (newCoordinator readyState)
      let commands = [(P1, Fire (Coord 1 6)), (P1, Fire (Coord 2 6))]
      concurrentlySubmit coordinator commands `shouldReturn` [Right True, Right True]
      actual@(state, _, _) <- atomically (snapshot coordinator)
      playerShots (gamePlayer1 state) `shouldBe` Map.fromList [(Coord 1 6, Hit), (Coord 2 6, Hit)]
      actual `shouldSatisfy` (`elem` serialSnapshots commands)

  it "records a concurrent duplicate hit once and then sends AlreadyFired (50 races)" $
    forM_ [1 :: Int .. 50] $ \_ -> do
      coordinator <- atomically (newCoordinator readyState)
      let commands = [(P1, Fire (Coord 1 6)), (P1, Fire (Coord 1 6))]
      concurrentlySubmit coordinator commands `shouldReturn` [Right True, Right True]
      actual@(state, _, _) <- atomically (snapshot coordinator)
      playerShots (gamePlayer1 state) `shouldBe` Map.singleton (Coord 1 6) Hit
      actual `shouldSatisfy` (`elem` serialSnapshots commands)

  it "enqueues one consistent GAME_OVER and FIFO end markers for simultaneous Quit (50 races)" $
    forM_ [1 :: Int .. 50] $ \_ -> do
      coordinator <- atomically (newCoordinator readyState)
      concurrentlySubmit coordinator [(P1, Quit), (P2, Quit)] `shouldReturn` [Right False, Right False]
      (state, first, second) <- atomically (snapshot coordinator)
      let winner = case gamePhase state of Finished player OpponentLeft -> player; _ -> error "Quit did not finish"
      first `shouldBe` [Just (b ("GAME_OVER " ++ show winner ++ " OPPONENT_LEFT\n")), Nothing]
      second `shouldBe` first
      atomically (submitCommand Rules.step coordinator winner Quit) `shouldReturn` Right False
      atomically (snapshot coordinator) `shouldReturn` (state, [], [])

  forM_ [P1, P2] $ \actor ->
    it ("commits " ++ show actor ++ "'s last ship cell, WIN/GAME_OVER and closure together") $ do
      let before = nearWin actor
          (almost, _) = either (error . show) id (Rules.step actor (Fire (Coord 2 10)) before)
          (finished, _) = either (error . show) id (Rules.step actor (Fire (Coord 5 6)) almost)
          outgoing = [Just (b "SHOT E6 WIN\n"), Just (b ("GAME_OVER " ++ show actor ++ " ALL_SHIPS_SUNK\n")), Nothing]
          incoming = [Just (b "INCOMING E6 WIN\n"), Just (b ("GAME_OVER " ++ show actor ++ " ALL_SHIPS_SUNK\n")), Nothing]
      coordinator <- atomically (newCoordinator almost)
      atomically (submitPayload Rules.step coordinator actor (b "FIRE E6")) `shouldReturn` Right False
      atomically (snapshot coordinator) `shouldReturn`
        (finished, if actor == P1 then outgoing else incoming, if actor == P2 then outgoing else incoming)
      atomically (welcomePlayer coordinator (otherPlayer actor)) `shouldReturn` Right False
      atomically (submitCommand Rules.step coordinator (otherPlayer actor) Quit) `shouldReturn` Right False
      atomically (snapshot coordinator) `shouldReturn` (finished, [], [])

  it "does not commit state or a partial batch when encoding a core event fails" $ do
    coordinator <- atomically (newCoordinator readyState)
    atomically (submitCommand badEventStub coordinator P1 (Fire (Coord 1 6))) `shouldReturn` Left InvalidCoordinateToken
    atomically (snapshot coordinator) `shouldReturn` (readyState, [], [])

  it "does not commit an unencodable rule error" $ do
    coordinator <- atomically (newCoordinator readyState)
    atomically (submitCommand (\_ _ _ -> Left (InvalidFleetSize 257)) coordinator P1 Quit) `shouldReturn` Left InvalidMessage
    atomically (snapshot coordinator) `shouldReturn` (readyState, [], [])

  it "rolls back both state and outboxes when the enclosing transaction throws" $ do
    coordinator <- atomically (newCoordinator readyState)
    (atomically (submitCommand Rules.step coordinator P1 (Fire (Coord 1 6)) >> throwSTM (AssertionFailed "rollback")) :: IO ())
      `shouldThrow` anyException
    atomically (snapshot coordinator) `shouldReturn` (readyState, [], [])

  it "rolls back speculative state and frames on retry/orElse" $ do
    coordinator <- atomically (newCoordinator readyState)
    atomically ((submitCommand Rules.step coordinator P1 (Fire (Coord 1 6)) >> retry) `orElse` pure ())
    atomically (snapshot coordinator) `shouldReturn` (readyState, [], [])

  it "puts WELCOME first at admission and clears only that absent player's older frames" $ do
    coordinator <- atomically (newCoordinator readyState)
    atomically (submitCommand Rules.step coordinator P1 (Fire (Coord 10 10))) `shouldReturn` Right True
    atomically (welcomePlayer coordinator P2) `shouldReturn` Right True
    let (after, _) = either (error . show) id (Rules.step P1 (Fire (Coord 10 10)) readyState)
    atomically (snapshot coordinator) `shouldReturn`
      (after, map (Just . b) ["SHOT J10 MISS\n", "TURN P2\n"], [Just (b "WELCOME 1 P2\n")])

  it "queues LINE_TOO_LONG before Quit's terminal response without changing state on the error" $ do
    coordinator <- atomically (newCoordinator readyState)
    atomically (submitTooLong Rules.step coordinator P1) `shouldReturn` Right True
    atomically (readGameState coordinator) `shouldReturn` readyState
    atomically (submitCommand Rules.step coordinator P1 Quit) `shouldReturn` Right False
    let (finished, _) = either (error . show) id (Rules.step P1 Quit readyState)
    atomically (snapshot coordinator) `shouldReturn`
      (finished, [Just (b "ERROR LINE_TOO_LONG\n"), Just (b "GAME_OVER P2 OPPONENT_LEFT\n"), Nothing],
                 [Just (b "GAME_OVER P2 OPPONENT_LEFT\n"), Nothing])

  it "can commit another command while neither recipient drains its queue" $ do
    coordinator <- atomically (newCoordinator readyState)
    forM_ [1 :: Int .. 100] $ \_ ->
      atomically (submitPayload Rules.step coordinator P2 (b "FIRE J10")) `shouldReturn` Right True
    await "C-04 commit without socket writer" (atomically (submitPayload Rules.step coordinator P1 (b "FIRE A6")))
      `shouldReturn` Right True
    state <- atomically (readGameState coordinator)
    playerShots (gamePlayer1 state) `shouldBe` Map.singleton (Coord 1 6) Hit

c05Spec :: Spec
c05Spec = describe "C-05 recipient queues and terminal delivery" $ do
  forM_ [P1, P2] $ \early ->
    it ("keeps " ++ show early ++ "'s fleet private and delivers the exact start batch to each player") $ do
      coordinator <- atomically (newCoordinator initialGameState)
      let late = otherPlayer early
          row actor = if actor == P1 then 1 else 6
          ownQueue actor frames = if actor == P1 then (frames, []) else ([], frames)
          (earlyFrames, otherFrames) = ownQueue early (map (Just . b) ["OK PLACE\n", "WAITING OPPONENT\n"])
          placed = fixture (fst <$> Rules.step early (PlaceFleet (placements (row early))) initialGameState)
      atomically (submitCommand Rules.step coordinator early (PlaceFleet (placements (row early)))) `shouldReturn` Right True
      atomically (snapshot coordinator) `shouldReturn` (placed, earlyFrames, otherFrames)
      atomically (submitCommand Rules.step coordinator late (PlaceFleet (placements (row late)))) `shouldReturn` Right True
      (state, first, second) <- atomically (snapshot coordinator)
      state `shouldBe` readyState
      forM_ [(P1, first), (P2, second)] $ \(recipient, frames) ->
        frames `shouldBe` map (Just . b) (["OK PLACE\n" | recipient == late] ++ ["START P1\n", "TURN P1\n"])

  forM_ [P1, P2] $ \actor ->
    it ("sends SHOT only to " ++ show actor ++ " and INCOMING only to its opponent") $ do
      let initial = if actor == P1 then readyState
            else fixture (fst <$> Rules.step P1 (Fire (Coord 10 10)) readyState)
          position = if actor == P1 then Coord 1 6 else Coord 1 1
          token = if actor == P1 then "A6" else "A1"
          expected = fixture (fst <$> Rules.step actor (Fire position) initial)
      coordinator <- atomically (newCoordinator initial)
      atomically (submitCommand Rules.step coordinator actor (Fire position)) `shouldReturn` Right True
      (state, first, second) <- atomically (snapshot coordinator)
      state `shouldBe` expected
      forM_ [(P1, first), (P2, second)] $ \(recipient, frames) ->
        frames `shouldBe` map (Just . b)
          [(if recipient == actor then "SHOT " else "INCOMING ") ++ token ++ " HIT\n", "TURN " ++ show actor ++ "\n"]

  forM_ [P1, P2] $ \departing ->
    forM_ [("unplaced", initialGameState), ("waiting", fixture (fst <$> Rules.step (otherPlayer departing)
            (PlaceFleet (placements 1)) initialGameState)), ("playing", readyState)] $ \(stage, initial) ->
      it ("ends once for " ++ show departing ++ " leaving during " ++ stage ++ " without later frames") $ do
        coordinator <- atomically (newCoordinator initial)
        atomically (submitCommand Rules.step coordinator departing Quit) `shouldReturn` Right False
        let winner = otherPlayer departing
            expected = initial { gamePhase = Finished winner OpponentLeft }
            frames = [Just (b ("GAME_OVER " ++ show winner ++ " OPPONENT_LEFT\n")), Nothing]
        atomically (snapshot coordinator) `shouldReturn` (expected, frames, frames)
        -- EOF finalizers, failed writers and buffered commands can all arrive
        -- after the first terminal transaction. They cannot rewrite the winner
        -- or append frames behind an end marker that a writer has consumed.
        forM_ [P1, P2] $ \actor -> do
          atomically (submitCommand Rules.step coordinator actor Quit) `shouldReturn` Right False
          atomically (submitPayload Rules.step coordinator actor (b "FIRE J10")) `shouldReturn` Right False
          atomically (submitTooLong Rules.step coordinator actor) `shouldReturn` Right False
          atomically (welcomePlayer coordinator actor) `shouldReturn` Right False
        atomically (snapshot coordinator) `shouldReturn` (expected, [], [])

c06Spec :: Spec
c06Spec = describe "C-06 concurrent shots and disconnects" $ do
  forM_ [P1, P2] $ \current -> do
    it (show current ++ " alone commits a Hit against the other player's concurrent shot (100 STM races)") $
      forM_ [1 :: Int .. 100] $ \_ -> do
        let before = if current == P1 then readyState
              else fixture (fst <$> Rules.step P1 (Fire (Coord 10 10)) readyState)
            position = if current == P1 then Coord 1 6 else Coord 1 1
            token = if current == P1 then "A6" else "A1"
            forbidden = otherPlayer current
            forbiddenPosition = if current == P1 then Coord 1 1 else Coord 1 6
            shooter = playerStateFor current before
            expected = setPlayerState current
              (shooter { playerShots = Map.insert position Hit (playerShots shooter) }) before
            allowedFrames = map (Just . b) ["SHOT " ++ token ++ " HIT\n", "TURN " ++ show current ++ "\n"]
            incoming = map (Just . b) ["INCOMING " ++ token ++ " HIT\n", "TURN " ++ show current ++ "\n"]
            rejected = Just (b ("ERROR NOT_YOUR_TURN " ++ show current ++ "\n"))
            possibilities = [(expected, if current == P1 then allowedFrames else peerFrames,
                               if current == P2 then allowedFrames else peerFrames)
                            | peerFrames <- [rejected : incoming, incoming ++ [rejected]]]
        coordinator <- atomically (newCoordinator before)
        concurrentlySubmit coordinator [(current, Fire position), (forbidden, Fire forbiddenPosition)]
          `shouldReturn` [Right True, Right True]
        actual <- atomically (snapshot coordinator)
        actual `shouldSatisfy` (`elem` possibilities)

    it (show current ++ " alone fires over TCP, and the rejected shot remains unfired (20 sessions)") $
      forM_ [1 :: Int .. 20] $ \_ ->
        withServer $ \port server -> withPair port $ \first second -> do
          startMatch first second
          if current == P2 then do
            send first "FIRE J10\n"
            expectLine first "SHOT J10 MISS"
            expectLine second "INCOMING J10 MISS"
            expectTurns first second "P2"
          else pure ()
          let (shooter, peer, target, peerTarget) = if current == P1
                then (first, second, "A6", "A1") else (second, first, "A1", "A6")
              errorLine = "ERROR NOT_YOUR_TURN " ++ show current
          _ <- await "C-06 gated TCP sends" $ concurrentlyAtGate
            [send shooter ("FIRE " ++ target ++ "\n"), send peer ("FIRE " ++ peerTarget ++ "\n")]
          expectLine shooter ("SHOT " ++ target ++ " HIT")
          expectLine shooter ("TURN " ++ show current)
          replies <- sequence [readLine peer, readLine peer, readLine peer]
          replies `shouldSatisfy` (`elem` map (map b)
            [[errorLine, "INCOMING " ++ target ++ " HIT", "TURN " ++ show current],
             ["INCOMING " ++ target ++ " HIT", "TURN " ++ show current, errorLine]])
          -- Hit retains the turn. A later Miss deliberately releases it;
          -- the rejected coordinate must now produce a first Hit, not a repeat.
          send shooter "FIRE J9\n"
          expectLine shooter "SHOT J9 MISS"
          expectLine peer "INCOMING J9 MISS"
          expectTurns first second (show (otherPlayer current))
          send peer ("FIRE " ++ peerTarget ++ "\n")
          expectLine peer ("SHOT " ++ peerTarget ++ " HIT")
          expectLine shooter ("INCOMING " ++ peerTarget ++ " HIT")
          expectTurns first second (show (otherPlayer current))
          send peer "QUIT\n"
          expectFinal first second (show current) "OPPONENT_LEFT" server

  forM_ [P1, P2] $ \departing ->
    forM_ [False, True] $ \playing ->
      forM_ [False, True] $ \hardClose ->
        it (show departing ++ " leaves " ++ (if playing then "midgame" else "after placing while waiting") ++
            (if hardClose then " by close" else " by EOF") ++ " without hanging (5 sessions)") $
          forM_ [1 :: Int .. 5] $ \_ ->
            withServer $ \port server -> withPair port $ \first second -> do
              let (leaver, survivor) = if departing == P1 then (first, second) else (second, first)
              if playing then do
                startMatch first second
                send first "FIRE A6\n"
                expectLine first "SHOT A6 HIT"
                expectLine second "INCOMING A6 HIT"
                expectTurns first second "P1"
              else do
                send leaver ((if departing == P1 then place1 else place2) ++ "\n")
                expectLine leaver "OK PLACE"
                expectLine leaver "WAITING OPPONENT"
              if hardClose then close leaver else shutdown leaver ShutdownSend
              expectLine survivor ("GAME_OVER " ++ show (otherPlayer departing) ++ " OPPONENT_LEFT")
              expectClosed survivor
              if hardClose then pure () else do
                expectLine leaver ("GAME_OVER " ++ show (otherPlayer departing) ++ " OPPONENT_LEFT")
                expectClosed leaver
              await "C-06 server joins workers and closes listener" (wait server)

startMatch :: Socket -> Socket -> IO ()
startMatch first second = do
  send first (place1 ++ "\n")
  expectLine first "OK PLACE"
  expectLine first "WAITING OPPONENT"
  send second (place2 ++ "\n")
  expectLine second "OK PLACE"
  forM_ [first, second] $ \connection -> do
    expectLine connection "START P1"
    expectLine connection "TURN P1"

c07Spec :: Spec
c07Spec = describe "C-07 bounded atomic outboxes" $ do
  it "rejects capacities that cannot hold the largest normal batch and two terminal entries" $
    forM_ [0 .. 4] $ \capacity ->
      atomically (newCoordinatorWithCapacity capacity initialGameState) `shouldThrow` anyException

  it "holds exactly 126 normal frames, reserves two terminal slots and ignores later commands" $ do
    coordinator <- atomically (newCoordinator readyState)
    fillErrors coordinator P1 126
    atomically (queuedFrameCount coordinator P1) `shouldReturn` 126
    atomically (readGameState coordinator) `shouldReturn` readyState
    await "overflow cannot retry on a full queue" (atomically (submitPayload Rules.step coordinator P1 (b "UNKNOWN")))
      `shouldReturn` Right False
    atomically (queuedFrameCount coordinator P1) `shouldReturn` 128
    atomically (queuedFrameCount coordinator P2) `shouldReturn` 2
    forM_ [1 :: Int .. 1000] $ \_ ->
      atomically (submitCommand Rules.step coordinator P2 Quit) `shouldReturn` Right False
    atomically (snapshot coordinator) `shouldReturn`
      (quitState P1 readyState, replicate 126 errorFrame ++ endingFrames P2, endingFrames P2)

  it "aborts PLACE entirely when its two-frame batch is one slot short" $ do
    coordinator <- atomically (newCoordinatorWithCapacity 5 initialGameState)
    fillErrors coordinator P1 2
    atomically (submitCommand Rules.step coordinator P1 (PlaceFleet (placements 1))) `shouldReturn` Right False
    atomically (snapshot coordinator) `shouldReturn`
      (quitState P1 initialGameState, replicate 2 errorFrame ++ endingFrames P2, endingFrames P2)

  it "disconnects the overflowing recipient rather than the sender and never commits the shot" $ do
    coordinator <- atomically (newCoordinatorWithCapacity 5 readyState)
    fillErrors coordinator P2 2
    atomically (submitCommand Rules.step coordinator P1 (Fire (Coord 1 6))) `shouldReturn` Right False
    atomically ((,) <$> isSlowClient coordinator P1 <*> isSlowClient coordinator P2) `shouldReturn` (False, True)
    atomically (snapshot coordinator) `shouldReturn`
      (quitState P2 readyState, endingFrames P1, replicate 2 errorFrame ++ endingFrames P1)

  it "chooses P1 for a same-batch tie, marks both sockets and ends only once" $ do
    coordinator <- atomically (newCoordinatorWithCapacity 5 readyState)
    forM_ [P1, P2] $ \actor -> fillErrors coordinator actor 3
    atomically (submitCommand Rules.step coordinator P1 (Fire (Coord 1 6))) `shouldReturn` Right False
    atomically ((,) <$> isSlowClient coordinator P1 <*> isSlowClient coordinator P2) `shouldReturn` (True, True)
    forM_ [P1, P2] $ \actor -> atomically (submitCommand Rules.step coordinator actor Quit) `shouldReturn` Right False
    atomically (snapshot coordinator) `shouldReturn`
      (quitState P1 readyState, replicate 3 errorFrame ++ endingFrames P2, replicate 3 errorFrame ++ endingFrames P2)

  it "allows ordinary Quit at a full normal limit without marking either client slow" $ do
    coordinator <- atomically (newCoordinatorWithCapacity 5 readyState)
    forM_ [P1, P2] $ \actor -> fillErrors coordinator actor 3
    await "reserved terminal slots" (atomically (submitCommand Rules.step coordinator P2 Quit)) `shouldReturn` Right False
    atomically ((,) <$> isSlowClient coordinator P1 <*> isSlowClient coordinator P2) `shouldReturn` (False, False)
    atomically (snapshot coordinator) `shouldReturn`
      (quitState P2 readyState, replicate 3 errorFrame ++ endingFrames P1, replicate 3 errorFrame ++ endingFrames P1)

  forM_ [P1, P2] $ \actor ->
    it ("fits the final WIN batch exactly at capacity for " ++ show actor) $ do
      let before = fixture (fst <$> Rules.step actor (Fire (Coord 2 10)) (nearWin actor))
          (after, frames) = either (error . show) id (applyCommand Rules.step actor (Fire (Coord 5 6)) before)
          expected player = replicate 5 errorFrame ++ [Just bytes | (recipient, bytes) <- frames, recipient == player] ++ [Nothing]
      coordinator <- atomically (newCoordinatorWithCapacity 8 before)
      forM_ [P1, P2] $ \player -> fillErrors coordinator player 5
      atomically (submitCommand Rules.step coordinator actor (Fire (Coord 5 6))) `shouldReturn` Right False
      forM_ [P1, P2] $ \player -> do
        atomically (queuedFrameCount coordinator player) `shouldReturn` 8
        atomically (isSlowClient coordinator player) `shouldReturn` False
      atomically (snapshot coordinator) `shouldReturn` (after, expected P1, expected P2)

  it "does not commit a winning shot when its normal frame cannot fit" $ do
    let before = fixture (fst <$> Rules.step P1 (Fire (Coord 2 10)) (nearWin P1))
    coordinator <- atomically (newCoordinatorWithCapacity 8 before)
    forM_ [P1, P2] $ \actor -> fillErrors coordinator actor 6
    atomically (submitCommand Rules.step coordinator P1 (Fire (Coord 5 6))) `shouldReturn` Right False
    atomically (snapshot coordinator) `shouldReturn`
      (quitState P1 before, replicate 6 errorFrame ++ endingFrames P2, replicate 6 errorFrame ++ endingFrames P2)

  it "uses the injected core with the overloaded recipient and the exact pre-command state" $ do
    coordinator <- atomically (newCoordinatorWithCapacity 5 readyState)
    fillErrors coordinator P2 3
    let core P2 Quit state | state == readyState =
          Right (state { gamePhase = Finished P2 AllShipsSunk }, [GameEnded P2 AllShipsSunk])
        core actor command state = Rules.step actor command state
    atomically (submitCommand core coordinator P1 (Fire (Coord 1 6))) `shouldReturn` Right False
    let final = [Just (b "GAME_OVER P2 ALL_SHIPS_SUNK\n"), Nothing]
    atomically (snapshot coordinator) `shouldReturn`
      (readyState { gamePhase = Finished P2 AllShipsSunk }, final, replicate 3 errorFrame ++ final)

  it "handles an overlong-line rejection through the same nonblocking overflow policy" $ do
    coordinator <- atomically (newCoordinatorWithCapacity 5 readyState)
    fillErrors coordinator P1 3
    await "overlong rejection at capacity" (atomically (submitTooLong Rules.step coordinator P1)) `shouldReturn` Right False
    atomically (snapshot coordinator) `shouldReturn`
      (quitState P1 readyState, replicate 3 errorFrame ++ endingFrames P2, endingFrames P2)

  it "wakes a writer waiting on an empty opposing queue when overload ends the game" $ do
    coordinator <- atomically (newCoordinatorWithCapacity 5 readyState)
    atomically ((Just <$> nextFrame coordinator P2) `orElse` pure Nothing) `shouldReturn` Nothing
    withAsync (atomically (nextFrame coordinator P2)) $ \writer -> do
      fillErrors coordinator P1 3
      atomically (submitPayload Rules.step coordinator P1 (b "UNKNOWN")) `shouldReturn` Right False
      await "waiting writer wakes" (wait writer) `shouldReturn` Just (frame (GameOver P2 OpponentLeft))
      atomically (nextFrame coordinator P2) `shouldReturn` Nothing

  forM_ ["throws", "retries"] $ \mode ->
    it ("rolls back state, all frames and slow flags when an outer transaction " ++ mode) $ do
      coordinator <- atomically (newCoordinatorWithCapacity 5 readyState)
      fillErrors coordinator P1 3
      let overflow = submitPayload Rules.step coordinator P1 (b "UNKNOWN")
      if mode == "throws" then
        atomically (overflow >> throwSTM (AssertionFailed "rollback")) `shouldThrow` anyException
      else atomically ((overflow >> retry) `orElse` pure ())
      atomically ((,) <$> isSlowClient coordinator P1 <*> isSlowClient coordinator P2) `shouldReturn` (False, False)
      atomically (snapshot coordinator) `shouldReturn` (readyState, replicate 3 errorFrame, [])

  forM_ ["missing", "duplicate", "nonterminal", "refused"] $ \malformation ->
    it ("rejects a " ++ malformation ++ " terminal core without consuming reserved slots") $ do
      coordinator <- atomically (newCoordinatorWithCapacity 5 readyState)
      fillErrors coordinator P1 3
      let core _ Quit state = case malformation of
            "missing" -> Right (state { gamePhase = Finished P2 OpponentLeft }, [])
            "duplicate" -> Right (state { gamePhase = Finished P2 OpponentLeft }, replicate 2 (GameEnded P2 OpponentLeft))
            "nonterminal" -> Right (state, [GameEnded P2 OpponentLeft])
            _ -> Left FleetsNotReady
          core actor command state = Rules.step actor command state
      await "malformed fallback cannot fill queue" (atomically (submitPayload core coordinator P1 (b "UNKNOWN")))
        `shouldReturn` Left InvalidMessage
      atomically (isSlowClient coordinator P1) `shouldReturn` False
      atomically (snapshot coordinator) `shouldReturn` (readyState, replicate 3 errorFrame, [])

  forM_ [P1, P2] $ \actor ->
    it ("serializes two near-limit hits without partial batches or duplicate endings for " ++ show actor ++ " (100 races)") $
      forM_ [1 :: Int .. 100] $ \_ -> do
        let before = if actor == P1 then readyState else fixture (fst <$> Rules.step P1 (Fire (Coord 10 10)) readyState)
            row = if actor == P1 then 6 else 1
            commands = [(actor, Fire (Coord column row)) | column <- [1, 2]]
            expected command =
              let (after, frames) = either (error . show) id (applyCommand Rules.step actor command before)
                  own player = replicate 3 errorFrame ++ [Just bytes | (recipient, bytes) <- frames, recipient == player] ++ endingFrames P2
              in (quitState P1 after, own P1, own P2)
        coordinator <- atomically (newCoordinatorWithCapacity 8 before)
        forM_ [P1, P2] $ \player -> fillErrors coordinator player 3
        results <- concurrentlySubmit coordinator commands
        sort (map (either (error . show) id) results) `shouldBe` [False, True]
        forM_ [P1, P2] $ \player -> do
          atomically (queuedFrameCount coordinator player) `shouldReturn` 7
          atomically (isSlowClient coordinator player) `shouldReturn` True
        actual <- atomically (snapshot coordinator)
        actual `shouldSatisfy` (`elem` map (expected . snd) commands)

  it "identifies P2 under concurrent near-limit commands from different players (100 races)" $
    forM_ [1 :: Int .. 100] $ \_ -> do
      coordinator <- atomically (newCoordinatorWithCapacity 8 readyState)
      fillErrors coordinator P2 6
      concurrentlySubmit coordinator [(P1, Fire (Coord 1 6)), (P2, Fire (Coord 1 1))]
        `shouldReturn` [Right False, Right False]
      atomically ((,) <$> isSlowClient coordinator P1 <*> isSlowClient coordinator P2) `shouldReturn` (False, True)
      atomically (snapshot coordinator) `shouldReturn`
        (quitState P2 readyState, endingFrames P1, replicate 6 errorFrame ++ endingFrames P1)

fillErrors :: Coordinator -> PlayerId -> Int -> IO ()
fillErrors coordinator actor count = forM_ [1 .. count] $ \_ ->
  atomically (submitPayload Rules.step coordinator actor (b "UNKNOWN")) `shouldReturn` Right True

errorFrame :: Maybe BSC.ByteString
errorFrame = Just (frame (Rejected BadCommand))

endingFrames :: PlayerId -> [Maybe BSC.ByteString]
endingFrames winner = [Just (frame (GameOver winner OpponentLeft)), Nothing]

quitState :: PlayerId -> GameState -> GameState
quitState actor state = fixture (fst <$> Rules.step actor Quit state)

-- Both workers reach the gate before it opens. No external gameplay lock is
-- introduced: only STM serializes submissions, and network IO stays outside it.
concurrentlySubmit :: Coordinator -> [(PlayerId, Command)] -> IO [Either ProtocolError Bool]
concurrentlySubmit coordinator commands = concurrentlyAtGate
  [atomically (submitCommand Rules.step coordinator actor command) | (actor, command) <- commands]

concurrentlyAtGate :: [IO a] -> IO [a]
concurrentlyAtGate actions = do
  gate <- newEmptyTMVarIO
  started <- newTVarIO (0 :: Int)
  let worker action = do
        atomically (modifyTVar' started (+ 1))
        atomically (readTMVar gate)
        action
  withAsync (mapConcurrently worker actions) $ \workers -> do
    await "concurrent workers reached gate" $ atomically $ do
      count <- readTVar started
      check (count == length actions)
      putTMVar gate ()
    await "concurrent actions completed" (wait workers)

type Snapshot = (GameState, [Maybe BSC.ByteString], [Maybe BSC.ByteString])

snapshot :: Coordinator -> STM Snapshot
snapshot coordinator = (,,) <$> readGameState coordinator <*> drain P1 <*> drain P2
  where
    drain player = do
      queued <- (Just <$> nextFrame coordinator player) `orElse` pure Nothing
      case queued of
        Nothing -> pure []
        Just frameValue -> (frameValue :) <$> drain player

serialSnapshots :: [(PlayerId, Command)] -> [Snapshot]
serialSnapshots commands = map simulate [commands, reverse commands]
  where
    simulate order = case foldM (\(state, previous) (actor, command) -> do
      (next, frames) <- applyCommand Rules.step actor command state
      pure (next, previous ++ frames)) (readyState, []) order of
        Left fault -> error (show fault)
        Right (state, frames) -> (state, recipient P1 frames, recipient P2 frames)
    recipient player frames = [Just bytes | (actor, bytes) <- frames, actor == player]

-- Test doubles emit distinctive outcomes to identify the injected core. They
-- do not detect hits/sunk/victory. Production always uses Rules.step.
unusedCore :: Step
unusedCore _ _ _ = error "parser failure must not invoke Step"

countingStub :: Step
countingStub P2 (Fire position) state
  | position == Coord 10 10 =
      let previous = playerShots (gamePlayer2 state)
          isSecond = Map.lookup position previous == Just Hit
          outcome = if isSecond then Win else Hit
          phase = if isSecond then Finished P2 AllShipsSunk else Turn P2
          events = if isSecond then [GameEnded P2 AllShipsSunk] else [TurnReady P2]
          next = setPlayerState P2 ((gamePlayer2 state) { playerShots = Map.insert position outcome previous }) state
      in Right (next { gamePhase = phase }, ShotResolved P2 position outcome : events)
countingStub actor command state = Rules.step actor command state

eofStub :: Step
eofStub P2 Quit state = Right (state { gamePhase = Finished P2 AllShipsSunk }, [GameEnded P2 AllShipsSunk])
eofStub actor command state = Rules.step actor command state

badEventStub :: Step
badEventStub _ (Fire _) state = Right (state { gamePhase = Turn P2 },
  [TurnReady P2, ShotResolved P1 (Coord 11 1) Hit])
badEventStub actor command state = Rules.step actor command state

readyState :: GameState
readyState = fixture $ do
  (placed, _) <- Rules.step P1 (PlaceFleet (placements 1)) initialGameState
  fst <$> Rules.step P2 (PlaceFleet (placements 6)) placed

-- Real step calls create the history, leaving DD B10 and CV E6 unshot.
nearWin :: PlayerId -> GameState
nearWin actor = fixture $ do
  (first, _) <- Rules.step P1 (PlaceFleet (placements 6)) initialGameState
  (ready, _) <- Rules.step P2 (PlaceFleet (placements 6)) first
  active <- if actor == P1 then pure ready else fst <$> Rules.step P1 (Fire (Coord 10 10)) ready
  foldM (\state position -> fst <$> Rules.step actor (Fire position) state)
    active
    [Coord column row | (row, width) <- [(6, 5), (7, 4), (8, 3), (9, 3), (10, 2)],
                       column <- [1 .. width], Coord column row `notElem` [Coord 2 10, Coord 5 6]]

fixture :: Either GameError GameState -> GameState
fixture = either (error . ("invalid test fixture: " ++) . show) id

placements :: Int -> FleetPlacement
placements row = zipWith (\ship offset -> ShipPlacement ship (Coord 1 (row + offset)) Horizontal)
  [Carrier, Battleship, Cruiser, Submarine, Destroyer] [0 .. 4]

place1, place2 :: String
place1 = "PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H"
place2 = "PLACE CV=A6:H;BB=A7:H;CR=A8:H;SB=A9:H;DD=A10:H"

withCore :: Step -> GameState -> (PortNumber -> Async () -> IO a) -> IO a
withCore core initial action = withSocketsDo $ do
  ready <- newEmptyMVar
  withAsync (runServerWith core initial 0 (putMVar ready)) $ \server -> do
    startup <- await "C-03 startup" (race (readMVar ready) (wait server))
    case startup of
      Left port -> action port server
      Right () -> ioError (userError "C-03 stopped before listen")

withPair :: PortNumber -> (Socket -> Socket -> IO a) -> IO a
withPair port action = withClient port $ \first -> do
  expectLine first "WELCOME 1 P1"
  withClient port $ \second -> do
    expectLine second "WELCOME 1 P2"
    action first second

placementStarted :: Socket -> IO ()
placementStarted connection = do
  expectLine connection "OK PLACE"
  next <- readLine connection
  if next == b "WAITING OPPONENT" then expectLine connection "START P1"
  else next `shouldBe` b "START P1"
  expectLine connection "TURN P1"

expectTurns :: Socket -> Socket -> String -> IO ()
expectTurns first second player = mapM_ (\connection -> expectLine connection ("TURN " ++ player)) [first, second]

expectFinal :: Socket -> Socket -> String -> String -> Async () -> IO ()
expectFinal first second winner reason server = do
  forM_ [first, second] $ \connection -> do
    expectLine connection ("GAME_OVER " ++ winner ++ " " ++ reason)
    expectClosed connection
  await "C-03 server exit" (wait server)

send :: Socket -> String -> IO ()
send connection = sendAll connection . b

b :: String -> BSC.ByteString
b = BSC.pack

frame :: Response -> BSC.ByteString
frame response = either (error . ("invalid response fixture: " ++) . show) id (encodeResponse response)
