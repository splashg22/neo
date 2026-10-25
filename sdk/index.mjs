// @neo/sdk — typed reads and transaction encoding for NEO on Robinhood Chain. Signs nothing.
//
//   import { Neo } from '@neo/sdk';
//   const neo = await Neo.connect({ chainId: 46630 });
//   await neo.symbol('ALFA');                    // { status: 'trading'|'halted'|'unknown', lastAction, ... }
//   await neo.actions('ALFA');                   // calendar
//   await neo.tradeStatus(poolKey);              // { status: 'ok'|'refused'|'unknown', reason, effective }
//   neo.tx.finalize(id)  neo.tx.challenge(id, bond)  neo.tx.acknowledge(poolKey)   // { to, data, value } for your wallet
//   neo.typedData.event(e)                       // EIP-712 payload for an attester's wallet.signTypedData
//
import { createPublicClient, http, parseAbi, stringToHex, hexToString, keccak256, encodeAbiParameters, encodeFunctionData } from 'viem';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
export const CHAINS = JSON.parse(readFileSync(join(here, '..', 'app', 'chains.json'), 'utf8'));
export const TAPE_ABI = parseAbi([
  'function isHalted(bytes32) view returns (bool)', 'function action(bytes32) view returns (uint8,uint64,uint256)', 'function eventsRoot() view returns (bytes32)', 'function eventCount() view returns (uint256)',
  'function disputeWindow() view returns (uint64)', 'function postBond() view returns (uint256)', 'function challengeBond() view returns (uint256)', 'function hasAttester(bytes32) view returns (bool)', 'function attesterOf(bytes32) view returns (address)', 'function eventsOf(bytes32) view returns (bytes32[])',
  'function pending(bytes32) view returns (((bytes32 symbol, uint8 kind, uint64 effective, uint256 value, uint64 nonce) e, address poster, address challenger, uint64 postedAt, uint8 status))',
  'function verify(bytes32,uint256,bytes32[]) view returns (bool)', 'function leafOf((bytes32 symbol, uint8 kind, uint64 effective, uint256 value, uint64 nonce)) pure returns (bytes32)',
  'function post((bytes32 symbol, uint8 kind, uint64 effective, uint256 value, uint64 nonce), bytes) payable returns (bytes32)', 'function challenge(bytes32) payable', 'function finalize(bytes32)', 'function resolve(bytes32,bool)',
]);
export const HOOK_ABI = parseAbi([
  'function tradeStatus((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)) view returns (uint8,bytes32,uint64)',
  'function symbolOf(bytes32) view returns (bytes32)', 'function operatorOf(bytes32) view returns (address)', 'function acknowledged(bytes32) view returns (bytes32)', 'function label() view returns (string)',
  'function bind((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks), bytes32)', 'function acknowledge((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks))',
]);
export const Kind = { None: 0, Split: 1, Dividend: 2, Halt: 3, Rename: 4 };
const KINDS = ['none', 'split', 'dividend', 'halt', 'rename'], STATUS = ['unknown', 'pending', 'challenged', 'finalized', 'rejected'], TS = ['unknown', 'ok', 'refused'];
export const symbolToBytes32 = s => stringToHex(s.slice(0, 32), { size: 32 });
export const bytes32ToSymbol = h => { try { return hexToString(h, { size: 32 }).replace(/\0+$/, ''); } catch { return h; } };
export const poolIdOf = k => keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'address' }, { type: 'uint24' }, { type: 'int24' }, { type: 'address' }], [k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks]));

