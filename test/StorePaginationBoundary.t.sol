// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StoreFixture, FeaturedPlacementsV2, HookListingRegistry} from "./helpers/StoreFixture.sol";

contract StorePaginationBoundaryTest is StoreFixture {
    function testSparsePagesAcrossMaxScanKeepIdsTotalsAndHistoricalRevisionsAligned() public {
        HookListingRegistry.Metadata memory data;
        data.name = "Pagination fixture";
        data.callbackDisclosure = "none";
        data.feeDisclosure = "none";
        data.adminDisclosure = "none";
        data.labels = new string[](1);
        data.labels[0] = "page";
        _deposit(alice, 105 * PRICE);
        _deposit(bob, 7);
        for (uint256 i = 1; i <= 105; ++i) {
            if (i == 101) vm.warp(START + DURATION / 2);
            // Separate test identities on different chain IDs; no chain RPC or deployed hook is needed.
            vm.prank(alice);
            uint256 listing = registry.createListing(i, hook, data);
            assertEq(_purchase(alice, listing), i);
        }
        vm.startPrank(bob);
        ads.boost(100, 2);
        ads.boost(101, 2);
        ads.boost(105, 3);
        vm.stopPrank();
        vm.startPrank(alice);
        ads.cancel(99);
        ads.cancel(102);
        registry.setListingActive(103, false);
        data.name = "Edited after purchase";
        registry.updateListing(104, data);
        vm.stopPrank();

        (FeaturedPlacementsV2.Placement[] memory page, uint256[] memory totals, uint256 next) = ads.featured(1, 100);
        assertEq(next, 101);
        assertEq(page.length, 99);
        assertEq(totals.length, 99);
        for (uint256 i; i < page.length; ++i) {
            uint256 expectedId = i < 98 ? i + 1 : 100;
            assertEq(page[i].id, expectedId);
            assertEq(page[i].label, bytes3("#ad"));
            assertEq(totals[i], PRICE + (expectedId == 100 ? 2 : 0));
        }
        (page, totals, next) = ads.featured(100, 2);
        assertEq(next, 102);
        assertEq(page.length, 2);
        assertEq(page[0].id, 100);
        assertEq(page[1].id, 101);
        assertEq(totals[0], totals[1], "equal rank straddles the MAX_SCAN boundary");
        assertEq(totals[0], PRICE + 2);

        (page, totals, next) = ads.featured(101, 100);
        assertEq(next, 106);
        assertEq(page.length, 4);
        assertEq(totals.length, 4);
        uint256[4] memory expected = [uint256(101), 103, 104, 105];
        for (uint256 i; i < 4; ++i) {
            assertEq(page[i].id, expected[i]);
            assertEq(page[i].revision, 1);
            assertEq(page[i].label, bytes3("#ad"));
            assertEq(abi.encode(page[i]), abi.encode(ads.getPlacement(expected[i])));
            assertEq(totals[i], PRICE + (expected[i] == 101 ? 2 : expected[i] == 105 ? 3 : 0));
        }
        assertEq(registry.getMetadata(104, page[2].revision).name, "Pagination fixture");
        assertEq(registry.getMetadata(104, 2).name, "Edited after purchase");

        // Every early placement expires together, without a keeper having to close it.
        vm.warp(START + DURATION);
        uint256 escrowBefore = ads.totalEscrowed();
        (page, totals, next) = ads.featured(1, 100);
        assertEq(page.length, 0);
        assertEq(totals.length, 0);
        assertEq(next, 101, "an empty page must not signal end of history");
        (page, totals, next) = ads.featured(next, 100);
        assertEq(page.length, 4);
        assertEq(next, 106);
        assertEq(page[0].id, 101);
        assertEq(totals[0], PRICE + 2);
        assertEq(ads.totalEscrowed(), escrowBefore, "expiry alone does not move escrow");

        (page, totals, next) = ads.featured(next, 100);
        assertEq(next, 106);
        assertEq(page.length, 0);
        assertEq(totals.length, 0);
        vm.expectRevert(FeaturedPlacementsV2.InvalidPage.selector);
        ads.featured(107, 100);
        vm.expectRevert(FeaturedPlacementsV2.InvalidPage.selector);
        ads.featured(1, 101);

        (uint256[] memory ids, uint256 cursor) = registry.search(1, 100, 101, alice, keccak256("page"));
        assertEq(ids.length, 0);
        assertEq(cursor, 101);
        (ids, cursor) = registry.search(cursor, 100, 101, alice, keccak256("page"));
        assertEq(ids.length, 1);
        assertEq(ids[0], 101);
        assertEq(cursor, 106);
        (ids, cursor) = registry.search(101, 100, 0, alice, keccak256("page"));
        assertEq(ids.length, 4);
        assertEq(ids[0], 101);
        assertEq(ids[1], 102, "cancelled ads do not hide organic listings");
        assertEq(ids[2], 104);
        assertEq(ids[3], 105);
        assertEq(cursor, 106);
        (ids, cursor) = registry.search(cursor, 100, 0, address(0), bytes32(0));
        assertEq(ids.length, 0);
        assertEq(cursor, 106);
        vm.expectRevert(HookListingRegistry.InvalidPage.selector);
        registry.search(107, 100, 0, address(0), bytes32(0));
        _assertSolvent();
    }
}
