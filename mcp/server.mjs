#!/usr/bin/env node
// NEO MCP server — corporate-action state for tokenized-equity pools on Robinhood Chain.
// Read-only. Builds nothing that signs. "unknown" is never "ok".
//
//   NEO_CHAIN=46630 node mcp/server.mjs        (stdio)
//
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { createPublicClient, http, parseAbi, stringToHex, hexToString, keccak256, encodeAbiParameters } from 'viem';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const app = join(here, '..', 'app');
const CHAINS = JSON.parse(readFileSync(join(app, 'chains.json'), 'utf8'));
const chainId = process.env.NEO_CHAIN || '46630';
const C = CHAINS[chainId];
if (!C) { console.error('unknown chain', chainId); process.exit(1); }
let D = null;
try { D = JSON.parse(readFileSync(join(app, C.deployments), 'utf8')); } catch { /* not deployed on this chain */ }

const pub = createPublicClient({ transport: http(process.env.NEO_RPC || C.rpc) });
const TAPE = parseAbi([
  'function isHalted(bytes32) view returns (bool)',
  'function action(bytes32) view returns (uint8,uint64,uint256)',
  'function eventsRoot() view returns (bytes32)',
  'function eventCount() view returns (uint256)',
  'function hasAttester(bytes32) view returns (bool)',
  'function attesterOf(bytes32) view returns (address)',
  'function eventsOf(bytes32) view returns (bytes32[])',
  'function disputeWindow() view returns (uint64)',
  'function pending(bytes32) view returns (((bytes32 symbol, uint8 kind, uint64 effective, uint256 value, uint64 nonce) e, address poster, address challenger, uint64 postedAt, uint8 status))',
]);
const HOOK = parseAbi([
  'function tradeStatus((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)) view returns (uint8,bytes32,uint64)',
  'function symbolOf(bytes32) view returns (bytes32)',
  'function operatorOf(bytes32) view returns (address)',
  'function label() view returns (string)',
]);
const KINDS = ['none', 'split', 'dividend', 'halt', 'rename'];
const STATUS = ['unknown', 'pending', 'challenged', 'finalized', 'rejected'];
const TS = ['unknown', 'ok', 'refused'];
const b32 = s => stringToHex(s.slice(0, 32), { size: 32 });
const str = h => { try { return hexToString(h, { size: 32 }).replace(/\0+$/, ''); } catch { return h; } };
const value = (kind, v) => kind === 1 ? { splitRatio: Number(v) / 1e4 } : kind === 2 ? { dividendMinorUnits: v.toString() } : kind === 3 ? { halted: v === 1n } : kind === 4 ? { newSymbol: str('0x' + v.toString(16).padStart(64, '0')) } : {};
const NOT_DEPLOYED = { error: `NEO is not deployed on chain ${chainId}`, chain: C.name };
const out = o => ({ content: [{ type: 'text', text: JSON.stringify(o, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2) }] });
const provenance = async () => { const b = await pub.getBlock(); return { chainId: Number(chainId), block: Number(b.number), timestamp: Number(b.timestamp), tape: D?.tape, hook: D?.hook }; };

const server = new McpServer({ name: 'neo', version: '0.1.0' });

server.tool('equity_halt_status', 'Is a tokenized stock halted on the Tape? Returns halted true/false, or unknown when the symbol has no attester (no data source).',
  { symbol: z.string().describe('Ticker as registered on the Tape, e.g. ALFA') },
  async ({ symbol }) => {
    if (!D) return out(NOT_DEPLOYED);
    const s = b32(symbol);
    const [has, halted] = await Promise.all([pub.readContract({ address: D.tape, abi: TAPE, functionName: 'hasAttester', args: [s] }), pub.readContract({ address: D.tape, abi: TAPE, functionName: 'isHalted', args: [s] })]);
    return out({ symbol, status: has ? (halted ? 'halted' : 'trading') : 'unknown', halted: has ? halted : null, reason: has ? undefined : 'no attester for this symbol', ...(await provenance()) });
  });

