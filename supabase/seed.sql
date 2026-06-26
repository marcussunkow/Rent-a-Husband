-- Rent a Husband — seed data (brief §11). Loaded by `supabase db reset`.

-- Job categories (brief §5).
insert into categories (slug, name, sort_order) values
  ('plumbing',   'Plumbing',    10),
  ('electrical', 'Electrical',  20),
  ('carpentry',  'Carpentry',   30),
  ('painting',   'Painting',    40),
  ('ac',         'AC & Cooling', 50),
  ('appliance',  'Appliance Repair', 60),
  ('masonry',    'Masonry & Tiling', 70),
  ('general',    'General Handyman', 80)
on conflict (slug) do nothing;

-- Single launch zone (brief §2.4 — density beats coverage).
-- TODO: set the real launch town/cluster (brief §13.6).
insert into service_zones (slug, name, active) values
  ('launch-zone', 'Launch Zone (set me)', true)
on conflict (slug) do nothing;
