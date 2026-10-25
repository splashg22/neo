// Tiny receiver that verifies NEO webhook signatures. Used by the e2e check.
//   NEO_WEBHOOK_SECRET=s node api/test-webhook-receiver.mjs   → http://127.0.0.1:8790/hook
import http from 'node:http';
import { createHmac, timingSafeEqual } from 'node:crypto';
const secret = process.env.NEO_WEBHOOK_SECRET || 'test';
let count = 0;
http.createServer((req, res) => {
  let body = ''; req.on('data', c => body += c); req.on('end', () => {
    const sig = req.headers['x-neo-signature'] || ''; const m = sig.match(/t=(\d+),v1=([0-9a-f]+)/);
    const expect = m ? createHmac('sha256', secret).update(m[1] + '.' + body).digest('hex') : '';
    const ok = m && expect.length === m[2].length && timingSafeEqual(Buffer.from(expect), Buffer.from(m[2]));
    count++; const msg = JSON.parse(body);
    console.log(JSON.stringify({ n: count, type: msg.type, symbol: msg.data?.symbol, task: msg.data?.task, signatureValid: !!ok }));
    res.writeHead(ok ? 200 : 401); res.end();
  });
}).listen(8790, '127.0.0.1', () => console.log('receiver on :8790'));
