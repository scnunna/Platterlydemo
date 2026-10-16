-- Platterly 0004: Platterly is the platform. Codes (PL-) and credit points are Platterly's, not the partner store's.
-- * members: one Platterly customer across every partner brand, with email and/or phone (both = a fuller profile).
-- * claims: a 2-hour fast-claim window (claim in time for bonus points), then the code stays valid until the store
--   closes. A reminder goes out when the 2 hours are up.
-- * orders: customers order through Platterly for pickup or delivery at the same price as the counter. Payment is
--   not taken online (pay at the store or on delivery; a card form is shown as a demo only).
-- Public calls (anon, through server/lead-proxy.mjs): submit_claim, menu_for, quote_order, place_order, order_status.

-- ---------- members and profiles ----------
create table public.members (
  id           uuid primary key default gen_random_uuid(),
  first_name   text not null check (length(first_name) between 1 and 60),
  email        text unique check (email = lower(email)),
  phone        text unique check (phone ~ '^\+1[0-9]{10}$'),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  check (email is not null or phone is not null)
);
alter table public.leads add column member_id uuid references public.members(id) on delete set null,
                         add column email text check (email = lower(email)),
                         add column phone text check (phone ~ '^\+1[0-9]{10}$');
update public.leads set email = contact where contact_kind = 'email';
update public.leads set phone = contact where contact_kind = 'phone';
create unique index leads_client_email_idx on public.leads (client_id, email) where email is not null;
create unique index leads_client_phone_idx on public.leads (client_id, phone) where phone is not null;
insert into public.members (first_name, email, phone)
  select distinct on (contact) first_name, email, phone from public.leads order by contact, created_at
  on conflict do nothing;
update public.leads l set member_id = m.id from public.members m where m.email = l.email or m.phone = l.phone;

-- Platterly credit points: 100 points = $1 off a Platterly order.
create table public.points_ledger (
  id         bigint generated always as identity primary key,
  member_id  uuid not null references public.members(id) on delete cascade,
  client_id  text references public.clients(id) on delete set null,
  delta      int not null check (delta <> 0),
  reason     text not null check (reason in ('fast_claim', 'order', 'store_visit', 'spent', 'refund', 'adjust')),
  ref        text,
  created_at timestamptz not null default now()
);
create index points_member_idx on public.points_ledger (member_id);
create or replace function public.member_points(p_member uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(delta), 0)::int from points_ledger where member_id = p_member
$$;

-- ---------- stores, offers, menus ----------
-- Closing time per weekday ('0' = Sunday ... '6' = Saturday), 'HH:MM', '24:00' = midnight.
alter table public.stores add column close_times jsonb not null default '{}'::jsonb,
                          add column pickup boolean not null default true,
                          add column delivery boolean not null default false;
alter table public.spins add column hold_until timestamptz, add column member_id uuid references public.members(id) on delete set null;

-- What a prize does to a Platterly order. {"normal": {...}, "big": {...}}, each one of:
--   {"free": "<menu id>", "qty": n, "requires": {"cat": "pizza", "sizes": ["L","XL"], "qty": 1}}
--   {"pct": 10, "requires": {"cat": "pizza", "qty": 5}}      {"amt": 2, "min": 10}
--   {"bogo": ["original", "sinful-cinnamon"]}  or  {"bogo_cat": "pretzels"}
alter table public.offers add column reward jsonb not null default '{}'::jsonb;

create table public.menu_items (
  client_id text not null references public.clients(id) on delete cascade,
  id        text not null check (id ~ '^[a-z0-9-]{1,40}$'),
  name      text not null,
  cat       text not null,
  grp       text,
  descr     text,
  price     numeric(8,2) check (price >= 0),
  sizes     jsonb,
  unit      text,
  tags      text[] not null default '{}',
  orderable boolean not null default true,
  sort      int not null default 0,
  primary key (client_id, id),
  check (not orderable or price is not null or sizes is not null)
);

-- ---------- reminders and orders ----------
create table public.reminders (
  id       bigint generated always as identity primary key,
  spin_id  uuid not null references public.spins(id) on delete cascade,
  channel  text not null check (channel in ('email', 'sms')),
  to_addr  text not null,
  due_at   timestamptz not null,
  status   text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'test_inbox', 'skipped', 'failed', 'cancelled')),
  attempts int not null default 0,
  sent_at  timestamptz,
  error    text
);
create index reminders_due_idx on public.reminders (due_at) where status = 'pending';

