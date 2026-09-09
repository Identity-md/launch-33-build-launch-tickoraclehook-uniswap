// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickOracleToken} from "../src/TickOracleToken.sol";
import {RuntimeCode} from "./utils/RuntimeCode.sol";

contract TickOracleTokenTest is Test {
    uint256 constant TOTAL_SUPPLY = 1_000_000_000_000_000_000_000_000_000; // 1e27

    TickOracleToken token;

    function setUp() public {
        token = new TickOracleToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Tick Oracle Signal");
        assertEq(token.symbol(), "TOS");
        assertEq(token.decimals(), 18);
    }

    function test_mintsTheWholeSupplyToItsDeployerOnce() public view {
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000 * 1e18);
        assertEq(token.balanceOf(address(this)), TOTAL_SUPPLY);
    }

    function test_mintsToWhoeverDeploysIt() public {
        address factory = address(0xFAC7);
        vm.prank(factory);
        TickOracleToken other = new TickOracleToken();
        assertEq(other.balanceOf(factory), TOTAL_SUPPLY);
        assertEq(other.balanceOf(address(this)), 0);
    }

    function test_hasNoMintBurnOrAdminEntryPoint() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "burn(uint256)",
            "burn(address,uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "upgradeTo(address)",
            "initialize(address)"
        ];

        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], address(this), uint256(1));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), TOTAL_SUPPLY, signatures[i]);
        }
    }

    function test_transferMovesExactlyWhatItWasAsked() public {
        address recipient = address(0xCAFE);
        assertTrue(token.transfer(recipient, 1_000 ether));
        assertEq(token.balanceOf(recipient), 1_000 ether);
        assertEq(token.balanceOf(address(this)), TOTAL_SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    function test_runtimeCode_hasNoEscapeHatch() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        RuntimeCode.assertNoEscapeHatch(code);
    }
}
