module Main (main) where

import qualified BoardSpec
import qualified CoordinatorSpec
import qualified IntegrationSpec
import qualified ProtocolSpec
import qualified RulesSpec
import Test.Hspec (hspec)
import qualified ViewSpec

main :: IO ()
main = hspec $ do
  BoardSpec.spec
  RulesSpec.spec
  ViewSpec.spec
  ProtocolSpec.spec
  CoordinatorSpec.spec
  IntegrationSpec.spec