create table public.orders (
  id          uuid primary key default gen_random_uuid(),
  number      text not null unique,
  client_id   text not null references public.clients(id) on delete cascade,
  store_id    text not null references public.stores(id),
  member_id   uuid references public.members(id) on delete set null,
  lead_id     uuid references public.leads(id) on delete set null,
  spin_id     uuid references public.spins(id) on delete set null,
  prize_used  boolean not null default false,
  mode        text not null check (mode in ('pickup', 'delivery')),
  name        text not null check (length(name) between 1 and 60),
  phone       text,
  email       text,
  address     text check (length(address) <= 200),
  note        text check (length(note) <= 300),
  items       jsonb not null,
  subtotal    numeric(10,2) not null,
  discount    numeric(10,2) not null default 0,
  tax         numeric(10,2) not null default 0,
  points_used int not null default 0 check (points_used >= 0),
  credit      numeric(10,2) not null default 0,
  total       numeric(10,2) not null,
  payment     text not null check (payment in ('pay_at_store', 'pay_on_delivery', 'card_demo')),
  status      text not null default 'new' check (status in ('new', 'accepted', 'ready', 'out_for_delivery', 'completed', 'cancelled')),
  fast_claim  boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index orders_client_idx on public.orders (client_id, created_at desc);
create unique index orders_one_per_prize_idx on public.orders (spin_id) where prize_used and status <> 'cancelled';

do $$ declare t text; begin
  foreach t in array array['members','points_ledger','menu_items','reminders','orders'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- Every client's codes are Platterly codes now.
drop index if exists public.clients_code_prefix_idx;
update public.clients set code_prefix = 'PL';
alter table public.clients alter column code_prefix set default 'PL';

-- ---------- helpers ----------
create or replace function public.store_close(p_store text, p_day date) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  select close_times ->> extract(dow from p_day)::int::text into v from stores where id = p_store;
  if v is null or v !~ '^([01][0-9]|2[0-4]):[0-5][0-9]$' then v := '24:00'; end if;
  return (p_day + v::interval) at time zone 'America/Toronto';
end $$;

create or replace function public.platterly_norm_email(p text) returns text language plpgsql immutable as $$
declare c record;
begin
  if coalesce(btrim(p), '') = '' then return null; end if;
  select * into c from platterly_contact(p);
  if c.kind is distinct from 'email' then
    raise exception 'Check the email address' using errcode = '22023', hint = 'It should look like name@example.com. Or leave it empty and use your mobile.';
  end if;
  return c.contact;
end $$;
create or replace function public.platterly_norm_phone(p text) returns text language plpgsql immutable as $$
declare c record;
begin
  if coalesce(btrim(p), '') = '' then return null; end if;
  select * into c from platterly_contact(p);
  if c.kind is distinct from 'phone' then
    raise exception 'Check the mobile number' using errcode = '22023', hint = 'Use a 10-digit number like 416 555 0123. Or leave it empty and use your email.';
  end if;
  return c.contact;
end $$;

-- ---------- the claim (QR page) ----------
create or replace function public.submit_claim(
  p_client text, p_store text, p_first_name text, p_email text, p_phone text, p_consent boolean, p_remind boolean,
  p_offer text, p_quiz_right boolean, p_source text, p_consent_wording text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := platterly_norm_email(p_email); v_phone text := platterly_norm_phone(p_phone);
  v_name text := btrim(coalesce(p_first_name, '')); v_today date := (now() at time zone 'America/Toronto')::date;
  m public.members; v_lead public.leads; o public.offers; s public.spins;
  v_prev int; v_returning boolean; v_up boolean; v_reason text; v_close timestamptz; v_hold timestamptz; v_rem text; v_new boolean := false;
begin
  if not exists (select 1 from clients where id = p_client) then
    raise exception 'Unknown client' using errcode = '22023', hint = 'The page is set up for a client that does not exist.';
  end if;
  if p_store is null or not exists (select 1 from stores where id = p_store and client_id = p_client) then
    select id into p_store from stores where client_id = p_client order by id limit 1;
  end if;
  if length(v_name) not between 1 and 60 then
    raise exception 'First name is required' using errcode = '22023', hint = 'Enter a first name (up to 60 letters).';
  end if;
  if v_email is null and v_phone is null then
    raise exception 'Add an email or a mobile number' using errcode = '22023', hint = 'We send your code there. One is enough; both is fine too.';
  end if;
  select * into o from offers where id = p_offer and client_id = p_client and active;
  if not found then raise exception 'That prize is not available' using errcode = '22023', hint = 'Reload the page and spin again.'; end if;

  -- One Platterly member per person, matched by email first, then phone. Fill in whichever contact was missing.
  select * into m from members where email = v_email and v_email is not null;
  if not found then select * into m from members where phone = v_phone and v_phone is not null; end if;
  if found then
    update members set first_name = v_name, last_seen_at = now(),
      email = coalesce(members.email, case when not exists (select 1 from members x where x.email = v_email) then v_email end),
      phone = coalesce(members.phone, case when not exists (select 1 from members x where x.phone = v_phone) then v_phone end)
    where id = m.id returning * into m;
  else
    insert into members (first_name, email, phone) values (v_name, v_email, v_phone) returning * into m;
  end if;

  select * into v_lead from leads where client_id = p_client and (member_id = m.id or email = v_email or phone = v_phone)
   order by (member_id = m.id) desc nulls last limit 1;
  if found then
    update leads set first_name = v_name, last_seen_at = now(), member_id = m.id,
      email = coalesce(leads.email, case when not exists (select 1 from leads x where x.client_id = p_client and x.email = v_email) then v_email end),
      phone = coalesce(leads.phone, case when not exists (select 1 from leads x where x.client_id = p_client and x.phone = v_phone) then v_phone end),
      consent = case when p_consent then true else leads.consent end
    where id = v_lead.id returning * into v_lead;
  else
    insert into leads (client_id, member_id, first_name, contact, contact_kind, email, phone, consent, first_store, first_source)
    values (p_client, m.id, v_name, coalesce(v_email, v_phone), case when v_email is not null then 'email' else 'phone' end,
            v_email, v_phone, coalesce(p_consent, false), p_store, left(p_source, 60))
    returning * into v_lead;
  end if;
  if p_consent then
    insert into consent_log (lead_id, consent, wording, source)
    values (v_lead.id, true, left(coalesce(p_consent_wording, 'Deals from Platterly and its partner store'), 400), 'Platterly Spin & Win QR');
  end if;

  -- Already claimed today at this brand: hand back today's code.
  select * into s from spins where lead_id = v_lead.id and spin_day = v_today;
  if not found then
    -- "The longer you've been a customer, the better you win": any earlier-day spin with Platterly, at any brand.
    select count(*) into v_prev from spins where member_id = m.id and spin_day < v_today;
    v_returning := v_prev > 0 or exists (select 1 from spins where lead_id = v_lead.id and spin_day < v_today);
    v_up := v_returning or coalesce(p_quiz_right, false);
    v_reason := case when v_returning and p_quiz_right then 'both' when v_returning then 'returning' when p_quiz_right then 'quiz' end;
    v_close := store_close(p_store, v_today);
    if v_close <= now() then v_close := store_close(p_store, v_today + 1); end if;
    v_hold := least(now() + interval '2 hours', v_close);
    insert into spins (client_id, lead_id, member_id, offer_id, upsized, upsize_reason, code, store_id, source, expires_at, hold_until)
    values (p_client, v_lead.id, m.id, o.id, v_up, v_reason, platterly_code('PL'), p_store, left(p_source, 60), v_close, v_hold)
    returning * into s;
    v_new := true;
    if coalesce(p_remind, false) and v_hold < v_close - interval '10 minutes' then
      insert into reminders (spin_id, channel, to_addr, due_at)
      values (s.id, case when m.email is not null then 'email' else 'sms' end, coalesce(m.email, m.phone), v_hold);
      v_rem := case when m.email is not null then 'email' else 'sms' end;
    end if;
  else
    select channel into v_rem from reminders where spin_id = s.id and status <> 'cancelled' limit 1;
  end if;
  select * into o from offers where id = s.offer_id;

  return jsonb_build_object('code', s.code, 'already', not v_new, 'returning', coalesce(s.upsize_reason in ('returning', 'both'), false),
    'upsized', s.upsized, 'title', case when s.upsized then o.big_title else o.title end, 'rule', case when s.upsized then o.big_rule else o.rule end,
    'hold_until', coalesce(s.hold_until, s.created_at + interval '2 hours'), 'expires_at', s.expires_at, 'reminder', v_rem,
    'fast_bonus', 100, 'points', member_points(m.id), 'has_email', m.email is not null, 'has_phone', m.phone is not null,
    'store', s.store_id, 'visits', (select count(*) from spins where member_id = m.id));
end $$;

-- ---------- ordering ----------
create or replace function public.menu_for(p_client text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'client', (select jsonb_build_object('id', c.id, 'name', c.name, 'brand_color', c.brand_color) from clients c where c.id = p_client),
    'stores', coalesce((select jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name, 'address', st.address, 'hours', st.hours,
                 'pickup', st.pickup, 'delivery', st.delivery,
                 'closes', store_close(st.id, (now() at time zone 'America/Toronto')::date)) order by st.name)
               from stores st where st.client_id = p_client), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'cat', m.cat, 'grp', m.grp, 'descr', m.descr,
                 'price', m.price, 'sizes', m.sizes, 'unit', m.unit, 'tags', m.tags) order by m.sort)
               from menu_items m where m.client_id = p_client and m.orderable), '[]'::jsonb))
