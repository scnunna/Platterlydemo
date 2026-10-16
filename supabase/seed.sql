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

-- Platterly 0004: menus for ordering through Platterly, closing times, pickup/delivery, prize rewards.
-- Generated from web/index.html (Panago Ontario menu, Oct 2026) and web/wetzels/menu.json (delivery-app prices,
-- to be confirmed by the store). Items with orderable = false exist only as prize items.
update public.stores set close_times = '{"0":"23:00","1":"23:00","2":"23:00","3":"23:00","4":"23:00","5":"24:00","6":"24:00"}'::jsonb, pickup = true, delivery = true where client_id = 'panago';
update public.stores set close_times = '{"0":"19:00","1":"21:00","2":"21:00","3":"21:00","4":"21:00","5":"21:00","6":"21:00"}'::jsonb, pickup = true, delivery = false where client_id = 'wetzels';
update public.offers set reward = '{"normal":{"free":"pop","qty":1,"requires":{"cat":"pizza","qty":1}},"big":{"free":"pop","qty":2,"requires":{"cat":"pizza","qty":1}}}'::jsonb where id = 'pop';
update public.offers set reward = '{"normal":{"free":"dip","qty":1,"requires":{"cat":"pizza","sizes":["L","XL"],"qty":1}},"big":{"free":"dip","qty":2,"requires":{"cat":"pizza","sizes":["L","XL"],"qty":1}}}'::jsonb where id = 'dip';
update public.offers set reward = '{"normal":{"free":"garlic-cheezy-bread","qty":1,"requires":{"cat":"pizza","sizes":["M","L","XL"],"qty":2}},"big":{"free":"garlic-cheezy-bread","qty":1,"requires":{"cat":"pizza","sizes":["L","XL"],"qty":1}}}'::jsonb where id = 'gcb';
update public.offers set reward = '{"normal":{"free":"churro-8","qty":1,"requires":{"cat":"pizza","sizes":["L","XL"],"qty":1}},"big":{"free":"churro-16","qty":1,"requires":{"cat":"pizza","sizes":["L","XL"],"qty":1}}}'::jsonb where id = 'churro';
update public.offers set reward = '{"normal":{"free":"wings-8","qty":1,"requires":{"cat":"pizza","sizes":["L","XL"],"qty":2}},"big":{"free":"wings-16","qty":1,"requires":{"cat":"pizza","sizes":["L","XL"],"qty":2}}}'::jsonb where id = 'wings';
update public.offers set reward = '{"normal":{"pct":10,"requires":{"cat":"pizza","qty":5}},"big":{"pct":15,"requires":{"cat":"pizza","qty":5}}}'::jsonb where id = 'tenoff';
update public.offers set reward = '{"normal":{"free":"dip","qty":1,"requires":{"cat":"pretzels","qty":1}},"big":{"free":"dip","qty":2,"requires":{"cat":"pretzels","qty":1}}}'::jsonb where id = 'wp-dip';
update public.offers set reward = '{"normal":{"amt":2,"min":10},"big":{"amt":5,"min":15}}'::jsonb where id = 'wp-off';
update public.offers set reward = '{"normal":{"free":"fresh-lemonade","qty":1,"requires":{"cat":"pretzels","qty":2}},"big":{"free":"fresh-lemonade","qty":1,"requires":{"cat":"pretzels","qty":1}}}'::jsonb where id = 'wp-lemon';
update public.offers set reward = '{"normal":{"bogo":["original","sinful-cinnamon"]},"big":{"bogo_cat":"pretzels"}}'::jsonb where id = 'wp-bogo';
update public.offers set reward = '{"normal":{"free":"wetzel-bitz","qty":1,"requires":{"cat":"pretzels","qty":2}},"big":{"free":"wetzel-bitz","qty":1,"requires":{"cat":"pretzels","qty":1}}}'::jsonb where id = 'wp-bitz';
update public.offers set reward = '{"normal":{"pct":10,"requires":{"cat":"catering","qty":1}},"big":{"pct":15,"requires":{"cat":"catering","qty":1}}}'::jsonb where id = 'wp-party';
insert into public.menu_items (client_id, id, name, cat, grp, descr, price, sizes, unit, tags, orderable, sort) values
  ('panago', 'beef-taco', 'Beef Taco', 'pizza', 'Meat pizzas', 'Salsa, ground beef, red onions, diced tomatoes, sour cream drizzle, shredded lettuce, mozzarella and cheddar', null, '{"S":16,"M":20,"L":25.25,"XL":30.5}'::jsonb, null, array[]::text[], true, 0),
  ('panago', 'chicken-taco', 'Chicken Taco', 'pizza', 'Meat pizzas', 'Salsa, grilled chicken, red onions, diced tomatoes, sour cream drizzle, shredded lettuce, mozzarella and cheddar', null, '{"S":16,"M":20,"L":25.25,"XL":30.5}'::jsonb, null, array[]::text[], true, 1),
  ('panago', 'brooklyn-pepperoni', 'Brooklyn Pepperoni', 'pizza', 'Meat pizzas', 'Organic tomato sauce, mozzarella, layers of pepperoni and Cupperoni', null, '{"S":13.5,"M":16,"L":20,"XL":23.75}'::jsonb, null, array[]::text[], true, 2),
  ('panago', 'deluxe', 'Deluxe (Pepperoni)', 'pizza', 'Meat pizzas', 'Organic tomato sauce, extra pepperoni, sliced fresh mushrooms, green peppers and mozzarella', null, '{"S":14.75,"M":18.5,"L":22.75,"XL":26}'::jsonb, null, array['deal']::text[], true, 3),
  ('panago', 'new-york-deli', 'New York Deli', 'pizza', 'Meat pizzas', 'Organic tomato sauce, pepperoni, Genoa salami, bacon, Canadian ham, spicy Italian sausage, mozzarella and cheddar', null, '{"S":16.25,"M":20.5,"L":25,"XL":29.5}'::jsonb, null, array[]::text[], true, 4),
  ('panago', 'chicken-club', 'Chicken Club', 'pizza', 'Meat pizzas', 'Jalapeño white sauce, grilled chicken, Canadian ham, bacon, tomatoes and mozzarella', null, '{"S":17.5,"M":22.25,"L":26.75,"XL":31.25}'::jsonb, null, array[]::text[], true, 5),
  ('panago', 'bbq-bacon-chicken', 'BBQ Bacon Chicken', 'pizza', 'Meat pizzas', 'Grilled chicken, bacon, caramelized onions, green peppers, mozzarella and cheddar, smoky BBQ drizzle', null, '{"S":16.25,"M":20.5,"L":25.5,"XL":30.25}'::jsonb, null, array[]::text[], true, 6),
  ('panago', 'true-canadian', 'True Canadian', 'pizza', 'Meat pizzas', 'Organic tomato sauce, extra pepperoni, bacon, sliced fresh mushrooms, mozzarella and cheddar', null, '{"S":14.25,"M":18,"L":23.25,"XL":27.5}'::jsonb, null, array[]::text[], true, 7),
  ('panago', 'hawaiian', 'Hawaiian', 'pizza', 'Meat pizzas', 'Organic tomato sauce, extra Canadian ham, extra pineapple and mozzarella', null, '{"S":14.5,"M":18.5,"L":23,"XL":27}'::jsonb, null, array['deal']::text[], true, 8),
  ('panago', 'tropical-hawaiian', 'Tropical Hawaiian', 'pizza', 'Meat pizzas', 'Sweet and smoky tropical sauce, bacon, Canadian ham, pineapple, mozzarella and cheddar', null, '{"S":14.5,"M":18.5,"L":23.25,"XL":27.5}'::jsonb, null, array[]::text[], true, 9),
  ('panago', 'tuscan-pesto-chicken', 'Tuscan Pesto Chicken', 'pizza', 'Meat pizzas', 'Grilled chicken, caramelized onions, green peppers, bruschetta tomatoes, shredded parmesan, mozzarella, pesto drizzle', null, '{"S":17.75,"M":22.75,"L":28,"XL":33.75}'::jsonb, null, array[]::text[], true, 10),
  ('panago', 'steak-mushroom-melt', 'Steak Mushroom Melt', 'pizza', 'Meat pizzas', 'Cheezy cheddar sauce, steak, bacon, sliced fresh mushrooms, mozzarella and cheddar', null, '{"S":18,"M":23,"L":27.75,"XL":33.5}'::jsonb, null, array[]::text[], true, 11),
  ('panago', 'philly-steak', 'Philly Steak', 'pizza', 'Meat pizzas', 'Jalapeño white sauce, steak, caramelized onions, green peppers, sliced fresh mushrooms and mozzarella', null, '{"S":17.25,"M":21.25,"L":26.25,"XL":31}'::jsonb, null, array[]::text[], true, 12),
  ('panago', 'butter-chicken', 'Butter Chicken', 'pizza', 'Meat pizzas', 'Jalapeño white sauce, tandoori spice, mozzarella and cheddar, tandoori chicken, tomatoes and caramelized onions', null, '{"S":17,"M":21,"L":25.5,"XL":30.5}'::jsonb, null, array[]::text[], true, 13),
  ('panago', 'panago-classic', 'Panago Classic', 'pizza', 'Meat pizzas', 'Organic tomato sauce, pepperoni, Canadian ham, red onions, sliced fresh mushrooms, black olives, green peppers and mozzarella', null, '{"S":15.5,"M":19.75,"L":24.25,"XL":28}'::jsonb, null, array[]::text[], true, 14),
  ('panago', 'chipotle-chicken', 'Chipotle Chicken', 'pizza', 'Meat pizzas', 'Chipotle cilantro sauce, grilled chicken, fire-roasted corn, red onions, green peppers, mozzarella and cheddar', null, '{"S":15.75,"M":19.5,"L":24.25,"XL":29}'::jsonb, null, array[]::text[], true, 15),
  ('panago', 'tropical-chicken', 'Tropical Chicken', 'pizza', 'Meat pizzas', 'Sweet and smoky tropical sauce, grilled chicken, pineapple, green peppers, caramelized onions, mozzarella and cheddar', null, '{"S":16,"M":19.5,"L":24.5,"XL":29.5}'::jsonb, null, array['deal']::text[], true, 16),
  ('panago', 'hot-honey-brooklyn', 'Hot Honey Brooklyn Pepperoni', 'pizza', 'Meat pizzas', 'Organic tomato sauce, mozzarella and cheddar, layers of pepperoni and Cupperoni, hot honey drizzle', null, '{"S":15.25,"M":18.5,"L":22.5,"XL":26.5}'::jsonb, null, array[]::text[], true, 17),
  ('panago', 'cupperoni-overload', 'Cupperoni Overload', 'pizza', 'Meat pizzas', 'Organic tomato sauce, mozzarella, crust-to-crust Cupperoni', null, '{"S":13.25,"M":15.75,"L":19.75,"XL":23.5}'::jsonb, null, array[]::text[], true, 18),
  ('panago', 'sweet-cupperoni-heat', 'Sweet Cupperoni Heat', 'pizza', 'Meat pizzas', 'Spicy marinara sauce, mozzarella and cheddar, extra pineapple and Cupperoni', null, '{"S":15,"M":18.5,"L":23.25,"XL":27}'::jsonb, null, array[]::text[], true, 19),
  ('panago', 'spicy-capicollo', 'Spicy Capicollo', 'pizza', 'Meat pizzas', 'Organic tomato sauce, spicy Italian sausage, capicollo, pepperoni, pepperoncini, mozzarella and cheddar', null, '{"S":15.5,"M":19.75,"L":24.25,"XL":28.75}'::jsonb, null, array[]::text[], true, 20),
  ('panago', 'butter-paneer', 'Butter Paneer', 'pizza', 'Veggie pizzas', 'Jalapeño white sauce, tandoori spice, paneer, caramelized onions, tomatoes, mozzarella and cheddar', null, '{"S":15,"M":19,"L":23,"XL":27}'::jsonb, null, array['veg','new']::text[], true, 21),
  ('panago', 'spicy-paneer', 'Spicy Paneer', 'pizza', 'Veggie pizzas', 'Chipotle cilantro sauce, tandoori spice, paneer, green peppers, caramelized onions, fire-roasted corn, jalapeños, mozzarella and cheddar', null, '{"S":15,"M":19,"L":23,"XL":27}'::jsonb, null, array['veg','new','deal']::text[], true, 22),
  ('panago', 'veggie-paneer', 'Veggie Paneer', 'pizza', 'Veggie pizzas', 'Garlic spread, tandoori spice, paneer, caramelized onions, pineapple, sliced fresh mushrooms, red onions, mozzarella and cheddar', null, '{"S":15,"M":19,"L":23,"XL":27}'::jsonb, null, array['veg','new']::text[], true, 23),
  ('panago', 'cheese', 'Cheese', 'pizza', 'Veggie pizzas', 'Organic tomato sauce and loads of mozzarella', null, '{"S":12,"M":15,"L":17.75,"XL":21.5}'::jsonb, null, array['veg']::text[], true, 24),
  ('panago', 'garden-veggie', 'Garden Veggie', 'pizza', 'Veggie pizzas', 'Organic tomato sauce, black olives, sliced fresh mushrooms, pineapple, green peppers, bruschetta tomatoes, red onions and mozzarella', null, '{"S":15.25,"M":18.75,"L":23.25,"XL":28.25}'::jsonb, null, array['veg']::text[], true, 25),
  ('panago', 'mediterranean-veggie', 'Mediterranean Veggie', 'pizza', 'Veggie pizzas', 'Organic tomato sauce, red onions, green peppers, bruschetta tomatoes, kalamata olives, feta, mozzarella and pesto drizzle', null, '{"S":16.25,"M":20.5,"L":25.75,"XL":30.5}'::jsonb, null, array['veg']::text[], true, 26),
  ('panago', 'pesto-garden-medley', 'Pesto Garden Medley', 'pizza', 'Veggie pizzas', 'Caramelized onions, green peppers, bruschetta tomatoes, shredded parmesan, mozzarella and pesto drizzle', null, '{"S":16.5,"M":20.25,"L":25,"XL":29.75}'::jsonb, null, array['veg']::text[], true, 27),
  ('panago', 'meat-free-deluxe', 'Meat-free Deluxe Pepperoni', 'pizza', 'Veggie pizzas', 'Organic tomato sauce, meat-free pepperoni, sliced fresh mushrooms, green peppers and mozzarella', null, '{"S":15,"M":18.25,"L":22.5,"XL":27}'::jsonb, null, array['veg']::text[], true, 28),
  ('panago', 'hot-honey-meat-free', 'Hot Honey Meat-free Pepperoni', 'pizza', 'Veggie pizzas', 'Organic tomato sauce, mozzarella and cheddar, layers of meat-free pepperoni, hot honey drizzle', null, '{"S":15.5,"M":18.75,"L":23,"XL":27}'::jsonb, null, array['veg']::text[], true, 29),
  ('panago', 'hola-elote', 'Hola Elote', 'pizza', 'Veggie pizzas', 'Chipotle cilantro sauce, red onions, green peppers, fire-roasted corn, feta, mozzarella, spicy avocado ranch drizzle, Cajun spice', null, '{"S":15.75,"M":19.75,"L":24.25,"XL":29.25}'::jsonb, null, array['veg']::text[], true, 30),
  ('panago', 'pb-deluxe', 'Plant-based Deluxe Pepperoni', 'pizza', 'Plant-based pizzas', 'Organic tomato sauce, meat-free pepperoni, black olives, green peppers, red onions and Daiya dairy-free cheese', null, '{"S":14.75,"M":18.5,"L":22.75,"XL":26.25}'::jsonb, null, array['plant']::text[], true, 31),
  ('panago', 'pb-spicy-hawaiian', 'Plant-based Spicy Hawaiian', 'pizza', 'Plant-based pizzas', 'Spicy marinara sauce, meat-free pepperoni, pepperoncini, pineapple and Daiya dairy-free cheese', null, '{"S":14.75,"M":18.5,"L":22.75,"XL":26.25}'::jsonb, null, array['plant']::text[], true, 32),
  ('panago', 'pb-mediterranean', 'Plant-based Mediterranean', 'pizza', 'Plant-based pizzas', 'Organic tomato sauce, meat-free pepperoni, kalamata olives, red onions, green peppers, bruschetta tomatoes and Daiya dairy-free cheese', null, '{"S":14.75,"M":18.5,"L":22.75,"XL":26.25}'::jsonb, null, array['plant','deal']::text[], true, 33),
  ('panago', 'pb-summer-bbq', 'Plant-based Summer BBQ', 'pizza', 'Plant-based pizzas', 'Red onions, extra fire-roasted corn, pepperoncini, Daiya dairy-free cheese and BBQ sauce drizzle', null, '{"S":14.5,"M":18,"L":22.25,"XL":26.25}'::jsonb, null, array['plant']::text[], true, 34),
  ('panago', 'pb-spicy-calabrese', 'Plant-based Spicy Calabrese', 'pizza', 'Plant-based pizzas', 'Spicy marinara sauce, meat-free pepperoni, red onions, green peppers, pepperoncini and Daiya dairy-free cheese', null, '{"S":14.5,"M":18,"L":22.25,"XL":26.25}'::jsonb, null, array['plant']::text[], true, 35),
  ('panago', 'ev-pep', 'Everyday Pep', 'pizza', 'Everyday Value pizzas', 'Organic tomato sauce, pepperoni and mozzarella', null, '{"S":10,"M":13.5,"L":18,"XL":20.75}'::jsonb, null, array['value']::text[], true, 36),
  ('panago', 'ev-hawaiian', 'Everyday Hawaiian', 'pizza', 'Everyday Value pizzas', 'Organic tomato sauce, ham, pineapple and mozzarella', null, '{"S":12,"M":15.5,"L":20,"XL":23.75}'::jsonb, null, array['value']::text[], true, 37),
  ('panago', 'ev-meat-trio', 'Everyday Meat Trio', 'pizza', 'Everyday Value pizzas', 'Organic tomato sauce, pepperoni, Genoa salami, spicy Italian sausage and mozzarella', null, '{"S":13,"M":17,"L":22,"XL":26.75}'::jsonb, null, array['value']::text[], true, 38),
  ('panago', 'ev-veggie', 'Everyday Veggie', 'pizza', 'Everyday Value pizzas', 'Organic tomato sauce, red onions, green peppers, sliced fresh mushrooms and mozzarella', null, '{"S":10,"M":13.5,"L":18,"XL":20.75}'::jsonb, null, array['value','veg']::text[], true, 39),
  ('panago', 'ev-chicken-melt', 'Everyday Chicken Melt', 'pizza', 'Everyday Value pizzas', 'Spicy marinara sauce, grilled chicken, caramelized onions, sliced fresh mushrooms and mozzarella', null, '{"S":13.5,"M":17.5,"L":23.5,"XL":28}'::jsonb, null, array['value']::text[], true, 40),
  ('panago', 'garlic-cheezy-bread', 'Garlic Cheezy Bread', 'breads', 'Breads', 'Fresh baked dough, garlic spread, mozzarella and cheddar. Includes dip', 7.25, null, '8 pc', array['veg']::text[], true, 41),
  ('panago', 'super-cheezy-bread', 'Super Cheezy Bread', 'breads', 'Breads', 'Fresh baked dough, cheezy cheddar sauce, mozzarella and cheddar. Includes dip', 7.25, null, '8 pc', array['veg']::text[], true, 42),
  ('panago', 'pb-cheezy-bread', 'Plant-based Cheezy Bread', 'breads', 'Breads', 'Fresh baked dough, vegan garlic spread and Daiya dairy-free cheese. Includes dip', 7.25, null, '8 pc', array['plant']::text[], true, 43),
  ('panago', 'wings-8', 'Wings, 8 pc', 'wings', 'Wings & bites', 'Hot & Spicy, Honey Garlic, Deliciously Simple or Salt & Pepper', 11.95, null, '8 pc', array[]::text[], true, 44),
  ('panago', 'wings-16', 'Wings, 16 pc', 'wings', 'Wings & bites', 'Hot & Spicy, Honey Garlic, Deliciously Simple or Salt & Pepper', 21.75, null, '16 pc', array[]::text[], true, 45),
  ('panago', 'chicken-bites', 'Chicken Bites', 'wings', 'Wings & bites', 'Includes dip', 11.5, null, '10 pc', array[]::text[], true, 46),
  ('panago', 'hot-honey-bites', 'Hot Honey Chicken Bites', 'wings', 'Wings & bites', 'Includes dip', 12, null, '10 pc', array[]::text[], true, 47),
  ('panago', 'bbq-bites', 'BBQ Chicken Bites', 'wings', 'Wings & bites', 'Includes dip', 12, null, '10 pc', array[]::text[], true, 48),
  ('panago', 'caesar', 'Caesar Salad', 'salads', 'Salads', 'Romaine, croutons, shredded parmesan, Caesar dressing', 8.75, null, 'entrée', array['veg']::text[], true, 49),
  ('panago', 'mediterranean-salad', 'Mediterranean Salad', 'salads', 'Salads', 'Romaine, red onions, green peppers, diced tomatoes, kalamata olives, feta', 9.25, null, 'entrée', array['veg']::text[], true, 50),
  ('panago', 'garden-salad', 'Garden Salad', 'salads', 'Salads', 'Romaine, green peppers, diced tomatoes, red onions, croutons, mozzarella and cheddar', 9.25, null, 'entrée', array['veg']::text[], true, 51),
  ('panago', 'southwest-salad', 'Southwest Salad', 'salads', 'Salads', 'Romaine, fire-roasted corn, diced tomatoes, pepperoncini, black olives, green peppers, feta', 9.25, null, 'entrée', array['veg']::text[], true, 52),
  ('panago', 'cajun-chicken-salad', 'Cajun Chicken Southwest Salad', 'salads', 'Salads', 'Cajun chicken, romaine, fire-roasted corn, diced tomatoes, pepperoncini, black olives, green peppers, feta', 12, null, 'entrée', array[]::text[], true, 53),
  ('panago', 'churro-8', 'Churro Bites, 8 pc', 'desserts', 'Desserts', 'Bite-sized churros in cinnamon sugar with sweet caramel filling', 6.85, null, '8 pc', array['veg']::text[], true, 54),
  ('panago', 'churro-16', 'Churro Bites, 16 pc', 'desserts', 'Desserts', 'Bite-sized churros in cinnamon sugar with sweet caramel filling', 13.5, null, '16 pc', array['veg']::text[], true, 55),
  ('panago', 'lava-cake', 'S''mores Lava Cake', 'desserts', 'Desserts', 'Molten chocolate centre, graham cracker crumbs, toasted marshmallows', 8.5, null, 'each', array['veg']::text[], true, 56),
  ('panago', 'tiramisu', 'Tiramisu', 'desserts', 'Desserts', 'Espresso-soaked ladyfingers, mascarpone cream, cocoa', 8.5, null, 'each', array['veg']::text[], true, 57),
  ('panago', 'dip', 'Dip', 'dips', 'Dips', 'Jalapeño Ranch, Chipotle Cilantro, Italian Tomato, Classic Caesar, Garlic, Cheezy Cheddar, Blue Cheese, BBQ and more', 1.3, null, '44 ml', array[]::text[], true, 58),
  ('panago', 'pop', '591 ml pop', 'drinks', 'Drinks', 'Prize item: pop is not on the printed menu', null, null, '591 ml', array[]::text[], false, 900),
  ('wetzels', 'original', 'Original', 'pretzels', 'Pretzels', 'Hand-rolled, baked fresh, butter and salt', 6.49, null, null, array[]::text[], true, 0),
  ('wetzels', 'sinful-cinnamon', 'Sinful Cinnamon', 'pretzels', 'Pretzels', 'Dipped in butter, rolled in cinnamon sugar', 7.49, null, null, array[]::text[], true, 1),
  ('wetzels', 'wetzel-bitz', 'Wetzel Bitz', 'bitz', 'Bitz', 'Bite-sized pretzel pieces, butter and salt', 8.25, null, null, array[]::text[], true, 2),
  ('wetzels', 'cheesy-dog-bites', 'Cheesy Dog Bites', 'dogs', 'Dogs', 'Mini cheese-filled dogs wrapped in pretzel dough', 11.45, null, null, array[]::text[], true, 3),
  ('wetzels', 'fresh-lemonade', 'Fresh Lemonade', 'lemonade', 'Lemonades', 'Made fresh in store', 5.59, null, null, array[]::text[], true, 4),
  ('wetzels', 'pink-lemonade', 'Pink Lemonade', 'lemonade', 'Lemonades', 'Made fresh in store', 5.59, null, null, array[]::text[], true, 5),
  ('wetzels', 'dip', 'Dip', 'dips', 'Dips', 'Cheese, caramel, chocolate hazelnut and more. Prize item until the store confirms its price', null, null, null, array[]::text[], false, 900)
on conflict (client_id, id) do update set name = excluded.name, cat = excluded.cat, grp = excluded.grp, descr = excluded.descr, price = excluded.price,
  sizes = excluded.sizes, unit = excluded.unit, tags = excluded.tags, orderable = excluded.orderable, sort = excluded.sort;
insert into public.client_onboarding (client_id, step_id, note) values
  ('wetzels', 'order-flow', 'Pickup only for now: delivery is off for the Eaton Centre store until a courier is agreed (stores.delivery).'),
  ('panago', 'order-flow', 'Delivery on: Platterly orders at walk-in prices, no delivery fee. Confirm Panago drivers take Platterly orders.')
on conflict do nothing;
