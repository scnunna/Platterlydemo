-- Platterly 0002: staff accounts (super admin, client admin) and the customer's own history.
-- Staff sign in through the lead proxy, which checks the password here (service role only) and keeps its own
-- short-lived session. Browser tokens never reach PostgREST, so nothing depends on the local stack's JWT secret.

create table public.staff (
  id            uuid primary key default gen_random_uuid(),
  email         text not null unique check (email = lower(email) and email ~ '^[^\s@]+@[^\s@]+\.[a-z]{2,}$'),
  name          text not null,
  role          text not null check (role in ('super_admin', 'client_admin')),
  client_id     text references public.clients(id) on delete cascade,
  password_hash text not null,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  last_login_at timestamptz,
  check ((role = 'client_admin') = (client_id is not null))
);
alter table public.staff enable row level security;
revoke all on public.staff from anon, authenticated;

-- Create or reset a staff account (run from psql / Studio as postgres).
create or replace function public.staff_upsert(p_email text, p_name text, p_role text, p_client text, p_password text)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid;
begin
  if length(coalesce(p_password, '')) < 12 then
    raise exception 'Password too short' using errcode = '22023', hint = 'Use at least 12 characters.';
  end if;
  insert into staff (email, name, role, client_id, password_hash)
  values (lower(btrim(p_email)), p_name, p_role, p_client, crypt(p_password, gen_salt('bf', 10)))
  on conflict (email) do update set name = excluded.name, role = excluded.role, client_id = excluded.client_id,
    password_hash = excluded.password_hash, active = true
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.staff_login(p_email text, p_password text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.staff;
begin
  select * into s from staff where email = lower(btrim(coalesce(p_email, ''))) and active;
  if not found or s.password_hash <> crypt(coalesce(p_password, ''), s.password_hash) then
    return jsonb_build_object('ok', false);
  end if;
  update staff set last_login_at = now() where id = s.id;
  return jsonb_build_object('ok', true, 'id', s.id, 'name', s.name, 'email', s.email, 'role', s.role, 'client_id', s.client_id,
    'clients', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name) from clients c
                         where s.role = 'super_admin' or c.id = s.client_id), '[]'::jsonb));
end $$;

create or replace function public.staff_change_password(p_staff uuid, p_old text, p_new text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.staff;
begin
  select * into s from staff where id = p_staff and active;
  if not found or s.password_hash <> crypt(coalesce(p_old, ''), s.password_hash) then
    return jsonb_build_object('ok', false, 'msg', 'Current password is wrong.');
  end if;
  if length(coalesce(p_new, '')) < 12 then return jsonb_build_object('ok', false, 'msg', 'Use at least 12 characters.'); end if;
  update staff set password_hash = crypt(p_new, gen_salt('bf', 10)) where id = s.id;
  return jsonb_build_object('ok', true);
end $$;

-- Which client a staff member may see. Super admin: any (or all when p_client is null). Client admin: only theirs.
create or replace function public.staff_scope(p_staff uuid, p_client text) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare s public.staff;
begin
  select * into s from staff where id = p_staff and active;
  if not found then raise exception 'Not signed in' using errcode = '42501', hint = 'Sign in again.'; end if;
  if s.role = 'client_admin' then
    if p_client is not null and p_client <> s.client_id then
      raise exception 'Not your client' using errcode = '42501', hint = 'You can only see your own stores.';
    end if;
    return array[s.client_id];
  end if;
  if p_client is null then return array(select id from clients); end if;
  return array[p_client];
end $$;

-- Lead list with the latest spin and totals. Search matches name or contact.
create or replace function public.staff_leads(p_staff uuid, p_client text, p_search text, p_consent_only boolean, p_limit int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_scope text[] := staff_scope(p_staff, p_client);
begin
  return coalesce((select jsonb_agg(row_to_json(x) order by x.last_seen_at desc) from (
    select l.id, l.client_id, l.first_name, l.contact, l.contact_kind, l.consent, l.first_store, l.first_source,
           l.created_at, l.last_seen_at,
           count(s.id) as spins, count(s.redeemed_at) as redeemed, coalesce(sum(s.order_total), 0) as redeemed_total,
           (select o.title || case when s2.upsized then ' (upsized)' else '' end from spins s2 join offers o on o.id = s2.offer_id
             where s2.lead_id = l.id order by s2.created_at desc limit 1) as last_prize,
           (select s2.code from spins s2 where s2.lead_id = l.id order by s2.created_at desc limit 1) as last_code,
           (select count(*) from catering_requests r where r.lead_id = l.id) as catering
    from leads l left join spins s on s.lead_id = l.id
    where l.client_id = any(v_scope)
      and (not coalesce(p_consent_only, false) or l.consent)
      and (coalesce(btrim(p_search), '') = '' or l.first_name ilike '%' || btrim(p_search) || '%' or l.contact ilike '%' || btrim(p_search) || '%')
    group by l.id
    order by l.last_seen_at desc
    limit least(greatest(coalesce(p_limit, 200), 1), 2000)) x), '[]'::jsonb);
end $$;

create or replace function public.staff_summary(p_staff uuid, p_client text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_scope text[] := staff_scope(p_staff, p_client); v_today date := (now() at time zone 'America/Toronto')::date;
begin
  return jsonb_build_object(
    'leads', (select count(*) from leads where client_id = any(v_scope)),
    'leads_today', (select count(*) from leads where client_id = any(v_scope) and (created_at at time zone 'America/Toronto')::date = v_today),
    'leads_7d', (select count(*) from leads where client_id = any(v_scope) and created_at > now() - interval '7 days'),
    'consent', (select count(*) from leads where client_id = any(v_scope) and consent),
    'spins', (select count(*) from spins where client_id = any(v_scope)),
    'redeemed', (select count(*) from spins where client_id = any(v_scope) and redeemed_at is not null),
    'returning', (select count(*) from (select lead_id from spins where client_id = any(v_scope) group by lead_id having count(*) > 1) r),
    'catering_new', (select count(*) from catering_requests where client_id = any(v_scope) and status = 'new'),
    'by_store', coalesce((select jsonb_object_agg(coalesce(store_id, 'unknown'), n) from (select store_id, count(*) n from spins where client_id = any(v_scope) group by 1) a), '{}'::jsonb),
    'by_source', coalesce((select jsonb_object_agg(coalesce(source, 'unknown'), n) from (select source, count(*) n from spins where client_id = any(v_scope) group by 1) a), '{}'::jsonb),
    'by_prize', coalesce((select jsonb_object_agg(o.title, n) from (select offer_id, count(*) n from spins where client_id = any(v_scope) group by 1) a join offers o on o.id = a.offer_id), '{}'::jsonb),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('day', d, 'leads', n) order by d) from (
        select (created_at at time zone 'America/Toronto')::date d, count(*) n from leads
        where client_id = any(v_scope) and created_at > now() - interval '30 days' group by 1) a), '[]'::jsonb)
  );
