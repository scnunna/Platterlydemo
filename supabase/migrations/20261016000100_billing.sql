-- Platterly 0005: settlements, invoices, weekly reports. All times are America/Toronto.
-- * Settlement every 3 days: orders completed at least 3 days ago (card and other payments take about 3 days to
--   clear) and not yet settled. Platterly owes the client the Platterly points customers used on those orders
--   (and, once Platterly takes card payments, the prepaid totals). A statement is emailed; the transfer is marked
--   paid in the portal.
-- * Invoice on Wednesday 9 AM for every order taken Monday 00:00 to Sunday 23:59 of the previous week:
--   commission = client's commission_pct x food (subtotal minus prize discount). No rate set = draft, not emailed.
-- * Weekly report on Monday 9 AM: orders, sales, points earned and used, leads, settlements, invoices, balance.
-- billing_tick(now) is idempotent; the proxy calls it every few minutes and sends what lands in outbox.

alter table public.clients add column commission_pct numeric(5,2) check (commission_pct between 0 and 50);
alter table public.orders add column completed_at timestamptz, add column settlement_id uuid, add column invoice_id uuid;
update public.orders set completed_at = updated_at where status = 'completed' and completed_at is null;

create table public.settlements (
  id            uuid primary key default gen_random_uuid(),
  number        text not null unique,
  client_id     text not null references public.clients(id) on delete cascade,
  cutoff        timestamptz not null,
  orders        int not null default 0,
  points_credit numeric(10,2) not null default 0,
  card_prepaid  numeric(10,2) not null default 0,
  amount        numeric(10,2) not null default 0,
  status        text not null check (status in ('nothing_due', 'statement_sent', 'paid')),
  created_at    timestamptz not null default now(),
  paid_at       timestamptz
);
create index settlements_client_idx on public.settlements (client_id, created_at desc);
alter table public.orders add constraint orders_settlement_fk foreign key (settlement_id) references public.settlements(id) on delete set null;

create table public.invoices (
  id             uuid primary key default gen_random_uuid(),
  number         text not null unique,
  client_id      text not null references public.clients(id) on delete cascade,
  week_start     date not null,
  week_end       date not null,
  orders         int not null default 0,
  food           numeric(10,2) not null default 0,
  commission_pct numeric(5,2),
  commission     numeric(10,2),
  total          numeric(10,2),
  lines          jsonb not null default '[]'::jsonb,
  status         text not null check (status in ('draft', 'sent', 'paid', 'void', 'nothing_due')),
  created_at     timestamptz not null default now(),
  sent_at        timestamptz,
  paid_at        timestamptz,
  unique (client_id, week_start)
);
alter table public.orders add constraint orders_invoice_fk foreign key (invoice_id) references public.invoices(id) on delete set null;

create table public.weekly_reports (
  client_id  text not null references public.clients(id) on delete cascade,
  week_start date not null,
  data       jsonb not null,
  created_at timestamptz not null default now(),
  primary key (client_id, week_start)
);

-- Emails Platterly sends to its partners (through the Platterly Listmonk). Reminders to customers stay in reminders.
create table public.outbox (
  id         bigint generated always as identity primary key,
  kind       text not null check (kind in ('weekly_report', 'invoice', 'settlement')),
  client_id  text not null references public.clients(id) on delete cascade,
  ref        text not null,
  recipients text[] not null,
  payload    jsonb not null,
  status     text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'test_inbox', 'failed')),
  attempts   int not null default 0,
  error      text,
  created_at timestamptz not null default now(),
  sent_at    timestamptz,
  unique (kind, ref)
);

do $$ declare t text; begin
  foreach t in array array['settlements','invoices','weekly_reports','outbox'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- Who gets partner mail: the client's active admins, plus Platterly super admins in copy.
create or replace function public.billing_recipients(p_client text) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(email order by role desc, email), '{}') from staff
  where active and (client_id = p_client or role = 'super_admin')
$$;

