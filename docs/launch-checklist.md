# Launch checklist

What exists, what is verified, and the decisions that stand between the repo and a live service on Robinhood Chain.

## Verified
- 108 Foundry tests across Tape, NeoHook, CorporateActionHook, LimitUpLimitDown, EligibilityGate, VolatilityFee, DividendPassThrough, all against a live Uniswap v4 PoolManager.
- Full lifecycle on a local chain: halt → refused swap → attested lift → challenge → uphold → swap → split → refused → acknowledge → swap.
- Service layer on a local chain: operator finalizes within one tick of the window closing; API, SSE, HMAC webhooks, SDK, MCP all agree with chain state.
- Console: 18 headless-Chromium checks, including "swap outcome matches the trade-status badge".

## Testnet (46630) — needs faucet ETH
- Deployer: `0xDF0874c81e4d5ff2dF7788Cb78499FE8209C2500` (key in `.env`, never committed). Faucet: https://faucet.testnet.chain.robinhood.com
- Then: `set -a; source .env; set +a; forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast`
- Verify: `forge verify-contract <addr> src/Tape.sol:Tape --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api --chain-id 46630` (repeat per contract).
- Commit `app/deployments.46630.json`; set `ATTESTER`/`SYMBOL` for a first test symbol; fund the reward pool with a little ETH; run one operator and the API against 46630.

## Public console — needs one GitHub action
- `.github/workflows/pages.yml` (on branch `pages-workflow`) must land on `main`. Either grant the `workflow` scope (`gh auth refresh -h github.com -s workflow`) or create the file in the GitHub UI. Pages is already set to the Actions source → https://splashg22.github.io/neo/
- The console's control room needs a public API URL: `?api=https://<host>/v1`.

## Hosting — needs an account
- `deploy/fly.api.toml` + `deploy/Dockerfile.api` (volume for the run ledger); `deploy/fly.operator.toml` + `deploy/Dockerfile.operator`. Secrets: `NEO_API_KEY`, `NEO_OPERATOR_KEY`, optional `NEO_RPC` (provider endpoint; the public RPC is rate-limited).

## Mainnet (4663) — decisions
| Decision | Default in code | Recommendation |
|---|---|---|
| Reviewer | deployer | a 2-of-3 Safe; `setReviewer` after deploy |
| Dispute window | 1 day | 1 day for halts is slow; consider per-kind windows (future change) |
| Post bond / challenge bond | 0.001 / 0.002 ETH | raise once real value trades; must exceed gas to challenge |
| Finalize reward | 0 | fund the pool and set ~2× typical finalize gas so operators run at a profit |
| First attester | none | the issuer or transfer agent of one tokenized stock; without one every pool reads `unknown` |
| Audit | none | required before any pool with real liquidity; Hookshade/Hookr are also unaudited, WTH partially |

## Known limitations (stated in NatSpec)
- Dividend pass-through pays in-range LPs at the first swap after pay date, not holders of record; snapshot + claim is future work. Escrow has no refund path yet.
- Eligibility gate trusts 20-byte `hookData` or `tx.origin`; a forwarding router can name any address.
- LULD checks the pre-swap price only.
- Volatility fee requires a dynamic-fee pool.
- `NeoHook` composes all five modules on one pool; the standalone hooks remain for pools that want exactly one.
