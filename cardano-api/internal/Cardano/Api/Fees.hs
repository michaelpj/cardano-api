{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}

{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

-- | Fee calculation
--
module Cardano.Api.Fees (
    -- * Transaction fees
    transactionFee,
    estimateTransactionFee,
    evaluateTransactionFee,
    estimateTransactionKeyWitnessCount,

    -- * Script execution units
    evaluateTransactionExecutionUnits,
    ScriptExecutionError(..),
    TransactionValidityError(..),

    -- * Transaction balance
    evaluateTransactionBalance,

    -- * Automated transaction building
    makeTransactionBodyAutoBalance,
    BalancedTxBody(..),
    TxBodyErrorAutoBalance(..),

    -- * Minimum UTxO calculation
    calculateMinimumUTxO,

    -- * Internal helpers
    mapTxScriptWitnesses,

    ResolvablePointers(..),
  ) where

import           Cardano.Api.Address
import           Cardano.Api.Certificate
import           Cardano.Api.Eon.BabbageEraOnwards
import           Cardano.Api.Eon.MaryEraOnwards
import           Cardano.Api.Eon.ShelleyBasedEra
import           Cardano.Api.Eras.Case
import           Cardano.Api.Eras.Core
import           Cardano.Api.Error
import qualified Cardano.Api.Ledger.Lens as A
import           Cardano.Api.NetworkId
import           Cardano.Api.Pretty
import           Cardano.Api.ProtocolParameters
import           Cardano.Api.Query
import           Cardano.Api.Script
import           Cardano.Api.Tx
import           Cardano.Api.TxBody
import           Cardano.Api.Value

import qualified Cardano.Binary as CBOR
import qualified Cardano.Chain.Common as Byron
import qualified Cardano.Ledger.Alonzo.Core as Ledger
import qualified Cardano.Ledger.Alonzo.Plutus.TxInfo as Alonzo
import qualified Cardano.Ledger.Alonzo.Scripts as Alonzo
import qualified Cardano.Ledger.Alonzo.Tx as Alonzo
import qualified Cardano.Ledger.Alonzo.TxWits as Alonzo
import qualified Cardano.Ledger.Api as L
import qualified Cardano.Ledger.Coin as Ledger
import           Cardano.Ledger.Credential as Ledger (Credential)
import qualified Cardano.Ledger.Crypto as Ledger
import qualified Cardano.Ledger.Keys as Ledger
import qualified Cardano.Ledger.Plutus.Language as Plutus
import qualified Cardano.Ledger.Shelley.API.Wallet as Ledger (evaluateTransactionFee)
import qualified Ouroboros.Consensus.HardFork.History as Consensus
import qualified PlutusLedgerApi.V1 as Plutus

import           Control.Monad (forM_)
import           Data.Bifunctor (bimap, first)
import qualified Data.ByteString as BS
import           Data.ByteString.Short (ShortByteString)
import           Data.Function ((&))
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (catMaybes, fromMaybe, maybeToList)
import           Data.Ratio
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as Text
import           Lens.Micro ((.~), (^.))
import           Prettyprinter

{- HLINT ignore "Redundant return" -}
--- ----------------------------------------------------------------------------
--- Transaction fees
---

-- | For a concrete fully-constructed transaction, determine the minimum fee
-- that it needs to pay.
--
-- This function is simple, but if you are doing input selection then you
-- probably want to consider estimateTransactionFee.
--
transactionFee :: ()
  => ShelleyBasedEra era
  -> Lovelace -- ^ The fixed tx fee
  -> Lovelace -- ^ The tx fee per byte
  -> Tx era
  -> Lovelace
transactionFee sbe txFeeFixed txFeePerByte tx =
  let a = toInteger txFeePerByte
      b = toInteger txFeeFixed
  in
  case tx of
    ShelleyTx _ tx' ->
      let x = shelleyBasedEraConstraints sbe $ tx' ^. L.sizeTxF in Lovelace (a * x + b)
{-# DEPRECATED transactionFee "Use 'evaluateTransactionFee' instead" #-}

--TODO: in the Byron case the per-byte is non-integral, would need different
-- parameters. e.g. a new data type for fee params, Byron vs Shelley

-- | This can estimate what the transaction fee will be, based on a starting
-- base transaction, plus the numbers of the additional components of the
-- transaction that may be added.
--
-- So for example with wallet coin selection, the base transaction should
-- contain all the things not subject to coin selection (such as script inputs,
-- metadata, withdrawals, certs etc)
--
estimateTransactionFee :: ()
  => ShelleyBasedEra era
  -> NetworkId
  -> Lovelace -- ^ The fixed tx fee
  -> Lovelace -- ^ The tx fee per byte
  -> Tx era
  -> Int -- ^ The number of extra UTxO transaction inputs
  -> Int -- ^ The number of extra transaction outputs
  -> Int -- ^ The number of extra Shelley key witnesses
  -> Int -- ^ The number of extra Byron key witnesses
  -> Lovelace
estimateTransactionFee sbe nw txFeeFixed txFeePerByte = \case
  ShelleyTx era tx ->
    let Lovelace baseFee = transactionFee sbe txFeeFixed txFeePerByte (ShelleyTx era tx)
    in \nInputs nOutputs nShelleyKeyWitnesses nByronKeyWitnesses ->
      --TODO: this is fragile. Move something like this to the ledger and
      -- make it robust, based on the txsize calculation.
      let extraBytes :: Int
          extraBytes =
              nInputs               * sizeInput
            + nOutputs              * sizeOutput
            + nByronKeyWitnesses    * sizeByronKeyWitnesses
            + nShelleyKeyWitnesses  * sizeShelleyKeyWitnesses

      in Lovelace (baseFee + toInteger txFeePerByte * toInteger extraBytes)
  where
    sizeInput               = smallArray + uint + hashObj
    sizeOutput              = smallArray + uint + address
    sizeByronKeyWitnesses   = smallArray + keyObj + sigObj + ccodeObj + attrsObj
    sizeShelleyKeyWitnesses = smallArray + keyObj + sigObj

    smallArray  = 1
    uint        = 5

    hashObj     = 2 + hashLen
    hashLen     = 32

    keyObj      = 2 + keyLen
    keyLen      = 32

    sigObj      = 2 + sigLen
    sigLen      = 64

    ccodeObj    = 2 + ccodeLen
    ccodeLen    = 32

    address     = 2 + addrHeader + 2 * addrHashLen
    addrHeader  = 1
    addrHashLen = 28

    attrsObj    = 2 + BS.length attributes
    attributes  = CBOR.serialize' $
                    Byron.mkAttributes Byron.AddrAttributes {
                      Byron.aaVKDerivationPath = Nothing,
                      Byron.aaNetworkMagic     = toByronNetworkMagic nw
                    }

--TODO: also deprecate estimateTransactionFee:
--{-# DEPRECATED estimateTransactionFee "Use 'evaluateTransactionFee' instead" #-}


-- | Compute the transaction fee for a proposed transaction, with the
-- assumption that there will be the given number of key witnesses (i.e.
-- signatures).
--
-- TODO: we need separate args for Shelley vs Byron key sigs
--
evaluateTransactionFee :: forall era. ()
  => ShelleyBasedEra era
  -> Ledger.PParams (ShelleyLedgerEra era)
  -> TxBody era
  -> Word  -- ^ The number of Shelley key witnesses
  -> Word  -- ^ The number of Byron key witnesses
  -> Lovelace
evaluateTransactionFee _ _ _ _ byronwitcount | byronwitcount > 0 =
  error "evaluateTransactionFee: TODO support Byron key witnesses"

evaluateTransactionFee sbe pp txbody keywitcount _byronwitcount =
  shelleyBasedEraConstraints sbe $
    case makeSignedTransaction' (shelleyBasedToCardanoEra sbe) [] txbody of
      ShelleyTx _ tx -> fromShelleyLovelace $ Ledger.evaluateTransactionFee pp tx keywitcount

-- | Give an approximate count of the number of key witnesses (i.e. signatures)
-- a transaction will need.
--
-- This is an estimate not a precise count in that it can over-estimate: it
-- makes conservative assumptions such as all inputs are from distinct
-- addresses, but in principle multiple inputs can use the same address and we
-- only need a witness per address.
--
-- Similarly there can be overlap between the regular and collateral inputs,
-- but we conservatively assume they are distinct.
--
-- TODO: it is worth us considering a more precise count that relies on the
-- UTxO to resolve which inputs are for distinct addresses, and also to count
-- the number of Shelley vs Byron style witnesses.
--
estimateTransactionKeyWitnessCount :: TxBodyContent BuildTx era -> Word
estimateTransactionKeyWitnessCount TxBodyContent {
                                     txIns,
                                     txInsCollateral,
                                     txExtraKeyWits,
                                     txWithdrawals,
                                     txCertificates,
                                     txUpdateProposal
                                   } =
  fromIntegral $
    length [ () | (_txin, BuildTxWith KeyWitness{}) <- txIns ]

  + case txInsCollateral of
      TxInsCollateral _ txins
        -> length txins
      _ -> 0

  + case txExtraKeyWits of
      TxExtraKeyWitnesses _ khs
        -> length khs
      _ -> 0

  + case txWithdrawals of
      TxWithdrawals _ withdrawals
        -> length [ () | (_, _, BuildTxWith KeyWitness{}) <- withdrawals ]
      _ -> 0

  + case txCertificates of
      TxCertificates _ _ (BuildTxWith witnesses)
        -> length [ () | KeyWitness{} <- Map.elems witnesses ]
      _ -> 0

  + case txUpdateProposal of
      TxUpdateProposal _ (UpdateProposal updatePerGenesisKey _)
        -> Map.size updatePerGenesisKey
      _ -> 0


-- ----------------------------------------------------------------------------
-- Script execution units
--

type PlutusScriptBytes = ShortByteString

data ResolvablePointers where
  ResolvablePointers ::
      ( Ledger.Era (ShelleyLedgerEra era)
      , Show (Ledger.TxCert (ShelleyLedgerEra era))
      )
    => ShelleyBasedEra era
    -> Map
         Alonzo.RdmrPtr
         ( Alonzo.ScriptPurpose (ShelleyLedgerEra era)
         , Maybe (PlutusScriptBytes, Plutus.Language)
         , Ledger.ScriptHash Ledger.StandardCrypto
         )
    -> ResolvablePointers

deriving instance Show ResolvablePointers

-- | The different possible reasons that executing a script can fail,
-- as reported by 'evaluateTransactionExecutionUnits'.
--
-- The first three of these are about failures before we even get to execute
-- the script, and two are the result of execution.
--
data ScriptExecutionError =

       -- | The script depends on a 'TxIn' that has not been provided in the
       -- given 'UTxO' subset. The given 'UTxO' must cover all the inputs
       -- the transaction references.
       ScriptErrorMissingTxIn TxIn

       -- | The 'TxIn' the script is spending does not have a 'ScriptDatum'.
       -- All inputs guarded by Plutus scripts need to have been created with
       -- a 'ScriptDatum'.
     | ScriptErrorTxInWithoutDatum TxIn

       -- | The 'ScriptDatum' provided does not match the one from the 'UTxO'.
       -- This means the wrong 'ScriptDatum' value has been provided.
       --
     | ScriptErrorWrongDatum (Hash ScriptData)

       -- | The script evaluation failed. This usually means it evaluated to an
       -- error value. This is not a case of running out of execution units
       -- (which is not possible for 'evaluateTransactionExecutionUnits' since
       -- the whole point of it is to discover how many execution units are
       -- needed).
       --
     | ScriptErrorEvaluationFailed Plutus.EvaluationError [Text.Text]

       -- | The execution units overflowed a 64bit word. Congratulations if
       -- you encounter this error. With the current style of cost model this
       -- would need a script to run for over 7 months, which is somewhat more
       -- than the expected maximum of a few milliseconds.
       --
     | ScriptErrorExecutionUnitsOverflow

       -- | An attempt was made to spend a key witnessed tx input
       -- with a script witness.
     | ScriptErrorNotPlutusWitnessedTxIn ScriptWitnessIndex ScriptHash

       -- | The redeemer pointer points to a script hash that does not exist
       -- in the transaction nor in the UTxO as a reference script"
     | ScriptErrorRedeemerPointsToUnknownScriptHash ScriptWitnessIndex

       -- | A redeemer pointer points to a script that does not exist.
     | ScriptErrorMissingScript
         Alonzo.RdmrPtr -- The invalid pointer
         ResolvablePointers -- A mapping a pointers that are possible to resolve

       -- | A cost model was missing for a language which was used.
     | ScriptErrorMissingCostModel Plutus.Language
  deriving Show

instance Error ScriptExecutionError where
  prettyError = \case
    ScriptErrorMissingTxIn txin ->
      "The supplied UTxO is missing the txin " <> pretty (renderTxIn txin)

    ScriptErrorTxInWithoutDatum txin ->
      mconcat
        [ "The Plutus script witness for the txin does not have a script datum "
        , "(according to the UTxO). The txin in question is "
        , pretty (renderTxIn txin)
        ]

    ScriptErrorWrongDatum dh ->
      mconcat
        [ "The Plutus script witness has the wrong datum (according to the UTxO). "
        , "The expected datum value has hash " <> pshow dh
        ]

    ScriptErrorEvaluationFailed evalErr logs ->
      mconcat
        [ "The Plutus script evaluation failed: " <> pretty evalErr
        , "\nScript debugging logs: " <> mconcat (map (\t -> pretty $ t `Text.append` "\n") logs)
        ]

    ScriptErrorExecutionUnitsOverflow ->
      mconcat
        [ "The execution units required by this Plutus script overflows a 64bit "
        , "word. In a properly configured chain this should be practically "
        , "impossible. So this probably indicates a chain configuration problem, "
        , "perhaps with the values in the cost model."
        ]

    ScriptErrorNotPlutusWitnessedTxIn scriptWitness scriptHash ->
      mconcat
        [ pretty (renderScriptWitnessIndex scriptWitness)
        , " is not a Plutus script witnessed tx input and cannot be spent using a "
        , "Plutus script witness.The script hash is " <> pshow scriptHash <> "."
        ]

    ScriptErrorRedeemerPointsToUnknownScriptHash scriptWitness ->
      mconcat
        [ pretty (renderScriptWitnessIndex scriptWitness)
        , " points to a script hash that is not known."
        ]

    ScriptErrorMissingScript rdmrPtr resolveable ->
      mconcat
        [ "The redeemer pointer: " <> pshow rdmrPtr <> " points to a Plutus "
        , "script that does not exist.\n"
        , "The pointers that can be resolved are: " <> pshow resolveable
        ]

    ScriptErrorMissingCostModel language ->
      "No cost model was found for language " <> pshow language

data TransactionValidityError =
    -- | The transaction validity interval is too far into the future.
    --
    -- Transactions with Plutus scripts need to have a validity interval that is
    -- not so far in the future that we cannot reliably determine the UTC time
    -- corresponding to the validity interval expressed in slot numbers.
    --
    -- This is because the Plutus scripts get given the transaction validity
    -- interval in UTC time, so that they are not sensitive to slot lengths.
    --
    -- If either end of the validity interval is beyond the so called \"time
    -- horizon\" then the consensus algorithm is not able to reliably determine
    -- the relationship between slots and time. This is this situation in which
    -- this error is reported. For the Cardano mainnet the time horizon is 36
    -- hours beyond the current time. This effectively means we cannot submit
    -- check or submit transactions that use Plutus scripts that have the end
    -- of their validity interval more than 36 hours into the future.
    TransactionValidityIntervalError Consensus.PastHorizonException

  | TransactionValidityTranslationError (Alonzo.TranslationError Ledger.StandardCrypto)

  | TransactionValidityCostModelError (Map AnyPlutusScriptVersion CostModel) String

deriving instance Show TransactionValidityError

instance Error TransactionValidityError where
  prettyError = \case
    TransactionValidityIntervalError pastTimeHorizon ->
      mconcat
        [ "The transaction validity interval is too far in the future. "
        , "For this network it must not be more than "
        , pretty (timeHorizonSlots pastTimeHorizon)
        , "slots ahead of the current time slot. "
        , "(Transactions with Plutus scripts must have validity intervals that "
        , "are close enough in the future that we can reliably turn the slot "
        , "numbers into UTC wall clock times.)"
        ]
      where
        timeHorizonSlots :: Consensus.PastHorizonException -> Word
        timeHorizonSlots Consensus.PastHorizon{Consensus.pastHorizonSummary}
          | eraSummaries@(_:_) <- pastHorizonSummary
          , Consensus.StandardSafeZone slots <-
              (Consensus.eraSafeZone . Consensus.eraParams . last) eraSummaries
          = fromIntegral slots

          | otherwise
          = 0 -- This should be impossible.
    TransactionValidityTranslationError errmsg ->
      "Error translating the transaction context: " <> pshow errmsg

    TransactionValidityCostModelError cModels err ->
      mconcat
        [ "An error occurred while converting from the cardano-api cost"
        , " models to the cardano-ledger cost models. Error: " <> pretty err
        , " Cost models: " <> pshow cModels
        ]

-- | Compute the 'ExecutionUnits' needed for each script in the transaction.
--
-- This works by running all the scripts and counting how many execution units
-- are actually used.
--
evaluateTransactionExecutionUnits :: forall era. ()
  => CardanoEra era
  -> SystemStart
  -> LedgerEpochInfo
  -> LedgerProtocolParameters era
  -> UTxO era
  -> TxBody era
  -> Either TransactionValidityError
            (Map ScriptWitnessIndex (Either ScriptExecutionError ExecutionUnits))
evaluateTransactionExecutionUnits era systemstart epochInfo pp utxo txbody =
    case makeSignedTransaction' era [] txbody of
      ShelleyTx sbe tx' -> evaluateTransactionExecutionUnitsShelley sbe systemstart epochInfo pp utxo tx'

evaluateTransactionExecutionUnitsShelley :: forall era. ()
  => ShelleyBasedEra era
  -> SystemStart
  -> LedgerEpochInfo
  -> LedgerProtocolParameters era
  -> UTxO era
  -> L.Tx (ShelleyLedgerEra era)
  -> Either TransactionValidityError
            (Map ScriptWitnessIndex (Either ScriptExecutionError ExecutionUnits))
evaluateTransactionExecutionUnitsShelley sbe systemstart epochInfo (LedgerProtocolParameters pp) utxo tx =
  caseShelleyToMaryOrAlonzoEraOnwards
    (const (Right Map.empty))
    (\_ ->
      case L.evalTxExUnits pp tx (toLedgerUTxO sbe utxo) ledgerEpochInfo systemstart of
        Left err    -> Left (TransactionValidityTranslationError err)
        Right exmap -> Right (fromLedgerScriptExUnitsMap exmap)
    )
    sbe
  where
    LedgerEpochInfo ledgerEpochInfo = epochInfo

    fromLedgerScriptExUnitsMap
      :: Map Alonzo.RdmrPtr (Either (L.TransactionScriptFailure (ShelleyLedgerEra era))
                                    Alonzo.ExUnits)
      -> Map ScriptWitnessIndex (Either ScriptExecutionError ExecutionUnits)
    fromLedgerScriptExUnitsMap exmap =
      Map.fromList
        [ (fromAlonzoRdmrPtr rdmrptr,
           bimap fromAlonzoScriptExecutionError fromAlonzoExUnits exunitsOrFailure)
        | (rdmrptr, exunitsOrFailure) <- Map.toList exmap ]

    fromAlonzoScriptExecutionError :: L.TransactionScriptFailure (ShelleyLedgerEra era)
                                   -> ScriptExecutionError
    fromAlonzoScriptExecutionError =
      shelleyBasedEraConstraints sbe $ \case
        L.UnknownTxIn     txin -> ScriptErrorMissingTxIn txin'
                                         where txin' = fromShelleyTxIn txin
        L.InvalidTxIn     txin -> ScriptErrorTxInWithoutDatum txin'
                                         where txin' = fromShelleyTxIn txin
        L.MissingDatum      dh -> ScriptErrorWrongDatum (ScriptDataHash dh)
        L.ValidationFailure (L.ValidationFailedV1 err logs _) ->
          ScriptErrorEvaluationFailed err logs
        L.ValidationFailure (L.ValidationFailedV2 err logs _) ->
          ScriptErrorEvaluationFailed err logs
        L.ValidationFailure (L.ValidationFailedV3 err logs _) ->
          ScriptErrorEvaluationFailed err logs
        L.IncompatibleBudget _ -> ScriptErrorExecutionUnitsOverflow

        -- This is only possible for spending scripts and occurs when
        -- we attempt to spend a key witnessed tx input with a Plutus
        -- script witness.
        L.RedeemerNotNeeded rdmrPtr scriptHash ->
          ScriptErrorNotPlutusWitnessedTxIn
            (fromAlonzoRdmrPtr rdmrPtr)
            (fromShelleyScriptHash scriptHash)
        L.RedeemerPointsToUnknownScriptHash rdmrPtr ->
          ScriptErrorRedeemerPointsToUnknownScriptHash $ fromAlonzoRdmrPtr rdmrPtr
        -- This should not occur while using cardano-cli because we zip together
        -- the Plutus script and the use site (txin, certificate etc). Therefore
        -- the redeemer pointer will always point to a Plutus script.
        L.MissingScript rdmrPtr resolveable ->
          let cnv1 Plutus.Plutus
                { Plutus.plutusLanguage = lang
                , Plutus.plutusScript = Alonzo.BinaryPlutus bytes
                } = (bytes, lang)
              cnv2 (purpose, mbScript, scriptHash) = (purpose, fmap cnv1 mbScript, scriptHash)
          in
            ScriptErrorMissingScript rdmrPtr
          $ ResolvablePointers sbe
          $ Map.map cnv2 resolveable

        L.NoCostModelInLedgerState l -> ScriptErrorMissingCostModel l

-- ----------------------------------------------------------------------------
-- Transaction balance
--

-- | Compute the total balance of the proposed transaction. Ultimately a valid
-- transaction must be fully balanced: that is have a total value of zero.
--
-- Finding the (non-zero) balance of partially constructed transaction is
-- useful for adjusting a transaction to be fully balanced.
--
evaluateTransactionBalance :: forall era. ()
                           => ShelleyBasedEra era
                           -> Ledger.PParams (ShelleyLedgerEra era)
                           -> Set PoolId
                           -> Map StakeCredential Lovelace
                           -> Map (Ledger.Credential Ledger.DRepRole Ledger.StandardCrypto) Lovelace
                           -> UTxO era
                           -> TxBody era
                           -> TxOutValue era
evaluateTransactionBalance sbe pp poolids stakeDelegDeposits drepDelegDeposits utxo (ShelleyTxBody _ txbody _ _ _ _) =
  shelleyBasedEraConstraints sbe
    $ TxOutValueShelleyBased sbe
    $ L.evalBalanceTxBody
        pp
        lookupDelegDeposit
        lookupDRepDeposit
        isRegPool
        (toLedgerUTxO sbe utxo)
        txbody
  where
    isRegPool :: Ledger.KeyHash Ledger.StakePool Ledger.StandardCrypto -> Bool
    isRegPool kh = StakePoolKeyHash kh `Set.member` poolids

    lookupDelegDeposit ::
      Ledger.Credential 'Ledger.Staking L.StandardCrypto -> Maybe Ledger.Coin
    lookupDelegDeposit stakeCred =
      toShelleyLovelace <$>
      Map.lookup (fromShelleyStakeCredential stakeCred) stakeDelegDeposits

    lookupDRepDeposit ::
      Ledger.Credential 'Ledger.DRepRole L.StandardCrypto -> Maybe Ledger.Coin
    lookupDRepDeposit drepCred =
      toShelleyLovelace <$>
      Map.lookup drepCred drepDelegDeposits

-- ----------------------------------------------------------------------------
-- Automated transaction building
--

-- | The possible errors that can arise from 'makeTransactionBodyAutoBalance'.
--
data TxBodyErrorAutoBalance =

       -- | The same errors that can arise from 'makeTransactionBody'.
       TxBodyError TxBodyError

       -- | One or more of the scripts fails to execute correctly.
     | TxBodyScriptExecutionError [(ScriptWitnessIndex, ScriptExecutionError)]

       -- | One or more of the scripts were expected to fail validation, but none did.
     | TxBodyScriptBadScriptValidity

       -- | There is not enough ada to cover both the outputs and the fees.
       -- The transaction should be changed to provide more input ada, or
       -- otherwise adjusted to need less (e.g. outputs, script etc).
       --
     | TxBodyErrorAdaBalanceNegative Lovelace

       -- | There is enough ada to cover both the outputs and the fees, but the
       -- resulting change is too small: it is under the minimum value for
       -- new UTxO entries. The transaction should be changed to provide more
       -- input ada.
       --
     | TxBodyErrorAdaBalanceTooSmall
         -- ^ Offending TxOut
         TxOutInAnyEra
         -- ^ Minimum UTxO
         Lovelace
         -- ^ Tx balance
         Lovelace

       -- | 'makeTransactionBodyAutoBalance' does not yet support the Byron era.
     | TxBodyErrorByronEraNotSupported

       -- | The 'ProtocolParameters' must provide the value for the min utxo
       -- parameter, for eras that use this parameter.
     | TxBodyErrorMissingParamMinUTxO

       -- | The transaction validity interval is too far into the future.
       -- See 'TransactionValidityIntervalError' for details.
     | TxBodyErrorValidityInterval TransactionValidityError

       -- | The minimum spendable UTxO threshold has not been met.
     | TxBodyErrorMinUTxONotMet
         -- ^ Offending TxOut
         TxOutInAnyEra
         -- ^ Minimum UTxO
         Lovelace
     | TxBodyErrorNonAdaAssetsUnbalanced Value
     | TxBodyErrorScriptWitnessIndexMissingFromExecUnitsMap
         ScriptWitnessIndex
         (Map ScriptWitnessIndex ExecutionUnits)

  deriving Show


instance Error TxBodyErrorAutoBalance where
  prettyError = \case
    TxBodyError err ->
      prettyError err

    TxBodyScriptExecutionError failures ->
      mconcat
        [ "The following scripts have execution failures:\n"
        , vsep
            [ mconcat
                [ "the script for " <> pretty (renderScriptWitnessIndex index)
                , " failed with: " <> "\n" <> prettyError failure
                ]
            | (index, failure) <- failures
            ]
        ]

    TxBodyScriptBadScriptValidity ->
      "One or more of the scripts were expected to fail validation, but none did."

    TxBodyErrorAdaBalanceNegative lovelace ->
      mconcat
        [ "The transaction does not balance in its use of ada. The net balance "
        , "of the transaction is negative: " <> pshow lovelace <> " lovelace. "
        , "The usual solution is to provide more inputs, or inputs with more ada."
        ]

    TxBodyErrorAdaBalanceTooSmall changeOutput minUTxO balance ->
      mconcat
        [ "The transaction does balance in its use of ada, however the net "
        , "balance does not meet the minimum UTxO threshold. \n"
        , "Balance: " <> pshow balance <> "\n"
        , "Offending output (change output): " <> pretty (prettyRenderTxOut changeOutput) <> "\n"
        , "Minimum UTxO threshold: " <> pshow minUTxO <> "\n"
        , "The usual solution is to provide more inputs, or inputs with more ada to "
        , "meet the minimum UTxO threshold"
        ]

    TxBodyErrorByronEraNotSupported ->
      "The Byron era is not yet supported by makeTransactionBodyAutoBalance"

    TxBodyErrorMissingParamMinUTxO ->
      "The minUTxOValue protocol parameter is required but missing"

    TxBodyErrorValidityInterval err ->
      prettyError err

    TxBodyErrorMinUTxONotMet txout minUTxO ->
      mconcat
        [ "Minimum UTxO threshold not met for tx output: " <> pretty (prettyRenderTxOut txout) <> "\n"
        , "Minimum required UTxO: " <> pshow minUTxO
        ]

    TxBodyErrorNonAdaAssetsUnbalanced val ->
      "Non-Ada assets are unbalanced: " <> pretty (renderValue val)

    TxBodyErrorScriptWitnessIndexMissingFromExecUnitsMap sIndex eUnitsMap ->
      mconcat
        [ "ScriptWitnessIndex (redeemer pointer): " <> pshow sIndex <> " is missing from the execution "
        , "units (redeemer pointer) map: " <> pshow eUnitsMap
        ]

handleExUnitsErrors ::
     ScriptValidity -- ^ Mark script as expected to pass or fail validation
  -> Map ScriptWitnessIndex ScriptExecutionError
  -> Map ScriptWitnessIndex ExecutionUnits
  -> Either TxBodyErrorAutoBalance (Map ScriptWitnessIndex ExecutionUnits)
handleExUnitsErrors ScriptValid failuresMap exUnitsMap =
    if null failures
      then Right exUnitsMap
      else Left (TxBodyScriptExecutionError failures)
  where failures :: [(ScriptWitnessIndex, ScriptExecutionError)]
        failures = Map.toList failuresMap
handleExUnitsErrors ScriptInvalid failuresMap exUnitsMap
  | null failuresMap = Left TxBodyScriptBadScriptValidity
  | otherwise = Right $ Map.map (\_ -> ExecutionUnits 0 0) failuresMap <> exUnitsMap

data BalancedTxBody era
  = BalancedTxBody
      (TxBodyContent BuildTx era)
      (TxBody era)
      (TxOut CtxTx era) -- ^ Transaction balance (change output)
      Lovelace    -- ^ Estimated transaction fee

-- | This is much like 'makeTransactionBody' but with greater automation to
-- calculate suitable values for several things.
--
-- In particular:
--
-- * It calculates the correct script 'ExecutionUnits' (ignoring the provided
--   values, which can thus be zero).
--
-- * It calculates the transaction fees, based on the script 'ExecutionUnits',
--   the current 'ProtocolParameters', and an estimate of the number of
--   key witnesses (i.e. signatures). There is an override for the number of
--   key witnesses.
--
-- * It accepts a change address, calculates the balance of the transaction
--   and puts the excess change into the change output.
--
-- * It also checks that the balance is positive and the change is above the
--   minimum threshold.
--
-- To do this it needs more information than 'makeTransactionBody', all of
-- which can be queried from a local node.
--
makeTransactionBodyAutoBalance :: forall era. ()
  => ShelleyBasedEra era
  -> SystemStart
  -> LedgerEpochInfo
  -> LedgerProtocolParameters era
  -> Set PoolId       -- ^ The set of registered stake pools, that are being
                      --   unregistered in this transaction.
  -> Map StakeCredential Lovelace
                      -- ^ Map of all deposits for stake credentials that are being
                      --   unregistered in this transaction
  -> Map (Ledger.Credential Ledger.DRepRole Ledger.StandardCrypto) Lovelace
                      -- ^ Map of all deposits for drep credentials that are being
                      --   unregistered in this transaction
  -> UTxO era         -- ^ Just the transaction inputs, not the entire 'UTxO'.
  -> TxBodyContent BuildTx era
  -> AddressInEra era -- ^ Change address
  -> Maybe Word       -- ^ Override key witnesses
  -> Either TxBodyErrorAutoBalance (BalancedTxBody era)
makeTransactionBodyAutoBalance sbe systemstart history lpp@(LedgerProtocolParameters pp) poolids stakeDelegDeposits
                            drepDelegDeposits utxo txbodycontent changeaddr mnkeys =
  shelleyBasedEraConstraints sbe $ do
    -- Our strategy is to:
    -- 1. evaluate all the scripts to get the exec units, update with ex units
    -- 2. figure out the overall min fees
    -- 3. update tx with fees
    -- 4. balance the transaction and update tx change output
    txbody0 <-
      first TxBodyError $ createAndValidateTransactionBody sbe txbodycontent
        { txOuts = txOuts txbodycontent ++
                   [TxOut changeaddr (lovelaceToTxOutValue sbe 0) TxOutDatumNone ReferenceScriptNone]
            --TODO: think about the size of the change output
            -- 1,2,4 or 8 bytes?
        }

    exUnitsMap <- first TxBodyErrorValidityInterval $
                    evaluateTransactionExecutionUnits
                      era
                      systemstart history
                      lpp
                      utxo
                      txbody0

    exUnitsMap' <-
      case Map.mapEither id exUnitsMap of
        (failures, exUnitsMap') ->
          handleExUnitsErrors
            (txScriptValidityToScriptValidity (txScriptValidity txbodycontent))
            failures
            exUnitsMap'

    txbodycontent1 <- substituteExecutionUnits exUnitsMap' txbodycontent

    -- Make a txbody that we will use for calculating the fees. For the purpose
    -- of fees we just need to make a txbody of the right size in bytes. We do
    -- not need the right values for the fee or change output. We use
    -- "big enough" values for the change output and set so that the CBOR
    -- encoding size of the tx will be big enough to cover the size of the final
    -- output and fee. Yes this means this current code will only work for
    -- final fee of less than around 4000 ada (2^32-1 lovelace) and change output
    -- of less than around 18 trillion ada  (2^64-1 lovelace).
    -- However, since at this point we know how much non-Ada change to give
    -- we can use the true values for that.
    let maxLovelaceChange = Lovelace (2^(64 :: Integer)) - 1
    let maxLovelaceFee = Lovelace (2^(32 :: Integer) - 1)

    let outgoing = mconcat [v | (TxOut _ (TxOutValueShelleyBased _ v) _ _) <- txOuts txbodycontent]
    let incoming = mconcat [v | (TxOut _ (TxOutValueShelleyBased _ v) _ _) <- Map.elems $ unUTxO utxo]
    let minted = case txMintValue txbodycontent1 of
          TxMintNone -> mempty
          TxMintValue w v _ -> toLedgerValue w v
    let change = mconcat [incoming, minted, negateLedgerValue sbe outgoing]
    let changeWithMaxLovelace = change & A.adaAssetL sbe .~ lovelaceToCoin maxLovelaceChange
    let changeTxOut = forShelleyBasedEraInEon sbe
          (lovelaceToTxOutValue sbe maxLovelaceChange)
          (\w -> maryEraOnwardsConstraints w $ TxOutValueShelleyBased sbe changeWithMaxLovelace)

    let (dummyCollRet, dummyTotColl) = maybeDummyTotalCollAndCollReturnOutput txbodycontent changeaddr
    txbody1 <- first TxBodyError $ -- TODO: impossible to fail now
               createAndValidateTransactionBody sbe txbodycontent1 {
                 txFee  = TxFeeExplicit sbe maxLovelaceFee,
                 txOuts = TxOut changeaddr changeTxOut TxOutDatumNone ReferenceScriptNone
                        : txOuts txbodycontent,
                 txReturnCollateral = dummyCollRet,
                 txTotalCollateral = dummyTotColl
               }

    let nkeys = fromMaybe (estimateTransactionKeyWitnessCount txbodycontent1)
                          mnkeys
        fee   = evaluateTransactionFee sbe pp txbody1 nkeys 0 --TODO: byron keys
        (retColl, reqCol) =
           caseShelleyToAlonzoOrBabbageEraOnwards
            (const (TxReturnCollateralNone, TxTotalCollateralNone))
            (\w ->
              calcReturnAndTotalCollateral w
                fee pp (txInsCollateral txbodycontent) (txReturnCollateral txbodycontent)
                (txTotalCollateral txbodycontent) changeaddr utxo
            )
            sbe

    -- Make a txbody for calculating the balance. For this the size of the tx
    -- does not matter, instead it's just the values of the fee and outputs.
    -- Here we do not want to start with any change output, since that's what
    -- we need to calculate.
    txbody2 <- first TxBodyError $ -- TODO: impossible to fail now
               createAndValidateTransactionBody sbe txbodycontent1 {
                 txFee = TxFeeExplicit sbe fee,
                 txReturnCollateral = retColl,
                 txTotalCollateral = reqCol
               }
    let balance = evaluateTransactionBalance sbe pp poolids stakeDelegDeposits drepDelegDeposits utxo txbody2

    forM_ (txOuts txbodycontent1) $ \txout -> checkMinUTxOValue txout pp

    -- check if the balance is positive or negative
    -- in one case we can produce change, in the other the inputs are insufficient
    balanceCheck pp balance

    --TODO: we could add the extra fee for the CBOR encoding of the change,
    -- now that we know the magnitude of the change: i.e. 1-8 bytes extra.

    -- The txbody with the final fee and change output. This should work
    -- provided that the fee and change are less than 2^32-1, and so will
    -- fit within the encoding size we picked above when calculating the fee.
    -- Yes this could be an over-estimate by a few bytes if the fee or change
    -- would fit within 2^16-1. That's a possible optimisation.
    let finalTxBodyContent = txbodycontent1 {
          txFee  = TxFeeExplicit sbe fee,
          txOuts = accountForNoChange
                     (TxOut changeaddr balance TxOutDatumNone ReferenceScriptNone)
                     (txOuts txbodycontent),
          txReturnCollateral = retColl,
          txTotalCollateral = reqCol
        }
    txbody3 <-
      first TxBodyError $ -- TODO: impossible to fail now. We need to implement a function
                          -- that simply creates a transaction body because we have already
                          -- validated the transaction body earlier within makeTransactionBodyAutoBalance
        createAndValidateTransactionBody sbe finalTxBodyContent
    return (BalancedTxBody finalTxBodyContent txbody3 (TxOut changeaddr balance TxOutDatumNone ReferenceScriptNone) fee)
 where
   -- Essentially we check for the existence of collateral inputs. If they exist we
   -- create a fictitious collateral return output. Why? Because we need to put dummy values
   -- to get a fee estimate (i.e we overestimate the fee.)
   maybeDummyTotalCollAndCollReturnOutput
     :: TxBodyContent BuildTx era -> AddressInEra era -> (TxReturnCollateral CtxTx era, TxTotalCollateral era)
   maybeDummyTotalCollAndCollReturnOutput TxBodyContent{txInsCollateral, txReturnCollateral, txTotalCollateral} cAddr =
     case txInsCollateral of
       TxInsCollateralNone -> (TxReturnCollateralNone, TxTotalCollateralNone)
       TxInsCollateral{} ->
         forEraInEon era
            (TxReturnCollateralNone, TxTotalCollateralNone)
            (\w ->
              let dummyRetCol =
                    TxReturnCollateral w
                    ( TxOut cAddr
                        (lovelaceToTxOutValue sbe $ Lovelace (2^(64 :: Integer)) - 1)
                        TxOutDatumNone ReferenceScriptNone
                    )
                  dummyTotCol = TxTotalCollateral w (Lovelace (2^(32 :: Integer) - 1))
              in case (txReturnCollateral, txTotalCollateral) of
                (rc@TxReturnCollateral{}, tc@TxTotalCollateral{}) -> (rc, tc)
                (rc@TxReturnCollateral{},TxTotalCollateralNone) -> (rc, dummyTotCol)
                (TxReturnCollateralNone,tc@TxTotalCollateral{}) -> (dummyRetCol, tc)
                (TxReturnCollateralNone, TxTotalCollateralNone) -> (dummyRetCol, dummyTotCol)
            )
   -- Calculation taken from validateInsufficientCollateral: https://github.com/input-output-hk/cardano-ledger/blob/389b266d6226dedf3d2aec7af640b3ca4984c5ea/eras/alonzo/impl/src/Cardano/Ledger/Alonzo/Rules/Utxo.hs#L335
   -- TODO: Bug Jared to expose a function from the ledger that returns total and return collateral.
   calcReturnAndTotalCollateral :: ()
      => Ledger.AlonzoEraPParams (ShelleyLedgerEra era)
      => BabbageEraOnwards era
      -> Lovelace -- ^ Fee
      -> Ledger.PParams (ShelleyLedgerEra era)
      -> TxInsCollateral era -- ^ From the initial TxBodyContent
      -> TxReturnCollateral CtxTx era -- ^ From the initial TxBodyContent
      -> TxTotalCollateral era -- ^ From the initial TxBodyContent
      -> AddressInEra era -- ^ Change address
      -> UTxO era
      -> (TxReturnCollateral CtxTx era, TxTotalCollateral era)
   calcReturnAndTotalCollateral _ _ _ TxInsCollateralNone _ _ _ _= (TxReturnCollateralNone, TxTotalCollateralNone)
   calcReturnAndTotalCollateral _ _ _ _ rc@TxReturnCollateral{} tc@TxTotalCollateral{} _ _ = (rc,tc)
   calcReturnAndTotalCollateral retColSup fee pp' (TxInsCollateral _ collIns) txReturnCollateral txTotalCollateral cAddr (UTxO utxo') =
      do
        let colPerc = pp' ^. Ledger.ppCollateralPercentageL
        -- We must first figure out how much lovelace we have committed
        -- as collateral and we must determine if we have enough lovelace at our
        -- collateral tx inputs to cover the tx
        let txOuts = catMaybes [ Map.lookup txin utxo' | txin <- collIns]
            totalCollateralLovelace = mconcat $ map (\(TxOut _ txOutVal _ _) -> txOutValueToLovelace txOutVal) txOuts
            requiredCollateral@(Lovelace reqAmt) = fromIntegral colPerc * fee
            totalCollateral = TxTotalCollateral retColSup . fromShelleyLovelace
                                                          . Ledger.rationalToCoinViaCeiling
                                                          $ reqAmt % 100
            -- Why * 100? requiredCollateral is the product of the collateral percentage and the tx fee
            -- We choose to multiply 100 rather than divide by 100 to make the calculation
            -- easier to manage. At the end of the calculation we then use % 100 to perform our division
            -- and round up.
            enoughCollateral = totalCollateralLovelace * 100 >= requiredCollateral
            Lovelace amt = totalCollateralLovelace * 100 - requiredCollateral
            returnCollateral = fromShelleyLovelace . Ledger.rationalToCoinViaFloor $ amt % 100

        case (txReturnCollateral, txTotalCollateral) of
#if MIN_VERSION_base(4,16,0)
#else
              -- For ghc-9.2, this pattern match is redundant, but ghc-8.10 will complain if its missing.
              (rc@TxReturnCollateral{}, tc@TxTotalCollateral{}) ->
                (rc, tc)
#endif
              (rc@TxReturnCollateral{}, TxTotalCollateralNone) ->
                (rc, TxTotalCollateralNone)
              (TxReturnCollateralNone, tc@TxTotalCollateral{}) ->
                (TxReturnCollateralNone, tc)
              (TxReturnCollateralNone, TxTotalCollateralNone) ->
                if enoughCollateral
                then
                  ( TxReturnCollateral
                      retColSup
                      (TxOut cAddr (lovelaceToTxOutValue sbe returnCollateral) TxOutDatumNone ReferenceScriptNone)
                  , totalCollateral
                  )
                else (TxReturnCollateralNone, TxTotalCollateralNone)

   era :: CardanoEra era
   era = shelleyBasedToCardanoEra sbe

   -- In the event of spending the exact amount of lovelace in
   -- the specified input(s), this function excludes the change
   -- output. Note that this does not save any fees because by default
   -- the fee calculation includes a change address for simplicity and
   -- we make no attempt to recalculate the tx fee without a change address.
   accountForNoChange :: TxOut CtxTx era -> [TxOut CtxTx era] -> [TxOut CtxTx era]
   accountForNoChange change@(TxOut _ balance _ _) rest =
     case txOutValueToLovelace balance of
       Lovelace 0 -> rest
       -- We append change at the end so a client can predict the indexes
       -- of the outputs
       _ -> rest ++ [change]

   balanceCheck :: Ledger.PParams (ShelleyLedgerEra era) -> TxOutValue era -> Either TxBodyErrorAutoBalance ()
   balanceCheck bpparams balance
    | txOutValueToLovelace balance == 0 && onlyAda (txOutValueToValue balance) = return ()
    | txOutValueToLovelace balance < 0 =
        Left . TxBodyErrorAdaBalanceNegative $ txOutValueToLovelace balance
    | otherwise =
        case checkMinUTxOValue (TxOut changeaddr balance TxOutDatumNone ReferenceScriptNone) bpparams of
          Left (TxBodyErrorMinUTxONotMet txOutAny minUTxO) ->
            Left $ TxBodyErrorAdaBalanceTooSmall txOutAny minUTxO (txOutValueToLovelace balance)
          Left err -> Left err
          Right _ -> Right ()

   isNotAda :: AssetId -> Bool
   isNotAda AdaAssetId = False
   isNotAda _ = True

   onlyAda :: Value -> Bool
   onlyAda = null . valueToList . filterValue isNotAda

   checkMinUTxOValue
     :: TxOut CtxTx era
     -> Ledger.PParams (ShelleyLedgerEra era)
     -> Either TxBodyErrorAutoBalance ()
   checkMinUTxOValue txout@(TxOut _ v _ _) bpp = do
      let minUTxO = calculateMinimumUTxO sbe txout bpp
      if txOutValueToLovelace v >= minUTxO
        then Right ()
        else Left $ TxBodyErrorMinUTxONotMet (txOutInAnyEra era txout) minUTxO

substituteExecutionUnits :: Map ScriptWitnessIndex ExecutionUnits
                         -> TxBodyContent BuildTx era
                         -> Either TxBodyErrorAutoBalance (TxBodyContent BuildTx era)
substituteExecutionUnits exUnitsMap =
    mapTxScriptWitnesses f
  where
    f :: ScriptWitnessIndex
      -> ScriptWitness witctx era
      -> Either TxBodyErrorAutoBalance (ScriptWitness witctx era)
    f _   wit@SimpleScriptWitness{} = Right wit
    f idx (PlutusScriptWitness langInEra version script datum redeemer _) =
      case Map.lookup idx exUnitsMap of
        Nothing ->
          Left $ TxBodyErrorScriptWitnessIndexMissingFromExecUnitsMap idx exUnitsMap
        Just exunits -> Right $ PlutusScriptWitness langInEra version script
                                            datum redeemer exunits
mapTxScriptWitnesses
  :: forall era.
      (forall witctx. ScriptWitnessIndex
                   -> ScriptWitness witctx era
                   -> Either TxBodyErrorAutoBalance (ScriptWitness witctx era))
  -> TxBodyContent BuildTx era
  -> Either TxBodyErrorAutoBalance (TxBodyContent BuildTx era)
mapTxScriptWitnesses f txbodycontent@TxBodyContent {
                         txIns,
                         txWithdrawals,
                         txCertificates,
                         txMintValue
                       } = do
    mappedTxIns <- mapScriptWitnessesTxIns txIns
    mappedWithdrawals <- mapScriptWitnessesWithdrawals txWithdrawals
    mappedMintedVals <- mapScriptWitnessesMinting txMintValue
    mappedTxCertificates <- mapScriptWitnessesCertificates txCertificates

    Right $ txbodycontent
      & setTxIns mappedTxIns
      & setTxMintValue mappedMintedVals
      & setTxCertificates mappedTxCertificates
      & setTxWithdrawals mappedWithdrawals

  where
    mapScriptWitnessesTxIns
      :: [(TxIn, BuildTxWith BuildTx (Witness WitCtxTxIn era))]
      -> Either TxBodyErrorAutoBalance [(TxIn, BuildTxWith BuildTx (Witness WitCtxTxIn era))]
    mapScriptWitnessesTxIns txins  =
      let mappedScriptWitnesses
            :: [ ( TxIn
                 , Either TxBodyErrorAutoBalance (BuildTxWith BuildTx (Witness WitCtxTxIn era))
                 )
               ]
          mappedScriptWitnesses =
            [ (txin, BuildTxWith <$> wit')
              -- The tx ins are indexed in the map order by txid
            | (ix, (txin, BuildTxWith wit)) <- zip [0..] (orderTxIns txins)
            , let wit' = case wit of
                           KeyWitness{}              -> Right wit
                           ScriptWitness ctx witness -> ScriptWitness ctx <$> witness'
                             where
                               witness' = f (ScriptWitnessIndexTxIn ix) witness
            ]
      in traverse ( \(txIn, eWitness) ->
                      case eWitness of
                        Left e -> Left e
                        Right wit -> Right (txIn, wit)
                  ) mappedScriptWitnesses

    mapScriptWitnessesWithdrawals
      :: TxWithdrawals BuildTx era
      -> Either TxBodyErrorAutoBalance (TxWithdrawals BuildTx era)
    mapScriptWitnessesWithdrawals  TxWithdrawalsNone = Right TxWithdrawalsNone
    mapScriptWitnessesWithdrawals (TxWithdrawals supported withdrawals) =
      let mappedWithdrawals
            :: [( StakeAddress
                , Lovelace
                , Either TxBodyErrorAutoBalance (BuildTxWith BuildTx (Witness WitCtxStake era))
                )]
          mappedWithdrawals =
              [ (addr, withdrawal, BuildTxWith <$> mappedWitness)
                -- The withdrawals are indexed in the map order by stake credential
              | (ix, (addr, withdrawal, BuildTxWith wit)) <- zip [0..] (orderStakeAddrs withdrawals)
              , let mappedWitness = adjustWitness (f (ScriptWitnessIndexWithdrawal ix)) wit
              ]
      in TxWithdrawals supported
           <$> traverse ( \(sAddr, ll, eWitness) ->
                            case eWitness of
                              Left e -> Left e
                              Right wit -> Right (sAddr, ll, wit)
                        ) mappedWithdrawals
      where
        adjustWitness
          :: (ScriptWitness witctx era -> Either TxBodyErrorAutoBalance (ScriptWitness witctx era))
          -> Witness witctx era
          -> Either TxBodyErrorAutoBalance (Witness witctx era)
        adjustWitness _ (KeyWitness ctx) = Right $ KeyWitness ctx
        adjustWitness g (ScriptWitness ctx witness') = ScriptWitness ctx <$> g witness'

    mapScriptWitnessesCertificates
      :: TxCertificates BuildTx era
      -> Either TxBodyErrorAutoBalance (TxCertificates BuildTx era)
    mapScriptWitnessesCertificates TxCertificatesNone = Right TxCertificatesNone
    mapScriptWitnessesCertificates (TxCertificates supported certs
                                                   (BuildTxWith witnesses)) =
      let mappedScriptWitnesses
           :: [(StakeCredential, Either TxBodyErrorAutoBalance (Witness WitCtxStake era))]
          mappedScriptWitnesses =
              [ (stakecred, ScriptWitness ctx <$> witness')
                -- The certs are indexed in list order
              | (ix, cert) <- zip [0..] certs
              , stakecred  <- maybeToList (selectStakeCredentialWitness cert)
              , ScriptWitness ctx witness
                           <- maybeToList (Map.lookup stakecred witnesses)
              , let witness' = f (ScriptWitnessIndexCertificate ix) witness
              ]
      in TxCertificates supported certs . BuildTxWith . Map.fromList <$>
           traverse ( \(sCred, eScriptWitness) ->
                        case eScriptWitness of
                          Left e -> Left e
                          Right wit -> Right (sCred, wit)
                    ) mappedScriptWitnesses

    mapScriptWitnessesMinting
      :: TxMintValue BuildTx era
      -> Either TxBodyErrorAutoBalance (TxMintValue BuildTx era)
    mapScriptWitnessesMinting  TxMintNone = Right TxMintNone
    mapScriptWitnessesMinting (TxMintValue supported value
                                           (BuildTxWith witnesses)) =
      --TxMintValue supported value $ BuildTxWith $ Map.fromList
      let mappedScriptWitnesses
            :: [(PolicyId, Either TxBodyErrorAutoBalance (ScriptWitness WitCtxMint era))]
          mappedScriptWitnesses =
            [ (policyid, witness')
              -- The minting policies are indexed in policy id order in the value
            | let ValueNestedRep bundle = valueToNestedRep value
            , (ix, ValueNestedBundle policyid _) <- zip [0..] bundle
            , witness <- maybeToList (Map.lookup policyid witnesses)
            , let witness' = f (ScriptWitnessIndexMint ix) witness
            ]
      in do final <- traverse ( \(pid, eScriptWitness) ->
                                   case eScriptWitness of
                                     Left e -> Left e
                                     Right wit -> Right (pid, wit)
                              ) mappedScriptWitnesses
            Right . TxMintValue supported value . BuildTxWith
              $ Map.fromList final

calculateMinimumUTxO
  :: ShelleyBasedEra era
  -> TxOut CtxTx era
  -> Ledger.PParams (ShelleyLedgerEra era)
  -> Lovelace
calculateMinimumUTxO sbe txout pp =
  shelleyBasedEraConstraints sbe
    $ let txOutWithMinCoin = L.setMinCoinTxOut pp (toShelleyTxOutAny sbe txout)
      in fromShelleyLovelace (txOutWithMinCoin ^. L.coinTxOutL)