server.tool('equity_actions', 'Corporate-action calendar for a tokenized stock: every event posted to the Tape (split, dividend, halt, rename) with status, effective time and dispute state. Rejected events are included and marked.',
  { symbol: z.string(), include: z.enum(['all', 'finalized', 'open']).default('all') },
  async ({ symbol, include }) => {
    if (!D) return out(NOT_DEPLOYED);
    const s = b32(symbol);
    const [ids, win, has] = await Promise.all([pub.readContract({ address: D.tape, abi: TAPE, functionName: 'eventsOf', args: [s] }), pub.readContract({ address: D.tape, abi: TAPE, functionName: 'disputeWindow' }), pub.readContract({ address: D.tape, abi: TAPE, functionName: 'hasAttester', args: [s] })]);
    const rows = await Promise.all(ids.map(async id => { const p = await pub.readContract({ address: D.tape, abi: TAPE, functionName: 'pending', args: [id] }); return { id, kind: KINDS[p.e.kind], ...value(p.e.kind, p.e.value), effective: Number(p.e.effective), effectiveISO: new Date(Number(p.e.effective) * 1000).toISOString(), status: STATUS[p.status], postedAt: Number(p.postedAt), windowClosesAt: Number(p.postedAt) + Number(win), poster: p.poster, challenger: p.challenger === '0x0000000000000000000000000000000000000000' ? null : p.challenger, nonce: Number(p.e.nonce) }; }));
    const f = include === 'finalized' ? rows.filter(r => r.status === 'finalized') : include === 'open' ? rows.filter(r => r.status === 'pending' || r.status === 'challenged') : rows;
    return out({ symbol, hasAttester: has, count: f.length, events: f.sort((a, b) => a.effective - b.effective), ...(await provenance()) });
  });

server.tool('equity_trade_status', 'Can this pool trade right now? Reads CorporateActionHook.tradeStatus for a Uniswap v4 pool key: ok | refused (halted, or a split/rename in effect and not acknowledged) | unknown (no attester). unknown is never ok. Read this before quoting or routing.',
  { currency0: z.string(), currency1: z.string(), fee: z.number().int(), tickSpacing: z.number().int(), hooks: z.string().optional().describe('defaults to the NEO hook on this chain') },
  async ({ currency0, currency1, fee, tickSpacing, hooks }) => {
    if (!D) return out(NOT_DEPLOYED);
    const key = { currency0, currency1, fee, tickSpacing, hooks: hooks || D.hook };
    const poolId = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'address' }, { type: 'uint24' }, { type: 'int24' }, { type: 'address' }], [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]));
    const [st, reason, eff] = await pub.readContract({ address: D.hook, abi: HOOK, functionName: 'tradeStatus', args: [key] });
    const sym = await pub.readContract({ address: D.hook, abi: HOOK, functionName: 'symbolOf', args: [poolId] });
    return out({ poolId, symbol: str(sym) || null, status: TS[st], reason: str(reason), effective: eff ? Number(eff) : null, ...(await provenance()) });
  });

server.tool('equity_tape', 'Tape summary on this chain: finalized event count, Merkle root of all finalized events, dispute window, and the attester for an optional symbol.',
  { symbol: z.string().optional() },
  async ({ symbol }) => {
    if (!D) return out(NOT_DEPLOYED);
    const [count, root, win] = await Promise.all([pub.readContract({ address: D.tape, abi: TAPE, functionName: 'eventCount' }), pub.readContract({ address: D.tape, abi: TAPE, functionName: 'eventsRoot' }), pub.readContract({ address: D.tape, abi: TAPE, functionName: 'disputeWindow' })]);
    const att = symbol ? await pub.readContract({ address: D.tape, abi: TAPE, functionName: 'attesterOf', args: [b32(symbol)] }) : undefined;
    return out({ finalized: Number(count), eventsRoot: root, disputeWindowSeconds: Number(win), attester: att, hookLabel: await pub.readContract({ address: D.hook, abi: HOOK, functionName: 'label' }), ...(await provenance()) });
  });

server.tool('hook_permissions', 'Decode the 14 Uniswap v4 permission bits from any hook address (pure; no chain read).',
  { address: z.string() },
  async ({ address }) => {
    if (!/^0x[0-9a-fA-F]{40}$/.test(address)) return out({ error: 'address must be 0x + 40 hex characters' });
    const NAMES = ['BEFORE_INITIALIZE', 'AFTER_INITIALIZE', 'BEFORE_ADD_LIQUIDITY', 'AFTER_ADD_LIQUIDITY', 'BEFORE_REMOVE_LIQUIDITY', 'AFTER_REMOVE_LIQUIDITY', 'BEFORE_SWAP', 'AFTER_SWAP', 'BEFORE_DONATE', 'AFTER_DONATE', 'BEFORE_SWAP_RETURNS_DELTA', 'AFTER_SWAP_RETURNS_DELTA', 'AFTER_ADD_LIQUIDITY_RETURNS_DELTA', 'AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA'];
    const mask = parseInt(address.slice(-4), 16) & 0x3fff;
    return out({ address, mask: '0x' + mask.toString(16).padStart(4, '0'), permissions: NAMES.filter((_, i) => mask >> (13 - i) & 1), isNeoHook: D ? address.toLowerCase() === D.hook.toLowerCase() : false });
  });

await server.connect(new StdioServerTransport());
