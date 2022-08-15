{- |
Module     : Sample.Proposal.UnlockStake
Maintainer : connor@mlabs.city
Description: Generate sample data for testing the functionalities of unlocking stake and retracting votes

Sample and utilities for testing the functionalities of unlocking stake and retracting votes
-}
module Sample.Proposal.UnlockStake (
  StakeRole (..),
  Parameters (..),
  unlockStake,
  mkTestTree,
  mkVoterRetractVotesWhileVotingParameters,
  mkVoterCreatorRetractVotesWhileVotingParameters,
  mkCreatorRemoveCreatorLocksWhenFinishedParameters,
  mkVoterCreatorRemoveAllLocksWhenFinishedParameters,
  mkVoterUnlockStakeAfterVotingParameters,
  mkVoterCreatorRemoveVoteLocksWhenLockedParameters,
  mkRetractVotesWhileNotVoting,
  mkUnockIrrelevantStakeParameters,
  mkRemoveCreatorLockBeforeFinishedParameters,
  mkRetractVotesWithCreatorStakeParamaters,
  mkAlterStakeParameters,
) where

--------------------------------------------------------------------------------

import Agora.Governor (Governor (..))
import Agora.Proposal (
  ProposalDatum (..),
  ProposalId (..),
  ProposalRedeemer (Unlock),
  ProposalStatus (..),
  ProposalVotes (..),
  ResultTag (..),
 )
import Agora.Proposal.Time (ProposalStartingTime (ProposalStartingTime))
import Agora.Scripts (AgoraScripts (..))
import Agora.Stake (ProposalLock (..), StakeDatum (..), StakeRedeemer (RetractVotes))
import Data.Default.Class (Default (def))
import Data.Tagged (Tagged (..), untag)
import Plutarch.Context (
  input,
  output,
  script,
  signedWith,
  txId,
  withDatum,
  withRef,
  withValue,
 )
import PlutusLedgerApi.V1.Value qualified as Value
import PlutusLedgerApi.V2 (
  DatumHash,
  PubKeyHash,
  TxOutRef (..),
  ValidatorHash,
 )
import PlutusTx.AssocMap qualified as AssocMap
import Sample.Proposal.Shared (stakeTxRef)
import Sample.Shared (
  agoraScripts,
  governor,
  minAda,
  proposalPolicySymbol,
  proposalValidatorHash,
  signer,
  stakeAssetClass,
  stakeValidatorHash,
 )
import Test.Specification (SpecificationTree, group, testValidator)
import Test.Util (CombinableBuilder, mkSpending, sortValue, updateMap)

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
defVoteFor :: ResultTag
defVoteFor = ResultTag 0

-- | The default number of GTs the stake will have.
defStakedGTs :: Tagged _ Integer
defStakedGTs = 100000

{- | If 'Parameters.alterOutputStake' is set to true, the
     'StakeDatum.stakedAmount' will be set to this.
-}
alteredStakedGTs :: Tagged _ Integer
alteredStakedGTs = 100

-- | Default owner of the stakes.
defOwner :: PubKeyHash
defOwner = signer

-- | How a stake has been used on a particular proposal.
data StakeRole
  = -- | The stake was spent to vote for a paraticular option.
    Voter
  | -- | The stake was used to create the proposal.
    Creator
  | -- | The stake was used to both create and vote for the proposal.
    Both
  | -- | The stake has nothing to do with the proposal.
    Irrelevant
  deriving stock (Bounded, Enum, Show)

-- | Parameters for creating a 'TxOut' that unlocks a stake.
data Parameters = Parameters
  { proposalCount :: Integer
  -- ^ The number of proposals in the 'TxOut'.
  , stakeRole :: StakeRole
  -- ^ The role of the stake we're unlocking.
  , retractVotes :: Bool
  -- ^ Whether to retract votes or not.
  , removeVoterLock :: Bool
  -- ^ Remove the voter locks from the input stake.
  , removeCreatorLock :: Bool
  -- ^ Remove the creator locks from the input stake.
  , proposalStatus :: ProposalStatus
  -- ^ The state of all the proposals.
  , alterOutputStake :: Bool
  }

