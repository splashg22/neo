// Headless click-through of the console against the local stack (Anvil + API + operator running).
//   node e2e/console.spec.mjs
import { chromium } from 'playwright';
import { readFileSync, mkdirSync } from 'node:fs';

const D = JSON.parse(readFileSync(new URL('../app/deployments.local.json', import.meta.url), 'utf8'));
mkdirSync(new URL('./shots/', import.meta.url), { recursive: true });
const shot = (page, n) => page.screenshot({ path: new URL(`./shots/${n}.png`, import.meta.url).pathname, fullPage: true });
const results = []; const check = (name, ok, detail = '') => { results.push({ name, ok, detail }); console.log((ok ? 'PASS ' : 'FAIL ') + name + (detail ? '  — ' + detail : '')); };

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const errors = []; page.on('pageerror', e => errors.push(e.message)); page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
await page.goto('http://127.0.0.1:5173/?chain=31337', { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => document.querySelector('#count')?.textContent !== '—', null, { timeout: 15000 });
await shot(page, '01-loaded');

check('page loads without JS errors', errors.length === 0, errors.join(' | ').slice(0, 200));
check('tape address shown', (await page.textContent('#tape-addr')).toLowerCase().includes(D.tape.toLowerCase()));
check('event count populated', /^\d+$/.test((await page.textContent('#count')).trim()), await page.textContent('#count'));
check('merkle root populated', /^0x[0-9a-f]{64}$/.test((await page.textContent('#root')).trim()));
check('hook permission tiles: 2 lit', (await page.$$('#tiles i.on')).length === 2);
check('calendar has rows', (await page.$$('#cal .day')).length >= 3, (await page.$$('#cal .day')).length + ' rows');
const badge = await page.getAttribute('#ts', 'class');
check('trade-status badge rendered', /badge (Ok|Refused|Unknown)/.test(badge), badge);
check('events table has rows', (await page.$$('#events tr')).length >= 3);
check('control room reached API', !(await page.textContent('#cr-src')).includes('not reachable'), await page.textContent('#cr-src'));
check('control room shows runs', (await page.$$('#cr-table tr')).length >= 1 && !(await page.textContent('#cr-table')).includes('No runs'));

// connect as attester (dev1), sign and post a new event
await page.selectOption('#signer', 'dev1'); await page.click('#connect');
await page.waitForFunction(() => /0x…|0x[0-9a-fA-F]{4}…/.test(document.querySelector('#who').textContent) || document.querySelector('#who').textContent.length > 6);
check('connected as dev signer', (await page.textContent('#who')).length > 6, await page.textContent('#who'));
await page.selectOption('#p-kind', '2'); await page.fill('#p-val', '55'); await page.fill('#p-nonce', String(900 + Math.floor(Math.random() * 1000)));
await page.click('#sign'); await page.waitForFunction(() => !document.querySelector('#post').disabled, null, { timeout: 10000 });
check('attester signature produced', (await page.textContent('#sig')).includes('signature 0x'));
const before = (await page.$$('#events tr')).length;
await page.click('#post'); await page.waitForFunction(n => document.querySelectorAll('#events tr').length > n, before, { timeout: 20000 });
check('posted event appears in table', (await page.$$('#events tr')).length === before + 1);
check('new event is Pending with window countdown', (await page.textContent('#events')).includes('closes in'));
await page.waitForFunction(() => /confirmed in block|reverted/.test(document.querySelector('#log').textContent), null, { timeout: 30000 }); // post receipt settled
await shot(page, '02-posted');

// try a swap as the deployer: ALFA is halted on this chain state, hook must refuse
await page.selectOption('#signer', 'dev0'); await page.click('#connect'); await page.waitForTimeout(500);
await page.evaluate(() => { document.querySelector('#log').innerHTML = ''; });
const expected = (await page.getAttribute('#ts', 'class')).includes('Refused') ? /Halted\(|AwaitingAcknowledgement\(|reverted/ : /confirmed in block/;
await page.click('#try-swap'); await page.waitForFunction(() => /Halted\(|AwaitingAcknowledgement\(|reverted|confirmed in block/.test(document.querySelector('#log').textContent), null, { timeout: 30000 });
const logTxt = await page.textContent('#log');
check('swap outcome matches the trade-status badge', expected.test(logTxt), logTxt.trim().split('\n')[0].slice(0, 140));

// create-pool panel: check tokens against the existing sample pool
await page.fill('#cp-a', D.token0); await page.fill('#cp-b', D.token1); await page.click('#cp-check');
await page.waitForFunction(() => document.querySelector('#cp-out').textContent.includes('poolId'), null, { timeout: 10000 });
check('create-pool check resolves tokens and finds existing binding', (await page.textContent('#cp-out')).includes('already bound to ALFA'), (await page.textContent('#cp-out')).slice(0, 120));

// chain selector lists the three chains; switching to 46630 shows the not-deployed state
check('chain selector has 3 chains', (await page.$$('#chain option')).length === 3);
await page.goto('http://127.0.0.1:5173/?chain=46630', { waitUntil: 'domcontentloaded' }); await page.waitForTimeout(800);
check('undeployed chain shows deploy instructions', (await page.textContent('body')).includes('not deployed on this chain'));
await shot(page, '03-testnet-undeployed');

await browser.close();
const failed = results.filter(r => !r.ok).length;
console.log(`\n${results.length - failed}/${results.length} checks passed`);
process.exit(failed ? 1 : 0);
