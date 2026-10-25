#!/usr/bin/env node
// NEO indexer API — reads for symbols, actions, pools, runs and operators; SSE stream; signed webhooks.
// Reads need no key. Webhook registration needs x-api-key. Nothing here signs anything.
//
//   NEO_CHAIN=31337 NEO_API_KEY=dev node api/server.mjs          → http://127.0.0.1:8787/v1
//
import http from 'node:http';
import { createHmac, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createPublicClient, http as viemHttp, parseAbi, stringToHex, hexToString, keccak256, encodeAbiParameters, encodeFunctionData } from 'viem';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const CHAINS = JSON.parse(readFileSync(join(root, 'app/chains.json'), 'utf8'));
const chainId = process.env.NEO_CHAIN || '31337';
const C = CHAINS[chainId]; if (!C) { console.error('unknown chain', chainId); process.exit(1); }
const D = JSON.parse(readFileSync(join(root, 'app', C.deployments), 'utf8'));
const PORT = Number(process.env.NEO_API_PORT || 8787);
const API_KEY = process.env.NEO_API_KEY || '';
const DATA = join(root, 'api', 'data', chainId); mkdirSync(DATA, { recursive: true });
const store = name => { const f = join(DATA, name + '.json'); return { read: () => existsSync(f) ? JSON.parse(readFileSync(f, 'utf8')) : [], write: v => writeFileSync(f, JSON.stringify(v, null, 1)) }; };
const runsStore = store('runs'), opsStore = store('operators'), hooksStore = store('webhooks');

const pub = createPublicClient({ transport: viemHttp(process.env.NEO_RPC || C.rpc) });
const TAPE = parseAbi([
  'function isHalted(bytes32) view returns (bool)', 'function action(bytes32) view returns (uint8,uint64,uint256)',
  'function eventsRoot() view returns (bytes32)', 'function eventCount() view returns (uint256)', 'function disputeWindow() view returns (uint64)',
  'function postBond() view returns (uint256)', 'function challengeBond() view returns (uint256)', 'function hasAttester(bytes32) view returns (bool)', 'function attesterOf(bytes32) view returns (address)',
  'function pending(bytes32) view returns (((bytes32 symbol, uint8 kind, uint64 effective, uint256 value, uint64 nonce) e, address poster, address challenger, uint64 postedAt, uint8 status))',
  'function finalize(bytes32)', 'function challenge(bytes32)', 'function post((bytes32 symbol, uint8 kind, uint64 effective, uint256 value, uint64 nonce), bytes)',
  'event Posted(bytes32 indexed id, bytes32 indexed symbol, uint8 kind, address poster)', 'event Challenged(bytes32 indexed id, address challenger)',
  'event Finalized(bytes32 indexed id, bytes32 indexed symbol, uint256 index, bytes32 root, address poster)', 'event Rejected(bytes32 indexed id, address challenger)',
]);
const HOOK = parseAbi([
  'function tradeStatus((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)) view returns (uint8,bytes32,uint64)',
  'function symbolOf(bytes32) view returns (bytes32)', 'function operatorOf(bytes32) view returns (address)', 'function acknowledged(bytes32) view returns (bytes32)',
  'function acknowledge((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks))', 'function label() view returns (string)',
  'event Bound(bytes32 indexed poolId, bytes32 symbol, address operator)', 'event Acknowledged(bytes32 indexed poolId, bytes32 actionHash)',
]);
const KINDS = ['none', 'split', 'dividend', 'halt', 'rename'], STATUS = ['unknown', 'pending', 'challenged', 'finalized', 'rejected'], TS = ['unknown', 'ok', 'refused'];
const b32 = s => stringToHex(s.slice(0, 32), { size: 32 });
const str = h => { try { return hexToString(h, { size: 32 }).replace(/\0+$/, ''); } catch { return h; } };
const J = (o) => JSON.stringify(o, (_, v) => typeof v === 'bigint' ? v.toString() : v);

