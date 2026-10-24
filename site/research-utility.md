# Utility study: what users can actually do on each Robinhood Chain hook project
Compiled 2026-10-24 from the live sites and docs. Companion to `research-wth-hookr.md`.

## Hookshade
- **Trader (/shade):** connect wallet per transaction → create a browser-only "shade account" → cast into a 2-block batch on the one seeded WETH/USDG market → anyone settles → collect. Shielded path via Groth16. The page replays settlement math in-browser as proof.
- **Watcher (/hooks):** browser-side price alerts polled by multicall; no wallet, nothing on-chain. Not v4 hooks despite the name.
- **LP / launcher / developer / agent:** nothing. "The shade is the sole LP." No SDK, API or MCP (roadmap Q1 2027).
- **Honesty devices:** every figure block-stamped; "What is actually real" status table; privacy section lists what remains visible; stateless wallet connection.
- **Usage:** 3 batches, 4 casts ever. Fee display bugs on /shade.

## AMLIL
- **Console (/app.html):** quote best route ETH↔USDG across native/hooked/external pools; swap via Universal Router from own wallet; optional "private mode" through a third-party mixer-style flow (2–3% fee). "Proof of savings" and "Buy $AMLIL" link to `#`.
- **Pool check:** `GET /api/pools/{token}` lists every v4 pool for a token with hook kind, liquidity, quote, flags, "best" marker.
- **Hooks registry:** 184 hooks scored 0–100; full list behind an x402 paywall (0.001 USDG/call). Hook authors earn nothing yet.
- **Agent surface:** OpenAPI 3.1 with x402 blocks, `llms.txt`, pay-per-call via EIP-3009 USDG with a self-hosted facilitator. No MCP, no SDK.
- **Token:** daily buyback-and-burn only; 2 burns so far. Lifetime x402 revenue 0.085 USDG, mostly self-paid.
- **Gaps:** landing stats hardcoded to 0; /docs and /console 404; single Vercel node; no audit.

## What The Hook
- **Dashboard:** payout counters, arbitrage volume, buybacks ledger, LP rewards panel, live arbitrage feed. Most counters render blank in HTML.
- **Use our hook (/dashboard/hook):** 3-step wizard: paste token → deposit ETH only (zap) → confirm, sign once. Hook and tick spacing preset.
- **Calculator / arb-meter:** what-if capture yield; how much outside bots extracted from any token's pools.
- **Trader:** nothing to do; rebate arrives in the same tx. **Launcher:** create two pools with the hook attached; auto-detected. **Developer / agent:** nothing.

## Hookr
- **Discover:** pools/hooks/tokens/revenue tokens, filters by block, block-pinned coverage note, impostor-token flags, "unavailable is not zero".
- **Builder:** 42 Hook Blocks, 163 parameters, bounds enforced; exits to launch, open pools for an existing token, save hook, deploy own root.
- **Launch:** details → hook → 1–8 pools → dry-run exact ETH and allowances → sign one tx. Everything frozen for the pool's life.
- **HookrScan:** reads any hook's 14 permission bits; "Automated screening, not an audit"; Hook Score unimplemented.
- **Portfolio:** positions, add LP (PositionManager), returns, claims. "Nothing is signed by connecting."
- **Agents:** SKILL.md under 8 KB, MCP at /api/mcp with 8 read + 3 build tools (build, never sign), `check_trade` tri-state.
- **Anti-patterns:** counters that never load, "Deploying soon" in nav, contradictory statuses across pages.

## What none of them offer, and what NEO's console does or should
Nobody surfaces the equity lifecycle. Hookr notes the ERC-8056 display multiplier changes nothing in pool math; halts come from the token's pause registry; dividends are not mentioned anywhere.

Implemented in `app/` (local chain today):
1. Tape explorer: event count, Merkle root, dispute window, bonds, per-symbol halt and last action.
2. Post flow: attester signs EIP-712 in the wallet, anyone posts with bond; challenge, finalize, reviewer uphold/reject from the event table.
3. Pool panel: bound symbol, operator, acknowledgement state; one-click "try a swap" / "try adding liquidity" that shows the exact hook revert under current Tape state; operator acknowledge.
4. Permission decoder for any hook address.

Next, in order of user value:
5. Per-symbol corporate-action calendar with countdown to effective time, block-pinned.
6. "Can I trade now?" tri-state (ok / refused / unknown) driven by halt and pending actions, as a view and as an MCP tool.
7. Pre-trade quote showing post-split or ex-dividend adjusted price, with "re-bases at block N" warning.
8. LP range re-centering preview for splits and one-click migrate.
9. Dividend claim ledger per position (claimable / claim).
10. Rename tracker with impostor-token flags.
11. SKILL.md and MCP tools: `equity_actions`, `equity_halt_status`, `equity_adjust_quote`, `equity_build_claim`; build, never sign.
12. Status table in the Hookshade register: every number says live / deployed / computed, and "unavailable is not zero".
