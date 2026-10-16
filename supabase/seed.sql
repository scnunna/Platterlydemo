-- Platterly seed: Panago (franchisee) and its Spin & Win prizes. Real configuration, no sample people.
insert into public.clients (id, name) values ('panago', 'Panago Ontario (franchisee)') on conflict (id) do nothing;
insert into public.stores (id, client_id, name, address) values
  ('gerrard', 'panago', 'Panago Gerrard', '44 Gerrard St W, Toronto, ON M5G 2K2'),
  ('bremner', 'panago', 'Panago Bremner', '133 Bremner Blvd, Toronto, ON M5J 3A7')
on conflict (id) do nothing;
-- Odds add up to 100. Values are Ontario menu prices (PL4, Oct 2026); pop is not on the printed menu.
insert into public.offers (id, client_id, title, rule, big_title, big_rule, odds, value) values
  ('pop',     'panago', 'Free 591 ml pop',          'with any pizza',                 'Two free pops',            'with any pizza',                 25, null),
  ('dip',     'panago', 'Free dip',                 'with any large pizza',           'Two free dips',            'with any large pizza',           20, 1.30),
  ('gcb',     'panago', 'Free Garlic Cheezy Bread', 'with any 2 medium pizzas',       'Free Garlic Cheezy Bread', 'with any 1 large pizza',         18, 7.25),
  ('churro',  'panago', 'Free 8 pc Churro Bites',   'with any large pizza',           'Free 16 pc Churro Bites',  'with any large pizza',           14, 6.85),
  ('wings',   'panago', 'Free 8 pc wings',          'with any 2 large pizzas',        'Free 16 pc wings',         'with any 2 large pizzas',        10, 11.95),
  ('tenoff',  'panago', '10% off',                  'an order of 5+ pizzas',          '15% off',                  'an order of 5+ pizzas',          13, null)
on conflict (id) do nothing;

-- Client look and coupon prefixes (0003).
update public.clients set code_prefix = 'PG', brand_color = '#522171', kind = 'Pizza franchisee' where id = 'panago';
update public.stores set hours = 'Daily 11 AM to 11 PM, Fri and Sat to midnight' where client_id = 'panago';

-- Wetzel's Pretzels, CF Toronto Eaton Centre. Research 2026-10-15: web/wetzels/menu.json.
insert into public.clients (id, name, code_prefix, brand_color, kind)
values ('wetzels', 'Wetzel''s Pretzels (CF Toronto Eaton Centre)', 'WP', '#004089', 'Mall snack kiosk')
on conflict (id) do nothing;
insert into public.stores (id, client_id, name, address, hours) values
  ('eaton', 'wetzels', 'Wetzel''s Toronto Eaton Centre', '220 Yonge St, Toronto, ON M5B 2H1', 'Mon to Sat 10 AM to 9 PM, Sun 11 AM to 7 PM')
on conflict (id) do nothing;
-- Odds add up to 100. Values: delivery-app list prices for this store (Oct 2026); in-store prices may be lower.
-- Draft prize list: the owner approves prizes and food cost before launch (onboarding step prize-list).
insert into public.offers (id, client_id, title, rule, big_title, big_rule, odds, value) values
  ('wp-dip',   'wetzels', 'Free dip',                    'with any pretzel',             'Two free dips',              'with any pretzel',            30, null),
  ('wp-off',   'wetzels', '$2 off',                      'any order of $10 or more',     '$5 off',                     'any order of $15 or more',    20, null),
  ('wp-lemon', 'wetzels', 'Free Fresh Lemonade',         'with any 2 pretzels',          'Free Fresh Lemonade',        'with any pretzel',            15, 5.59),
  ('wp-bogo',  'wetzels', 'Buy one, get one Original',   'Original or Sinful Cinnamon',  'Buy one, get one any pretzel','any pretzel on the menu',     15, 6.49),
  ('wp-bitz',  'wetzels', 'Free Wetzel Bitz',            'with any 2 pretzels',          'Free Wetzel Bitz',           'with any pretzel',            15, 8.25),
  ('wp-party', 'wetzels', '10% off a Party Pack',        'or any catering tray',         '15% off a Party Pack',       'or any catering tray',         5, null)
