module ViewSpec (spec) where

import Battleship.Board (placeFleet)
import Battleship.Coordinator (applyCommand)
import Battleship.Rules (step)
import Battleship.Types
import Battleship.View (viewFor)
import Control.Monad (foldM, forM_)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Proxy (Proxy (..))
import Data.Typeable (typeRep)
import RulesSpec (b04Cases, b04Trace)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = do
  b03Spec
  b04Spec
  b05Spec

b03Spec :: Spec
b03Spec = describe "B-03 private player views" $ do
  it "implements the published pure ViewFor signature" $
    typeRep (proxyOf viewFor) `shouldBe` typeRep (Proxy :: Proxy ViewFor)

  forM_ [P1, P2] $ \viewer -> do
    it (show viewer ++ " sees no fleet, shots or opponent readiness in the empty game") $
      viewFor viewer initialGameState `shouldBe`
        PlayerView viewer Placing Nothing Map.empty Map.empty False

    it (show viewer ++ " sees only its own placement and the opponent readiness flag") $ do
      let ownOnly = play [(viewer, PlaceFleet (horizontal 6))]
          enemyOnly = play [(otherPlayer viewer, PlaceFleet (horizontal 1))]
          both = play (placements viewer (horizontal 1))
      viewFor viewer ownOnly `shouldBe`
        PlayerView viewer Placing (Just (fleet (horizontal 6))) Map.empty Map.empty False
      viewFor viewer enemyOnly `shouldBe`
        PlayerView viewer Placing Nothing Map.empty Map.empty True
      viewFor viewer both `shouldBe`
        PlayerView viewer (Turn P1) (Just (fleet (horizontal 6))) Map.empty Map.empty True

    it (show viewer ++ " gets identical whole views for 72 different unshot opponent layouts") $ do
      let expected = PlayerView viewer (Turn P1) (Just (fleet (horizontal 6))) Map.empty Map.empty True
      forM_ layouts $ \enemy -> do
        let state = play (placements viewer enemy)
            projected = viewFor viewer state
        projected `shouldBe` expected
        checkProjection viewer state
        -- With no outgoing shots, all 17 enemy cells are still hidden.
        Set.size (cells (fleet enemy)) `shouldBe` 17
        Map.keysSet (outgoingShotsView projected) `shouldBe` Set.empty

    it (show viewer ++ " hides every unshot enemy coordinate before and after Hit/Sunk/Quit") $ do
      -- The carrier and observations are identical; only twelve secret cells
      -- of the other four ships change. Whole-view equality detects any extra
      -- leak, including geometry hidden in a newly added field.
      let prefix = [(P1, Fire (Coord 10 10)) | viewer == P2] ++
            [(viewer, Fire (Coord column 1)) | column <- [1 .. 5]]
          commands enemy = placements viewer enemy ++ prefix ++ [(otherPlayer viewer, Quit)]
          first = trace (commands (horizontal 1))
          second = trace (commands alternateEnemy)
      length first `shouldBe` length second
      forM_ (zip first second) $ \(left, right) -> do
        viewFor viewer left `shouldBe` viewFor viewer right
        checkProjection viewer left
        checkProjection viewer right
      let sunk = first !! (length first - 2)
          final = last first
      Map.lookup (Coord 5 1) (outgoingShotsView (viewFor viewer sunk)) `shouldBe` Just (Sunk Carrier)
      gamePhase final `shouldBe` Finished viewer OpponentLeft
      Map.size (outgoingShotsView (viewFor viewer final)) `shouldBe` 5
      Set.size (cells (fleet (horizontal 1)) `Set.difference`
                Map.keysSet (outgoingShotsView (viewFor viewer final))) `shouldBe` 12

    it (show viewer ++ " preserves own cells even when the same coordinates are secret on the other board") $ do
      let state = play ([(P1, PlaceFleet (horizontal 1)), (P2, PlaceFleet (horizontal 1))] ++
                       [(P1, Fire (Coord 10 10)) | viewer == P2] ++ [(viewer, Fire (Coord 1 1))])
          projected = viewFor viewer state
      ownFleetView projected `shouldBe` Just (fleet (horizontal 1))
      outgoingShotsView projected `shouldBe` Map.singleton (Coord 1 1) Hit
      Set.size (cells (fleet (horizontal 1)) `Set.difference` Map.keysSet (outgoingShotsView projected)) `shouldBe` 16
      checkProjection viewer state

    it (show viewer ++ " receives filtered wire events and errors, never a state or opponent PLACE payload") $ do
      let own = horizontal 6
          enemy = otherPlayer viewer
          waiting = play [(viewer, PlaceFleet own)]
          ready = play (placements viewer (horizontal 1) ++ [(P1, Fire (Coord 10 10)) | viewer == P2])
          (afterHit, _) = transition viewer (Fire (Coord 1 1)) ready
      applyCommand step viewer (PlaceFleet own) initialGameState `shouldBe`
        Right (waiting, [(viewer, b "OK PLACE\n"), (viewer, b "WAITING OPPONENT\n")])
      applyCommand step enemy (PlaceFleet (horizontal 1)) waiting `shouldBe`
        Right (play (placements viewer (horizontal 1)),
          [(enemy, b "OK PLACE\n"), (P1, b "START P1\n"), (P2, b "START P1\n"),
           (P1, b "TURN P1\n"), (P2, b "TURN P1\n")])
      applyCommand step viewer (Fire (Coord 1 1)) ready `shouldBe`
        Right (afterHit, [(viewer, b "SHOT A1 HIT\n"), (enemy, b "INCOMING A1 HIT\n"),
                         (P1, b ("TURN " ++ show viewer ++ "\n")), (P2, b ("TURN " ++ show viewer ++ "\n"))])
      applyCommand step enemy (Fire (Coord 1 2)) afterHit `shouldBe`
        Right (afterHit, [(enemy, b ("ERROR NOT_YOUR_TURN " ++ show viewer ++ "\n"))])
      let overlapping = take 4 own ++ [ShipPlacement Destroyer (Coord 1 6) Horizontal]
      applyCommand step viewer (PlaceFleet overlapping) initialGameState `shouldBe`
        Right (initialGameState, [(viewer, b "ERROR SHIPS_OVERLAP A6\n")])

  forM_ [P1, P2] $ \winner ->
    it ("projects every real transition through Miss/Hit/Sunk/Win for winner " ++ show winner) $ do
      let enemyFleet = if winner == P1 then horizontal 6 else horizontal 1
          opening = [(P1, Fire (Coord 10 10))] ++ [(P2, Fire (Coord 10 10)) | winner == P1]
          commands = [(P1, PlaceFleet (horizontal 1)), (P2, PlaceFleet (horizontal 6))] ++
                     opening ++ [(winner, Fire cell) | cell <- orderedCells enemyFleet]
          states = trace commands
          finished = last states
      forM_ states $ \state -> forM_ [P1, P2] $ \viewer -> checkProjection viewer state
      gamePhase finished `shouldBe` Finished winner AllShipsSunk
      viewPhase (viewFor winner finished) `shouldBe` Finished winner AllShipsSunk
      Map.size (outgoingShotsView (viewFor winner finished)) `shouldBe` if winner == P1 then 18 else 17
      Map.size (incomingShotsView (viewFor (otherPlayer winner) finished)) `shouldBe` if winner == P1 then 18 else 17