-- | Iterate over the proposal id of every proposal, given the number of proposals.
forEachProposalId :: Parameters -> (ProposalId -> a) -> [a]
forEachProposalId ps = forEachProposalId' ps.proposalCount
  where
    forEachProposalId' :: Integer -> (ProposalId -> a) -> [a]
    forEachProposalId' 0 _ = error "zero proposal"
    forEachProposalId' n f = f . ProposalId <$> [0 .. n - 1]

-- | Create locks for the input stake given the parameters.
mkInputStakeLocks :: Parameters -> [ProposalLock]
mkInputStakeLocks ps = mconcat $ forEachProposalId ps $ mkStakeLocksFor ps.stakeRole
  where
    mkStakeLocksFor :: StakeRole -> ProposalId -> [ProposalLock]
    mkStakeLocksFor sr pid =
      let voted = [Voted pid defVoteFor]
          created = [Created pid]
       in case sr of
            Voter -> voted
            Creator -> created
            Both -> voted <> created
            _ -> []

-- | Create locks for the output stake by removing locks from the input locks.
mkOutputStakeLocks :: Parameters -> [ProposalLock]
mkOutputStakeLocks ps =
  filter
    ( \lock -> not $ case lock of
        Voted _ _ -> ps.removeVoterLock
        Created _ -> ps.removeCreatorLock
    )
    inputLocks
  where
    inputLocks = mkInputStakeLocks ps

-- | Create the stake input datum given the parameters.
mkStakeInputDatum :: Parameters -> StakeDatum
mkStakeInputDatum ps =
  StakeDatum
    { stakedAmount = defStakedGTs
    , owner = defOwner
    , delegatedTo = Nothing
    , lockedBy = mkInputStakeLocks ps
    }

-- | Create stake output datum given the parameters.
mkStakeOutputDatum :: Parameters -> StakeDatum
mkStakeOutputDatum ps =
  let template = mkStakeInputDatum ps
      stakedAmount' =
        if ps.alterOutputStake
          then alteredStakedGTs
          else defStakedGTs
   in template
        { stakedAmount = stakedAmount'
        , lockedBy = mkOutputStakeLocks ps
        }

-- | Generate some input proposals and their corresponding output proposals.
mkProposals :: Parameters -> [(ProposalDatum, ProposalDatum)]
mkProposals ps = forEachProposalId ps $ mkProposalDatumPair ps

-- | Create the input proposal datum.
mkProposalInputDatum :: Parameters -> ProposalId -> ProposalDatum
mkProposalInputDatum p pid = fst $ mkProposalDatumPair p pid

-- | Create a input proposal and its corresponding output proposal.
mkProposalDatumPair ::
  Parameters ->
  ProposalId ->
  (ProposalDatum, ProposalDatum)
