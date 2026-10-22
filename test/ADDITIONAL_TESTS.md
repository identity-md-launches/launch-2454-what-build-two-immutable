# Additional store tests

These tests extend the existing suite without changing application contracts or configuration.

| File | Additional coverage |
| --- | --- |
| `FeaturedModelInvariant.t.sol` | Independent per-account ledger, overlapping payer/booster/recipient roles, listing transfers, recipient rotation, cross-account withdrawal destinations, donations, rejected calls, historical placements and sparse featured pages. |
| `FeaturedTokenBoundary.t.sol` | Malformed decimals/balance ABIs, retryable configuration failures, pending/replaced owner permissions, missing allowances/balances, atomic failed withdrawals, hostile token proceeds claims and full `uint256` boost amounts. |
| `RegistryBoundary.t.sol` | Exact metadata limits, invalid bytes throughout labels, atomic rejection of edits, label removal/reordering, duplicate ownership transfers and unknown IDs. |
| `StorePaginationBoundary.t.sol` | 105 listings/placements crossing the 100-ID scan boundary, ties across pages, filtered totals, empty intermediate pages, terminal cursors and pinned metadata revisions. |

The new invariant campaign runs 256 sequences of 96 calls. Only the twelve explicitly selected
handler operations are fuzz targets. Failed operations must return their expected custom errors;
unexpected reverts fail the campaign. Each sequence starts with a third-party boosted cancellation,
a boosted settlement and a live boosted placement, so the accounting assertions are exercised even
when random calls cannot make progress.

The handler records expected balances from operation inputs. It does not use `available`, `proceeds`,
`totalBoost`, `isActive` or placement getters to decide successful action preconditions or update its
ledger. Cancellation uses the independent identity `refund = ceil(PRICE * remaining / DURATION)`.
Each actor can occupy multiple roles, allowing per-account checks to catch misdirected payments even
when aggregate conservation still holds. A fixed initial token supply bounds all funding, and the
history is capped at 40 placements to keep each invariant check bounded.

Direct token donations create no user credit. Therefore the custody property is
`token.balanceOf(escrow) = accountedBalance + trackedDonations`, while
`accountedBalance = totalAvailable + totalEscrowed + totalProceeds` still holds exactly.
After every sequence, all open placements are settled and every legitimate liability is withdrawn;
only the tracked unsolicited donations remain.

Run from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xb0ac9c1ac023e343fef45fa2aff7fe0c69e33849c1f1ea1d0d0fcc255fc6c781 forge test
```

All tests run offline using the existing committed dependencies and local token fixtures. They do
not verify the live IMD deployment at the supplied Robinhood Chain address; live token identity and
behavior remain a separate deployment/integration check. Test actor addresses are local fixtures,
not proposed deployment owners, recipients or dependencies.
