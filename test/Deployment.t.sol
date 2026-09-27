// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DaemonSponsorPool} from "../src/DaemonSponsorPool.sol";

/// @dev A local constructor probe, not an implementation of the service's ProjectFactory.
contract ConstructorProbe {
    function deploy() external returns (LaunchToken token, DaemonSponsorPool app) {
        token = new LaunchToken{salt: bytes32(uint256(1))}();
        app = new DaemonSponsorPool{salt: bytes32(uint256(2))}(address(token));
    }
}

contract DeploymentTest is Test {
    function test_factoryConstructionPreservesSupplyAndNeedsNoInitialisation() public {
        vm.chainId(11155111);
        ConstructorProbe factory = new ConstructorProbe();
        (LaunchToken token, DaemonSponsorPool app) = factory.deploy();
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.balanceOf(address(app)), 0);
        assertEq(address(app.token()), address(token));
        assertEq(app.genesis(), block.timestamp);
        assertEq(app.currentEpoch(), 0);
        assertFalse(app.isRegistered(address(factory)));
        _checkRuntime(address(token).code);
        _checkRuntime(address(app).code);
    }

    function _checkRuntime(bytes memory runtime) private pure {
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
            }
        }
    }
}
