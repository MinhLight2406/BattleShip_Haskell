module ProtocolSpec (spec) where

-- Reference grammar/framing checks for the document, not the production codec.
import Battleship.Types
import Control.Monad (foldM, forM_)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (chr, ord)
import Data.Either (isRight)
import Data.List (isInfixOf, stripPrefix)
import Data.Maybe (isJust)
import Paths_battleship_haskell (getDataFileName)
import Test.Hspec
  ( Spec, beforeAll, describe, expectationFailure, it, shouldBe, shouldSatisfy )

spec :: Spec
spec = describe "D-01 protocol contract" $ do
  describe "coordinate grammar" $ do
    it "accepts all 100 coordinates and maps to the one-based A-01 Coord" $
      forM_ [(column, row) | column <- [1 .. 10], row <- [1 .. 10]] $
        \(column, row) ->
          parseCoordRef ([chr (ord 'A' + column - 1)] ++ show row)
            `shouldBe` Just (Coord column row)

    forM_ ["", "A0", "A11", "K1", "a1", "A01", "AA1", "1A", "A-1", "A+1"] $
      \coordinate -> it ("rejects " ++ show coordinate) $
        parseCoordRef coordinate `shouldBe` Nothing

  describe "command grammar" $ do
    it "maps the complete canonical PLACE to A-01 placements" $
      parseCommandRef firstPlace `shouldBe` Right (PlaceFleet firstPlacements)

    it "accepts another ship order without reordering the request" $
      parseCommandRef reversedPlace `shouldBe` Right (PlaceFleet (reverse firstPlacements))

    it "preserves a duplicate ID for Board to reject instead of overwriting it" $
      parseCommandRef "PLACE CV=A1:H;CV=A2:H" `shouldBe`
        Right (PlaceFleet [ShipPlacement Carrier (Coord 1 1) Horizontal,
                           ShipPlacement Carrier (Coord 1 2) Horizontal])

    it "leaves fleet count and placement geometry to Board/Rules" $
      parseCommandRef "PLACE CV=J10:H" `shouldBe`
        Right (PlaceFleet [ShipPlacement Carrier (Coord 10 10) Horizontal])

    it "accepts vertical placements" $
      parseCommandRef "PLACE DD=J9:V" `shouldBe`
        Right (PlaceFleet [ShipPlacement Destroyer (Coord 10 9) Vertical])

    forM_ [("FIRE A1", Fire (Coord 1 1)), ("FIRE J10", Fire (Coord 10 10)),
           ("QUIT", Quit)] $ \(payload, expected) ->
      it ("parses " ++ payload) $ parseCommandRef payload `shouldBe` Right expected

    forM_ ["", "fire A1", "FIRE", "FIRE A1 EXTRA", " FIRE A1", "FIRE A1 ",
           "FIRE  A1", "FIRE\tA1", "P1 FIRE A1", "QUIT P1", "PLACE",
           "PLACE XX=A1:H", "PLACE CV=A1:X", "PLACE CV=A1:H;",
           "PLACE CV=A1:H;;BB=A2:H", "PLACE CV==A1:H", "PLACE CV=A1:H:H",
           "PLACE CV =A1:H", "FIRE A1\nQUIT", "FIRE A1\0", "BẮN A1"] $
      \payload -> it ("rejects malformed command " ++ show payload) $
        parseCommandRef payload `shouldSatisfy` isInvalidCommand

    forM_ ["FIRE K1", "FIRE A01", "FIRE A0", "PLACE CV=A11:H"] $
      \payload -> it ("classifies coordinate error " ++ payload) $
        parseCommandRef payload `shouldBe` Left (InvalidCoordinate (Coord 0 0))

  describe "server grammar" $ do
    forM_ ["WELCOME P1", "WELCOME 2 P1", "WELCOME 1 P3", "START P2",
           "OK QUIT", "WAITING", "WAITING FLEET", "TURN P3", "SHOT K1 HIT",
           "SHOT A1 SUNK", "SHOT A1 SUNK XX", "SHOT A1 HIT CV",
           "INCOMING A1 WIN CV", "GAME_OVER P1", "GAME_OVER P1 DRAW",
           "ERROR UNKNOWN", "ERROR NOT_YOUR_TURN", "ERROR INVALID_FLEET_SIZE -1",
           "ERROR INVALID_FLEET_SIZE 04", "ERROR INVALID_FLEET_SIZE 257",
           "ERROR INVALID_COMMAND raw", "FLEET CV=A1:H", "TURN  P1"] $
      \payload -> it ("rejects malformed response " ++ show payload) $
        validResponseRef payload `shouldBe` False

    forM_ errorExamples $ \(gameError, expectedWire) ->
      it ("maps A-01 error to " ++ expectedWire) $ do
        renderErrorRef gameError `shouldBe` expectedWire
        validResponseRef expectedWire `shouldBe` True

    forM_ [P1, P2] $ \shooter ->
      forM_ [Miss, Hit, Sunk Destroyer, Win] $ \outcome ->
        it ("routes " ++ show outcome ++ " separately for shooter " ++ show shooter) $ do
          let result = routeShotRef shooter (Coord 2 10) outcome
          result `shouldBe`
            [(shooter, "SHOT B10 " ++ renderOutcomeRef outcome),
             (otherPlayer shooter, "INCOMING B10 " ++ renderOutcomeRef outcome)]
          map snd result `shouldSatisfy` all validResponseRef

  describe "byte framing" $ do
    it "splits coalesced messages and keeps an incomplete tail" $
      feedChunksRef [BSC.pack "FIRE A1\nQUIT\nFIRE B"] `shouldBe`
        Right ([BSC.pack "FIRE A1", BSC.pack "QUIT"], BSC.pack "FIRE B")

    it "does not emit a command until LF arrives" $
      feedChunksRef [BSC.pack "FIRE A1"] `shouldBe` Right ([], BSC.pack "FIRE A1")

    it "accepts CRLF and CR/LF split between recv calls" $
      feedChunksRef [BSC.pack "FIRE A1\r", BSC.pack "\nQUIT\n"] `shouldBe`
        Right ([BSC.pack "FIRE A1", BSC.pack "QUIT"], BS.empty)

    it "gives the same frames at every possible two-chunk split" $ do
      let stream = BSC.pack (firstPlace ++ "\r\nFIRE A1\nQUIT\n")
          expected = Right (map BSC.pack [firstPlace, "FIRE A1", "QUIT"], BS.empty)
      forM_ [0 .. BS.length stream] $ \offset ->
        feedChunksRef [BS.take offset stream, BS.drop offset stream] `shouldBe` expected

    it "accepts exactly 256 payload bytes with LF or CRLF" $
      forM_ ["\n", "\r\n"] $ \ending ->
        feedChunksRef [BS.replicate 256 65 <> BSC.pack ending]
          `shouldBe` Right ([BS.replicate 256 65], BS.empty)

    it "allows the extra pending CR at the exact limit" $
      feedChunksRef [BS.replicate 256 65 <> BSC.pack "\r", BSC.pack "\n"]
        `shouldBe` Right ([BS.replicate 256 65], BS.empty)

    it "rejects byte 257 without waiting for a newline" $
      feedChunksRef [BS.replicate 256 65, BSC.pack "B"] `shouldBe` Left RefLineTooLong

    it "rejects a completed oversized line" $
      feedChunksRef [BS.replicate 257 65 <> BSC.pack "\n"] `shouldBe` Left RefLineTooLong

    it "counts UTF-8 bytes rather than characters before validating grammar" $
      feedChunksRef [BS.pack (concat (replicate 129 [0xc3, 0xa9])) <> BSC.pack "\n"]
        `shouldBe` Left RefLineTooLong

    forM_ [BSC.pack "FIRE\tA1\n", BSC.pack "FIRE A1\0\n",
           BSC.pack "FIRE A1\rX\n", BS.pack [0xff, 10], BS.pack [0xc3, 0xa9, 10]] $
      \bytes -> it ("rejects control or non-ASCII frame " ++ show bytes) $
        case feedChunksRef [bytes] of
          Right ([payload], pending) -> do
            pending `shouldBe` BS.empty
            parseCommandRef (BSC.unpack payload) `shouldSatisfy` isInvalidCommand
          result -> expectationFailure ("Unexpected framing: " ++ show result)

    it "rejects a malformed line without losing the following valid command" $
      case feedChunksRef [BSC.pack "FIRE\tA1\nFIRE A1\n"] of
        Right (payloads, pending) -> do
          pending `shouldBe` BS.empty
          map (parseCommandRef . BSC.unpack) payloads `shouldBe`
            [Left syntaxError, Right (Fire (Coord 1 1))]
        result -> expectationFailure ("Unexpected framing: " ++ show result)

  beforeAll (getDataFileName "docs/protocol.md" >>= readFile) $
    describe "document fixtures and transcripts" $ do
      it "publishes the same version and byte limit as the reference grammar" $ \document -> do
        document `shouldSatisfy` isInfixOf "MAX_LINE_BYTES = 256"
        document `shouldSatisfy` isInfixOf "WELCOME 1 P1"

      it "all published command vectors parse as A-01 commands" $ \document ->
        checkBlock document "contract:commands" $ \payloads -> do
          payloads `shouldSatisfy` (not . null)
          forM_ payloads $ \payload -> parseCommandRef payload `shouldSatisfy` isRight

      it "all response vectors are valid and cover every A-01 error mapping" $ \document ->
        checkBlock document "contract:responses" $ \payloads -> do
          payloads `shouldSatisfy` (not . null)
          forM_ payloads $ \payload -> validResponseRef payload `shouldBe` True
          forM_ errorExamples $ \(_, wire) -> payloads `shouldSatisfy` elem wire

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
                 "S -> C1: SHOT " ++ coordinate ++ " " ++ renderOutcomeRef outcome,
                 "S -> C2: INCOMING " ++ coordinate ++ " " ++ renderOutcomeRef outcome,
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

