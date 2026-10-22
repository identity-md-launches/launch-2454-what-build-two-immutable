# The Hooks Store contracts

Two immutable application contracts: a free listing registry and a refundable,
24-hour featured-placement escrow paid in IMD. Build from the repository root.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xb0ac9c1ac023e343fef45fa2aff7fe0c69e33849c1f1ea1d0d0fcc255fc6c781 forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer runs **200**, and
`bytecode_hash = "none"` with CBOR metadata disabled. All Solidity dependencies
are ordinary files under `lib/`; the build and tests need no network, RPC, keys,
environment configuration, FFI, or filesystem cheatcode permissions. The test
command's seed is the assignment's reproducibility seed; the configuration does
not override it. Fuzz tests run 256 cases; each of the two stateful invariants
runs 128 sequences of 128 actions with `fail_on_revert = true`.

The implementation starts from the request's
[pinned source at commit 46e17ea70534e8a7ac2c4ff78501a3c183d32da8](https://github.com/identity-md-launches/launch-1811-build-technical-foundation-hooks/tree/46e17ea70534e8a7ac2c4ff78501a3c183d32da8/src/store).
`HookListingRegistry.sol`, `StoreAdmin.sol`, and `ExactStoreToken.sol` are preserved
byte-for-byte. [Provenance](docs/UPSTREAM.md) records the imported files and V2
changes. [Review notes](docs/REVIEW.md) describe coverage and remaining operational
assumptions.

## Deployment parameters

Deploy only these two contracts, in this order, using the launch's normal
deployment handoff. Neither constructor is payable or calls another contract.
Neither constructor requires another address to have code. No tokens, hooks,
pools, liquidity, or proceeds are created or transferred at deployment.

| Contract | Source | Constructor arguments, in order |
| --- | --- | --- |
| `HookListingRegistry` | `src/store/HookListingRegistry.sol` | None |
| `FeaturedPlacementsV2` | `src/store/FeaturedPlacementsV2.sol` | `$owner`, `$contract:HookListingRegistry` |

The Solidity constructor types are `FeaturedPlacementsV2(address owner_,
HookListingRegistry registry_)`. Ownership belongs to the explicit `owner_`,
even when a factory deploys it. The registry has no administrator. The registry
reference is immutable. Both contracts have immutable code, without a proxy,
upgrade entry point, delegatecall, callcode, or selfdestruct.

The first launch targets **Robinhood Chain, chain ID 4663**. The separate Ethereum
launch targets **chain ID 1** and uses the same source and build settings, with
its own registry and escrow state. There are no chain-specific address constants
in the contracts and no cross-chain state synchronization. Deployment addresses
come from the confirmed launch handoff, not this repository.

For the stated Robinhood launch, `$owner` resolves to
`0x5bff2a2fecd1d6152676813b21346238733beab1`. The token is deliberately not a
constructor argument. The manifest is supplied by the separate launch step.

## After launch

The owner must complete these settings before purchases can work:

| Setter | Value and source | Effect |
| --- | --- | --- |
| `configureToken(address)` | On Robinhood, the brief supplies IMD at `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`. Verify its identity and transfer behavior on chain before calling. | Owner-only and successful configuration is permanent. Requires deployed code, 18 decimals, and a valid `balanceOf` response. |
| `setProceedsRecipient(address)` | The owner's own wallet; for the stated launch, `0x5bff2a2fecd1d6152676813b21346238733beab1`. | Owner-only. Affects future purchases; each placement pins its recipient when purchased. |

The Ethereum IMD address is not supplied in the brief. For that separate launch,
the owner obtains and verifies the Ethereum IMD address from the issuer's
canonical deployment records, then calls the same one-time `configureToken`.
There is no assumed reuse of the Robinhood address and no fallback token.
Leaving it unconfigured safely disables token-dependent operations.

Before configuration, `deposit`, `withdraw`, `withdrawProceeds`, and `purchase`
revert with `TokenNotConfigured`. After the token is set, deposits and withdrawals
work independently of the proceeds-recipient setting; purchases still revert
with `RecipientNotConfigured` until the recipient is set. No placement exists to
boost before a successful purchase.

Owner rotation uses `transferOwnership(proposedOwner)`, followed by
`acceptOwnership()` from that proposed owner. The existing owner can replace or
cancel a pending proposal using `cancelOwnershipTransfer()`. Ownership transfer
does not change the configured token, proceeds recipient, or historical rights.
The owner's powers are limited to this handover, configuring the token once, and
setting the recipient for future purchases. There is no pause, sweep, price or
duration setter, administrative cancellation, or power to withdraw another
account's funds. Recipient rotation must preserve access to old recipient wallets
until their historical proceeds are withdrawn.

## Listings and placements

Listings are free apart from network gas. A listing is a claim by its owner about
a `(chainId, hook)` identity, not proof of hook ownership, deployment, or security.
Separate owners can list the same hook; an owner cannot create a duplicate claim.
Metadata revisions remain readable. Listing owners can edit, archive, reactivate,
and transfer their listings through a two-step handover. `isAudited` always
returns false. Ad payments do not change that result.

An advertiser approves the configured token to the escrow and calls
`deposit(amount)`. `purchase(listingId, expectedRevision, expectedRecipient,
deadline)` uses **100000000000000000 base units (0.1 IMD)** from the current
listing owner's deposit. The purchase pins the metadata revision, payer,
recipient, start, and end. Its lifetime is **86400 seconds (24 hours)**, measured
using `block.timestamp`. At most one live placement exists per listing.

Any account can call `boost(placementId, amount)` using its own available deposit.
Amounts must be positive and within that balance. Boosts cannot spend wallet
allowances directly or consume another user's deposit or proceeds. Boosting
does not extend the placement or grant cancellation rights. It increments
`totalBoost[id]` and moves the amount from available funds into escrow.

For boosting and cancellation, a placement must still have status `Open` **and**
the current timestamp must be strictly before `endsAt`. At `endsAt`, it disappears
from the featured feed immediately, although its status stays `Open` until
settled. Anyone can call `settle(id)` from that timestamp onward. A new placement
can be purchased after expiry even if the previous placement remains unsettled.

Only the original payer or the current listing owner can cancel before expiry.
The refund always belongs to the original payer, including after a listing
transfer. Archiving or editing a listing leaves purchased snapshots active.
The current listing owner can cancel a seller's placement to clear it for a new
purchase. A third-party booster must accept that either authorized party may
cancel immediately and the boost will still be forfeited.

For elapsed time `e`, cancellation credits:

```text
baseEarned = floor(PRICE * e / DURATION)
payerRefund = PRICE - baseEarned
recipientProceeds = baseEarned + totalBoost[id]
```

Thus rounding stays in the payer's favor, and even an immediate cancellation
refunds only the base price. Settlement credits `PRICE + totalBoost[id]` to the
pinned recipient. Boosts are never refunded. Closing a placement performs no
token transfer: refunds become available balances and proceeds become recipient
credits. Depositors call `withdraw(amount, to)` and recipients call
`withdrawProceeds(amount, to)` themselves. Failed transfers revert the debit and
can be retried. There is no automated settlement transaction or keeper reward;
anyone may settle, and recipients can settle expired placements before claiming.

## Website and event integration

`rankOf(id)` returns the base price plus cumulative boosts, **not an ordinal
position**. It rejects unknown IDs and retains the historical total after
cancellation or settlement. Use `isActive(id)` to determine current eligibility.

The V2 return ABI is:

```solidity
featured(uint256 cursor, uint256 scanLimit)
    returns (Placement[] ads, uint256[] totals, uint256 nextCursor)
```

`totals[i]` corresponds to `ads[i]`. Start at cursor 1 and use scan limits from 1
through 100. Both arrays contain only live placements and have equal lengths.
The cursor counts scanned IDs, so empty pages can precede later results. Continue
until `nextCursor > placementCount`. Reads remain in ascending ID order and do
not sort globally on chain. Fetch all pages at the same block, then sort by
**total descending, breaking ties by lower placement ID first**. Treat amounts
and IDs as integers of full EVM precision (for example JavaScript `BigInt`).
Read a placement's historical metadata revision when rendering it.

Each placement has the immutable `bytes3("#ad")` label. All placement lifecycle
events carry it: `PlacementPurchased`, `PlacementBoosted`, `PlacementCancelled`,
and `PlacementSettled`. V2 adds `bytes3 label` to the cancellation and settlement
event signatures so subscribers must use the V2 ABI. Deposit, withdrawal, and
administration events retain their original signatures. The boost event includes
the booster, amount, and new base-plus-boost total. Cancellation/settlement
`earned` amounts include the complete boost. The website must display `#ad` for
every paid placement, independently of listing labels.

## Accounting and assumptions

The contract maintains:

```text
accountedBalance = totalAvailable + totalEscrowed + totalProceeds
totalEscrowed = sum(PRICE + totalBoost[id] for every unclosed placement)
```

Expiry alone does not release escrow; cancellation or settlement does. Boost
history remains in `totalBoost` after closure but is no longer counted as escrow.
For an exact, non-rebasing token and no unsolicited transfers, token custody equals
`accountedBalance`. Direct token transfers do not create credits, can make custody
larger than accounted liabilities, and have no recovery/sweep mechanism.

The configured token must implement honest balances and exact transfers without
rebasing. Incoming and outgoing transfers verify both endpoint balance changes;
true-returning and no-return tokens are supported, while fees, false returns,
malformed responses, and fake movements are rejected. These checks cannot establish
token identity or prevent later token-admin changes, confiscation, or rebasing.
The owner must review those properties before the irreversible configuration.
No production RPC verification of the IMD token is claimed by these local tests.

Timestamp changes and transaction inclusion affect when a cancellation or boost
lands. The contract does not guarantee website display, rank persistence, or a
refund for service outages. Listing metadata is untrusted content and must be
rendered safely by the website. The launch's independent security review remains
separate from these implementation tests.
