-- Crumb & Ember — schema + seed data
-- Applied automatically on first boot of the postgres container
-- (docker-entrypoint-initdb.d) and via the bakery-db-init ConfigMap in k8s.

CREATE TABLE IF NOT EXISTS products (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  category    TEXT NOT NULL,
  price       NUMERIC(8,2) NOT NULL,
  description TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS profiles (
  id      TEXT PRIMARY KEY,
  name    TEXT NOT NULL,
  email   TEXT UNIQUE NOT NULL,
  address TEXT NOT NULL DEFAULT '',
  dietary JSONB NOT NULL DEFAULT '[]'::jsonb
);

CREATE TABLE IF NOT EXISTS accounts (
  email         TEXT PRIMARY KEY,
  user_id       TEXT UNIQUE NOT NULL,
  name          TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE SEQUENCE IF NOT EXISTS order_seq START 1001;

CREATE TABLE IF NOT EXISTS orders (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL,
  items       JSONB NOT NULL,
  pickup_time TEXT,
  status      TEXT NOT NULL DEFAULT 'received',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_user   ON orders (user_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders (status);
CREATE INDEX IF NOT EXISTS idx_products_cat  ON products (category);

CREATE TABLE IF NOT EXISTS payments (
  id                  TEXT PRIMARY KEY,          -- razorpay order_id or mock pay_ id
  provider            TEXT NOT NULL DEFAULT 'mock',
  order_id            TEXT NOT NULL,
  razorpay_payment_id TEXT,
  amount              NUMERIC(10,2) NOT NULL,
  currency            TEXT NOT NULL DEFAULT 'INR',
  method              TEXT,
  status              TEXT NOT NULL DEFAULT 'created',
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_payments_order  ON payments (order_id);
CREATE INDEX IF NOT EXISTS idx_payments_status ON payments (status);

-- ---------------------------------------------------------------- seed data
INSERT INTO products (id, name, category, price, description) VALUES
  ('p-1',  'Levain Country Loaf',   'bread',        8.50, '48-hour fermented sourdough, dark bake.'),
  ('p-2',  'Seeded Rye',            'bread',        7.00, 'Dense Danish-style rye with sunflower and flax.'),
  ('p-3',  'Butter Croissant',      'viennoiserie', 4.25, '27 layers of cultured butter.'),
  ('p-4',  'Cardamom Knot',         'viennoiserie', 4.75, 'Swedish-style bun, freshly ground cardamom.'),
  ('p-5',  'Pain au Chocolat',      'viennoiserie', 4.50, 'Two batons of 70% chocolate.'),
  ('p-6',  'Morning Bun',           'viennoiserie', 4.50, 'Croissant dough, orange zest, muscovado.'),
  ('p-7',  'Pistachio Financier',   'patisserie',   3.75, 'Brown-butter almond cake, Sicilian pistachio.'),
  ('p-8',  'Sour Cherry Galette',   'patisserie',   6.25, 'Rye crust, whole sour cherries.'),
  ('p-9',  'Canele',                'patisserie',   3.50, 'Rum and vanilla, caramelised copper-mould crust.'),
  ('p-10', 'Baguette Tradition',    'bread',        3.90, 'Slow-fermented, thin crackling crust.'),
  ('p-11', 'Focaccia al Rosmarino', 'bread',        5.50, 'Olive oil crumb, flaky salt, rosemary.'),
  ('p-12', 'Espresso Walnut Babka', 'patisserie',   9.00, 'Twisted brioche, espresso frangipane.')
ON CONFLICT (id) DO NOTHING;

INSERT INTO profiles (id, name, email, address, dietary) VALUES
  ('u-1', 'Amelie Fournier', 'amelie@crumbandember.dev', '12 Rue du Levain', '["nut-free"]'),
  ('u-2', 'Tomas Iversen',   'tomas@example.com',        '8 Rye Lane',        '[]')
ON CONFLICT (id) DO NOTHING;

-- The demo account (amelie / baguette) is seeded by auth-service on startup
-- so the scrypt hash is produced by the same code path that verifies it.