$$;

-- Price a cart on the server (the page's prices are never trusted). Used by quote_order and place_order.
create or replace function public.price_order(p_client text, p_items jsonb, p_offer text, p_upsized boolean, p_use_prize boolean)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  it jsonb; mi public.menu_items; v_qty int; v_size text; v_price numeric; v_lines jsonb := '[]'; v_sub numeric := 0; v_disc numeric := 0;
  o public.offers; r jsonb; req jsonb; v_have int; v_ok boolean := false; v_note text; v_free public.menu_items; v_bogo numeric;
begin
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) not between 1 and 40 then
    raise exception 'Add something to your order' using errcode = '22023', hint = 'Pick at least one item (up to 40 lines).';
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    select * into mi from menu_items where client_id = p_client and id = it->>'id' and orderable;
    if not found then raise exception 'An item is no longer on the menu' using errcode = '22023', hint = 'Reload the menu and add it again.'; end if;
    v_qty := coalesce((it->>'qty')::int, 0);
    if v_qty not between 1 and 50 then raise exception 'Quantities go from 1 to 50' using errcode = '22023', hint = 'Change the quantity and try again.'; end if;
    v_size := nullif(it->>'size', '');
    if mi.sizes is not null then
      v_price := (mi.sizes ->> v_size)::numeric;
      if v_price is null then raise exception 'Pick a size for %', mi.name using errcode = '22023', hint = 'Choose S, M, L or XL.'; end if;
    else v_price := mi.price; v_size := null; end if;
    v_lines := v_lines || jsonb_build_object('id', mi.id, 'name', mi.name, 'cat', mi.cat, 'size', v_size, 'qty', v_qty, 'price', v_price, 'line', v_price * v_qty);
    v_sub := v_sub + v_price * v_qty;
  end loop;

  select * into o from offers where id = p_offer and client_id = p_client;
  if found and coalesce(p_use_prize, false) then
    r := o.reward -> case when p_upsized then 'big' else 'normal' end;
    req := r -> 'requires';
    select coalesce(sum((l->>'qty')::int), 0) into v_have from jsonb_array_elements(v_lines) l
     where req is not null and (req->>'cat' is null or l->>'cat' = req->>'cat')
       and (req->'sizes' is null or req->'sizes' ? (l->>'size'));
    if req is not null and v_have < coalesce((req->>'qty')::int, 1) then
      v_note := 'To use your prize (' || (case when p_upsized then o.big_title || ', ' || o.big_rule else o.title || ', ' || o.rule end) || '), add the qualifying items.';
    elsif r ? 'min' and v_sub < (r->>'min')::numeric then
      v_note := 'To use your prize, your order needs to be $' || to_char((r->>'min')::numeric, 'FM990.00') || ' or more before tax.';
    elsif r ? 'free' then
      select * into v_free from menu_items where client_id = p_client and id = r->>'free';
      v_lines := v_lines || jsonb_build_object('id', v_free.id, 'name', v_free.name, 'cat', v_free.cat, 'size', null,
        'qty', coalesce((r->>'qty')::int, 1), 'price', 0, 'line', 0, 'prize', true);
      v_ok := true;
    elsif r ? 'pct' then v_disc := round(v_sub * (r->>'pct')::numeric / 100, 2); v_ok := true;
    elsif r ? 'amt' then v_disc := least((r->>'amt')::numeric, v_sub); v_ok := true;
    elsif r ? 'bogo' or r ? 'bogo_cat' then
      select min((l->>'price')::numeric), coalesce(sum((l->>'qty')::int), 0) into v_bogo, v_have from jsonb_array_elements(v_lines) l
       where (r ? 'bogo' and r->'bogo' ? (l->>'id')) or (r ? 'bogo_cat' and l->>'cat' = r->>'bogo_cat');
      if v_have >= 2 then v_disc := v_bogo; v_ok := true;
      else v_note := 'To use your prize (' || (case when p_upsized then o.big_title || ', ' || o.big_rule else o.title || ', ' || o.rule end) || '), add 2 qualifying pretzels.'; end if;
    end if;
  end if;
  return jsonb_build_object('lines', v_lines, 'subtotal', round(v_sub, 2), 'discount', round(v_disc, 2), 'prize_applied', v_ok, 'prize_note', v_note,
    'prize', case when o.id is not null then case when p_upsized then o.big_title || ', ' || o.big_rule else o.title || ', ' || o.rule end end);
