// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StoreFixture, HookListingRegistry} from "./helpers/StoreFixture.sol";

contract RegistryBoundaryTest is StoreFixture {
    function testMaximumMetadataAndSixteenMaximumLengthLabelsRoundTrip() public {
        HookListingRegistry.Metadata memory data = _metadata();
        data.name = _text(96);
        data.sourceRef = _text(512);
        data.testRef = _text(512);
        data.reviewRef = _text(512);
        data.auditRef = _text(512);
        data.callbackMask = 0x3fff;
        data.callbackDisclosure = _text(1024);
        data.feeDisclosure = _text(1024);
        data.adminDisclosure = _text(1024);
        data.labels = new string[](16);
        for (uint256 i; i < 16; ++i) {
            bytes memory label = bytes(_text(32));
            label[0] = bytes1(uint8(97 + i));
            data.labels[i] = string(label);
        }
        vm.prank(alice);
        uint256 id = registry.createListing(1, hook, data);
        bytes32 originalHash = keccak256(abi.encode(data));
        assertEq(keccak256(abi.encode(registry.getMetadata(id, 1))), originalHash);
        for (uint256 i; i < 16; ++i) {
            bytes32 label = keccak256(bytes(data.labels[i]));
            (uint256[] memory ids,) = registry.search(1, 100, 1, alice, label);
            assertEq(ids.length, 1);
            assertEq(ids[0], id);
        }
        string[] memory previousLabels = data.labels;
        data.labels = new string[](0);
        vm.prank(alice);
        registry.updateListing(id, data);
        assertEq(registry.getMetadata(id, 2).labels.length, 0);
        assertEq(keccak256(abi.encode(registry.getMetadata(id, 1))), originalHash);
        for (uint256 i; i < previousLabels.length; ++i) {
            bytes32 label = keccak256(bytes(previousLabels[i]));
            assertFalse(registry.hasLabel(id, label));
            (uint256[] memory ids,) = registry.search(1, 100, 0, address(0), label);
            assertEq(ids.length, 0);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzEveryMetadataLimitRejectsCreateAndUpdateAtomically(
        uint256 fieldSeed,
        uint256 lengthSeed,
        bool emptyRequired
    ) public {
        uint256 id = _create(alice);
        vm.startPrank(alice);
        registry.proposeListingOwner(id, bob);
        registry.setListingActive(id, false);
        vm.stopPrank();
        bytes32 beforeListing = keccak256(abi.encode(registry.getListing(id)));
        bytes32 beforeMetadata = keccak256(abi.encode(registry.getMetadata(id, 1)));
        HookListingRegistry.Metadata memory data = _metadata();
        data.labels[0] = "changed-label";
        uint256 field = fieldSeed % 9;
        if (field == 0) data.name = emptyRequired ? "" : _text(bound(lengthSeed, 97, 128));
        else if (field == 1) data.sourceRef = _text(bound(lengthSeed, 513, 544));
        else if (field == 2) data.testRef = _text(bound(lengthSeed, 513, 544));
        else if (field == 3) data.reviewRef = _text(bound(lengthSeed, 513, 544));
        else if (field == 4) data.auditRef = _text(bound(lengthSeed, 513, 544));
        else if (field == 5) data.callbackDisclosure = emptyRequired ? "" : _text(bound(lengthSeed, 1025, 1056));
        else if (field == 6) data.feeDisclosure = emptyRequired ? "" : _text(bound(lengthSeed, 1025, 1056));
        else if (field == 7) data.adminDisclosure = emptyRequired ? "" : _text(bound(lengthSeed, 1025, 1056));
        else data.callbackMask = uint160(bound(lengthSeed, 0x4000, type(uint160).max));
        vm.prank(alice);
        vm.expectRevert(HookListingRegistry.InvalidMetadata.selector);
        registry.updateListing(id, data);
        vm.prank(bob);
        vm.expectRevert(HookListingRegistry.InvalidMetadata.selector);
        registry.createListing(1, hook, data);
        assertEq(registry.listingCount(), 1);
        assertEq(keccak256(abi.encode(registry.getListing(id))), beforeListing);
        assertEq(keccak256(abi.encode(registry.getMetadata(id, 1))), beforeMetadata);
        assertTrue(registry.hasLabel(id, keccak256("swap-limit")));
        assertFalse(registry.hasLabel(id, keccak256("changed-label")));
        assertEq(registry.listingFor(registry.identityKey(1, hook, bob)), 0);
        vm.expectRevert(HookListingRegistry.UnknownRevision.selector);
        registry.getMetadata(id, 2);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzLabelsRejectEveryByteOutsideLowercaseDigitHyphen(uint256 byteSeed, uint256 positionSeed) public {
        // The complement has 219 byte values. Generate it directly, without discarding runs.
        uint256 ordinal = bound(byteSeed, 0, 218);
        uint8 invalid;
        for (uint256 candidate; candidate < 256; ++candidate) {
            bool allowed =
                candidate == 45 || (candidate >= 48 && candidate <= 57) || (candidate >= 97 && candidate <= 122);
            if (allowed) continue;
            if (ordinal == 0) {
                invalid = uint8(candidate);
                break;
            }
            --ordinal;
        }
        uint256 id = _create(alice);
        HookListingRegistry.Metadata memory data = _metadata();
        bytes memory label = bytes(_text(32));
        label[positionSeed % 32] = bytes1(invalid);
        data.labels[0] = string(label);
        vm.prank(alice);
        vm.expectRevert(HookListingRegistry.InvalidLabels.selector);
        registry.updateListing(id, data);
        vm.prank(bob);
        vm.expectRevert(HookListingRegistry.InvalidLabels.selector);
        registry.createListing(1, hook, data);
        assertEq(registry.getListing(id).revision, 1);
        assertEq(abi.encode(registry.getMetadata(id, 1)), abi.encode(_metadata()));
        assertTrue(registry.hasLabel(id, keccak256("swap-limit")));
        assertEq(registry.listingCount(), 1);
    }

    function testDuplicateLabelsAtLastPositionAreAtomicAndReorderingPreservesSearch() public {
        uint256 id = _create(alice);
        HookListingRegistry.Metadata memory data = _metadata();
        data.labels = new string[](16);
        for (uint256 i; i < 15; ++i) {
            data.labels[i] = string.concat("label-", vm.toString(i));
        }
        data.labels[15] = data.labels[0];
        vm.prank(alice);
        vm.expectRevert(HookListingRegistry.InvalidLabels.selector);
        registry.updateListing(id, data);
        assertEq(registry.getListing(id).revision, 1);
        assertTrue(registry.hasLabel(id, keccak256("swap-limit")));
        assertFalse(registry.hasLabel(id, keccak256("label-0")));

        data = _metadata();
        data.labels[0] = "static-fee";
        data.labels[1] = "swap-limit";
        vm.prank(alice);
        registry.updateListing(id, data);
        assertEq(registry.getListing(id).revision, 2);
        assertTrue(registry.hasLabel(id, keccak256("swap-limit")));
        assertTrue(registry.hasLabel(id, keccak256("static-fee")));
        assertEq(abi.encode(registry.getMetadata(id, 1)), abi.encode(_metadata()));
    }

    function testDuplicateOwnershipAcceptanceCanBeRetriedAfterConflictingIdentityMoves() public {
        uint256 first = _create(alice);
        uint256 second = _create(bob);
        vm.prank(alice);
        registry.proposeListingOwner(first, bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HookListingRegistry.DuplicateListing.selector, second));
        registry.acceptListingOwnership(first);
        assertEq(registry.getListing(first).proposedOwner, bob);
        assertEq(registry.getListing(first).owner, alice);
        assertEq(registry.listingFor(registry.identityKey(1, hook, alice)), first);
        assertEq(registry.listingFor(registry.identityKey(1, hook, bob)), second);

        vm.prank(bob);
        registry.proposeListingOwner(second, treasury);
        vm.prank(treasury);
        registry.acceptListingOwnership(second);
        vm.prank(bob);
        registry.acceptListingOwnership(first);
        assertEq(registry.listingFor(registry.identityKey(1, hook, alice)), 0);
        assertEq(registry.listingFor(registry.identityKey(1, hook, bob)), first);
        assertEq(registry.listingFor(registry.identityKey(1, hook, treasury)), second);
        assertEq(registry.getListing(first).proposedOwner, address(0));
        vm.prank(bob);
        vm.expectRevert(HookListingRegistry.NotProposedOwner.selector);
        registry.acceptListingOwnership(first);

        vm.prank(bob);
        registry.proposeListingOwner(first, bob);
        vm.prank(bob);
        registry.acceptListingOwnership(first);
        assertEq(registry.listingFor(registry.identityKey(1, hook, bob)), first, "self-transfer retains identity");
        assertEq(registry.getListing(first).revision, 1);
        assertEq(abi.encode(registry.getMetadata(first, 1)), abi.encode(_metadata()));
    }

    function testUnknownListingFailsEveryMutationWithoutCreatingGhostRecords() public {
        uint256[3] memory unknown = [uint256(0), 1, type(uint256).max];
        for (uint256 i; i < unknown.length; ++i) {
            uint256 id = unknown[i];
            bytes memory reason = abi.encodeWithSelector(HookListingRegistry.UnknownListing.selector, id);
            vm.expectRevert(reason);
            registry.updateListing(id, _metadata());
            vm.expectRevert(reason);
            registry.setListingActive(id, true);
            vm.expectRevert(reason);
            registry.proposeListingOwner(id, alice);
            vm.expectRevert(reason);
            registry.cancelListingTransfer(id);
            vm.expectRevert(reason);
            registry.acceptListingOwnership(id);
            vm.expectRevert(reason);
            registry.getMetadata(id, 1);
            vm.expectRevert(reason);
            registry.isAudited(id);
        }
        assertEq(registry.listingCount(), 0);
        (uint256[] memory page, uint256 next) = registry.search(1, 100, 0, address(0), bytes32(0));
        assertEq(page.length, 0);
        assertEq(next, 1);
    }

    function _text(uint256 length) internal pure returns (string memory) {
        bytes memory value = new bytes(length);
        for (uint256 i; i < length; ++i) {
            value[i] = "a";
        }
        return string(value);
    }
}
