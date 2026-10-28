// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title plea (PLEA)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 PLEA (18 decimals) is minted
///         once, in the constructor, to the deployer. There is no owner, no minter, no burner, no
///         pause and no blocklist: after deployment the contract has no privileged functions and
///         the supply can never change.
/// @dev Self-contained on purpose so that the deployed bytecode depends on nothing but this file.
///      Follows ERC-20 (EIP-20) exactly, including the optional `name`, `symbol` and `decimals`.
///      `transferFrom` moves tokens only from `from` and only within the allowance `from` granted
///      to `msg.sender`. An allowance of `type(uint256).max` is treated as unlimited and is not
///      decremented, which matches the OpenZeppelin convention most integrators expect.
contract PleaToken {
    // ---------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------

    /// @notice ERC-20 token name.
    string public constant name = "plea";

    /// @notice ERC-20 token symbol.
    string public constant symbol = "PLEA";

    /// @notice ERC-20 decimals.
    uint8 public constant decimals = 18;

    /// @notice The only supply there will ever be: 1,000,000,000 PLEA in minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(decimals);

    // ---------------------------------------------------------------------------------------
    // Events (ERC-20)
    // ---------------------------------------------------------------------------------------

    /// @notice Emitted when `value` tokens move from `from` to `to`. The mint in the constructor
    ///         is emitted with `from == address(0)`.
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted when `owner` sets `spender`'s allowance to `value`.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------

    /// @notice `sender` tried to move `needed` but holds only `balance`.
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /// @notice `spender` tried to spend `needed` of `owner`'s tokens but was allowed only `allowance`.
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /// @notice The zero address may not receive tokens or be approved as a spender.
    error InvalidReceiver(address receiver);

    /// @notice The zero address may not be approved as a spender.
    error InvalidSpender(address spender);

    // ---------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------

    /// @notice Balance of each holder, in minor units.
    mapping(address account => uint256) public balanceOf;

    /// @notice Remaining amount `spender` may move out of `owner`'s balance.
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    // ---------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------

    /// @notice Mints the entire fixed supply to the deployer (`msg.sender`). Nothing can mint after
    ///         this. On the IdentityMD launch the deployer is the ProjectFactory, which then pays
    ///         the supply out according to the launch manifest.
    constructor() {
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------
    // ERC-20
    // ---------------------------------------------------------------------------------------

    /// @notice The fixed total supply. Constant for the life of the contract.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @notice Moves `amount` from the caller to `to`.
    /// @dev Reverts on insufficient balance or a zero-address receiver; never returns false.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to `amount`.
    /// @dev Overwrites rather than adds. Callers that want to change a non-zero allowance safely
    ///      should set it to zero first, or use the allowance exactly, as ERC-20 recommends.
    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert InvalidSpender(spender);
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Moves `amount` from `from` to `to` using the caller's allowance from `from`.
    /// @dev An allowance of `type(uint256).max` is unlimited and is not decremented. Any other
    ///      allowance is reduced by `amount`, with no Approval event, as OpenZeppelin does.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance(msg.sender, allowed, amount);
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert InvalidReceiver(to);
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            // The sum of all balances is TOTAL_SUPPLY, so `balanceOf[to] + amount` cannot overflow.
            balanceOf[from] = fromBalance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
