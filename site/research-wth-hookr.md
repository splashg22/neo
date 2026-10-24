# Research: What The Hook and Hookr (Robinhood Chain, chain 4663)
Compiled 2026-10-24 from their public sites and docs. Numbers are as published by each project.

## What The Hook (WTH)
**Product.** A Uniswap v4 hook that captures the arbitrage a user's own swap creates, in the same transaction, and redistributes it. Flow: swap moves pool A → route checker scans an admin-approved set of routes to pool B (incl. unhooked v3 pools) → proprietary ArbExecutor runs the correction trade (2 or 3 legs) and closes all balances atomically → payout ledger records shares, pays only from realized profit. Pool types: WTH's own pools; "integrating pools" (any v4 pool for the same asset vs USDG/ETH/WETH, ≥2 pools, hook attached at creation); stock-token/USDG pools (NVDA, SPCX, SNDK, AAPL, GOOGL, MU at 0.0375% and 0.1% tiers). 237 arbs over a 300k-block window, 10 three-pool.

**Economics.** WTH pools: 10% swapper / 90% treasury. Integrating pools: 10% referral + 40% treasury off the top; remainder 5% swapper / 45% LPs. Token 0xb8Fa…EfF79, fixed supply, no mint; supply figure not published. Value accrual = treasury revenue. Buybacks/burns panel exists but empty. Referrals negotiated, not permissionless.

**Deployments (4663).** Token 0xb8Fa8010833463Aac5595b55B9045479239EfF79; Hook v2 0x58A6eF29ddCdb064A72b550a78D84a8e065994C0 (live 5 Oct 2026); Hook v1 0xc52fc526…54c0 (Aug 2026, still live); ArbExecutor v2 0xF2Ca86F1…85aC; v1 0x2F4f6Dd5…aFB3; PositionFeeClaimer 0x82067B7E…B700; Safe 4-of-8 0x98c86816…cE59 (signers unnamed). GitHub README also lists Base and Arc deployments. Roadmap undated: Ethereum, every EVM chain, Hyperliquid L2, launchpad, agentic integration.

**Security.** Pashov Audit Group, 5–8 Oct 2026, scope only wthHOOKV2.sol; informational findings only; PDF image-only; audited repo now 404. Unaudited: executor (closed source), hook v1, fee claimer, token. Public repo is README-only.

**Traction.** As of 24 Oct 2026: $190,810 distributed over 69,383 distributions (treasury $110,161, swappers $27,061, LPs $28,862; itemized sum $166,084). Caveated as small, self-reported. TAM/SAM/SOM and 2030 scenarios labelled assumptions.

**Developer surface.** No SDK, no API. One long docs page, 26 sections (Protocol / Market / Strategy incl. SWOT, PESTLE, Ansoff / Reference). Tools: dashboard, 3-step zap to hook a token, calculator, arb-meter.

**Site.** Intro animation → hero "Arbitrage will always happen. We simply change where the value goes." + Audited-by badge → live metrics → partner marquee (Hookr, Shroom, Delta) → how it works (3) → split → user flow (4) → bring your own token → BUY NOW / docs → addresses with copy + explorer links. Terse, slogan-driven.

**Gaps.** Executor closed and unaudited; v1 still live; no token supply/distribution; anonymous 4-of-8 Safe approves routes; metric inconsistencies; no SDK/FAQ; no measured capture yield.

## Hookr
**Product.** Modular v4 hook infrastructure. Every pool names HookrRoot (flag suffix 0x2acc) as hook; "Hookr adds a hook, Uniswap holds the money." Launcher picks Hook Blocks in a builder; HookrLauncher deploys the token, HookrLane initializes 1–8 pools (one per quote: ETH, HOOKR, USDG, reviewed tokens, Robinhood stock tokens), configuration frozen for the pool's life. FamilyRouter splits trades across legs; FamilyLock holds dev principal to an unlock block. Owned roots: anyone deploys an unmodified HookrRoot copy.

**Hook Blocks (22+).** Core: Anti-Snipe, Dynamic fees, Auto Burn, LP Rewards, Creator royalty, King of the Pool, Wallet Cap. Launch-day: Arb recapture (WTH executor), Tax + Conversion, Buy/Sell Block, Market Guard (Chainlink ETH/USD only, no pool uses it), Market-hours fee (regular 0% / pre-after 0.2% / overnight 0.4% / closed 0.6%; only on stock-token pools; no pool uses it), Managed fee (keeper), Zap Relay, Pool Mesh, Swap Reward Mint, Revenue Router, Pay Later, Limit orders, Best route, Floor bid, Vesting Milestone, Entry Ratio Guarantee, Recovery reserve, Canonical Venue Token, Hook Blocks Market, Fee Bridge, Family Pinger. Soon: Usage fee, Exit Clock, Holder Pot, Storm Fee, Dev Drip, Referrals, Auction launches, Buyback & burn, Oracle Recorder.

