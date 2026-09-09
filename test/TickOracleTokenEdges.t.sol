// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TickOracleToken} from "../src/TickOracleToken.sol";
import {Selectors} from "./utils/Selectors.sol";

/// @notice The token beyond its happy path: the exact policy supply, the single mint, the standard's revert
/// paths, and proof from the bytecode that nothing beyond the nine standard functions is reachable.
contract TickOracleTokenEdgesTest is Test {
    uint256 constant TOTAL_SUPPLY = 1_000_000_000_000_000_000_000_000_000; // the policy number, 1e27

    TickOracleToken token;

    function setUp() public {
        token = new TickOracleToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Supply
    // ---------------------------------------------------------------------------------------------

    function test_supplyIsThePolicyNumberAndNothingElse() public view {
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** uint256(token.decimals()));
        assertEq(token.balanceOf(address(this)), TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_constructorMintsExactlyOnce() public {
        vm.recordLogs();
        TickOracleToken fresh = new TickOracleToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "more than one event at construction");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(0), "not a mint");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(this), "minted to someone else");
        assertEq(abi.decode(logs[0].data, (uint256)), TOTAL_SUPPLY);
        assertEq(fresh.totalSupply(), TOTAL_SUPPLY);
    }

    function test_notEvenTheDeployerCanMintOrBurnAfterwards() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", address(this), 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(this)), TOTAL_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // The standard's paths, including the ones that revert
    // ---------------------------------------------------------------------------------------------

    function test_transferFrom_movesExactlyWhatWasApproved() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        assertTrue(token.approve(spender, 300 ether));
        assertEq(token.allowance(address(this), spender), 300 ether);

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, 120 ether));
        assertEq(token.balanceOf(recipient), 120 ether);
        assertEq(token.balanceOf(address(this)), TOTAL_SUPPLY - 120 ether);
        assertEq(token.allowance(address(this), spender), 180 ether);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 180 ether, 181 ether)
        );
        token.transferFrom(address(this), recipient, 181 ether);
    }

    function test_transferFrom_anInfiniteAllowanceIsNotSpentDown() public {
        address spender = makeAddr("spender");
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(address(this), spender, 1 ether);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
    }

    function test_transferFrom_withoutAllowanceReverts() public {
        address spender = makeAddr("spender");
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), spender, 1);
    }

    function test_transfer_beyondTheBalanceReverts() public {
        address poor = makeAddr("poor");
        token.transfer(poor, 5);
        vm.prank(poor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 5, 6));
        token.transfer(address(this), 6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), TOTAL_SUPPLY - 5, TOTAL_SUPPLY
            )
        );
        token.transfer(poor, TOTAL_SUPPLY);
    }

    function test_transfer_toTheZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    function test_approve_theZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transfer_ofZeroIsAllowedAndChangesNothing() public {
        address recipient = makeAddr("recipient");
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), recipient, 0);
        assertTrue(token.transfer(recipient, 0));
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(address(this)), TOTAL_SUPPLY);
    }

    function test_transfer_theWholeSupplyAtOnce() public {
        address recipient = makeAddr("recipient");
        assertTrue(token.transfer(recipient, TOTAL_SUPPLY));
        assertEq(token.balanceOf(recipient), TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    /// @notice Any sequence of transfers among a handful of holders conserves the supply exactly.
    function testFuzz_transfersConserveTheSupply(uint256 seed, uint8 count) public {
        address[4] memory holders = [address(this), makeAddr("h1"), makeAddr("h2"), makeAddr("h3")];
        for (uint256 i = 0; i < count; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address from = holders[r % 4];
            address to = holders[(r >> 8) % 4];
            uint256 amount = (r >> 16) % (token.balanceOf(from) + 1);
            vm.prank(from);
            assertTrue(token.transfer(to, amount));
        }
        uint256 sum;
        for (uint256 i = 0; i < 4; i++) {
            sum += token.balanceOf(holders[i]);
        }
        assertEq(sum, TOTAL_SUPPLY, "balances do not add up to the supply");
        assertEq(token.totalSupply(), TOTAL_SUPPLY, "the supply moved");
    }

    // ---------------------------------------------------------------------------------------------
    // Nothing beyond the standard
    // ---------------------------------------------------------------------------------------------

    function test_token_acceptsNoValueAndHasNoFallback() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "accepted plain ETH");
        (ok,) = address(token).call{value: 1}(abi.encodeCall(IERC20.totalSupply, ()));
        assertFalse(ok, "accepted ETH with a call");
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok, "has a fallback");
        (ok,) = address(token).call("");
        assertFalse(ok, "has a receive function");
        assertEq(address(token).balance, 0);
    }

    function test_token_hasNoExtensionBeyondTheStandard() public {
        string[16] memory signatures = [
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
            "nonces(address)",
            "DOMAIN_SEPARATOR()",
            "increaseAllowance(address,uint256)",
            "decreaseAllowance(address,uint256)",
            "snapshot()",
            "delegate(address)",
            "delegates(address)",
            "getVotes(address)",
            "flashLoan(address,address,uint256,bytes)",
            "paused()",
            "owner()",
            "cap()",
            "setMinter(address)",
            "issue(uint256)",
            "unpause()"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], address(this), address(this), uint256(1));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
    }

    /// @notice The dispatcher reaches exactly the nine ERC-20 functions. A mint, an owner or an upgrade path
    /// hidden behind any selector at all would have to show up here.
    function test_runtimeCode_dispatchesExactlyTheNineStandardFunctions() public view {
        bytes4[] memory found = Selectors.push4Immediates(address(token).code);
        bytes4[9] memory standard = [
            bytes4(keccak256("name()")),
            bytes4(keccak256("symbol()")),
            bytes4(keccak256("decimals()")),
            IERC20.totalSupply.selector,
            IERC20.balanceOf.selector,
            IERC20.transfer.selector,
            IERC20.transferFrom.selector,
            IERC20.approve.selector,
            IERC20.allowance.selector
        ];
        assertEq(found.length, standard.length, "the dispatcher knows a selector the standard does not");
        for (uint256 i = 0; i < standard.length; i++) {
            assertTrue(Selectors.contains(found, standard[i]), "a standard function is missing");
        }
    }

    function test_runtimeCodeIsTheSameWhoeverDeploysIt() public {
        vm.prank(makeAddr("someone else"));
        TickOracleToken other = new TickOracleToken();
        assertEq(address(other).code, address(token).code, "the deployer changes the code");
    }
}
