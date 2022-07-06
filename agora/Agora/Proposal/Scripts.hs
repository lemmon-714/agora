{- |
Module     : Agora.Proposal.Scripts
Maintainer : emi@haskell.fyi
Description: Plutus Scripts for Proposals.

Plutus Scripts for Proposals.
-}
module Agora.Proposal.Scripts (
  proposalValidator,
  proposalPolicy,
) where

import Agora.Proposal (
  PProposalDatum (PProposalDatum),
  PProposalRedeemer (..),
  PProposalVotes (PProposalVotes),
  Proposal (governorSTAssetClass, stakeSTAssetClass),
  ProposalStatus (..),
  pretractVotes,
  pwinner',
 )
import Agora.Proposal.Time (
  currentProposalTime,
  isDraftPeriod,
  isExecutionPeriod,
  isLockingPeriod,
  isVotingPeriod,
 )
import Agora.Stake (
  PProposalLock (..),
  PStakeDatum (..),
  PStakeUsage (..),
  pgetStakeUsage,
 )
import Agora.Utils (
  getMintingPolicySymbol,
  mustBePJust,
  mustFindDatum',
  pisUniq',
  pltAsData,
 )
import Plutarch.Api.V1 (
  PDatumHash,
  PMintingPolicy,
  PPubKeyHash,
  PScriptContext (PScriptContext),
  PScriptPurpose (PMinting, PSpending),
  PTxInfo (PTxInfo),
  PTxOut,
  PValidator,
 )
import Plutarch.Api.V1.AssetClass (passetClass, passetClassValueOf)
import Plutarch.Api.V1.ScriptContext (
  pfindTxInByTxOutRef,
  pisTokenSpent,
  ptryFindDatum,
  ptxSignedBy,
 )
import "liqwid-plutarch-extra" Plutarch.Api.V1.Value (psymbolValueOf)
import Plutarch.Extra.Comonad (pextract)
import Plutarch.Extra.IsData (pmatchEnum)
import Plutarch.Extra.List (pmapMaybe, pmergeBy, pmsortBy)
import Plutarch.Extra.Map (plookup, pupdate)
import Plutarch.Extra.Maybe (pfromDJust, pfromJust, pisJust)
import Plutarch.Extra.Record (mkRecordConstr, (.&), (.=))
import Plutarch.Extra.TermCont (
  pguardC,
  pletC,
  pletFieldsC,
  pmatchC,
  ptryFromC,
 )
import Plutarch.SafeMoney (PDiscrete (..))
import Plutarch.Unsafe (punsafeCoerce)
import PlutusLedgerApi.V1.Value (AssetClass (AssetClass))

{- | Policy for Proposals.

     == What this policy does

     === For minting:

     - Governor is happy with mint.

       * The governor must do most of the checking for the validity of the
         transaction. For example, the governor must check that the datum
         is correct, and that the ST is correctly paid to the right validator.

     - Exactly 1 token is minted.

     === For burning:

     - This policy cannot be burned.

     @since 0.1.0
-}
proposalPolicy ::
  -- | The assetclass of GST, see 'Agora.Governor.Scripts.governorPolicy'.
  AssetClass ->
  ClosedTerm PMintingPolicy
proposalPolicy (AssetClass (govCs, govTn)) =
  plam $ \_redeemer ctx' -> unTermCont $ do
    PScriptContext ctx' <- pmatchC ctx'
    ctx <- pletFieldsC @'["txInfo", "purpose"] ctx'
    PTxInfo txInfo' <- pmatchC $ pfromData ctx.txInfo
    txInfo <- pletFieldsC @'["inputs", "mint"] txInfo'
    PMinting _ownSymbol <- pmatchC $ pfromData ctx.purpose

    let inputs = txInfo.inputs
        mintedValue = pfromData txInfo.mint

    PMinting ownSymbol' <- pmatchC $ pfromData ctx.purpose
    let mintedProposalST =
          passetClassValueOf
            # mintedValue
            # (passetClass # (pfield @"_0" # ownSymbol') # pconstant "")

    pguardC "Governance state-thread token must move" $
      pisTokenSpent
        # (passetClass # pconstant govCs # pconstant govTn)
        # inputs

    pguardC "Minted exactly one proposal ST" $
      mintedProposalST #== 1

    pure $ popaque (pconstant ())

