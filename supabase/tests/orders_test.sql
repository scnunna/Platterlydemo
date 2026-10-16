-- Run: docker exec -i supabase_db_platterly psql -U postgres -v ON_ERROR_STOP=1 -q < supabase/tests/orders_test.sql
-- Platterly claims (email and/or phone, 2-hour window, reminders), members across brands, points, orders. Rolled back.
begin;
select public.staff_upsert('pg@test.ca', 'Pg Owner', 'client_admin', 'panago', 'panago owner pass 1');
select public.staff_upsert('wz@test.ca', 'Wz Owner', 'client_admin', 'wetzels', 'wetzels owner pass');
create temp table t (k text primary key, v jsonb); grant all on t to anon;
set local role anon;
-- both contacts, reminder on
insert into t values ('a', public.submit_claim('panago', 'gerrard', 'Ana', 'Ana@Test.ca', '(416) 555-0101', true, true, 'dip', false, 'tv-2', 'w'));
-- same person at another brand, phone only: same Platterly member
insert into t values ('w', public.submit_claim('wetzels', 'eaton', 'Ana', null, '416 555 0101', false, true, 'wp-off', false, 'tv-1', null));
-- phone only, no reminder
insert into t values ('b', public.submit_claim('panago', 'bremner', 'Ben', '', '6475550199', false, false, 'tenoff', false, 'tv-3', null));
-- again today: same code back
insert into t values ('a2', public.submit_claim('panago', 'gerrard', 'Ana', 'ana@test.ca', null, false, true, 'pop', false, 'tv-2', null));
reset role;

