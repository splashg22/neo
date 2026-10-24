# NEO — the stock's rulebook, as a hook

A corporate-action oracle and Uniswap v4 hooks for tokenized-stock pools on Robinhood Chain (chain id 4663).

Tokenized stocks split, pay dividends, get halted and change symbols. A v4 pool knows a price and a tick, nothing else. **The Tape** records those events on-chain, attested by the issuer, disputed by anyone, finalized into plain storage and an append-only Merkle tree. NEO hooks read it in the swap path with one `view` call; no oracle round-trip.

## Contracts

| Contract | Role |
| --- | --- |
| `src/interfaces/ITape.sol` | The interface every hook imports: `isHalted`, `action`, `eventsRoot`, `verify`, plus the `post` / `challenge` / `finalize` / `resolve` lifecycle. |
| `src/Tape.sol` | Attest, dispute, finalize. EIP-712 attester signatures per symbol, ETH bonds for poster and challenger, reviewer settles disputes, loser's bond pays the winner. Finalized events update `isHalted` / `action` and append a leaf. |
| `src/libraries/IncrementalMerkle.sol` | Depth-20 append-only keccak tree (deposit-contract construction). Ordered sibling proofs. |
| `src/CorporateActionHook.sol` | First NEO hook. Permissions `BEFORE_SWAP \| BEFORE_ADD_LIQUIDITY`. A pool bound to a symbol refuses swaps and new liquidity while halted, and from a split or rename's effective time until the pool operator `acknowledge`s it. Removing liquidity is never blocked. Exposes `label()`. |

### Event kinds

| Kind | `value` |
| --- | --- |
| `Split` | new shares per old share, scaled 1e4 (`40_000` = 4-for-1) |
| `Dividend` | cash per share, quote-asset minor units |
| `Halt` | `1` halt, `0` lift |
| `Rename` | new symbol as `bytes32` |

### Lifecycle

1. **post** — anyone, with the symbol's attester signature and `postBond`. Opens the dispute window.
2. **challenge** — anyone inside the window, with `challengeBond`.
3. **finalize** — after the window, if unchallenged. Applies state, appends the leaf, refunds the poster.
4. **resolve** — reviewer settles a challenge. Correct event: finalize, poster takes both bonds. Wrong event: reject, challenger takes both bonds.

## Build and test

Requires [Foundry](https://getfoundry.sh).

```bash
git submodule update --init --recursive
forge test -vv
```

`lib/v4-periphery` is pinned to `3779387e` (2025-11-05), the last commit that ships `src/utils/BaseHook.sol` and `HookMiner.sol`; later commits moved hooks to a separate repo. `v4-core` is resolved through v4-periphery's own submodule so the two always match. Also in the repo: `site/neo.html`, the concept page (publishable as a static page), and `site/research-wth-hookr.md`, notes on the two neighbouring projects on Robinhood Chain.

Tests cover signature and bond checks, nonce replay, the dispute window, both resolve outcomes, on-chain Merkle root against a reference tree with proofs for every leaf (and forged/misindexed proofs failing), hook address mining, halt blocking swap and add-liquidity but not remove, split blocking until acknowledged, dividends never blocking, and unbound pools being inert.

## Deploy

```bash
cp .env.example .env   # fill in
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

`Deploy.s.sol` deploys the Tape, then mines a CREATE2 salt so the hook's address carries exactly `BEFORE_SWAP | BEFORE_ADD_LIQUIDITY` and deploys it against the chain's `PoolManager`.

## Status

Nothing here is deployed or audited. Example tickers in tests are placeholders. NEO is independent and not affiliated with Robinhood, Uniswap, Arbitrum, Hookr or What The Hook.
