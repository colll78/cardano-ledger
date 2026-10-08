{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Ledger.Dijkstra (
  DijkstraEra,
  ApplyTxError (..),
  mkDijkstraStAnnTopTx,
  evalDijkstraTxExUnits,
  evalDijkstraTxExUnitsWithLogs,
  DijkstraRedeemerReport,
  DijkstraRedeemerReportWithLogs,
) where

import Cardano.Ledger.Alonzo.Plutus.Context (
  EraPlutusContext (TxInfoResult, mkTxInfoResult),
  LedgerLevelTxInfo (..),
  LedgerTxInfo (..),
  SupportedPlutusRunnable (..),
  toScriptHashByPurpose,
 )
import Cardano.Ledger.Alonzo.Plutus.Evaluate (
  TransactionScriptFailure,
  evalTxExUnitsWithLogsFromLedgerTxInfo,
  scriptsWithContextFromLedgerTxInfo,
  scriptsWithContextFromLedgerTxInfoWithResult,
 )
import Cardano.Ledger.Alonzo.UTxO (
  AlonzoEraUTxO,
  AlonzoScriptsNeeded,
  resolveNeededPlutusScriptsWithPurpose,
 )
import Cardano.Ledger.BaseTypes (Inject (inject), StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Binary (DecCBOR, EncCBOR)
import Cardano.Ledger.Block (EraBlockHeader, LeiosBbodySignal (..), LeiosEraBlockHeader)
import Cardano.Ledger.Conway.Governance (RunConwayRatify)
import Cardano.Ledger.Dijkstra.Block ()
import Cardano.Ledger.Dijkstra.BlockBody ()
import Cardano.Ledger.Dijkstra.Core
import Cardano.Ledger.Dijkstra.Era
import Cardano.Ledger.Dijkstra.Forecast ()
import Cardano.Ledger.Dijkstra.Genesis ()
import Cardano.Ledger.Dijkstra.Governance ()
import Cardano.Ledger.Dijkstra.Rules (
  DijkstraLedgerPredFailure,
  DijkstraMempoolPredFailure (LedgerFailure),
 )
import Cardano.Ledger.Dijkstra.Scripts ()
import Cardano.Ledger.Dijkstra.State.CertState ()
import Cardano.Ledger.Dijkstra.State.Stake ()
import Cardano.Ledger.Dijkstra.Transition ()
import Cardano.Ledger.Dijkstra.Translation ()
import Cardano.Ledger.Dijkstra.Tx (DijkstraStAnnTx (..))
import Cardano.Ledger.Dijkstra.TxBody ()
import Cardano.Ledger.Dijkstra.TxInfo ()
import Cardano.Ledger.Dijkstra.TxWits ()
import Cardano.Ledger.Dijkstra.UTxO ()
import Cardano.Ledger.Plutus (ExUnits, Language (..), plutusLanguage)
import Cardano.Ledger.Shelley.API (
  ApplyBlock (..),
  ApplyTick (..),
  ApplyTx (..),
  defaultApplyTxWithValidation,
  defaultReapplyValidatedTx,
 )
import Cardano.Ledger.State (EraUTxO (..), ScriptsProvided, UTxO)
import Cardano.Ledger.TxIn (TxId)
import Cardano.Slotting.EpochInfo (EpochInfo)
import Cardano.Slotting.Time (SystemStart)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import GHC.Generics (Generic)
import Lens.Micro

instance ApplyTx DijkstraEra where
  newtype ApplyTxError DijkstraEra = DijkstraApplyTxError (NonEmpty (DijkstraMempoolPredFailure DijkstraEra))
    deriving (Eq, Show)
    deriving newtype (EncCBOR, DecCBOR, Semigroup, Generic)

  mkStAnnTx = mkDijkstraStAnnTopTx

  internalApplyTxWithValidation = defaultApplyTxWithValidation @"MEMPOOL" DijkstraApplyTxError

  internalReapplyValidatedTx = defaultReapplyValidatedTx @"MEMPOOL" DijkstraApplyTxError

instance ApplyTick DijkstraEra

instance (EraBlockHeader h DijkstraEra, LeiosEraBlockHeader h DijkstraEra) => ApplyBlock h DijkstraEra where
  wrapBlockSignal = LeiosBbodySignal

instance RunConwayRatify DijkstraEra

instance Inject (NonEmpty (DijkstraMempoolPredFailure DijkstraEra)) (ApplyTxError DijkstraEra) where
  inject = DijkstraApplyTxError

instance Inject (NonEmpty (DijkstraLedgerPredFailure DijkstraEra)) (ApplyTxError DijkstraEra) where
  inject = DijkstraApplyTxError . fmap LedgerFailure

mkDijkstraStAnnTopTx ::
  ( AlonzoEraUTxO era
  , AlonzoEraTx era
  , DijkstraEraTxBody era
  , EraPlutusContext era
  , ScriptsNeeded era ~ AlonzoScriptsNeeded era
  ) =>
  EpochInfo (Either Text) ->
  SystemStart ->
  PParams era ->
  UTxO era ->
  Map.Map ScriptHash (SupportedPlutusRunnable era) ->
  Tx TopTx era ->
  DijkstraStAnnTx TopTx era
mkDijkstraStAnnTopTx ei sysStart pp utxo stAnnTxCache tx =
  let
    DijkstraBatchContexts
      { dbcScriptsProvided = scriptsProvided
      , dbcPlutusRunnableCache = newStAnnTxCache
      , dbcTopContext = topContext
      , dbcSubContexts = subContexts
      } = mkDijkstraBatchContexts ei sysStart pp utxo stAnnTxCache tx
    languagesUsed =
      Set.fromList [plutusLanguage spr | (_, SupportedPlutusRunnable spr) <- dbctxScriptsUsed topContext]
   in
    DijkstraStAnnTopTx
      { dsattTx = tx
      , dsattScriptsNeeded = dbctxScriptsNeeded topContext
      , dsattScriptsProvided = scriptsProvided
      , dsattPlutusLegacyMode = not $ Set.null $ Set.filter (<= PlutusV3) languagesUsed
      , dsattPlutusRunnableCache = newStAnnTxCache
      , dsattPlutusLanguagesUsed = languagesUsed
      , dsattPlutusScriptsWithContext =
          scriptsWithContextFromLedgerTxInfo (dbctxLedgerTxInfo topContext) (pp ^. ppCostModelsL)
      , dsattSubTransactions =
          map (mkDijkstraStAnnSubTx pp scriptsProvided newStAnnTxCache) subContexts
      }

mkDijkstraStAnnSubTx ::
  ( AlonzoEraUTxO era
  , AlonzoEraTx era
  ) =>
  PParams era ->
  ScriptsProvided era ->
  Map.Map ScriptHash (SupportedPlutusRunnable era) ->
  DijkstraBodyContext SubTx era ->
  DijkstraStAnnTx SubTx era
mkDijkstraStAnnSubTx pp scriptsProvided plutusScriptsCache context =
  DijkstraStAnnSubTx
    { dsastTx = dbctxTx context
    , dsastScriptsNeeded = dbctxScriptsNeeded context
    , dsastScriptsHashesNeeded = getScriptsHashesNeeded (dbctxScriptsNeeded context)
    , dsastScriptsProvided = scriptsProvided
    , dsastTxInfoResult = dbctxTxInfoResult context
    , dsastPlutusLanguagesUsed =
        Set.fromList [plutusLanguage spr | (_, SupportedPlutusRunnable spr) <- dbctxScriptsUsed context]
    , dsastPlutusRunnableCache = plutusScriptsCache
    , dsastPlutusScriptsWithContext =
        scriptsWithContextFromLedgerTxInfoWithResult
          (dbctxLedgerTxInfo context)
          (dbctxTxInfoResult context)
          (pp ^. ppCostModelsL)
    }

-- Keep annotation metadata independent of LedgerTxInfo's strict fields, so
-- inspecting scripts or a child's transaction does not force context translation.
data DijkstraBodyContext level era = DijkstraBodyContext
  { dbctxTx :: Tx level era
  , dbctxScriptsNeeded :: ScriptsNeeded era
  , dbctxScriptsUsed :: [(PlutusPurpose AsIxItem era, SupportedPlutusRunnable era)]
  , dbctxLedgerTxInfo :: LedgerTxInfo level era
  , dbctxTxInfoResult :: TxInfoResult era
  }

data DijkstraBatchContexts era = DijkstraBatchContexts
  { dbcScriptsProvided :: ScriptsProvided era
  , dbcPlutusRunnableCache :: Map.Map ScriptHash (SupportedPlutusRunnable era)
  , dbcTopContext :: DijkstraBodyContext TopTx era
  , dbcSubContexts :: [DijkstraBodyContext SubTx era]
  }

-- | Validation and estimation use the same body-local script resolution, child
-- indexes and Guarding views. Every child shares the top-level resolver cache;
-- child cache updates are unnecessary because scriptsProvided covers the batch.
mkDijkstraBatchContexts ::
  forall era.
  ( AlonzoEraUTxO era
  , AlonzoEraTx era
  , DijkstraEraTxBody era
  , EraPlutusContext era
  , ScriptsNeeded era ~ AlonzoScriptsNeeded era
  ) =>
  EpochInfo (Either Text) ->
  SystemStart ->
  PParams era ->
  UTxO era ->
  Map.Map ScriptHash (SupportedPlutusRunnable era) ->
  Tx TopTx era ->
  DijkstraBatchContexts era
mkDijkstraBatchContexts ei sysStart pp utxo initialCache tx =
  DijkstraBatchContexts
    { dbcScriptsProvided = scriptsProvided
    , dbcPlutusRunnableCache = scriptsCache
    , dbcTopContext = topContext
    , dbcSubContexts = subContexts
    }
  where
    protVer = pp ^. ppProtocolVersionL
    scriptsProvided = getScriptsProvided utxo tx
    (scriptsCache, topContext) =
      mkContext
        ( LedgerTopTxInfo $
            Map.fromList
              [(txIdTx (dbctxTx context), dbctxTxInfoResult context) | context <- subContexts]
        )
        initialCache
        tx
    subContexts =
      [ snd $ mkContext (LedgerSubTxInfo txIx) scriptsCache child
      | (txIx, child) <- zip [TxIx 0 ..] (toList (tx ^. bodyTxL . subTransactionsTxBodyL))
      ]
    mkContext ::
      forall level.
      LedgerLevelTxInfo level era ->
      Map.Map ScriptHash (SupportedPlutusRunnable era) ->
      Tx level era ->
      (Map.Map ScriptHash (SupportedPlutusRunnable era), DijkstraBodyContext level era)
    mkContext levelInfo cache bodyTx =
      let
        needed = getScriptsNeeded utxo (bodyTx ^. bodyTxL)
        (newCache, scriptsUsed) = resolveNeededPlutusScriptsWithPurpose protVer scriptsProvided needed cache
        ledgerTxInfo =
          LedgerTxInfo
            { ltiProtVer = protVer
            , ltiEpochInfo = ei
            , ltiSystemStart = sysStart
            , ltiUTxO = utxo
            , ltiTx = bodyTx
            , ltiScriptsUsed = scriptsUsed
            , ltiScriptHashesUsed = toScriptHashByPurpose scriptsUsed
            , ltiLevelTxInfo = levelInfo
            }
       in
        ( newCache
        , DijkstraBodyContext
            { dbctxTx = bodyTx
            , dbctxScriptsNeeded = needed
            , dbctxScriptsUsed = scriptsUsed
            , dbctxLedgerTxInfo = ledgerTxInfo
            , dbctxTxInfoResult = mkTxInfoResult ledgerTxInfo
            }
        )

-- | Execution estimates indexed by body identity and body-local redeemer
-- pointer. 'SNothing' identifies the top-level body; 'SJust' contains a child's
-- transaction id, so identical pointers in distinct bodies remain distinct.
type DijkstraRedeemerReport era =
  Map.Map
    (StrictMaybe TxId, PlutusPurpose AsIx era)
    (Either (TransactionScriptFailure era) ExUnits)

type DijkstraRedeemerReportWithLogs era =
  Map.Map
    (StrictMaybe TxId, PlutusPurpose AsIx era)
    (Either (TransactionScriptFailure era) ([Text], ExUnits))

-- | Estimate every body in a Dijkstra batch using its actual context.
evalDijkstraTxExUnits ::
  ( AlonzoEraTx era
  , AlonzoEraUTxO era
  , DijkstraEraTxBody era
  , EraPlutusContext era
  , ScriptsNeeded era ~ AlonzoScriptsNeeded era
  ) =>
  PParams era ->
  Tx TopTx era ->
  UTxO era ->
  EpochInfo (Either Text) ->
  SystemStart ->
  DijkstraRedeemerReport era
evalDijkstraTxExUnits pp tx utxo ei sysStart =
  Map.map (fmap snd) $ evalDijkstraTxExUnitsWithLogs pp tx utxo ei sysStart

-- | Batch execution estimates with logs. Witness/reference scripts are shared
-- exactly as in validation. Each child's index and the parent's Guarding child
-- views are supplied through the existing ledger context interface.
evalDijkstraTxExUnitsWithLogs ::
  forall era.
  ( AlonzoEraTx era
  , AlonzoEraUTxO era
  , DijkstraEraTxBody era
  , EraPlutusContext era
  , ScriptsNeeded era ~ AlonzoScriptsNeeded era
  ) =>
  PParams era ->
  Tx TopTx era ->
  UTxO era ->
  EpochInfo (Either Text) ->
  SystemStart ->
  DijkstraRedeemerReportWithLogs era
evalDijkstraTxExUnitsWithLogs pp tx utxo ei sysStart =
  Map.unions $
    estimate SNothing (dbctxLedgerTxInfo topContext)
      : [estimate (SJust (txIdTx (dbctxTx context))) (dbctxLedgerTxInfo context) | context <- subContexts]
  where
    DijkstraBatchContexts
      { dbcScriptsProvided = provided
      , dbcTopContext = topContext
      , dbcSubContexts = subContexts
      } = mkDijkstraBatchContexts ei sysStart pp utxo mempty tx
    estimate ::
      forall level. StrictMaybe TxId -> LedgerTxInfo level era -> DijkstraRedeemerReportWithLogs era
    estimate bodyId =
      Map.mapKeysMonotonic (\pointer -> (bodyId, pointer))
        . evalTxExUnitsWithLogsFromLedgerTxInfo pp provided