do $$ declare a jsonb := (select v from t where k = 'a'); w jsonb := (select v from t where k = 'w'); b jsonb := (select v from t where k = 'b');
             mem uuid; x jsonb; q jsonb; o jsonb; pg uuid := (select id from public.staff where email = 'pg@test.ca'); wz uuid := (select id from public.staff where email = 'wz@test.ca'); begin
  -- claims
  assert a->>'code' ~ '^PL-[A-Z2-9]{6}$' and w->>'code' ~ '^PL-', 'Platterly codes for every brand';
  assert (a->>'has_email')::boolean and (a->>'has_phone')::boolean, 'both contacts kept';
  assert (select email || ' ' || phone from public.leads where client_id = 'panago' and first_name = 'Ana') = 'ana@test.ca +14165550101', 'lead has both';
  assert (select count(*) from public.members where email = 'ana@test.ca' or phone = '+14165550101') = 1, 'one member across brands';
  assert (select count(distinct member_id) from public.leads where first_name = 'Ana') = 1, 'both leads point at the member';
  assert (w->>'has_email')::boolean, 'phone-only claim at a second brand still knows the email';
  assert (select v->>'code' from t where k = 'a2') = a->>'code' and (select (v->>'already')::boolean from t where k = 'a2'), 'same code later today';
  assert (a->>'hold_until')::timestamptz between now() + interval '119 minutes' and now() + interval '121 minutes'
      or (a->>'hold_until')::timestamptz = (a->>'expires_at')::timestamptz, '2-hour window (or close, if sooner)';
  assert (a->>'expires_at')::timestamptz = public.store_close('gerrard', (now() at time zone 'America/Toronto')::date)
      or (a->>'expires_at')::timestamptz = public.store_close('gerrard', (now() at time zone 'America/Toronto')::date + 1), 'valid until store close';
  assert a->>'reminder' in ('email') or a->>'reminder' is null, 'email reminder preferred when both given';
  assert b->>'reminder' is null and not exists (select 1 from public.reminders r join public.spins s on s.id = r.spin_id where s.code = b->>'code'), 'no reminder when declined';
  -- input checks
  begin perform public.submit_claim('panago', 'gerrard', 'Zed', null, null, false, false, 'dip', false, null, null); raise exception 'no contact accepted';
  exception when invalid_parameter_value then null; end;
  begin perform public.submit_claim('panago', 'gerrard', 'Zed', 'not-an-email', null, false, false, 'dip', false, null, null); raise exception 'bad email accepted';
  exception when invalid_parameter_value then null; end;
  begin perform public.submit_claim('panago', 'gerrard', 'Zed', null, '12345', false, false, 'dip', false, null, null); raise exception 'bad phone accepted';
  exception when invalid_parameter_value then null; end;

  -- reminders: due ones are claimed once, and a used code's reminder is cancelled
  update public.reminders set due_at = now() - interval '1 minute';
  x := public.reminders_claim(10);
  assert jsonb_array_length(x) >= 1 and x->0->>'code' like 'PL-%' and x->0 ? 'expires_at', 'due reminder claimed with its details';
  assert jsonb_array_length(public.reminders_claim(10)) = 0, 'not claimed twice';
  perform public.reminder_done((x->0->>'id')::bigint, 'test_inbox', null);
  assert (select status from public.reminders where id = (x->0->>'id')::bigint) = 'test_inbox', 'reminder marked';

  -- menu and quotes
  x := public.menu_for('panago');
  assert jsonb_array_length(x->'items') = 59 and not (x->'items') @> '[{"id":"pop"}]', 'orderable menu only';
  assert x->'stores' @> '[{"id":"gerrard","delivery":true}]', 'Panago delivers';
  assert public.menu_for('wetzels')->'stores' @> '[{"id":"eaton","delivery":false,"pickup":true}]', 'Wetzel''s pickup only for now';
  q := public.quote_order(a->>'code', '[{"id":"cheese","size":"M","qty":1}]', true, 0);
  assert not (q->>'prize_applied')::boolean and q->>'prize_note' like 'To use your prize%', 'medium pizza does not unlock a large-pizza prize';
  q := public.quote_order(a->>'code', '[{"id":"cheese","size":"L","qty":1}]', true, 0);
  assert (q->>'prize_applied')::boolean and q->'lines' @> '[{"id":"dip","price":0,"prize":true}]', 'free dip added at $0';
  assert (q->>'subtotal')::numeric = 17.75 and (q->>'tax')::numeric = 2.31 and (q->>'total')::numeric = 20.06, 'server prices: 17.75 + 13% HST';
  q := public.quote_order(b->>'code', '[{"id":"ev-pep","size":"L","qty":5}]', true, 0);
  assert (q->>'discount')::numeric = 9.00, '10% off 5 pizzas';
  q := public.quote_order(w->>'code', '[{"id":"original","qty":1}]', true, 0);
  assert not (q->>'prize_applied')::boolean, '$2 off needs $10';
  q := public.quote_order(w->>'code', '[{"id":"original","qty":2}]', true, 0);
  assert (q->>'discount')::numeric = 2.00, '$2 off over $10';
  begin perform public.quote_order(a->>'code', '[{"id":"cheese","qty":1}]', true, 0); raise exception 'missing size accepted';
  exception when invalid_parameter_value then null; end;
  begin perform public.quote_order(a->>'code', '[{"id":"pop","qty":1}]', true, 0); raise exception 'prize-only item sold';
  exception when invalid_parameter_value then null; end;

  -- order: delivery same price, prize used, code consumed, reminder cancelled
  begin perform public.place_order(a->>'code', 'gerrard', 'delivery', 'Ana', null, '100 Bay St', null, '[{"id":"cheese","size":"L","qty":1}]', true, 0, 'pay_on_delivery');
    raise exception 'delivery without phone';
  exception when invalid_parameter_value then null; end;
  begin perform public.place_order(w->>'code', 'eaton', 'delivery', 'Ana', '4165550101', '220 Yonge St', null, '[{"id":"original","qty":2}]', true, 0, 'pay_on_delivery');
    raise exception 'Wetzel''s delivery accepted';
  exception when invalid_parameter_value then null; end;
  o := public.place_order(a->>'code', 'gerrard', 'delivery', 'Ana', '416 555 0101', '100 Bay St, 12th floor', 'buzz 12', '[{"id":"cheese","size":"L","qty":1}]', true, 0, 'pay_on_delivery');
  assert (o->>'ok')::boolean and o->>'number' ~ '^PO-' and (o->>'prize_used')::boolean and (o->>'total')::numeric = 20.06, 'order placed at counter price, no delivery fee';
  assert (select redeemed_at is not null from public.spins where code = a->>'code'), 'code used by the order';
  assert (public.order_status(o->>'number', a->>'code')->>'status') = 'new', 'customer can see status';
  assert not (public.order_status(o->>'number', b->>'code')->>'ok')::boolean, 'another code cannot see it';
  -- staff see only their client's orders; completion awards points (5 per $1 food + 100 fast-claim bonus)
  assert public.staff_orders(pg, null) @> jsonb_build_array(jsonb_build_object('number', o->>'number')), 'Panago sees its order';
  assert not public.staff_orders(wz, null) @> jsonb_build_array(jsonb_build_object('number', o->>'number')), 'Wetzel''s does not';
  begin perform public.staff_set_order_status(wz, (select id from public.orders where number = o->>'number'), 'accepted'); raise exception 'cross-client status';
  exception when insufficient_privilege then null; end;
  mem := (select member_id from public.spins where code = a->>'code');
  x := public.staff_set_order_status(pg, (select id from public.orders where number = o->>'number'), 'completed');
  assert (x->>'points_awarded')::int = 88 + 100, 'points: floor(17.75 * 5) + fast-claim 100';
  assert public.member_points(mem) = 188, 'balance';
  assert not (public.staff_set_order_status(pg, (select id from public.orders where number = o->>'number'), 'cancelled')->>'ok')::boolean, 'completed is final';

  -- spend points on the Wetzel's order (same member), then cancel: points and code come back
  o := public.place_order(w->>'code', 'eaton', 'pickup', 'Ana', null, null, null, '[{"id":"original","qty":2}]', true, 150, 'card_demo');
  assert (o->>'points_used')::int = 150 and public.member_points(mem) = 38, 'points spent across brands';
  assert (select total from public.orders where number = o->>'number') = round((12.98 - 2) * 1.13 - 1.50, 2), 'total = (subtotal - prize) + HST - credit';
  x := public.staff_set_order_status(wz, (select id from public.orders where number = o->>'number'), 'cancelled');
  assert public.member_points(mem) = 188 and (select redeemed_at is null from public.spins where code = w->>'code'), 'cancel refunds points and frees the code';
  -- points cannot exceed balance
  q := public.quote_order(w->>'code', '[{"id":"original","qty":2}]', true, 100000);
  assert (q->>'points_used')::int = 188, 'points capped at balance';

  -- counter redemption builds points too, and the customer door shows points and orders
  x := public.staff_redeem(pg, b->>'code', 'bremner', 40);
  assert (x->>'ok')::boolean and (x->>'points_awarded')::int = 300, '200 for $40 + 100 fast-claim';
  x := public.customer_history(null, 'ana@test.ca', w->>'code');
  assert (x->>'ok')::boolean and (x->>'points')::int = 188 and jsonb_array_length(x->'orders') = 2 and jsonb_array_length(x->'spins') = 2, 'customer door: points, orders, both brands';
  assert (public.customer_history(null, '4165550101', a->>'code')->>'ok')::boolean, 'phone works as the contact too';
end $$;

-- the public role reaches only the public calls
set local role anon;
do $$ begin
  begin perform public.reminders_claim(1); raise exception 'anon claimed reminders'; exception when insufficient_privilege then null; end;
  begin perform public.staff_orders(gen_random_uuid(), null); raise exception 'anon listed orders'; exception when insufficient_privilege then null; end;
  begin perform public.price_order('panago', '[]', null, false, false); raise exception 'anon priced directly'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.orders; raise exception 'anon read orders'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.members; raise exception 'anon read members'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'orders_test: all passed';
rollback;
