# Source provenance

All imported application files, original tests, and vendored test libraries were
retrieved from `identity-md-launches/launch-1811-build-technical-foundation-hooks`
at commit `46e17ea70534e8a7ac2c4ff78501a3c183d32da8`. No moving branch, submodule,
package download, or online dependency is required to build this deliverable.

The unchanged audited application files have these SHA-256 hashes:

| File | SHA-256 |
| --- | --- |
| `src/store/HookListingRegistry.sol` | `b868400163017d67a3ab81618bc3e3bb5acf939098a90e769486e6ec5d4f4052` |
| `src/store/StoreAdmin.sol` | `20714eb0b2a724ca8bcb9cc3581e4451f3d59e3414a559deb736f3cfacb76337` |
| `src/store/ExactStoreToken.sol` | `b745c4cee9e13edd71cd8290f52720197cf58da07bc7a5db9021d610719bf387` |

These three files are excluded from automatic formatting to preserve their exact
source. Production contracts import only local store files; all library helpers
are internal and leave no deployment link references.

`FeaturedPlacements.sol` becomes `src/store/FeaturedPlacementsV2.sol`. Its changes
are the new name, 24-hour duration, deposited-balance boosts, boost-aware closure
accounting, rank totals, featured-page totals, corresponding NatSpec, and `#ad`
labels on all placement lifecycle events. Price, purchase terms, refund rounding,
registry behavior, owner powers, token configuration, deposits, withdrawals,
recipient pinning, and exact-transfer helpers retain the original behavior.

The original six store test files are retained: `HookListingRegistry.t.sol`,
`FeaturedPlacements.t.sol`, `FeaturedAdversarial.t.sol`, `FeaturedInvariant.t.sol`,
`FeaturedTransfer.t.sol`, and `FeaturedTransferInvariant.t.sol`. They use the V2
name and ABI. The fixture duration is 24 hours; two tests that previously acted
after one day now act at half-duration to preserve their original pre-expiry
scenario. The invariant handlers now generate boosts and account for them.
`FeaturedBoost.t.sol` and `StoreDeployment.t.sol` provide additional V2 coverage.

`lib/forge-std/src`, its MIT/Apache licenses, and
`lib/solmate/src/tokens/ERC20.sol` with its AGPL license are ordinary vendored
files copied from that same pinned commit. Solmate's ERC20 is used only by the
original test mock, never by the application contracts. `lib/SHA256SUMS` covers
the vendored subset. The application license is the upstream MIT `LICENSE`.