export class Neo {
  static async connect({ chainId, rpc, deployments } = {}) {
    const id = String(chainId || 46630); const c = CHAINS[id]; if (!c) throw new Error('unknown chain ' + id);
    const d = deployments || JSON.parse(readFileSync(join(here, '..', 'app', c.deployments), 'utf8'));
    return new Neo(id, c, d, createPublicClient({ transport: http(rpc || c.rpc) }));
  }
  constructor(chainId, chain, d, client) { this.chainId = Number(chainId); this.chain = chain; this.addresses = d; this.client = client;
    this.tx = {
      finalize: id => ({ to: d.tape, data: encodeFunctionData({ abi: TAPE_ABI, functionName: 'finalize', args: [id] }), value: 0n, chainId: this.chainId }),
      challenge: (id, bond) => ({ to: d.tape, data: encodeFunctionData({ abi: TAPE_ABI, functionName: 'challenge', args: [id] }), value: bond, chainId: this.chainId }),
      post: (e, sig, bond) => ({ to: d.tape, data: encodeFunctionData({ abi: TAPE_ABI, functionName: 'post', args: [e, sig] }), value: bond, chainId: this.chainId }),
      resolve: (id, correct) => ({ to: d.tape, data: encodeFunctionData({ abi: TAPE_ABI, functionName: 'resolve', args: [id, correct] }), value: 0n, chainId: this.chainId }),
      bind: (key, symbol) => ({ to: d.hook, data: encodeFunctionData({ abi: HOOK_ABI, functionName: 'bind', args: [key, symbolToBytes32(symbol)] }), value: 0n, chainId: this.chainId }),
      acknowledge: key => ({ to: d.hook, data: encodeFunctionData({ abi: HOOK_ABI, functionName: 'acknowledge', args: [key] }), value: 0n, chainId: this.chainId }),
    };
    this.typedData = { event: e => ({ domain: { name: 'NEO Tape', version: '1', chainId: this.chainId, verifyingContract: d.tape }, types: { Event: [{ name: 'symbol', type: 'bytes32' }, { name: 'kind', type: 'uint8' }, { name: 'effective', type: 'uint64' }, { name: 'value', type: 'uint256' }, { name: 'nonce', type: 'uint64' }] }, primaryType: 'Event', message: e }) };
  }
  _t(fn, args = []) { return this.client.readContract({ address: this.addresses.tape, abi: TAPE_ABI, functionName: fn, args }); }
  _h(fn, args = []) { return this.client.readContract({ address: this.addresses.hook, abi: HOOK_ABI, functionName: fn, args }); }
  async provenance() { const b = await this.client.getBlock(); return { chainId: this.chainId, block: Number(b.number), timestamp: Number(b.timestamp) }; }
  async tape() { const [c, r, w, pb, cb] = await Promise.all([this._t('eventCount'), this._t('eventsRoot'), this._t('disputeWindow'), this._t('postBond'), this._t('challengeBond')]); return { finalized: Number(c), eventsRoot: r, disputeWindowSeconds: Number(w), postBond: pb, challengeBond: cb, ...(await this.provenance()) }; }
  async symbol(sym) { const s = symbolToBytes32(sym); const [has, halted, a] = await Promise.all([this._t('hasAttester', [s]), this._t('isHalted', [s]), this._t('action', [s])]); return { symbol: sym, status: has ? (halted ? 'halted' : 'trading') : 'unknown', hasAttester: has, halted: has ? halted : null, lastAction: a[0] ? { kind: KINDS[a[0]], effective: Number(a[1]), value: a[2] } : null, ...(await this.provenance()) }; }
  async actions(sym) { const ids = await this._t('eventsOf', [symbolToBytes32(sym)]); const rows = await Promise.all(ids.map(async id => { const p = await this._t('pending', [id]); return { id, symbol: sym, kind: KINDS[p.e.kind], effective: Number(p.e.effective), value: p.e.value, nonce: Number(p.e.nonce), status: STATUS[p.status], poster: p.poster, challenger: p.challenger, postedAt: Number(p.postedAt) }; })); return rows.sort((x, y) => x.effective - y.effective); }
  async event(id) { const p = await this._t('pending', [id]); return { id, symbol: bytes32ToSymbol(p.e.symbol), kind: KINDS[p.e.kind], effective: Number(p.e.effective), value: p.e.value, nonce: Number(p.e.nonce), status: STATUS[p.status], poster: p.poster, challenger: p.challenger, postedAt: Number(p.postedAt) }; }
  async tradeStatus(key) { const k = { ...key, hooks: key.hooks || this.addresses.hook }; const [st, reason, eff] = await this._h('tradeStatus', [k]); return { poolId: poolIdOf(k), status: TS[st], reason: bytes32ToSymbol(reason), effective: eff ? Number(eff) : null, ...(await this.provenance()) }; }
  async pool(key) { const id = poolIdOf({ ...key, hooks: key.hooks || this.addresses.hook }); const [s, op, ack] = await Promise.all([this._h('symbolOf', [id]), this._h('operatorOf', [id]), this._h('acknowledged', [id])]); return { poolId: id, symbol: bytes32ToSymbol(s) || null, operator: op, acknowledged: ack }; }
  static decodePermissions(address) { const NAMES = ['BEFORE_INITIALIZE', 'AFTER_INITIALIZE', 'BEFORE_ADD_LIQUIDITY', 'AFTER_ADD_LIQUIDITY', 'BEFORE_REMOVE_LIQUIDITY', 'AFTER_REMOVE_LIQUIDITY', 'BEFORE_SWAP', 'AFTER_SWAP', 'BEFORE_DONATE', 'AFTER_DONATE', 'BEFORE_SWAP_RETURNS_DELTA', 'AFTER_SWAP_RETURNS_DELTA', 'AFTER_ADD_LIQUIDITY_RETURNS_DELTA', 'AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA']; const mask = parseInt(address.slice(-4), 16) & 0x3fff; return { mask, permissions: NAMES.filter((_, i) => mask >> (13 - i) & 1) }; }
}