end $$;

-- The checkout summary for a code, before the customer confirms.
create or replace function public.quote_order(p_code text, p_items jsonb, p_use_prize boolean, p_points int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.spins; q jsonb; v_bal int; v_pts int; v_tax numeric; v_after numeric;
begin
  select * into s from spins where code = upper(btrim(coalesce(p_code, '')));
  if not found then raise exception 'Code not found' using errcode = 'P0002', hint = 'Spin and claim a prize first, then order with its code.'; end if;
  q := price_order(s.client_id, p_items, s.offer_id, s.upsized, coalesce(p_use_prize, true) and s.redeemed_at is null and s.expires_at > now());
  v_after := (q->>'subtotal')::numeric - (q->>'discount')::numeric;
  v_tax := round(v_after * 0.13, 2);
  v_bal := coalesce(member_points(s.member_id), 0);
  v_pts := least(greatest(coalesce(p_points, 0), 0), v_bal, floor((v_after + v_tax) * 100)::int);
  return q || jsonb_build_object('tax', v_tax, 'points_balance', v_bal, 'points_used', v_pts, 'credit', round(v_pts / 100.0, 2),
    'total', round(v_after + v_tax - v_pts / 100.0, 2), 'code_usable', s.redeemed_at is null and s.expires_at > now(),
    'fast_claim', now() <= coalesce(s.hold_until, s.created_at), 'hold_until', s.hold_until, 'expires_at', s.expires_at);
end $$;

create or replace function public.place_order(
  p_code text, p_store text, p_mode text, p_name text, p_phone text, p_address text, p_note text,
  p_items jsonb, p_use_prize boolean, p_points int, p_payment text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.spins; st public.stores; q jsonb; v_phone text; o public.orders; v_use boolean; m public.members;
begin
  select * into s from spins where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then raise exception 'Code not found' using errcode = 'P0002', hint = 'Spin and claim a prize first, then order with its code.'; end if;
  if (select count(*) from orders where spin_id = s.id and created_at > now() - interval '1 day') >= 5 then
    raise exception 'Too many orders on this code today' using errcode = '53400', hint = 'Call the store if you need to change an order.';
  end if;
  select * into st from stores where id = coalesce(p_store, s.store_id) and client_id = s.client_id;
  if not found then raise exception 'Pick a store' using errcode = '22023', hint = 'Choose the store you want to order from.'; end if;
  if p_mode not in ('pickup', 'delivery') or (p_mode = 'pickup' and not st.pickup) or (p_mode = 'delivery' and not st.delivery) then
    raise exception 'That store does not offer %', coalesce(p_mode, 'that') using errcode = '22023', hint = 'Choose pickup or delivery from the options shown.';
  end if;
  if p_payment not in ('pay_at_store', 'pay_on_delivery', 'card_demo') or (p_mode = 'pickup' and p_payment = 'pay_on_delivery') or (p_mode = 'delivery' and p_payment = 'pay_at_store') then
    raise exception 'Pick how you will pay' using errcode = '22023', hint = 'Pay at the store for pickup, or pay the driver for delivery.';
  end if;
  if length(btrim(coalesce(p_name, ''))) not between 1 and 60 then raise exception 'Add a name for the order' using errcode = '22023', hint = 'Staff call out this name.'; end if;
  v_phone := platterly_norm_phone(p_phone);
  if p_mode = 'delivery' then
    if v_phone is null then raise exception 'Delivery needs a mobile number' using errcode = '22023', hint = 'The driver calls it on arrival.'; end if;
    if length(btrim(coalesce(p_address, ''))) not between 5 and 200 then raise exception 'Add the delivery address' using errcode = '22023', hint = 'Street, unit or floor, and buzzer.'; end if;
  end if;
  v_use := coalesce(p_use_prize, true) and s.redeemed_at is null and s.expires_at > now();
  q := quote_order(s.code, p_items, v_use, p_points);
  v_use := v_use and (q->>'prize_applied')::boolean;
  select * into m from members where id = s.member_id;

  insert into orders (number, client_id, store_id, member_id, lead_id, spin_id, prize_used, mode, name, phone, email, address, note, items,
                      subtotal, discount, tax, points_used, credit, total, payment, fast_claim)
  values (platterly_code('PO'), s.client_id, st.id, s.member_id, s.lead_id, s.id, v_use, p_mode, btrim(p_name), coalesce(v_phone, m.phone), m.email,
          case when p_mode = 'delivery' then btrim(p_address) end, nullif(left(btrim(coalesce(p_note, '')), 300), ''), q->'lines',
          (q->>'subtotal')::numeric, (q->>'discount')::numeric, (q->>'tax')::numeric, (q->>'points_used')::int, (q->>'credit')::numeric,
          (q->>'total')::numeric, p_payment, (q->>'fast_claim')::boolean and v_use)
  returning * into o;
  if o.points_used > 0 then
    insert into points_ledger (member_id, client_id, delta, reason, ref) values (s.member_id, s.client_id, -o.points_used, 'spent', o.number);
  end if;
  if v_use then
    update spins set redeemed_at = now(), redeemed_store = st.id, order_total = o.subtotal where id = s.id;
    update reminders set status = 'cancelled' where spin_id = s.id and status = 'pending';
  end if;
  return jsonb_build_object('ok', true, 'number', o.number, 'status', o.status, 'total', o.total, 'prize_used', v_use, 'mode', o.mode,
    'store', st.name, 'points_used', o.points_used, 'points_balance', member_points(s.member_id),
    'earn', floor((o.subtotal - o.discount) * 5)::int + case when o.fast_claim then 100 else 0 end);
end $$;

create or replace function public.order_status(p_number text, p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('ok', true, 'number', o.number, 'status', o.status, 'mode', o.mode, 'total', o.total, 'updated_at', o.updated_at)
    from orders o join spins s on s.id = o.spin_id
    where o.number = upper(btrim(coalesce(p_number, ''))) and s.code = upper(btrim(coalesce(p_code, '')))),
    jsonb_build_object('ok', false, 'msg', 'Order not found.'))
$$;

-- ---------- staff ----------
create or replace function public.staff_orders(p_staff uuid, p_client text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_scope text[] := staff_scope(p_staff, p_client);
begin
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
    select o.id, o.number, o.client_id, o.store_id, o.mode, o.name, o.phone, o.email, o.address, o.note, o.items, o.subtotal, o.discount, o.tax,
           o.points_used, o.credit, o.total, o.payment, o.status, o.prize_used, o.created_at, o.updated_at, s.code
    from orders o left join spins s on s.id = o.spin_id
    where o.client_id = any(v_scope) order by o.created_at desc limit 500) x), '[]'::jsonb);