{- | The validator for Proposals.

     The documentation for various of the redeemers lives at 'Agora.Proposal.ProposalRedeemer'.

     == What this validator does

     === Voting/unlocking

     When voting and unlocking, the proposal must witness a state transition
     occuring in the relevant Stake. This transition must place a lock on
     the stake that is tagged with the right 'Agora.Proposal.ResultTag', and 'Agora.Proposal.ProposalId'.

     === Periods

     Most redeemers are time-sensitive.

     A list of all time-sensitive redeemers and their requirements:

     - 'Agora.Proposal.Vote' can only be used when both the status is in 'Agora.Proposal.VotingReady',
       and 'Agora.Proposal.Time.isVotingPeriod' is true.
     - 'Agora.Proposal.Cosign' can only be used when both the status is in 'Agora.Proposal.Draft',
       and 'Agora.Proposal.Time.isDraftPeriod' is true.
     - 'Agora.Proposal.AdvanceProposal' can only be used when the status can be advanced
       (see 'Agora.Proposal.AdvanceProposal' docs).
     - 'Agora.Proposal.Unlock' is always valid.

     @since 0.1.0
-}
proposalValidator :: Proposal -> ClosedTerm PValidator
proposalValidator proposal =
  plam $ \datum redeemer ctx' -> unTermCont $ do
    PScriptContext ctx' <- pmatchC ctx'
    ctx <- pletFieldsC @'["txInfo", "purpose"] ctx'
    txInfo <- pletC $ pfromData ctx.txInfo
    PTxInfo txInfo' <- pmatchC txInfo
    txInfoF <-
      pletFieldsC
        @'[ "inputs"
          , "outputs"
          , "mint"
          , "datums"
          , "signatories"
          , "validRange"
          ]
        txInfo'
    PSpending ((pfield @"_0" #) -> txOutRef) <- pmatchC $ pfromData ctx.purpose

    PJust ((pfield @"resolved" #) -> txOut) <- pmatchC $ pfindTxInByTxOutRef # txOutRef # txInfoF.inputs
    txOutF <- pletFieldsC @'["address", "value"] $ txOut

    (pfromData -> proposalDatum, _) <-
      ptryFromC @(PAsData PProposalDatum) datum
    (pfromData -> proposalRedeemer, _) <-
      ptryFromC @(PAsData PProposalRedeemer) redeemer

    proposalF <-
      pletFieldsC
        @'[ "proposalId"
          , "effects"
          , "status"
          , "cosigners"
          , "thresholds"
          , "votes"
          , "timingConfig"
          , "startingTime"
          ]
        proposalDatum

    ownAddress <- pletC $ txOutF.address

    thresholdsF <- pletFieldsC @'["execute", "create", "vote"] proposalF.thresholds

    currentStatus <- pletC $ pfromData $ proposalF.status

    let stCurrencySymbol =
          pconstant $ getMintingPolicySymbol (proposalPolicy proposal.governorSTAssetClass)

    signedBy <- pletC $ ptxSignedBy # txInfoF.signatories

    currentTime <- pletC $ currentProposalTime # txInfoF.validRange

    -- Own output is an output that
    --  * is sent to the address of the proposal validator
    --  * has an PST
    --  * has the same proposal id as the proposal input
    --
    -- We match the proposal id here so that we can support multiple
    --  proposal inputs in one thansaction.
    ownOutput <-
      pletC $
        mustBePJust # "Own output should be present" #$ pfind
          # plam
            ( \input -> unTermCont $ do
                inputF <- pletFieldsC @'["address", "value", "datumHash"] input

                -- TODO: this is highly inefficient: O(n) for every output,
                --       Maybe we can cache the sorted datum map?
                let datum =
                      mustFindDatum' @PProposalDatum
                        # inputF.datumHash
                        # txInfoF.datums

                    proposalId = pfield @"proposalId" # datum

                pure $
                  inputF.address #== ownAddress
                    #&& psymbolValueOf # stCurrencySymbol # inputF.value #== 1
                    #&& proposalId #== proposalF.proposalId
            )
          # pfromData txInfoF.outputs

    proposalOut <-
      pletC $
        mustFindDatum' @PProposalDatum
          # (pfield @"datumHash" # ownOutput)
          # txInfoF.datums

    proposalUnchanged <- pletC $ proposalOut #== proposalDatum

    proposalOutStatus <-
      pletC $
        pfromData $
          pfield @"status" # proposalOut

    onlyStatusChanged <-
      pletC $
        -- Only the status of proposals is updated.

        -- Only the status of proposals is updated.
        proposalOut
          #== mkRecordConstr
            PProposalDatum
            ( #proposalId .= proposalF.proposalId
                .& #effects .= proposalF.effects
                .& #status .= pdata proposalOutStatus
                .& #cosigners .= proposalF.cosigners
                .& #thresholds .= proposalF.thresholds
                .& #votes .= proposalF.votes
                .& #timingConfig .= proposalF.timingConfig
                .& #startingTime .= proposalF.startingTime
            )

    --------------------------------------------------------------------------

    -- Find the stake inputs/outputs by SST.

    let AssetClass (stakeSym, stakeTn) = proposal.stakeSTAssetClass
    stakeSTAssetClass <-
      pletC $ passetClass # pconstant stakeSym # pconstant stakeTn

    filterStakeDatumHash :: Term _ (PAsData PTxOut :--> PMaybe (PAsData PDatumHash)) <-
      pletC $
        plam $ \(pfromData -> txOut) -> unTermCont $ do
          txOutF <- pletFieldsC @'["value", "datumHash"] txOut
          pure $
            pif
              (passetClassValueOf # txOutF.value # stakeSTAssetClass #== 1)
              ( let datumHash = pfromDJust # txOutF.datumHash
                 in pcon $ PJust $ pdata datumHash
              )
              (pcon PNothing)

    stakeInputDatumHashes <-
      pletC $
        pmapMaybe @PBuiltinList
          # plam ((filterStakeDatumHash #) . (pfield @"resolved" #))
          # txInfoF.inputs

    stakeOutputDatumHashes <-
      pletC $
        pmapMaybe @PBuiltinList
          # filterStakeDatumHash
          # txInfoF.outputs

    stakeInputNum <- pletC $ plength # stakeInputDatumHashes

    pguardC "Every stake input should have a correspoding output" $
      stakeInputNum #== plength # stakeOutputDatumHashes

    ----------------------------------------------------------------------------

    withMultipleStakes' ::
      Term
        _
        ( ( PInteger
              :--> PBuiltinList (PAsData PPubKeyHash)
              :--> PUnit
          )
            :--> PUnit
        ) <-
      pletC $
        plam $ \validationLogic -> unTermCont $ do
          -- The following code ensures that all the stake datums are not
          --   changed.
          --
          -- TODO: This is quite inefficient (O(nlogn)) but for now we don't
          --   have a nice way to check this. In plutus v2 we'll have map of
          --   (Script -> Redeemer) in ScriptContext, which should be the
          --   straight up solution.
          let sortDatumHashes = phoistAcyclic $ pmsortBy # pltAsData

              sortedStakeInputDatumHashes =
                sortDatumHashes # stakeInputDatumHashes

              sortedStakeOutputDatumHashes =
                sortDatumHashes # stakeOutputDatumHashes

          pguardC "All stake datum are unchanged" $
            plistEquals
              # sortedStakeInputDatumHashes
              # sortedStakeOutputDatumHashes

          PPair totalStakedAmount stakeOwners <-
            pmatchC $
              pfoldl
                # plam
                  ( \l dh -> unTermCont $ do
                      let stake =
                            pfromData $
                              pfromJust
                                #$ ptryFindDatum
                                  @(PAsData PStakeDatum)
                                # pfromData dh
                                # txInfoF.datums

                      stakeF <- pletFieldsC @'["stakedAmount", "owner"] stake

                      PPair amount owners <- pmatchC l

                      let newAmount = amount + punsafeCoerce (pfromData stakeF.stakedAmount)
                          updatedOwners = pcons # stakeF.owner # owners

                      pure $ pcon $ PPair newAmount updatedOwners
                  )
                # pcon (PPair (0 :: Term _ PInteger) (pnil @PBuiltinList))
                # stakeInputDatumHashes

          sortedStakeOwners <- pletC $ pmsortBy # pltAsData # stakeOwners

          pure $ validationLogic # totalStakedAmount # sortedStakeOwners

    withSingleStake' ::
      Term
        _
        ( ( PStakeDatum :--> PStakeDatum :--> PBool :--> PUnit
          )
            :--> PUnit
        ) <- pletC $
      plam $ \validationLogic -> unTermCont $ do
        pguardC "Can only deal with one stake" $
          stakeInputNum #== 1

        stakeInputHash <- pletC $ pfromData $ phead # stakeInputDatumHashes
        stakeOutputHash <- pletC $ pfromData $ phead # stakeOutputDatumHashes

        stakeIn :: Term _ PStakeDatum <-
          pletC $
            pfromData $
              pfromJust #$ ptryFindDatum # stakeInputHash # txInfoF.datums

        stakeOut :: Term _ PStakeDatum <-
          pletC $
            pfromData $
              pfromJust #$ ptryFindDatum # stakeOutputHash # txInfoF.datums

        stakeUnchanged <- pletC $ stakeInputHash #== stakeOutputHash

        pure $ validationLogic # stakeIn # stakeOut # stakeUnchanged

    let withMultipleStakes val =
          withMultipleStakes' #$ plam $
            \totalStakedAmount
             sortedStakeOwner ->
                unTermCont $
                  val totalStakedAmount sortedStakeOwner

        withSingleStake val =
          withSingleStake' #$ plam $ \stakeIn stakeOut stakeUnchange -> unTermCont $ do
            stakeInF <- pletFieldsC @'["stakedAmount", "lockedBy", "owner"] stakeIn

            val stakeInF stakeOut stakeUnchange

    pure $
      popaque $
        pmatch proposalRedeemer $ \case
          PCosign r -> withMultipleStakes $ \_ sortedStakeOwners -> do
            pguardC "Should be in draft state" $
              currentStatus #== pconstant Draft

            newSigs <- pletC $ pfield @"newCosigners" # r

            pguardC "Signed by all new cosigners" $
              pall # signedBy # newSigs

            updatedSigs <-
              pletC $
                pmergeBy # pltAsData
                  # newSigs
                  # proposalF.cosigners

            pguardC "Cosigners are unique" $
              pisUniq' # updatedSigs

            pguardC "All new cosigners are witnessed by their Stake datums" $
              plistEquals # sortedStakeOwners # newSigs

            let expectedDatum =
                  mkRecordConstr
                    PProposalDatum
                    ( #proposalId .= proposalF.proposalId
                        .& #effects .= proposalF.effects
                        .& #status .= proposalF.status
                        .& #cosigners .= pdata updatedSigs
                        .& #thresholds .= proposalF.thresholds
                        .& #votes .= proposalF.votes
                        .& #timingConfig .= proposalF.timingConfig
                        .& #startingTime .= proposalF.startingTime
                    )

            pguardC "Signatures are correctly added to cosignature list" $
              proposalOut #== expectedDatum

            pure $ pconstant ()

          ----------------------------------------------------------------------

          PVote r -> withSingleStake $ \stakeInF stakeOut _ -> do
            pguardC "Input proposal must be in VotingReady state" $
              currentStatus #== pconstant VotingReady

            pguardC "Proposal time should be wthin the voting period" $
              isVotingPeriod # proposalF.timingConfig
                # proposalF.startingTime
                # currentTime

            -- Ensure the transaction is voting to a valid 'ResultTag'(outcome).
            PProposalVotes voteMap <- pmatchC proposalF.votes
            voteFor <- pletC $ pfromData $ pfield @"resultTag" # r

            pguardC "Vote option should be valid" $
              pisJust #$ plookup # voteFor # voteMap

            -- Ensure that no lock with the current proposal id has been put on the stake.
            pguardC "Same stake shouldn't vote on the same proposal twice" $
              pnot #$ pany
                # plam
                  ( \((pfield @"proposalTag" #) . pfromData -> pid) ->
                      pid #== proposalF.proposalId
                  )
                # pfromData stakeInF.lockedBy

            let -- The amount of new votes should be the 'stakedAmount'.
                -- Update the vote counter of the proposal, and leave other stuff as is.
                expectedNewVotes = pmatch (pfromData proposalF.votes) $ \(PProposalVotes m) ->
                  pcon $
                    PProposalVotes $
                      pupdate
                        # plam
                          ( \votes -> unTermCont $ do
                              PDiscrete v <- pmatchC stakeInF.stakedAmount
                              pure $ pcon $ PJust $ votes + (pextract # v)
                          )
                        # voteFor
                        # m
                expectedProposalOut =
                  mkRecordConstr
                    PProposalDatum
                    ( #proposalId .= proposalF.proposalId
                        .& #effects .= proposalF.effects
                        .& #status .= proposalF.status
                        .& #cosigners .= proposalF.cosigners
                        .& #thresholds .= proposalF.thresholds
                        .& #votes .= pdata expectedNewVotes
                        .& #timingConfig .= proposalF.timingConfig
                        .& #startingTime .= proposalF.startingTime
                    )

            pguardC "Output proposal should be valid" $ proposalOut #== expectedProposalOut

            -- We validate the output stake datum here as well: We need the vote option
            -- to create a valid 'ProposalLock', however the vote option is encoded
            -- in the proposal redeemer, which is invisible for the stake validator.

            let newProposalLock =
                  mkRecordConstr
                    PProposalLock
                    ( #vote .= pdata voteFor
                        .& #proposalTag .= proposalF.proposalId
                    )
                -- Prepend the new lock to existing locks
                expectedProposalLocks =
                  pcons
                    # pdata newProposalLock
                    # pfromData stakeInF.lockedBy
                expectedStakeOut =
                  mkRecordConstr
                    PStakeDatum
                    ( #stakedAmount .= stakeInF.stakedAmount
                        .& #owner .= stakeInF.owner
                        .& #lockedBy .= pdata expectedProposalLocks
                    )

            pguardC "Output stake should be locked by the proposal" $ expectedStakeOut #== stakeOut

            pure $ pconstant ()

          ----------------------------------------------------------------------

          PUnlock r -> withSingleStake $ \stakeInF stakeOut _ -> do
            -- At draft stage, the votes should be empty.
            pguardC "Shouldn't retract votes from a draft proposal" $
              pnot #$ currentStatus #== pconstant Draft

            -- This is the vote option we're retracting from.
            retractFrom <- pletC $ pfield @"resultTag" # r

            -- Determine if the input stake is actually locked by this proposal.
            stakeUsage <- pletC $ pgetStakeUsage # stakeInF.lockedBy # proposalF.proposalId

            pguardC "Stake input relevant" $
              pmatch stakeUsage $ \case
                PDidNothing ->
                  ptraceIfFalse "Stake should be relevant" $
                    pconstant False
                PCreated ->
                  ptraceIfFalse "Removing creator's locks means status is Finished" $
                    currentStatus #== pconstant Finished
                PVotedFor rt ->
                  ptraceIfFalse "Result tag should match the one given in the redeemer" $
                    rt #== retractFrom

            -- The count of removing votes is equal to the 'stakeAmount' of input stake.
            retractCount <-
              pletC $
                pmatch stakeInF.stakedAmount $ \(PDiscrete v) -> pextract # v

            -- The votes can only change when the proposal still allows voting.
            let shouldUpdateVotes =
                  currentStatus #== pconstant VotingReady
                    #&& pnot # (pcon PCreated #== stakeUsage)

            pguardC "Proposal output correct" $
              pif
                shouldUpdateVotes
                ( let -- Remove votes and leave other parts of the proposal as it.
                      expectedVotes = pretractVotes # retractFrom # retractCount # proposalF.votes

                      expectedProposalOut =
                        mkRecordConstr
                          PProposalDatum
                          ( #proposalId .= proposalF.proposalId
                              .& #effects .= proposalF.effects
                              .& #status .= proposalF.status
                              .& #cosigners .= proposalF.cosigners
                              .& #thresholds .= proposalF.thresholds
                              .& #votes .= pdata expectedVotes
                              .& #timingConfig .= proposalF.timingConfig
                              .& #startingTime .= proposalF.startingTime
                          )
                   in ptraceIfFalse "Update votes" $
                        expectedProposalOut #== proposalOut
                )
                -- No change to the proposal is allowed.
                $ ptraceIfFalse "Proposal unchanged" proposalUnchanged

            -- At last, we ensure that all locks belong to this proposal will be removed.
            stakeOutputLocks <- pletC $ pfield @"lockedBy" # stakeOut

            let templateStakeOut =
                  mkRecordConstr
                    PStakeDatum
                    ( #stakedAmount .= stakeInF.stakedAmount
                        .& #owner .= stakeInF.owner
                        .& #lockedBy .= stakeOutputLocks
                    )

            pguardC "Only locks updated in the output stake" $
              templateStakeOut #== stakeOut

            pguardC "All relevant locks removed from the stake" $
              pgetStakeUsage # pfromData stakeOutputLocks
                # proposalF.proposalId #== pcon PDidNothing

            pure $ pconstant ()

          ----------------------------------------------------------------------

          PAdvanceProposal _ ->
            let fromDraft = withMultipleStakes $ \totalStakedAmount sortedStakeOwners ->
                  pmatchC (isDraftPeriod # proposalF.timingConfig # proposalF.startingTime # currentTime) >>= \case
                    PTrue -> do
                      pguardC "More cosigns than minimum amount" $
                        punsafeCoerce (pfromData thresholdsF.vote) #< totalStakedAmount

                      pguardC "All new cosigners are witnessed by their Stake datums" $
                        plistEquals # sortedStakeOwners # proposalF.cosigners

                      -- 'Draft' -> 'VotingReady'
                      pguardC "Proposal status set to VotingReady" $
                        proposalOutStatus #== pconstant VotingReady

                      pure $ pconstant ()
                    PFalse -> do
                      pguardC "Advance to failed state" $ proposalOutStatus #== pconstant Finished

                      pure $ pconstant ()

                fromOther = withSingleStake $ \_ _ stakeUnchanged -> do
                  pguardC "Stake should not change" stakeUnchanged

                  pguardC
                    "Only status changes in the output proposal"
                    onlyStatusChanged

                  inVotingPeriod <- pletC $ isVotingPeriod # proposalF.timingConfig # proposalF.startingTime # currentTime
                  inLockedPeriod <- pletC $ isLockingPeriod # proposalF.timingConfig # proposalF.startingTime # currentTime
                  inExecutionPeriod <- pletC $ isExecutionPeriod # proposalF.timingConfig # proposalF.startingTime # currentTime

                  proposalStatus <- pletC $ pto $ pfromData proposalF.status

                  -- Check the timings.
                  let isFinished = currentStatus #== pconstant Finished

                      notTooLate = pmatchEnum proposalStatus $ \case
                        -- Can only advance after the voting period is over.
                        VotingReady -> inLockedPeriod
                        Locked -> inExecutionPeriod
                        _ -> pconstant False

                      notTooEarly = pmatchEnum (pto $ pfromData proposalF.status) $ \case
                        VotingReady -> pnot # inVotingPeriod
                        Locked -> pnot # inLockedPeriod
                        _ -> pconstant True

                  pguardC "Cannot advance ahead of time" notTooEarly
                  pguardC "Finished proposals cannot be advanced" $ pnot # isFinished

                  let toFailedState = unTermCont $ do
                        pguardC "Proposal should fail: not on time" $
                          proposalOutStatus #== pconstant Finished

                        -- TODO: Should check that the GST is not moved
                        --        if the proposal is in 'Locked' state.

                        pure $ pconstant ()

                      toNextState = pmatchEnum proposalStatus $ \case
                        VotingReady -> unTermCont $ do
                          -- 'VotingReady' -> 'Locked'
                          pguardC "Proposal status set to Locked" $
                            proposalOutStatus #== pconstant Locked

                          pguardC "Winner outcome not found" $
                            pisJust #$ pwinner' # proposalF.votes
                              #$ punsafeCoerce
                              $ pfromData thresholdsF.execute

                          pure $ pconstant ()
                        Locked -> unTermCont $ do
                          -- 'Locked' -> 'Finished'
                          pguardC "Proposal status set to Finished" $
                            proposalOutStatus #== pconstant Finished

                          -- TODO: Perform other necessary checks.
                          pure $ pconstant ()
                        _ -> pconstant ()

                  pure $
                    pif
                      notTooLate
                      -- On time: advance to next status.
                      toNextState
                      -- Too late: failed proposal, status set to 'Finished'.
                      toFailedState
             in pif (currentStatus #== pconstant Draft) fromDraft fromOther
