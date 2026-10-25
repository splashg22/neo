#!/usr/bin/env node
// NEO operator — the keeper role the Tape was designed for.
// Watches pending events and finalizes them the moment their dispute window closes;
// optionally posts attester-signed events from a feed file; heartbeats and records every run to the API.
// Policy is on-chain: finalize() cannot apply anything the Tape would not accept; the operator holds no user funds.
//
//   NEO_CHAIN=31337 NEO_OPERATOR_KEY=0x... NEO_API_KEY=dev node operator/operator.mjs
//   optional: NEO_FEED=operator/feed.json  (array of {event:{symbol,kind,effective,value,nonce}, signature})
//
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createPublicClient, createWalletClient, http, parseAbi, stringToHex, hexToString } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const here = dirname(fileURLToPath(import.meta.url)); const root = join(here, '..');
const CHAINS = JSON.parse(readFileSync(join(root, 'app/chains.json'), 'utf8'));
const chainId = process.env.NEO_CHAIN || '31337'; const C = CHAINS[chainId];
const D = JSON.parse(readFileSync(join(root, 'app', C.deployments), 'utf8'));
const API = process.env.NEO_API || 'http://127.0.0.1:8787/v1'; const API_KEY = process.env.NEO_API_KEY || '';
const KEY = process.env.NEO_OPERATOR_KEY; if (!KEY) { console.error('NEO_OPERATOR_KEY required'); process.exit(1); }
const MAX_GAS_PRICE = BigInt(process.env.NEO_MAX_GAS_PRICE_WEI || 2_000_000_000); // 2 gwei: do not run when the chain is expensive
const NAME = process.env.NEO_OPERATOR_NAME || 'neo-operator';

const account = privateKeyToAccount(KEY);
const chain = { id: Number(chainId), name: C.name, nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [process.env.NEO_RPC || C.rpc] } } };
const pub = createPublicClient({ chain, transport: http(chain.rpcUrls.default.http[0]) });
const wallet = createWalletClient({ chain, transport: http(chain.rpcUrls.default.http[0]), account });
const TAPE = parseAbi([
  'function disputeWindow() view returns (uint64)', 'function postBond() view returns (uint256)', 'function eventsOf(bytes32) view returns (bytes32[])',
  'function pending(bytes32) view returns (((bytes32 symbol, uint8 kind, uint64 effective, uint256 value, uint64 nonce) e, address poster, address challenger, uint64 postedAt, uint8 status))',
  'function finalize(bytes32)', 'function post((bytes32 symbol, uint8 kind, uint64 effective, uint256 value, uint64 nonce), bytes) payable returns (bytes32)', 'function leafOf((bytes32 symbol, uint8 kind, uint64 effective, uint256 value, uint64 nonce)) pure returns (bytes32)',
  'event Posted(bytes32 indexed id, bytes32 indexed symbol, uint8 kind, address poster)',
]);
const str = h => { try { return hexToString(h, { size: 32 }).replace(/\0+$/, ''); } catch { return h; } };
const b32 = s => stringToHex(s.slice(0, 32), { size: 32 });
const log = (...a) => console.log(new Date().toISOString(), ...a);
const api = async (path, body) => { try { const r = await fetch(API + path, { method: 'POST', headers: { 'content-type': 'application/json', 'x-api-key': API_KEY }, body: JSON.stringify(body) }); return r.ok; } catch { return false; } };
const record = (run) => api('/runs', { operator: account.address, name: NAME, chainId: Number(chainId), ...run });

const window = Number(await pub.readContract({ address: D.tape, abi: TAPE, functionName: 'disputeWindow' }));
log(`operator ${account.address} on ${C.name}; tape ${D.tape}; window ${window}s`);

async function pendingIds() {
  const logs = await pub.getLogs({ address: D.tape, event: TAPE.find(x => x.name === 'Posted'), fromBlock: 0n });
  const out = [];
  for (const l of logs) { const p = await pub.readContract({ address: D.tape, abi: TAPE, functionName: 'pending', args: [l.args.id] }); if (p.status === 1) out.push({ id: l.args.id, ...p }); }
  return out;
}

let busy = false; const inflight = new Set();
async function tick() {
  if (busy) return; busy = true;
  try { await _tick(); } finally { busy = false; }
}
async function _tick() {
  const gas = await pub.getGasPrice(); if (gas > MAX_GAS_PRICE) { log('gas', gas, '> cap, skipping'); return; }
  const block = await pub.getBlock(); const now = Number(block.timestamp);
  let ranOne = false;
  for (const p of await pendingIds()) {
    const closes = Number(p.postedAt) + window; if (now < closes || inflight.has(p.id)) continue;
    inflight.add(p.id);
    const t0 = Date.now();
    try {
      const sim = await pub.simulateContract({ address: D.tape, abi: TAPE, functionName: 'finalize', args: [p.id], account });
      const hash = await wallet.writeContract(sim.request); const rc = await pub.waitForTransactionReceipt({ hash });
      ranOne = true; log('finalized', str(p.e.symbol), ['', 'split', 'dividend', 'halt', 'rename'][p.e.kind], hash, rc.status);
      await record({ task: 'finalize', id: p.id, symbol: str(p.e.symbol), kind: p.e.kind, tx: hash, ok: rc.status === 'success', gasUsed: rc.gasUsed.toString(), ms: Date.now() - t0 });
    } catch (e) { log('finalize failed', p.id, e.shortMessage || e.message); await record({ task: 'finalize', id: p.id, symbol: str(p.e.symbol), ok: false, error: (e.shortMessage || e.message).slice(0, 200), ms: Date.now() - t0 }); }
    finally { inflight.delete(p.id); }
  }
  // feed: attester-signed events waiting to be posted
  const feed = process.env.NEO_FEED && existsSync(process.env.NEO_FEED) ? JSON.parse(readFileSync(process.env.NEO_FEED, 'utf8')) : [];
  for (const item of feed) {
    const e = { symbol: b32(item.event.symbol), kind: Number(item.event.kind), effective: BigInt(item.event.effective), value: BigInt(item.event.value), nonce: BigInt(item.event.nonce) };
    const id = await pub.readContract({ address: D.tape, abi: TAPE, functionName: 'leafOf', args: [e] });
    const p = await pub.readContract({ address: D.tape, abi: TAPE, functionName: 'pending', args: [id] }); if (p.status !== 0) continue; // already posted
    const t0 = Date.now();
    try {
      const bond = await pub.readContract({ address: D.tape, abi: TAPE, functionName: 'postBond' });
      const sim = await pub.simulateContract({ address: D.tape, abi: TAPE, functionName: 'post', args: [e, item.signature], value: bond, account });
      const hash = await wallet.writeContract(sim.request); const rc = await pub.waitForTransactionReceipt({ hash });
      ranOne = true; log('posted', item.event.symbol, item.event.kind, hash, rc.status);
      await record({ task: 'post', id, symbol: item.event.symbol, kind: e.kind, tx: hash, ok: rc.status === 'success', gasUsed: rc.gasUsed.toString(), ms: Date.now() - t0 });
    } catch (e2) { log('post failed', item.event.symbol, e2.shortMessage || e2.message); await record({ task: 'post', id, symbol: item.event.symbol, ok: false, error: (e2.shortMessage || e2.message).slice(0, 200), ms: Date.now() - t0 }); }
  }
  await api('/operators/heartbeat', { address: account.address, name: NAME, lastBlock: Number(block.number), version: '0.1.0', ranOne });
}
await tick(); setInterval(() => tick().catch(e => log('tick', e.shortMessage || e.message)), Number(process.env.NEO_INTERVAL_MS || 5000));
