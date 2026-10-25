# NEO — the stock's rulebook, as a hook

A corporate-action oracle and Uniswap v4 hooks for tokenized-stock pools on Robinhood Chain (chain id 4663).

Tokenized stocks split, pay dividends, get halted and change symbols. A v4 pool knows a price and a tick, nothing else. **The Tape** records those events on-chain, attested by the issuer, disputed by anyone, finalized into plain storage and an append-only Merkle tree. NEO hooks read it in the swap path with one `view` call; no oracle round-trip.

## Contracts

| Contract | Role |
| --- | --- |
| `src/interfaces/ITape.sol` | The interface every hook imports: `isHalted`, `action`, `eventsRoot`, `verify`, plus the `post` / `challenge` / `finalize` / `resolve` lifecycle. |
| `src/Tape.sol` | Attest, dispute, finalize. EIP-712 attester signatures per symbol, ETH bonds for poster and challenger, reviewer settles disputes, loser's bond pays the winner. Finalized events update `isHalted` / `action` and append a leaf. `eventsOf(symbol)` indexes every posted event for calendars; `hasAttester(symbol)` says whether a data source exists. **Operator wage on-chain:** anyone can `fund()` the `rewardPool`; the reviewer sets `finalizeReward`; whoever lands `finalize()` is paid it, never from bonds, and an empty pool never blocks finalization. |
| `src/libraries/IncrementalMerkle.sol` | Depth-20 append-only keccak tree (deposit-contract construction). Ordered sibling proofs. |
| `src/hooks/LimitUpLimitDownHook.sol` | `BEFORE_SWAP`. Refuses a swap when the pool's pre-swap price is outside a band (default ±10%) around a reference price from an `IReferencePrice` oracle, when the reference is stale (default 15 min) or missing, or when the stock is halted. `tradeStatus(key)` view with reasons `unbound · halted · no-reference · outside-band · ok`. Pre-swap check only; a post-swap check would need `AFTER_SWAP`. |
| `src/hooks/EligibilityGateHook.sol` | `BEFORE_SWAP \| BEFORE_ADD_LIQUIDITY`. Only addresses on an `IAllowlist` may swap or add liquidity; removing is never gated. The trader is taken from 20-byte `hookData`, else `tx.origin` (limitation documented). No allowlist set means nobody is eligible. |
| `src/hooks/VolatilityFeeHook.sol` | `BEFORE_SWAP \| AFTER_SWAP`. Dynamic LP fee = base + feePerTick × EWMA of recent tick moves, clamped to a max, plus a bump for a window around any Tape event. Requires a dynamic-fee pool. Transient storage for the pre-swap tick. |
| `src/hooks/DividendPassThroughHook.sol` | `BEFORE_SWAP`. Issuer deposits the cash dividend in the quote token as escrow; on the first swap at or after a finalized dividend's pay date the hook `donate`s it to in-range liquidity and settles from its own balance; never pays the same dividend twice; skips (keeps escrow) when the pool has no liquidity. **Caveat:** pays in-range LPs at the flush, not holders of record on the record date; a snapshot + claim design is future work and is stated in the NatSpec. |
| `src/CorporateActionHook.sol` | First NEO hook. Permissions `BEFORE_SWAP \| BEFORE_ADD_LIQUIDITY`. A pool bound to a symbol refuses swaps and new liquidity while halted, and from a split or rename's effective time until the pool operator `acknowledge`s it. Removing liquidity is never blocked. Exposes `label()` and `tradeStatus(poolKey)` → `(Unknown \| Ok \| Refused, reason, effective)`. |

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

Tests (86 across six suites) cover every hook's permission mask via address mining, reverts through `CustomRevert.WrappedError`, tradeStatus in every state, the per-symbol event index, signature and bond checks, nonce replay, the dispute window, both resolve outcomes, on-chain Merkle root against a reference tree with proofs for every leaf (and forged/misindexed proofs failing), hook address mining, halt blocking swap and add-liquidity but not remove, split blocking until acknowledged, dividends never blocking, and unbound pools being inert.

## Run it locally

```bash
scripts/dev.sh
```

Starts Anvil on `:8545`, deploys a complete environment (`script/DeployLocal.s.sol`: PoolManager, Tape, CorporateActionHook at a mined address, mock ALFA and USDG tokens, one hooked pool with liquidity, an attester, three posted events) and serves the console at `http://127.0.0.1:5173`. `scripts/dev.sh stop` tears it down.

The console (`app/index.html`, viem) is a working surface for every role:

- **Tape** — finalized count, `eventsRoot()`, dispute window, bonds; read any symbol's halt state and last action.
- **Post an event** — the attester signs the EIP-712 `Event` in their wallet; anyone posts it with the bond.
- **Events** — every posted event with status and window countdown; challenge, finalize, and reviewer uphold/reject inline.
- **Hook** — the sample pool's bound symbol, operator and acknowledgement; "Try a swap" / "Try adding liquidity" show exactly what the hook does under the current Tape state; operator acknowledge after a split.
- **Can I trade now?** — `hook.tradeStatus(poolKey)` as a badge: **Ok**, **Refused** (halted, or a split/rename in effect and not acknowledged, with the effective time) or **Unknown** (the symbol has no attester, so no data source). Unknown is never Ok. Read before sending anything; the same view is what an MCP tool or router should call.
- **Calendar** — every event ever posted for the symbol (`tape.eventsOf`), sorted by effective date: what it is, what it does to the pool, "in effect" or countdown, status, dispute-window countdown for open ones; rejected events stay in the list struck through.
- **Create a stock pool** — check two tokens, initialize a Uniswap v4 pool with the NEO hook at a chosen price, bind it to a symbol (you become its operator), then add liquidity (local test router locally; the Uniswap app with the hook preset on Robinhood Chain).
- **Decode any hook address** — the 14 permission bits.

