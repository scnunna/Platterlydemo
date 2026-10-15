-- Platterly 0001: Spin & Win lead capture.
-- The public QR page never touches tables. It calls two functions through the lead proxy
-- (server/lead-proxy.mjs): submit_lead() and request_catering(). Everything else is private.

create extension if not exists pgcrypto;

create table public.clients (
  id         text primary key check (id ~ '^[a-z0-9][a-z0-9-]{1,40}$'),
  name       text not null,
  created_at timestamptz not null default now()
);

create table public.stores (
  id        text primary key check (id ~ '^[a-z0-9][a-z0-9-]{1,40}$'),
  client_id text not null references public.clients(id) on delete cascade,
  name      text not null,
  address   text
);

-- Prizes on the wheel. Odds are published in the game's rules (Competition Act s.74.06).
create table public.offers (
  id          text primary key,
  client_id   text not null references public.clients(id) on delete cascade,
  title       text not null,
  rule        text not null,
  big_title   text not null,
  big_rule    text not null,
  odds        int  not null check (odds between 0 and 100),
  value       numeric(8,2),
  active      boolean not null default true
);

-- One row per person per client. contact = lower-cased email or +1 phone digits.
create table public.leads (
  id            uuid primary key default gen_random_uuid(),
  client_id     text not null references public.clients(id) on delete cascade,
  first_name    text not null check (length(first_name) between 1 and 60),
  contact       text not null check (length(contact) between 5 and 120),
  contact_kind  text not null check (contact_kind in ('email', 'phone')),
  consent       boolean not null default false,
  first_store   text references public.stores(id),
  first_source  text,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  unique (client_id, contact)
);

-- CASL: every consent change is kept (keep 3 years after the relationship ends).
create table public.consent_log (
  id         bigint generated always as identity primary key,
  lead_id    uuid not null references public.leads(id) on delete cascade,
  consent    boolean not null,
  wording    text not null,
  source     text not null,
  created_at timestamptz not null default now()
);

-- One spin = one single-use coupon. Redemption is recorded by staff, which builds purchase history.
create table public.spins (
  id            uuid primary key default gen_random_uuid(),
  client_id     text not null references public.clients(id) on delete cascade,
  lead_id       uuid not null references public.leads(id) on delete cascade,
  offer_id      text not null references public.offers(id),
  upsized       boolean not null default false,
  upsize_reason text check (upsize_reason in ('quiz', 'returning', 'both')),
  code          text not null unique,
  store_id      text references public.stores(id),
  source        text,
  spin_day      date not null default (now() at time zone 'America/Toronto')::date,
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null,
  redeemed_at   timestamptz,
  redeemed_store text references public.stores(id),
  order_total   numeric(10,2),
  unique (lead_id, spin_day)
);

create table public.catering_requests (
  id         uuid primary key default gen_random_uuid(),
  client_id  text not null references public.clients(id) on delete cascade,
  lead_id    uuid not null references public.leads(id) on delete cascade,
  event_date date not null,
  package    text not null check (length(package) between 1 and 60),
  headcount  int check (headcount between 1 and 2000),
  status     text not null default 'new' check (status in ('new', 'contacted', 'quoted', 'booked', 'lost')),
  created_at timestamptz not null default now()
);

create index spins_lead_idx on public.spins (lead_id, created_at desc);
create index leads_client_idx on public.leads (client_id, created_at desc);

-- Lock everything: RLS on, no policies, no grants for the public roles.
do $$ declare t text; begin
  foreach t in array array['clients','stores','offers','leads','consent_log','spins','catering_requests'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- Normalise an email or a North American phone number. Returns null when it is neither.
create or replace function public.platterly_contact(p text, out contact text, out kind text)
language plpgsql immutable as $$
declare d text;
begin
  p := btrim(coalesce(p, ''));
  if p ~* '^[^\s@]+@[^\s@]+\.[a-z]{2,}$' then contact := lower(p); kind := 'email'; return; end if;
  d := regexp_replace(p, '\D', '', 'g');
  if length(d) = 11 and left(d, 1) = '1' then d := substr(d, 2); end if;
  if length(d) = 10 then contact := '+1' || d; kind := 'phone'; return; end if;
  contact := null; kind := null;
end $$;

create or replace function public.platterly_code(prefix text) returns text
language sql volatile as $$
  select prefix || '-' || string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + (get_byte(b, i) % 32), 1), '')
  from (select extensions.gen_random_bytes(6) b) r, generate_series(0, 5) i
