-- Analytics, the TV's live numbers, and per-client commission settings.
--   events: page steps the database cannot see on its own (QR page opened, wheel spun, join form opened), per store
--     and per TV screen (the QR's c= number). Claims, redemptions and orders come from spins and orders.
--   public_stats: spins today, the next monthly lunch draw and recent winners (first names only) for the TV.
--   Commissions: rate, start date, invoice email, notes and a change history per client (super admin only).

create table public.events (
  id         bigint generated always as identity primary key,
  client_id  text not null references public.clients(id) on delete cascade,
  store_id   text references public.stores(id),
  screen     text check (length(screen) <= 20),
  step       text not null check (step in ('view', 'spin', 'join')),
  sid        text check (length(sid) <= 40),
  created_at timestamptz not null default now()
);
create index events_client_idx on public.events (client_id, created_at desc);
create index spins_client_day_idx on public.spins (client_id, created_at desc);
alter table public.events enable row level security;
revoke all on public.events from anon, authenticated;

-- One row per step per browser session, so reloading the page does not inflate the numbers.
create unique index events_once_idx on public.events (sid, step) where sid is not null;

create or replace function public.track_event(p_client text, p_store text, p_screen text, p_step text, p_sid text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from clients where id = p_client) or p_step not in ('view', 'spin', 'join') then
    return jsonb_build_object('ok', false);
  end if;
  insert into events (client_id, store_id, screen, step, sid)
  values (p_client, (select id from stores where id = p_store and client_id = p_client), left(nullif(btrim(p_screen), ''), 20), p_step, left(nullif(p_sid, ''), 40))
  on conflict (sid, step) where sid is not null do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- The TV screen's live strip. First names only; a winner is shown at most for the day they won.
create or replace function public.public_stats(p_client text, p_store text) returns jsonb
language sql stable security definer set search_path = public as $$
  with today as (select (now() at time zone 'America/Toronto')::date d)
  select jsonb_build_object(
    'spins_today', (select count(*) from spins s, today where s.client_id = p_client and s.spin_day = today.d
                      and (p_store is null or s.store_id = p_store or s.store_id is null)),
    'next_draw', (select (date_trunc('month', today.d) + interval '1 month')::date from today),
    'recent', coalesce((select jsonb_agg(r) from (
        select l.first_name as name, case when s.upsized then o.big_title else o.title end as prize,
               floor(extract(epoch from now() - s.created_at) / 60)::int as ago_min
          from spins s join leads l on l.id = s.lead_id join offers o on o.id = s.offer_id, today
         where s.client_id = p_client and s.spin_day = today.d and (p_store is null or s.store_id = p_store or s.store_id is null)
         order by s.created_at desc limit 5) r), '[]'))
$$;

-- Funnel for the portal: per store and per TV screen, over the last p_days days.
create or replace function public.staff_analytics(p_staff uuid, p_client text, p_days int) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_scope text[] := staff_scope(p_staff, p_client); v_from timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)));
begin
  return (with
    ev as (select client_id, coalesce(store_id, '') store, coalesce(screen, 'direct') screen, step, created_at from events
            where client_id = any(v_scope) and created_at >= v_from),
    sp as (select s.id, s.client_id, coalesce(s.store_id, '') store, coalesce(nullif(regexp_replace(coalesce(s.source, ''), '^tv-', ''), ''), 'direct') screen,
                  s.redeemed_at, s.created_at from spins s where s.client_id = any(v_scope) and s.created_at >= v_from),
    od as (select o.spin_id, o.subtotal - o.discount food from orders o where o.client_id = any(v_scope) and o.created_at >= v_from and o.status <> 'cancelled'),
    keys as (select client_id, store, screen from ev union select client_id, store, screen from sp),
    rows as (
      select k.client_id, k.store, k.screen,
        (select count(*) from ev where (ev.client_id, ev.store, ev.screen) = (k.client_id, k.store, k.screen) and step = 'view') views,
        (select count(*) from ev where (ev.client_id, ev.store, ev.screen) = (k.client_id, k.store, k.screen) and step = 'spin') spins,
        (select count(*) from ev where (ev.client_id, ev.store, ev.screen) = (k.client_id, k.store, k.screen) and step = 'join') joins,
        (select count(*) from sp where (sp.client_id, sp.store, sp.screen) = (k.client_id, k.store, k.screen)) claims,
        (select count(*) from sp where (sp.client_id, sp.store, sp.screen) = (k.client_id, k.store, k.screen) and redeemed_at is not null) redeemed,
        (select count(*) from od join sp on sp.id = od.spin_id where (sp.client_id, sp.store, sp.screen) = (k.client_id, k.store, k.screen)) orders,
        (select coalesce(sum(od.food), 0) from od join sp on sp.id = od.spin_id where (sp.client_id, sp.store, sp.screen) = (k.client_id, k.store, k.screen)) food
      from keys k),
    days as (select d::date as day,
        (select count(*) from events e where e.client_id = any(v_scope) and e.step = 'view' and (e.created_at at time zone 'America/Toronto')::date = d::date) views,
        (select count(*) from spins s where s.client_id = any(v_scope) and s.spin_day = d::date) claims,
        (select count(*) from spins s where s.client_id = any(v_scope) and (s.redeemed_at at time zone 'America/Toronto')::date = d::date) redeemed
      from generate_series((v_from at time zone 'America/Toronto')::date, (now() at time zone 'America/Toronto')::date, interval '1 day') d)
    select jsonb_build_object('since', v_from,
      'rows', coalesce((select jsonb_agg(to_jsonb(r) order by r.client_id, r.store, r.screen) from rows r), '[]'),
      'days', coalesce((select jsonb_agg(to_jsonb(d) order by d.day) from days d), '[]')));
