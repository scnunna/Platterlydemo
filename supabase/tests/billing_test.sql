-- Run: docker exec -i supabase_db_platterly psql -U postgres -v ON_ERROR_STOP=1 -q < supabase/tests/billing_test.sql
-- Settlement every 3 days, Wednesday invoice for the week to Sunday, weekly report, outbox, Listmonk sync helpers.
-- Week under test: Monday 2026-10-05 .. Sunday 2026-10-11 (America/Toronto). Rolled back.
begin;
delete from public.outbox; delete from public.settlements; delete from public.invoices; delete from public.weekly_reports;
update public.clients set created_at = '2026-09-01', commission_pct = null;
update public.clients set commission_pct = 10 where id = 'panago';
select public.staff_upsert('super@test.ca', 'Super', 'super_admin', null, 'correct horse battery');
select public.staff_upsert('pg@test.ca', 'Pg Owner', 'client_admin', 'panago', 'panago owner pass 1');
select public.staff_upsert('wz@test.ca', 'Wz Owner', 'client_admin', 'wetzels', 'wetzels owner pass');
create function pg_temp.t(s text) returns timestamptz language sql as $$ select (s::timestamp at time zone 'America/Toronto') $$;
insert into public.orders (number, client_id, store_id, mode, name, items, subtotal, discount, tax, points_used, credit, total, payment, status, created_at, completed_at) values
  ('PO-TEST01', 'panago', 'gerrard', 'pickup',   'A', '[]', 30, 3, 3.51, 150, 1.50, 29.01, 'pay_at_store',    'completed', pg_temp.t('2026-10-06 12:00'), pg_temp.t('2026-10-06 12:30')),
  ('PO-TEST02', 'panago', 'bremner', 'delivery', 'B', '[]', 20, 0, 2.60, 0,   0,    22.60, 'pay_on_delivery', 'completed', pg_temp.t('2026-10-11 23:30'), pg_temp.t('2026-10-12 00:10')),
  ('PO-TEST03', 'panago', 'gerrard', 'pickup',   'C', '[]', 10, 0, 1.30, 0,   0,    11.30, 'card_demo',       'completed', pg_temp.t('2026-10-12 00:30'), pg_temp.t('2026-10-12 01:00')),
  ('PO-TEST04', 'panago', 'gerrard', 'pickup',   'D', '[]', 50, 0, 6.50, 0,   0,    56.50, 'pay_at_store',    'cancelled', pg_temp.t('2026-10-07 18:00'), null),
  ('PO-TEST05', 'wetzels', 'eaton',  'pickup',   'E', '[]', 12.98, 2, 1.43, 200, 2.00, 10.41, 'pay_at_store', 'completed', pg_temp.t('2026-10-08 14:00'), pg_temp.t('2026-10-08 14:05'));