b04Spec :: Spec
b04Spec = describe "B-04 privacy after every accepted or rejected command" $
  forM_ [P1, P2] $ \winner ->
    it ("keeps both views private throughout errors and after " ++ show winner ++ " wins") $ do
      forM_ (zip (b04Cases winner) (b04Trace winner)) $ \((_, _, expected), (before, after, actual)) -> do
        -- Assert the named error/result here too: this must not become a view
        -- test that silently skips an unexpectedly accepted invalid command.
        fmap (\events -> (gamePhase after, events)) actual `shouldBe` expected
        forM_ [P1, P2] $ \viewer -> do
          checkProjection viewer before
          checkProjection viewer after
          case expected of
            Left _ -> do
              after `shouldBe` before
              viewFor viewer after `shouldBe` viewFor viewer before
            Right _ -> pure ()
      let (_, finished, _) = last (b04Trace winner)
          loser = otherPlayer winner
          hiddenWinnerCells = maybe Set.empty cells (playerFleet (playerStateFor winner finished))
            `Set.difference` Map.keysSet (outgoingShotsView (viewFor loser finished))
      gamePhase finished `shouldBe` Finished winner AllShipsSunk
      -- The loser fired only at water. Winning must not reveal the winner's
      -- still-unshot fleet; the final secrecy check is therefore non-vacuous.
      Set.size hiddenWinnerCells `shouldBe` 17
      forM_ (Set.toList hiddenWinnerCells) $ \coordinate ->
        Map.lookup coordinate (outgoingShotsView (viewFor loser finished)) `shouldBe` Nothing

