module ProtocolSpec (spec) where

-- Golden vectors/transcripts from D-01, now exercising the D-02 production API.
import Battleship.Protocol
import Battleship.Types
import Control.Monad (foldM, forM_)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (chr, ord)
import Data.Either (isRight)
import Data.List (dropWhileEnd, isInfixOf, permutations, sortOn, stripPrefix)
import Paths_battleship_haskell (getDataFileName)
import Test.Hspec
  ( Spec, beforeAll, describe, expectationFailure, it, shouldBe, shouldSatisfy )

spec :: Spec
spec = describe "D-01/D-02 production protocol" $ do
  describe "coordinate grammar" $ do
    it "accepts all 100 coordinates and maps to the one-based A-01 Coord" $
      forM_ [(column, row) | column <- [1 .. 10], row <- [1 .. 10]] $
        \(column, row) ->
          parseCoordText ([chr (ord 'A' + column - 1)] ++ show row)
            `shouldBe` Just (Coord column row)

    forM_ ["", "A0", "A11", "K1", "a1", "A01", "AA1", "1A", "A-1", "A+1"] $
      \coordinate -> it ("rejects " ++ show coordinate) $
        parseCoordText coordinate `shouldBe` Nothing

  describe "command grammar" $ do
    it "maps the complete canonical PLACE to A-01 placements" $
      parseCommandText firstPlace `shouldBe` Right (PlaceFleet firstPlacements)

    it "accepts another ship order without reordering the request" $
      parseCommandText reversedPlace `shouldBe` Right (PlaceFleet (reverse firstPlacements))

    it "preserves a duplicate ID for Board to reject instead of overwriting it" $
      parseCommandText "PLACE CV=A1:H;CV=A2:H" `shouldBe`
        Right (PlaceFleet [ShipPlacement Carrier (Coord 1 1) Horizontal,
                           ShipPlacement Carrier (Coord 1 2) Horizontal])

    it "leaves fleet count and placement geometry to Board/Rules" $
      parseCommandText "PLACE CV=J10:H" `shouldBe`
        Right (PlaceFleet [ShipPlacement Carrier (Coord 10 10) Horizontal])

    it "accepts vertical placements" $
      parseCommandText "PLACE DD=J9:V" `shouldBe`
        Right (PlaceFleet [ShipPlacement Destroyer (Coord 10 9) Vertical])

    forM_ [("FIRE A1", Fire (Coord 1 1)), ("FIRE J10", Fire (Coord 10 10)),
           ("QUIT", Quit)] $ \(payload, expected) ->
      it ("parses " ++ payload) $ parseCommandText payload `shouldBe` Right expected

    forM_ ["", "fire A1", "FIRE", "FIRE A1 EXTRA", " FIRE A1", "FIRE A1 ",
           "FIRE  A1", "FIRE\tA1", "P1 FIRE A1", "QUIT P1", "PLACE",
           "PLACE XX=A1:H", "PLACE CV=A1:X", "PLACE CV=A1:H;",
           "PLACE CV=A1:H;;BB=A2:H", "PLACE CV==A1:H", "PLACE CV=A1:H:H",
           "PLACE CV =A1:H", "FIRE A1\nQUIT", "FIRE A1\0", "BẮN A1"] $
      \payload -> it ("rejects malformed command " ++ show payload) $
        parseCommandText payload `shouldSatisfy` isInvalidCommand

    forM_ ["FIRE K1", "FIRE A01", "FIRE A0", "PLACE CV=A11:H"] $
      \payload -> it ("classifies coordinate error " ++ payload) $
        parseCommandText payload `shouldBe` Left InvalidCoordinateToken

  describe "server grammar" $ do
    forM_ ["WELCOME P1", "WELCOME 2 P1", "WELCOME 1 P3", "START P2",
           "OK QUIT", "WAITING", "WAITING FLEET", "TURN P3", "SHOT K1 HIT",
           "SHOT A1 SUNK", "SHOT A1 SUNK XX", "SHOT A1 HIT CV",
           "INCOMING A1 WIN CV", "GAME_OVER P1", "GAME_OVER P1 DRAW",
           "ERROR UNKNOWN", "ERROR NOT_YOUR_TURN", "ERROR INVALID_FLEET_SIZE -1",
           "ERROR INVALID_FLEET_SIZE 04", "ERROR INVALID_FLEET_SIZE 257",
           "ERROR INVALID_COMMAND raw", "FLEET CV=A1:H", "TURN  P1"] $
      \payload -> it ("rejects malformed response " ++ show payload) $
        validResponseText payload `shouldBe` False

    forM_ errorExamples $ \(gameError, expectedWire) ->
      it ("maps A-01 error to " ++ expectedWire) $ do
        renderErrorWire gameError `shouldBe` expectedWire
        validResponseText expectedWire `shouldBe` True

    forM_ [P1, P2] $ \shooter ->
      forM_ [Miss, Hit, Sunk Destroyer, Win] $ \outcome ->
        it ("routes " ++ show outcome ++ " separately for shooter " ++ show shooter) $ do
          let result = routeShotWire shooter (Coord 2 10) outcome
          result `shouldBe`
            [(shooter, "SHOT B10 " ++ outcomeLabel outcome),
             (otherPlayer shooter, "INCOMING B10 " ++ outcomeLabel outcome)]
          map snd result `shouldSatisfy` all validResponseText

  describe "byte framing" $ do
    it "splits coalesced messages and keeps an incomplete tail" $
      feedChunks [BSC.pack "FIRE A1\nQUIT\nFIRE B"] `shouldBe`
        Right ([BSC.pack "FIRE A1", BSC.pack "QUIT"], BSC.pack "FIRE B")

    it "does not emit a command until LF arrives" $
      feedChunks [BSC.pack "FIRE A1"] `shouldBe` Right ([], BSC.pack "FIRE A1")

    it "accepts CRLF and CR/LF split between recv calls" $
      feedChunks [BSC.pack "FIRE A1\r", BSC.pack "\nQUIT\n"] `shouldBe`
        Right ([BSC.pack "FIRE A1", BSC.pack "QUIT"], BS.empty)

    it "gives the same frames at every possible two-chunk split" $ do
      let stream = BSC.pack (firstPlace ++ "\r\nFIRE A1\nQUIT\n")
          expected = Right (map BSC.pack [firstPlace, "FIRE A1", "QUIT"], BS.empty)
      forM_ [0 .. BS.length stream] $ \offset ->
        feedChunks [BS.take offset stream, BS.drop offset stream] `shouldBe` expected

    it "accepts exactly 256 payload bytes with LF or CRLF" $
      forM_ ["\n", "\r\n"] $ \ending ->
        feedChunks [BS.replicate 256 65 <> BSC.pack ending]
          `shouldBe` Right ([BS.replicate 256 65], BS.empty)

    it "allows the extra pending CR at the exact limit" $
      feedChunks [BS.replicate 256 65 <> BSC.pack "\r", BSC.pack "\n"]
        `shouldBe` Right ([BS.replicate 256 65], BS.empty)

    it "rejects byte 257 without waiting for a newline" $
      feedChunks [BS.replicate 256 65, BSC.pack "B"] `shouldBe` Left LineTooLong

    it "rejects a completed oversized line" $
      feedChunks [BS.replicate 257 65 <> BSC.pack "\n"] `shouldBe` Left LineTooLong

    it "counts UTF-8 bytes rather than characters before validating grammar" $
      feedChunks [BS.pack (concat (replicate 129 [0xc3, 0xa9])) <> BSC.pack "\n"]
        `shouldBe` Left LineTooLong

    forM_ [BSC.pack "FIRE\tA1\n", BSC.pack "FIRE A1\0\n",
           BSC.pack "FIRE A1\rX\n", BS.pack [0xff, 10], BS.pack [0xc3, 0xa9, 10]] $
      \bytes -> it ("rejects control or non-ASCII frame " ++ show bytes) $
        case feedChunks [bytes] of
          Right ([payload], pending) -> do
            pending `shouldBe` BS.empty
            parseCommandText (BSC.unpack payload) `shouldSatisfy` isInvalidCommand
          result -> expectationFailure ("Unexpected framing: " ++ show result)

    it "rejects a malformed line without losing the following valid command" $
      case feedChunks [BSC.pack "FIRE\tA1\nFIRE A1\n"] of
        Right (payloads, pending) -> do
          pending `shouldBe` BS.empty
          map (parseCommandText . BSC.unpack) payloads `shouldBe`
            [Left syntaxError, Right (Fire (Coord 1 1))]
        result -> expectationFailure ("Unexpected framing: " ++ show result)

  describe "encoder and typed round trips" $ do
    it "encodes/decodes every coordinate and FIRE with one final LF" $
      forM_ [Coord column row | column <- [1 .. 10], row <- [1 .. 10]] $ \coordinate -> do
        let token = [chr (ord 'A' + coordColumn coordinate - 1)] ++ show (coordRow coordinate)
        encodeCoord coordinate `shouldBe` Right (BSC.pack token)
        encodeCommand (Fire coordinate) `shouldBe` Right (BSC.pack ("FIRE " ++ token ++ "\n"))
        parseCommand (BSC.pack ("FIRE " ++ token)) `shouldBe` Right (Fire coordinate)

    it "uses canonical CV/BB/CR/SB/DD order for all 120 fleet permutations" $
      forM_ (permutations firstPlacements) $ \placements -> do
        encodeCommand (PlaceFleet placements) `shouldBe` Right (BSC.pack (firstPlace ++ "\n"))
        parseCommandText (frameText (encodeCommand (PlaceFleet placements)))
          `shouldBe` Right (PlaceFleet (sortOn placementShip placements))

    it "retains duplicates and incomplete fleets during command encoding" $ do
      let placements = [ShipPlacement Destroyer (Coord 10 9) Vertical,
                        ShipPlacement Carrier (Coord 1 1) Horizontal,
                        ShipPlacement Carrier (Coord 1 2) Horizontal]
      encodeCommand (PlaceFleet placements) `shouldBe` Right (BSC.pack "PLACE CV=A1:H;CV=A2:H;DD=J9:V\n")
      parseCommandText (frameText (encodeCommand (PlaceFleet placements)))
        `shouldBe` Right (PlaceFleet (sortOn placementShip placements))

    it "encodes QUIT exactly and refuses an empty PLACE" $ do
      encodeCommand Quit `shouldBe` Right (BSC.pack "QUIT\n")
      encodeCommand (PlaceFleet []) `shouldBe` Left InvalidMessage

    it "refuses encoded commands that exceed the wire byte limit" $
      encodeCommand (PlaceFleet (replicate 40 (ShipPlacement Carrier (Coord 1 1) Horizontal))) `shouldBe` Left LineTooLong

    it "round-trips every bounded count and rejects noncanonical count tokens" $ do
      forM_ [0 .. 256] $ \count -> do
        let response = Rejected (FleetSize count)
        encodeResponse response `shouldBe` Right (BSC.pack ("ERROR INVALID_FLEET_SIZE " ++ show count ++ "\n"))
        parseResponse (BSC.pack ("ERROR INVALID_FLEET_SIZE " ++ show count)) `shouldBe` Right response
      forM_ ["-1", "257", "01", "+1", "1.0", replicate 200 '9'] $ \count ->
        parseResponse (BSC.pack ("ERROR INVALID_FLEET_SIZE " ++ count)) `shouldBe` Left InvalidMessage

    forM_ [-1, 257, minBound, maxBound] $ \count ->
      it ("refuses encoding out-of-range count " ++ show count) $
        encodeResponse (Rejected (FleetSize count)) `shouldBe` Left InvalidMessage

    forM_ [Coord 0 1, Coord 1 0, Coord 11 10, Coord 10 11,
           Coord minBound maxBound, Coord maxBound minBound] $ \coordinate ->
      it ("refuses unsafe coordinate encoding " ++ show coordinate) $ do
        encodeCoord coordinate `shouldBe` Left InvalidCoordinateToken
        encodeCommand (Fire coordinate) `shouldBe` Left InvalidCoordinateToken
        encodeCommand (PlaceFleet [ShipPlacement Carrier coordinate Horizontal]) `shouldBe` Left InvalidCoordinateToken
        forM_ [Shot coordinate Miss, Incoming coordinate Hit,
               Rejected (Overlap coordinate), Rejected (RepeatedShot coordinate)] $ \response ->
          encodeResponse response `shouldBe` Left InvalidCoordinateToken

    it "does not encode START P2 or reveal raw error/debug data" $ do
      encodeResponse (Start P2) `shouldBe` Left InvalidMessage
      encodeEvent (Turn P2) (GameStarted P2) `shouldBe` Left InvalidMessage
      encodeResponse (Rejected (wireError (InvalidCommand "bí mật\nQUIT")))
        `shouldBe` Right (BSC.pack "ERROR INVALID_COMMAND\n")

    it "validates length before grammar and requires payloads without terminators" $ do
      parseCommand (BS.replicate 257 0) `shouldBe` Left LineTooLong
      parseResponse (BS.replicate 257 0) `shouldBe` Left LineTooLong
      parseCommandText ("FIRE " ++ replicate 251 'A') `shouldBe` Left InvalidCoordinateToken
      forM_ ["QUIT\n", "QUIT\r\n"] $ \payload -> parseCommandText payload `shouldBe` Left InvalidMessage
      forM_ ["TURN P1\n", "TURN P1\r\n", "TURN\tP1", "TURN P1\0"] $ \payload ->
        parseResponse (BSC.pack payload) `shouldBe` Left InvalidMessage
      parseResponse (BSC.pack "WELCOME 2 P1") `shouldBe` Left UnsupportedVersion

    it "keeps PLACE error priority: structure/ID, coordinate, then orientation" $ do
      forM_ ["PLACE XX=K1:X", "PLACE CV=K1:X:V", "PLACE CV==K1:X"] $ \payload ->
        parseCommandText payload `shouldBe` Left InvalidMessage
      parseCommandText "PLACE CV=K1:X" `shouldBe` Left InvalidCoordinateToken
      parseCommandText "PLACE CV=A1:X" `shouldBe` Left InvalidMessage

    it "routes placement, start, turns and game end in the documented order" $ do
      encodeEvent Placing (FleetAccepted P1) `shouldBe` Right
        [(P1, BSC.pack "OK PLACE\n"), (P1, BSC.pack "WAITING OPPONENT\n")]
      let events = [FleetAccepted P2, GameStarted P1, TurnReady P1]
      fmap concat (traverse (encodeEvent (Turn P1)) events) `shouldBe` Right
        [(P2, BSC.pack "OK PLACE\n"), (P1, BSC.pack "START P1\n"), (P2, BSC.pack "START P1\n"),
         (P1, BSC.pack "TURN P1\n"), (P2, BSC.pack "TURN P1\n")]
      forM_ [P1, P2] $ \winner -> forM_ [AllShipsSunk, OpponentLeft] $ \reason ->
        routeEvent (Finished winner reason) (GameEnded winner reason)
          `shouldBe` [(P1, GameOver winner reason), (P2, GameOver winner reason)]

    it "round-trips every typed response family, player, ship, reason and outcome" $ do
      let responses = [Welcome player | player <- [P1, P2]] ++ [PlaceOK, WaitingOpponent, Start P1] ++
            [TurnOf player | player <- [P1, P2]] ++
            [constructor coordinate outcome | constructor <- [Shot, Incoming],
             coordinate <- [Coord 1 1, Coord 10 10], outcome <- [Miss, Hit, Win] ++ map Sunk [minBound .. maxBound]] ++
            [GameOver player reason | player <- [P1, P2], reason <- [AllShipsSunk, OpponentLeft]] ++
            map (Rejected . wireError . fst) errorExamples ++ [Rejected TooLong, Rejected ServerFull] ++
            [Rejected (constructor ship) | constructor <- [Missing, Duplicate, OutOfBounds], ship <- [minBound .. maxBound]]
      forM_ responses $ \response ->
        parseResponse (BSC.pack (frameText (encodeResponse response))) `shouldBe` Right response

    it "preserves frames completed before an overlong later frame" $
      feedFrames BS.empty (BSC.pack "QUIT\nFIRE A1\n" <> BS.replicate 257 65)
        `shouldBe` ([BSC.pack "QUIT", BSC.pack "FIRE A1"], Left LineTooLong)

    it "frames byte-by-byte input and rejects invalid externally supplied pending buffers" $ do
      feedChunks (map BS.singleton (BS.unpack (BSC.pack "QUIT\r\nFIRE J10\n")))
        `shouldBe` Right ([BSC.pack "QUIT", BSC.pack "FIRE J10"], BS.empty)
      feedFrames (BS.replicate 257 65) BS.empty `shouldBe` ([], Left LineTooLong)
      feedFrames (BSC.pack "QUIT\n") BS.empty `shouldBe` ([], Left InvalidMessage)

  beforeAll (getDataFileName "docs/protocol.md" >>= readFile) $
    describe "document fixtures and transcripts" $ do
      it "publishes the same version and byte limit as the reference grammar" $ \document -> do
        document `shouldSatisfy` isInfixOf "MAX_LINE_BYTES = 256"
        document `shouldSatisfy` isInfixOf "WELCOME 1 P1"

      it "all published command vectors parse as A-01 commands" $ \document ->
        checkBlock document "contract:commands" $ \payloads -> do
          payloads `shouldSatisfy` (not . null)
          forM_ payloads $ \payload -> parseCommandText payload `shouldSatisfy` isRight

      it "all response vectors are valid and cover every A-01 error mapping" $ \document ->
        checkBlock document "contract:responses" $ \payloads -> do
          payloads `shouldSatisfy` (not . null)
          forM_ payloads $ \payload -> validResponseText payload `shouldBe` True
          forM_ errorExamples $ \(_, wire) -> payloads `shouldSatisfy` elem wire

      it "encodes every published response vector to its exact LF frame" $ \document ->
        checkBlock document "contract:responses" $ \payloads -> forM_ payloads $ \payload ->
          (parseResponse (BSC.pack payload) >>= encodeResponse) `shouldBe` Right (BSC.pack (payload ++ "\n"))

      forM_ ["connect-first-shot", "miss", "sunk", "win", "quit", "disconnect", "server-full"] $ \name ->
        it ("parses and encodes all rows in transcript " ++ name) $ \document ->
          checkBlock document ("transcript:" ++ name) $ \rows -> forM_ rows checkEncodedTranscriptRow

      it "classifies the deliberately invalid commands in the error/retry transcript" $ \document ->
        checkBlock document "transcript:errors-and-retry" $ \rows -> do
          forM_ [payload | row <- rows, Just payload <- [stripPrefix "C1 -> S: " row]] $ \payload ->
            parseCommandText payload `shouldBe` case payload of
              "FIRE K1" -> Left InvalidCoordinateToken
              "fire B6" -> Left InvalidMessage
              "FIRE A6" -> Right (Fire (Coord 1 6))
              "FIRE B6" -> Right (Fire (Coord 2 6))
              _ -> Left InvalidMessage
          forM_ [payload | row <- rows, prefix <- ["S -> C1: ", "S -> C2: "],
                           Just payload <- [stripPrefix prefix row]] $ \payload ->
            (parseResponse (BSC.pack payload) >>= encodeResponse) `shouldBe` Right (BSC.pack (payload ++ "\n"))

      it "freezes connection, placement acknowledgements and the first HIT in order" $ \document ->
        checkBlock document "transcript:connect-first-shot" $ \rows -> do
          rows `shouldBe` firstShotTranscript
          forM_ rows checkTranscriptRow

      it "freezes actor-only errors followed by a successful retry" $ \document ->
        checkBlock document "transcript:errors-and-retry" $ \rows ->
          rows `shouldBe`
            ["C2 -> S: FIRE J10", "S -> C2: ERROR NOT_YOUR_TURN P1",
             "C1 -> S: FIRE K1", "S -> C1: ERROR INVALID_COORDINATE",
             "C1 -> S: FIRE A6", "S -> C1: ERROR ALREADY_FIRED A6",
             "C1 -> S: fire B6", "S -> C1: ERROR INVALID_COMMAND",
             "C1 -> S: FIRE B6", "S -> C1: SHOT B6 HIT",
             "S -> C2: INCOMING B6 HIT", "S -> C1: TURN P1", "S -> C2: TURN P1"]

      forM_ [("miss", "J10", Miss, "TURN P2"),
             ("sunk", "B10", Sunk Destroyer, "TURN P1"),
             ("win", "B10", Win, "GAME_OVER P1 ALL_SHIPS_SUNK")] $
        \(name, coordinate, outcome, following) ->
          it ("publishes correct routing/next message for " ++ name) $ \document ->
            checkBlock document ("transcript:" ++ name) $ \rows -> do
              rows `shouldBe`
                ["C1 -> S: FIRE " ++ coordinate,
                 "S -> C1: SHOT " ++ coordinate ++ " " ++ outcomeLabel outcome,
                 "S -> C2: INCOMING " ++ coordinate ++ " " ++ outcomeLabel outcome,
                 "S -> C1: " ++ following, "S -> C2: " ++ following]
              forM_ rows checkTranscriptRow

      forM_ [("quit", ["C2 -> S: QUIT", "S -> C1: GAME_OVER P1 OPPONENT_LEFT",
                        "S -> C2: GAME_OVER P1 OPPONENT_LEFT"]),
             ("disconnect", ["S -> C1: GAME_OVER P1 OPPONENT_LEFT"]),
             ("server-full", ["S -> C3: ERROR SERVER_FULL"])] $ \(name, expected) ->
        it ("publishes terminal handling for " ++ name) $ \document ->
          checkBlock document ("transcript:" ++ name) $ \rows -> do
            rows `shouldBe` expected
            forM_ rows checkTranscriptRow

