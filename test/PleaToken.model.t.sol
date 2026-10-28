// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PleaToken} from "../src/PleaToken.sol";

/// @notice Model-based handler: keeps its own ledger of every actor's balance and every allowance
///         and checks the token against it after each call. Unlike the plain handler it also drives
///         the failure paths (overspending a balance, overspending an allowance, a zero receiver, a
///         zero spender) and requires each to revert with the right error and change nothing.
contract PleaModelHandler is Test {
    PleaToken public immutable token;
    address[] public actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    uint256 public ghostReverts;
    uint256 public ghostUnlimitedSpends;

    constructor(PleaToken token_, address[] memory actors_, address deployer) {
        token = token_;
        actors = actors_;
        ghostBalance[deployer] = token_.TOTAL_SUPPLY();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _move(address from, address to, uint256 amount) internal {
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
    }

    // ---------------------------------------------------------------------------------------
    // Successful paths
    // ---------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (unlimited) amount = type(uint256).max;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 cap = ghostBalance[owner] < allowed ? ghostBalance[owner] : allowed;
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (allowed == type(uint256).max) ghostUnlimitedSpends++;
        else ghostAllowance[owner][spender] = allowed - amount;
        _move(owner, to, amount);
    }

    // ---------------------------------------------------------------------------------------
    // Failure paths: each must revert with the documented error and leave everything as it was
    // ---------------------------------------------------------------------------------------

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[from];
        uint256 amount = held + bound(excess, 1, type(uint256).max - held);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, from, held, amount));
        vm.prank(from);
        token.transfer(to, amount);
        ghostReverts++;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
        ghostReverts++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
        ghostReverts++;
    }

    function transferFromOverAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed == type(uint256).max) return; // unlimited: there is no amount above it
        uint256 amount = allowed + bound(excess, 1, type(uint256).max - allowed);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, spender, allowed, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ghostReverts++;
    }

    /// @dev Within the allowance but above the owner's balance: must revert and must not burn the
    ///      allowance on the way out.
    function transferFromOverBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 held = ghostBalance[owner];
        if (allowed <= held) return; // no amount is both within the allowance and above the balance
        amount = bound(amount, held + 1, allowed);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, owner, held, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ghostReverts++;
    }
}

contract PleaTokenModelInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    PleaToken internal token;
    PleaModelHandler internal handler;
    address[] internal actors;

    function setUp() public {
        address deployer = makeAddr("deployer");
        vm.prank(deployer);
        token = new PleaToken();

        actors.push(deployer);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        // The token's own address is a valid receiver; tokens sent there are simply held by it.
        actors.push(address(token));

        handler = new PleaModelHandler(token, actors, deployer);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesMatchModel() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            assertEq(token.balanceOf(actors[i]), handler.ghostBalance(actors[i]), "balance diverged from model");
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY, "balances no longer sum to the supply");
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesMatchModel() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            for (uint256 j = 0; j < actors.length; j++) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.ghostAllowance(actors[i], actors[j]),
                    "allowance diverged from model"
                );
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_nothingLeaksOutsideActors() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.allowance(address(handler), address(handler)), 0);
    }
}

