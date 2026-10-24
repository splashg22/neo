# NEO — corporate actions for tokenized-equity pools (Robinhood Chain)

NEO records splits, dividends, halts and symbol changes for stock tokens as on-chain state (the Tape), and ships a Uniswap v4 hook that refuses swaps and new liquidity while a stock is halted or a split/rename is in effect and unacknowledged. Removing liquidity is never blocked.

## Chains
| chain | id | Tape / hook |
|---|---|---|
| Robinhood Chain | 4663 | see `deployments.4663.json` next to this file (absent = not deployed) |
| Robinhood Chain Testnet | 46630 | see `deployments.46630.json` |

Public RPCs: `https://rpc.mainnet.chain.robinhood.com`, `https://rpc.testnet.chain.robinhood.com` (rate-limited).

## Rules
1. **Read `tradeStatus` before quoting or routing a stock-token pool.** `unknown` is never `ok`. `refused` means the swap will revert.
2. **Never sign on the user's behalf.** Every NEO tool is read-only. Posting, challenging, finalizing and acknowledging are wallet actions the user takes in the console.
3. **Quote provenance.** Every answer carries `chainId`, `block` and `timestamp`; repeat them.
4. **Unavailable is not zero.** A symbol with no attester has no data; say so rather than "no events".

## Tools (MCP, stdio)
```
NEO_CHAIN=46630 node mcp/server.mjs
```
- `equity_halt_status(symbol)` → halted | trading | unknown
- `equity_actions(symbol, include=all|finalized|open)` → calendar of events with status and dispute window
- `equity_trade_status(currency0, currency1, fee, tickSpacing, hooks?)` → ok | refused(reason, effective) | unknown
- `equity_tape(symbol?)` → finalized count, Merkle root, dispute window, attester
- `hook_permissions(address)` → the 14 permission bits of any v4 hook

## Direct reads (no MCP)
- `Tape.isHalted(bytes32 symbol)`, `Tape.action(bytes32) → (kind, effective, value)`, `Tape.eventsOf(bytes32) → bytes32[]`, `Tape.pending(bytes32 id)`
- `CorporateActionHook.tradeStatus(PoolKey) → (0 unknown | 1 ok | 2 refused, bytes32 reason, uint64 effective)`
- Symbols are `bytes32(bytes("ALFA"))`. Split value is new shares per old share × 1e4; dividend value is cash per share in quote minor units; halt value 1/0; rename value is the new symbol as bytes32.