do $$ declare x jsonb; s uuid := (select id from public.staff where email = 'super@test.ca'); pg uuid := (select id from public.staff where email = 'pg@test.ca');
             wz uuid := (select id from public.staff where email = 'wz@test.ca'); v_id uuid; begin
  -- before 9 AM nothing happens
  assert not (public.billing_tick(pg_temp.t('2026-10-13 08:00'))->>'ran')::boolean, 'nothing before 9 AM';
  -- Tuesday 9:30: first settlement (orders completed by Sat 9:30) and last week's report; no invoice before Wednesday
  x := public.billing_tick(pg_temp.t('2026-10-13 09:30'));
  assert (select amount from public.settlements where client_id = 'panago') = 1.50 and (select orders from public.settlements where client_id = 'panago') = 1, 'Panago: only the order cleared 3+ days ago';
  assert (select amount from public.settlements where client_id = 'wetzels') = 2.00, 'Wetzel''s: points credit owed';
  assert (select settlement_id is null from public.orders where number = 'PO-TEST02'), 'Monday order still clearing';
  assert (select count(*) from public.weekly_reports where week_start = '2026-10-05') = 2, 'weekly report per client';
  assert not exists (select 1 from public.invoices), 'no invoice on Tuesday';
  assert (select count(*) from public.outbox where kind = 'settlement') = 2 and (select count(*) from public.outbox where kind = 'weekly_report') = 2, 'emails queued';
  assert (select recipients from public.outbox where kind = 'settlement' and client_id = 'panago') @> array['pg@test.ca', 'super@test.ca']
     and not (select recipients from public.outbox where kind = 'settlement' and client_id = 'panago') @> array['wz@test.ca'], 'right recipients';
  x := (select payload from public.outbox where kind = 'weekly_report' and client_id = 'panago');
  assert (x->>'orders')::int = 2 and (x->>'cancelled')::int = 1 and (x->>'food')::numeric = 47 and (x->>'delivery')::int = 1, 'report: the week''s orders ' || x::text;
  -- Wednesday 9:30: invoice for every order taken Mon..Sun (not the Monday-after order, not the cancelled one)
  x := public.billing_tick(pg_temp.t('2026-10-14 09:30'));
  assert (select number || ' ' || orders || ' ' || food || ' ' || commission || ' ' || status from public.invoices where client_id = 'panago')
       = 'INV-2026-W41-PANAGO 2 47.00 4.70 sent', 'Panago invoice: 2 orders, 10% of $47';
  assert (select status from public.invoices where client_id = 'wetzels') = 'draft', 'no rate: draft, not sent';
  assert (select count(*) from public.outbox where kind = 'invoice') = 1, 'only the sent invoice is emailed';
  assert (select count(*) from public.settlements) = 2, 'no second settlement within 3 days';
  x := public.billing_tick(pg_temp.t('2026-10-14 15:00'));
  assert (select count(*) from public.invoices) = 2 and (select count(*) from public.outbox) = 5, 'idempotent';
  -- Friday: next settlement picks up the orders that have now cleared
  x := public.billing_tick(pg_temp.t('2026-10-16 09:30'));
  assert (select orders from public.settlements where client_id = 'panago' order by created_at desc limit 1) = 2, 'second settlement: the two cleared orders';
  assert (select count(*) from public.settlements where client_id = 'wetzels' and status = 'nothing_due') = 1, 'nothing due is recorded quietly';
  assert (select count(*) from public.outbox where kind = 'settlement') = 3, 'no email for nothing due';

  -- portal: client admins see only their own; actions are super admin only
  x := public.staff_billing(wz, null);
  assert jsonb_array_length(x->'clients') = 1 and x->'clients'->0->>'id' = 'wetzels' and not (x->'invoices') @> '[{"client_id":"panago"}]', 'scoped billing view';
  begin perform public.staff_billing(wz, 'panago'); raise exception 'cross-client billing read'; exception when insufficient_privilege then null; end;
  begin perform public.staff_billing_rate(wz, 'wetzels', 5); raise exception 'client set own rate'; exception when insufficient_privilege then null; end;
  begin perform public.staff_billing_action(pg, 'run', null); raise exception 'client ran billing'; exception when insufficient_privilege then null; end;
  assert not (public.staff_billing_rate(s, 'wetzels', 80)->>'ok')::boolean, 'rate capped at 50%';
  perform public.staff_billing_rate(s, 'wetzels', 12);
  assert (select commission from public.invoices where client_id = 'wetzels') = 1.32, 'draft recalculated: 12% of $10.98';
  v_id := (select id from public.invoices where client_id = 'wetzels');
  assert (public.staff_billing_action(s, 'invoice_send', v_id)->>'ok')::boolean, 'draft send ok';
  assert (select status from public.invoices where id = v_id) = 'sent', 'draft sent';
  assert not (public.staff_billing_action(s, 'invoice_send', v_id)->>'ok')::boolean, 'cannot send twice';
  assert (public.staff_billing_action(s, 'settlement_paid', (select id from public.settlements where client_id = 'panago' order by created_at limit 1))->>'ok')::boolean, 'settlement paid';
  assert (public.staff_billing_action(s, 'invoice_paid', v_id)->>'ok')::boolean, 'invoice paid';
  x := public.staff_billing(s, 'panago');
  assert (x->'clients'->0->>'invoices_open')::numeric = 4.70, 'open invoices';

  -- outbox: claimed once, marked
  x := public.outbox_claim(50);
  assert jsonb_array_length(x) = 7 and jsonb_array_length(public.outbox_claim(50)) = 0, 'claimed once';
  perform public.outbox_done((x->0->>'id')::bigint, 'test_inbox', null);
  assert (select status from public.outbox where id = (x->0->>'id')::bigint) = 'test_inbox', 'marked';
  perform public.outbox_done((x->1->>'id')::bigint, 'failed', 'smtp down');
  assert (select count(*) from jsonb_array_elements(public.outbox_claim(50))) = 1, 'failed mail is retried';
end $$;

-- Listmonk sync helpers: only consented emails go to the deals list; an unsubscribe there turns consent off here
create temp table c (k text primary key, v jsonb); grant all on c to anon;
set local role anon;
insert into c values ('y', public.submit_claim('panago', 'gerrard', 'Yes', 'yes@test.ca', null, true, false, 'pop', false, null, 'w'));
insert into c values ('n', public.submit_claim('panago', 'gerrard', 'No', 'no@test.ca', null, false, false, 'pop', false, null, null));
insert into c values ('p', public.submit_claim('panago', 'gerrard', 'Phone', null, '4165550111', true, false, 'pop', false, null, 'w'));
reset role;
do $$ declare x jsonb := public.marketing_contacts('panago'); begin
  assert x @> '[{"email":"yes@test.ca"}]' and not x @> '[{"email":"no@test.ca"}]' and not x::text like '%4165550111%', 'consented emails only';
  assert public.marketing_optout('panago', array['YES@test.ca']) = 1, 'one opt-out';
  assert not (select consent from public.leads where email = 'yes@test.ca'), 'unsubscribe syncs back';
  assert (select wording from public.consent_log l join public.leads d on d.id = l.lead_id where d.email = 'yes@test.ca' order by l.id desc limit 1) like 'Unsubscribed%', 'logged';
end $$;
set local role anon;
do $$ begin
  begin perform public.billing_tick(now()); raise exception 'anon ran billing'; exception when insufficient_privilege then null; end;
  begin perform public.marketing_contacts('panago'); raise exception 'anon read contacts'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.invoices; raise exception 'anon read invoices'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'billing_test: all passed';
rollback;