-- Small text/frame adapters only; no second test-only grammar or encoder.
parseCoordText :: String -> Maybe Coord
parseCoordText = either (const Nothing) Just . parseCoord . BSC.pack

parseCommandText :: String -> Either ProtocolError Command
parseCommandText = parseCommand . BSC.pack

syntaxError :: ProtocolError
syntaxError = InvalidMessage

validResponseText :: String -> Bool
validResponseText = isRight . parseResponse . BSC.pack

shipLabel :: ShipId -> String
shipLabel Carrier = "CV"
shipLabel Battleship = "BB"
shipLabel Cruiser = "CR"
shipLabel Submarine = "SB"
shipLabel Destroyer = "DD"

outcomeLabel :: Outcome -> String
outcomeLabel Miss = "MISS"
outcomeLabel Hit = "HIT"
outcomeLabel (Sunk ship) = "SUNK " ++ shipLabel ship
outcomeLabel Win = "WIN"

renderErrorWire :: GameError -> String
renderErrorWire = frameText . encodeResponse . Rejected . wireError

routeShotWire :: PlayerId -> Coord -> Outcome -> [(PlayerId, String)]
routeShotWire shooter coordinate outcome = case encodeEvent (Turn shooter) (ShotResolved shooter coordinate outcome) of
  Right recipients -> [(player, BSC.unpack (BS.init bytes)) | (player, bytes) <- recipients]
  Left fault -> error ("Invalid shot fixture: " ++ show fault)