b05Spec :: Spec
b05Spec = describe "B-05 event/view consistency and secret geometry" $ do
  forM_ [P1, P2] $ \winner ->
    it ("reconstructs both whole views from Events through errors and " ++ show winner ++ " winning") $ do
      forM_ [P1, P2] $ \viewer -> do
        final <- foldM (\previous ((_, command, expected), (before, after, actual)) -> do
          previous `shouldBe` viewFor viewer before
          fmap (\events -> (gamePhase after, events)) actual `shouldBe` expected
          let next = case actual of
                Left _ -> previous
                Right events -> foldl (viewAfterEvent command) previous events
          next `shouldBe` viewFor viewer after
          checkProjection viewer after
          pure next) (PlayerView viewer Placing Nothing Map.empty Map.empty False)
            (zip (b04Cases winner) (b04Trace winner))
        viewPhase final `shouldBe` Finished winner AllShipsSunk

  forM_ [P1, P2] $ \viewer ->
    it (show viewer ++ " cannot distinguish changed unshot ships in Events or whole views after Sunk/Quit") $ do
      let firstEnemy = horizontal 1
          secondEnemy = alternateEnemy
          firstCells = cells (fleet firstEnemy)
          secondCells = cells (fleet secondEnemy)
          commonCarrier = Set.fromList [Coord column 1 | column <- [1 .. 5]]
          opening = [(P1, Fire (Coord 10 10)) | viewer == P2]
          shots = [(viewer, Fire (Coord column 1)) | column <- [1 .. 5]]
          commands enemy = placements viewer enemy ++ opening ++ shots ++ [(otherPlayer viewer, Quit)]
      Set.intersection firstCells secondCells `shouldBe` commonCarrier
      Set.size (firstCells `Set.difference` secondCells) `shouldBe` 12
      Set.size (secondCells `Set.difference` firstCells) `shouldBe` 12
      (finalLeft, finalRight) <- foldM (\(left, right) ((actor, commandLeft), (actorRight, commandRight)) -> do
        actorRight `shouldBe` actor
        let (nextLeft, eventsLeft) = transition actor commandLeft left
            (nextRight, eventsRight) = transition actorRight commandRight right
        eventsLeft `shouldSatisfy` (not . null)
        eventsLeft `shouldBe` eventsRight
        viewFor viewer nextLeft `shouldBe` viewFor viewer nextRight
        forM_ [nextLeft, nextRight] (checkProjection viewer)
        pure (nextLeft, nextRight)) (initialGameState, initialGameState)
          (zip (commands firstEnemy) (commands secondEnemy))
      forM_ [(finalLeft, firstCells), (finalRight, secondCells)] $ \(finished, enemyCells) -> do
        let projected = viewFor viewer finished
        viewPhase projected `shouldBe` Finished viewer OpponentLeft
        outgoingShotsView projected `shouldBe`
          Map.fromList ([(Coord column 1, Hit) | column <- [1 .. 4]] ++ [(Coord 5 1, Sunk Carrier)])
        Set.size (enemyCells `Set.difference` Map.keysSet (outgoingShotsView projected)) `shouldBe` 12