end $$;

-- ---------- commissions ----------
alter table public.clients
  add column commission_from date,
  add column billing_email text check (billing_email is null or billing_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  add column commission_note text check (length(commission_note) <= 500);

create table public.commission_history (
  id         bigint generated always as identity primary key,
  client_id  text not null references public.clients(id) on delete cascade,
  pct        numeric(5,2),
  from_date  date,
  note       text,
  changed_by text,
  changed_at timestamptz not null default now()
);
alter table public.commission_history enable row level security;
revoke all on public.commission_history from anon, authenticated;

-- Invoices also go to the client's billing email, when one is set.
create or replace function public.billing_recipients(p_client text) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct e), '{}') from (
    select email e from staff where active and (client_id = p_client or role = 'super_admin')
    union select billing_email from clients where id = p_client and billing_email is not null) x
$$;

create or replace function public.staff_commissions(p_staff uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform staff_require_super(p_staff);
  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'pct', c.commission_pct, 'from', c.commission_from,
      'billing_email', c.billing_email, 'note', c.commission_note,
      'food_28d', (select coalesce(sum(o.subtotal - o.discount), 0) from orders o where o.client_id = c.id and o.status = 'completed' and o.completed_at > now() - interval '28 days'),
      'drafts', (select count(*) from invoices i where i.client_id = c.id and i.status = 'draft'),
      'history', coalesce((select jsonb_agg(jsonb_build_object('pct', h.pct, 'from', h.from_date, 'note', h.note, 'by', h.changed_by, 'at', h.changed_at) order by h.id desc)
                           from (select * from commission_history where client_id = c.id order by id desc limit 10) h), '[]')) order by c.name)
    from clients c), '[]');
end $$;

-- Set a client's commission. Draft invoices are re-rated, as staff_billing_rate did; sent ones never change.
create or replace function public.staff_commission_set(p_staff uuid, p_client text, p_pct numeric, p_from date, p_billing_email text, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.staff := staff_require_super(p_staff);
begin
  if p_pct is not null and (p_pct < 0 or p_pct > 50) then return jsonb_build_object('ok', false, 'msg', 'Use a rate from 0 to 50%.'); end if;
  if nullif(btrim(p_billing_email), '') is not null and btrim(p_billing_email) !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return jsonb_build_object('ok', false, 'msg', 'That billing email does not look right.');
  end if;
  update clients set commission_pct = p_pct, commission_from = p_from, billing_email = lower(nullif(btrim(p_billing_email), '')),
         commission_note = nullif(btrim(left(p_note, 500)), '')
   where id = p_client;
  if not found then return jsonb_build_object('ok', false, 'msg', 'Unknown client.'); end if;
  insert into commission_history (client_id, pct, from_date, note, changed_by) values (p_client, p_pct, p_from, nullif(btrim(left(p_note, 500)), ''), s.email);
  update invoices set commission_pct = p_pct, commission = round(food * p_pct / 100, 2), total = round(food * p_pct / 100, 2)
   where client_id = p_client and status = 'draft' and (p_from is null or week_start >= p_from);
  return jsonb_build_object('ok', true);
end $$;

-- The billing tick only charges weeks on or after the rate's start date; earlier weeks stay drafts.
create or replace function public.commission_for(p_client text, p_week date) returns numeric
language sql stable security definer set search_path = public as $$
  select case when commission_from is null or p_week >= commission_from then commission_pct end from clients where id = p_client
$$;

-- billing_tick as before, with the rate taken from commission_for (start date respected).
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
        billing_recipients(c.id), week_numbers(c.id, v_ws) || jsonb_build_object('client', c.name, 'commission_pct', commission_for(c.id, v_ws)))
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
              commission_for(c.id, v_ws), round(v_food * commission_for(c.id, v_ws) / 100, 2), round(v_food * commission_for(c.id, v_ws) / 100, 2), v_lines,
              case when v_n = 0 then 'nothing_due' when commission_for(c.id, v_ws) is null then 'draft' else 'sent' end, case when v_n > 0 and commission_for(c.id, v_ws) is not null then p_now end)
      returning * into inv;
      update orders set invoice_id = inv.id where client_id = c.id and created_at >= a and created_at < b and status <> 'cancelled';
      if inv.status = 'sent' then perform queue_invoice(inv.id); end if;
      v_made := v_made || jsonb_build_object('invoice', inv.number, 'status', inv.status);
    end if;
  end loop;
  return jsonb_build_object('ran', true, 'made', v_made);
end $$;

do $$ declare f text; begin
  foreach f in array array['track_event(text,text,text,text,text)', 'public_stats(text,text)'] loop
    execute format('revoke all on function public.%s from public, authenticated', f);
    execute format('grant execute on function public.%s to anon, service_role', f);
  end loop;
  foreach f in array array['staff_analytics(uuid,text,int)', 'staff_commissions(uuid)', 'staff_commission_set(uuid,text,numeric,date,text,text)',
    'commission_for(text,date)', 'billing_recipients(text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
