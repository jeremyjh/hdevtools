module Cabal
  ( getPackageGhcOpts
  ) where

import Data.Char (isSpace)
import Data.List (foldl', nub, isPrefixOf)
import Data.Monoid (Monoid(..))

import Distribution.PackageDescription (Executable(..), TestSuite(..), Benchmark(..), emptyHookedBuildInfo)
import Distribution.PackageDescription.Parse (readPackageDescription)
import Distribution.Simple.Configure (configure)
import Distribution.Simple.LocalBuildInfo (LocalBuildInfo(..), ComponentLocalBuildInfo(..), Component(..), ComponentName(..), allComponentsBy, componentBuildInfo, foldComponent)
import Distribution.Simple.Compiler (PackageDB(..))
import Distribution.Simple.GHC (componentGhcOptions)
import Distribution.Simple.Program (defaultProgramConfiguration)
import Distribution.Simple.Program.Db (lookupProgram)
import Distribution.Simple.Program.Types (ConfiguredProgram(programVersion), simpleProgram)
import Distribution.Simple.Program.GHC (GhcOptions(..), renderGhcOptions)
import Distribution.Simple.Setup (ConfigFlags(..), defaultConfigFlags)
import Distribution.Verbosity (silent)
import Distribution.Version (Version(..))

import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, splitFileName, (</>))

componentName :: Component -> ComponentName
componentName =
    foldComponent (const CLibName)
                  (CExeName . exeName)
                  (CTestName . testName)
                  (CBenchName . benchmarkName)

getComponentLocalBuildInfo :: LocalBuildInfo -> ComponentName -> ComponentLocalBuildInfo
getComponentLocalBuildInfo lbi CLibName =
    case libraryConfig lbi of
        Nothing -> error $ "internal error: missing library config"
        Just clbi -> clbi
getComponentLocalBuildInfo lbi (CExeName name) =
    case lookup name (executableConfigs lbi) of
        Nothing -> error $ "internal error: missing config for executable " ++ name
        Just clbi -> clbi
getComponentLocalBuildInfo lbi (CTestName name) =
    case lookup name (testSuiteConfigs lbi) of
        Nothing -> error $ "internal error: missing config for test suite " ++ name
        Just clbi -> clbi
getComponentLocalBuildInfo lbi (CBenchName name) =
    case lookup name (testSuiteConfigs lbi) of
        Nothing -> error $ "internal error: missing config for benchmark " ++ name
        Just clbi -> clbi


getPackageGhcOpts :: FilePath -> IO (Either String [String])
getPackageGhcOpts path = do
    genPkgDescr <- readPackageDescription silent path

    let cfgFlags' = (defaultConfigFlags defaultProgramConfiguration)

    let sandboxConfig = takeDirectory path </> "cabal.sandbox.config"
    exists <- doesFileExist sandboxConfig

    cfgFlags <- case exists of
                     False -> return cfgFlags'
                     True -> do
                         sandboxPackageDb <- getSandboxPackageDB sandboxConfig
                         return $ cfgFlags'
                                      { configPackageDBs = [Just $ sandboxPackageDb]
                                      }

    localBuildInfo <- configure (genPkgDescr, emptyHookedBuildInfo) cfgFlags
    let baseDir = fst . splitFileName $ path
    case getGhcVersion localBuildInfo of
        Nothing -> return $ Left "GHC is not configured"
        Just ghcVersion -> do
            let ghcOpts' = foldl' mappend mempty $ map (getComponentGhcOptions localBuildInfo) $ flip allComponentsBy (\c -> c) . localPkgDescr $ localBuildInfo
                -- FIX bug in GhcOptions' `mappend`
                ghcOpts = ghcOpts' { ghcOptPackageDBs = nub (ghcOptPackageDBs ghcOpts')
                                   , ghcOptPackages = nub (ghcOptPackages ghcOpts')
                                   , ghcOptSourcePath = map (baseDir </>) (ghcOptSourcePath ghcOpts')
                                   }
            return $ Right $ renderGhcOptions ghcVersion ghcOpts

    where
    getComponentGhcOptions :: LocalBuildInfo -> Component -> GhcOptions
    getComponentGhcOptions lbi comp =
        componentGhcOptions silent lbi bi clbi (buildDir lbi)

      where bi   = componentBuildInfo comp
            clbi = getComponentLocalBuildInfo lbi (componentName comp)

    getGhcVersion :: LocalBuildInfo -> Maybe Version
    getGhcVersion lbi = let db = withPrograms lbi
                         in do ghc <- lookupProgram (simpleProgram "ghc") db
                               programVersion ghc

    getSandboxPackageDB :: FilePath -> IO PackageDB
    getSandboxPackageDB sandboxPath = do
        contents <- readFile sandboxPath
        return $ SpecificPackageDB $ extractValue . parse $ contents
      where
        pkgDbKey = "package-db:"
        parse = head . filter (pkgDbKey `isPrefixOf`) . lines
        extractValue = fst . break isSpace . dropWhile isSpace . drop (length pkgDbKey)