-- A week's numbers for one client (Monday..Sunday, local).
create or replace function public.week_numbers(p_client text, p_start date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a timestamptz := (p_start::timestamp at time zone 'America/Toronto'); b timestamptz := ((p_start + 7)::timestamp at time zone 'America/Toronto');
        v_unsettled numeric; v_owed_paid numeric; v_inv_open numeric;
begin
  select coalesce(sum(credit + case when payment = 'card_platterly' then total else 0 end), 0) into v_unsettled
    from orders where client_id = p_client and status = 'completed' and settlement_id is null;
  select coalesce(sum(amount), 0) into v_owed_paid from settlements where client_id = p_client and status = 'statement_sent';
  select coalesce(sum(total), 0) into v_inv_open from invoices where client_id = p_client and status = 'sent';
  return jsonb_build_object(
    'week_start', p_start, 'week_end', p_start + 6,
    'orders', (select count(*) from orders where client_id = p_client and created_at >= a and created_at < b and status <> 'cancelled'),
    'pickup', (select count(*) from orders where client_id = p_client and created_at >= a and created_at < b and status <> 'cancelled' and mode = 'pickup'),
    'delivery', (select count(*) from orders where client_id = p_client and created_at >= a and created_at < b and status <> 'cancelled' and mode = 'delivery'),
    'cancelled', (select count(*) from orders where client_id = p_client and created_at >= a and created_at < b and status = 'cancelled'),
    'food', (select coalesce(sum(subtotal - discount), 0) from orders where client_id = p_client and created_at >= a and created_at < b and status <> 'cancelled'),
    'prize_value', (select coalesce(sum(discount), 0) from orders where client_id = p_client and created_at >= a and created_at < b and status <> 'cancelled'),
    'points_earned', (select coalesce(sum(delta), 0) from points_ledger where client_id = p_client and delta > 0 and reason <> 'refund' and created_at >= a and created_at < b),
    'points_used', (select coalesce(-sum(delta), 0) from points_ledger where client_id = p_client and reason = 'spent' and created_at >= a and created_at < b)
                 - (select coalesce(sum(delta), 0) from points_ledger where client_id = p_client and reason = 'refund' and created_at >= a and created_at < b),
    'points_credit', (select coalesce(sum(credit), 0) from orders where client_id = p_client and created_at >= a and created_at < b and status = 'completed'),
    'leads_new', (select count(*) from leads where client_id = p_client and created_at >= a and created_at < b),
    'leads_consented', (select count(*) from leads where client_id = p_client and created_at >= a and created_at < b and consent),
    'counter_redemptions', (select count(*) from spins s where client_id = p_client and redeemed_at >= a and redeemed_at < b and not exists (select 1 from orders o where o.spin_id = s.id and o.prize_used)),
    'settled_in_week', (select coalesce(sum(amount), 0) from settlements where client_id = p_client and created_at >= a and created_at < b),
    'balance', jsonb_build_object('platterly_owes_unsettled', v_unsettled, 'platterly_owes_statements', v_owed_paid,
                                  'client_owes_invoices', v_inv_open, 'net_to_client', v_unsettled + v_owed_paid - v_inv_open),
    'next_settlement', (select max(created_at) + interval '3 days' from settlements where client_id = p_client)
  );
end $$;

create or replace function public.billing_tick(p_now timestamptz) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_local timestamp := p_now at time zone 'America/Toronto'; v_day date := v_local::date; v_dow int := extract(isodow from v_local)::int;
  c record; v_last timestamptz; v_cut timestamptz := p_now - interval '3 days'; st public.settlements; inv public.invoices;
  v_ws date; v_n int; v_credit numeric; v_card numeric; v_food numeric; v_lines jsonb; v_made jsonb := '[]';
  a timestamptz; b timestamptz;
begin
  if v_local::time < time '09:00' then return jsonb_build_object('ran', false, 'why', 'before 9 AM'); end if;
  for c in select * from clients order by id loop
    -- 1. settlement every 3 days
    select max(created_at) into v_last from settlements where client_id = c.id;
    if v_last is null or (v_last at time zone 'America/Toronto')::date + 3 <= v_day then
      select count(*), coalesce(sum(credit), 0), coalesce(sum(case when payment = 'card_platterly' then total else 0 end), 0)
        into v_n, v_credit, v_card
        from orders where client_id = c.id and status = 'completed' and settlement_id is null and completed_at <= v_cut;
      insert into settlements (number, client_id, cutoff, orders, points_credit, card_prepaid, amount, status, created_at)
      values ('ST-' || upper(c.id) || '-' || to_char(v_day, 'YYYYMMDD'), c.id, v_cut, v_n, v_credit, v_card, v_credit + v_card,
              case when v_n = 0 then 'nothing_due' else 'statement_sent' end, p_now)
      returning * into st;
      update orders set settlement_id = st.id where client_id = c.id and status = 'completed' and settlement_id is null and completed_at <= v_cut;
      if v_n > 0 then
        insert into outbox (kind, client_id, ref, recipients, payload) values ('settlement', c.id, st.number, billing_recipients(c.id),
          jsonb_build_object('number', st.number, 'client', c.name, 'cutoff', st.cutoff, 'orders', st.orders, 'points_credit', st.points_credit,
            'card_prepaid', st.card_prepaid, 'amount', st.amount,
            'lines', (select jsonb_agg(jsonb_build_object('number', o.number, 'completed_at', o.completed_at, 'mode', o.mode, 'total', o.total,
                       'credit', o.credit, 'payment', o.payment) order by o.completed_at) from orders o where o.settlement_id = st.id)));
      end if;
      v_made := v_made || jsonb_build_object('settlement', st.number, 'orders', v_n);
    end if;

    -- 2. weekly report, Monday, for last Monday..Sunday
    v_ws := (date_trunc('week', v_local)::date) - 7;
    -- (a missed Monday or Wednesday is caught up on the next tick; weeks before the client joined are skipped)
    if c.created_at < ((v_ws + 7)::timestamp at time zone 'America/Toronto') and not exists (select 1 from weekly_reports where client_id = c.id and week_start = v_ws) then
      insert into weekly_reports (client_id, week_start, data) values (c.id, v_ws, week_numbers(c.id, v_ws));
      insert into outbox (kind, client_id, ref, recipients, payload) values ('weekly_report', c.id, 'WR-' || upper(c.id) || '-' || to_char(v_ws, 'YYYYMMDD'),
        billing_recipients(c.id), week_numbers(c.id, v_ws) || jsonb_build_object('client', c.name, 'commission_pct', c.commission_pct))
      on conflict (kind, ref) do nothing;
      v_made := v_made || jsonb_build_object('report', v_ws);
    end if;

    -- 3. invoice, Wednesday, for every order taken last Monday..Sunday
    if v_dow >= 3 and c.created_at < ((v_ws + 7)::timestamp at time zone 'America/Toronto') and not exists (select 1 from invoices where client_id = c.id and week_start = v_ws) then
      a := v_ws::timestamp at time zone 'America/Toronto'; b := (v_ws + 7)::timestamp at time zone 'America/Toronto';
      select count(*), coalesce(sum(subtotal - discount), 0),
             coalesce(jsonb_agg(jsonb_build_object('number', number, 'created_at', created_at, 'mode', mode, 'status', status,
               'food', subtotal - discount) order by created_at), '[]')
        into v_n, v_food, v_lines
        from orders where client_id = c.id and created_at >= a and created_at < b and status <> 'cancelled';
      insert into invoices (number, client_id, week_start, week_end, orders, food, commission_pct, commission, total, lines, status, sent_at)
      values ('INV-' || to_char(v_ws, 'IYYY') || '-W' || to_char(v_ws, 'IW') || '-' || upper(c.id), c.id, v_ws, v_ws + 6, v_n, v_food,
              c.commission_pct, round(v_food * c.commission_pct / 100, 2), round(v_food * c.commission_pct / 100, 2), v_lines,
              case when v_n = 0 then 'nothing_due' when c.commission_pct is null then 'draft' else 'sent' end, case when v_n > 0 and c.commission_pct is not null then p_now end)
      returning * into inv;
      update orders set invoice_id = inv.id where client_id = c.id and created_at >= a and created_at < b and status <> 'cancelled';
      if inv.status = 'sent' then perform queue_invoice(inv.id); end if;
      v_made := v_made || jsonb_build_object('invoice', inv.number, 'status', inv.status);
    end if;
  end loop;
  return jsonb_build_object('ran', true, 'made', v_made);
end $$;

create or replace function public.queue_invoice(p_id uuid) returns void
language sql security definer set search_path = public as $$
  insert into outbox (kind, client_id, ref, recipients, payload)
  select 'invoice', i.client_id, i.number, billing_recipients(i.client_id),
         to_jsonb(i) - 'id' || jsonb_build_object('client', c.name)
  from invoices i join clients c on c.id = i.client_id where i.id = p_id
  on conflict (kind, ref) do nothing;
$$;

-- Proxy side of the outbox.
create or replace function public.outbox_claim(p_limit int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  with due as (select id from outbox where status = 'pending' or (status = 'failed' and attempts < 3)
               order by id for update skip locked limit least(greatest(coalesce(p_limit, 10), 1), 50)),
       upd as (update outbox o set status = 'sending', attempts = attempts + 1 from due where o.id = due.id returning o.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'client_id', client_id, 'ref', ref, 'recipients', recipients, 'payload', payload)), '[]') into v from upd;
  return v;
