// Platterly lead proxy: the only part of the laptop stack that faces the internet.
// It forwards exactly two calls to the local Supabase stack and nothing else:
//   POST /v1/lead      -> rpc/submit_lead
//   POST /v1/catering  -> rpc/request_catering
//   GET  /v1/health    -> {ok}
// The database key is added here, so the public repo and the QR page never hold one.
// Node 18+, no dependencies.  Env: PLATTERLY_API, PLATTERLY_ANON_KEY, PORT (default 56380).
import http from 'node:http';

const API = process.env.PLATTERLY_API || 'http://127.0.0.1:56321';
const KEY = process.env.PLATTERLY_ANON_KEY || '';
const PORT = Number(process.env.PORT || 56380);
const ORIGINS = new Set((process.env.PLATTERLY_ORIGINS ||
  'https://godsmustb.github.io,https://appassets.androidplatform.net,http://127.0.0.1:8099,http://localhost:8099').split(','));
const ROUTES = {
  '/v1/lead': { rpc: 'submit_lead', fields: ['p_client', 'p_store', 'p_first_name', 'p_contact', 'p_consent', 'p_offer', 'p_quiz_right', 'p_source', 'p_consent_wording'], perMin: 20 },
  '/v1/catering': { rpc: 'request_catering', fields: ['p_code', 'p_event_date', 'p_package', 'p_headcount'], perMin: 10 }
};
const MAX_BODY = 4096;

if (!KEY) { console.error('PLATTERLY_ANON_KEY is not set. Start with server/start.ps1, which reads it from `supabase status`.'); process.exit(1); }

// Per-IP limits allow a whole office on one Wi-Fi (colleagues scanning a shared photo) while stopping floods.
const hits = new Map(); // ip|route -> [timestamps]
function limited(ip, route, perMin) {
  const k = ip + '|' + route, now = Date.now(), arr = (hits.get(k) || []).filter(t => now - t < 60e3);
  arr.push(now); hits.set(k, arr);
  if (hits.size > 5000) for (const [kk, v] of hits) if (now - v[v.length - 1] > 60e3) hits.delete(kk);
  return arr.length > perMin;
}

function send(res, status, body, origin) {
  const h = { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' };
  if (origin && ORIGINS.has(origin)) { h['access-control-allow-origin'] = origin; h['vary'] = 'Origin'; }
  res.writeHead(status, h); res.end(JSON.stringify(body));
}

const server = http.createServer((req, res) => {
  const origin = req.headers.origin;
  const url = new URL(req.url, 'http://x');
  const ip = String(req.headers['cf-connecting-ip'] || req.socket.remoteAddress || '?');

  if (req.method === 'OPTIONS') {
    if (!origin || !ORIGINS.has(origin) || !ROUTES[url.pathname]) { res.writeHead(403); return res.end(); }
    res.writeHead(204, { 'access-control-allow-origin': origin, 'access-control-allow-methods': 'POST', 'access-control-allow-headers': 'content-type', 'access-control-max-age': '600', 'vary': 'Origin' });
    return res.end();
  }
  if (req.method === 'GET' && url.pathname === '/v1/health') return send(res, 200, { ok: true }, origin);

  const route = ROUTES[url.pathname];
  if (req.method !== 'POST' || !route) return send(res, 404, { error: 'Not found' }, origin);
  if (origin && !ORIGINS.has(origin)) return send(res, 403, { error: 'This page is not allowed to send leads.' }, origin);
  if (limited(ip, url.pathname, route.perMin)) return send(res, 429, { error: 'Too many tries. Wait a minute and try again.' }, origin);

  let size = 0, chunks = [];
  req.on('data', c => { size += c.length; if (size > MAX_BODY) { req.destroy(); } else chunks.push(c); });
  req.on('end', async () => {
    let body;
    try { body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); } catch { return send(res, 400, { error: 'The request was not valid JSON.' }, origin); }
    if (typeof body !== 'object' || body === null || Array.isArray(body)) return send(res, 400, { error: 'Expected a JSON object.' }, origin);
    const args = {};
    for (const f of route.fields) args[f] = body[f] === undefined ? null : body[f];
    try {
      const r = await fetch(`${API}/rest/v1/rpc/${route.rpc}`, {
        method: 'POST',
        headers: { apikey: KEY, authorization: `Bearer ${KEY}`, 'content-type': 'application/json' },
        body: JSON.stringify(args), signal: AbortSignal.timeout(8000)
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok) {
        // Postgres errors carry our message + hint; pass only those, never internals.
        const msg = data && data.message && /^[\w\s.,'’()-]{1,160}$/.test(data.message) ? data.message : 'Could not save that.';
        return send(res, r.status >= 500 ? 502 : 400, { error: msg, hint: typeof data.hint === 'string' ? data.hint.slice(0, 200) : undefined }, origin);
      }
      return send(res, 200, data, origin);
    } catch (e) {
      return send(res, 503, { error: 'The store system is offline right now.', hint: 'Your spin is saved on this phone. Show this screen at the counter.' }, origin);
    }
  });
});
server.listen(PORT, '127.0.0.1', () => console.log(`lead proxy on http://127.0.0.1:${PORT} -> ${API}`));
