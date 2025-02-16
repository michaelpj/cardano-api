-- | This module provides a library interface that is intended to be
-- the complete API for Byron covering everything, including exposing
-- constructors for the lower level types.
--

module Cardano.Api.Byron
  ( module Cardano.Api,
    AsType(..),

    -- * Cryptographic key interface
    -- $keys
    VerificationKey(..),
    SigningKey(..),
    SomeByronSigningKey(..),

    -- * Hashes
    Hash(..),

    -- * Payment addresses
    -- | Constructing and inspecting Byron payment addresses
    Address(ByronAddress),
    NetworkId(Mainnet, Testnet),

    -- * Building transactions
    -- | Constructing and inspecting transactions
    TxId(TxId),
    TxIn(TxIn),
    TxOut(TxOut),
    TxIx(TxIx),
    Lovelace(Lovelace),

    -- * Signing transactions
    -- | Creating transaction witnesses one by one, or all in one go.
    ATxAux(..),

    -- ** Incremental signing and separate witnesses
    KeyWitness (ByronKeyWitness),
    WitnessNetworkIdOrByronAddress
      ( WitnessNetworkId
      , WitnessByronAddress
      ),

    -- * Errors
    Error(..),
    FileError(..),

    -- ** Low level protocol interaction with a Cardano node
    LocalNodeConnectInfo(LocalNodeConnectInfo),
    LocalNodeClientProtocols(LocalNodeClientProtocols),

    -- *** Chain sync protocol
    ChainSyncClient(..),

    -- *** Local tx submission
    LocalTxSubmissionClient(LocalTxSubmissionClient),

    -- *** Local state query
    LocalStateQueryClient(..),

    -- * Address
    NetworkMagic(..),

    -- * Update Proposal
    ByronUpdateProposal(..),
    ByronProtocolParametersUpdate (..),
    makeByronUpdateProposal,
    toByronLedgerUpdateProposal,
    makeProtocolParametersUpdate,

    -- * Vote
    ByronVote(..),
    makeByronVote,
    toByronLedgertoByronVote,

    -- ** Conversions
    fromByronTxIn,
    toByronLovelace,
    toByronNetworkMagic,
    toByronProtocolMagicId,
    toByronRequiresNetworkMagic,

    -- * Hardcoded configuration parameters
    applicationName,
    applicationVersion,
    softwareVersion,

    -- * Serialization
    serializeByronTx,
    writeByronTxFileTextEnvelopeCddl,
  ) where

import           Cardano.Api
import           Cardano.Api.Address
import           Cardano.Api.Keys.Byron
import           Cardano.Api.NetworkId
import           Cardano.Api.SerialiseLedgerCddl
import           Cardano.Api.SpecialByron
import           Cardano.Api.Tx
import           Cardano.Api.TxBody
import           Cardano.Api.Value
