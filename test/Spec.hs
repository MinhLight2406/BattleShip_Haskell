module Main (main) where

import qualified BoardSpec
import qualified CoordinatorSpec
import qualified IntegrationSpec
import qualified ProtocolSpec
import qualified RulesSpec
import qualified ServerSpec
import qualified SharedContractSpec
import Test.Hspec (hspec)
import qualified TypesSpec
import qualified ViewSpec

main :: IO ()
main = hspec $ do
  TypesSpec.spec
  BoardSpec.spec
  RulesSpec.spec
  ViewSpec.spec
  ProtocolSpec.spec
  SharedContractSpec.spec
  CoordinatorSpec.spec
  ServerSpec.spec
  IntegrationSpec.spec