// ------------------------------------------------------------------ index
const index = { events: new Map(), pools: new Map(), lastBlock: 0n, symbols: new Set() };
const subscribers = new Set();
function emit(type, data) { const msg = { id: randomUUID(), type, at: Date.now(), chainId: Number(chainId), data }; for (const res of subscribers) res.write(`event: ${type}\ndata: ${J(msg)}\n\n`); dispatchWebhooks(msg).catch(() => {}); }
async function refreshEvent(id) {
  const p = await pub.readContract({ address: D.tape, abi: TAPE, functionName: 'pending', args: [id] });
  const e = { id, symbol: str(p.e.symbol), kind: KINDS[p.e.kind], effective: Number(p.e.effective), value: p.e.value.toString(), nonce: Number(p.e.nonce), status: STATUS[p.status], poster: p.poster, challenger: p.challenger === '0x0000000000000000000000000000000000000000' ? null : p.challenger, postedAt: Number(p.postedAt) };
  index.events.set(id, e); index.symbols.add(e.symbol); return e;
}
async function sync() {
  const head = await pub.getBlockNumber(); if (head <= index.lastBlock) return;
  const from = index.lastBlock === 0n ? 0n : index.lastBlock + 1n;
  const [posted, challenged, finalized, rejected, bound, acked] = await Promise.all(
    ['Posted', 'Challenged', 'Finalized', 'Rejected'].map(n => pub.getLogs({ address: D.tape, event: TAPE.find(x => x.name === n), fromBlock: from, toBlock: head }))
      .concat(['Bound', 'Acknowledged'].map(n => pub.getLogs({ address: D.hook, event: HOOK.find(x => x.name === n), fromBlock: from, toBlock: head }))));
  for (const l of posted) emit('event.posted', await refreshEvent(l.args.id));
  for (const l of challenged) emit('event.challenged', await refreshEvent(l.args.id));
  for (const l of finalized) emit('event.finalized', { ...(await refreshEvent(l.args.id)), index: Number(l.args.index), root: l.args.root, tx: l.transactionHash });
  for (const l of rejected) emit('event.rejected', await refreshEvent(l.args.id));
  for (const l of bound) { index.pools.set(l.args.poolId, { poolId: l.args.poolId, symbol: str(l.args.symbol), operator: l.args.operator, boundAt: Number(l.blockNumber) }); emit('pool.bound', index.pools.get(l.args.poolId)); }
  for (const l of acked) { const p = index.pools.get(l.args.poolId) || { poolId: l.args.poolId }; p.acknowledged = l.args.actionHash; p.acknowledgedAt = Number(l.blockNumber); index.pools.set(l.args.poolId, p); emit('pool.acknowledged', p); }
  index.lastBlock = head;
}
await sync(); setInterval(() => sync().catch(e => console.error('sync', e.message)), 3000);

// ------------------------------------------------------------------ webhooks
async function dispatchWebhooks(msg) {
  for (const w of hooksStore.read()) {
    if (w.events?.length && !w.events.includes(msg.type)) continue;
    const body = J(msg); const ts = Math.floor(Date.now() / 1000); const sig = createHmac('sha256', w.secret).update(ts + '.' + body).digest('hex');
    fetch(w.url, { method: 'POST', headers: { 'content-type': 'application/json', 'x-neo-signature': `t=${ts},v1=${sig}` }, body }).catch(() => {});
  }
}

