module CoordinatorSpec (spec) where

import Battleship.Coordinator
import Battleship.Protocol
import qualified Battleship.Rules as Rules
import Battleship.Server (runServerWith)
import Battleship.Types
import Control.Concurrent.Async (Async, mapConcurrently_, race, wait, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (SomeException)
import Control.Monad (foldM, forM_)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map.Strict as Map
import Data.List (isInfixOf, sort)
import Network.Socket (PortNumber, ShutdownCmd (ShutdownSend), Socket, shutdown, withSocketsDo)
import Network.Socket.ByteString (sendAll)
import ServerSpec (await, expectClosed, expectLine, readLine, withClient, withServer)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldThrow)

spec :: Spec
spec = describe "C-03 Coordinator" $ do
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
  foldM (\state position -> fst <$> Rules.step actor (Fire position) state)
    (ready { gamePhase = Turn actor })
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
