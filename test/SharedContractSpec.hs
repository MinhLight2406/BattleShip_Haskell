module SharedContractSpec (spec) where

import Control.Monad (forM, forM_)
import Data.Char (isSpace)
import Data.List (dropWhileEnd, isInfixOf, isPrefixOf, nub, sort, tails)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>), takeExtension)
import Test.Hspec (Spec, beforeAll, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "S-01 shared contract" $ do
  it "reads the same contract fixture from LF and Windows CRLF documents" $ do
    let lf = "<!-- contract:owners -->\n```text\napp/ServerMain.hs C\n```\n"
        crlf = concatMap (\character -> if character == '\n' then "\r\n" else [character]) lf
    fixture "contract:owners" "text" lf `shouldBe` "app/ServerMain.hs C\n"
    fixture "contract:owners" "text" crlf `shouldBe` "app/ServerMain.hs C\n"
  describe "source declaration check" $ do
    it "finds data, newtype and aliases including multiline declarations" $
      declaredSharedTypes "data\n Coord = Coord Int Int\nnewtype Command = C Int\ntype Coord = Int"
        `shouldBe` ["Coord", "Command", "Coord"]

    it "ignores line comments, nested block comments and string/character literals" $
      declaredSharedTypes (unlines
        ["-- data Coord = C", "{- type Command = Int {- data Coord = C -} -}",
         "message = \"data Command = Quit\"", "character = 'x'",
         "data Coord = Coord Int Int"]) `shouldBe` ["Coord"]

    it "does not confuse references, signatures or longer names with declarations" $
      declaredSharedTypes "fire :: Coord -> Command\ndata CoordView = V Coord\nf = Command"
        `shouldBe` []

    it "also detects a family declaration under the shared type name" $
      declaredSharedTypes "type family Coord a\ndata family Command a"
        `shouldBe` ["Coord", "Command"]

  beforeAll loadRepository $ describe "repository matches the review document" $ do
    it "keeps all domain constructors, fields and signature aliases in sync" $ \(document, sources) -> do
      let actual = haskellTokens (sourceFor "src/Battleship/Types.hs" sources)
          declarations = takeUntil ["boardSize", "::"] (dropUntil ["data", "PlayerId"] actual)
          expected = haskellTokens (fixture "contract:domain-api" "haskell" document)
      expected `shouldSatisfy` (not . null)
      declarations `shouldBe` expected

    it "allows Coord only in Battleship.Types across src, app and test" $ \(_, sources) ->
      declarationFiles "Coord" sources `shouldBe` ["src/Battleship/Types.hs"]

    it "allows Command only in Battleship.Types across src, app and test" $ \(_, sources) ->
      declarationFiles "Command" sources `shouldBe` ["src/Battleship/Types.hs"]

    it "keeps Fleet abstract and restricts private representation access to Board/Types" $ \(_, sources) -> do
      let exports = takeUntil ["where"] (haskellTokens (sourceFor "src/Battleship/Types.hs" sources))
          privateModule = haskellTokens "Battleship.Internal.Fleet"
          users = [path | (path, source) <- sources, path /= "src/Battleship/Internal/Fleet.hs",
                          privateModule `isInfixOf` haskellTokens source]
      exports `shouldSatisfy` (not . isInfixOf ["Fleet", "("])
      exports `shouldSatisfy` elem "fleetShips"
      users `shouldBe` ["src/Battleship/Board.hs", "src/Battleship/Types.hs"]

    it "lists every Haskell source and build configuration exactly once with an owner" $ \(document, sources) -> do
      let rows = map words (lines (fixture "contract:owners" "text" document))
          entries = [(path, owner) | [path, owner] <- rows]
          paths = map fst entries
      length entries `shouldBe` length rows
      sort paths `shouldBe` sort (map fst sources ++ ["package.yaml", "stack.yaml"])
      length (nub paths) `shouldBe` length paths
      map snd entries `shouldSatisfy` all (`elem` ["A", "B", "C", "D", "R"])

    it "keeps the two IO entry points in separate Main components" $ \(_, sources) -> do
      let entryPoints = ["app/ServerMain.hs", "app/ClientMain.hs"]
      forM_ entryPoints $ \path -> do
        let tokens = haskellTokens (sourceFor path sources)
        take 6 tokens `shouldBe` ["module", "Main", "(", "main", ")", "where"]
        tokens `shouldSatisfy` isInfixOf ["main", "::", "IO", "(", ")"]

-- Repository check, not a Haskell compiler. GHC and existing TypesSpec remain
-- responsible for resolving imports and type checking. Lexing skips comments
-- and treats literals as tokens so examples do not look like declarations.
haskellTokens :: String -> [String]
haskellTokens source = case dropWhile isSpace source of
  [] -> []
  '-' : '-' : rest -> haskellTokens (dropWhile (/= '\n') rest)
  '{' : '-' : rest -> haskellTokens (skipBlock 1 rest)
  input -> case lex input of
    [(token, rest)] | not (null token) -> token : haskellTokens rest
    _ -> error "S-01: cannot tokenize Haskell source"
  where
    skipBlock :: Int -> String -> String
    skipBlock _ [] = error "S-01: unclosed block comment"
    skipBlock depth ('{' : '-' : rest) = skipBlock (depth + 1) rest
    skipBlock 1 ('-' : '}' : rest) = rest
    skipBlock depth ('-' : '}' : rest) = skipBlock (depth - 1) rest
    skipBlock depth (_ : rest) = skipBlock depth rest

declaredSharedTypes :: String -> [String]
declaredSharedTypes source =
  [name | suffix <- tails (haskellTokens source),
          Just name <- [declaredName suffix], name `elem` ["Coord", "Command"]]
  where
    declaredName (keyword : modifier : name : _)
      | keyword `elem` ["data", "type"] && modifier `elem` ["family", "instance"] = Just name
    declaredName (keyword : name : _)
      | keyword `elem` ["data", "newtype", "type"] = Just name
    declaredName _ = Nothing

declarationFiles :: String -> [(FilePath, String)] -> [FilePath]
declarationFiles name sources =
  [path | (path, source) <- sources, declared <- declaredSharedTypes source, declared == name]

dropUntil :: Eq a => [a] -> [a] -> [a]
dropUntil prefix tokens = case dropWhile (not . isPrefixOf prefix) (tails tokens) of
  suffix : _ -> suffix
  [] -> error "S-01: missing API boundary"

takeUntil :: Eq a => [a] -> [a] -> [a]
takeUntil prefix tokens
  | prefix `isPrefixOf` tokens = []
takeUntil _ [] = error "S-01: missing API boundary"
takeUntil prefix (token : rest) = token : takeUntil prefix rest

fixture :: String -> String -> String -> String
fixture marker language document =
  case dropWhile (/= "<!-- " ++ marker ++ " -->") (map (dropWhileEnd (== '\r')) (lines document)) of
    _ : fence : rest | fence == "```" ++ language -> case break (== "```") rest of
      (body, _ : _) -> unlines body
      _ -> error ("S-01: unclosed fixture " ++ marker)
    _ -> error ("S-01: missing fixture " ++ marker)

sourceFor :: FilePath -> [(FilePath, String)] -> String
sourceFor path = maybe (error ("S-01: missing source " ++ path)) id . lookup path

loadRepository :: IO (String, [(FilePath, String)])
loadRepository = do
  document <- readFile "docs/shared_contract.md"
  paths <- concat <$> mapM haskellFiles ["src", "app", "test", "bench"]
  sources <- forM (sort paths) $ \path -> do
    source <- readFile path
    pure (map (\character -> if character == '\\' then '/' else character) path, source)
  pure (document, sources)

haskellFiles :: FilePath -> IO [FilePath]
haskellFiles directory = do
  names <- listDirectory directory
  concat <$> forM names (\name -> do
    let path = directory </> name
    isDirectory <- doesDirectoryExist path
    if isDirectory then haskellFiles path
      else pure [path | takeExtension path == ".hs"])