-- Everything below is test-only reference code for D-01. Production functions
-- will need independent tests against the same vectors when implemented.
parseCoordRef :: String -> Maybe Coord
parseCoordRef (column : row)
  | column >= 'A' && column <= 'J' = do
      number <- lookup row [(show n, n) | n <- [1 .. 10]]
      pure (Coord (ord column - ord 'A' + 1) number)
parseCoordRef _ = Nothing

parseShipRef :: String -> Maybe ShipId
parseShipRef code = lookup code
  [("CV", Carrier), ("BB", Battleship), ("CR", Cruiser),
   ("SB", Submarine), ("DD", Destroyer)]

parseCommandRef :: String -> Either GameError Command
parseCommandRef payload
  | not (all printableAscii payload) = Left syntaxError
  | otherwise = case splitOn ' ' payload of
      ["QUIT"] -> Right Quit
      ["FIRE", coordinate] | not (null coordinate) -> Fire <$> coordinateRef coordinate
      ["PLACE", entries] | not (null entries) ->
        PlaceFleet <$> traverse placementRef (splitOn ';' entries)
      _ -> Left syntaxError
  where
    placementRef entry = case splitOn '=' entry of
      [code, position] -> case splitOn ':' position of
        [coordinate, direction] -> do
          ship <- maybe (Left syntaxError) Right (parseShipRef code)
          start <- coordinateRef coordinate
          orientation <- case direction of
            "H" -> Right Horizontal
            "V" -> Right Vertical
            _ -> Left syntaxError
          pure (ShipPlacement ship start orientation)
        _ -> Left syntaxError
      _ -> Left syntaxError