end $$;
create or replace function public.outbox_done(p_id bigint, p_status text, p_error text) returns void
language sql security definer set search_path = public as $$
  update outbox set status = case when p_status in ('sent', 'test_inbox', 'failed') then p_status else 'failed' end,
    sent_at = case when p_status in ('sent', 'test_inbox') then now() end, error = left(p_error, 300)
  where id = p_id and status = 'sending';
$$;

-- Consented contacts for the client's own Listmonk "Deals" list, and opt-outs coming back from it.
create or replace function public.marketing_contacts(p_client text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('email', l.email, 'name', l.first_name, 'phone', l.phone, 'store', l.first_store,
           'source', l.first_source, 'since', l.created_at, 'points', member_points(l.member_id)) order by l.created_at), '[]')
  from leads l where l.client_id = p_client and l.consent and l.email is not null
$$;
create or replace function public.marketing_optout(p_client text, p_emails text[]) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; l record;
begin
  for l in select * from leads where client_id = p_client and consent and email = any(select lower(x) from unnest(p_emails) x) loop
    update leads set consent = false where id = l.id;
    insert into consent_log (lead_id, consent, wording, source) values (l.id, false, 'Unsubscribed from the email list', 'Listmonk');
    n := n + 1;
  end loop;
  return n;
end $$;

