// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PleaToken} from "../src/PleaToken.sol";

/// @notice Stands in for the launch factory: a contract that deploys the token and so must end up
///         holding the whole supply, because the constructor mints to `msg.sender`.
contract FactoryStub {
    PleaToken public token;

    function launch() external returns (PleaToken) {
        token = new PleaToken();
        return token;
    }

    function send(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract PleaTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    PleaToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    function setUp() public {
        vm.prank(deployer);
        token = new PleaToken();
    }

    // -----------------------------------------------------------------------------------------
    // Metadata and supply
    // -----------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "plea");
        assertEq(token.symbol(), "PLEA");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), deployer, SUPPLY);
        vm.prank(deployer);
        new PleaToken();
    }

    /// @dev On the real launch the deployer is the ProjectFactory, a contract. The mint must land
    ///      on it, not on the EOA that called it.
    function test_contractDeployerReceivesSupplyNotTxOrigin() public {
        FactoryStub factory = new FactoryStub();
        address origin = makeAddr("origin");
        vm.prank(origin, origin);
        PleaToken launched = factory.launch();
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(origin), 0);
        assertEq(launched.totalSupply(), SUPPLY);
        // And the factory can pay it out in full, with nothing withheld.
        assertTrue(factory.send(alice, SUPPLY / 10));
        assertEq(launched.balanceOf(alice), SUPPLY / 10);
        assertEq(launched.balanceOf(address(factory)), SUPPLY - SUPPLY / 10);
    }

    // -----------------------------------------------------------------------------------------
    // transfer
    // -----------------------------------------------------------------------------------------

    function test_transferMovesExactAmountAndEmits() public {
        uint256 amount = 1_234 ether;
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, amount);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferHasNoFeeAlongAChainOfHolders() public {
        uint256 amount = 777 ether;
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        token.transfer(alice, SUPPLY);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, alice, 10 ether, 10 ether + 1));
        vm.prank(alice);
        token.transfer(bob, 10 ether + 1);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transfer(alice, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1);
    }

    // -----------------------------------------------------------------------------------------
    // approve / allowance
    // -----------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, spender, 5 ether);
        vm.prank(deployer);
        assertTrue(token.approve(spender, 5 ether));
        assertEq(token.allowance(deployer, spender), 5 ether);
    }

    function test_approveOverwritesRatherThanAdds() public {
        vm.startPrank(deployer);
        token.approve(spender, 5 ether);
        token.approve(spender, 2 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 2 ether);
    }

    function test_approveCanExceedBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, SUPPLY * 2));
        assertEq(token.allowance(alice, spender), SUPPLY * 2);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    // -----------------------------------------------------------------------------------------
    // transferFrom
    // -----------------------------------------------------------------------------------------

    function test_transferFromSpendsAllowanceAndMovesTokens() public {
        vm.prank(deployer);
        token.approve(spender, 100 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, bob, 60 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, 60 ether));
        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 60 ether);
        assertEq(token.allowance(deployer, spender), 40 ether);
        assertEq(token.balanceOf(spender), 0, "the spender itself received nothing");
    }

    function test_transferFromUnlimitedAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(bob), 1 ether);
    }

    function test_transferFromExactAllowanceLeavesZero() public {
        vm.prank(deployer);
        token.approve(spender, 3 ether);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 3 ether);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromRevertsWhenAllowanceTooSmall() public {
        vm.prank(deployer);
        token.approve(spender, 5 ether);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, spender, 5 ether, 6 ether));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 6 ether);
        // Nothing moved and the allowance is intact.
        assertEq(token.allowance(deployer, spender), 5 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromRevertsWhenOwnerBalanceTooSmall() public {
        vm.prank(deployer);
        token.transfer(alice, 2 ether);
        vm.prank(alice);
        token.approve(spender, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, alice, 2 ether, 3 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 3 ether);
        assertEq(token.allowance(alice, spender), 10 ether, "allowance is untouched when the transfer reverts");
    }

    function test_transferFromRevertsToZeroAddress() public {
        vm.prank(deployer);
        token.approve(spender, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(deployer, address(0), 1 ether);
    }

    /// @dev A holder cannot pull from another holder just by calling transferFrom on themselves,
    ///      and an allowance granted to one spender is not usable by another.
    function test_allowanceIsPerSpender() public {
        vm.prank(deployer);
        token.approve(spender, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, alice, 0, 1 ether));
        vm.prank(alice);
        token.transferFrom(deployer, alice, 1 ether);
    }

    /// @dev Even the deployer (the most plausibly trusted address) cannot move a holder's balance
    ///      without an allowance.
    function test_deployerCannotPullFromHolder() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    // -----------------------------------------------------------------------------------------
    // No privileged surface
    // -----------------------------------------------------------------------------------------

    /// @dev None of the usual mint / admin entry points exist. Each call must fail (no fallback)
    ///      and leave the supply and balances untouched, from a stranger and from the deployer.
    function test_noMintOrAdminFunctionExists() public {
        address attacker = makeAddr("attacker");
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "owner()",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
            assertEq(token.balanceOf(deployer), SUPPLY, signatures[i]);
        }
    }

    /// @dev No pause / freeze / blocklist entry point exists either, and a holder keeps control of
    ///      their balance whatever the deployer tries.
    function test_noPauseOrFreezeFunctionExists() public {
        vm.prank(deployer);
        token.transfer(alice, 50 ether);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(alice), 50 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 25 ether));
        assertEq(token.balanceOf(bob), 25 ether);
    }

    function test_rejectsEtherAndUnknownCalls() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token has no receive function");
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok, "the token has no fallback function");
    }

    /// @dev Mirrors the launch floor's opcode scan: no DELEGATECALL, CALLCODE or SELFDESTRUCT in
    ///      reachable runtime code, and the runtime fits EIP-170.
    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        bool reachable = true;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // -----------------------------------------------------------------------------------------
    // Fuzz
    // -----------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), SUPPLY);
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(deployer), SUPPLY - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, alice, held, amount));
        vm.prank(alice);
        token.transfer(bob, amount);
    }

    function testFuzz_transferFromWithinAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, allowed);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, amount));
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.allowance(deployer, spender), allowed - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromAboveAllowanceReverts(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, type(uint256).max - 1);
        amount = bound(amount, allowed + 1, type(uint256).max);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, spender, allowed, amount));
        vm.prank(spender);
        token.transferFrom(deployer, bob, amount);
    }

    function testFuzz_approveRoundTrips(address who, uint256 amount) public {
        vm.assume(who != address(0));
        vm.prank(alice);
        assertTrue(token.approve(who, amount));
        assertEq(token.allowance(alice, who), amount);
        assertEq(token.allowance(who, alice), 0);
    }
}
