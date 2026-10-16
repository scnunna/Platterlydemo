// Platterly lead proxy: the only part of the laptop stack that faces the internet.
// It forwards a fixed list of calls to the local Supabase stack and nothing else.
//   Public (QR page):   POST /v1/claim, /v1/lead (old pages), /v1/catering, /v1/me  -> anon role
//   Public (ordering):  POST /v1/code, /v1/menu, /v1/quote, /v1/order, /v1/order-status -> anon role
//   Staff (admin page): POST /v1/staff/login, then /v1/staff/*        -> service role, scoped in SQL by staff id
//                       (/v1/staff/onboarding* is super admin only)
//   GET /v1/health
// Database keys are added here, so the public repo and the pages never hold one. Staff sessions are random
// tokens kept in memory (12 h); a restart signs everyone out. Node 18+, no dependencies.
// It also runs Platterly's background jobs: claim reminders, billing (settlements, invoices, weekly reports) and the
// Listmonk deals-list sync. Email goes out through the self-hosted Listmonk instances (server/listmonk).
// Env: PLATTERLY_API, PLATTERLY_ANON_KEY, PLATTERLY_SERVICE_KEY, PORT (default 56380), PLATTERLY_ORIGINS,
//      LM_PLATTERLY_API_TOKEN, LM_PANAGO_API_TOKEN, LM_WETZELS_API_TOKEN (listmonk.env), PLATTERLY_SITE,
//      TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM (texts, optional).
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
  '/v1/staff/billing': { rpc: 'staff_billing', args: (b, s) => ({ p_staff: s.id, p_client: b.client || null }) },
  '/v1/staff/billing-rate': { rpc: 'staff_billing_rate', args: (b, s) => ({ p_staff: s.id, p_client: b.client || null, p_pct: b.pct === '' || b.pct == null ? null : Number(b.pct) }) },
  '/v1/staff/billing-action': { rpc: 'staff_billing_action', args: (b, s) => ({ p_staff: s.id, p_action: b.action || null, p_id: b.id || null }), after: () => setTimeout(sendOutbox, 500) },
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
      if (r.ok && STAFF[path].after) STAFF[path].after();
      return r.ok ? send(res, 200, r.data, origin) : dbError(res, r, origin);
    } catch (e) {
      return send(res, 503, { error: 'The store system is offline right now.', hint: 'Your spin is saved on this phone. Show this screen at the counter.' }, origin);
    }
  });
});
// ---------- email through Listmonk ----------
// One Listmonk per sender (server/listmonk/docker-compose.yml): 'platterly' for partner mail, one per client for that
// client's customers. Each has its own SMTP setting; while it points at the local test inbox (Mailpit) a message is
// recorded as test_inbox, meaning it did not leave this laptop.
const SITE = process.env.PLATTERLY_SITE || 'https://godsmustb.github.io/platterlycatering';
const LM = { platterly: 56390, panago: 56391, wetzels: 56392 };
const lmTemplate = {}, lmTest = {};
const instanceFor = client => (LM[client] && process.env[`LM_${client.toUpperCase()}_API_TOKEN`]) ? client : 'platterly';
async function lm(inst, method, p, body) {
  const token = process.env[`LM_${inst.toUpperCase()}_API_TOKEN`];
  if (!token) throw new Error(`Listmonk ${inst}: no API token (listmonk.env)`);
  const r = await fetch(`http://127.0.0.1:${LM[inst]}/api${p}`, { method, signal: AbortSignal.timeout(15000),
    headers: { authorization: `token platterly-api:${token}`, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, data: j.data, message: j.message };
}
async function lmReady(inst) {
  if (!lmTemplate[inst] || Date.now() - (lmTest[inst]?.at || 0) > 600e3) {
    const t = await lm(inst, 'GET', '/templates'); if (!t.ok) throw new Error(`Listmonk ${inst}: ${t.status} ${t.message || ''}`);
    const tpl = (t.data || []).find(x => x.name === 'Platterly message'); if (!tpl) throw new Error(`Listmonk ${inst}: run server/listmonk/setup.mjs`);
    lmTemplate[inst] = tpl.id;
    const st = await lm(inst, 'GET', '/settings');
    lmTest[inst] = { at: Date.now(), test: !st.ok || (st.data.smtp || []).filter(x => x.enabled).every(x => /inbucket|mailpit|yoursite\.com/.test(x.host || '')) };
  }
}
async function sendEmail(inst, to, name, subject, html) {
  await lmReady(inst);
  const c = await lm(inst, 'POST', '/subscribers', { email: to, name: name || to.split('@')[0], status: 'enabled', lists: [], preconfirm_subscriptions: true });
  if (!c.ok && c.status !== 409) throw new Error(`Listmonk ${inst} subscriber: ${c.status} ${c.message || ''}`);
  const r = await lm(inst, 'POST', '/tx', { subscriber_email: to, template_id: lmTemplate[inst], content_type: 'html', data: { subject, html } });
  if (!r.ok) throw new Error(`Listmonk ${inst} send: ${r.status} ${r.message || ''}`);
  return lmTest[inst].test ? 'test_inbox' : 'sent';
}
async function sendSms(to, text) {
  const sid = process.env.TWILIO_ACCOUNT_SID, tok = process.env.TWILIO_AUTH_TOKEN, from = process.env.TWILIO_FROM;
  if (!sid || !tok || !from) return 'skipped';
  const r = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, { method: 'POST', signal: AbortSignal.timeout(10000),
    headers: { authorization: 'Basic ' + Buffer.from(`${sid}:${tok}`).toString('base64'), 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ To: to, From: from, Body: text }) });
  if (!r.ok) throw new Error(`Twilio ${r.status}`);
  return 'sent';
}