end $$;

create or replace function public.staff_catering(p_staff uuid, p_client text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_scope text[] := staff_scope(p_staff, p_client);
begin
  return coalesce((select jsonb_agg(row_to_json(x) order by x.event_date) from (
    select r.id, r.client_id, r.event_date, r.package, r.headcount, r.status, r.created_at, l.first_name, l.contact, l.consent
    from catering_requests r join leads l on l.id = r.lead_id where r.client_id = any(v_scope)) x), '[]'::jsonb);
end $$;

create or replace function public.staff_set_catering_status(p_staff uuid, p_id uuid, p_status text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.catering_requests;
begin
  select * into r from catering_requests where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'msg', 'Request not found.'); end if;
  perform staff_scope(p_staff, r.client_id);
  update catering_requests set status = p_status where id = p_id;
  return jsonb_build_object('ok', true);
exception when check_violation then return jsonb_build_object('ok', false, 'msg', 'Unknown status.');
end $$;

-- Counter redemption, limited to the staff member's client.
create or replace function public.staff_redeem(p_staff uuid, p_code text, p_store text, p_order_total numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.spins; o public.offers; l public.leads;
begin
  select * into s from spins where code = upper(btrim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('ok', false, 'msg', 'No coupon with that code.'); end if;
  perform staff_scope(p_staff, s.client_id);
  select * into o from offers where id = s.offer_id; select * into l from leads where id = s.lead_id;
  return redeem_code(p_code, p_store, p_order_total) || jsonb_build_object('prize', case when s.upsized then o.big_title else o.title end,
    'rule', case when s.upsized then o.big_rule else o.rule end, 'name', l.first_name);
end $$;

-- Customer access: their own prize history, proven by the contact plus any code they received.
create or replace function public.customer_history(p_client text, p_contact text, p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c record; v_lead uuid;
begin
  select * into c from platterly_contact(p_contact);
  select l.id into v_lead from leads l join spins s on s.lead_id = l.id
   where l.client_id = p_client and l.contact = c.contact and s.code = upper(btrim(coalesce(p_code, ''))) limit 1;
  if v_lead is null then return jsonb_build_object('ok', false, 'msg', 'No prizes found for that contact and code.'); end if;
  return jsonb_build_object('ok', true, 'name', (select first_name from leads where id = v_lead),
    'spins', (select jsonb_agg(jsonb_build_object('code', s.code, 'prize', case when s.upsized then o.big_title else o.title end,
                'rule', case when s.upsized then o.big_rule else o.rule end, 'day', s.spin_day, 'expires_at', s.expires_at,
                'redeemed', s.redeemed_at is not null) order by s.created_at desc)
              from spins s join offers o on o.id = s.offer_id where s.lead_id = v_lead));
end $$;

do $$ declare f text; begin
  foreach f in array array['staff_upsert(text,text,text,text,text)', 'staff_login(text,text)', 'staff_change_password(uuid,text,text)',
    'staff_scope(uuid,text)', 'staff_leads(uuid,text,text,boolean,int)', 'staff_summary(uuid,text)', 'staff_catering(uuid,text)',
    'staff_set_catering_status(uuid,uuid,text)', 'staff_redeem(uuid,text,text,numeric)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  execute 'revoke all on function public.customer_history(text,text,text) from public, authenticated';
  execute 'grant execute on function public.customer_history(text,text,text) to anon';
end $$;
