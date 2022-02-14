# Treasury technical design

| Specification | Implementation    | Last revision |
|:-----------:|:--------------:|:-------------:|
| WIP         |  WIP           | v0.1 2022-02-07 |

---

**Specification ownership:** [Jack Hodgkinson]

**Authors**:

-   [Jack Hodgkinson]

**Implementation ownership:** _unassigned_

[Jack Hodgkinson]: https://github.com/jhodgdev

[Emily Martins]: https://github.com/emiflake

**Current Status**:

Initial conceptual draft. Requires review from [Emily Martins].

---

Treasuries in Cardano governance systems serve two functions:

1.  To serve as a community reserve or wallet.
2.  To allow users to redeem their allocated share of rewards.

## Community reserve

A decentralised autonomous organisation (DAO) may wish to source funds from its members to save for use at a later date. A treasury therefore serves as a form of 'community wallet', where members can contribute funds, knowing that they may only be released at the behest of the community.

Treasuries are not, by default, limited to the reserve of a single token and are indeed able to hold any supported Cardano tokens.

A treasury, as a community's reserves, will naturally need to interact with governance proposals. Indeed, the primary mechanism by which funds are able to be released by the treasury, will be the passing of an appropriate proposal.

## Reward holder

The treasury will further be the initial holder of all a governance system's GT. It is likely that any governance system will desire a method to distribute these GT through the community _over time_. The amount of GT a DAO member is eligible for at a given time can be termed that user's 'reward'. The specifics of any 'reward structure', namely:

1.  Who is eligible for rewards?
2.  When may they receive those rewards?
3.  How much do they receive in their reward?

are all, naturally, protocol-specific. A simple method for creating such a bespoke reward structure is **not** considered in-scope for Agora v1. Agora v1 will offer a simple, prescribed reward structure, that allows the treasury to determine the reward eligibility of a user and allow them to redeem said amount.