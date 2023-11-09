{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Cardano.Api.Eon.ShelleyToMaryEra
  ( ShelleyToMaryEra(..)
  , shelleyToMaryEraConstraints
  , shelleyToMaryEraToCardanoEra
  , shelleyToMaryEraToShelleyBasedEra

  , ShelleyToMaryEraConstraints
  ) where

import           Cardano.Api.Eon.ShelleyBasedEra
import           Cardano.Api.Eras.Core
import           Cardano.Api.Modes
import           Cardano.Api.Query.Types

import           Cardano.Binary
import qualified Cardano.Crypto.Hash.Blake2b as Blake2b
import qualified Cardano.Crypto.Hash.Class as C
import qualified Cardano.Crypto.VRF as C
import qualified Cardano.Ledger.Api as L
import qualified Cardano.Ledger.BaseTypes as L
import qualified Cardano.Ledger.Core as L
import qualified Cardano.Ledger.SafeHash as L
import qualified Cardano.Ledger.Shelley.TxCert as L
import qualified Ouroboros.Consensus.Protocol.Abstract as Consensus
import qualified Ouroboros.Consensus.Protocol.Praos.Common as Consensus
import qualified Ouroboros.Consensus.Shelley.Ledger as Consensus

import           Data.Aeson
import           Data.Typeable (Typeable)

data ShelleyToMaryEra era where
  ShelleyToMaryEraShelley :: ShelleyToMaryEra ShelleyEra
  ShelleyToMaryEraAllegra :: ShelleyToMaryEra AllegraEra
  ShelleyToMaryEraMary    :: ShelleyToMaryEra MaryEra

deriving instance Show (ShelleyToMaryEra era)
deriving instance Eq (ShelleyToMaryEra era)

instance Eon ShelleyToMaryEra where
  inEonForEra no yes = \case
    ByronEra    -> no
    ShelleyEra  -> yes ShelleyToMaryEraShelley
    AllegraEra  -> yes ShelleyToMaryEraAllegra
    MaryEra     -> yes ShelleyToMaryEraMary
    AlonzoEra   -> no
    BabbageEra  -> no
    ConwayEra   -> no

instance ToCardanoEra ShelleyToMaryEra where
  toCardanoEra = \case
    ShelleyToMaryEraShelley  -> ShelleyEra
    ShelleyToMaryEraAllegra  -> AllegraEra
    ShelleyToMaryEraMary     -> MaryEra

type ShelleyToMaryEraConstraints era =
  ( C.HashAlgorithm (L.HASH (L.EraCrypto (LedgerEra era)))
  , C.Signable (L.VRF (L.EraCrypto (LedgerEra era))) L.Seed
  , Consensus.PraosProtocolSupportsNode (ConsensusProtocol era)
  , Consensus.ShelleyBlock (ConsensusProtocol era) (LedgerEra era) ~ ConsensusBlockForEra era
  , Consensus.ShelleyCompatible (ConsensusProtocol era) (LedgerEra era)
  , L.ADDRHASH (Consensus.PraosProtocolSupportsNodeCrypto (ConsensusProtocol era)) ~ Blake2b.Blake2b_224
  , L.Crypto (L.EraCrypto (LedgerEra era))
  , L.Era (LedgerEra era)
  , L.EraCrypto (LedgerEra era) ~ L.StandardCrypto
  , L.EraPParams (LedgerEra era)
  , L.EraTx (LedgerEra era)
  , L.EraTxBody (LedgerEra era)
  , L.EraTxOut (LedgerEra era)
  , L.HashAnnotated (L.TxBody (LedgerEra era)) L.EraIndependentTxBody L.StandardCrypto
  , L.ProtVerAtMost (LedgerEra era) 4
  , L.ProtVerAtMost (LedgerEra era) 6
  , L.ProtVerAtMost (LedgerEra era) 8
  , L.ShelleyEraTxBody (LedgerEra era)
  , L.ShelleyEraTxCert (LedgerEra era)
  , L.TxCert (LedgerEra era) ~ L.ShelleyTxCert (LedgerEra era)

  , FromCBOR (Consensus.ChainDepState (ConsensusProtocol era))
  , FromCBOR (DebugLedgerState era)
  , IsCardanoEra era
  , IsShelleyBasedEra era
  , ToJSON (DebugLedgerState era)
  , Typeable era
  )

shelleyToMaryEraConstraints :: ()
  => ShelleyToMaryEra era
  -> (ShelleyToMaryEraConstraints era => a)
  -> a
shelleyToMaryEraConstraints = \case
  ShelleyToMaryEraShelley -> id
  ShelleyToMaryEraAllegra -> id
  ShelleyToMaryEraMary    -> id

shelleyToMaryEraToCardanoEra :: ShelleyToMaryEra era -> CardanoEra era
shelleyToMaryEraToCardanoEra = shelleyBasedToCardanoEra . shelleyToMaryEraToShelleyBasedEra

shelleyToMaryEraToShelleyBasedEra :: ShelleyToMaryEra era -> ShelleyBasedEra era
shelleyToMaryEraToShelleyBasedEra = \case
  ShelleyToMaryEraShelley -> ShelleyBasedEraShelley
  ShelleyToMaryEraAllegra -> ShelleyBasedEraAllegra
  ShelleyToMaryEraMary    -> ShelleyBasedEraMary
