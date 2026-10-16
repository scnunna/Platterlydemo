-- Platterly 0003: more than one client, and the super-admin onboarding board.
-- Each client gets its own coupon prefix (Panago PG-, Wetzel's WP-; PL- when none is set) and brand colour. The onboarding board is a
-- fixed journey (stages -> steps) with each client's progress; only a super admin can read or change it.

alter table public.clients
  add column code_prefix text check (code_prefix ~ '^[A-Z]{2}$'),
  add column brand_color text not null default '#0E4D4A' check (brand_color ~ '^#[0-9A-Fa-f]{6}$'),
  add column kind text not null default 'franchisee' check (length(kind) between 1 and 40);
create unique index clients_code_prefix_idx on public.clients (code_prefix);
update public.clients set code_prefix = 'PG' where id = 'panago';
alter table public.stores add column hours text;

-- The client's journey, the same for every client. Columns of the board are stages; cards are steps.
create table public.onboarding_stages (
  stage int primary key check (stage between 1 and 20),
  title text not null,
  goal  text not null
);
create table public.onboarding_steps (
  id     text primary key check (id ~ '^[a-z0-9-]{2,40}$'),
  stage  int not null references public.onboarding_stages(stage),
  sort   int not null,
  title  text not null,
  detail text not null,
  owner  text not null check (owner in ('platterly', 'client', 'both')),
  unique (stage, sort)
);
create table public.client_onboarding (
  client_id text not null references public.clients(id) on delete cascade,
  step_id   text not null references public.onboarding_steps(id) on delete cascade,
  done_at   timestamptz,
  done_by   text,
  note      text check (length(note) <= 500),
  updated_at timestamptz not null default now(),
  primary key (client_id, step_id)
);
do $$ declare t text; begin
  foreach t in array array['onboarding_stages','onboarding_steps','client_onboarding'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

insert into public.onboarding_stages (stage, title, goal) values
  (1, 'Discover',           'Who decides, which stores, what a win looks like'),
  (2, 'Research & brand',   'Menu, prices, catering, deals and brand captured'),
  (3, 'Offers & rules',     'Prize wheel, contest rules and consent signed off'),
  (4, 'Build',              'Client, stores, QR page and screens set up'),
  (5, 'Accounts & training','Owner signed in, staff can redeem a code'),
  (6, 'Launch',             'Screen on, QR scanned on site, first real lead'),
  (7, 'Live & grow',        'Weekly numbers, follow-ups, catering bookings');

insert into public.onboarding_steps (id, stage, sort, title, detail, owner) values
  ('discovery-call',   1, 1, 'Discovery call',               'Goals, busy seasons, what they want from screens and catering. Keep the notes.', 'both'),
  ('decision-maker',   1, 2, 'Decision-maker and stores',     'Owner or operator name, legal business name, store addresses, who signs.', 'client'),
  ('pilot-scope',      1, 3, 'Pilot scope agreed',            'Which store, how many screens, start date, price of the pilot.', 'both'),
  ('menu-prices',      2, 1, 'Menu and prices captured',      'Current in-store menu with prices. Delivery-app prices are marked up; confirm at the counter.', 'platterly'),
  ('catering-map',     2, 2, 'Catering packages mapped',      'Party packs, trays, serves-how-many, lead time, whether the store offers it.', 'platterly'),
  ('deals-map',        2, 3, 'Store deals and loyalty mapped','Existing promos and rewards app, so the wheel does not clash with them.', 'platterly'),
  ('brand-kit',        2, 4, 'Brand kit',                     'Logo, colours, fonts, voice, taken from the brand''s own site or files.', 'platterly'),
  ('prize-list',       3, 1, 'Prize wheel approved',          'Prizes, odds and food cost agreed with the owner. Every spin wins; prizes unlock with a purchase.', 'both'),
  ('contest-rules',    3, 2, 'Contest rules',                 'No purchase necessary, odds published, skill-testing question for draws (Competition Act s.74.06).', 'platterly'),
  ('casl',             3, 3, 'CASL consent wording',          'Unticked box naming the business, its address and contact. Unsubscribe in every message.', 'platterly'),
  ('brand-signoff',    3, 4, 'Brand or landlord sign-off',    'Franchisor approval for branded contests and codes; mall marketing approval for in-mall screens.', 'client'),
  ('client-record',    4, 1, 'Client and stores in Platterly','Client, stores, hours, coupon prefix and prizes in the lead database.', 'platterly'),
  ('qr-page',          4, 2, 'Spin & Win page live',          'Branded lead page on GitHub Pages, tested end to end.', 'platterly'),
  ('screens',          4, 3, 'Screen loop pages',             'Six-page TV or counter-screen loop with a store-tagged QR on every page.', 'platterly'),
  ('qr-tested',        4, 4, 'QR codes scan-tested',          'Every QR decodes to the right store and screen tag.', 'platterly'),
  ('client-admin',     5, 1, 'Client admin login created',    'Owner account limited to their own client. Send the sign-in privately.', 'platterly'),
  ('first-signin',     5, 2, 'Owner signed in, password changed','The owner signs in once and changes the starting password.', 'client'),
  ('staff-trained',    5, 3, 'Staff trained on Redeem',       'Counter staff can check a code and mark it used.', 'client'),
  ('test-redeem',      5, 4, 'Test code redeemed in store',   'One real code redeemed at the counter, on the store''s own device.', 'both'),
  ('screen-installed', 6, 1, 'Screen bought and mounted',     'MVP: one screen, visible from the counter or the walkway.', 'client'),
  ('site-scan',        6, 2, 'On-site scan test',             'Scan from where customers stand, on two phones, cellular data.', 'both'),
  ('first-lead',       6, 3, 'First real lead',               'A customer who is not staff spins and joins.', 'client'),
  ('weekly-report',    7, 1, 'Weekly numbers review',         'Leads, consent rate, redemptions, best screen. Change one thing a week.', 'platterly'),
  ('follow-up',        7, 2, 'Consented list follow-up',      'Message only contacts who said yes. Catering offer before each busy season.', 'both'),
  ('catering-booked',  7, 3, 'First catering booking',        'A quote request from the prize screen turns into an order.', 'client');

-- Only a super admin passes.
create or replace function public.staff_require_super(p_staff uuid) returns public.staff
language plpgsql stable security definer set search_path = public as $$
declare s public.staff;
begin
  select * into s from staff where id = p_staff and active;
  if not found or s.role <> 'super_admin' then
    raise exception 'Super admin only' using errcode = '42501', hint = 'Only the Platterly team can see onboarding.';
  end if;
  return s;
end $$;

-- The whole board: stages, steps, and every client's progress plus live facts that show whether a step really happened.
create or replace function public.staff_onboarding(p_staff uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform staff_require_super(p_staff);
  return jsonb_build_object(
    'stages', (select jsonb_agg(to_jsonb(s) order by s.stage) from onboarding_stages s),
    'steps', (select jsonb_agg(to_jsonb(t) order by t.stage, t.sort) from onboarding_steps t),
    'clients', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name, 'kind', c.kind, 'brand_color', c.brand_color, 'code_prefix', c.code_prefix, 'created_at', c.created_at,
        'stores', (select coalesce(jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name, 'address', st.address) order by st.name), '[]') from stores st where st.client_id = c.id),
        'admins', (select coalesce(jsonb_agg(jsonb_build_object('email', a.email, 'name', a.name, 'last_login_at', a.last_login_at) order by a.email), '[]') from staff a where a.client_id = c.id and a.active),
        'facts', jsonb_build_object(
          'leads', (select count(*) from leads l where l.client_id = c.id),
          'redeemed', (select count(*) from spins s where s.client_id = c.id and s.redeemed_at is not null),
          'catering_booked', (select count(*) from catering_requests r where r.client_id = c.id and r.status = 'booked'),
          'offers', (select count(*) from offers o where o.client_id = c.id and o.active)),
        'progress', (select coalesce(jsonb_object_agg(p.step_id, jsonb_build_object('done_at', p.done_at, 'done_by', p.done_by, 'note', p.note)), '{}') from client_onboarding p where p.client_id = c.id)
      ) order by c.created_at) from clients c), '[]'::jsonb)
  );