Use a browser wallet pointed at `127.0.0.1:8545` (chain 31337), or pick a Dev signer in the header: Anvil's well-known test accounts for reviewer, attester, pool operator and challenger. The dispute window is 45 seconds locally.

## Chains

| | Chain ID | RPC (public, rate-limited) | Explorer |
|---|---|---|---|
| Robinhood Chain | 4663 | `https://rpc.mainnet.chain.robinhood.com` | robinhoodchain.blockscout.com |
| Robinhood Chain Testnet | 46630 | `https://rpc.testnet.chain.robinhood.com` | explorer.testnet.chain.robinhood.com · faucet.testnet.chain.robinhood.com |

Uniswap v4 `PoolManager` is at `0x8366a39CC670B4001A1121B8F6A443A643e40951` on both. The console (`app/`) has a chain selector and loads `app/deployments.<chainId>.json`; a chain without that file shows the deploy command instead.

## Service layer

Hooks only run inside swaps and liquidity calls; the Tape only changes when someone sends a transaction. The service layer is what makes NEO run without anyone clicking.

| Package | What it does |
|---|---|
| `operator/` | **Operator daemon.** Watches pending events and finalizes each one the moment its dispute window closes; optionally posts attester-signed events from a feed file. Simulates before sending, skips when gas is above a cap, never holds user funds. Records every run and heartbeats to the API. `NEO_CHAIN=46630 NEO_OPERATOR_KEY=0x… NEO_API_KEY=… node operator/operator.mjs`. Anyone can run one; the Tape's own rules are the policy. |
| `api/` | **Indexer API** at `/v1`: `tape`, `events`, `symbols/:sym`, `symbols/:sym/actions`, `pools`, `pools/:id`, `POST trade-status`, `runs` (with 24h stats), `operators` (with liveness), `stream` (SSE), `POST webhooks` (HMAC-SHA256 signed, `x-neo-signature: t=…,v1=…`), and `POST tx/finalize|challenge|acknowledge` which return `{to,data,value}` for the user's wallet. Reads need no key, 300 req/min per IP; writes need `x-api-key`. Every answer carries `chainId`, `block`, `timestamp`, `indexedTo`. |
| `sdk/` | **`@neo/sdk` and `neo` CLI** on viem: `tape()`, `symbol()`, `actions()`, `event()`, `tradeStatus()`, `pool()`, `Neo.decodePermissions()`, `tx.*` encoders and `typedData.event()` for attesters. Signs nothing. |
| `mcp/` | **MCP server** for agents (below). |

Console's **Control room** panel reads the API: runs and success rate over 24h, operators alive, indexed block, and a live SSE feed. Point it at another API with `?api=https://…/v1`.

## Agents and integrators

- **MCP server** (`mcp/server.mjs`, stdio, read-only): `equity_halt_status`, `equity_actions`, `equity_trade_status`, `equity_tape`, `hook_permissions`. Every answer carries `chainId`, `block`, `timestamp`. `cd mcp && npm i && NEO_CHAIN=46630 node server.mjs`; `node test-client.mjs` exercises all tools against a local chain.
- **Skill file** for agents: [`app/agents/SKILL.md`](app/agents/SKILL.md). Rule one: read `tradeStatus` before quoting a stock-token pool; `unknown` is never `ok`.
- **Attesters**: [`docs/attesters.md`](docs/attesters.md) — how an issuer signs events and what happens after.

## Hosting

`deploy/` has Dockerfiles and Fly configs for the API (`neo-api`, persistent volume for the run ledger) and an operator (`neo-operator`); secrets are `NEO_API_KEY`, `NEO_OPERATOR_KEY`, optional `NEO_RPC` for a provider endpoint. `e2e/console.spec.mjs` clicks through the console in headless Chromium against the local stack.

`app/` is static. `.github/workflows/pages.yml` publishes it to GitHub Pages on every push to `main` that touches `app/`. Commit the `deployments.<chainId>.json` files you want the public console to use.

## Deploy

```bash
cp .env.example .env   # PRIVATE_KEY, RPC_URL; defaults target testnet 46630
set -a; source .env; set +a
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
forge verify-contract <tape> src/Tape.sol:Tape --verifier blockscout --verifier-url $VERIFIER_URL --chain-id 46630
```

`Deploy.s.sol` deploys the Tape, mines a CREATE2 salt so the hook's address carries exactly `BEFORE_SWAP | BEFORE_ADD_LIQUIDITY`, deploys the hook against the chain's `PoolManager`, and writes `app/deployments.<chainId>.json`. Optional `ATTESTER` + `SYMBOL` set a first attester in the same run.

## Status

Nothing here is deployed or audited. Example tickers in tests are placeholders. NEO is independent and not affiliated with Robinhood, Uniswap, Arbitrum, Hookr or What The Hook.
