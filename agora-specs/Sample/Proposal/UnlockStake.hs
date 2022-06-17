module Sample.Proposal.UnlockStake (
  unlockStake,
  StakeRole (..),
  UnlockStakeParameters (..),
  votesTemplate,
  emptyEffectFor,
  mkProposalInputDatum,
  mkStakeInputDatum,
  mkProposalValidatorTestCase,
) where

--------------------------------------------------------------------------------

import PlutusLedgerApi.V1 (
  Datum (Datum),
  DatumHash,
  ScriptContext (..),
  ScriptPurpose (Spending),
  ToData (toBuiltinData),
  TxInInfo (TxInInfo),
  TxInfo (..),
  TxOut (TxOut, txOutAddress, txOutDatumHash, txOutValue),
  TxOutRef (..),
  ValidatorHash,
 )
import PlutusLedgerApi.V1.Value qualified as Value
import PlutusTx.AssocMap qualified as AssocMap

--------------------------------------------------------------------------------

import Agora.Proposal (
  ProposalDatum (..),
  ProposalId (..),
  ProposalRedeemer (Unlock),
  ProposalStatus (..),
  ProposalVotes (..),
  ResultTag (..),
 )
import Agora.Proposal.Time (ProposalStartingTime (ProposalStartingTime))
import Agora.Stake (ProposalLock (ProposalLock), Stake (..), StakeDatum (..))
import Sample.Shared (
  minAda,
  proposalPolicySymbol,
  proposalValidatorAddress,
  signer,
  stake,
  stakeAssetClass,
 )
import Test.Util (closedBoundedInterval, datumPair, sortValue, toDatumHash, updateMap)

--------------------------------------------------------------------------------

import Agora.Proposal.Scripts (proposalValidator)
import Control.Monad (join)
import Data.Default.Class (Default (def))
import Data.Tagged (Tagged (..), untag)
import Sample.Proposal.Shared (proposalRef, stakeRef)
import Sample.Shared qualified as Shared
import Test.Specification (SpecificationTree, validatorFailsWith, validatorSucceedsWith)
import Data.List (sortBy)

--------------------------------------------------------------------------------

-- | The template "shape" that votes of proposals generated by 'mkProposalDatumPair' have.
votesTemplate :: ProposalVotes
votesTemplate =
  ProposalVotes $
    AssocMap.fromList
      [ (ResultTag 0, 0)
      , (ResultTag 1, 0)
      ]

-- | Create empty effects for every result tag given the votes.
emptyEffectFor ::
  ProposalVotes ->
  AssocMap.Map ResultTag (AssocMap.Map ValidatorHash DatumHash)
emptyEffectFor (ProposalVotes vs) =
  AssocMap.fromList $
    map (,AssocMap.empty) (AssocMap.keys vs)

-- | The default vote option that will be used by functions in this module.
defaultVoteFor :: ResultTag
defaultVoteFor = ResultTag 0

-- | The default number of GTs the stake will have.
defaultStakedGTs :: Tagged _ Integer
defaultStakedGTs = Tagged 100000

-- | How a stake has been used on a particular proposal.
data StakeRole
  = -- | The stake was spent to vote for a paraticular option.
    Voter
  | -- | The stake was used to created the proposal.
    Creator
  | -- | The stake has nothing to do with the proposal.
    Irrelevant

-- | Parameters for creating a 'TxOut' that unlocks a stake.
data UnlockStakeParameters = UnlockStakeParameters
  { proposalCount :: Integer
  -- ^ The number of proposals in the 'TxOut'.
  , stakeUsage :: StakeRole
  -- ^ The role of the stake we're unlocking.
  , retractVotes :: Bool
  -- ^ Whether to retract votes or not.
  , proposalStatus :: ProposalStatus
  -- ^ The state of all the proposals.
  }

instance Show UnlockStakeParameters where
  show p =
    let role = case p.stakeUsage of
          Voter -> "voter"
          Creator -> "creator"
          _ -> "irrelevant stake"

        action =
          if p.retractVotes
            then "unlock stake + retract votes"
            else "unlock stake"

        while = show p.proposalStatus

        proposalInfo = mconcat [show p.proposalCount, " proposals"]
     in mconcat [proposalInfo, ", ", role, ", ", action, ", ", while]

-- | Generate some input proposals and their corresponding output proposals.
mkProposals :: UnlockStakeParameters -> ([ProposalDatum], [ProposalDatum])
mkProposals p = unzip $ forEachProposalId p.proposalCount $ mkProposalDatumPair p

-- | Iterate over the proposal id of every proposal, given the number of proposals.
forEachProposalId :: Integer -> (ProposalId -> a) -> [a]
forEachProposalId 0 _ = error "zero proposal"
forEachProposalId n f = f . ProposalId <$> [0 .. n - 1]

-- | Create a valid stake 'TxOut' given the stake datum.
mkStakeTxOut :: StakeDatum -> TxOut
mkStakeTxOut sd =
  let sst = Value.assetClassValue stakeAssetClass 1
      gts = Value.assetClassValue (untag stake.gtClassRef) (untag sd.stakedAmount)
   in TxOut
        { txOutAddress = proposalValidatorAddress
        , txOutValue = sortValue $ sst <> minAda <> gts
        , txOutDatumHash = Just $ toDatumHash sd
        }

