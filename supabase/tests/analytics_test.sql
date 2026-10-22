-- Run: docker exec -i supabase_db_platterly psql -U postgres -v ON_ERROR_STOP=1 -q < supabase/tests/analytics_test.sql
-- Page-step events, the TV's live numbers, the portal funnel and per-client commission settings. Rolled back.
begin;
delete from public.events; delete from public.invoices; delete from public.commission_history;
update public.clients set created_at = '2026-09-01', commission_pct = null, commission_from = null, billing_email = null, commission_note = null;
select public.staff_upsert('super@test.ca', 'Super', 'super_admin', null, 'correct horse battery');
select public.staff_upsert('pg@test.ca', 'Pg Owner', 'client_admin', 'panago', 'panago owner pass 1');
create function pg_temp.t(s text) returns timestamptz language sql as $$ select (s::timestamp at time zone 'America/Toronto') $$;

do $$ declare x jsonb; s uuid := (select id from public.staff where email = 'super@test.ca'); pg uuid := (select id from public.staff where email = 'pg@test.ca'); r jsonb; begin
  -- events: one per step per session, unknown clients and steps ignored, a store from another client dropped
  perform public.track_event('panago', 'gerrard', '2', 'view', 'sess-a');
  perform public.track_event('panago', 'gerrard', '2', 'view', 'sess-a');
  perform public.track_event('panago', 'gerrard', '2', 'spin', 'sess-a');
  perform public.track_event('panago', 'eaton', '5', 'view', 'sess-b');
  assert not (public.track_event('nope', null, null, 'view', 'x')->>'ok')::boolean, 'unknown client refused';
  assert not (public.track_event('panago', null, null, 'claim', 'x')->>'ok')::boolean, 'unknown step refused';
  assert (select count(*) from public.events where sid = 'sess-a') = 2, 'reload does not double count';
  assert (select store_id from public.events where sid = 'sess-b') is null, 'another client''s store is not kept';

  -- a claim from TV screen 2 joins the same funnel row
  x := public.submit_claim('panago', 'gerrard', 'Priya', 'priya-an@test.ca', null, true, false, 'pop', false, 'tv-2', 'w');
  r := public.staff_analytics(s, 'panago', 30);
  x := (select e from jsonb_array_elements(r->'rows') e where e->>'store' = 'gerrard' and e->>'screen' = '2');
  assert (x->>'views')::int = 1 and (x->>'spins')::int = 1 and (x->>'claims')::int = 1 and (x->>'redeemed')::int = 0, 'funnel row ' || x::text;
  assert jsonb_array_length(r->'days') >= 30, 'one row per day';
  -- a client admin only sees their own client
  assert not exists (select 1 from jsonb_array_elements(public.staff_analytics(pg, null, 30)->'rows') e where e->>'client_id' <> 'panago'), 'scoped to own client';

  -- TV stats: first names and prizes only, today only
  x := public.public_stats('panago', 'gerrard');
  assert (x->>'spins_today')::int >= 1 and x->'recent'->0->>'name' = 'Priya' and x->'recent'->0 ? 'prize' and not (x->'recent'->0 ? 'contact'), 'tv stats ' || x::text;
  assert (x->>'next_draw')::date = (date_trunc('month', (now() at time zone 'America/Toronto')::date) + interval '1 month')::date, 'next draw is the 1st of next month';

  -- commissions: super admin only, validated, history kept, drafts re-rated from the start date on
  begin perform public.staff_commissions(pg); assert false, 'client admin must not see commissions'; exception when insufficient_privilege then null; end;
  assert not (public.staff_commission_set(s, 'panago', 60, null, null, null)->>'ok')::boolean, 'rate over 50 refused';
  assert not (public.staff_commission_set(s, 'panago', 8, null, 'not-an-email', null)->>'ok')::boolean, 'bad billing email refused';
  insert into public.invoices (number, client_id, week_start, week_end, orders, food, lines, status) values
    ('INV-T1', 'panago', '2026-10-05', '2026-10-11', 1, 100, '[]', 'draft'), ('INV-T2', 'panago', '2026-10-12', '2026-10-18', 1, 200, '[]', 'draft');
  assert (public.staff_commission_set(s, 'panago', 8, '2026-10-12', 'Billing@Panago.test', 'Signed 2026-10-20')->>'ok')::boolean, 'set rate';
  assert (select commission from public.invoices where number = 'INV-T2') = 16.00, 'draft from the start date re-rated';
  assert (select commission from public.invoices where number = 'INV-T1') is null, 'draft before the start date untouched';
  assert public.commission_for('panago', '2026-10-05') is null and public.commission_for('panago', '2026-10-12') = 8, 'rate applies from the start date';
  assert public.billing_recipients('panago') @> array['billing@panago.test', 'pg@test.ca', 'super@test.ca'], 'billing email gets invoices';
  x := (select e from jsonb_array_elements(public.staff_commissions(s)) e where e->>'id' = 'panago');
  assert (x->>'pct')::numeric = 8 and x->>'billing_email' = 'billing@panago.test' and jsonb_array_length(x->'history') = 1 and x->'history'->0->>'by' = 'super@test.ca', 'settings ' || x::text;
end $$;

-- anon may track and read TV stats, but not the funnel or commissions
set local role anon;
do $$ begin
  perform public.track_event('panago', null, '1', 'view', 'anon-sess');
  perform public.public_stats('panago', null);
  begin perform public.staff_analytics(gen_random_uuid(), null, 30); assert false, 'anon must not read the funnel'; exception when insufficient_privilege then null; end;
  begin perform public.staff_commissions(gen_random_uuid()); assert false, 'anon must not read commissions'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'analytics_test: all passed';
rollback;
