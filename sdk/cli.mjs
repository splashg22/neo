#!/usr/bin/env node
// neo CLI — reads and transaction encoding. Never signs.
//   neo tape                      neo symbol ALFA            neo actions ALFA
//   neo status <c0> <c1> <fee> <tickSpacing>                 neo decode 0xHOOK
//   neo tx finalize <id> | challenge <id> | acknowledge <c0> <c1> <fee> <ts>
//   env: NEO_CHAIN (default 46630), NEO_RPC
import { Neo } from './index.mjs';
const [cmd, ...a] = process.argv.slice(2);
const out = o => console.log(JSON.stringify(o, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2));
if (!cmd || cmd === 'help') { console.log('neo tape | symbol <SYM> | actions <SYM> | status <c0> <c1> <fee> <ts> | decode <addr> | tx finalize|challenge|acknowledge ...'); process.exit(0); }
if (cmd === 'decode') { out(Neo.decodePermissions(a[0])); process.exit(0); }
const neo = await Neo.connect({ chainId: process.env.NEO_CHAIN || 46630, rpc: process.env.NEO_RPC });
const key = () => ({ currency0: a[0], currency1: a[1], fee: Number(a[2]), tickSpacing: Number(a[3]) });
if (cmd === 'tape') out(await neo.tape());
else if (cmd === 'symbol') out(await neo.symbol(a[0]));
else if (cmd === 'actions') out(await neo.actions(a[0]));
else if (cmd === 'status') out(await neo.tradeStatus(key()));
else if (cmd === 'pool') out(await neo.pool(key()));
else if (cmd === 'tx') { const sub = a.shift(); if (sub === 'finalize') out(neo.tx.finalize(a[0])); else if (sub === 'challenge') out(neo.tx.challenge(a[0], (await neo.tape()).challengeBond)); else if (sub === 'acknowledge') out(neo.tx.acknowledge({ ...key(), hooks: neo.addresses.hook })); else console.error('tx finalize|challenge|acknowledge'); }
else console.error('unknown command', cmd);
