-- Run: docker exec -i supabase_db_platterly psql -U postgres -v ON_ERROR_STOP=1 -q < supabase/tests/staff_test.sql
begin;
insert into public.clients (id, name) values ('otherbrand', 'Other Brand (test)');
select public.staff_upsert('super@test.ca', 'Super', 'super_admin', null, 'correct horse battery');
select public.staff_upsert('kiran@test.ca', 'Kiran', 'client_admin', 'panago', 'panago owner pass 1');
select public.staff_upsert('other@test.ca', 'Other', 'client_admin', 'otherbrand', 'other owner pass 12');
create temp table t (k text primary key, v jsonb); grant all on t to anon;
set local role anon;
insert into t values ('a', public.submit_lead('panago','gerrard','Ana','ana@test.ca',true,'gcb',false,'tv-2',null));
reset role;
insert into public.leads (client_id, first_name, contact, contact_kind) values ('otherbrand', 'Zed', 'zed@test.ca', 'email');

do $$ declare k uuid := (select id from public.staff where email='kiran@test.ca');
             o uuid := (select id from public.staff where email='other@test.ca');
             s uuid := (select id from public.staff where email='super@test.ca');
             x jsonb; begin
  -- login
  assert (public.staff_login('Kiran@Test.ca', 'panago owner pass 1')->>'ok')::boolean, 'login ok (case-insensitive email)';
  assert not (public.staff_login('kiran@test.ca', 'wrong')->>'ok')::boolean, 'bad password refused';
  assert not (public.staff_login('nobody@test.ca', 'x')->>'ok')::boolean, 'unknown user refused';
  assert jsonb_array_length(public.staff_login('kiran@test.ca','panago owner pass 1')->'clients') = 1, 'client admin sees one client';
  assert jsonb_array_length(public.staff_login('super@test.ca','correct horse battery')->'clients') >= 2, 'super admin sees all clients';
  -- scoping
  x := public.staff_leads(k, null, null, false, 100);
  assert x @> '[{"first_name":"Ana"}]' and not x @> '[{"first_name":"Zed"}]', 'client admin sees only own leads';
  assert not public.staff_leads(o, null, null, false, 100) @> '[{"first_name":"Ana"}]', 'other client cannot see Panago';
  begin perform public.staff_leads(k, 'otherbrand', null, false, 100); raise exception 'cross-client read allowed';
  exception when insufficient_privilege then null; end;
  x := public.staff_leads(s, null, null, false, 100);
  assert x @> '[{"first_name":"Ana"}]' and x @> '[{"first_name":"Zed"}]', 'super admin sees everyone';
  assert public.staff_leads(s, 'otherbrand', null, false, 100) @> '[{"first_name":"Zed"}]' and not public.staff_leads(s, 'otherbrand', null, false, 100) @> '[{"first_name":"Ana"}]', 'super admin filter';
  assert jsonb_array_length(public.staff_leads(k, null, 'ana@', false, 100)) = 1, 'search';
  assert (public.staff_summary(k, null)->>'leads')::int = 1, 'summary scoped';
end $$;
-- other client's admin cannot redeem Panago code (raises)
do $$ begin
  begin perform public.staff_redeem((select id from public.staff where email='other@test.ca'), (select v->>'code' from t where k='a'), null, 10);
    raise exception 'cross-client redeem allowed';
  exception when insufficient_privilege then null; end;
  assert (public.staff_redeem((select id from public.staff where email='kiran@test.ca'), (select v->>'code' from t where k='a'), 'gerrard', 31.50)->>'prize') = 'Free Garlic Cheezy Bread', 'own redeem';
end $$;
-- customer history: contact + code required
set local role anon;
do $$ begin
  assert (public.customer_history('panago', 'ANA@test.ca', (select v->>'code' from t where k='a'))->>'ok')::boolean, 'customer sees own';
  assert not (public.customer_history('panago', 'ana@test.ca', 'PG-WRONG1')->>'ok')::boolean, 'wrong code refused';
  begin perform public.staff_login('kiran@test.ca','panago owner pass 1'); raise exception 'anon can call staff_login';
  exception when insufficient_privilege then null; end;
  begin perform public.staff_leads(gen_random_uuid(), null, null, false, 10); raise exception 'anon can call staff_leads';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.staff; raise exception 'anon can read staff';
  exception when insufficient_privilege then null; end;
end $$;
select 'ALL STAFF TESTS PASSED' as result;
rollback;