end $$;

-- Tick or untick a step, with an optional note. p_done null keeps the state and only changes the note.
create or replace function public.staff_onboarding_set(p_staff uuid, p_client text, p_step text, p_done boolean, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.staff := staff_require_super(p_staff);
begin
  if not exists (select 1 from clients where id = p_client) then return jsonb_build_object('ok', false, 'msg', 'Unknown client.'); end if;
  if not exists (select 1 from onboarding_steps where id = p_step) then return jsonb_build_object('ok', false, 'msg', 'Unknown step.'); end if;
  insert into client_onboarding (client_id, step_id, done_at, done_by, note)
  values (p_client, p_step, case when p_done then now() end, case when p_done then s.name end, nullif(left(btrim(coalesce(p_note, '')), 500), ''))
  on conflict (client_id, step_id) do update set
    done_at = case when p_done is null then client_onboarding.done_at when p_done then coalesce(client_onboarding.done_at, now()) end,
    done_by = case when p_done is null then client_onboarding.done_by when p_done then coalesce(client_onboarding.done_by, s.name) end,
    note = case when p_note is null then client_onboarding.note else nullif(left(btrim(p_note), 500), '') end,
    updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

do $$ declare f text; begin
  foreach f in array array['staff_require_super(uuid)', 'staff_onboarding(uuid)', 'staff_onboarding_set(uuid,text,text,boolean,text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- Coupons carry the client's own prefix (was always PG-).
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
  values (p_client, v_lead.id, v_offer.id, v_up, v_reason, platterly_code(coalesce((select code_prefix from clients where id = p_client), 'PL')), p_store, left(p_source, 60),
          ((v_today + 1)::timestamp at time zone 'America/Toronto'))
  returning * into v_spin;

  return jsonb_build_object('code', v_spin.code, 'already', false, 'returning', v_returning, 'upsized', v_up,
    'title', case when v_up then v_offer.big_title else v_offer.title end,
    'rule', case when v_up then v_offer.big_rule else v_offer.rule end,
    'expires_at', v_spin.expires_at, 'visits', v_prev + 1);
end $$;

-- Sign-in also returns each client's stores, coupon prefix and colour, so the portal is not Panago-only.
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
    'clients', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'code_prefix', c.code_prefix, 'brand_color', c.brand_color,
        'stores', (select coalesce(jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name) order by st.name), '[]') from stores st where st.client_id = c.id)) order by c.name) from clients c
                         where s.role = 'super_admin' or c.id = s.client_id), '[]'::jsonb));
end $$;

-- Customer door: the code itself says which client it belongs to, so p_client may be null.
create or replace function public.customer_history(p_client text, p_contact text, p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c record; v_lead uuid;
begin
  select * into c from platterly_contact(p_contact);
  select l.id into v_lead from leads l join spins s on s.lead_id = l.id
   where (p_client is null or l.client_id = p_client) and l.contact = c.contact and s.code = upper(btrim(coalesce(p_code, ''))) limit 1;
  if v_lead is null then return jsonb_build_object('ok', false, 'msg', 'No prizes found for that contact and code.'); end if;
  return jsonb_build_object('ok', true, 'name', (select first_name from leads where id = v_lead),
    'spins', (select jsonb_agg(jsonb_build_object('code', s.code, 'prize', case when s.upsized then o.big_title else o.title end,
                'rule', case when s.upsized then o.big_rule else o.rule end, 'day', s.spin_day, 'expires_at', s.expires_at,
                'redeemed', s.redeemed_at is not null) order by s.created_at desc)
              from spins s join offers o on o.id = s.offer_id where s.lead_id = v_lead));
end $$;
