# plea (PLEA)

A fixed-supply ERC-20 token for the IdentityMD custom-token launch on Ethereum mainnet (chain id 1).

| Property        | Value                                                  |
| --------------- | ------------------------------------------------------ |
| Contract        | `PleaToken` (`src/PleaToken.sol`)                      |
| Name            | `plea`                                                 |
| Symbol          | `PLEA`                                                 |
| Decimals        | 18                                                     |
| Total supply    | 1,000,000,000 PLEA = `1000000000000000000000000000` minor units |
| Minted to       | `msg.sender` of the constructor, once, in full         |
| Constructor args| none                                                   |
| Owner / admin   | none                                                   |

## Behaviour

- The constructor mints the whole supply to the deployer and emits a `Transfer` from the zero address.
  Nothing else can ever mint: there is no `mint`, no minter role, no owner, no proxy and no upgrade path.
- Nothing can burn, pause, freeze, blocklist or seize. The supply is constant for the life of the
  contract and only a holder (or a spender the holder approved) can move a holder's balance.
- `transfer`, `approve` and `transferFrom` follow ERC-20 exactly. Transfers carry no fee, no tax and
  no reflection: the amount sent is the amount received, on every path.
- `transferFrom` moves tokens only from `from`, and only within the allowance `from` granted to the
  caller. An allowance of `2^256 - 1` is unlimited and is not decremented (the OpenZeppelin convention).
- Transfers to the zero address and approvals of the zero address revert. Reverts use custom errors:
  `InsufficientBalance`, `InsufficientAllowance`, `InvalidReceiver`, `InvalidSpender`.
- The contract has no `receive` or `fallback`, so it refuses ETH and unknown calls.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`.

## Launch and deployment parameters

The launch is performed by IdentityMD's deployer through the ProjectFactory; nothing in this
repository deploys, broadcasts or signs. The values below are what the launch uses and are listed here
for reference only. The manifest (`launch.json`) is written by the manifest step after this work is
accepted, not by this repository.

- Chain: Ethereum mainnet, chain id 1.
- `token.contract`: `PleaToken`. `token.constructorArgs`: `[]`.
- `token.totalSupply`: `1000000000000000000000000000` (1e9 × 1e18). `token.decimals`: `18`.
- The deployer of the token is the factory, so the factory receives the whole supply and pays it out:
  10% to the launch's MerkleDistributor, 82% (`poolBps` 8200) seeds the Uniswap v4 pool, and the
  remaining 8% goes to `remainderTo` (`0xee2aaa315cf7ed169f93148d30d24af9318dbb66`).
- Pool: paired with IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), fee 12500 (1.25%),
  tick spacing 60, opening price derived by the deployer from `initialMarketCapWei`
  (2,500 IMD for the whole supply).
- The token needs no exemptions because it taxes nothing, so it takes no `$factory`, `$poolManager`
  or `$launchNumber` constructor argument.
- No application contracts are part of this launch (`contracts: []`).

## Assumptions

- The requester asked for a plain fixed-supply token. No burn, tax, vesting, governance, permit or
  owner functionality was requested, so none is included. Adding any of these later would require a
  new token: this contract cannot be upgraded.
- "All minted once to the deployer" means `msg.sender` of the constructor. On the launch this is the
  factory contract, never an EOA, and the tests cover deployment from a contract.
- `optimizer_runs = 200`, `evm_version = "cancun"` and `bytecode_hash = "none"` are pinned in
  `foundry.toml` so the verifier reproduces the launched bytecode exactly.

## Operational responsibilities

After launch there is nothing to configure and nothing to operate: no setter, no role, no key. The
only responsibilities are the launch's own:

- The factory must forward the supply exactly as the manifest says. The token imposes no constraint on
  this and withholds nothing.
- Holders are responsible for their own keys and allowances. Approve only what a spender needs; an
  unlimited approval stays in force until the holder changes it.
- Anyone integrating the token should treat it as a standard 18-decimal ERC-20 with revert-on-failure
  semantics (it never returns `false`).

## Security notes

Checked against the `eth-security` checklist. Items that apply:

- Access control: there are no privileged functions, so there is nothing to restrict.
- Reentrancy: the contract makes no external calls.
- Integer math: balances are bounded by the constant supply, so the unchecked arithmetic in
  `_transfer` cannot overflow. All other arithmetic is checked.
- Input validation: zero-address receivers and spenders are rejected.
- No `delegatecall`, no `selfdestruct`, no proxy, no initializer.
- Slither was not available on this machine and was not run; the code avoids the patterns its
  blocking detectors flag (see above).

Tests passing do not constitute an audit. An independent adversarial review is still part of the
launch process.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

Compiler pinned to `solc = "0.8.26"`. `forge-std` is vendored under `lib/forge-std` as plain files
(v1.9.6, MIT/Apache-2.0); there are no submodules and no network is needed.

Tests (`test/`):

- `PleaToken.t.sol`: metadata, supply, constructor mint to an EOA and to a contract deployer,
  `transfer`/`approve`/`transferFrom` success paths with events, every revert path with its exact
  error, absence of mint/admin/pause/freeze entry points, ETH and unknown-call rejection, an opcode
  scan of the runtime, and fuzz tests for conservation, allowance accounting and the revert bounds.
- `PleaToken.invariant.t.sol`: a handler drives random transfers, approvals and `transferFrom`s; the
  invariants are a constant total supply, balances summing to the supply, and no stray balances.
