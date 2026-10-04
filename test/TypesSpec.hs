module TypesSpec (spec) where

import Battleship.Types
import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import qualified Data.Set as Set
import Data.Typeable (typeRep)
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe)

spec :: Spec
spec = do
  describe "R-01 board and ship constants" $ do
    it "uses a 10 by 10 board" $
      boardSize `shouldBe` 10

    forM_ expectedShips $ \(ship, expectedLength) ->
      it (show ship ++ " has the specified length") $
        shipLength ship `shouldBe` expectedLength

    it "contains exactly the five ship identities in R-01" $
      ([minBound .. maxBound] :: [ShipId]) `shouldBe` map fst expectedShips

    it "contains 17 occupied cells in a complete fleet" $
      sum (map shipLength [minBound .. maxBound]) `shouldBe` 17

  describe "PlayerId and otherPlayer" $ do
    it "contains exactly two player identities" $
      ([minBound .. maxBound] :: [PlayerId]) `shouldBe` [P1, P2]

    forM_ [(P1, P2), (P2, P1)] $ \(player, opponent) ->
      it (show player ++ " selects the other player") $
        otherPlayer player `shouldBe` opponent

    it "selecting the opponent twice returns the original identity" $
      forM_ [P1, P2] $ \player -> do
        otherPlayer (otherPlayer player) `shouldBe` player
        otherPlayer player `shouldNotBe` player

  describe "initialGameState" $ do
    it "begins in placement with no active turn or winner" $
      gamePhase initialGameState `shouldBe` Placing

    forM_ [P1, P2] $ \player ->
      it (show player ++ " has an explicitly absent fleet and no fired shots") $ do
        let state = playerStateFor player initialGameState
        playerFleet state `shouldBe` Nothing
        playerShots state `shouldBe` Map.empty

  describe "separate immutable player states" $ do
    forM_ [(P1, firstPlayer), (P2, secondPlayer)] $ \(player, expected) -> do
      it ("selects the correct state for " ++ show player) $
        playerStateFor player playingState `shouldBe` expected

      it ("placing " ++ show player ++ " alone leaves the opponent unready") $ do
        let updated = setPlayerState player expected initialGameState
        playerFleet (playerStateFor player updated) `shouldBe` playerFleet expected
        playerFleet (playerStateFor (otherPlayer player) updated) `shouldBe` Nothing
        gamePhase updated `shouldBe` Placing
        playerFleet (playerStateFor player initialGameState) `shouldBe` Nothing

      forM_ [Placing, Turn P1, Turn P2, Finished P1 AllShipsSunk,
             Finished P2 AllShipsSunk, Finished P1 OpponentLeft,
             Finished P2 OpponentLeft] $ \phase ->
        it ("updates only " ++ show player ++ " and preserves " ++ show phase) $ do
          -- These are record-update fixtures, not validated Rules transitions.
          let original = playingState { gamePhase = phase }
              replacement = expected { playerShots = Map.singleton (Coord 10 9) Miss }
              updated = setPlayerState player replacement original
          playerStateFor player updated `shouldBe` replacement
          playerStateFor (otherPlayer player) updated
            `shouldBe` playerStateFor (otherPlayer player) original
          gamePhase updated `shouldBe` phase
          playerStateFor player original `shouldBe` expected

    it "updates to distinct players commute without losing either fleet" $ do
      let firstThenSecond = setPlayerState P2 secondPlayer
            (setPlayerState P1 firstPlayer initialGameState)
          secondThenFirst = setPlayerState P1 firstPlayer
            (setPlayerState P2 secondPlayer initialGameState)
      firstThenSecond `shouldBe` secondThenFirst
      gamePlayer1 firstThenSecond `shouldBe` firstPlayer
      gamePlayer2 firstThenSecond `shouldBe` secondPlayer

  describe "published function type contracts (not gameplay implementations)" $ do
    it "step accepts socket identity, command, state and returns error or state/events" $
      typeRep (Proxy :: Proxy Step) `shouldBe`
        typeRep (Proxy :: Proxy
          (PlayerId -> Command -> GameState -> Either GameError (GameState, [Event])))

    it "placeFleet accepts a complete request and returns an error or fleet" $
      typeRep (Proxy :: Proxy PlaceFleetFn) `shouldBe`
        typeRep (Proxy :: Proxy (FleetPlacement -> Either GameError Fleet))

    it "viewFor returns a PlayerView instead of a raw GameState" $
      typeRep (Proxy :: Proxy ViewFor) `shouldBe`
        typeRep (Proxy :: Proxy (PlayerId -> GameState -> PlayerView))

expectedShips :: [(ShipId, Int)]
expectedShips =
  [(Carrier, 5), (Battleship, 4), (Cruiser, 3), (Submarine, 3), (Destroyer, 2)]

-- The example PLACE command in protocol.md occupies five separate rows.
firstFleet :: Fleet
firstFleet = Fleet $ Map.fromList
  [ (Carrier, cells 1 5)
  , (Battleship, cells 2 4)
  , (Cruiser, cells 3 3)
  , (Submarine, cells 4 3)
  , (Destroyer, cells 5 2)
  ]
  where
    cells row count = Set.fromList [Coord column row | column <- [1 .. count]]

secondFleet :: Fleet
secondFleet = Fleet $ Map.map (Set.map moveDown) (fleetShips firstFleet)
  where
    moveDown coord = coord { coordRow = coordRow coord + 5 }

firstPlayer :: PlayerState
firstPlayer = PlayerState (Just firstFleet) (Map.singleton (Coord 1 6) Hit)

secondPlayer :: PlayerState
secondPlayer = PlayerState (Just secondFleet) (Map.singleton (Coord 10 10) Miss)

playingState :: GameState
playingState = GameState firstPlayer secondPlayer (Turn P1)
