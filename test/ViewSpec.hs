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
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import qualified Test.QuickCheck as QC
import TestSupport.Generators
  (genValidFleet, genFleetKeepingCarrier, legalBoardCells, referenceCells, validGeneratedFleet)

spec :: Spec
spec = do
  b03Spec
  b04Spec
  b05Spec
  b06Spec

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

b06Spec :: Spec
b06Spec = describe "B-06 QuickCheck private views" $ modifyMaxSuccess (max 1000) $
  forM_ [P1, P2] $ \viewer -> describe (show viewer) $ do
    it "preserves only the viewer's own accepted fleet throughout valid play" $
      forGameTrace viewer $ everyObservation $ \state observed ->
        let projected = viewFor viewer state
        in QC.conjoin
          [ viewPlayer projected QC.=== viewer
          , ownFleetView projected QC.=== ownFleetView observed ]

    it "matches outgoing and incoming histories reconstructed from shot events" $
      forGameTrace viewer $ everyObservation $ \state observed ->
        let projected = viewFor viewer state
        in QC.conjoin
          [ outgoingShotsView projected QC.=== outgoingShotsView observed
          , incomingShotsView projected QC.=== incomingShotsView observed ]

    it "returns exactly the permitted public observations, including phase and readiness" $
      forGameTrace viewer $ everyObservation $ \state observed ->
        viewFor viewer state QC.=== observed

    it "cannot distinguish genuinely changed hidden cells with identical events, including Sunk" $
      QC.checkCoverage $ QC.forAll (genPrivatePair viewer) $ \(first, second) ->
        case (replayFor viewer first, replayFor viewer second) of
          (Right left, Right right) ->
            let (finalLeft, _, _) = last left
                (finalRight, _, _) = last right
                enemyCells state = maybe Set.empty cells (playerFleet (playerStateFor (otherPlayer viewer) state))
                oldCells = enemyCells finalLeft
                newCells = enemyCells finalRight
                shots = Map.keysSet (playerShots (playerStateFor viewer finalLeft))
                moved = Set.union (oldCells `Set.difference` newCells) (newCells `Set.difference` oldCells)
                sawSunk = any (\(_, events, _) -> any isCarrierSunk events) left
                isCarrierSunk (ShotResolved _ _ (Sunk Carrier)) = True
                isCarrierSunk _ = False
                phase = gamePhase finalLeft
            in QC.cover 15 sawSunk "observed Sunk Carrier"
               $ QC.cover 10 (case phase of Finished _ AllShipsSunk -> True; _ -> False) "finished by sinking"
               $ QC.cover 10 (case phase of Finished _ OpponentLeft -> True; _ -> False) "finished by quit"
               $ QC.cover 10 (case phase of Turn _ -> True; _ -> False) "still playing"
               $ QC.conjoin
                 [ QC.counterexample "Hidden geometry did not actually change" (not (Set.null moved))
                 , QC.counterexample "Private-pair generator violated the independent fleet contract"
                     (all validGeneratedFleet [request | (_, PlaceFleet request) <- first ++ second])
                 , QC.counterexample "Changed cells were already observed" (Set.null (Set.intersection moved shots))
                 , QC.counterexample "Too few unshot cells for a meaningful privacy check"
                     (Set.size (oldCells `Set.difference` shots) >= 12 && Set.size (newCells `Set.difference` shots) >= 12)
                 , map (\(_, events, _) -> events) left QC.=== map (\(_, events, _) -> events) right
                 , map (\(_, _, observed) -> observed) left QC.=== map (\(_, _, observed) -> observed) right
                 , map (\(state, _, _) -> viewFor viewer state) left QC.===
                     map (\(state, _, _) -> viewFor viewer state) right ]
          result -> QC.counterexample ("Generated private scripts failed: " ++ show result) False

    it "covers placement, active play, both winners and both termination reasons" $
      QC.checkCoverage $ forGameTrace viewer $ \observations ->
        let (final, _, _) = last observations
            phase = gamePhase final
            outcomes = [outcome | (_, events, _) <- observations, ShotResolved _ _ outcome <- events]
        in QC.cover 15 (phase == Placing) "placing"
           $ QC.cover 15 (case phase of Turn _ -> True; _ -> False) "playing"
           $ QC.cover 30 (case phase of Finished _ _ -> True; _ -> False) "finished"
           $ QC.cover 15 (case phase of Finished _ AllShipsSunk -> True; _ -> False) "all ships sunk"
           $ QC.cover 15 (case phase of Finished _ OpponentLeft -> True; _ -> False) "opponent left"
           $ QC.cover 15 (case phase of Finished P1 _ -> True; _ -> False) "P1 winner"
           $ QC.cover 15 (case phase of Finished P2 _ -> True; _ -> False) "P2 winner"
           $ QC.cover 10 (Miss `elem` outcomes) "Miss"
           $ QC.cover 10 (Hit `elem` outcomes) "Hit"
           $ QC.cover 10 (any (\outcome -> case outcome of Sunk _ -> True; _ -> False) outcomes) "Sunk"
           $ QC.cover 15 (Win `elem` outcomes) "Win"
           $ QC.property True