-- Test-only projection from observations, not GameState. FleetAccepted carries
-- no geometry: only the owner's already-known PLACE request may supply it.
-- This never decides hits, sunk ships, winners or whose turn comes next.
viewAfterEvent :: Command -> PlayerView -> Event -> PlayerView
viewAfterEvent command previous event = case event of
  FleetAccepted player
    | player /= viewPlayer previous -> previous { opponentReady = True }
    | otherwise -> case command of
        PlaceFleet request -> previous { ownFleetView = Just (fleet request) }
        _ -> error "B-05 FleetAccepted without a PLACE request"
  GameStarted player -> previous { viewPhase = Turn player }
  ShotResolved player coordinate outcome
    | player == viewPlayer previous -> previous
        { outgoingShotsView = Map.insert coordinate outcome (outgoingShotsView previous) }
    | otherwise -> previous
        { incomingShotsView = Map.insert coordinate outcome (incomingShotsView previous) }
  TurnReady player -> previous { viewPhase = Turn player }
  GameEnded winner reason -> previous { viewPhase = Finished winner reason }

-- The complete record is the public-data oracle. Own-board coordinates can
-- coincide with secret enemy-board coordinates; they must remain visible as
-- own cells. Only outgoing keys may describe cells on the opponent's board.
checkProjection :: PlayerId -> GameState -> IO ()
checkProjection viewer state = do
  let (own, enemy) = case viewer of
        P1 -> (gamePlayer1 state, gamePlayer2 state)
        P2 -> (gamePlayer2 state, gamePlayer1 state)
      projected = viewFor viewer state
      hidden = maybe Set.empty cells (playerFleet enemy) `Set.difference` Map.keysSet (playerShots own)
  projected `shouldBe` PlayerView viewer (gamePhase state) (playerFleet own)
    (playerShots own) (playerShots enemy) (playerFleet enemy /= Nothing)
  forM_ (Set.toList hidden) $ \coordinate ->
    Map.lookup coordinate (outgoingShotsView projected) `shouldBe` Nothing

proxyOf :: a -> Proxy a
proxyOf _ = Proxy

b :: String -> BSC.ByteString
b = BSC.pack

fleet :: FleetPlacement -> Fleet
fleet request = either (error . ("Invalid ViewSpec fleet: " ++) . show) id (placeFleet request)

cells :: Fleet -> Set.Set Coord
cells = Set.unions . Map.elems . fleetShips

transition :: PlayerId -> Command -> GameState -> (GameState, [Event])
transition actor command state = either (error . ("Invalid ViewSpec command: " ++) . show) id (step actor command state)

trace :: [(PlayerId, Command)] -> [GameState]
trace = scanl (\state (actor, command) -> fst (transition actor command state)) initialGameState

play :: [(PlayerId, Command)] -> GameState
play = last . trace

placements :: PlayerId -> FleetPlacement -> [(PlayerId, Command)]
placements viewer enemy = [(viewer, PlaceFleet (horizontal 6)), (otherPlayer viewer, PlaceFleet enemy)]

horizontal :: Int -> FleetPlacement
horizontal startRow = [ShipPlacement ship (Coord 1 row) Horizontal |
  (ship, row) <- zip [Carrier, Battleship, Cruiser, Submarine, Destroyer] [startRow ..]]

orderedCells :: FleetPlacement -> [Coord]
orderedCells request = [Coord (coordColumn start + offset) (coordRow start) |
  ShipPlacement ship start _ <- request, offset <- [0 .. shipLength ship - 1]]

layouts :: [FleetPlacement]
layouts = [[ShipPlacement ship
  (if direction == Horizontal then Coord column (row + index) else Coord (column + index) row) direction |
  (index, ship) <- zip [0 ..] [Carrier, Battleship, Cruiser, Submarine, Destroyer]] |
  direction <- [Horizontal, Vertical], column <- [1 .. 6], row <- [1 .. 6]]

alternateEnemy :: FleetPlacement
alternateEnemy = [ShipPlacement Carrier (Coord 1 1) Horizontal,
  ShipPlacement Battleship (Coord 10 2) Vertical, ShipPlacement Cruiser (Coord 9 2) Vertical,
  ShipPlacement Submarine (Coord 8 2) Vertical, ShipPlacement Destroyer (Coord 7 2) Vertical]