end $$;

-- Moving an order along. Completed: the customer earns 5 points per $1 of food, plus the fast-claim bonus.
-- Cancelled: points spent come back and an unexpired prize code works again.
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
  update orders set status = p_status, updated_at = now() where id = o.id;
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

-- Counter redemption now also builds Platterly points: 5 per $1 of the order, +100 inside the 2-hour window.
create or replace function public.staff_redeem(p_staff uuid, p_code text, p_store text, p_order_total numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.spins; o public.offers; l public.leads; r jsonb; v_pts int := 0;
begin
  select * into s from spins where code = upper(btrim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('ok', false, 'msg', 'No code like that.'); end if;
  perform staff_scope(p_staff, s.client_id);
  select * into o from offers where id = s.offer_id; select * into l from leads where id = s.lead_id;
  r := redeem_code(p_code, p_store, p_order_total);
  if (r->>'ok')::boolean then
    update reminders set status = 'cancelled' where spin_id = s.id and status = 'pending';
    if s.member_id is not null then
      if coalesce(p_order_total, 0) > 0 then
        v_pts := floor(p_order_total * 5)::int;
        insert into points_ledger (member_id, client_id, delta, reason, ref) values (s.member_id, s.client_id, v_pts, 'store_visit', s.code);
      end if;
      if now() <= coalesce(s.hold_until, s.created_at) then
        insert into points_ledger (member_id, client_id, delta, reason, ref) values (s.member_id, s.client_id, 100, 'fast_claim', s.code);
        v_pts := v_pts + 100;
      end if;
    end if;
  end if;
  return r || jsonb_build_object('prize', case when s.upsized then o.big_title else o.title end,
    'rule', case when s.upsized then o.big_rule else o.rule end, 'name', l.first_name, 'points_awarded', v_pts);
end $$;

-- Customer door: their prizes, Platterly points and orders, proven by a contact plus any code they received.
create or replace function public.customer_history(p_client text, p_contact text, p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c record; v_member uuid;
begin
  select * into c from platterly_contact(p_contact);
  select s.member_id into v_member from spins s join members m on m.id = s.member_id
   where s.code = upper(btrim(coalesce(p_code, ''))) and (m.email = c.contact or m.phone = c.contact)
     and (p_client is null or s.client_id = p_client) limit 1;
  if v_member is null then
    -- codes from before members existed
    select l.member_id into v_member from leads l join spins s on s.lead_id = l.id
     where (p_client is null or l.client_id = p_client) and l.contact = c.contact and s.code = upper(btrim(coalesce(p_code, ''))) limit 1;
  end if;
  if v_member is null then return jsonb_build_object('ok', false, 'msg', 'No prizes found for that contact and code.'); end if;
  return jsonb_build_object('ok', true, 'name', (select first_name from members where id = v_member),
    'points', member_points(v_member),
    'spins', (select jsonb_agg(jsonb_build_object('code', s.code, 'client', cl.name, 'prize', case when s.upsized then o.big_title else o.title end,
                'rule', case when s.upsized then o.big_rule else o.rule end, 'day', s.spin_day, 'expires_at', s.expires_at,
                'redeemed', s.redeemed_at is not null) order by s.created_at desc)
              from spins s join offers o on o.id = s.offer_id join clients cl on cl.id = s.client_id where s.member_id = v_member),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('number', o.number, 'client', cl.name, 'status', o.status, 'mode', o.mode, 'total', o.total,
                'created_at', o.created_at) order by o.created_at desc) from orders o join clients cl on cl.id = o.client_id where o.member_id = v_member), '[]'::jsonb),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('delta', p.delta, 'reason', p.reason, 'ref', p.ref, 'at', p.created_at) order by p.created_at desc)
              from points_ledger p where p.member_id = v_member), '[]'::jsonb));