-- Dummy Coord represents a parse failure; v1 never echoes an invalid coordinate.
coordinateRef :: String -> Either GameError Coord
coordinateRef = maybe (Left (InvalidCoordinate (Coord 0 0))) Right . parseCoordRef

syntaxError :: GameError
syntaxError = InvalidCommand "reference grammar"

validResponseRef :: String -> Bool
validResponseRef payload = length payload <= 256 && all printableAscii payload &&
  case splitOn ' ' payload of
    ["WELCOME", "1", player] -> validPlayer player
    ["OK", "PLACE"] -> True
    ["WAITING", "OPPONENT"] -> True
    ["START", "P1"] -> True
    ["TURN", player] -> validPlayer player
    kind : coordinate : outcome | kind `elem` ["SHOT", "INCOMING"] ->
      isJust (parseCoordRef coordinate) && validOutcome outcome
    ["GAME_OVER", player, reason] -> validPlayer player &&
      reason `elem` ["ALL_SHIPS_SUNK", "OPPONENT_LEFT"]
    ["ERROR", code] -> code `elem`
      ["INVALID_COMMAND", "INVALID_COORDINATE", "FLEET_ALREADY_PLACED",
       "FLEETS_NOT_READY", "GAME_FINISHED", "LINE_TOO_LONG", "SERVER_FULL"]
    ["ERROR", "INVALID_FLEET_SIZE", count] -> count `elem` map show ([0 .. 256] :: [Int])
    ["ERROR", code, ship] | code `elem` ["MISSING_SHIP", "DUPLICATE_SHIP", "SHIP_OUT_OF_BOUNDS"] ->
      isJust (parseShipRef ship)
    ["ERROR", code, coordinate] | code `elem` ["SHIPS_OVERLAP", "ALREADY_FIRED"] ->
      isJust (parseCoordRef coordinate)
    ["ERROR", "NOT_YOUR_TURN", player] -> validPlayer player
    _ -> False
  where
    validPlayer player = player `elem` ["P1", "P2"]
    validOutcome [outcome] = outcome `elem` ["MISS", "HIT", "WIN"]
    validOutcome ["SUNK", ship] = isJust (parseShipRef ship)
    validOutcome _ = False