-- Completing an order now stamps completed_at (settlements count from it).
create or replace function public.staff_set_order_status(p_staff uuid, p_id uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.orders; v_earn int;
begin
  select * into o from orders where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'msg', 'Order not found.'); end if;
  perform staff_scope(p_staff, o.client_id);
  if p_status not in ('new', 'accepted', 'ready', 'out_for_delivery', 'completed', 'cancelled') then return jsonb_build_object('ok', false, 'msg', 'Unknown status.'); end if;
  if o.status in ('completed', 'cancelled') then return jsonb_build_object('ok', false, 'msg', 'This order is already ' || o.status || '.'); end if;
  if p_status = 'out_for_delivery' and o.mode <> 'delivery' then return jsonb_build_object('ok', false, 'msg', 'Pickup orders are not delivered.'); end if;
  update orders set status = p_status, updated_at = now(), completed_at = case when p_status = 'completed' then now() end where id = o.id;
  if p_status = 'completed' and o.member_id is not null then
    v_earn := floor((o.subtotal - o.discount) * 5)::int;
    if v_earn > 0 then insert into points_ledger (member_id, client_id, delta, reason, ref) values (o.member_id, o.client_id, v_earn, 'order', o.number); end if;
    if o.fast_claim then insert into points_ledger (member_id, client_id, delta, reason, ref) values (o.member_id, o.client_id, 100, 'fast_claim', o.number); end if;
  elsif p_status = 'cancelled' then
    if o.points_used > 0 then insert into points_ledger (member_id, client_id, delta, reason, ref) values (o.member_id, o.client_id, o.points_used, 'refund', o.number); end if;
    if o.prize_used then update spins set redeemed_at = null, redeemed_store = null, order_total = null where id = o.spin_id and expires_at > now(); end if;
  end if;
  return jsonb_build_object('ok', true, 'points_awarded', coalesce(v_earn, 0) + case when p_status = 'completed' and o.fast_claim then 100 else 0 end);
end $$;