end $$;

-- ---------- reminders (the proxy sends them) ----------
create or replace function public.reminders_claim(p_limit int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  update reminders r set status = 'cancelled' from spins s
   where s.id = r.spin_id and r.status = 'pending' and r.due_at <= now() and (s.redeemed_at is not null or s.expires_at <= now());
  with due as (
    select id from reminders where status = 'pending' and due_at <= now() order by due_at for update skip locked limit least(greatest(coalesce(p_limit, 10), 1), 50)
  ), upd as (
    update reminders r set status = 'sending', attempts = attempts + 1 from due where r.id = due.id returning r.*
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'channel', u.channel, 'to', u.to_addr, 'first_name', l.first_name, 'code', s.code,
           'prize', case when s.upsized then o.big_title else o.title end, 'rule', case when s.upsized then o.big_rule else o.rule end,
           'store', st.name, 'address', st.address, 'delivery', coalesce(st.delivery, false), 'client', c.name, 'client_id', c.id, 'expires_at', s.expires_at)), '[]'::jsonb) into v
  from upd u join spins s on s.id = u.spin_id join leads l on l.id = s.lead_id join offers o on o.id = s.offer_id
       join clients c on c.id = s.client_id left join stores st on st.id = s.store_id;
  return v;
end $$;

create or replace function public.reminder_done(p_id bigint, p_status text, p_error text) returns void
language sql security definer set search_path = public as $$
  update reminders set status = case when p_status in ('sent', 'test_inbox', 'skipped', 'failed') then p_status else 'failed' end,
    sent_at = case when p_status in ('sent', 'test_inbox') then now() end, error = left(p_error, 300)
  where id = p_id and status = 'sending';
