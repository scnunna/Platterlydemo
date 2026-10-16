// Platterly lead proxy: the only part of the laptop stack that faces the internet.
// It forwards a fixed list of calls to the local Supabase stack and nothing else.
//   Public (QR page):   POST /v1/claim, /v1/lead (old pages), /v1/catering, /v1/me  -> anon role
//   Public (ordering):  POST /v1/code, /v1/menu, /v1/quote, /v1/order, /v1/order-status -> anon role
//   Staff (admin page): POST /v1/staff/login, then /v1/staff/*        -> service role, scoped in SQL by staff id
//                       (/v1/staff/onboarding* is super admin only)
//   GET /v1/health
// Database keys are added here, so the public repo and the pages never hold one. Staff sessions are random
// tokens kept in memory (12 h); a restart signs everyone out. Node 18+, no dependencies.
// It also sends the 2-hour claim reminders (see sendReminders below).
// Env: PLATTERLY_API, PLATTERLY_ANON_KEY, PLATTERLY_SERVICE_KEY, PORT (default 56380), PLATTERLY_ORIGINS,
//      PLATTERLY_MAIL (test | resend), RESEND_API_KEY, PLATTERLY_MAIL_FROM, PLATTERLY_MAILPIT,
//      TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM, PLATTERLY_SITE.
import http from 'node:http';
import crypto from 'node:crypto';

const API = process.env.PLATTERLY_API || 'http://127.0.0.1:56321';
const ANON = process.env.PLATTERLY_ANON_KEY || '';
const SERVICE = process.env.PLATTERLY_SERVICE_KEY || '';
const PORT = Number(process.env.PORT || 56380);
const ORIGINS = new Set((process.env.PLATTERLY_ORIGINS ||
  'https://godsmustb.github.io,https://appassets.androidplatform.net,http://127.0.0.1:8099,http://localhost:8099').split(','));
const MAX_BODY = 8192; // an order of 40 lines fits
const SESSION_MS = 12 * 3600e3;

if (!ANON || !SERVICE) { console.error('PLATTERLY_ANON_KEY and PLATTERLY_SERVICE_KEY must be set. Start with server/start.ps1.'); process.exit(1); }

// route -> rpc, the role key to use, how to build its arguments, per-IP limit per minute
const PUBLIC = {
  '/v1/claim': { rpc: 'submit_claim', perMin: 20, args: b => pick(b, ['p_client', 'p_store', 'p_first_name', 'p_email', 'p_phone', 'p_consent', 'p_remind', 'p_offer', 'p_quiz_right', 'p_source', 'p_consent_wording']) },
  '/v1/code': { rpc: 'code_info', perMin: 30, args: b => pick(b, ['p_code']) },
  '/v1/menu': { rpc: 'menu_for', perMin: 60, args: b => pick(b, ['p_client']) },
  '/v1/quote': { rpc: 'quote_order', perMin: 90, args: b => pick(b, ['p_code', 'p_items', 'p_use_prize', 'p_points']) },
  '/v1/order': { rpc: 'place_order', perMin: 10, args: b => pick(b, ['p_code', 'p_store', 'p_mode', 'p_name', 'p_phone', 'p_address', 'p_note', 'p_items', 'p_use_prize', 'p_points', 'p_payment']) },
  '/v1/order-status': { rpc: 'order_status', perMin: 30, args: b => pick(b, ['p_number', 'p_code']) },
  '/v1/lead': { rpc: 'submit_lead', perMin: 20, args: b => pick(b, ['p_client', 'p_store', 'p_first_name', 'p_contact', 'p_consent', 'p_offer', 'p_quiz_right', 'p_source', 'p_consent_wording']) },
  '/v1/catering': { rpc: 'request_catering', perMin: 10, args: b => pick(b, ['p_code', 'p_event_date', 'p_package', 'p_headcount']) },
  '/v1/me': { rpc: 'customer_history', perMin: 10, args: b => pick(b, ['p_client', 'p_contact', 'p_code']) }
};
const STAFF = {
  '/v1/staff/leads': { rpc: 'staff_leads', args: (b, s) => ({ p_staff: s.id, p_client: b.client || null, p_search: b.search || null, p_consent_only: !!b.consent_only, p_limit: Number(b.limit) || 500 }) },
  '/v1/staff/summary': { rpc: 'staff_summary', args: (b, s) => ({ p_staff: s.id, p_client: b.client || null }) },
  '/v1/staff/catering': { rpc: 'staff_catering', args: (b, s) => ({ p_staff: s.id, p_client: b.client || null }) },
  '/v1/staff/catering-status': { rpc: 'staff_set_catering_status', args: (b, s) => ({ p_staff: s.id, p_id: b.id || null, p_status: b.status || null }) },
  '/v1/staff/redeem': { rpc: 'staff_redeem', args: (b, s) => ({ p_staff: s.id, p_code: b.code || null, p_store: b.store || null, p_order_total: b.total === '' || b.total == null ? null : Number(b.total) }) },
  '/v1/staff/orders': { rpc: 'staff_orders', args: (b, s) => ({ p_staff: s.id, p_client: b.client || null }) },
  '/v1/staff/order-status': { rpc: 'staff_set_order_status', args: (b, s) => ({ p_staff: s.id, p_id: b.id || null, p_status: b.status || null }) },
  // Super admin only (checked in SQL): the client onboarding board.
  '/v1/staff/onboarding': { rpc: 'staff_onboarding', args: (b, s) => ({ p_staff: s.id }) },
  '/v1/staff/onboarding-set': { rpc: 'staff_onboarding_set', args: (b, s) => ({ p_staff: s.id, p_client: b.client || null, p_step: b.step || null, p_done: typeof b.done === 'boolean' ? b.done : null, p_note: typeof b.note === 'string' ? b.note : null }) },
  '/v1/staff/password': { rpc: 'staff_change_password', args: (b, s) => ({ p_staff: s.id, p_old: b.old || null, p_new: b.new || null }) }
};
const pick = (b, fields) => Object.fromEntries(fields.map(f => [f, b[f] === undefined ? null : b[f]]));