// ------------------------------------------------------------------ http
const rateBucket = new Map();
function rateLimited(ip) { const now = Date.now(); const b = rateBucket.get(ip) || []; const recent = b.filter(t => now - t < 60_000); recent.push(now); rateBucket.set(ip, recent); return recent.length > 300; }
const send = (res, code, body) => { res.writeHead(code, { 'content-type': 'application/json', 'access-control-allow-origin': '*', 'access-control-allow-headers': 'content-type,x-api-key' }); res.end(J(body)); };
const provenance = async () => { const b = await pub.getBlock(); return { chainId: Number(chainId), block: Number(b.number), timestamp: Number(b.timestamp), indexedTo: Number(index.lastBlock) }; };
const readBody = req => new Promise(r => { let s = ''; req.on('data', c => s += c); req.on('end', () => { try { r(JSON.parse(s || '{}')); } catch { r({}); } }); });
const page = (arr, q) => { const limit = Math.min(Number(q.get('limit') || 50), 200); const cursor = Number(q.get('cursor') || 0); return { items: arr.slice(cursor, cursor + limit), nextCursor: cursor + limit < arr.length ? cursor + limit : null, total: arr.length }; };

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x'); const p = url.pathname.replace(/\/$/, ''); const q = url.searchParams;
  if (req.method === 'OPTIONS') return send(res, 204, {});
  if (rateLimited(req.socket.remoteAddress)) return send(res, 429, { error: 'rate limited: 300 req/min per IP' });
  try {
    if (p === '/v1' || p === '/v1/health') return send(res, 200, { name: 'neo-api', version: '0.1.0', chain: C.name, tape: D.tape, hook: D.hook, ...(await provenance()), subscribers: subscribers.size });
    if (p === '/v1/tape') { const [count, root, win, pb, cb, label] = await Promise.all([pub.readContract({ address: D.tape, abi: TAPE, functionName: 'eventCount' }), pub.readContract({ address: D.tape, abi: TAPE, functionName: 'eventsRoot' }), pub.readContract({ address: D.tape, abi: TAPE, functionName: 'disputeWindow' }), pub.readContract({ address: D.tape, abi: TAPE, functionName: 'postBond' }), pub.readContract({ address: D.tape, abi: TAPE, functionName: 'challengeBond' }), pub.readContract({ address: D.hook, abi: HOOK, functionName: 'label' })]); return send(res, 200, { finalized: Number(count), eventsRoot: root, disputeWindowSeconds: Number(win), postBond: pb, challengeBond: cb, hookLabel: label, symbols: [...index.symbols], ...(await provenance()) }); }
    if (p === '/v1/events') { let arr = [...index.events.values()]; if (q.get('status')) arr = arr.filter(e => e.status === q.get('status')); if (q.get('symbol')) arr = arr.filter(e => e.symbol === q.get('symbol')); arr.sort((a, b) => b.postedAt - a.postedAt); return send(res, 200, { ...page(arr, q), ...(await provenance()) }); }
    let m;
    if ((m = p.match(/^\/v1\/symbols\/([A-Za-z0-9.\-]+)$/))) { const sym = m[1], s = b32(sym); const [has, halted, a, att] = await Promise.all([pub.readContract({ address: D.tape, abi: TAPE, functionName: 'hasAttester', args: [s] }), pub.readContract({ address: D.tape, abi: TAPE, functionName: 'isHalted', args: [s] }), pub.readContract({ address: D.tape, abi: TAPE, functionName: 'action', args: [s] }), pub.readContract({ address: D.tape, abi: TAPE, functionName: 'attesterOf', args: [s] })]); return send(res, 200, { symbol: sym, status: has ? (halted ? 'halted' : 'trading') : 'unknown', hasAttester: has, attester: has ? att : null, halted: has ? halted : null, lastAction: a[0] ? { kind: KINDS[a[0]], effective: Number(a[1]), value: a[2] } : null, pools: [...index.pools.values()].filter(x => x.symbol === sym), ...(await provenance()) }); }
    if ((m = p.match(/^\/v1\/symbols\/([A-Za-z0-9.\-]+)\/actions$/))) { const arr = [...index.events.values()].filter(e => e.symbol === m[1]).sort((a, b) => a.effective - b.effective); return send(res, 200, { symbol: m[1], ...page(arr, q), ...(await provenance()) }); }
    if ((m = p.match(/^\/v1\/pools\/(0x[0-9a-fA-F]{64})$/))) { const pool = index.pools.get(m[1]) || { poolId: m[1] }; return send(res, 200, { ...pool, ...(await provenance()) }); }
    if (p === '/v1/pools') return send(res, 200, { items: [...index.pools.values()], ...(await provenance()) });
    if (p === '/v1/trade-status' && req.method === 'POST') { const b = await readBody(req); const key = { currency0: b.currency0, currency1: b.currency1, fee: Number(b.fee), tickSpacing: Number(b.tickSpacing), hooks: b.hooks || D.hook }; const [st, reason, eff] = await pub.readContract({ address: D.hook, abi: HOOK, functionName: 'tradeStatus', args: [key] }); const poolId = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'address' }, { type: 'uint24' }, { type: 'int24' }, { type: 'address' }], [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks])); return send(res, 200, { poolId, status: TS[st], reason: str(reason), effective: eff ? Number(eff) : null, ...(await provenance()) }); }
    // tx encoding: data for the user's wallet to sign; never signed here
    if (p === '/v1/tx/finalize' && req.method === 'POST') { const b = await readBody(req); return send(res, 200, { to: D.tape, data: encodeFunctionData({ abi: TAPE, functionName: 'finalize', args: [b.id] }), value: '0', chainId: Number(chainId) }); }
    if (p === '/v1/tx/challenge' && req.method === 'POST') { const b = await readBody(req); const cb = await pub.readContract({ address: D.tape, abi: TAPE, functionName: 'challengeBond' }); return send(res, 200, { to: D.tape, data: encodeFunctionData({ abi: TAPE, functionName: 'challenge', args: [b.id] }), value: cb.toString(), chainId: Number(chainId) }); }
    if (p === '/v1/tx/acknowledge' && req.method === 'POST') { const b = await readBody(req); return send(res, 200, { to: D.hook, data: encodeFunctionData({ abi: HOOK, functionName: 'acknowledge', args: [{ currency0: b.currency0, currency1: b.currency1, fee: Number(b.fee), tickSpacing: Number(b.tickSpacing), hooks: b.hooks || D.hook }] }), value: '0', chainId: Number(chainId) }); }
    // runs + operators (written by operators with the api key)
    if (p === '/v1/runs' && req.method === 'GET') { let arr = runsStore.read(); if (q.get('operator')) arr = arr.filter(r => r.operator === q.get('operator')); arr.sort((a, b) => b.at - a.at); const since = Date.now() - 86_400_000; return send(res, 200, { ...page(arr, q), last24h: { runs: arr.filter(r => r.at > since).length, ok: arr.filter(r => r.at > since && r.ok).length }, ...(await provenance()) }); }
    if (p === '/v1/runs' && req.method === 'POST') { if (!API_KEY || req.headers['x-api-key'] !== API_KEY) return send(res, 401, { error: 'x-api-key required' }); const b = await readBody(req); const run = { id: randomUUID(), at: Date.now(), ...b }; const arr = runsStore.read(); arr.push(run); runsStore.write(arr.slice(-5000)); emit('run', run); return send(res, 201, run); }
    if (p === '/v1/operators' && req.method === 'GET') { const arr = opsStore.read(); const now = Date.now(); return send(res, 200, { items: arr.map(o => ({ ...o, alive: now - o.lastSeen < 30_000 })), ...(await provenance()) }); }
    if (p === '/v1/operators/heartbeat' && req.method === 'POST') { if (!API_KEY || req.headers['x-api-key'] !== API_KEY) return send(res, 401, { error: 'x-api-key required' }); const b = await readBody(req); const arr = opsStore.read(); const i = arr.findIndex(o => o.address === b.address); const o = { address: b.address, name: b.name || null, lastSeen: Date.now(), lastBlock: b.lastBlock || null, version: b.version || null, runs: (i >= 0 ? arr[i].runs : 0) + (b.ranOne ? 1 : 0) }; if (i >= 0) arr[i] = o; else arr.push(o); opsStore.write(arr); return send(res, 200, o); }
    if (p === '/v1/webhooks' && req.method === 'POST') { if (!API_KEY || req.headers['x-api-key'] !== API_KEY) return send(res, 401, { error: 'x-api-key required' }); const b = await readBody(req); if (!/^https?:\/\//.test(b.url || '')) return send(res, 400, { error: 'url required' }); const w = { id: randomUUID(), url: b.url, events: b.events || [], secret: b.secret || randomUUID().replace(/-/g, ''), createdAt: Date.now() }; const arr = hooksStore.read(); arr.push(w); hooksStore.write(arr); return send(res, 201, w); }
    if (p === '/v1/stream') { res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive', 'access-control-allow-origin': '*' }); res.write(`event: hello\ndata: ${J({ chainId: Number(chainId), indexedTo: Number(index.lastBlock) })}\n\n`); subscribers.add(res); req.on('close', () => subscribers.delete(res)); return; }
    return send(res, 404, { error: 'not found', routes: ['/v1', '/v1/tape', '/v1/events', '/v1/symbols/:sym', '/v1/symbols/:sym/actions', '/v1/pools', '/v1/pools/:id', 'POST /v1/trade-status', 'POST /v1/tx/finalize|challenge|acknowledge', '/v1/runs', '/v1/operators', 'POST /v1/webhooks', '/v1/stream'] });
  } catch (e) { return send(res, 500, { error: e.shortMessage || e.message }); }
});
server.listen(PORT, '127.0.0.1', () => console.log(`neo-api ${C.name} (${chainId}) → http://127.0.0.1:${PORT}/v1  indexed to block ${index.lastBlock}`));
