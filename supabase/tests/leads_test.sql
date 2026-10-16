-- Run: docker exec -i supabase_db_platterly psql -U postgres -v ON_ERROR_STOP=1 -q < supabase/tests/leads_test.sql
-- Everything runs in a transaction and is rolled back.
begin;
create temp table r (k text primary key, v jsonb);
grant all on r to anon;
set local role anon;

-- 1. happy path: phone normalised, coupon issued, not upsized
insert into r values ('a', public.submit_lead('panago','gerrard','Priya','(416) 555-0123',true,'gcb',false,'tv-2','Yes, send me deals'));
do $$ declare x jsonb := (select v from r where k='a'); begin
  assert x->>'code' ~ '^PL-[A-Z2-9]{6}$', 'code format ' || x::text;
  assert (x->>'upsized')::boolean = false and (x->>'returning')::boolean = false, 'first spin not upsized';
end $$;

-- 2. same person, same day, different formatting: same coupon back
insert into r values ('b', public.submit_lead('panago','gerrard','Priya','416-555-0123',false,'wings',false,'tv-2',null));
do $$ begin assert (select v->>'code' from r where k='b') = (select v->>'code' from r where k='a'), 'one spin per day'; 
  assert (select (v->>'already')::boolean from r where k='b'), 'already flag'; end $$;

-- 3. quiz right upsizes
insert into r values ('c', public.submit_lead('panago','bremner','Sam','sam@Example.com',false,'churro',true,'tv-3',null));
do $$ begin assert (select v->>'title' from r where k='c') = 'Free 16 pc Churro Bites', 'quiz upsize'; end $$;

-- 4. no table access for the public role
do $$ begin
  begin perform 1 from public.leads limit 1; raise exception 'anon could read leads';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.spins limit 1; raise exception 'anon could read spins';
  exception when insufficient_privilege then null; end;
end $$;

-- 5. bad input is rejected with a fix hint
do $$ begin
  begin perform public.submit_lead('panago',null,'X','not-a-contact',false,'pop',false,null,null); raise exception 'bad contact accepted';
  exception when invalid_parameter_value then null; end;
  begin perform public.submit_lead('panago',null,'X','x@y.ca',false,'lava',false,null,null); raise exception 'unknown prize accepted';
  exception when invalid_parameter_value then null; end;
  begin perform public.submit_lead('nope',null,'X','x@y.ca',false,'pop',false,null,null); raise exception 'unknown client accepted';
  exception when invalid_parameter_value then null; end;
end $$;

-- 6. catering request tied to the coupon
insert into r values ('d', public.request_catering((select v->>'code' from r where k='a'), current_date + 10, 'Office 25', 25));
do $$ begin assert (select (v->>'ok')::boolean from r where k='d'), 'catering ok'; end $$;
do $$ begin
  begin perform public.request_catering('PG-NOPE00', current_date + 1, 'Team 10', 10); raise exception 'unknown code accepted';
  exception when no_data_found then null; end;
end $$;

-- 7. returning customer (spun on an earlier day) gets the gold upsize automatically
reset role;
update public.spins set spin_day = spin_day - 3 where code = (select v->>'code' from r where k='a');
set local role anon;
insert into r values ('e', public.submit_lead('panago','gerrard','Priya','4165550123',false,'dip',false,'tv-1',null));
do $$ declare x jsonb := (select v from r where k='e'); begin
  assert (x->>'returning')::boolean and (x->>'upsized')::boolean and x->>'title' = 'Two free dips', 'returning upsize ' || x::text;
  assert (x->>'visits')::int = 2, 'visit count';
end $$;

-- 8. staff redemption (service role only) records history; anon cannot redeem
do $$ begin
  begin perform public.redeem_code('PG-XXXXXX', 'gerrard', 40); raise exception 'anon could redeem';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ declare c text := (select v->>'code' from r where k='e'); begin
  assert (public.redeem_code(c, 'gerrard', 42.50)->>'ok')::boolean, 'redeem';
  assert not (public.redeem_code(c, 'gerrard', 42.50)->>'ok')::boolean, 'single use';
  assert (select redeemed from public.lead_summary where contact = '+14165550123') = 1, 'history';
  assert (select count(*) from public.consent_log) = 1, 'consent logged only when given';
end $$;
select 'ALL LEAD TESTS PASSED' as result;
rollback;