feedChunks :: [BS.ByteString] -> Either ProtocolError ([BS.ByteString], BS.ByteString)
feedChunks = foldM feed ([], BS.empty)
  where
    feed (previous, pending) chunk = do
      let (complete, next) = feedFrames pending chunk
      remaining <- next
      pure (previous ++ complete, remaining)

frameText :: Either ProtocolError BS.ByteString -> String
frameText (Right bytes) = BSC.unpack (BS.init bytes)
frameText (Left fault) = error ("Invalid encoding fixture: " ++ show fault)

isInvalidCommand :: Either ProtocolError Command -> Bool
isInvalidCommand (Left InvalidMessage) = True
isInvalidCommand _ = False

checkBlock :: String -> String -> ([String] -> IO ()) -> IO ()
checkBlock document marker check = case dropWhile (/= "<!-- " ++ marker ++ " -->") normalizedLines of
  _ : "```text" : rest -> case break (== "```") rest of
    (payloads, _ : _) -> check payloads
    _ -> expectationFailure ("Unclosed fixture: " ++ marker)
  _ -> expectationFailure ("Missing fixture: " ++ marker)
  where normalizedLines = map (dropWhileEnd (== '\r')) (lines document)

checkTranscriptRow :: String -> IO ()
checkTranscriptRow row = case stripPrefix "C1 -> S: " row of
  Just payload -> parseCommandText payload `shouldSatisfy` isRight
  Nothing -> case stripPrefix "C2 -> S: " row of
    Just payload -> parseCommandText payload `shouldSatisfy` isRight
    Nothing -> case [payload | prefix <- ["S -> C1: ", "S -> C2: ", "S -> C3: "],
                               Just payload <- [stripPrefix prefix row]] of
      [payload] -> validResponseText payload `shouldBe` True
      _ -> expectationFailure ("Invalid transcript direction: " ++ row)