on conflict (id) do nothing;

-- Onboarding progress at setup. After this, the super admin ticks steps on the board.
insert into public.client_onboarding (client_id, step_id, done_at, done_by, note) values
  ('panago', 'discovery-call',  now(), 'Platterly setup', 'Phone call with Kiran Varma: catering + corporate focus, Nov to Jan, 6-screen loop, Temu-style wheel.'),
  ('panago', 'decision-maker',  now(), 'Platterly setup', 'Kiran Varma, Ontario franchisee. Gerrard St W + Bremner Blvd. Legal business name still to confirm.'),
  ('panago', 'pilot-scope',     now(), 'Platterly setup', 'MVP on 1 TV, whole setup by November, 2 weeks. Screen purchase first.'),
  ('panago', 'menu-prices',     now(), 'Platterly setup', 'Ontario menu PL4, Oct 2026 regular pricing.'),
  ('panago', 'catering-map',    now(), 'Platterly setup', 'Winter Sales Sprint consultant plan.'),
  ('panago', 'brand-kit',       now(), 'Platterly setup', 'Content Studio client panago + web/panago/brand.json.'),
  ('panago', 'contest-rules',   now(), 'Platterly setup', 'Rules and odds in the game. Legal review recommended before launch.'),
  ('panago', 'casl',            now(), 'Platterly setup', null),
  ('panago', 'client-record',   now(), 'Platterly setup', null),
  ('panago', 'qr-page',         now(), 'Platterly setup', 'web/panago/, live test lead saved and deleted.'),
  ('panago', 'screens',         now(), 'Platterly setup', 'web/panago/tv/, kiosk mode ?s=g#tv.'),
  ('panago', 'qr-tested',       now(), 'Platterly setup', 'All 6 pages x 2 stores decode.'),
  ('panago', 'client-admin',    now(), 'Platterly setup', 'Placeholder email panago.admin@platterly.local until Kiran sends his.'),
  ('panago', 'prize-list',      null,  null,              'Prize types from Kiran''s call; odds and food cost not yet approved.'),
  ('wetzels', 'menu-prices',    now(), 'Platterly setup', 'Menu from wetzelspretzels.ca. Prices only from delivery apps (marked up): confirm at the counter.'),
  ('wetzels', 'catering-map',   now(), 'Platterly setup', 'Packs and trays from wetzels.com (US). Not confirmed for Canada or this store.'),
  ('wetzels', 'deals-map',      now(), 'Platterly setup', 'Wetzel''s Rewards (US terms): 50 points = $5, sign-up BOGO. Canadian terms unconfirmed.'),
  ('wetzels', 'brand-kit',      now(), 'Platterly setup', 'Blue #004089, yellow #FED900, sky #B7E5F0, Londrina Solid, from wetzels.com.'),
  ('wetzels', 'contest-rules',  now(), 'Platterly setup', 'Rules and odds in the game. Legal review recommended before launch.'),
  ('wetzels', 'casl',           now(), 'Platterly setup', 'Names the store and address. Swap in the legal operator name once known.'),
  ('wetzels', 'client-record',  now(), 'Platterly setup', null),
  ('wetzels', 'qr-page',        now(), 'Platterly setup', 'web/wetzels/.'),
  ('wetzels', 'client-admin',   now(), 'Platterly setup', 'Placeholder email wetzels.admin@platterly.local until the owner sends theirs.'),
  ('wetzels', 'discovery-call', null,  null,              'Not done yet: no call with the store. Operator unknown (MTY Food Group owns Wetzel''s Canada).'),
  ('wetzels', 'prize-list',     null,  null,              'Draft prize list in the game; owner to approve prizes and food cost.')
on conflict do nothing;
