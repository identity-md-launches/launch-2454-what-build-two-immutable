# Implementation review

The V2 delta was reviewed against the pinned source, concentrating on authority,
conservation, closure boundaries, and interactions with the configured token.
This is an implementation review, not an independent security audit.

| Area | Checks and resulting behavior |
| --- | --- |
| Authority | A factory deployment retains the explicit launch owner. Factory and unrelated callers cannot configure the token, change the recipient, or take ownership. Listing control remains in the unchanged registry. |
| Boost accounting | Boosts debit only the caller's available balance and credit escrow. Unit tests include third-party and payer boosts, repetition, insufficient deposits despite allowances, and attempted spending of proceeds. |
| Cancellation | The original integer base-price refund is preserved. Fuzz tests assert its rounding inequality and that all boosts go to the pinned recipient. Listing-owner transfers and recipient rotation cannot redirect refunds or old proceeds. |
| Settlement | Expiry excludes an ad from the feed without requiring a transaction. Permissionless settlement moves base plus boosts once. Renewals coexist safely with expired unsettled escrow. |
| Boundaries | Zero and unknown IDs, zero amounts, excessive amounts, cancelled/settled placements, the last active second, and exact expiry are exercised. |
| Feed | Totals align with filtered placements through empty pages and expiry. Equal totals retain ascending IDs during scans. Higher totals are available for website sorting without unbounded on-chain sorting. |
| Tokens and callbacks | Existing tests reject recipient/sender fees, false/malformed returns, missing code, and fake movements; no-return tokens work. Every guarded custody entry point, including boost, rejects transfer callbacks. Closing boosted placements does not depend on successful token transfers. Failed withdrawals retain retryable credits. |
| Stateful accounting | Two handlers exercise purchases, boosts, cancellation, settlement, withdrawals, recipient changes, time changes, and listing transfers. Each run starts with actual third-party boosts. Tests sum individual credits, all open escrows, all historical boosts, all earnings and all cash flows independently, then wind down every position. |
| Deployment | Local CREATE2 factory rehearsals deploy both contracts in one call on chain IDs 4663 and 1, confirm initially unset token/recipient and zero custody, check EIP-170 runtime size, and scan for the forbidden escape opcodes using the supplied floor's method. |

The original source's timestamp comparisons intentionally implement time-based
terms. Solidity initializes local counters to zero. Token configuration's code
length check rejects zero addresses, and `onlyOwner` preceding `nonReentrant`
does not perform an external call. Custody events emitted after token calls are
inside the reentrancy guard and are reverted if exact-transfer checks fail.
These account for the relevant heuristic warnings from `forge build` without
altering the audited mechanisms.

The supplied protected deployment tests rely on the later launch manifest and
its environment. The repository's deployment rehearsals are local checks of the
same constraints; they do not claim to replace the final protected run. No
production deployment, signed transaction, RPC fork, Slither run, or Mythril run
is part of this deliverable. Production token verification and independent
adversarial review remain launch responsibilities.