-- ---------- portal ----------
create or replace function public.staff_billing(p_staff uuid, p_client text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_scope text[] := staff_scope(p_staff, p_client);
begin
  return jsonb_build_object(
    'clients', (select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'commission_pct', c.commission_pct,
        'unsettled_credit', (select coalesce(sum(credit), 0) from orders o where o.client_id = c.id and o.status = 'completed' and o.settlement_id is null),
        'unsettled_orders', (select count(*) from orders o where o.client_id = c.id and o.status = 'completed' and o.settlement_id is null),
        'clearing', (select coalesce(sum(credit), 0) from orders o where o.client_id = c.id and o.status = 'completed' and o.settlement_id is null and o.completed_at > now() - interval '3 days'),
        'next_settlement', coalesce((select max(created_at) + interval '3 days' from settlements s where s.client_id = c.id), now()),
        'statements_unpaid', (select coalesce(sum(amount), 0) from settlements s where s.client_id = c.id and s.status = 'statement_sent'),
        'invoices_open', (select coalesce(sum(total), 0) from invoices i where i.client_id = c.id and i.status = 'sent')) order by c.name)
      from clients c where c.id = any(v_scope)),
    'settlements', coalesce((select jsonb_agg(to_jsonb(s) order by s.created_at desc) from (select * from settlements where client_id = any(v_scope) and status <> 'nothing_due' order by created_at desc limit 60) s), '[]'),
    'invoices', coalesce((select jsonb_agg(to_jsonb(i) order by i.week_start desc) from (select * from invoices where client_id = any(v_scope) order by week_start desc limit 60) i), '[]'),
    'reports', coalesce((select jsonb_agg(jsonb_build_object('client_id', r.client_id, 'week_start', r.week_start, 'data', r.data) order by r.week_start desc) from (select * from weekly_reports where client_id = any(v_scope) order by week_start desc limit 20) r), '[]'),
    'outbox', coalesce((select jsonb_agg(jsonb_build_object('kind', o.kind, 'ref', o.ref, 'status', o.status, 'sent_at', o.sent_at, 'error', o.error) order by o.id desc) from (select * from outbox where client_id = any(v_scope) order by id desc limit 30) o), '[]'));
end $$;

create or replace function public.staff_billing_rate(p_staff uuid, p_client text, p_pct numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform staff_require_super(p_staff);
  if p_pct is not null and (p_pct < 0 or p_pct > 50) then return jsonb_build_object('ok', false, 'msg', 'Use a rate from 0 to 50%.'); end if;
  update clients set commission_pct = p_pct where id = p_client;
  if not found then return jsonb_build_object('ok', false, 'msg', 'Unknown client.'); end if;
  update invoices set commission_pct = p_pct, commission = round(food * p_pct / 100, 2), total = round(food * p_pct / 100, 2)
   where client_id = p_client and status = 'draft';
  return jsonb_build_object('ok', true);
end $$;

-- Super admin: send a draft invoice, mark an invoice or settlement paid, void an invoice, or run billing now.
create or replace function public.staff_billing_action(p_staff uuid, p_action text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare i public.invoices;
begin
  perform staff_require_super(p_staff);
  if p_action = 'run' then return jsonb_build_object('ok', true, 'result', billing_tick(now())); end if;
  if p_action = 'invoice_send' then
    select * into i from invoices where id = p_id for update;
    if not found then return jsonb_build_object('ok', false, 'msg', 'Invoice not found.'); end if;
    if i.status <> 'draft' then return jsonb_build_object('ok', false, 'msg', 'Only drafts can be sent.'); end if;
    if i.commission_pct is null then return jsonb_build_object('ok', false, 'msg', 'Set the commission rate for this client first.'); end if;
    update invoices set status = 'sent', sent_at = now() where id = i.id;
    perform queue_invoice(i.id);
  elsif p_action = 'invoice_paid' then update invoices set status = 'paid', paid_at = now() where id = p_id and status = 'sent';
  elsif p_action = 'invoice_void' then update invoices set status = 'void' where id = p_id and status in ('draft', 'sent');
  elsif p_action = 'settlement_paid' then update settlements set status = 'paid', paid_at = now() where id = p_id and status = 'statement_sent';
  else return jsonb_build_object('ok', false, 'msg', 'Unknown action.'); end if;
  if not found then return jsonb_build_object('ok', false, 'msg', 'Nothing changed (wrong state).'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- Onboarding: the reminder step now means Listmonk; billing terms are agreed at the start.
update public.onboarding_steps set title = 'Client email (Listmonk) set up',
  detail = 'The client''s own Listmonk (server/listmonk) has a real SMTP sender. Until then reminders go to the local test inbox only.'
 where id = 'reminder-sender';
insert into public.onboarding_steps (id, stage, sort, title, detail, owner) values
  ('billing-terms', 1, 4, 'Commission and billing agreed', 'Commission rate on Platterly orders, invoice every Wednesday for the week to Sunday, settlement of points every 3 days.', 'both')
on conflict (id) do nothing;

do $$ declare f text; begin
  foreach f in array array['billing_recipients(text)', 'week_numbers(text,date)', 'billing_tick(timestamptz)', 'queue_invoice(uuid)',
    'outbox_claim(int)', 'outbox_done(bigint,text,text)', 'marketing_contacts(text)', 'marketing_optout(text,text[])',
    'staff_billing(uuid,text)', 'staff_billing_rate(uuid,text,numeric)', 'staff_billing_action(uuid,text,uuid)',
    'staff_set_order_status(uuid,uuid,text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