// Per-IP limits allow a whole office on one Wi-Fi (colleagues scanning a shared photo) while stopping floods.
const hits = new Map();
function limited(key, max, windowMs = 60e3) {
  const now = Date.now(), arr = (hits.get(key) || []).filter(t => now - t < windowMs);
  arr.push(now); hits.set(key, arr);
  if (hits.size > 5000) for (const [k, v] of hits) if (now - v[v.length - 1] > 3600e3) hits.delete(k);
  return arr.length > max;
}

const sessions = new Map(); // token -> {id, role, client_id, exp}
function session(req) {
  const m = /^Bearer ([A-Za-z0-9_-]{40,})$/.exec(req.headers.authorization || '');
  const s = m && sessions.get(m[1]);
  if (!s || s.exp < Date.now()) { if (m) sessions.delete(m[1]); return null; }
  return s;
}

function send(res, status, body, origin) {
  const h = { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' };
  if (origin && ORIGINS.has(origin)) { h['access-control-allow-origin'] = origin; h['vary'] = 'Origin'; }
  res.writeHead(status, h); res.end(JSON.stringify(body));
}

async function rpc(name, args, key) {
  const r = await fetch(`${API}/rest/v1/rpc/${name}`, {
    method: 'POST', headers: { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' },
    body: JSON.stringify(args), signal: AbortSignal.timeout(8000)
  });
  const data = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, data };
}
function dbError(res, r, origin) {
  // Postgres errors carry our message + hint; pass only those, never internals.
  const d = r.data || {};
  const msg = typeof d.message === 'string' && /^[\w\s.,'’()-]{1,160}$/.test(d.message) ? d.message : 'Could not do that.';
  const status = d.code === '42501' ? 403 : r.status >= 500 ? 502 : 400;
  return send(res, status, { error: msg, hint: typeof d.hint === 'string' ? d.hint.slice(0, 200) : undefined }, origin);
}

const server = http.createServer((req, res) => {
  const origin = req.headers.origin;
  const path = new URL(req.url, 'http://x').pathname;
  const ip = String(req.headers['cf-connecting-ip'] || req.socket.remoteAddress || '?');
  const known = PUBLIC[path] || STAFF[path] || path === '/v1/staff/login' || path === '/v1/staff/logout';

  if (req.method === 'OPTIONS') {
    if (!origin || !ORIGINS.has(origin) || !known) { res.writeHead(403); return res.end(); }
    res.writeHead(204, { 'access-control-allow-origin': origin, 'access-control-allow-methods': 'POST', 'access-control-allow-headers': 'content-type, authorization', 'access-control-max-age': '600', 'vary': 'Origin' });
    return res.end();
  }
  if (req.method === 'GET' && path === '/v1/health') return send(res, 200, { ok: true }, origin);
  if (req.method !== 'POST' || !known) return send(res, 404, { error: 'Not found' }, origin);
  if (origin && !ORIGINS.has(origin)) return send(res, 403, { error: 'This page is not allowed here.' }, origin);
  if (limited(ip + '|' + path, PUBLIC[path] ? PUBLIC[path].perMin : 60)) return send(res, 429, { error: 'Too many tries. Wait a minute and try again.' }, origin);

  let size = 0; const chunks = [];
  req.on('data', c => { size += c.length; if (size > MAX_BODY) req.destroy(); else chunks.push(c); });
  req.on('end', async () => {
    let b;
    try { b = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); } catch { return send(res, 400, { error: 'The request was not valid JSON.' }, origin); }
    if (typeof b !== 'object' || b === null || Array.isArray(b)) return send(res, 400, { error: 'Expected a JSON object.' }, origin);
    try {
      if (PUBLIC[path]) {
        const r = await rpc(PUBLIC[path].rpc, PUBLIC[path].args(b), ANON);
        return r.ok ? send(res, 200, r.data, origin) : dbError(res, r, origin);
      }
      if (path === '/v1/staff/login') {
        const email = String(b.email || '').trim().toLowerCase();
        if (limited('login-ip|' + ip, 8, 600e3) || limited('login-email|' + email, 10, 3600e3)) return send(res, 429, { error: 'Too many sign-in attempts. Try again in 10 minutes.' }, origin);
        const r = await rpc('staff_login', { p_email: email, p_password: String(b.password || '') }, SERVICE);
        if (!r.ok) return dbError(res, r, origin);
        if (!r.data.ok) return send(res, 401, { error: 'Email or password is wrong.' }, origin);
        const token = crypto.randomBytes(32).toString('base64url');
        sessions.set(token, { id: r.data.id, role: r.data.role, client_id: r.data.client_id, exp: Date.now() + SESSION_MS });
        const { id, ...who } = r.data;
        return send(res, 200, { token, expires_in: SESSION_MS / 1000, ...who }, origin);
      }
      if (path === '/v1/staff/logout') {
        const m = /^Bearer (.+)$/.exec(req.headers.authorization || ''); if (m) sessions.delete(m[1]);
        return send(res, 200, { ok: true }, origin);
      }
      const s = session(req);
      if (!s) return send(res, 401, { error: 'Signed out. Sign in again.' }, origin);
      const r = await rpc(STAFF[path].rpc, STAFF[path].args(b, s), SERVICE);
      return r.ok ? send(res, 200, r.data, origin) : dbError(res, r, origin);
    } catch (e) {
      return send(res, 503, { error: 'The store system is offline right now.', hint: 'Your spin is saved on this phone. Show this screen at the counter.' }, origin);
    }
  });
});
// ---------- claim reminders ----------
// Two hours after a claim the fast-claim bonus ends; the code stays valid until the store closes. The customer chose
// to get one reminder (email when they gave one, else a text). It is a service message about the code they asked
// for, not marketing: no other offers in it.
// Email: PLATTERLY_MAIL=resend sends through Resend (RESEND_API_KEY, PLATTERLY_MAIL_FROM on a verified domain).
//        Otherwise it goes to the local test inbox (Mailpit, http://127.0.0.1:56324) and is marked test_inbox:
//        it does NOT reach the customer until a real sender is set.
// Text:  TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM. Without them a text reminder is marked skipped.
const MAIL = process.env.PLATTERLY_MAIL || 'test';
const MAILPIT = process.env.PLATTERLY_MAILPIT || 'http://127.0.0.1:56324';
const FROM = process.env.PLATTERLY_MAIL_FROM || 'Platterly <codes@platterly.local>';
const SITE = process.env.PLATTERLY_SITE || 'https://godsmustb.github.io/platterlycatering';
const closeText = iso => new Date(iso).toLocaleTimeString('en-CA', { hour: 'numeric', minute: '2-digit', timeZone: 'America/Toronto' }).replace(':00', '');
function reminderText(r) {
  const link = `${SITE}/order/?code=${encodeURIComponent(r.code)}`, ways = r.delivery ? 'pickup or delivery' : 'pickup';
  return {
    subject: `Your Platterly code is still good until ${closeText(r.expires_at)} today`,
    sms: `Platterly: Hi ${r.first_name}, your prize (${r.prize}) is still yours until ${closeText(r.expires_at)} today at ${r.store}. Code ${r.code}. Order for ${ways}: ${link} Reply STOP to opt out.`,
    text: `Hi ${r.first_name},\n\nYour 2-hour fast-claim bonus has ended, but your prize is still yours:\n\n  ${r.prize}, ${r.rule}\n  Code: ${r.code}\n  Valid until ${closeText(r.expires_at)} today at ${r.store}${r.address ? ', ' + r.address : ''}\n\n` +
          `Show the code at the counter, or order through Platterly for ${ways} at the same price as the store: ${link}\n\n` +
          `You are getting this one reminder because you asked for it when you claimed your prize. It is not a marketing message.\n` +
          `Platterly, marketing partner of ${r.client}. ${SITE}/`
  };
}
async function sendEmail(to, m) {
  if (MAIL === 'resend') {
    const r = await fetch('https://api.resend.com/emails', { method: 'POST', signal: AbortSignal.timeout(10000),
      headers: { authorization: `Bearer ${process.env.RESEND_API_KEY || ''}`, 'content-type': 'application/json' },
      body: JSON.stringify({ from: FROM, to: [to], subject: m.subject, text: m.text }) });
    if (!r.ok) throw new Error(`Resend ${r.status}`);
    return 'sent';
  }
  const r = await fetch(`${MAILPIT}/api/v1/send`, { method: 'POST', signal: AbortSignal.timeout(10000), headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ From: { Email: 'codes@platterly.local', Name: 'Platterly' }, To: [{ Email: to }], Subject: m.subject, Text: m.text }) });
  if (!r.ok) throw new Error(`test inbox ${r.status}`);
  return 'test_inbox';
}
async function sendSms(to, m) {
  const sid = process.env.TWILIO_ACCOUNT_SID, tok = process.env.TWILIO_AUTH_TOKEN, from = process.env.TWILIO_FROM;
  if (!sid || !tok || !from) return 'skipped';
  const r = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, { method: 'POST', signal: AbortSignal.timeout(10000),
    headers: { authorization: 'Basic ' + Buffer.from(`${sid}:${tok}`).toString('base64'), 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ To: to, From: from, Body: m.sms }) });
  if (!r.ok) throw new Error(`Twilio ${r.status}`);
  return 'sent';
}
let sending = false;
async function sendReminders() {
  if (sending) return; sending = true;
  try {
    const due = await rpc('reminders_claim', { p_limit: 20 }, SERVICE);
    for (const r of (due.ok && Array.isArray(due.data) ? due.data : [])) {
      let status = 'failed', error = null;
      try { const m = reminderText(r); status = r.channel === 'email' ? await sendEmail(r.to, m) : await sendSms(r.to, m); if (status === 'skipped') error = 'No SMS sender configured'; }
      catch (e) { error = String(e.message || e).slice(0, 200); }
      await rpc('reminder_done', { p_id: r.id, p_status: status, p_error: error }, SERVICE);
      console.log(`reminder ${r.id} ${r.channel} ${status}${error ? ' (' + error + ')' : ''}`); // no addresses in the log
    }
  } catch (e) { console.error('reminders:', e.message); } finally { sending = false; }
}
setInterval(sendReminders, 60e3);
setTimeout(sendReminders, 5e3);

server.listen(PORT, '127.0.0.1', () => console.log(`lead proxy on http://127.0.0.1:${PORT} -> ${API} · reminders: email ${MAIL === 'resend' ? 'Resend' : 'test inbox only'}, SMS ${process.env.TWILIO_ACCOUNT_SID ? 'Twilio' : 'off'}`));
