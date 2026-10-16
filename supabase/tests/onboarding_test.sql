-- Run: docker exec -i supabase_db_platterly psql -U postgres -v ON_ERROR_STOP=1 -q < supabase/tests/onboarding_test.sql
-- Second client (Wetzel's), per-client coupon prefixes, and the super-admin-only onboarding board. Rolled back.
begin;
select public.staff_upsert('super@test.ca', 'Super', 'super_admin', null, 'correct horse battery');
select public.staff_upsert('wz@test.ca', 'Wz Owner', 'client_admin', 'wetzels', 'wetzels owner pass');
select public.staff_upsert('pg@test.ca', 'Pg Owner', 'client_admin', 'panago', 'panago owner pass 1');
create temp table t (k text primary key, v jsonb); grant all on t to anon;
set local role anon;
insert into t values ('w', public.submit_lead('wetzels', 'eaton', 'Maya', 'maya@test.ca', true, 'wp-dip', true, 'tv-direct', 'test wording'));
insert into t values ('p', public.submit_lead('panago', 'gerrard', 'Maya', 'maya@test.ca', false, 'pop', false, 'tv-1', null));
reset role;

do $$ declare s uuid := (select id from public.staff where email = 'super@test.ca');
             w uuid := (select id from public.staff where email = 'wz@test.ca');
             x jsonb; c jsonb; begin
  -- prefixes and scoping
  assert (select v->>'code' from t where k = 'w') ~ '^PL-[A-Z2-9]{6}$', 'Wetzel''s code is a Platterly code';
  assert (select v->>'code' from t where k = 'p') ~ '^PL-[A-Z2-9]{6}$', 'Panago code is a Platterly code';
  assert (select v->>'title' from t where k = 'w') = 'Two free dips', 'quiz upsizes Wetzel''s prize';
  assert (select count(*) from public.leads where contact = 'maya@test.ca') = 2, 'same person is a separate lead per client';
  assert not public.staff_leads(w, null, null, false, 100) @> '[{"client_id":"panago"}]', 'Wetzel''s owner sees no Panago leads';
  assert public.staff_leads(w, null, null, false, 100) @> '[{"client_id":"wetzels"}]', 'Wetzel''s owner sees own lead';
  -- sign-in carries stores and prefix
  x := public.staff_login('wz@test.ca', 'wetzels owner pass');
  assert x->'clients' @> '[{"id":"wetzels","stores":[{"id":"eaton"}]}]', 'login returns stores and prefix';
  assert jsonb_array_length(x->'clients') = 1, 'client admin sees one client';
  -- customer door with no client: the code decides
  x := public.customer_history(null, 'maya@test.ca', (select v->>'code' from t where k = 'w'));
  assert (x->>'ok')::boolean and x->'spins'->0->>'prize' = 'Two free dips', 'customer history by code alone';
  assert not (public.customer_history(null, 'other@test.ca', (select v->>'code' from t where k = 'w'))->>'ok')::boolean, 'wrong contact refused';
  -- board: super admin only
  x := public.staff_onboarding(s);
  assert jsonb_array_length(x->'stages') = 7 and jsonb_array_length(x->'steps') = 27, 'stages and steps';
  assert x->'clients' @> '[{"id":"wetzels"}]' and x->'clients' @> '[{"id":"panago"}]', 'board lists every client';
  begin perform public.staff_onboarding(w); raise exception 'client admin read the board';
  exception when insufficient_privilege then null; end;
  begin perform public.staff_onboarding_set(w, 'wetzels', 'discovery-call', true, null); raise exception 'client admin changed the board';
  exception when insufficient_privilege then null; end;
  -- tick, note, untick
  assert (public.staff_onboarding_set(s, 'wetzels', 'site-scan', true, 'scanned from the walkway')->>'ok')::boolean, 'tick';
  c := (select e from jsonb_array_elements(public.staff_onboarding(s)->'clients') e where e->>'id' = 'wetzels');
  assert c->'progress'->'site-scan'->>'done_at' is not null and c->'progress'->'site-scan'->>'done_by' = 'Super', 'done with who';
  perform public.staff_onboarding_set(s, 'wetzels', 'site-scan', null, 'new note');
  c := (select e from jsonb_array_elements(public.staff_onboarding(s)->'clients') e where e->>'id' = 'wetzels');
  assert c->'progress'->'site-scan'->>'note' = 'new note' and c->'progress'->'site-scan'->>'done_at' is not null, 'note only keeps done';
  perform public.staff_onboarding_set(s, 'wetzels', 'site-scan', false, null);
  c := (select e from jsonb_array_elements(public.staff_onboarding(s)->'clients') e where e->>'id' = 'wetzels');
  assert c->'progress'->'site-scan'->>'done_at' is null and c->'progress'->'site-scan'->>'note' = 'new note', 'untick keeps note';
  assert (c->'facts'->>'leads')::int >= 1 and (c->'facts'->>'offers')::int = 6, 'live facts';
  assert not (public.staff_onboarding_set(s, 'nope', 'site-scan', true, null)->>'ok')::boolean, 'unknown client';
  assert not (public.staff_onboarding_set(s, 'wetzels', 'nope', true, null)->>'ok')::boolean, 'unknown step';
  assert (select sum(odds) from public.offers where client_id = 'wetzels') = 100, 'Wetzel''s odds add to 100';
end $$;

-- the public role cannot reach the board at all
set local role anon;
do $$ begin
  begin perform public.staff_onboarding(gen_random_uuid()); raise exception 'anon reached the board';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.client_onboarding; raise exception 'anon read progress';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'onboarding_test: all passed';
rollback;