**Economics.** Hookr takes 20% (default) to 50% of the protocol share of block fees, never the base LP fee. Hookr minimum 0.1% of each swap when nothing else pays Hookr. Arb recapture on new pools: WTH 25 / Hookr 25 / pool 50 (trader 25% of pool share, rest to in-range LPs). Hook Blocks Market: usage fee default 0.5%, split builder 45 / backers 25 / Hookr 20 / reserve 10; bonds 25k–250k HOOKR by risk tier. $HOOKR 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c, ~1B implied supply; listed MEXC, LBank, BitKan, Ourbit; burn counter "Loading…". Revenue tokens: lock a fee right → fixed-supply ERC-20; Hookr 0% if all on Hookr hook, else 5% of supply; live since 2026-10-19.

**Deployments (4663, hookr-1, commit 412960b).** 35 verified contracts incl. Registry 0x463c82be…4602, Treasury 0x2242F7FC…B4a9, Router 0xC2Bc9a3f…93C9, Quoter 0x445D7891…7865, Launcher 0x1cf2748A…8Ef4, HookrRoot 0x89c9FB50…6aCc, HookrRules 0x4a71c270…7942, HookrLane 0x9A8a1006…60BB, HookrRecapture 0xF83569E5…5583, FamilyRouter 0x854f3Fa7…E559, FamilyLock 0xfAFEcE64…e00b, RootFactory 0x21E438Fa…DCE4, OwnedRootFactory 0xA6c2a401…f3ec, Compliance/ComplianceGuard, FeeAdvisory, SessionAdvisory 0x78Bc6b73…66b1, LiquidityVault, Revenue Tokenizer 0xfb3c1501…12ef. Uniswap PoolManager 0x8366a39CC670B4001A1121B8F6A443A643e40951; Universal Router 0x88767899…0904. Tokens: USDG 0x5fc5360D…d168, NFLX 0xE0444EF8…91E8, AAPL 0xaF3D76f1…93f9. Only 4663 documented despite a 6-chain selector.

**Security.** "Hookr's contracts are unaudited. They have been adversarially reviewed, not externally audited." Submitted for audit. Source verified on RobinScan/Sourcify/Blockscout. Admin via ≥30-min timelock: admit blocks/partners/lanes/quotes, set minimum fee 0–1%, market calendar years; instant: revoke blocks, pause new pools, pause buyback. Keeper moves managed fee inside frozen bounds. Three Admin contracts with unstated key holders.

**Traction (API).** hooksCreated 63; lifetime pools 158; trades 87,593; launches 116; ≈159,473 ETH volume; 8 stock-quoted pools with 0 swaps; burned/TVL/traders null. Arb recapture: 22 pools, 5,328 recaptures. Methodology page: "unavailable is not zero", APR overstated, partial reads shown as ≥.

**Developer surface.** hookr-sdk 1.1.1 on viem, signs nothing, refuses drifted bytecode and unbounded swaps. MCP server at /api/mcp (8 read + 3 build tools, no auth). SKILL.md for agents. HookrScan decodes the 14 permission flags; Hook Score "Not scanned". APIs: /api/hooks/catalog, /api/protocol-stats, /api/pool-apr. ~60 docs pages.

**Site.** Nav → hero (headline, Launch with a hook / See live pools, token search, chain selector, root addresses) → announcement strip → More ways in → 22-block grid → Revenue Tokens → Running totals (all "Loading…") → New in Hookr → Who it's for (7 roles) → Building on Hookr (WTH, StonkBrokers, Uniswap live; 10 coming soon) → community posts → markets → FAQ → closing CTA with $HOOKR address. Tone: terse, engineering-precise, candid about limits.

**Tokenized stocks, specifically.**
- Halts: the stock token's own chain-wide pause/blocklist contract halts transfers, which halts every pool holding it; fail-closed. Hookr adds nothing of its own.
- Splits/corporate actions: handled by the token's ERC-8056 `uiMultiplier`, a display multiplier; "does not change pool math, tick spacing, or any Hook Block."
- Dividends: not mentioned anywhere.
- adminBurn: a privileged role can burn a holder's balance, so pool supply isn't fixed by the token contract.
- Market hours: the Market-hours fee block and an off-chain-fed "shared market calendar" with years added via timelock. No pool uses it.
- Stock price oracle: none; Market Guard is Chainlink ETH/USD only. StonkBrokers has an "oracle-anchored dynamic fee" hook for stock pools with no oracle named.
- Advice: put the stock on the quote side; keep auto burn off it.

**Gaps.** Unaudited with custody-adjacent blocks live; landing metrics never render; tokenized-stocks doc link 404s; no dividend handling; no stock-price oracle; stock-quoted pools have 0 swaps; arb recapture status contradicted between pages; admin key holders unstated; docs huge but thin on onboarding.