$$;

-- The QR page calls this after the customer joins.
-- Returns the coupon. A returning customer (a spin on an earlier day) gets the upsized prize: the
-- owner's "the longer you've been a customer, the better you win". One spin per person per day.
create or replace function public.submit_lead(
  p_client text, p_store text, p_first_name text, p_contact text, p_consent boolean,
  p_offer text, p_quiz_right boolean, p_source text, p_consent_wording text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c record; v_lead public.leads; v_offer public.offers; v_prev int; v_returning boolean;
  v_up boolean; v_reason text; v_spin public.spins; v_today date := (now() at time zone 'America/Toronto')::date;
  v_name text := btrim(coalesce(p_first_name, ''));
begin
  if not exists (select 1 from clients where id = p_client) then
    raise exception 'Unknown client' using errcode = '22023', hint = 'The page is set up for a client that does not exist.';
  end if;
  if p_store is not null and not exists (select 1 from stores where id = p_store and client_id = p_client) then
    p_store := null;
  end if;
  if length(v_name) not between 1 and 60 then
    raise exception 'First name is required' using errcode = '22023', hint = 'Enter a first name (up to 60 letters).';
  end if;
  select * into c from platterly_contact(p_contact);
  if c.contact is null then
    raise exception 'Contact is not an email or a 10-digit mobile number' using errcode = '22023',
      hint = 'Enter an email address or a 10-digit mobile number.';
  end if;
  select * into v_offer from offers where id = p_offer and client_id = p_client and active;
  if not found then
    raise exception 'That prize is not available' using errcode = '22023', hint = 'Reload the page and spin again.';
  end if;

  insert into leads (client_id, first_name, contact, contact_kind, consent, first_store, first_source)
  values (p_client, v_name, c.contact, c.kind, coalesce(p_consent, false), p_store, left(p_source, 60))
  on conflict (client_id, contact) do update
    set first_name = excluded.first_name, last_seen_at = now(),
        consent = case when p_consent then true else leads.consent end
  returning * into v_lead;

  if p_consent then
    insert into consent_log (lead_id, consent, wording, source)
    values (v_lead.id, true, left(coalesce(p_consent_wording, 'Deals and catering offers'), 400), 'Spin & Win QR');
  end if;

  -- Already spun today: hand back today's coupon instead of a new one.
  select * into v_spin from spins where lead_id = v_lead.id and spin_day = v_today;
  if found then
    select * into v_offer from offers where id = v_spin.offer_id;
    return jsonb_build_object('code', v_spin.code, 'already', true, 'returning', true, 'upsized', v_spin.upsized,
      'title', case when v_spin.upsized then v_offer.big_title else v_offer.title end,
      'rule', case when v_spin.upsized then v_offer.big_rule else v_offer.rule end,
      'expires_at', v_spin.expires_at, 'visits', (select count(*) from spins where lead_id = v_lead.id));
  end if;

  select count(*) into v_prev from spins where lead_id = v_lead.id and spin_day < v_today;
  v_returning := v_prev > 0;
  v_up := v_returning or coalesce(p_quiz_right, false);
  v_reason := case when v_returning and p_quiz_right then 'both' when v_returning then 'returning' when p_quiz_right then 'quiz' end;

  insert into spins (client_id, lead_id, offer_id, upsized, upsize_reason, code, store_id, source, expires_at)
  values (p_client, v_lead.id, v_offer.id, v_up, v_reason, platterly_code('PG'), p_store, left(p_source, 60),
          ((v_today + 1)::timestamp at time zone 'America/Toronto'))
  returning * into v_spin;

  return jsonb_build_object('code', v_spin.code, 'already', false, 'returning', v_returning, 'upsized', v_up,
    'title', case when v_up then v_offer.big_title else v_offer.title end,
    'rule', case when v_up then v_offer.big_rule else v_offer.rule end,
    'expires_at', v_spin.expires_at, 'visits', v_prev + 1);
end $$;

-- "Ordering for a team?" on the prize screen. Tied to the coupon the customer just received.
create or replace function public.request_catering(p_code text, p_event_date date, p_package text, p_headcount int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.spins; v_id uuid;
begin
  select * into s from spins where code = upper(btrim(coalesce(p_code, '')));
  if not found then
    raise exception 'Coupon not found' using errcode = 'P0002', hint = 'Spin and join first, then request a quote.';
  end if;
  if p_event_date is null or p_event_date < (now() at time zone 'America/Toronto')::date
     or p_event_date > (now() at time zone 'America/Toronto')::date + 365 then
    raise exception 'Pick an event date in the next 12 months' using errcode = '22023', hint = 'Choose a date from today onward.';
  end if;
  if (select count(*) from catering_requests where lead_id = s.lead_id and created_at > now() - interval '1 day') >= 3 then
    raise exception 'Too many quote requests today' using errcode = '53400', hint = 'The store will call you about the ones you sent.';
  end if;
  insert into catering_requests (client_id, lead_id, event_date, package, headcount)
  values (s.client_id, s.lead_id, p_event_date, left(btrim(coalesce(p_package, 'Not sure')), 60), p_headcount)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Staff redeem a code at the counter (used later by the Platterly admin; service role only for now).
create or replace function public.redeem_code(p_code text, p_store text, p_order_total numeric)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.spins;
begin
  select * into s from spins where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then return jsonb_build_object('ok', false, 'msg', 'No coupon with that code.'); end if;
  if s.redeemed_at is not null then return jsonb_build_object('ok', false, 'msg', 'Already used on ' || to_char(s.redeemed_at at time zone 'America/Toronto', 'Mon DD HH24:MI') || '.'); end if;
  if s.expires_at < now() then return jsonb_build_object('ok', false, 'msg', 'Expired.'); end if;
  update spins set redeemed_at = now(), redeemed_store = p_store, order_total = p_order_total where id = s.id;
  return jsonb_build_object('ok', true, 'offer', s.offer_id, 'upsized', s.upsized);
end $$;

revoke all on function public.submit_lead(text, text, text, text, boolean, text, boolean, text, text) from public;
revoke all on function public.request_catering(text, date, text, int) from public;
revoke all on function public.redeem_code(text, text, numeric) from public, anon, authenticated;
-- Supabase grants new functions to anon/authenticated by default: take those back explicitly.
revoke all on function public.submit_lead(text, text, text, text, boolean, text, boolean, text, text) from anon, authenticated;
revoke all on function public.request_catering(text, date, text, int) from anon, authenticated;
revoke all on function public.platterly_contact(text) from public, anon, authenticated;
revoke all on function public.platterly_code(text) from public, anon, authenticated;
grant execute on function public.submit_lead(text, text, text, text, boolean, text, boolean, text, text) to anon;
grant execute on function public.request_catering(text, date, text, int) to anon;
grant execute on function public.redeem_code(text, text, numeric) to service_role;

-- Owner's view: one row per lead with their spin and redemption history.
create or replace view public.lead_summary with (security_invoker = true) as
select l.client_id, l.first_name, l.contact, l.contact_kind, l.consent, l.created_at as first_seen, l.last_seen_at,
       count(s.id) as spins, count(s.redeemed_at) as redeemed, coalesce(sum(s.order_total), 0) as redeemed_order_total,
       max(s.created_at) as last_spin,
       (select count(*) from catering_requests r where r.lead_id = l.id) as catering_requests
from public.leads l left join public.spins s on s.lead_id = l.id
group by l.id;
revoke all on public.lead_summary from anon, authenticated;