mkProposalDatumPair params pid =
  let inputVotes = mkInputVotes params.stakeRole $ untag defStakedGTs

      input =
        ProposalDatum
          { proposalId = pid
          , effects = emptyEffectFor votesTemplate
          , status = params.proposalStatus
          , cosigners = [defOwner]
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
    mkInputVotes Creator _ =
      ProposalVotes $
        updateMap (Just . const 1000) defVoteFor $
          getProposalVotes votesTemplate
    mkInputVotes Irrelevant _ = votesTemplate
    mkInputVotes _ vc =
      ProposalVotes $
        updateMap (Just . const vc) defVoteFor $
          getProposalVotes votesTemplate

-- | Create a 'TxInfo' that tries to unlock a stake.
unlockStake :: forall b. CombinableBuilder b => Parameters -> b
unlockStake ps =
  let pst = Value.singleton proposalPolicySymbol "" 1
      sst = Value.assetClassValue stakeAssetClass 1

      pIODatums = mkProposals ps

      proposals =
        foldMap
          ( \((i, o), idx) ->
              mconcat
                [ input $
                    mconcat
                      [ script proposalValidatorHash
                      , withValue pst
                      , withDatum i
                      , withRef (mkProposalRef idx)
                      ]
                , output $
                    mconcat
                      [ script proposalValidatorHash
                      , withValue (sortValue $ pst <> minAda)
                      , withDatum o
                      ]
                ]
          )
          (zip pIODatums [0 ..])

      stakeValue =
        sortValue $
          mconcat
            [ Value.assetClassValue
                (untag governor.gtClassRef)
                (untag defStakedGTs)
            , sst
            , minAda
            ]

      sInDatum = mkStakeInputDatum ps
      sOutDatum = mkStakeOutputDatum ps

      stakes =
        mconcat
          [ input $
              mconcat
                [ script stakeValidatorHash
                , withValue stakeValue
                , withDatum sInDatum
                , withRef stakeRef
                ]
          , output $
              mconcat
                [ script stakeValidatorHash
                , withValue stakeValue
                , withDatum sOutDatum
                ]
          ]

      builder =
        mconcat
          [ txId "388bc0b897b3dadcd479da4c88291de4113a50b72ddbed001faf7fc03f11bc52"
          , proposals
          , stakes
          , signedWith defOwner
          ]
   in builder

-- | Reference to the stake UTXO.
stakeRef :: TxOutRef
stakeRef = TxOutRef stakeTxRef 1

-- | Generate the reference to a proposal UTXOs, given the index of the proposal.
mkProposalRef :: Int -> TxOutRef
mkProposalRef offset = TxOutRef stakeTxRef $ 2 + fromIntegral offset

-- | Proposal redeemer used by 'mkTestTree', in this case it's always 'Unlock'.
proposalRedeemer :: ProposalRedeemer
proposalRedeemer = Unlock

-- | Stake redeemer used by 'mkTestTree', in this case it's always 'RetractVotes'.
stakeRedeemer :: StakeRedeemer
stakeRedeemer = RetractVotes

--------------------------------------------------------------------------------

{- | Legal parameters that retract votes while the proposals is in 'VotingReady'
      state, and also remove voter locks from the stake, which is
      used to vote on the proposals.
-}
mkVoterRetractVotesWhileVotingParameters :: Integer -> Parameters
mkVoterRetractVotesWhileVotingParameters nProposals =
  Parameters
    { proposalCount = nProposals
    , stakeRole = Voter
    , retractVotes = True
    , removeVoterLock = True
    , removeCreatorLock = False
    , proposalStatus = VotingReady
    , alterOutputStake = False
    }

{- | Legal parameters that retract votes while the proposals is in 'VotingReady'
      state, and also remove voter locks from the stake, which is
      used to both create and vote on the proposals.
-}
mkVoterCreatorRetractVotesWhileVotingParameters :: Integer -> Parameters
mkVoterCreatorRetractVotesWhileVotingParameters nProposals =
  Parameters
    { proposalCount = nProposals
    , stakeRole = Both
    , retractVotes = True
    , removeVoterLock = True
    , removeCreatorLock = False
    , proposalStatus = VotingReady
    , alterOutputStake = False
    }

{- | Legal parameters that remove creator locks from the stake while the
      proposals is in 'Finished' state. The stake was only used for creating
      the proposals.
-}
mkCreatorRemoveCreatorLocksWhenFinishedParameters :: Integer -> Parameters
mkCreatorRemoveCreatorLocksWhenFinishedParameters nProposals =
  Parameters
    { proposalCount = nProposals
    , stakeRole = Creator
    , retractVotes = False
    , removeVoterLock = False
    , removeCreatorLock = True
    , proposalStatus = Finished
    , alterOutputStake = False
    }

{- | Legal parameters that remove voter and creator locks from the stake while
      the proposals is in 'Finished' state. The stake was used for creating
      and voting on the proposals.
-}
mkVoterCreatorRemoveAllLocksWhenFinishedParameters :: Integer -> Parameters
mkVoterCreatorRemoveAllLocksWhenFinishedParameters nProposals =
  Parameters
    { proposalCount = nProposals
    , stakeRole = Both
    , retractVotes = False
    , removeVoterLock = True
    , removeCreatorLock = True
    , proposalStatus = Finished
    , alterOutputStake = False
    }

{- Legal parameters that remove voter locks from the stake after the voting
    phrase. The stake was used only for voting on the proposals.
-}
mkVoterUnlockStakeAfterVotingParameters :: Integer -> [Parameters]
mkVoterUnlockStakeAfterVotingParameters nProposals =
  map
    ( \st ->
        Parameters
          { proposalCount = nProposals
          , stakeRole = Voter
          , retractVotes = False
          , removeVoterLock = True
          , removeCreatorLock = False
          , proposalStatus = st
          , alterOutputStake = False
          }
    )
    [Locked, Finished]

{- Legal parameters that remove voter locks whenproposals are in phrase.
    The stake was used for crating and voting on the proposals.
-}
mkVoterCreatorRemoveVoteLocksWhenLockedParameters :: Integer -> Parameters
mkVoterCreatorRemoveVoteLocksWhenLockedParameters nProposals =
  Parameters
    { proposalCount = nProposals
    , stakeRole = Both
    , retractVotes = False
    , removeVoterLock = True
    , removeCreatorLock = False
    , proposalStatus = Locked
    , alterOutputStake = False
    }

{- | Illegal parameters that retract votes when the proposals are not in voting
      phrase.
-}
mkRetractVotesWhileNotVoting :: Integer -> [Parameters]
mkRetractVotesWhileNotVoting nProposals = do
  role <- enumFrom Voter
  status <- [Draft, Locked, Finished]

  pure $
    Parameters
      { proposalCount = nProposals
      , stakeRole = role
      , retractVotes = True
      , removeVoterLock = True
      , removeCreatorLock = False
      , proposalStatus = status
      , alterOutputStake = False
      }

{- | Illegal parameter that try to unlock a stake that has nothing to do with
      the proposals.
-}
mkUnockIrrelevantStakeParameters :: Integer -> [Parameters]
mkUnockIrrelevantStakeParameters nProposals = do
  status <- [Draft, VotingReady, Locked, Finished]
  retractVotes <- [True, False]

  pure $
    Parameters
      { proposalCount = nProposals
      , stakeRole = Irrelevant
      , retractVotes = retractVotes
      , removeVoterLock = True
      , removeCreatorLock = True
      , proposalStatus = status
      , alterOutputStake = False
      }

{- | Illegal parameters that remove the creator locks before the proposals are
      'Finished'.
-}
mkRemoveCreatorLockBeforeFinishedParameters :: Integer -> [Parameters]
mkRemoveCreatorLockBeforeFinishedParameters nProposals = do
  status <- [Draft, VotingReady, Locked]

  pure $
    Parameters
      { proposalCount = nProposals
      , stakeRole = Creator
      , retractVotes = False
      , removeVoterLock = False
      , removeCreatorLock = True
      , proposalStatus = status
      , alterOutputStake = False
      }

{- | Illegal parameters that try to retract votes with a stake that was only used
    for creating the proposals.
-}
mkRetractVotesWithCreatorStakeParamaters :: Integer -> Parameters
mkRetractVotesWithCreatorStakeParamaters nProposals =
  Parameters
    { proposalCount = nProposals
    , stakeRole = Creator
    , retractVotes = True
    , removeVoterLock = True
    , removeCreatorLock = True
    , proposalStatus = VotingReady
    , alterOutputStake = False
    }

{- | Illegal parameters that try to change the 'StakeDatum.stakedAmount' field of
      the output stake datum.
-}
mkAlterStakeParameters :: Integer -> [Parameters]
mkAlterStakeParameters nProposals = do
  role <- enumFrom Voter
  status <- [Draft, Locked, Finished]

  pure $
    Parameters
      { proposalCount = nProposals
      , stakeRole = role
      , retractVotes = True
      , removeVoterLock = True
      , removeCreatorLock = False
      , proposalStatus = status
      , alterOutputStake = True
      }

--------------------------------------------------------------------------------

{- | Create a test tree that runs both the stake validator and the proposal
     validator.
-}
mkTestTree :: String -> Parameters -> Bool -> SpecificationTree
mkTestTree name ps isValid = group name [stake, proposal]
  where
    spend = mkSpending unlockStake ps

    stake =
      testValidator
        (not ps.alterOutputStake)
        "stake"
        agoraScripts.compiledStakeValidator
        (mkStakeInputDatum ps)
        stakeRedeemer
        (spend stakeRef)

    proposal =
      let idx = 0
          pid = ProposalId $ fromIntegral idx
          ref = mkProposalRef idx
       in testValidator
            isValid
            "proposal"
            agoraScripts.compiledProposalValidator
            (mkProposalInputDatum ps pid)
            proposalRedeemer
            (spend ref)
