// Configures the three Platterly Listmonk instances (see docker-compose.yml). Safe to re-run.
// - sender name and address, root URL
// - SMTP: the local test inbox (Mailpit) ONLY while the SMTP is still Listmonk's placeholder. A real SMTP server
//   entered in Listmonk's admin (Settings > SMTP) is never overwritten.
// - the "Platterly message" transactional template the proxy sends through
// - lists: each client's "Deals and catering offers" (consented contacts only); Platterly's "Partners"
// Tokens: LM_<NAME>_API_TOKEN from %LOCALAPPDATA%\platterly\listmonk.env (start.ps1 loads it). Node 18+.
import fs from 'node:fs';
import path from 'node:path';

const envFile = path.join(process.env.LOCALAPPDATA || '.', 'platterly', 'listmonk.env');
if (fs.existsSync(envFile)) for (const l of fs.readFileSync(envFile, 'utf8').split(/\r?\n/)) { const m = /^([A-Z_]+)=(.*)$/.exec(l.trim()); if (m && !process.env[m[1]]) process.env[m[1]] = m[2]; }

export const INSTANCES = {
  platterly: { port: 56390, site: 'Platterly', from: 'Platterly <hello@platterly.local>', list: 'Partners' },
  panago: { port: 56391, site: 'Platterly × Panago', from: 'Platterly for Panago <panago@platterly.local>', list: 'Deals and catering offers' },
  wetzels: { port: 56392, site: "Platterly × Wetzel's", from: "Platterly for Wetzel's <wetzels@platterly.local>", list: 'Deals and party-pack offers' }
};
const TEST_SMTP = { enabled: true, host: 'supabase_inbucket_platterly', port: 1025, auth_protocol: 'none', username: '', password: '', tls_type: 'none',
  tls_skip_verify: false, max_conns: 5, idle_timeout: '15s', wait_timeout: '5s', max_msg_retries: 2, email_headers: [], hello_hostname: '' };
export const TEMPLATE = 'Platterly message';

async function lm(name, method, p, body) {
  const i = INSTANCES[name], token = process.env[`LM_${name.toUpperCase()}_API_TOKEN`];
  if (!token) throw new Error(`LM_${name.toUpperCase()}_API_TOKEN is not set`);
  const r = await fetch(`http://127.0.0.1:${i.port}/api${p}`, { method, signal: AbortSignal.timeout(15000),
    headers: { authorization: `token platterly-api:${token}`, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`${name} ${method} ${p}: ${r.status} ${j.message || ''}`);
  return j.data;
}
const healthy = async name => { for (let k = 0; k < 30; k++) { try { await lm(name, 'GET', '/lists?per_page=1'); return; } catch { await new Promise(r => setTimeout(r, 1000)); } } throw new Error(`${name} did not come back`); };

async function setup(name) {
  const i = INSTANCES[name];
  await healthy(name);
  const s = await lm(name, 'GET', '/settings');
  // Listmonk ships an enabled placeholder (smtp.yoursite.com) and a disabled Gmail sample. Only the enabled ones count.
  const on = (s.smtp || []).filter(x => x.enabled);
  const placeholder = !on.length || on.every(x => /yoursite\.com$/.test(x.host || ''));
  const want = { 'app.root_url': `http://127.0.0.1:${i.port}`, 'app.from_email': i.from, 'app.site_name': i.site };
  const change = Object.entries(want).some(([k, v]) => s[k] !== v) || placeholder;
  if (change) {
    Object.assign(s, want);
    // Listmonk matches SMTP servers by uuid: edit the placeholder entry in place rather than replacing it.
    if (placeholder) { const k = s.smtp.findIndex(x => /yoursite\.com$/.test(x.host || '')); if (k >= 0) s.smtp[k] = Object.assign({}, s.smtp[k], TEST_SMTP); else s.smtp.push(TEST_SMTP); }
    await lm(name, 'PUT', '/settings', s);
    await new Promise(r => setTimeout(r, 1500)); await healthy(name); // Listmonk reloads after a settings change
  }
  const smtp = (await lm(name, 'GET', '/settings')).smtp.filter(x => x.enabled).map(x => `${x.host}:${x.port}`).join(', ');
  const tpls = await lm(name, 'GET', '/templates');
  let tpl = tpls.find(t => t.name === TEMPLATE);
  if (!tpl) tpl = await lm(name, 'POST', '/templates', { name: TEMPLATE, type: 'tx', subject: '{{ .Tx.Data.subject }}', body: '{{ .Tx.Data.html | Safe }}' });
  const lists = (await lm(name, 'GET', '/lists?per_page=all')).results;
  let list = lists.find(l => l.name === i.list);
  if (!list) list = await lm(name, 'POST', '/lists', { name: i.list, type: 'private', optin: 'single', tags: ['platterly'],
    description: name === 'platterly' ? 'Partner contacts for reports, settlements and invoices.' : 'Customers who ticked the deals box (CASL consent, logged in Platterly). Synced by the Platterly proxy; unsubscribes sync back.' });
  console.log(`${name.padEnd(10)} http://127.0.0.1:${i.port}  smtp ${smtp}${/inbucket|mailpit/.test(smtp) ? ' (TEST INBOX: mail does not leave this laptop)' : ''}  template #${tpl.id}  list #${list.id} "${list.name}"`);
}

if (process.argv[1] && import.meta.url.endsWith(path.basename(process.argv[1]))) {
  for (const n of Object.keys(INSTANCES)) await setup(n).catch(e => { console.error(`${n}: ${e.message}`); process.exitCode = 1; });
}
