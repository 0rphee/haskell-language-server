{-# LANGUAGE CPP             #-}
{-# LANGUAGE PatternSynonyms #-}

-- | Compat module for 'UnitState' and 'UnitInfo'.
module Development.IDE.GHC.Compat.Units (
    -- * UnitState
    UnitState,
    initUnits,
    oldInitUnits,
    unitState,
    getUnitName,
    explicitUnits,
    preloadClosureUs,
    listVisibleModuleNames,
    LookupResult(..),
    lookupModuleWithSuggestions,
    -- * UnitInfoMap
    UnitInfoMap,
    getUnitInfoMap,
    lookupUnit,
    lookupUnit',
    -- * UnitInfo
    UnitInfo,
    unitExposedModules,
    unitDepends,
    unitHaddockInterfaces,
    mkUnit,
    unitPackageNameString,
    unitPackageVersion,
    -- * UnitId helpers
    UnitId,
    Unit,
    unitString,
    stringToUnit,
    definiteUnitId,
    defUnitId,
    installedModule,
    -- * Module
    toUnitId,
    Development.IDE.GHC.Compat.Units.moduleUnitId,
    moduleUnit,
    -- * ExternalPackageState
    ExternalPackageState(..),
    -- * Utils
    filterInplaceUnits,
    FinderCache,
    showSDocForUser',
    findImportedModule,
    ) where

import           Data.Either
import           Development.IDE.GHC.Compat.Core
import           Development.IDE.GHC.Compat.Env
import           Development.IDE.GHC.Compat.Outputable
import           Prelude                               hiding (mod)

-- See Note [Guidelines For Using CPP In GHCIDE Import Statements]

import           GHC.Types.Unique.Set
import qualified GHC.Unit.Info                         as UnitInfo
import           GHC.Unit.State                        (LookupResult, UnitInfo,
                                                        UnitInfoMap,
                                                        UnitState (unitInfoMap),
                                                        lookupUnit', mkUnit,
                                                        unitDepends,
                                                        unitExposedModules,
                                                        unitPackageNameString,
                                                        unitPackageVersion)
import qualified GHC.Unit.State                        as State
import           GHC.Unit.Types
import qualified GHC.Unit.Types                        as Unit


#if !MIN_VERSION_ghc(9,3,0)
import           GHC.Data.FastString

#endif

import qualified GHC.Data.ShortText                    as ST
import           GHC.Unit.External
import qualified GHC.Unit.Finder                       as GHC

#if !MIN_VERSION_ghc(9,3,0)
import           GHC.Unit.Env
import           GHC.Unit.Finder                       hiding
                                                       (findImportedModule)
#endif

#if MIN_VERSION_ghc(9,3,0)
import           Control.Monad
import qualified Data.List.NonEmpty                    as NE
import qualified Data.Map.Strict                       as Map
import qualified GHC
import qualified GHC.Driver.Session                    as DynFlags
import           GHC.Types.PkgQual                     (PkgQual (NoPkgQual))
import           GHC.Unit.Home.ModInfo
#endif


type PreloadUnitClosure = UniqSet UnitId

unitState :: HscEnv -> UnitState
unitState = ue_units . hsc_unit_env

#if MIN_VERSION_ghc(9,3,0)
createUnitEnvFromFlags :: NE.NonEmpty DynFlags -> HomeUnitGraph
createUnitEnvFromFlags unitDflags =
  let
    newInternalUnitEnv dflags = mkHomeUnitEnv dflags emptyHomePackageTable Nothing
    unitEnvList = NE.map (\dflags -> (homeUnitId_ dflags, newInternalUnitEnv dflags)) unitDflags
  in
    unitEnv_new (Map.fromList (NE.toList (unitEnvList)))

initUnits :: [DynFlags] -> HscEnv -> IO HscEnv
initUnits unitDflags env = do
  let dflags0         = hsc_dflags env
  -- additionally, set checked dflags so we don't lose fixes
  let initial_home_graph = createUnitEnvFromFlags (dflags0 NE.:| unitDflags)
      home_units = unitEnv_keys initial_home_graph
  home_unit_graph <- forM initial_home_graph $ \homeUnitEnv -> do
    let cached_unit_dbs = homeUnitEnv_unit_dbs homeUnitEnv
        dflags = homeUnitEnv_dflags homeUnitEnv
        old_hpt = homeUnitEnv_hpt homeUnitEnv

    (dbs,unit_state,home_unit,mconstants) <- State.initUnits (hsc_logger env) dflags cached_unit_dbs home_units

    updated_dflags <- DynFlags.updatePlatformConstants dflags mconstants
    pure HomeUnitEnv
      { homeUnitEnv_units = unit_state
      , homeUnitEnv_unit_dbs = Just dbs
      , homeUnitEnv_dflags = updated_dflags
      , homeUnitEnv_hpt = old_hpt
      , homeUnitEnv_home_unit = Just home_unit
      }

  let dflags1 = homeUnitEnv_dflags $ unitEnv_lookup (homeUnitId_ dflags0) home_unit_graph
  let unit_env = UnitEnv
        { ue_platform        = targetPlatform dflags1
        , ue_namever         = GHC.ghcNameVersion dflags1
        , ue_home_unit_graph = home_unit_graph
        , ue_current_unit    = homeUnitId_ dflags0
        , ue_eps             = ue_eps (hsc_unit_env env)
        }
  pure $ hscSetFlags dflags1 $ hscSetUnitEnv unit_env env
#else
initUnits :: [DynFlags] -> HscEnv -> IO HscEnv
initUnits _df env = pure env -- Can't do anything here, oldInitUnits should already be called
#endif


-- | oldInitUnits only needs to modify DynFlags for GHC <9.2
-- For GHC >= 9.2, we need to set the hsc_unit_env also, that is
-- done later by initUnits
oldInitUnits :: DynFlags -> IO DynFlags
oldInitUnits = pure

explicitUnits :: UnitState -> [Unit]
explicitUnits ue =
#if MIN_VERSION_ghc(9,3,0)
  map fst $ State.explicitUnits ue
#else
  State.explicitUnits ue
#endif

listVisibleModuleNames :: HscEnv -> [ModuleName]
listVisibleModuleNames env =
  State.listVisibleModuleNames $ unitState env

getUnitName :: HscEnv -> UnitId -> Maybe PackageName
getUnitName env i =
  State.unitPackageName <$> State.lookupUnitId (unitState env) i

lookupModuleWithSuggestions
  :: HscEnv
  -> ModuleName
#if MIN_VERSION_ghc(9,3,0)
  -> GHC.PkgQual
#else
  -> Maybe FastString
#endif
  -> LookupResult
lookupModuleWithSuggestions env modname mpkg =
  State.lookupModuleWithSuggestions (unitState env) modname mpkg

getUnitInfoMap :: HscEnv -> UnitInfoMap
getUnitInfoMap =
  unitInfoMap . ue_units . hsc_unit_env

lookupUnit :: HscEnv -> Unit -> Maybe UnitInfo
lookupUnit env pid = State.lookupUnit (unitState env) pid

preloadClosureUs :: HscEnv -> PreloadUnitClosure
preloadClosureUs = State.preloadClosure . unitState

unitHaddockInterfaces :: UnitInfo -> [FilePath]
unitHaddockInterfaces =
  fmap ST.unpack . UnitInfo.unitHaddockInterfaces

-- ------------------------------------------------------------------
-- Backwards Compatible UnitState
-- ------------------------------------------------------------------

-- ------------------------------------------------------------------
-- Patterns and helpful definitions
-- ------------------------------------------------------------------

definiteUnitId :: Definite uid -> GenUnit uid
definiteUnitId         = RealUnit
defUnitId :: unit -> Definite unit
defUnitId              = Definite
installedModule :: unit -> ModuleName -> GenModule unit
installedModule        = Module


moduleUnitId :: Module -> UnitId
moduleUnitId =
    Unit.toUnitId . Unit.moduleUnit

filterInplaceUnits :: [UnitId] -> [PackageFlag] -> ([UnitId], [PackageFlag])
filterInplaceUnits us packageFlags =
  partitionEithers (map isInplace packageFlags)
  where
    isInplace :: PackageFlag -> Either UnitId PackageFlag
    isInplace p@(ExposePackage _ (UnitIdArg u) _) =
      if toUnitId u `elem` us
        then Left $ toUnitId  u
        else Right p
    isInplace p = Right p

showSDocForUser' :: HscEnv -> PrintUnqualified -> SDoc -> String
showSDocForUser' env = showSDocForUser (hsc_dflags env) (unitState env)

findImportedModule :: HscEnv -> ModuleName -> IO (Maybe Module)
findImportedModule env mn = do
#if MIN_VERSION_ghc(9,3,0)
    res <- GHC.findImportedModule env mn NoPkgQual
#else
    res <- GHC.findImportedModule env mn Nothing
#endif
    case res of
        Found _ mod -> pure . pure $ mod
        _           -> pure Nothing
