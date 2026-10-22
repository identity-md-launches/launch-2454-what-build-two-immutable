// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StoreFixture, FeaturedPlacementsV2} from "./helpers/StoreFixture.sol";
import {StoreTokenMock} from "./helpers/StoreTokenMock.sol";
import {IStoreToken, ExactStoreToken} from "../src/store/ExactStoreToken.sol";
import {StoreAdmin} from "../src/store/StoreAdmin.sol";

contract FeaturedTokenBoundaryTest is StoreFixture {
    function testMalformedDecimalsCannotConsumeOneTimeConfiguration() public {
        FeaturedPlacementsV2 fresh = new FeaturedPlacementsV2(alice, registry);
        bytes[] memory replies = new bytes[](8);
        replies[0] = hex"";
        replies[1] = hex"12";
        replies[2] = new bytes(31);
        replies[3] = abi.encodePacked(uint256(18), bytes1(0));
        replies[4] = abi.encode(uint256(18), uint256(0));
        replies[5] = abi.encode(uint256(17));
        replies[6] = abi.encode(uint256(19));
        replies[7] = abi.encode(type(uint256).max);
        for (uint256 i; i < replies.length; ++i) {
            vm.mockCall(address(token), abi.encodeCall(IStoreToken.decimals, ()), replies[i]);
            vm.prank(alice);
            vm.expectRevert(FeaturedPlacementsV2.InvalidToken.selector);
            fresh.configureToken(address(token));
            assertEq(fresh.imd(), address(0));
        }
        vm.mockCallRevert(address(token), abi.encodeCall(IStoreToken.decimals, ()), hex"1234");
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.InvalidToken.selector);
        fresh.configureToken(address(token));
        vm.clearMockedCalls();
        vm.prank(alice);
        fresh.configureToken(address(token));
        assertEq(fresh.imd(), address(token));
    }

    function testMalformedBalanceAbiCannotConsumeOneTimeConfiguration() public {
        FeaturedPlacementsV2 fresh = new FeaturedPlacementsV2(alice, registry);
        uint256[5] memory lengths = [uint256(0), 1, 31, 33, 64];
        bytes memory callData = abi.encodeCall(IStoreToken.balanceOf, (address(fresh)));
        for (uint256 i; i < lengths.length; ++i) {
            vm.mockCall(address(token), callData, new bytes(lengths[i]));
            vm.prank(alice);
            vm.expectRevert(ExactStoreToken.TokenCallFailed.selector);
            fresh.configureToken(address(token));
            assertEq(fresh.imd(), address(0));
        }
        vm.mockCallRevert(address(token), callData, hex"1234");
        vm.prank(alice);
        vm.expectRevert(ExactStoreToken.TokenCallFailed.selector);
        fresh.configureToken(address(token));
        vm.clearMockedCalls();
        vm.prank(alice);
        fresh.configureToken(address(token));
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.TokenAlreadyConfigured.selector);
        fresh.configureToken(address(token));
    }

    function testPendingAndReplacedOwnersCannotConfigureOrRedirect() public {
        FeaturedPlacementsV2 fresh = new FeaturedPlacementsV2(alice, registry);
        vm.prank(alice);
        fresh.transferOwnership(bob);
        _assertNoAdminPowers(fresh, bob);
        vm.prank(alice);
        fresh.transferOwnership(treasury);
        vm.prank(bob);
        vm.expectRevert(StoreAdmin.NotPendingOwner.selector);
        fresh.acceptOwnership();
        vm.prank(treasury);
        fresh.acceptOwnership();
        _assertNoAdminPowers(fresh, alice);
        vm.startPrank(treasury);
        fresh.configureToken(address(token));
        fresh.setProceedsRecipient(treasury);
        vm.expectRevert(StoreAdmin.NotPendingOwner.selector);
        fresh.acceptOwnership();
        vm.expectRevert(StoreAdmin.InvalidAddress.selector);
        fresh.transferOwnership(address(0));
        vm.expectRevert(StoreAdmin.InvalidAddress.selector);
        fresh.transferOwnership(address(fresh));
        vm.stopPrank();
        assertEq(fresh.owner(), treasury);
        assertEq(fresh.pendingOwner(), address(0));
        assertEq(fresh.accountedBalance(), 0);
    }

    function testMissingAllowanceAndBalanceDoNotCreditOrConsumeUserFunds() public {
        token.mint(alice, PRICE);
        vm.prank(alice);
        vm.expectRevert(ExactStoreToken.TokenCallFailed.selector);
        ads.deposit(PRICE);
        vm.startPrank(alice);
        token.approve(address(ads), PRICE - 1);
        vm.expectRevert(ExactStoreToken.TokenCallFailed.selector);
        ads.deposit(PRICE);
        token.approve(address(ads), 2 * PRICE);
        vm.expectRevert(ExactStoreToken.TokenCallFailed.selector);
        ads.deposit(PRICE + 1);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), PRICE);
        assertEq(token.allowance(alice, address(ads)), 2 * PRICE);
        assertEq(ads.available(alice), 0);
        assertEq(ads.accountedBalance(), 0);
        vm.prank(alice);
        ads.deposit(PRICE);
        vm.prank(alice);
        ads.withdraw(PRICE, bob);
        assertEq(token.balanceOf(bob), PRICE);
        _assertSolvent();
    }

    function testMalformedBalanceReadsBlockWithdrawalsAtomicallyAndAllowRetry() public {
        (uint256 id,) = _fundedAd();
        _deposit(alice, PRICE);
        vm.warp(START + DURATION);
        ads.settle(id);
        address[3] memory queried = [address(ads), bob, treasury];
        for (uint256 i; i < queried.length; ++i) {
            vm.mockCall(address(token), abi.encodeCall(IStoreToken.balanceOf, (queried[i])), hex"01");
            address to = queried[i] == address(ads) ? bob : queried[i];
            vm.prank(alice);
            vm.expectRevert(ExactStoreToken.TokenCallFailed.selector);
            ads.withdraw(PRICE, to);
            vm.prank(treasury);
            vm.expectRevert(ExactStoreToken.TokenCallFailed.selector);
            ads.withdrawProceeds(PRICE, to);
            vm.clearMockedCalls();
            assertEq(ads.available(alice), PRICE);
            assertEq(ads.proceeds(treasury), PRICE);
            assertEq(token.balanceOf(address(ads)), 2 * PRICE);
            assertEq(token.balanceOf(bob), 0);
            assertEq(token.balanceOf(treasury), 0);
            _assertSolvent();
        }
        vm.prank(alice);
        ads.withdraw(PRICE, bob);
        vm.prank(treasury);
        ads.withdrawProceeds(PRICE, bob);
        assertEq(token.balanceOf(bob), 2 * PRICE);
        _assertSolvent();
    }

    function testEveryRejectedTokenTransferLeavesBoostedProceedsClaimRetryable() public {
        StoreTokenMock hostile = new StoreTokenMock();
        ads = new FeaturedPlacementsV2(address(this), registry);
        ads.configureToken(address(hostile));
        ads.setProceedsRecipient(treasury);
        uint256 listing = _create(alice);
        hostile.mint(alice, 4 * PRICE);
        vm.startPrank(alice);
        hostile.approve(address(ads), 4 * PRICE);
        ads.deposit(4 * PRICE);
        vm.stopPrank();
        uint256 id = _purchase(alice, listing);
        vm.prank(alice);
        ads.boost(id, 2 * PRICE);
        vm.warp(START + DURATION);
        ads.settle(id);
        for (uint256 mode = 1; mode <= uint256(StoreTokenMock.Mode.NoMovement); ++mode) {
            if (mode == uint256(StoreTokenMock.Mode.NoReturn)) continue;
            hostile.setMode(StoreTokenMock.Mode(mode));
            vm.prank(treasury);
            vm.expectRevert(
                mode >= uint256(StoreTokenMock.Mode.RecipientFee)
                    ? ExactStoreToken.InexactTransfer.selector
                    : ExactStoreToken.TokenCallFailed.selector
            );
            ads.withdrawProceeds(3 * PRICE, bob);
            assertEq(ads.proceeds(treasury), 3 * PRICE);
            assertEq(ads.totalProceeds(), 3 * PRICE);
            assertEq(ads.available(alice), PRICE);
            assertEq(ads.totalAvailable(), PRICE);
            assertEq(ads.accountedBalance(), 4 * PRICE);
            assertEq(hostile.balanceOf(address(ads)), 4 * PRICE);
            assertEq(hostile.balanceOf(bob), 0);
        }
        hostile.setMode(StoreTokenMock.Mode.NoReturn);
        vm.prank(treasury);
        ads.withdrawProceeds(3 * PRICE, bob);
        vm.prank(alice);
        ads.withdraw(PRICE, alice);
        assertEq(hostile.balanceOf(bob), 3 * PRICE);
        assertEq(ads.accountedBalance(), 0);
        assertEq(hostile.balanceOf(address(ads)), 0);
    }

    function testMaximumUint256EscrowCanCancelAndFullyExit() public {
        _fullRangeLifecycle(type(uint256).max - PRICE, 1, false);
    }

    function testMaximumUint256EscrowCanSettleAndFullyExit() public {
        _fullRangeLifecycle(type(uint256).max - PRICE, DURATION, true);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzFullUint256BoostPreservesRefundAndWithdrawalLiveness(uint256 amount, uint256 elapsed, bool settle)
        public
    {
        amount = bound(amount, 1, type(uint256).max - PRICE);
        elapsed = settle ? DURATION : bound(elapsed, 0, DURATION - 1);
        _fullRangeLifecycle(amount, elapsed, settle);
    }

    function _fullRangeLifecycle(uint256 amount, uint256 elapsed, bool settle) internal {
        (uint256 id,) = _fundedAd();
        _deposit(bob, amount);
        vm.prank(bob);
        ads.boost(id, amount);
        assertEq(ads.totalEscrowed(), PRICE + amount);
        assertEq(ads.rankOf(id), PRICE + amount);
        vm.warp(START + elapsed);
        uint256 refund;
        if (settle) {
            ads.settle(id);
        } else {
            vm.prank(alice);
            refund = ads.cancel(id);
            uint256 remainingValue = PRICE * (DURATION - elapsed);
            assertGe(refund * DURATION, remainingValue);
            assertLt(refund * DURATION - remainingValue, DURATION);
        }
        assertEq(ads.available(bob), 0);
        assertEq(ads.totalEscrowed(), 0);
        assertEq(ads.totalProceeds() + refund, PRICE + amount);
        _assertSolvent();
        uint256 proceeds = ads.proceeds(treasury);
        vm.prank(treasury);
        ads.withdrawProceeds(proceeds, bob);
        if (refund != 0) {
            vm.prank(alice);
            ads.withdraw(refund, bob);
        }
        assertEq(token.balanceOf(bob), PRICE + amount);
        assertEq(ads.accountedBalance(), 0);
        _assertSolvent();
    }

    function _assertNoAdminPowers(FeaturedPlacementsV2 target, address caller) internal {
        vm.startPrank(caller);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        target.configureToken(address(token));
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        target.setProceedsRecipient(caller);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        target.transferOwnership(caller);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        target.cancelOwnershipTransfer();
        vm.stopPrank();
    }
}
