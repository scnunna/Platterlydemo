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
