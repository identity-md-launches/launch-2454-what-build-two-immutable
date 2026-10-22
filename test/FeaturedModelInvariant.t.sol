// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StoreFixture, FeaturedPlacementsV2, HookListingRegistry, TestToken} from "./helpers/StoreFixture.sol";

/// @dev Expected balances come from inputs and a separate ledger, never from the escrow's getters.
/// All four actors can be payers, boosters, listing owners, recipients and withdrawal destinations.
contract FeaturedModelHandler is Test {
    uint256 internal constant PRICE = 0.1 ether;
    uint256 internal constant DURATION = 24 hours;
    uint256 internal constant INITIAL_WALLET = 100 * PRICE;

    struct Ad {
        uint256 listingId;
        address payer;
        address recipient;
        uint256 start;
        uint256 boost;
        uint256 refund;
        uint256 closedAt;
        FeaturedPlacementsV2.Status status;
    }

    FeaturedPlacementsV2 public immutable ads;
    HookListingRegistry public immutable registry;
    TestToken public immutable token;
    address[4] public actors;
    address[4] public listingOwners;
    bool[4] public visible;
    uint256[4] public latest;
    address public recipient;
    mapping(address => uint256) public credit;
    mapping(address => uint256) public earned;
    mapping(address => uint256) public wallet;
    mapping(uint256 => Ad) internal records;
    uint256 public count;
    uint256 public donations;
    uint256 public deposited;
    uint256 public paidOut;
    uint256 public boosts;
    uint256 public cancellations;
    uint256 public settlements;
    uint256 public rejectedCalls;

    constructor(FeaturedPlacementsV2 ads_, TestToken token_, address[4] memory actors_) {
        ads = ads_;
        registry = ads_.registry();
        token = token_;
        actors = actors_;
        recipient = actors_[0];
        for (uint256 i; i < 4; ++i) {
            listingOwners[i] = actors_[i];
            visible[i] = true;
            wallet[actors_[i]] = INITIAL_WALLET;
        }
    }

    function deposit(uint256 actorSeed, uint256 amount) public {
        address actor = actors[actorSeed % 4];
        if (wallet[actor] == 0) return;
        amount = bound(amount, 1, wallet[actor]);
        vm.prank(actor);
        ads.deposit(amount);
        wallet[actor] -= amount;
        credit[actor] += amount;
        deposited += amount;
    }

    function donate(uint256 actorSeed, uint256 amount) public {
        address actor = actors[actorSeed % 4];
        if (wallet[actor] == 0) return;
        amount = bound(amount, 1, wallet[actor]);
        vm.prank(actor);
        token.transfer(address(ads), amount);
        wallet[actor] -= amount;
        donations += amount;
    }

    function withdraw(uint256 actorSeed, uint256 toSeed, uint256 amount, bool proceedsOnly) public {
        address actor = actors[actorSeed % 4];
        address to = actors[toSeed % 4];
        uint256 balance = proceedsOnly ? earned[actor] : credit[actor];
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(actor);
        if (proceedsOnly) {
            ads.withdrawProceeds(amount, to);
            earned[actor] -= amount;
        } else {
            ads.withdraw(amount, to);
            credit[actor] -= amount;
        }
        wallet[to] += amount;
        paidOut += amount;
    }

    function purchase(uint256 listingSeed) public {
        uint256 index = listingSeed % 4;
        address payer = listingOwners[index];
        if (count >= 40 || !visible[index] || credit[payer] < PRICE || _live(latest[index])) return;
        uint256 now_ = vm.getBlockTimestamp();
        vm.prank(payer);
        uint256 id = ads.purchase(index + 1, 1, recipient, now_);
        assertEq(id, count + 1, "purchase IDs must not skip or reuse history");
        ++count;
        records[id] = Ad(index + 1, payer, recipient, now_, 0, 0, 0, FeaturedPlacementsV2.Status.Open);
        latest[index] = id;
        credit[payer] -= PRICE;
    }

    function boost(uint256 actorSeed, uint256 idSeed, uint256 amount) public {
        if (count == 0) return;
        uint256 id = 1 + idSeed % count;
        address actor = actors[actorSeed % 4];
        if (!_live(id) || credit[actor] == 0) return;
        amount = bound(amount, 1, credit[actor]);
        vm.prank(actor);
        ads.boost(id, amount);
        credit[actor] -= amount;
        records[id].boost += amount;
        boosts += amount;
    }

    function close(uint256 idSeed, bool asCurrentOwner, uint256 callerSeed) public {
        if (count == 0) return;
        uint256 id = 1 + idSeed % count;
        Ad storage ad = records[id];
        if (ad.status != FeaturedPlacementsV2.Status.Open) return;
        uint256 now_ = vm.getBlockTimestamp();
        uint256 refund;
        if (now_ < ad.start + DURATION) {
            // Independent rounding oracle: refund is ceil(price * remaining / duration).
            uint256 remaining = ad.start + DURATION - now_;
            refund = (PRICE * remaining + DURATION - 1) / DURATION;
            address caller = asCurrentOwner ? listingOwners[ad.listingId - 1] : ad.payer;
            vm.prank(caller);
            assertEq(ads.cancel(id), refund, "base-only pro-rata refund");
            ad.status = FeaturedPlacementsV2.Status.Cancelled;
            credit[ad.payer] += refund;
            ++cancellations;
        } else {
            vm.prank(actors[callerSeed % 4]);
            ads.settle(id);
            ad.status = FeaturedPlacementsV2.Status.Settled;
            ++settlements;
        }
        ad.refund = refund;
        ad.closedAt = now_;
        earned[ad.recipient] += PRICE + ad.boost - refund;
    }

    function advanceTime(uint256 delta) public {
        vm.warp(vm.getBlockTimestamp() + bound(delta, 0, DURATION));
    }

    function rotateRecipient(uint256 actorSeed) public {
        recipient = actors[actorSeed % 4];
        ads.setProceedsRecipient(recipient);
    }

    function transferListing(uint256 listingSeed, uint256 actorSeed) public {
        uint256 index = listingSeed % 4;
        address next = actors[actorSeed % 4];
        vm.prank(listingOwners[index]);
        registry.proposeListingOwner(index + 1, next);
        vm.prank(next);
        registry.acceptListingOwnership(index + 1);
        listingOwners[index] = next;
    }

    function toggleListing(uint256 listingSeed, bool active) public {
        uint256 index = listingSeed % 4;
        vm.prank(listingOwners[index]);
        registry.setListingActive(index + 1, active);
        visible[index] = active;
    }

    /// @dev Failures are expected explicitly; any unexpected revert fails the invariant campaign.
    function rejectOverspend(uint256 actorSeed, bool proceedsOnly) public {
        address actor = actors[actorSeed % 4];
        uint256 amount = (proceedsOnly ? earned[actor] : credit[actor]) + 1;
        vm.prank(actor);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        if (proceedsOnly) ads.withdrawProceeds(amount, actor);
        else ads.withdraw(amount, actor);
        ++rejectedCalls;
    }

    function rejectPlacementAction(uint256 idSeed, uint256 actorSeed) public {
        if (count == 0) return;
        uint256 id = 1 + idSeed % count;
        Ad memory ad = records[id];
        if (ad.status != FeaturedPlacementsV2.Status.Open) {
            vm.prank(actors[actorSeed % 4]);
            vm.expectRevert(FeaturedPlacementsV2.PlacementClosed.selector);
            ads.boost(id, 1);
            vm.expectRevert(FeaturedPlacementsV2.PlacementClosed.selector);
            ads.settle(id);
        } else if (!_live(id)) {
            vm.prank(ad.payer);
            vm.expectRevert(FeaturedPlacementsV2.PlacementExpired.selector);
            ads.cancel(id);
            vm.prank(actors[actorSeed % 4]);
            vm.expectRevert(FeaturedPlacementsV2.PlacementExpired.selector);
            ads.boost(id, 1);
        } else {
            address stranger = actors[actorSeed % 4];
            for (uint256 i; stranger == ad.payer || stranger == listingOwners[ad.listingId - 1]; ++i) {
                stranger = actors[i % 4];
            }
            vm.prank(stranger);
            vm.expectRevert(FeaturedPlacementsV2.NotPayer.selector);
            ads.cancel(id);
            vm.expectRevert(FeaturedPlacementsV2.PlacementNotExpired.selector);
            ads.settle(id);
        }
        ++rejectedCalls;
    }

    function _live(uint256 id) internal view returns (bool) {
        return
            records[id].status == FeaturedPlacementsV2.Status.Open
                && vm.getBlockTimestamp() < records[id].start + DURATION;
    }

    function assertModel() public view {
        uint256 availableSum;
        uint256 proceedsSum;
        uint256 walletSum;
        for (uint256 i; i < 4; ++i) {
            address actor = actors[i];
            assertEq(ads.available(actor), credit[actor], "credit belongs to the correct depositor/payer");
            assertEq(ads.proceeds(actor), earned[actor], "proceeds belong to the pinned recipient");
            assertEq(token.balanceOf(actor), wallet[actor], "exact withdrawal destination and amount");
            availableSum += credit[actor];
            proceedsSum += earned[actor];
            walletSum += wallet[actor];
            HookListingRegistry.Listing memory listing = registry.getListing(i + 1);
            assertEq(listing.owner, listingOwners[i]);
            assertEq(listing.active, visible[i]);
            assertEq(ads.latestPlacement(i + 1), latest[i]);
        }
        uint256 escrowSum;
        uint256 boostSum;
        for (uint256 id = 1; id <= count; ++id) {
            Ad memory expected = records[id];
            FeaturedPlacementsV2.Placement memory actual = ads.getPlacement(id);
            assertEq(actual.id, id);
            assertEq(actual.listingId, expected.listingId);
            assertEq(actual.payer, expected.payer);
            assertEq(actual.recipient, expected.recipient);
            assertEq(actual.revision, 1);
            assertEq(actual.startsAt, expected.start);
            assertEq(actual.endsAt, expected.start + DURATION);
            assertEq(actual.closedAt, expected.closedAt);
            assertEq(actual.refund, expected.refund);
            assertEq(uint256(actual.status), uint256(expected.status), "closed placements never reopen");
            assertEq(actual.label, bytes3("#ad"));
            assertEq(ads.totalBoost(id), expected.boost);
            assertEq(ads.rankOf(id), PRICE + expected.boost);
            assertEq(ads.isActive(id), _live(id));
            if (expected.status == FeaturedPlacementsV2.Status.Open) escrowSum += PRICE + expected.boost;
            boostSum += expected.boost;
        }
        assertEq(ads.placementCount(), count);
        assertEq(ads.totalAvailable(), availableSum);
        assertEq(ads.totalProceeds(), proceedsSum);
        assertEq(ads.totalEscrowed(), escrowSum, "expired but unclosed ads still owe all escrow");
        assertEq(ads.accountedBalance(), availableSum + proceedsSum + escrowSum);
        assertEq(ads.accountedBalance(), deposited - paidOut);
        assertEq(token.balanceOf(address(ads)), ads.accountedBalance() + donations);
        assertEq(token.balanceOf(address(ads)) + walletSum, 4 * INITIAL_WALLET);
        assertEq(token.totalSupply(), 4 * INITIAL_WALLET);
        assertEq(boostSum, boosts);
        assertEq(ads.proceedsRecipient(), recipient);
        assertEq(ads.owner(), address(this));
        assertEq(ads.imd(), address(token));
    }

    function assertPages() public view {
        // Short pages deliberately cross runs of cancelled, expired and settled records.
        uint256 cursor = 1;
        while (cursor <= count) {
            (FeaturedPlacementsV2.Placement[] memory page, uint256[] memory totals, uint256 next) =
                ads.featured(cursor, 3);
            uint256 end = cursor + 3 <= count + 1 ? cursor + 3 : count + 1;
            assertEq(next, end);
            uint256 found;
            for (uint256 id = cursor; id < end; ++id) {
                if (!_live(id)) continue;
                assertLt(found, page.length, "missing live placement");
                assertEq(page[found].id, id, "stable lower-ID tie break");
                assertEq(totals[found], PRICE + records[id].boost, "totals follow filtered placement IDs");
                assertEq(abi.encode(page[found]), abi.encode(ads.getPlacement(id)));
                ++found;
            }
            assertEq(page.length, found, "no closed ads or duplicates");
            assertEq(totals.length, found);
            cursor = next;
        }
    }

    function windDown() public {
        vm.warp(vm.getBlockTimestamp() + DURATION);
        for (uint256 id = 1; id <= count; ++id) {
            close(id - 1, false, id);
        }
        for (uint256 i; i < 4; ++i) {
            withdraw(i, (i + 1) % 4, credit[actors[i]], false);
            withdraw(i, (i + 1) % 4, earned[actors[i]], true);
        }
        assertModel();
        assertEq(ads.accountedBalance(), 0, "every liability remains withdrawable");
        assertEq(token.balanceOf(address(ads)), donations, "unsolicited funds never become spendable credit");
    }
}

