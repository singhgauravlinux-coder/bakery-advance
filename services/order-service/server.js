'use strict';
const express = require('express');
const pino = require('pino');
const pinoHttp = require('pino-http');
const { Pool } = require('pg');

const SERVICE_NAME = process.env.SERVICE_NAME || 'order-service';
const PORT = Number(process.env.PORT || 3000);
const DATABASE_URL = process.env.DATABASE_URL || '';

// All logs are structured JSON on stdout (12-factor), ready for
// Fluent Bit / Loki / ELK collection from the container runtime.
const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  timestamp: pino.stdTimeFunctions.isoTime,
  base: { service: SERVICE_NAME, version: process.env.SERVICE_VERSION || '1.0.0' },
  formatters: { level: (label) => ({ level: label }) }
});

// --- Storage: PostgreSQL when DATABASE_URL is set, in-memory otherwise ---
const pool = DATABASE_URL ? new Pool({ connectionString: DATABASE_URL, max: 10 }) : null;
if (pool) pool.on('error', (err) => logger.error({ event: 'pg_pool_error', message: err.message }, 'postgres pool error'));

const memory = { orders: new Map(), seq: 1000 };

const store = pool ? {
  mode: 'postgres',
  async create(userId, items, pickupTime) {
    const { rows } = await pool.query(
      `INSERT INTO orders (id, user_id, items, pickup_time)
       VALUES ('ord-' || nextval('order_seq'), $1, $2::jsonb, $3)
       RETURNING id, user_id AS "userId", items, pickup_time AS "pickupTime", status, created_at AS "createdAt"`,
      [userId, JSON.stringify(items), pickupTime || null]);
    return rows[0];
  },
  async list() {
    const { rows } = await pool.query(
      `SELECT id, user_id AS "userId", items, pickup_time AS "pickupTime", status, created_at AS "createdAt"
       FROM orders ORDER BY created_at DESC LIMIT 500`);
    return rows;
  },
  async get(id) {
    const { rows } = await pool.query(
      `SELECT id, user_id AS "userId", items, pickup_time AS "pickupTime", status, created_at AS "createdAt"
       FROM orders WHERE id = $1`, [id]);
    return rows[0] || null;
  },
  async setStatus(id, status) {
    const { rows } = await pool.query(
      `UPDATE orders SET status = COALESCE($2, status) WHERE id = $1
       RETURNING id, user_id AS "userId", items, pickup_time AS "pickupTime", status, created_at AS "createdAt"`,
      [id, status || null]);
    return rows[0] || null;
  },
  async ping() { await pool.query('SELECT 1'); }
} : {
  mode: 'memory',
  async create(userId, items, pickupTime) {
    const id = 'ord-' + (++memory.seq);
    const order = { id, userId, items, pickupTime: pickupTime || null, status: 'received', createdAt: new Date().toISOString() };
    memory.orders.set(id, order);
    return order;
  },
  async list() { return [...memory.orders.values()]; },
  async get(id) { return memory.orders.get(id) || null; },
  async setStatus(id, status) {
    const order = memory.orders.get(id);
    if (!order) return null;
    if (status) order.status = status;
    return order;
  },
  async ping() {}
};

const app = express();
app.use(express.json());
app.use(pinoHttp({
  logger,
  customProps: (req) => ({ requestId: req.headers['x-request-id'] || undefined })
}));

// --- Kubernetes probes -------------------------------------------------
app.get('/health', (req, res) => res.json({ status: 'ok', service: SERVICE_NAME }));
app.get('/ready', async (req, res) => {
  try {
    await store.ping();
    res.json({ ready: true, service: SERVICE_NAME, storage: store.mode });
  } catch (err) {
    req.log.warn({ event: 'readiness_failed', message: err.message }, 'database unreachable');
    res.status(503).json({ ready: false, service: SERVICE_NAME, storage: store.mode });
  }
});

// --- Order lifecycle ---
app.post('/orders', async (req, res, next) => {
  try {
    const { userId, items, pickupTime } = req.body || {};
    if (!userId || !Array.isArray(items) || items.length === 0)
      return res.status(400).json({ error: 'userId and a non-empty items array are required' });
    const order = await store.create(userId, items, pickupTime);
    req.log.info({ event: 'order_created', orderId: order.id, userId, itemCount: items.length }, 'order received');
    res.status(201).json(order);
  } catch (err) { next(err); }
});

app.get('/orders', async (req, res, next) => {
  try { res.json(await store.list()); } catch (err) { next(err); }
});

app.get('/orders/:id', async (req, res, next) => {
  try {
    const order = await store.get(req.params.id);
    if (!order) return res.status(404).json({ error: 'Order not found' });
    res.json(order);
  } catch (err) { next(err); }
});

app.put('/orders/:id/status', async (req, res, next) => {
  try {
    const order = await store.setStatus(req.params.id, req.body && req.body.status);
    if (!order) return res.status(404).json({ error: 'Order not found' });
    req.log.info({ event: 'order_status_changed', orderId: order.id, status: order.status }, 'order status updated');
    res.json(order);
  } catch (err) { next(err); }
});

// --- 404 + error handling ----------------------------------------------
app.use((req, res) => res.status(404).json({ error: 'Route not found' }));
app.use((err, req, res, next) => {
  req.log.error({ event: 'unhandled_error', message: err.message }, 'request failed');
  res.status(500).json({ error: 'Internal server error' });
});

const server = app.listen(PORT, () =>
  logger.info({ event: 'service_started', port: PORT, storage: store.mode }, `${SERVICE_NAME} listening`));

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    logger.info({ event: 'shutdown', signal }, 'shutting down gracefully');
    server.close(async () => { if (pool) await pool.end().catch(() => {}); process.exit(0); });
  });
}