checkEncodedTranscriptRow :: String -> IO ()
checkEncodedTranscriptRow row =
  case [payload | prefix <- ["C1 -> S: ", "C2 -> S: "], Just payload <- [stripPrefix prefix row]] of
    [payload] -> do
      let bytes = BSC.pack payload
      (parseCommand bytes >>= encodeCommand) `shouldBe` Right (bytes <> BSC.pack "\n")
    _ -> case [payload | prefix <- ["S -> C1: ", "S -> C2: ", "S -> C3: "],
                         Just payload <- [stripPrefix prefix row]] of
      [payload] -> (parseResponse (BSC.pack payload) >>= encodeResponse) `shouldBe` Right (BSC.pack (payload ++ "\n"))
      _ -> expectationFailure ("Invalid transcript direction: " ++ row)

firstPlace :: String
firstPlace = "PLACE CV=A1:H;BB=A2:H;CR=A3:H;SB=A4:H;DD=A5:H"

reversedPlace :: String
reversedPlace = "PLACE DD=A5:H;SB=A4:H;CR=A3:H;BB=A2:H;CV=A1:H"

firstPlacements :: FleetPlacement
firstPlacements =
  [ShipPlacement ship (Coord 1 row) Horizontal |
   (ship, row) <- zip [Carrier, Battleship, Cruiser, Submarine, Destroyer] [1 .. 5]]