const H = v => String(v == null ? '' : v).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const $ = n => '$' + Number(n || 0).toFixed(2);
const tz = { timeZone: 'America/Toronto' };
const dLong = iso => new Date(iso).toLocaleDateString('en-CA', { ...tz, weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });
const dShort = iso => new Date(iso).toLocaleDateString('en-CA', { ...tz, month: 'short', day: 'numeric' });
const dDay = ymd => new Date(ymd + 'T12:00:00Z').toLocaleDateString('en-CA', { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' });
const closeText = iso => new Date(iso).toLocaleTimeString('en-CA', { ...tz, hour: 'numeric', minute: '2-digit' }).replace(':00', '');
function shell(title, inner, foot) {
  return `<div style="font-family:Segoe UI,Helvetica,Arial,sans-serif;color:#13201F;max-width:640px;margin:0 auto">
  <div style="background:#0E4D4A;color:#fff;padding:16px 20px;border-radius:12px 12px 0 0"><div style="font-size:20px;font-weight:800;letter-spacing:-.02em">platterly</div><div style="font-size:15px;opacity:.9">${H(title)}</div></div>
  <div style="border:1px solid #D3DBD6;border-top:0;border-radius:0 0 12px 12px;padding:18px 20px;font-size:14px;line-height:1.5">${inner}
  <p style="color:#56645F;font-size:12px;margin-top:18px">${foot || ''} Platterly · ${H(SITE)}/</p></div></div>`;
}
const table = (head, rows, right = []) => `<table style="border-collapse:collapse;width:100%;font-size:13px;margin:8px 0"><tr>${head.map((h, k) => `<th style="text-align:${right.includes(k) ? 'right' : 'left'};padding:6px 8px;background:#E9EEEB;border-bottom:1px solid #D3DBD6">${H(h)}</th>`).join('')}</tr>${rows.map(r => `<tr>${r.map((c, k) => `<td style="text-align:${right.includes(k) ? 'right' : 'left'};padding:6px 8px;border-bottom:1px solid #E9EEEB">${c}</td>`).join('')}</tr>`).join('')}</table>`;
const kv = pairs => `<table style="border-collapse:collapse;width:100%;font-size:14px;margin:8px 0">${pairs.map(([k, v, b]) => `<tr><td style="padding:5px 0;color:#56645F">${H(k)}</td><td style="padding:5px 0;text-align:right;${b ? 'font-weight:800;font-size:16px' : ''}">${v}</td></tr>`).join('')}</table>`;
const PAYN = { pay_at_store: 'At the counter', pay_on_delivery: 'To the driver', card_demo: 'At the store (demo card)' };

function render(kind, p) {
  if (kind === 'settlement') return { subject: `Platterly settlement ${p.number}: ${$(p.amount)} for ${p.client}`, html: shell(`Settlement ${p.number}`,
    `<p>Every 3 days Platterly settles the orders whose payments have cleared (completed on or before <b>${H(dLong(p.cutoff))}</b>).</p>
     ${kv([['Orders settled', String(p.orders)], ['Platterly points used by customers', $(p.points_credit)], ['Card payments collected by Platterly', $(p.card_prepaid)], ['Platterly pays you', $(p.amount), true]])}
     ${table(['Order', 'Completed', 'Type', 'Paid', 'Total', 'Points'], (p.lines || []).map(l => [H(l.number), H(dShort(l.completed_at)), H(l.mode), H(PAYN[l.payment] || l.payment), $(l.total), $(l.credit)]), [4, 5])}
     <p style="color:#56645F;font-size:12px">Customers paid you the order totals directly. The points part is Platterly's: we transfer it to you.</p>`) };
  if (kind === 'invoice') return { subject: `Platterly invoice ${p.number}: ${$(p.total)} (week of ${dDay(p.week_start)})`, html: shell(`Invoice ${p.number}`,
    `<p>To <b>${H(p.client)}</b>, for every order taken through Platterly from <b>${H(dDay(p.week_start))}</b> to <b>${H(dDay(p.week_end))}</b> (Sunday, end of day).</p>
     ${table(['Order', 'Taken', 'Type', 'Food'], (p.lines || []).map(l => [H(l.number), H(dShort(l.created_at)), H(l.mode), $(l.food)]), [3])}
     ${kv([['Orders', String(p.orders)], ['Food sold through Platterly', $(p.food)], [`Platterly commission (${Number(p.commission_pct)}%)`, $(p.commission)], ['Amount due', $(p.total), true]])}
     <p style="color:#56645F;font-size:12px">Food is menu price minus prize discounts, before tax. Points customers used are settled to you separately every 3 days.</p>`) };
  if (kind === 'weekly_report') {
    const b = p.balance || {};
    return { subject: `Platterly weekly report: ${p.client}, ${dDay(p.week_start)} to ${dDay(p.week_end)}`, html: shell(`Weekly report · ${dDay(p.week_start)} to ${dDay(p.week_end)}`,
    `<h3 style="margin:4px 0">Orders through Platterly</h3>${kv([['Orders', `${p.orders} (${p.pickup} pickup, ${p.delivery} delivery)`], ['Cancelled', String(p.cancelled)], ['Food sold', $(p.food)], ['Prizes given on orders', $(p.prize_value)]])}
     <h3 style="margin:12px 0 4px">Platterly points at your store</h3>${kv([['Points earned by your customers', String(p.points_earned)], ['Points used on orders', String(p.points_used)], ['Value of points used (Platterly pays)', $(p.points_credit)]])}
     <h3 style="margin:12px 0 4px">Leads from Spin &amp; Win</h3>${kv([['New leads', String(p.leads_new)], ['Said yes to deals', String(p.leads_consented)], ['Prizes redeemed at the counter', String(p.counter_redemptions)]])}
     <h3 style="margin:12px 0 4px">Balance</h3>${kv([['Platterly owes you, clearing', $(b.platterly_owes_unsettled)], ['Platterly owes you, settled', $(b.platterly_owes_statements)], ['Open Platterly invoices', $(b.client_owes_invoices)], ['Net to you', $(b.net_to_client), true]])}
     <p>Next settlement: ${p.next_settlement ? H(dLong(p.next_settlement)) : 'the first one runs on the next billing day'}. Your invoice for this week arrives on Wednesday.</p>`) };
  }
}

let busy = { reminders: false, outbox: false, billing: false, sync: false };
const job = (name, fn) => async () => { if (busy[name]) return; busy[name] = true; try { await fn(); } catch (e) { console.error(`${name}:`, e.message); } finally { busy[name] = false; } };

// Two hours after a claim the fast-claim bonus ends; the code stays valid until close. One reminder, by the customer's
// choice, through the client's own Listmonk (or a text). A service message about their code: no other offers in it.
const sendReminders = job('reminders', async () => {
  const due = await rpc('reminders_claim', { p_limit: 20 }, SERVICE);
  for (const r of (due.ok && Array.isArray(due.data) ? due.data : [])) {
    const link = `${SITE}/order/?code=${encodeURIComponent(r.code)}`, ways = r.delivery ? 'pickup or delivery' : 'pickup', until = closeText(r.expires_at);
    let status = 'failed', error = null;
    try {
      if (r.channel === 'email') status = await sendEmail(instanceFor(r.client_id), r.to, r.first_name, `Your Platterly code is still good until ${until} today`, shell(`Your prize is still yours until ${until} today`,
        `<p>Hi ${H(r.first_name)},</p><p>Your 2-hour fast-claim bonus has ended, but your prize is still yours:</p>
         <p style="background:#F3F5F2;border-radius:10px;padding:12px 14px"><b>${H(r.prize)}</b>, ${H(r.rule)}<br>Code <b style="font-family:monospace;font-size:17px">${H(r.code)}</b><br>Valid until ${H(until)} today at ${H(r.store)}${r.address ? ', ' + H(r.address) : ''}</p>
         <p>Show the code at the counter, or <a href="${H(link)}">order through Platterly</a> for ${ways} at the same price as the store.</p>`,
        `You are getting this one reminder because you asked for it when you claimed your prize. It is not a marketing message. Platterly, marketing partner of ${H(r.client)}.`));
      else { status = await sendSms(r.to, `Platterly: Hi ${r.first_name}, your prize (${r.prize}) is still yours until ${until} today at ${r.store}. Code ${r.code}. Order for ${ways}: ${link} Reply STOP to opt out.`); if (status === 'skipped') error = 'No SMS sender configured'; }
    } catch (e) { error = String(e.message || e).slice(0, 200); }
    await rpc('reminder_done', { p_id: r.id, p_status: status, p_error: error }, SERVICE);
    console.log(`reminder ${r.id} ${r.channel} ${status}${error ? ' (' + error + ')' : ''}`); // no addresses in the log
  }
});

// Partner mail: settlements, invoices, weekly reports, through Platterly's own Listmonk.
const sendOutbox = job('outbox', async () => {
  const due = await rpc('outbox_claim', { p_limit: 20 }, SERVICE);
  for (const o of (due.ok && Array.isArray(due.data) ? due.data : [])) {
    let status = 'failed', error = null;
    try {
      const m = render(o.kind, o.payload); const got = [];
      for (const to of o.recipients || []) got.push(await sendEmail('platterly', to, null, m.subject, m.html));
      status = !got.length ? 'failed' : got.every(x => x === 'test_inbox') ? 'test_inbox' : 'sent'; if (!got.length) error = 'No recipients (no active client admin)';
    } catch (e) { error = String(e.message || e).slice(0, 200); }
    await rpc('outbox_done', { p_id: o.id, p_status: status, p_error: error }, SERVICE);
    console.log(`outbox ${o.kind} ${o.ref} ${status}${error ? ' (' + error + ')' : ''}`);
  }
});
const runBilling = job('billing', async () => {
  const r = await rpc('billing_tick', { p_now: new Date().toISOString() }, SERVICE);
  if (r.ok && r.data && r.data.made && r.data.made.length) console.log('billing', JSON.stringify(r.data.made));
  await sendOutbox();
});

// Each client's Listmonk "deals" list holds exactly the leads who ticked the deals box and gave an email.
// Unsubscribes and blocklists in Listmonk turn consent off in Platterly (logged in consent_log).
const DEALS = { panago: 'Deals and catering offers', wetzels: 'Deals and party-pack offers' };
const syncLists = job('sync', async () => {
  for (const [client, listName] of Object.entries(DEALS)) {
    if (instanceFor(client) !== client) continue;
    const lists = await lm(client, 'GET', '/lists?per_page=all'); const list = (lists.data?.results || []).find(l => l.name === listName);
    if (!list) continue;
    const subs = await lm(client, 'GET', `/subscribers?list_id=${list.id}&per_page=all`);
    const inList = new Map((subs.data?.results || []).map(x => [x.email.toLowerCase(), x]));
    const out = [...inList.values()].filter(x => x.status === 'blocklisted' || (x.lists || []).some(l => l.id === list.id && l.subscription_status === 'unsubscribed')).map(x => x.email.toLowerCase());
    if (out.length) { const r = await rpc('marketing_optout', { p_client: client, p_emails: out }, SERVICE); if (r.ok && r.data) console.log(`sync ${client}: ${r.data} unsubscribed`); }
    const want = await rpc('marketing_contacts', { p_client: client }, SERVICE);
    let added = 0;
    for (const c of (want.ok && Array.isArray(want.data) ? want.data : [])) {
      if (inList.has(c.email) || out.includes(c.email)) continue;
      const attribs = { platterly: { phone: c.phone, store: c.store, source: c.source, since: c.since, points: c.points } };
      const r = await lm(client, 'POST', '/subscribers', { email: c.email, name: c.name, status: 'enabled', lists: [list.id], attribs, preconfirm_subscriptions: true });
      if (r.status === 409) {
        const f = await lm(client, 'GET', `/subscribers?query=${encodeURIComponent(`subscribers.email = '${c.email.replace(/'/g, "''")}'`)}`);
        const sub = f.data?.results?.[0];
        if (sub && sub.status !== 'blocklisted') await lm(client, 'PUT', '/subscribers/lists', { ids: [sub.id], action: 'add', target_list_ids: [list.id], status: 'confirmed' });
      }
      if (r.ok || r.status === 409) added++;
    }
    if (added) console.log(`sync ${client}: ${added} added to "${listName}"`);
  }
});

setInterval(sendReminders, 60e3); setTimeout(sendReminders, 5e3);
setInterval(runBilling, 300e3); setTimeout(runBilling, 15e3);
setInterval(syncLists, 900e3); setTimeout(syncLists, 30e3);

server.listen(PORT, '127.0.0.1', () => console.log(`lead proxy on http://127.0.0.1:${PORT} -> ${API} · email via Listmonk (${Object.keys(LM).filter(k => process.env[`LM_${k.toUpperCase()}_API_TOKEN`]).join(', ') || 'not configured'}), SMS ${process.env.TWILIO_ACCOUNT_SID ? 'Twilio' : 'off'}`));