-- | Create the input stake and its corresponding output stake.
mkStakeDatumPair :: UnlockStakeParameters -> (StakeDatum, StakeDatum)
mkStakeDatumPair c =
  let output =
        StakeDatum
          { stakedAmount = defaultStakedGTs
          , owner = signer
          , lockedBy = []
          }

      inputLocks = join $ forEachProposalId c.proposalCount (mkStakeLocks c.stakeUsage)

      input = output {lockedBy = inputLocks}
   in (input, output)
  where
    mkStakeLocks :: StakeRole -> ProposalId -> [ProposalLock]
    mkStakeLocks Voter pid = [ProposalLock defaultVoteFor pid]
    mkStakeLocks Creator pid =
      map (`ProposalLock` pid) $
        AssocMap.keys $ getProposalVotes votesTemplate
    mkStakeLocks _ _ = []

-- | Create a valid proposal 'TxOut' given the proposal datum.
mkProposalTxOut :: ProposalDatum -> TxOut
mkProposalTxOut pd =
  let pst = Value.singleton proposalPolicySymbol "" 1
   in TxOut
        { txOutAddress = proposalValidatorAddress
        , txOutValue = sortValue $ pst <> minAda
        , txOutDatumHash = Just $ toDatumHash pd
        }

-- | Create a input proposal and its corresponding output proposal.
mkProposalDatumPair ::
  UnlockStakeParameters ->
  ProposalId ->
  (ProposalDatum, ProposalDatum)
mkProposalDatumPair params pid =
  let owner = signer

      inputVotes = mkInputVotes params.stakeUsage $ untag defaultStakedGTs

      input =
        ProposalDatum
          { proposalId = pid
          , effects = emptyEffectFor votesTemplate
          , status = params.proposalStatus
          , cosigners = [owner]
          , thresholds = def
          , votes = inputVotes
          , timingConfig = def
          , startingTime = ProposalStartingTime 0
          }

      output =
        if params.retractVotes
          then input {votes = votesTemplate}
          else input
   in (input, output)
  where
    -- Assemble the votes of the input proposal based on 'votesTemplate'.
    mkInputVotes ::
      StakeRole ->
      -- The staked amount/votes.
      Integer ->
      ProposalVotes
    mkInputVotes Voter vc =
      ProposalVotes $
        updateMap (Just . const vc) defaultVoteFor $
          getProposalVotes votesTemplate
    mkInputVotes Creator _ =
      ProposalVotes $
        updateMap (Just . const 1000) defaultVoteFor $
          getProposalVotes votesTemplate
    mkInputVotes _ _ = votesTemplate

-- | Create a 'TxInfo' that tries to unlock a stake.
unlockStake :: UnlockStakeParameters -> TxInfo
unlockStake p =
  let (pInDatums, pOutDatums) = mkProposals p
      (sInDatum, sOutDatum) = mkStakeDatumPair p

      pIns =
        zipWith
          ( \i d ->
              ( let txOut = mkProposalTxOut d
                    ref = proposalRef {txOutRefIdx = i}
                 in TxInInfo ref txOut
              )
          )
          [1 ..]
          pInDatums
      pOuts = map mkProposalTxOut pOutDatums

      sIn = TxInInfo stakeRef $ mkStakeTxOut sInDatum
      sOut = mkStakeTxOut sOutDatum

      mkDatum :: forall d. (ToData d) => d -> Datum
      mkDatum = Datum . toBuiltinData

      proposalDatums :: [ProposalDatum]
      proposalDatums =
        if p.retractVotes
          then pInDatums <> pOutDatums
          else pInDatums

      sortDatums :: [(DatumHash, Datum)] -> [(DatumHash, Datum)]
      sortDatums = sortBy (\(k1, _) (k2 , _) -> compare k2 k1)
   in TxInfo
        { txInfoInputs = sIn : pIns
        , txInfoOutputs = sOut : pOuts
        , txInfoFee = Value.singleton "" "" 2
        , txInfoMint = mempty
        , txInfoDCert = []
        , txInfoWdrl = []
        , -- Time doesn't matter int this case.
          txInfoValidRange = closedBoundedInterval 0 100
        , txInfoSignatories = [signer]
        , txInfoData = sortDatums $ datumPair <$> (mkDatum <$> [sInDatum, sOutDatum]) <> (mkDatum <$> proposalDatums)
        , txInfoId = "95ba4015e30aef16a3461ea97a779f814aeea6b8009d99a94add4b8293be737a"
        }

-- | Create the input proposal datum.
mkProposalInputDatum :: UnlockStakeParameters -> ProposalId -> ProposalDatum
mkProposalInputDatum p pid = fst $ mkProposalDatumPair p pid

-- | Create the input stake datum.
mkStakeInputDatum :: UnlockStakeParameters -> StakeDatum
mkStakeInputDatum = fst . mkStakeDatumPair

-- | Create a test case that tests the proposal validator's @'Unlock' _@ redeemer.
mkProposalValidatorTestCase :: UnlockStakeParameters -> Bool -> SpecificationTree
mkProposalValidatorTestCase p shouldSucceed =
  let datum = mkProposalInputDatum p $ ProposalId 0
      redeemer = Unlock (ResultTag 0)
      name = show p
      scriptContext = ScriptContext (unlockStake p) (Spending proposalRef)
      f = if shouldSucceed then validatorSucceedsWith else validatorFailsWith
   in f name (proposalValidator Shared.proposal) datum redeemer scriptContext
