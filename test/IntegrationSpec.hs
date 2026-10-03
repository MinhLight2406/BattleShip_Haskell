module IntegrationSpec (spec) where

import System.Exit (ExitCode (ExitSuccess))
import System.Process (readProcessWithExitCode)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "C-01 executable smoke tests" $ do
  it "server starts, prints its skeleton message, and exits successfully" $
    checkExecutable "battleship-server" "Battleship server: skeleton ready."

  it "client starts, prints its skeleton message, and exits successfully" $
    checkExecutable "battleship-client" "Battleship client: skeleton ready."

checkExecutable :: FilePath -> String -> Expectation
checkExecutable executable expectedMessage = do
  (exitCode, stdoutText, stderrText) <- readProcessWithExitCode executable [] ""
  exitCode `shouldBe` ExitSuccess
  lines stdoutText `shouldBe` [expectedMessage]
  stderrText `shouldBe` ""
