# NEO hooks — specification for the remaining modules

All hooks follow `src/CorporateActionHook.sol`: extend `v4-periphery/src/utils/BaseHook.sol`, take `(IPoolManager, ITape)` in the constructor, keep per-pool state keyed by `PoolId`, use `bind(PoolKey, bytes32 symbol)` with first-caller-is-operator semantics, expose `label()` (plain words) and a `tradeStatus`-style view where it makes sense. Permissions must be exactly the flags each hook needs; tests mine the address with `HookMiner` and assert the mask. Tests use `v4-core/test/utils/Deployers.sol` like `test/CorporateActionHook.t.sol`, and must assert both the happy path and the revert through `CustomRevert.WrappedError` (see `_expectHookRevert` there).

Shared conventions
- Symbols: `bytes32(bytes("ALFA"))`. Tape reads: `tape.isHalted(sym)`, `tape.action(sym) -> (Kind, effective, value)`, `tape.hasAttester(sym)`.
- Never block `beforeRemoveLiquidity`: LPs can always leave.
- Operator-only setters are `onlyOperator(poolId)`; `NotOperator()` error.
- Fees returned from `_beforeSwap` use `LPFeeLibrary.OVERRIDE_FEE_FLAG` and require the pool to be initialized with the dynamic-fee flag (`LPFeeLibrary.DYNAMIC_FEE_FLAG` as `fee`). Tests must initialize such pools.
- Reference price: hooks that need one read `IReferencePrice(oracle).latest(bytes32 symbol) -> (uint160 sqrtPriceX96, uint64 updatedAt)`; define that interface in `src/interfaces/IReferencePrice.sol` and a `MockReferencePrice` in `src/test/`. A stale price (older than `maxAge`) is treated as absent.

## 1. LimitUpLimitDownHook — `src/hooks/LimitUpLimitDownHook.sol`
Permissions: `BEFORE_SWAP`.
- Per pool: `bandBps` (default 1000 = 10%), `maxAge` (default 15 min), `oracle` (IReferencePrice), symbol.
- `_beforeSwap`: if `tape.isHalted(sym)` revert `Halted(sym)`. Read reference price; if absent/stale, revert `NoReference(sym)` (unknown is never ok). Read pool's current `sqrtPriceX96` via `StateLibrary.getSlot0`. Compute the price ratio pool/reference in bps (square the sqrt ratio; use `FullMath`). If outside `[1e4-band, 1e4+band]` revert `OutsideBand(sym, poolBps, bandBps)`. Note: this checks the pre-swap price against the band; document that a post-swap check would need `AFTER_SWAP`.
- Operator setters: `setBand`, `setOracle`, `setMaxAge`.
- Tests: in band passes; halted reverts; stale oracle reverts; pool moved out of band (do a large swap on a pool without the hook? simpler: set oracle price far from pool price) reverts; operator-only.

## 2. EligibilityGateHook — `src/hooks/EligibilityGateHook.sol`
Permissions: `BEFORE_SWAP | BEFORE_ADD_LIQUIDITY`.
- Per pool: `IAllowlist allowlist` (interface `isAllowed(address) view returns (bool)`, define in `src/interfaces/IAllowlist.sol`, mock in `src/test/MockAllowlist.sol`), `gateSwaps` (bool), `gateLiquidity` (bool).
- The checked address: routers call hooks, so `sender` is the router. Accept the trader from `hookData` when it is exactly 20 bytes (`abi.encodePacked(address)`), otherwise fall back to `tx.origin`. Document this limitation in NatSpec.
- Revert `NotEligible(address)`.
- Tests: allowed address via hookData passes; disallowed via hookData reverts; empty hookData uses tx.origin (use `vm.prank(addr, addr)` to set both); operator can swap allowlist.

## 3. VolatilityFeeHook — `src/hooks/VolatilityFeeHook.sol`
Permissions: `BEFORE_SWAP | AFTER_SWAP`.
- Per pool: `baseFee` (e.g. 500 = 0.05%), `maxFee` (e.g. 10000 = 1%), `window` blocks, `eventBumpBps`, `eventBumpSeconds`.
- `_afterSwap`: record the tick delta of this swap (read `getSlot0` tick before in `_beforeSwap` via transient-style storage mapping, after in `_afterSwap`); keep an EWMA of absolute tick moves per pool.
- `_beforeSwap`: fee = baseFee + k * ewma, clamped to maxFee; additionally if `tape.action(sym).effective` is within `eventBumpSeconds` of `block.timestamp` (before or after), add `eventBumpBps`. Return with `OVERRIDE_FEE_FLAG`.
- Tests: first swap charges baseFee; after several large swaps fee rises and never exceeds maxFee; event within window bumps fee; pool must be dynamic-fee.

## 4. DividendPassThroughHook — `src/hooks/DividendPassThroughHook.sol`
Permissions: `BEFORE_SWAP` (used only as the trigger to flush) and none else; donation is done via `poolManager.donate` from inside the callback (the manager is unlocked during a swap).
- Per pool: symbol, quote currency (the non-stock side), `escrow` balance.
- `deposit(PoolKey, uint256 amount)`: anyone (the issuer / custodian) transfers quote tokens to the hook as escrow for the next dividend.
- `_beforeSwap`: if `tape.action(sym)` is `Kind.Dividend` with `effective <= block.timestamp` and the hook has not yet flushed for that `(effective, value)` and escrow > 0: call `poolManager.donate(key, amount0, amount1, "")` with the escrow on the quote side, then settle the donation: `key.currencyX.settle(poolManager, address(this), amount, false)` using `CurrencySettler` from `v4-core/test/utils/CurrencySettler.sol`. Mark flushed. Emit `DividendDistributed(poolId, effective, amount)`.
- Document clearly: donate goes to in-range liquidity at the moment of the flush, which is the first swap after pay date, not the record date; a snapshot-based version is future work.
- Tests: deposit, finalize dividend on the Tape, swap triggers donate (assert hook's token balance went to 0 and the LP's fee growth increased, e.g. by removing liquidity and checking balance delta), second swap does not donate again, no donate before pay date.

Each file compiles under `forge build` with the repo's `foundry.toml` and passes `forge test`. Keep NatSpec on every public function. Do not modify `src/Tape.sol`, `src/CorporateActionHook.sol`, or existing tests.
