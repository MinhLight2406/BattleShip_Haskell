module Main (main) where

import Battleship.Types
import Battleship.View (viewFor)
import Control.Exception (evaluate)
import qualified Data.Map.Strict as Map
import Data.List (nub)
import Fixtures
import Test.Hspec
import TestSupport.Generators (validGeneratedFleet)

main :: IO ()
main = hspec $ describe "NM-03 reproducible benchmark" $ do
  mapM_ seedSpec seeds
  it "uses distinct workloads for the fixed seeds" $
    length (nub (map (fixtureJSON . fixture) seeds)) `shouldBe` 3
  it "fully forces a fleet field in the second player's view" $ do
    let view = (viewFor P2 initialGameState) { ownFleetView = error "unforced fleet" }
    evaluate (digestTrace [(initialGameState, Right [], viewFor P1 initialGameState, view)]) `shouldThrow` anyErrorCall
  it "fully forces a nested ship ID in a shot outcome" $ do
    let player = PlayerState Nothing (Map.singleton (Coord 1 1) (Sunk (error "unforced outcome")))
        state = initialGameState { gamePlayer1 = player }
    evaluate (digestTrace [(state, Right [], viewFor P1 state, viewFor P2 state)]) `shouldThrow` anyErrorCall

seedSpec :: Int -> Spec
seedSpec seed = describe ("seed " ++ show seed) $ do
  let value = fixture seed
      trace = replayPure initialGameState (entries value)
  it "generates the same valid fleets and command sequence twice" $ do
    value `shouldBe` fixture seed
    validGeneratedFleet (fleet1 value) `shouldBe` True
    validGeneratedFleet (fleet2 value) `shouldBe` True
  it "completes a game with concrete error/hit/miss/sunk/win expectations" $ do
    length trace `shouldBe` 25
    let (state, _, _, _) = case reverse trace of
          row : _ -> row
          [] -> error "Empty benchmark trace"
        events = concat [observed | (_, Right observed, _, _) <- trace]
    gamePhase state `shouldBe` Finished P1 AllShipsSunk
    length [() | ShotResolved _ _ Miss <- events] `shouldBe` 2
    length [() | ShotResolved _ _ Hit <- events] `shouldBe` 12
    length [() | ShotResolved _ _ (Sunk _) <- events] `shouldBe` 4
    length [() | ShotResolved _ _ Win <- events] `shouldBe` 1
    length [() | (_, Left _, _, _) <- trace] `shouldBe` 4
    Map.size (playerShots (gamePlayer1 state)) `shouldBe` 18
    Map.size (playerShots (gamePlayer2 state)) `shouldBe` 1
  it "agrees with real STM coordinator and all filtered response batches" $ do
    actual <- replayCoordinator (entries value)
    actual `shouldBe` trace
    digestTrace actual `shouldBe` digestTrace trace
  it "agrees with the capability-local worker and every private frame" $ do
    actual <- replayWorker (entries value)
    actual `shouldBe` trace
    digestTrace actual `shouldBe` digestTrace trace
  it "has a stable checksum across fresh executions" $
    digestTrace (replayPure initialGameState (entries (fixture seed))) `shouldBe` case seed of
      424242 -> 3724987551376790105
      8675309 -> 18305205042670867969
      20261011 -> 658854099022739308
      _ -> error "Seed has no frozen pre-optimization checksum"
