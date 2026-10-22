// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StoreFixture, FeaturedPlacementsV2, HookListingRegistry} from "./helpers/StoreFixture.sol";

contract FeaturedBoostTest is StoreFixture {
    function testThirdPartyBoostUsesOnlyTheirDepositAndKeepsTermsPinned() public {
        (uint256 id, uint256 listingId) = _fundedAd();
        _deposit(bob, 3 * PRICE);
        uint256 custody = token.balanceOf(address(ads));
        vm.warp(START + 1 hours);
        vm.expectEmit(true, true, false, true, address(ads));
        emit FeaturedPlacementsV2.PlacementBoosted(id, bob, PRICE, 2 * PRICE, bytes3("#ad"));
        vm.prank(bob);
        ads.boost(id, PRICE);
        vm.prank(bob);
        ads.boost(id, PRICE / 2);

        assertEq(ads.available(bob), 3 * PRICE / 2);
        assertEq(ads.available(alice), 0);
        assertEq(ads.totalBoost(id), 3 * PRICE / 2);
        assertEq(ads.rankOf(id), 5 * PRICE / 2);
        assertEq(ads.totalEscrowed(), 5 * PRICE / 2);
        assertEq(ads.totalProceeds(), 0);
        assertEq(token.balanceOf(address(ads)), custody);
        FeaturedPlacementsV2.Placement memory item = ads.getPlacement(id);
        assertEq(item.payer, alice);
        assertEq(item.recipient, treasury);
        assertEq(item.revision, 1);
        assertEq(item.startsAt, START);
        assertEq(item.endsAt, START + DURATION);
        assertEq(item.label, bytes3("#ad"));
        assertEq(ads.latestPlacement(listingId), id);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacementsV2.NotPayer.selector);
        ads.cancel(id);
        _assertSolvent();
    }

    function testImmediateCancelRefundsOnlyBaseAndForfeitsAllBoosts() public {
        (uint256 id,) = _fundedAd();
        _deposit(bob, PRICE);
        _deposit(alice, PRICE / 2);
        vm.prank(bob);
        ads.boost(id, PRICE);
        vm.prank(alice);
        ads.boost(id, PRICE / 2);
        vm.expectEmit(true, false, false, true, address(ads));
        emit FeaturedPlacementsV2.PlacementCancelled(id, PRICE, 3 * PRICE / 2, bytes3("#ad"));
        vm.prank(alice);
        assertEq(ads.cancel(id), PRICE);
        assertEq(ads.getPlacement(id).refund, PRICE);
        assertEq(ads.available(alice), PRICE);
        assertEq(ads.available(bob), 0);
        assertEq(ads.totalEscrowed(), 0);
        assertEq(ads.proceeds(treasury), 3 * PRICE / 2);
        assertEq(ads.rankOf(id), 5 * PRICE / 2);
        assertEq(ads.totalBoost(id), 3 * PRICE / 2);
        assertEq(token.balanceOf(treasury), 0);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.withdraw(1, bob);
        vm.prank(treasury);
        ads.withdrawProceeds(3 * PRICE / 2, treasury);
        vm.prank(alice);
        ads.withdraw(PRICE, alice);
        assertEq(ads.accountedBalance(), 0);
        _assertSolvent();
    }

    function testFuzzCancelBoostsPreservesOriginalRoundingAndConservation(uint256 elapsed, uint128 amount) public {
        elapsed = bound(elapsed, 0, DURATION - 1);
        uint256 boosted = bound(uint256(amount), 1, type(uint128).max);
        (uint256 id,) = _fundedAd();
        _deposit(bob, boosted);
        vm.prank(bob);
        ads.boost(id, boosted);
        vm.warp(START + elapsed);
        vm.prank(alice);
        uint256 refund = ads.cancel(id);
        uint256 baseEarned = PRICE * elapsed / DURATION;
        assertEq(refund, PRICE - baseEarned);
        assertEq(ads.proceeds(treasury), baseEarned + boosted);
        assertEq(ads.totalAvailable(), refund);
        assertEq(ads.available(bob), 0);
        assertEq(ads.totalEscrowed(), 0);
        assertEq(refund + ads.proceeds(treasury), PRICE + boosted);
        assertGe(refund * DURATION, PRICE * (DURATION - elapsed));
        assertLt(refund * DURATION - PRICE * (DURATION - elapsed), DURATION);
        _assertSolvent();
        vm.prank(treasury);
        ads.withdrawProceeds(baseEarned + boosted, treasury);
        vm.prank(alice);
        ads.withdraw(refund, alice);
        assertEq(ads.accountedBalance(), 0);
        _assertSolvent();
    }

    function testFuzzExpirySettlesBaseAndBoostToPinnedRecipient(uint128 amount) public {
        uint256 boosted = bound(uint256(amount), 1, type(uint128).max);
        (uint256 id,) = _fundedAd();
        ads.setProceedsRecipient(nextTreasury);
        _deposit(bob, boosted);
        vm.prank(bob);
        ads.boost(id, boosted);
        vm.warp(START + DURATION);
        vm.expectEmit(true, true, false, true, address(ads));
        emit FeaturedPlacementsV2.PlacementSettled(id, treasury, PRICE + boosted, bytes3("#ad"));
        vm.prank(bob);
        ads.settle(id);
        assertEq(ads.proceeds(treasury), PRICE + boosted);
        assertEq(ads.proceeds(nextTreasury), 0);
        assertEq(ads.available(alice), 0);
        assertEq(ads.available(bob), 0);
        assertEq(ads.totalEscrowed(), 0);
        assertEq(ads.getPlacement(id).refund, 0);
        assertEq(ads.rankOf(id), PRICE + boosted);
        vm.prank(treasury);
        ads.withdrawProceeds(PRICE + boosted, treasury);
        assertEq(ads.accountedBalance(), 0);
        _assertSolvent();
    }

    function testNewListingOwnerCancellationDoesNotRefundBoosterOrRedirectProceeds() public {
        (uint256 id, uint256 listingId) = _fundedAd();
        _deposit(bob, PRICE);
        vm.prank(bob);
        ads.boost(id, PRICE);
        vm.prank(alice);
        registry.proposeListingOwner(listingId, bob);
        vm.prank(bob);
        registry.acceptListingOwnership(listingId);
        ads.setProceedsRecipient(nextTreasury);
        vm.warp(START + DURATION / 2);
        vm.prank(bob);
        ads.cancel(id);
        assertEq(ads.available(alice), PRICE / 2);
        assertEq(ads.available(bob), 0);
        assertEq(ads.proceeds(treasury), 3 * PRICE / 2);
        assertEq(ads.proceeds(nextTreasury), 0);
        _assertSolvent();
    }

    function testBoostCannotSpendWalletApprovalAnotherDepositOrProceeds() public {
        (uint256 id,) = _fundedAd();
        _deposit(alice, PRICE);
        token.mint(bob, PRICE);
        vm.startPrank(bob);
        token.approve(address(ads), PRICE);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.boost(id, PRICE);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), PRICE);
        assertEq(ads.available(alice), PRICE);
        assertEq(ads.totalBoost(id), 0);
        vm.warp(START + DURATION);
        ads.settle(id);
        uint256 nextId = _purchase(alice, ads.getPlacement(id).listingId);
        vm.prank(treasury);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.boost(nextId, PRICE);
        assertEq(ads.proceeds(treasury), PRICE);
        _assertSolvent();
    }

    function testInvalidBoostAmountsAndIdsRevertWithoutDebiting() public {
        (uint256 id,) = _fundedAd();
        _deposit(bob, PRICE);
        vm.startPrank(bob);
        vm.expectRevert(FeaturedPlacementsV2.UnknownPlacement.selector);
        ads.boost(0, 1);
        vm.expectRevert(FeaturedPlacementsV2.UnknownPlacement.selector);
        ads.boost(id + 1, 1);
        vm.expectRevert(FeaturedPlacementsV2.InvalidAmount.selector);
        ads.boost(id, 0);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.boost(id, PRICE + 1);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.boost(id, type(uint256).max);
        vm.stopPrank();
        vm.expectRevert(FeaturedPlacementsV2.UnknownPlacement.selector);
        ads.rankOf(0);
        vm.expectRevert(FeaturedPlacementsV2.UnknownPlacement.selector);
        ads.rankOf(id + 1);
        assertEq(ads.available(bob), PRICE);
        assertEq(ads.totalBoost(id), 0);
        assertEq(ads.rankOf(id), PRICE);
        _assertSolvent();
    }

    function testBoostBoundaryAndClosedPlacements() public {
        (uint256 id,) = _fundedAd();
        _deposit(bob, PRICE);
        vm.warp(START + DURATION - 1);
        vm.prank(bob);
        ads.boost(id, 1);
        vm.warp(START + DURATION);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacementsV2.PlacementExpired.selector);
        ads.boost(id, 1);
        ads.settle(id);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacementsV2.PlacementClosed.selector);
        ads.boost(id, 1);

        _deposit(alice, PRICE);
        uint256 cancelled = _purchase(alice, ads.getPlacement(id).listingId);
        vm.prank(alice);
        ads.cancel(cancelled);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacementsV2.PlacementClosed.selector);
        ads.boost(cancelled, 1);
        assertEq(ads.available(bob), PRICE - 1);
        assertEq(ads.totalBoost(id), 1);
        assertEq(ads.totalBoost(cancelled), 0);
        _assertSolvent();
    }

    function testBoostSurvivesArchivingAndDoesNotChangePinnedMetadata() public {
        (uint256 id, uint256 listingId) = _fundedAd();
        HookListingRegistry.Metadata memory data = _metadata();
        data.name = "Updated listing";
        vm.startPrank(alice);
        registry.updateListing(listingId, data);
        registry.setListingActive(listingId, false);
        vm.stopPrank();
        _deposit(bob, PRICE);
        vm.prank(bob);
        ads.boost(id, PRICE);
        assertEq(ads.getPlacement(id).revision, 1);
        assertTrue(ads.isActive(id));
        assertEq(ads.rankOf(id), 2 * PRICE);
        _assertSolvent();
    }

    function testRankingTiesUseLowerIdAcrossPagesAndTotalsAlignAfterFiltering() public {
        (uint256 first,) = _fundedAd();
        uint256 bobListing = _create(bob);
        _deposit(bob, 4 * PRICE);
        uint256 second = _purchase(bob, bobListing);
        vm.startPrank(bob);
        ads.boost(second, PRICE);
        ads.boost(first, PRICE);
        vm.stopPrank();
        assertEq(ads.rankOf(first), ads.rankOf(second));
        (FeaturedPlacementsV2.Placement[] memory page, uint256[] memory totals, uint256 next) = ads.featured(1, 1);
        assertEq(page.length, 1);
        assertEq(totals.length, 1);
        assertEq(page[0].id, first);
        assertEq(totals[0], 2 * PRICE);
        (page, totals, next) = ads.featured(next, 1);
        assertEq(page[0].id, second);
        assertEq(totals[0], 2 * PRICE);
        assertEq(next, 3);

        vm.prank(bob);
        ads.boost(second, 1);
        (page, totals, next) = ads.featured(1, 100);
        assertEq(page[0].id, first);
        assertEq(page[1].id, second);
        assertEq(totals[0], 2 * PRICE);
        assertEq(totals[1], 2 * PRICE + 1);
        // The higher-ID ad now ranks first by total; scanning itself remains ascending.
        assertGt(totals[1], totals[0]);

        vm.prank(alice);
        ads.cancel(first);
        (page, totals, next) = ads.featured(1, 1);
        assertEq(page.length, 0);
        assertEq(totals.length, 0);
        assertEq(next, 2);
        (page, totals, next) = ads.featured(1, 100);
        assertEq(page.length, 1);
        assertEq(totals.length, 1);
        assertEq(page[0].id, second);
        assertEq(totals[0], 2 * PRICE + 1);
        vm.warp(START + DURATION);
        (page, totals, next) = ads.featured(1, 100);
        assertEq(page.length, 0);
        assertEq(totals.length, 0);
        assertEq(next, 3);
        _assertSolvent();
    }

    function testExpiredBoostedPlacementCanBeRenewedBeforeSettlementWithoutAffectingNewOne() public {
        (uint256 oldId, uint256 listingId) = _fundedAd();
        _deposit(bob, 2 * PRICE);
        _deposit(alice, PRICE);
        vm.prank(bob);
        ads.boost(oldId, PRICE);
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.AlreadyFeatured.selector);
        ads.purchase(listingId, 1, treasury, START);
        vm.warp(START + DURATION);
        uint256 newId = _purchase(alice, listingId);
        vm.prank(bob);
        ads.boost(newId, PRICE / 2);
        assertEq(ads.totalEscrowed(), 7 * PRICE / 2);
        ads.settle(oldId);
        assertEq(ads.totalEscrowed(), 3 * PRICE / 2);
        assertEq(ads.proceeds(treasury), 2 * PRICE);
        assertEq(ads.latestPlacement(listingId), newId);
        assertEq(ads.rankOf(newId), 3 * PRICE / 2);
        assertTrue(ads.isActive(newId));
        _assertSolvent();
    }

    function testPurchaseEventRetainsAdLabelAndOriginalPrice() public {
        uint256 listingId = _create(alice);
        _deposit(alice, PRICE);
        vm.expectEmit(true, true, true, true, address(ads));
        emit FeaturedPlacementsV2.PlacementPurchased(
            1, listingId, alice, 1, treasury, START, START + DURATION, PRICE, bytes3("#ad")
        );
        _purchase(alice, listingId);
    }
}
