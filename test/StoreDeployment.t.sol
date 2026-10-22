// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookListingRegistry} from "../src/store/HookListingRegistry.sol";
import {FeaturedPlacementsV2} from "../src/store/FeaturedPlacementsV2.sol";
import {StoreAdmin} from "../src/store/StoreAdmin.sol";
import {TestToken} from "./helpers/TestToken.sol";

/// @dev Local factory rehearsal only; no factory is part of the application deployment.
contract StoreDeploymentProbe {
    function deploy(address owner) external returns (HookListingRegistry registry, FeaturedPlacementsV2 ads) {
        registry = new HookListingRegistry{salt: keccak256("registry")}();
        ads = new FeaturedPlacementsV2{salt: keccak256("placements")}(owner, registry);
    }
}

contract StoreDeploymentTest is Test {
    function testFactoryLaunchOnRobinhood() public {
        _rehearse(4663);
    }

    function testFactoryLaunchOnEthereum() public {
        _rehearse(1);
    }

    function _rehearse(uint256 chainId) internal {
        vm.chainId(chainId);
        address owner = makeAddr("explicit launch owner");
        StoreDeploymentProbe factory = new StoreDeploymentProbe();
        (HookListingRegistry registry, FeaturedPlacementsV2 ads) = factory.deploy(owner);
        assertEq(ads.owner(), owner);
        assertNotEq(ads.owner(), address(factory));
        assertNotEq(ads.owner(), address(this));
        assertEq(address(ads.registry()), address(registry));
        assertEq(ads.imd(), address(0));
        assertEq(ads.proceedsRecipient(), address(0));
        assertEq(ads.accountedBalance(), 0);
        assertEq(address(ads).balance, 0);
        assertEq(address(registry).balance, 0);
        assertEq(ads.placementCount(), 0);
        assertEq(registry.listingCount(), 0);
        _checkRuntime(address(registry).code);
        _checkRuntime(address(ads).code);

        TestToken token = new TestToken("Mock IMD", 18);
        vm.startPrank(address(factory));
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        ads.configureToken(address(token));
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        ads.setProceedsRecipient(address(factory));
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        ads.transferOwnership(address(factory));
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        ads.cancelOwnershipTransfer();
        vm.expectRevert(StoreAdmin.NotPendingOwner.selector);
        ads.acceptOwnership();
        vm.stopPrank();
        vm.startPrank(owner);
        ads.configureToken(address(token));
        ads.setProceedsRecipient(owner);
        vm.stopPrank();
        assertEq(ads.proceedsRecipient(), owner);
        assertEq(token.balanceOf(owner), 0);
        assertEq(ads.accountedBalance(), 0);
    }

    function _checkRuntime(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        // Mirrors the supplied floor's reachable-opcode scan, skipping PUSH data and trailing constants.
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}
