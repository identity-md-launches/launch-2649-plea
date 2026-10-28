// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PleaToken} from "../src/PleaToken.sol";

/// @notice Drives the token through random transfers, approvals and transferFroms between a fixed
///         set of actors, only with inputs the token accepts, so the invariants below are checked
///         against every reachable state rather than a hand-picked one.
contract PleaTokenHandler is Test {
    PleaToken public immutable token;
    address[] public actors;
    uint256 public ghostTransferred;

    constructor(PleaToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        require(token.transfer(to, amount), "transfer returned false");
        ghostTransferred += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        require(token.approve(spender, amount), "approve returned false");
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 cap = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        if (balance < cap) cap = balance;
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        require(token.transferFrom(owner, to, amount), "transferFrom returned false");
        ghostTransferred += amount;
    }
}

contract PleaTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    PleaToken internal token;
    PleaTokenHandler internal handler;
    address[] internal actors;

    function setUp() public {
        address deployer = makeAddr("deployer");
        vm.prank(deployer);
        token = new PleaToken();

        actors.push(deployer);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));

        handler = new PleaTokenHandler(token, actors);
        targetContract(address(handler));
    }

    /// @dev The supply never changes, whatever sequence of calls is made.
    function invariant_totalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Every unit minted is held by exactly one of the actors: nothing is lost to a fee,
    ///      burned, or created.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY);
    }

    /// @dev Nobody outside the actor set ever gains a balance: there is no hidden fee receiver.
    function invariant_noStrayBalances() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }
}
