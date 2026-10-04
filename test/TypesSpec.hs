module TypesSpec (spec) where

import Battleship.Types
import Battleship.Rules (step)
import Control.Monad (foldM, forM_)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
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

firstPlayer :: PlayerState
firstPlayer = gamePlayer1 playingState

secondPlayer :: PlayerState
secondPlayer = gamePlayer2 playingState

playingState :: GameState
playingState = case foldM (\state (actor, command) -> fst <$> step actor command state) initialGameState
  [(P1, PlaceFleet (placements 1)), (P2, PlaceFleet (placements 6)),
   (P1, Fire (Coord 1 6)), (P1, Fire (Coord 10 10)), (P2, Fire (Coord 10 10))] of
  Right state -> state
  Left fault -> error ("Invalid TypesSpec command fixture: " ++ show fault)
  where
    placements startRow = [ShipPlacement ship (Coord 1 row) Horizontal |
      (ship, row) <- zip [Carrier, Battleship, Cruiser, Submarine, Destroyer] [startRow ..]]
