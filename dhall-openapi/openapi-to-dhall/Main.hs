{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RecordWildCards #-}

module Main (main) where

import Control.Applicative.Combinators (option, sepBy1)
import Data.Aeson                      (decodeFileStrict, eitherDecodeFileStrict)
import Data.Bifunctor                  (bimap)
import Data.Foldable                   (for_)
import Data.Maybe                      (isJust)
import Data.Text                       (Text, pack, unpack)
import Data.Void                       (Void)
import Dhall.Core                      (Expr (..))
import Dhall.Format                    (Format (..))
import Numeric.Natural                 (Natural)
import Text.Megaparsec
    ( Parsec
    , errorBundlePretty
    , parse
    , some
    , optional
    , (<|>)
    , eof
    )
import Text.Megaparsec.Char            (alphaNumChar, char)

import Dhall.Kubernetes.Data           (patchCyclicImports)
import Dhall.Kubernetes.Types
    ( DuplicateHandler
    , AliasConverter
    , ModelName (..)
    , ModelHierarchy
    , Prefix
    , Swagger (..)
    )
import System.FilePath                  (FilePath, (</>))

import qualified Data.List                             as List
import qualified Data.Map.Strict                       as Data.Map
import qualified Data.Ord                              as Ord
import qualified Data.Text                             as Text
import qualified Data.Text.IO                          as Text
import qualified Data.Text.Prettyprint.Doc             as Pretty
import qualified Data.Text.Prettyprint.Doc.Render.Text as PrettyText
import qualified Dhall.Core                            as Dhall
import qualified Dhall.Format
import qualified Dhall.Kubernetes.Convert              as Convert
import qualified Dhall.Kubernetes.Types                as Types
import qualified Dhall.Map
import qualified Dhall.Parser
import qualified Dhall.Util
import qualified GHC.IO.Encoding
import qualified Options.Applicative
import qualified System.IO
import qualified System.Directory                      as Directory
import qualified Text.Megaparsec                       as Megaparsec
import qualified Text.Megaparsec.Char.Lexer            as Megaparsec.Lexer

-- | Top-level program options
data Options = Options
    { duplicates :: Duplicates
    , prefixMap :: Data.Map.Map Prefix Dhall.Import
    , splits :: Data.Map.Map ModelHierarchy (Maybe ModelName)
    , filename :: String
    , crd :: Bool
    }

data Duplicates = Skip | PreferHeuristic | Full | FullNested
  deriving (Eq, Show, Read, Bounded, Enum)

-- | Write and format a Dhall expression to a file
writeDhall :: FilePath -> Types.Expr -> IO ()
writeDhall path expr = do
  putStrLn $ "Writing file '" <> path <> "'"
  Text.writeFile path $ pretty expr <> "\n"

  let chosenCharacterSet = Nothing -- Infer from input

  let censor = Dhall.Util.NoCensor

  let outputMode = Dhall.Util.Write

  let input =
        Dhall.Util.PossiblyTransitiveInputFile
            path
            Dhall.Util.NonTransitive

  let formatOptions = Dhall.Format.Format{..}

  Dhall.Format.format formatOptions

-- | Pretty print things
pretty :: Pretty.Pretty a => a -> Text
pretty = PrettyText.renderStrict
  . Pretty.layoutPretty Pretty.defaultLayoutOptions
  . Pretty.pretty

data Stability = Alpha Natural | Beta Natural | Production deriving (Eq, Ord)

data Version = Version
    { stability :: Stability
    , version :: Natural
    } deriving (Eq, Ord)

parseStability :: Parsec Void Text Stability
parseStability = parseAlpha <|> parseBeta <|> parseProduction
  where
    parseAlpha = do
        _ <- "alpha"
        n <- Megaparsec.Lexer.decimal
        return (Alpha n)

    parseBeta = do
        _ <- "beta"
        n <- Megaparsec.Lexer.decimal
        return (Beta n)

    parseProduction = do
        return Production

parseVersion :: Parsec Void Text Version
parseVersion = Megaparsec.try parseSuffix <|> parsePrefix
  where
    parseComponent = do
        Megaparsec.takeWhile1P (Just "not a period") (/= '.')

    parseSuffix = do
        _ <- "v"
        version <- Megaparsec.Lexer.decimal
        stability <- parseStability
        _ <- "."
        _ <- parseComponent
        Megaparsec.eof
        return Version{..}

    parsePrefix = do
        _ <- parseComponent
        _ <- "."
        parseVersion

getVersion :: ModelName -> Maybe Version
getVersion ModelName{..} =
    case Megaparsec.parse parseVersion "" unModelName of
        Left  _       -> Nothing
        Right version -> Just version

-- https://github.com/dhall-lang/dhall-kubernetes/issues/112
data Autoscaling = AutoscalingV1 | AutoscalingV2beta1 | AutoscalingV2beta2
    deriving (Eq, Ord)

getAutoscaling :: ModelName -> Maybe Autoscaling
getAutoscaling ModelName{..}
    | Text.isPrefixOf "io.k8s.api.autoscaling.v1"      unModelName =
        Just AutoscalingV1
    | Text.isPrefixOf "io.k8s.api.autoscaling.v2beta1" unModelName =
        Just AutoscalingV2beta1
    | Text.isPrefixOf "io.k8s.api.autoscaling.v2beta2" unModelName =
        Just AutoscalingV2beta2
    | otherwise =
        Nothing

isK8sNative :: ModelName -> Bool
isK8sNative ModelName{..} = Text.isPrefixOf "io.k8s." unModelName

preferStableResource :: DuplicateHandler
preferStableResource (names) = do
    let issue112 = Ord.comparing getAutoscaling
    let k8sOverCrd = Ord.comparing isK8sNative
    let defaultComparison = Ord.comparing getVersion
    let comparison = issue112 <> k8sOverCrd <> defaultComparison
    return (List.maximumBy comparison names)

skipDuplicatesHandler :: DuplicateHandler
skipDuplicatesHandler = const Nothing

errorDuplicatesHandler :: DuplicateHandler
errorDuplicatesHandler models = error $ "Found conflicting model names: " ++ (List.intercalate ", " $ fmap show models)

getDuplicatesHandler :: Duplicates -> DuplicateHandler
getDuplicatesHandler Skip = skipDuplicatesHandler
getDuplicatesHandler PreferHeuristic = preferStableResource
getDuplicatesHandler _ = errorDuplicatesHandler

getAliasConverter :: Duplicates -> AliasConverter
getAliasConverter Full = toFullModelName
getAliasConverter FullNested = toFullModelName
getAliasConverter _ = toSimpleModelName

toSimpleModelName :: AliasConverter
toSimpleModelName (ModelName name) =
  let elems = Text.split (== '.') name
  in elems List.!! (length elems - 1)

toFullModelName :: AliasConverter
toFullModelName m
  | useShortName = toSimpleModelName m
  | otherwise = unModelName m
  where
    nonPrefixed = [ModelName "io.k8s.apimachinery.pkg.util.intstr.IntOrString"] :: [ModelName]
    useShortName = m `elem` nonPrefixed

parseImport :: String -> Types.Expr -> Dhall.Parser.Parser Dhall.Import
parseImport _ (Dhall.Note _ (Dhall.Embed l)) = pure l
parseImport prefix e = fail $ "Expected a Dhall import for " <> prefix <> " not:\n" <> show e

parsePrefixMap :: Options.Applicative.ReadM (Data.Map.Map Prefix Dhall.Import)
parsePrefixMap =
  Options.Applicative.eitherReader $ \s ->
    bimap errorBundlePretty Data.Map.fromList $ result (pack s)
  where
    parser = do
      prefix <- some (alphaNumChar <|> char '.')
      char '='
      e <- Dhall.Parser.expr
      imp <- parseImport prefix e
      return (pack prefix, imp)
    result = parse ((Dhall.Parser.unParser parser `sepBy1` char ',') <* eof) "MAPPING"

parseSplits :: Options.Applicative.ReadM (Data.Map.Map ModelHierarchy (Maybe ModelName))
parseSplits =
  Options.Applicative.eitherReader $ \s ->
    bimap errorBundlePretty Data.Map.fromList $ result (pack s)
  where
    parseModelInner = some (alphaNumChar <|> char '-' <|> char '.')
    parseModel = (ModelName . pack) <$> (((char '(') *> parseModelInner <* (char ')')) <|> parseModelInner)
    parser = do
      path <- parseModel `sepBy1` char '.'
      model <- optional $ do
        char '='
        mo <- parseModel
        return mo
      return (path, model)
    result = parse ((Dhall.Parser.unParser parser `sepBy1` char ',') <* eof) "MAPPING"


parseDuplicates :: Options.Applicative.ReadM Duplicates
parseDuplicates = Options.Applicative.str >>= toDuplicates
  where
    toDuplicates :: String -> Options.Applicative.ReadM Duplicates
    toDuplicates "skip" = return Skip
    toDuplicates "prefer" = return PreferHeuristic
    toDuplicates "full" = return Full
    toDuplicates "nested" = return FullNested
    toDuplicates _ = Options.Applicative.readerError "Accepted duplicates options are 'skip', 'prefer', 'full' and 'nested'"

parseOptions :: Options.Applicative.Parser Options
parseOptions = Options <$> parseSkip <*> parsePrefixMap' <*> parseSplits' <*> fileArg <*> crdArg
  where
    parseSkip =
      option PreferHeuristic $ Options.Applicative.option parseDuplicates
        (  Options.Applicative.long "duplicates"
        <> Options.Applicative.help
           "Specify how to handle duplicates of a given model name with multiple versions and groups. \
           \prefer: (Default) Prefer types according to a heuristic i.e. stable over beta/alpha, native over CRDs. \
           \skip: Skip types with the same name when aggregating types. \
           \full: Use fully qualified names to disambiguate between model names with multiple versions and groups. \
           \nested: Similar to full but instead nests by any occurances of the '.' character."
        )
    parsePrefixMap' =
      option Data.Map.empty $ Options.Applicative.option parsePrefixMap
        (  Options.Applicative.long "prefixMap"
        <> Options.Applicative.help "Specify prefix mappings as 'prefix1=importBase1,prefix2=importBase2,...'"
        <> Options.Applicative.metavar "MAPPING"
        )
    parseSplits' =
      option Data.Map.empty $ Options.Applicative.option parseSplits
        (  Options.Applicative.long "splitPaths"
        <> Options.Applicative.help
          "Specifiy path and model name pairs with paths being delimited by '.' and pairs separated by '=' for which \
          \definitions should be aritifically split with a ref: \n\
          \'(com.example.v1.Certificate).spec=com.example.v1.CertificateSpec'\n\
          \When the model name is omitted, a guess will be made based on the first word of the definition's \
          \description. Also note that top level model names in a path must use () when the name contains '.'"
        <> Options.Applicative.metavar "SPLITS"
        )
    fileArg = Options.Applicative.strArgument
            (  Options.Applicative.help "The input file to read"
            <> Options.Applicative.metavar "FILE"
            <> Options.Applicative.action "file"
            )
    crdArg = Options.Applicative.switch
      (  Options.Applicative.long "crd"
      <> Options.Applicative.help "The input file is a custom resource definition"
      )

-- | `ParserInfo` for the `Options` type
parserInfoOptions :: Options.Applicative.ParserInfo Options
parserInfoOptions =
    Options.Applicative.info
        (Options.Applicative.helper <*> parseOptions)
        (   Options.Applicative.progDesc "Swagger to Dhall generator"
        <>  Options.Applicative.fullDesc
        )

main :: IO ()
main = do
  GHC.IO.Encoding.setLocaleEncoding System.IO.utf8

  Options{..} <- Options.Applicative.execParser parserInfoOptions

  -- Get the Definitions
  defs <-
        if crd then do
          crdFile <- eitherDecodeFileStrict filename
          case crdFile of
            Left e -> do
                fail $ "Unable to decode the CRD file. " <> show e
            Right s -> do
                case Convert.toDefinition s of
                    Left text -> do
                        fail (Text.unpack text)
                    Right result -> do
                        return (Data.Map.fromList [result])
        else do
            swaggerFile <- decodeFileStrict filename
            case swaggerFile of
              Nothing -> fail "Unable to decode the Swagger file"
              Just (Swagger{..})  -> pure definitions

  let fix m = Data.Map.adjust patchCyclicImports (ModelName m)

  -- Convert to Dhall types in a Map
  let types = Convert.toTypes prefixMap (Convert.pathSplitter splits)
        -- TODO: find a better way to deal with this cyclic import
         $ fix "io.k8s.apiextensions-apiserver.pkg.apis.apiextensions.v1beta1.JSONSchemaProps"
         $ fix "io.k8s.apiextensions-apiserver.pkg.apis.apiextensions.v1.JSONSchemaProps"
            defs

  -- Output to types
  Directory.createDirectoryIfMissing True "types"
  for_ (Data.Map.toList types) $ \(ModelName name, expr) -> do
    let path = "./types" </> unpack name <> ".dhall"
    writeDhall path expr

  -- Convert from Dhall types to defaults
  let defaults = Data.Map.mapMaybeWithKey (Convert.toDefault prefixMap defs) types

  -- Output to defaults
  Directory.createDirectoryIfMissing True "defaults"
  for_ (Data.Map.toList defaults) $ \(ModelName name, expr) -> do
    let path = "./defaults" </> unpack name <> ".dhall"
    writeDhall path expr

  let mkImport folders file = Dhall.Embed $ Convert.mkImport prefixMap folders file
  let mkImportWithModel folders (ModelName key) = mkImport folders (key <> ".dhall")

  let toSchema model _ _ =
        Dhall.RecordLit
          [ ("Type", Dhall.makeRecordField $ mkImportWithModel ["types", ".."] model)
          , ("default", Dhall.makeRecordField $ mkImportWithModel ["defaults", ".."] model)
          ]

  let schemas = Data.Map.intersectionWithKey toSchema types defaults

  let package =
        Combine
          mempty
          Nothing
          (mkImport [ ] "schemas.dhall")
          (RecordLit
              [ ( "IntOrString"
                , Dhall.makeRecordField $ Field (mkImport [ ] "types.dhall") $ Dhall.makeFieldSelection "IntOrString"
                )
              , ( "Resource", Dhall.makeRecordField $ mkImport [ ] "typesUnion.dhall")
              ]
          )

  -- Output schemas that combine both the types and defaults
  Directory.createDirectoryIfMissing True "schemas"
  for_ (Data.Map.toList schemas) $ \(ModelName name, expr) -> do
    let path = "./schemas" </> unpack name <> ".dhall"
    writeDhall path expr

  let duplicateHandler = getDuplicatesHandler duplicates
      aliasConverter = getAliasConverter duplicates
      isStandalone model = and $ (\ def -> isJust $ Types.baseData def) <$> Data.Map.lookup model defs

  let typesRecordPath = "./types.dhall"
      typesUnionPath = "./typesUnion.dhall"
      defaultsRecordPath = "./defaults.dhall"
      schemasRecordPath = "./schemas.dhall"
      packageRecordPath = "./package.dhall"

  if duplicates == FullNested
  then do
    let
        makeRecord = Convert.groupByOnParts duplicateHandler aliasConverter
        typesRecord = makeRecord
                    $ Data.Map.mapWithKey (\k _ -> mkImportWithModel ["types"] k) types
        defaultsRecord = makeRecord
                       $ Data.Map.mapWithKey (\k _ -> mkImportWithModel ["defaults"] k)
                       $ Data.Map.restrictKeys types (Data.Map.keysSet defaults)
        schemasRecord = makeRecord
                      $ Data.Map.mapWithKey (\k _ -> mkImportWithModel ["schemas"] k)
                      $ Data.Map.restrictKeys types (Data.Map.keysSet schemas)
        typesUnionMap = Dhall.Map.fromList
                      $ List.sortOn snd
                      $ Data.Map.toList
                      $ Convert.groupBy duplicateHandler aliasConverter
                      $ Data.Map.keys types
        typesUnion = Dhall.Union
                   $ fmap (Just . mkImportWithModel ["types"])
                   $ Dhall.Map.filter isStandalone typesUnionMap

    writeDhall typesUnionPath typesUnion
    writeDhall typesRecordPath typesRecord
    writeDhall defaultsRecordPath defaultsRecord
    writeDhall schemasRecordPath schemasRecord
    writeDhall packageRecordPath package
  else do

    let makeRecord = Dhall.RecordLit . fmap Dhall.makeRecordField
        typesMap = Dhall.Map.fromList
                 $ List.sortOn snd
                 $ Data.Map.toList
                 $ Convert.groupBy duplicateHandler aliasConverter
                 $ Data.Map.keys types
        defaultsMap = Dhall.Map.filter (`elem` (Data.Map.keys defaults)) typesMap
        schemasMap = Dhall.Map.filter (`elem` (Data.Map.keys schemas)) typesMap
        typesRecord = makeRecord $ fmap (mkImportWithModel ["types"]) typesMap
        typesUnion = Dhall.Union $ fmap (Just . mkImportWithModel ["types"]) $ Dhall.Map.filter isStandalone typesMap
        defaultsRecord = makeRecord $ fmap (mkImportWithModel ["defaults"]) defaultsMap
        schemasRecord = makeRecord $ fmap (mkImportWithModel ["schemas"]) schemasMap

    writeDhall typesUnionPath typesUnion
    writeDhall typesRecordPath typesRecord
    writeDhall defaultsRecordPath defaultsRecord
    writeDhall schemasRecordPath schemasRecord
    writeDhall packageRecordPath package