contract FeaturedModelInvariantTest is StoreFixture {
    FeaturedModelHandler internal model;

    function setUp() public override {
        super.setUp();
        address[4] memory actors = [alice, bob, treasury, nextTreasury];
        for (uint256 i; i < 4; ++i) {
            vm.prank(actors[i]);
            registry.createListing(i + 1, hook, _metadata());
            token.mint(actors[i], 100 * PRICE);
            vm.prank(actors[i]);
            token.approve(address(ads), type(uint256).max);
        }
        ads.setProceedsRecipient(alice);
        model = new FeaturedModelHandler(ads, token, actors);
        ads.transferOwnership(address(model));
        vm.prank(address(model));
        ads.acceptOwnership();

        // Seed both closure paths, third-party boosts, role overlap and a direct donation on every run.
        for (uint256 i; i < 4; ++i) {
            model.deposit(i, 20 * PRICE);
        }
        model.purchase(0);
        model.purchase(1);
        model.boost(2, 0, PRICE);
        model.boost(3, 1, 2 * PRICE);
        model.advanceTime(1);
        model.transferListing(0, 2);
        model.close(0, true, 0);
        model.advanceTime(DURATION);
        model.close(1, false, 3);
        model.rotateRecipient(1);
        model.purchase(2);
        model.boost(0, 2, 1);
        model.donate(3, 1);
        model.rejectOverspend(0, false);
        model.rejectPlacementAction(2, 3);
        model.assertModel();

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = model.deposit.selector;
        selectors[1] = model.donate.selector;
        selectors[2] = model.withdraw.selector;
        selectors[3] = model.purchase.selector;
        selectors[4] = model.boost.selector;
        selectors[5] = model.close.selector;
        selectors[6] = model.advanceTime.selector;
        selectors[7] = model.rotateRecipient.selector;
        selectors[8] = model.transferListing.selector;
        selectors[9] = model.toggleListing.selector;
        selectors[10] = model.rejectOverspend.selector;
        selectors[11] = model.rejectPlacementAction.selector;
        targetSelector(FuzzSelector(address(model), selectors));
        targetContract(address(model));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariantIndividualEntitlementsAndPlacementHistoryMatchIndependentLedger() public view {
        model.assertModel();
        model.assertPages();
        assertGt(model.boosts(), 0);
        assertGt(model.cancellations(), 0);
        assertGt(model.settlements(), 0);
        assertGt(model.rejectedCalls(), 0);
    }

    function afterInvariant() public {
        model.windDown();
    }
}