/// @notice Edge cases the main unit suite does not pin, and the launch payout as the factory runs it.
contract PleaTokenEdgeTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);

    PleaToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    function setUp() public {
        vm.prank(deployer);
        token = new PleaToken();
    }

    /// @dev Exactly what the launch does with the supply: 10% to the distributor, which pays it out
    ///      whole; a pool share; the remainder. Every leg arrives exactly, nothing is withheld.
    function test_launchPayoutArrivesWhole() public {
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("poolManager");
        address requester = makeAddr("requester");
        uint256 swarm = SUPPLY * 1_000 / 10_000;
        uint256 pool = SUPPLY * 5_000 / 10_000;

        vm.startPrank(deployer);
        token.transfer(distributor, swarm);
        token.transfer(poolManager, pool);
        token.transfer(requester, SUPPLY - swarm - pool);
        vm.stopPrank();
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.balanceOf(requester), SUPPLY - swarm - pool);

        // The distributor pays claims out to the last unit.
        uint256 claimants = 7;
        uint256 share = swarm / claimants;
        for (uint256 i = 0; i < claimants; i++) {
            uint256 amount = i == claimants - 1 ? token.balanceOf(distributor) : share;
            address claimant = address(uint160(0xC1A1 + i));
            vm.prank(distributor);
            assertTrue(token.transfer(claimant, amount));
            assertEq(token.balanceOf(claimant), amount);
        }
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev A spender with an unlimited allowance is still capped by the owner's balance.
    function test_unlimitedAllowanceStillBoundByBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 5 ether);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, alice, 5 ether, 5 ether + 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 5 ether + 1);
        vm.prank(spender);
        token.transferFrom(alice, bob, 5 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 5 ether);
        assertEq(token.allowance(alice, spender), type(uint256).max);
    }

    /// @dev An allowance of max - 1 is an ordinary allowance and is decremented.
    function test_allowanceOneBelowMaxIsDecremented() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, spender), type(uint256).max - 2);
    }

    /// @dev Holders need an allowance even to transferFrom themselves: the function does not special
    ///      case msg.sender == from.
    function test_transferFromSelfRequiresAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(deployer, alice, 1);

        vm.startPrank(deployer);
        token.approve(deployer, 1);
        assertTrue(token.transferFrom(deployer, alice, 1));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.allowance(deployer, deployer), 0);
    }

    /// @dev transferFrom with from == to keeps the balance and still spends the allowance.
    function test_transferFromToOwnerKeepsBalanceSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 10 ether);
        vm.prank(spender);
        token.transferFrom(deployer, deployer, 4 ether);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, spender), 6 ether);
    }

    /// @dev A zero-amount transferFrom needs no allowance and emits a zero Transfer.
    function test_transferFromZeroWithoutAllowance() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
    }

    /// @dev The zero address holds nothing and nobody can spend "from" it beyond zero.
    function test_cannotPullFromZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(0), bob, 1);
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @dev A transfer to the zero address is refused even for zero tokens: it is not a burn path.
    function test_zeroAmountToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 0);
    }

    /// @dev A failed transfer leaves both balances as they were.
    function test_failedTransferChangesNothing() public {
        vm.prank(deployer);
        token.transfer(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeCall(PleaToken.transfer, (bob, 1 ether + 1)));
        assertFalse(ok);
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Tokens sent to the token contract stay there; nothing can retrieve or burn them.
    function test_tokensSentToTokenAreHeldNotBurned() public {
        vm.prank(deployer);
        token.transfer(address(token), 3 ether);
        assertEq(token.balanceOf(address(token)), 3 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // -----------------------------------------------------------------------------------------
    // Fuzz: arithmetic at the edges, without discarding inputs
    // -----------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_twoHopTransferConserves(uint256 a, uint256 b, uint160 toRaw) public {
        address to = address(uint160(bound(toRaw, 1, type(uint160).max)));
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        vm.prank(deployer);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(to, b);
        uint256 sum = token.balanceOf(deployer);
        if (alice != deployer) sum += token.balanceOf(alice);
        if (to != deployer && to != alice) sum += token.balanceOf(to);
        assertEq(sum, SUPPLY);
        if (to != alice && to != deployer) {
            assertEq(token.balanceOf(to), b);
            assertEq(token.balanceOf(alice), a - b);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromOverBalanceKeepsAllowance(uint256 held, uint256 allowed, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        allowed = bound(allowed, held + 1, type(uint256).max);
        amount = bound(amount, held + 1, allowed);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(spender, allowed);
        vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientBalance.selector, alice, held, amount));
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), allowed);
        assertEq(token.balanceOf(alice), held);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_repeatedSpendsNeverExceedAllowance(uint256 allowed, uint256 step) public {
        allowed = bound(allowed, 1, SUPPLY);
        step = bound(step, 1, allowed);
        vm.prank(deployer);
        token.approve(spender, allowed);
        uint256 spent;
        for (uint256 i = 0; i < 8; i++) {
            uint256 left = token.allowance(deployer, spender);
            if (left < step) {
                vm.expectRevert(abi.encodeWithSelector(PleaToken.InsufficientAllowance.selector, spender, left, step));
                vm.prank(spender);
                token.transferFrom(deployer, bob, step);
                break;
            }
            vm.prank(spender);
            token.transferFrom(deployer, bob, step);
            spent += step;
        }
        assertLe(spent, allowed);
        assertEq(token.balanceOf(bob), spent);
        assertEq(token.allowance(deployer, spender), allowed - spent);
    }
}