-- Scripts carry reproducible inputs; all states and observations are derived
-- by step. Four equally likely endings exercise partial and terminal games.
genGameCommands :: QC.Gen [(PlayerId, Command)]
genGameCommands = do
  firstFleet <- genValidFleet
  secondFleet <- genValidFleet
  placementCommands <- QC.shuffle [(P1, PlaceFleet firstFleet), (P2, PlaceFleet secondFleet)]
  winner <- QC.elements [P1, P2]
  let winnerFleet = if winner == P1 then firstFleet else secondFleet
      enemyFleet = if winner == P1 then secondFleet else firstFleet
  hits <- QC.shuffle (concatMap referenceCells enemyFleet)
  winnerWater <- QC.shuffle (waterOutside [enemyFleet])
  enemyWater <- QC.shuffle (waterOutside [winnerFleet])
  missCount <- QC.chooseInt (0, 3)
  let (opening, replies) = case enemyWater of
        firstWater : remaining
          | winner == P2 -> ([(P1, Fire firstWater)], remaining)
          | otherwise -> ([], enemyWater)
        [] -> error "Valid 17-cell fleet must leave water for the opening"
      misses = concat [[(winner, Fire target), (otherPlayer winner, Fire reply)] |
                       (target, reply) <- take missCount (zip winnerWater replies)]
      complete = placementCommands ++ opening ++ misses ++ [(winner, Fire coordinate) | coordinate <- hits]
  QC.oneof
    [ do count <- QC.chooseInt (0, 1); pure (take count complete)
    , do count <- QC.chooseInt (2, length complete - 1); pure (take count complete)
    , do count <- QC.chooseInt (0, length complete - 1)
         quitter <- QC.elements [P1, P2]
         pure (take count complete ++ [(quitter, Quit)])
    , pure complete ]

-- The viewer observes only common water and the unchanged Carrier. The other
-- player may sink the viewer's whole fleet; twelve enemy cells remain secret
-- even at that terminal state. No altered GameState or filtered failed run.
genPrivatePair :: PlayerId -> QC.Gen ([(PlayerId, Command)], [(PlayerId, Command)])
genPrivatePair viewer = do
  own <- genValidFleet
  original <- genValidFleet
  changed <- genFleetKeepingCarrier original
  let carrier = concatMap referenceCells [placement | placement <- original, placementShip placement == Carrier]
      enemy = otherPlayer viewer
  hits <- QC.shuffle carrier
  ownWater <- QC.shuffle (waterOutside [own])
  commonWater <- QC.shuffle (waterOutside [original, changed])
  hitCount <- QC.frequency [(1, QC.chooseInt (1, 4)), (1, pure 5)]
  winningShots <- QC.shuffle (concatMap referenceCells own)
  ownFirst <- QC.elements [False, True]
  let (opening, reply) = case ownWater of
        firstWater : secondWater : _
          | viewer == P2 -> ([(P1, Fire firstWater)], secondWater)
          | otherwise -> ([], firstWater)
        _ -> error "Valid 17-cell fleet must leave at least two water cells"
      (miss, passTurn) = case commonWater of
        firstWater : secondWater : _ -> (firstWater, secondWater)
        _ -> error "Two valid fleets must leave common water"
      history = opening ++ [(viewer, Fire miss), (enemy, Fire reply)]
        ++ [(viewer, Fire coordinate) | coordinate <- take hitCount hits]
  ending <- QC.oneof
    [ pure []
    , do quitter <- QC.elements [P1, P2]; pure [(quitter, Quit)]
    , pure ([(viewer, Fire passTurn)] ++ [(enemy, Fire coordinate) | coordinate <- winningShots]) ]
  let commands opponent =
        (if ownFirst then [(viewer, PlaceFleet own), (enemy, PlaceFleet opponent)]
                     else [(enemy, PlaceFleet opponent), (viewer, PlaceFleet own)]) ++ history ++ ending
  pure (commands original, commands changed)

waterOutside :: [FleetPlacement] -> [Coord]
waterOutside fleets = [coordinate | coordinate <- legalBoardCells,
                      coordinate `notElem` concatMap (concatMap referenceCells) fleets]

type Observation = (GameState, [Event], PlayerView)

replayFor :: PlayerId -> [(PlayerId, Command)] -> Either String [Observation]
replayFor viewer = go initialGameState [] (PlayerView viewer Placing Nothing Map.empty Map.empty False)
  where
    go state events observed [] = Right [(state, events, observed)]
    go state events observed ((actor, command) : remaining) = do
      (next, emitted) <- either (Left . show) Right (step actor command state)
      let nextObserved = foldl (viewAfterEvent command) observed emitted
      ((state, events, observed) :) <$> go next emitted nextObserved remaining

forGameTrace :: PlayerId -> ([Observation] -> QC.Property) -> QC.Property
forGameTrace viewer assertion = QC.forAll genGameCommands $ \commands ->
  case replayFor viewer commands of
    Left fault -> QC.counterexample ("Generated script was rejected: " ++ fault) False
    Right observations ->
      QC.counterexample "Script generator violated the independent fleet contract"
        (all validGeneratedFleet [request | (_, PlaceFleet request) <- commands]) QC..&&. assertion observations

everyObservation :: (GameState -> PlayerView -> QC.Property) -> [Observation] -> QC.Property
everyObservation assertion observations = QC.conjoin
  [ QC.counterexample ("Transition " ++ show index ++ ", phase " ++ show (gamePhase state)) (assertion state observed)
  | (index, (state, _, observed)) <- zip [0 :: Int ..] observations ]

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