$$;

do $$ declare f text; begin
  foreach f in array array['member_points(uuid)', 'store_close(text,date)', 'platterly_norm_email(text)', 'platterly_norm_phone(text)',
    'price_order(text,jsonb,text,boolean,boolean)', 'staff_orders(uuid,text)', 'staff_set_order_status(uuid,uuid,text)',
    'reminders_claim(int)', 'reminder_done(bigint,text,text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array['submit_claim(text,text,text,text,text,boolean,boolean,text,boolean,text,text)', 'menu_for(text)',
    'quote_order(text,jsonb,boolean,int)', 'place_order(text,text,text,text,text,text,text,jsonb,boolean,int,text)', 'order_status(text,text)'] loop
    execute format('revoke all on function public.%s from public, authenticated', f);
    execute format('grant execute on function public.%s to anon, service_role', f);
  end loop;
end $$;

-- Leads list shows both contacts when the customer gave both.
create or replace function public.staff_leads(p_staff uuid, p_client text, p_search text, p_consent_only boolean, p_limit int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_scope text[] := staff_scope(p_staff, p_client);
begin
  return coalesce((select jsonb_agg(row_to_json(x) order by x.last_seen_at desc) from (
    select l.id, l.client_id, l.first_name, l.contact, l.contact_kind, l.email, l.phone, l.consent, l.first_store, l.first_source,
           l.created_at, l.last_seen_at,
           count(s.id) as spins, count(s.redeemed_at) as redeemed, coalesce(sum(s.order_total), 0) as redeemed_total,
           (select o.title || case when s2.upsized then ' (upsized)' else '' end from spins s2 join offers o on o.id = s2.offer_id
             where s2.lead_id = l.id order by s2.created_at desc limit 1) as last_prize,
           (select s2.code from spins s2 where s2.lead_id = l.id order by s2.created_at desc limit 1) as last_code,
           (select count(*) from catering_requests r where r.lead_id = l.id) as catering
    from leads l left join spins s on s.lead_id = l.id
    where l.client_id = any(v_scope)
      and (not coalesce(p_consent_only, false) or l.consent)
      and (coalesce(btrim(p_search), '') = '' or l.first_name ilike '%' || btrim(p_search) || '%' or l.contact ilike '%' || btrim(p_search) || '%' or l.email ilike '%' || btrim(p_search) || '%' or l.phone ilike '%' || btrim(p_search) || '%')
    group by l.id
    order by l.last_seen_at desc
    limit least(greatest(coalesce(p_limit, 200), 1), 2000)) x), '[]'::jsonb);
end $$;

-- The old QR call (one contact field) goes through the same claim, so every lead has a Platterly member.
-- Kept for phones that queued a sign-up offline before the pages changed.
create or replace function public.submit_lead(
  p_client text, p_store text, p_first_name text, p_contact text, p_consent boolean,
  p_offer text, p_quiz_right boolean, p_source text, p_consent_wording text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from platterly_contact(p_contact);
  if c.contact is null then
    raise exception 'Contact is not an email or a 10-digit mobile number' using errcode = '22023',
      hint = 'Enter an email address or a 10-digit mobile number.';
  end if;
  return submit_claim(p_client, p_store, p_first_name, case when c.kind = 'email' then c.contact end, case when c.kind = 'phone' then c.contact end,
                      p_consent, false, p_offer, p_quiz_right, p_source, p_consent_wording);
end $$;

-- The order page opens with only a code: which brand and store, the prize, its timers, the member's points.
-- First name only (no email or phone): the code is a bearer token for one day.
create or replace function public.code_info(p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('ok', true, 'code', s.code, 'client', s.client_id, 'store', s.store_id, 'first_name', l.first_name,
      'prize', case when s.upsized then o.big_title else o.title end, 'rule', case when s.upsized then o.big_rule else o.rule end,
      'upsized', s.upsized, 'used', s.redeemed_at is not null, 'hold_until', s.hold_until, 'expires_at', s.expires_at,
      'expired', s.expires_at <= now(), 'points', member_points(s.member_id), 'has_phone', m.phone is not null)
    from spins s join offers o on o.id = s.offer_id join leads l on l.id = s.lead_id left join members m on m.id = s.member_id
    where s.code = upper(btrim(coalesce(p_code, '')))),
    jsonb_build_object('ok', false, 'msg', 'No Platterly code like that. Check the letters, or spin to get one.'))
$$;
revoke all on function public.code_info(text) from public, authenticated;
grant execute on function public.code_info(text) to anon, service_role;

-- Onboarding: two platform steps every partner now needs.
insert into public.onboarding_steps (id, stage, sort, title, detail, owner) values
  ('reminder-sender', 4, 5, 'Reminder sender set up', 'Resend (email) and Twilio (text) keys in mail.env on the store laptop. Until then reminders go to the test inbox only.', 'platterly'),
  ('order-flow',      5, 5, 'Store takes Platterly orders', 'Staff watch the Orders tab, enter each order in the till, and mark it ready. Delivery: who drives is agreed.', 'client')
on conflict (id) do nothing;
