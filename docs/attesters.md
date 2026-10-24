# Becoming an attester

An attester is the address allowed to sign corporate-action events for one symbol. The Tape accepts an event only with the attester's EIP-712 signature; anyone may then post it with a bond, and anyone may challenge it during the dispute window.

## Who should be an attester
The issuer of the tokenized stock, its transfer agent, or a data provider the issuer designates. One address per symbol; the reviewer can rotate it.

## Setup
1. Give the reviewer your signing address. The reviewer calls `Tape.setAttester(bytes32("TICKER"), attester)`. Until then `hasAttester` is false and every reader reports **unknown** for the symbol.
2. Keep the key in a signer that supports EIP-712 (hardware wallet, KMS, or the console's wallet flow).

## Signing an event
Domain: `{ name: "NEO Tape", version: "1", chainId, verifyingContract: <Tape> }`
Type: `Event(bytes32 symbol, uint8 kind, uint64 effective, uint256 value, uint64 nonce)`

| kind | meaning | value |
|---|---|---|
| 1 Split | new shares per old share | ratio × 1e4 (4-for-1 = 40000; 1-for-10 reverse = 1000) |
| 2 Dividend | cash per share | quote-asset minor units (cents for USDG) |
| 3 Halt | trading halt on/off | 1 or 0 |
| 4 Rename | symbol change | new symbol as bytes32 |

`effective` is the unix time the action takes effect (ex-date for a split, pay date for a dividend, now for a halt). `nonce` must be unique per symbol; reuse reverts.

## Lifecycle after you sign
- Anyone posts the signed event with `postBond`. The console does this in one click after signing.
- Dispute window (`disputeWindow()` seconds). Anyone bonded may challenge against the public filing.
- Unchallenged → `finalize()` applies it: `isHalted` / `action` update, a leaf is appended to `eventsRoot()`.
- Challenged → the reviewer resolves. Correct event: finalized, challenger's bond to the poster. Wrong event: rejected, poster's bond to the challenger.

## What hooks do with it
- **Halt on** → pools bound to the symbol refuse swaps and new liquidity. **Halt off** → trading resumes.
- **Split / Rename** → from `effective`, pools refuse swaps and new liquidity until the pool operator calls `acknowledge()` after re-pricing or migrating liquidity.
- **Dividend** → informational today; the dividend pass-through hook will route cash to in-range positions on the record date.

## Responsibilities
Post promptly, post once, and keep the effective time exactly as filed. A wrong event costs the poster their bond; a pattern of wrong events gets the attester rotated.