renderShipRef :: ShipId -> String
renderShipRef Carrier = "CV"
renderShipRef Battleship = "BB"
renderShipRef Cruiser = "CR"
renderShipRef Submarine = "SB"
renderShipRef Destroyer = "DD"

renderCoordRef :: Coord -> String
renderCoordRef (Coord column row) = [chr (ord 'A' + column - 1)] ++ show row

renderOutcomeRef :: Outcome -> String
renderOutcomeRef Miss = "MISS"
renderOutcomeRef Hit = "HIT"
renderOutcomeRef (Sunk ship) = "SUNK " ++ renderShipRef ship
renderOutcomeRef Win = "WIN"

renderErrorRef :: GameError -> String
renderErrorRef gameError = "ERROR " ++ case gameError of
  InvalidCommand _ -> "INVALID_COMMAND"
  InvalidCoordinate _ -> "INVALID_COORDINATE"
  InvalidFleetSize count -> "INVALID_FLEET_SIZE " ++ show count
  MissingShip ship -> "MISSING_SHIP " ++ renderShipRef ship
  DuplicateShip ship -> "DUPLICATE_SHIP " ++ renderShipRef ship
  ShipOutOfBounds ship _ -> "SHIP_OUT_OF_BOUNDS " ++ renderShipRef ship
  ShipsOverlap coordinate -> "SHIPS_OVERLAP " ++ renderCoordRef coordinate
  FleetAlreadyPlaced -> "FLEET_ALREADY_PLACED"
  FleetsNotReady -> "FLEETS_NOT_READY"
  NotYourTurn P1 -> "NOT_YOUR_TURN P1"
  NotYourTurn P2 -> "NOT_YOUR_TURN P2"
  AlreadyFired coordinate -> "ALREADY_FIRED " ++ renderCoordRef coordinate
  GameAlreadyFinished -> "GAME_FINISHED"

routeShotRef :: PlayerId -> Coord -> Outcome -> [(PlayerId, String)]
routeShotRef shooter coordinate outcome =
  [(shooter, "SHOT " ++ payload), (otherPlayer shooter, "INCOMING " ++ payload)]
  where payload = renderCoordRef coordinate ++ " " ++ renderOutcomeRef outcome

data FrameFault = RefLineTooLong deriving (Eq, Show)

feedChunksRef :: [BS.ByteString] -> Either FrameFault ([BS.ByteString], BS.ByteString)
feedChunksRef = foldM feed ([], BS.empty)
  where
    feed (previous, pending) chunk = do
      (complete, remaining) <- consume [] (pending <> chunk)
      pure (previous ++ complete, remaining)
    consume complete bytes = case BS.elemIndex 10 bytes of
      Nothing
        | BS.length bytes <= 256 || (BS.length bytes == 257 && BS.last bytes == 13) ->
            Right (reverse complete, bytes)
        | otherwise -> Left RefLineTooLong
      Just offset -> do
        let raw = BS.take offset bytes
            payload = if not (BS.null raw) && BS.last raw == 13 then BS.init raw else raw
        if BS.length payload > 256 then Left RefLineTooLong
          else consume (payload : complete) (BS.drop (offset + 1) bytes)

splitOn :: Char -> String -> [String]
splitOn delimiter value = case break (== delimiter) value of
  (part, []) -> [part]
  (part, _ : rest) -> part : splitOn delimiter rest

printableAscii :: Char -> Bool
printableAscii character = character >= ' ' && character <= '~'

isInvalidCommand :: Either GameError Command -> Bool
isInvalidCommand (Left (InvalidCommand _)) = True
isInvalidCommand _ = False

checkBlock :: String -> String -> ([String] -> IO ()) -> IO ()
checkBlock document marker check = case dropWhile (/= "<!-- " ++ marker ++ " -->") (lines document) of
  _ : "```text" : rest -> case break (== "```") rest of
    (payloads, _ : _) -> check payloads
    _ -> expectationFailure ("Unclosed fixture: " ++ marker)
  _ -> expectationFailure ("Missing fixture: " ++ marker)

checkTranscriptRow :: String -> IO ()
checkTranscriptRow row = case stripPrefix "C1 -> S: " row of
  Just payload -> parseCommandRef payload `shouldSatisfy` isRight
  Nothing -> case stripPrefix "C2 -> S: " row of
    Just payload -> parseCommandRef payload `shouldSatisfy` isRight
    Nothing -> case [payload | prefix <- ["S -> C1: ", "S -> C2: ", "S -> C3: "],
                               Just payload <- [stripPrefix prefix row]] of
      [payload] -> validResponseRef payload `shouldBe` True
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