errorExamples :: [(GameError, String)]
errorExamples =
  [(InvalidCommand "Tiếng Việt\nQUIT", "ERROR INVALID_COMMAND"),
   (InvalidCoordinate (Coord (-1) 0), "ERROR INVALID_COORDINATE"),
   (InvalidFleetSize 4, "ERROR INVALID_FLEET_SIZE 4"),
   (MissingShip Destroyer, "ERROR MISSING_SHIP DD"),
   (DuplicateShip Carrier, "ERROR DUPLICATE_SHIP CV"),
   (ShipOutOfBounds Carrier (Coord 14 10), "ERROR SHIP_OUT_OF_BOUNDS CV"),
   (ShipsOverlap (Coord 1 1), "ERROR SHIPS_OVERLAP A1"),
   (FleetAlreadyPlaced, "ERROR FLEET_ALREADY_PLACED"),
   (FleetsNotReady, "ERROR FLEETS_NOT_READY"),
   (NotYourTurn P1, "ERROR NOT_YOUR_TURN P1"),
   (AlreadyFired (Coord 1 6), "ERROR ALREADY_FIRED A6"),
   (GameAlreadyFinished, "ERROR GAME_FINISHED")]

firstShotTranscript :: [String]
firstShotTranscript =
  ["S -> C1: WELCOME 1 P1", "C1 -> S: " ++ firstPlace,
   "S -> C1: OK PLACE", "S -> C1: WAITING OPPONENT", "S -> C2: WELCOME 1 P2",
   "C2 -> S: PLACE CV=A6:H;BB=A7:H;CR=A8:H;SB=A9:H;DD=A10:H",
   "S -> C2: OK PLACE", "S -> C1: START P1", "S -> C2: START P1",
   "S -> C1: TURN P1", "S -> C2: TURN P1", "C1 -> S: FIRE A6",
   "S -> C1: SHOT A6 HIT", "S -> C2: INCOMING A6 HIT",
   "S -> C1: TURN P1", "S -> C2: TURN P1"]
