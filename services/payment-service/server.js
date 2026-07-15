'use strict';
const crypto = require('crypto');
const express = require('express');
const pino = require('pino');
const pinoHttp = require('pino-http');
const { Pool } = require('pg');

const SERVICE_NAME = process.env.SERVICE_NAME || 'payment-service';
const PORT = Number(process.env.PORT || 3000);
const DATABASE_URL = process.env.DATABASE_URL || '';

// --- Razorpay configuration --------------------------------------------
// When RAZORPAY_KEY_ID / RAZORPAY_KEY_SECRET are set the service talks to
// the real Razorpay API. Without them it falls back to the mock provider so
// local dev / CI keep working with zero credentials.
const RAZORPAY_KEY_ID = process.env.RAZORPAY_KEY_ID || '';
const RAZORPAY_KEY_SECRET = process.env.RAZORPAY_KEY_SECRET || '';
const RAZORPAY_WEBHOOK_SECRET = process.env.RAZORPAY_WEBHOOK_SECRET || '';
const RAZORPAY_ENABLED = Boolean(RAZORPAY_KEY_ID && RAZORPAY_KEY_SECRET);

let razorpay = null;
if (RAZORPAY_ENABLED) {
  const Razorpay = require('razorpay');
  razorpay = new Razorpay({ key_id: RAZORPAY_KEY_ID, key_secret: RAZORPAY_KEY_SECRET });
}

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

// Self-migrating: init.sql only runs on the FIRST postgres boot, so existing
// clusters would miss the payments table. This is idempotent and cheap.
const MIGRATION = `
  CREATE TABLE IF NOT EXISTS payments (
    id                  TEXT PRIMARY KEY,
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
`;

const ROW = `id, provider, order_id AS "orderId", razorpay_payment_id AS "razorpayPaymentId",
             amount, currency, method, status, created_at AS "createdAt", updated_at AS "updatedAt"`;

const memory = new Map();

const store = pool ? {
  mode: 'postgres',
  async init() { await pool.query(MIGRATION); },
  async create(p) {
    const { rows } = await pool.query(
      `INSERT INTO payments (id, provider, order_id, amount, currency, method, status)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       RETURNING ${ROW}`,
      [p.id, p.provider, p.orderId, p.amount, p.currency || 'INR', p.method || null, p.status]);
    return rows[0];
  },
  async get(id) {
    const { rows } = await pool.query(`SELECT ${ROW} FROM payments WHERE id = $1`, [id]);
    return rows[0] || null;
  },
  async byOrder(orderId) {
    const { rows } = await pool.query(
      `SELECT ${ROW} FROM payments WHERE order_id = $1 ORDER BY created_at DESC`, [orderId]);
    return rows;
  },
  async update(id, { status, razorpayPaymentId }) {
    const { rows } = await pool.query(
      `UPDATE payments
       SET status = COALESCE($2, status),
           razorpay_payment_id = COALESCE($3, razorpay_payment_id),
           updated_at = now()
       WHERE id = $1
       RETURNING ${ROW}`,
      [id, status || null, razorpayPaymentId || null]);
    return rows[0] || null;
  },
  async ping() { await pool.query('SELECT 1'); }
} : {
  mode: 'memory',
  async init() {},
  async create(p) {
    const record = { ...p, currency: p.currency || 'INR', createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
    memory.set(p.id, record);
    return record;
  },
  async get(id) { return memory.get(id) || null; },
  async byOrder(orderId) { return [...memory.values()].filter(p => p.orderId === orderId); },
  async update(id, { status, razorpayPaymentId }) {
    const record = memory.get(id);
    if (!record) return null;
    if (status) record.status = status;
    if (razorpayPaymentId) record.razorpayPaymentId = razorpayPaymentId;
    record.updatedAt = new Date().toISOString();
    return record;
  },
  async ping() {}
};

const app = express();
// Keep the raw body around: Razorpay webhook signatures are computed over
// the exact bytes received, so re-serialising parsed JSON would break HMAC.
app.use(express.json({
  verify: (req, res, buf) => { req.rawBody = buf; }
}));
app.use(pinoHttp({
  logger,
  customProps: (req) => ({ requestId: req.headers['x-request-id'] || undefined })
}));

// --- Kubernetes probes -------------------------------------------------
app.get('/health', (req, res) => res.json({ status: 'ok', service: SERVICE_NAME, provider: RAZORPAY_ENABLED ? 'razorpay' : 'mock', storage: store.mode }));
app.get('/ready', async (req, res) => {
  try {
    await store.ping();
    res.json({ ready: true, service: SERVICE_NAME, storage: store.mode });
  } catch (err) {
    req.log.error({ event: 'readiness_failed', message: err.message }, 'database unreachable');
    res.status(503).json({ ready: false, error: 'database unreachable' });
  }
});

const timingSafeEqualHex = (a, b) => {
  const bufA = Buffer.from(a, 'utf8');
  const bufB = Buffer.from(b, 'utf8');
  return bufA.length === bufB.length && crypto.timingSafeEqual(bufA, bufB);
};

// --- Razorpay: create an order ------------------------------------------
// The frontend calls this, then opens Razorpay Checkout with the returned
// razorpayOrderId + keyId. Amount is accepted in rupees and converted to
// paise (Razorpay's smallest currency unit). The transaction is persisted
// immediately with status "created".
app.post('/payments/razorpay/order', async (req, res) => {
  if (!RAZORPAY_ENABLED) {
    return res.status(503).json({ error: 'Razorpay is not configured (set RAZORPAY_KEY_ID / RAZORPAY_KEY_SECRET)' });
  }
  const { orderId, amount, currency } = req.body || {};
  if (!orderId || !amount || Number(amount) <= 0) {
    return res.status(400).json({ error: 'orderId and a positive amount are required' });
  }
  try {
    const rzpOrder = await razorpay.orders.create({
      amount: Math.round(Number(amount) * 100), // rupees -> paise
      currency: currency || 'INR',
      receipt: String(orderId),
      notes: { bakeryOrderId: String(orderId) }
    });
    const record = await store.create({
      id: rzpOrder.id,
      provider: 'razorpay',
      orderId: String(orderId),
      amount: Number(amount),
      currency: rzpOrder.currency,
      status: 'created'
    });
    req.log.info({ event: 'razorpay_order_created', razorpayOrderId: rzpOrder.id, orderId, amount }, 'razorpay order created');
    res.status(201).json({ ...record, razorpayOrderId: rzpOrder.id, keyId: RAZORPAY_KEY_ID });
  } catch (err) {
    req.log.error({ event: 'razorpay_order_failed', orderId, message: err.message }, 'razorpay order creation failed');
    res.status(502).json({ error: 'Failed to create Razorpay order' });
  }
});

// --- Razorpay: verify a checkout payment ---------------------------------
// Called by the frontend after Checkout succeeds. Verifies the signature
// Razorpay returns (HMAC-SHA256 of "order_id|payment_id" with the key secret)
// and marks the stored transaction as paid.
app.post('/payments/razorpay/verify', async (req, res) => {
  if (!RAZORPAY_ENABLED) {
    return res.status(503).json({ error: 'Razorpay is not configured' });
  }
  const { razorpay_order_id: rzpOrderId, razorpay_payment_id: rzpPaymentId, razorpay_signature: signature } = req.body || {};
  if (!rzpOrderId || !rzpPaymentId || !signature) {
    return res.status(400).json({ error: 'razorpay_order_id, razorpay_payment_id and razorpay_signature are required' });
  }
  const expected = crypto
    .createHmac('sha256', RAZORPAY_KEY_SECRET)
    .update(`${rzpOrderId}|${rzpPaymentId}`)
    .digest('hex');
  if (!timingSafeEqualHex(expected, signature)) {
    req.log.warn({ event: 'razorpay_signature_invalid', razorpayOrderId: rzpOrderId }, 'signature verification failed');
    return res.status(400).json({ verified: false, error: 'Invalid payment signature' });
  }
  try {
    const record = await store.update(rzpOrderId, { status: 'paid', razorpayPaymentId: rzpPaymentId });
    req.log.info({ event: 'razorpay_payment_verified', razorpayOrderId: rzpOrderId, razorpayPaymentId: rzpPaymentId }, 'payment verified');
    res.json({ verified: true, razorpayOrderId: rzpOrderId, razorpayPaymentId: rzpPaymentId, status: 'paid', payment: record });
  } catch (err) {
    req.log.error({ event: 'payment_update_failed', message: err.message }, 'failed to persist verification');
    res.status(500).json({ error: 'Payment verified but could not be persisted' });
  }
});

// --- Razorpay: webhook ----------------------------------------------------
// Configure in the Razorpay dashboard to POST here (via the ingress:
// /api/payments/razorpay/webhook). Signature is HMAC-SHA256 of the raw body
// with the webhook secret. Captured/failed events update the stored row.
app.post('/payments/razorpay/webhook', async (req, res) => {
  if (!RAZORPAY_WEBHOOK_SECRET) {
    return res.status(503).json({ error: 'Webhook secret not configured (set RAZORPAY_WEBHOOK_SECRET)' });
  }
  const signature = req.headers['x-razorpay-signature'];
  if (!signature || !req.rawBody) {
    return res.status(400).json({ error: 'Missing signature or body' });
  }
  const expected = crypto.createHmac('sha256', RAZORPAY_WEBHOOK_SECRET).update(req.rawBody).digest('hex');
  if (!timingSafeEqualHex(expected, String(signature))) {
    req.log.warn({ event: 'razorpay_webhook_invalid' }, 'webhook signature verification failed');
    return res.status(400).json({ error: 'Invalid webhook signature' });
  }
  const eventType = req.body && req.body.event;
  const paymentEntity = req.body && req.body.payload && req.body.payload.payment && req.body.payload.payment.entity;
  try {
    if (paymentEntity && paymentEntity.order_id) {
      const status = eventType === 'payment.captured' ? 'paid'
        : eventType === 'payment.failed' ? 'failed'
        : null;
      if (status) await store.update(paymentEntity.order_id, { status, razorpayPaymentId: paymentEntity.id });
    }
    req.log.info({ event: 'razorpay_webhook', webhookEvent: eventType }, 'webhook processed');
    res.json({ received: true });
  } catch (err) {
    req.log.error({ event: 'webhook_persist_failed', message: err.message }, 'failed to persist webhook update');
    // 500 so Razorpay retries the delivery.
    res.status(500).json({ error: 'Failed to persist webhook event' });
  }
});

// --- Mock provider (kept for local dev without Razorpay keys) -----------
app.post('/payments', async (req, res) => {
  const { orderId, amount, method } = req.body || {};
  if (!orderId || !amount) return res.status(400).json({ error: 'orderId and amount are required' });
  try {
    const payment = await store.create({
      id: 'pay_' + Math.random().toString(36).slice(2, 10),
      provider: 'mock',
      orderId: String(orderId),
      amount: Number(amount),
      method: method || 'card',
      status: 'succeeded'
    });
    req.log.info({ event: 'payment_captured', paymentId: payment.id, orderId, amount }, 'payment processed');
    res.status(201).json(payment);
  } catch (err) {
    req.log.error({ event: 'payment_create_failed', message: err.message }, 'failed to persist payment');
    res.status(500).json({ error: 'Failed to store payment' });
  }
});

// Transactions for a bakery order (must come before /payments/:id).
app.get('/payments/order/:orderId', async (req, res) => {
  const rows = await store.byOrder(req.params.orderId);
  res.json(rows);
});

app.get('/payments/:id', async (req, res) => {
  const payment = await store.get(req.params.id);
  if (!payment) return res.status(404).json({ error: 'Payment not found' });
  res.json(payment);
});

// --- 404 + error handling ----------------------------------------------
app.use((req, res) => res.status(404).json({ error: 'Route not found' }));
app.use((err, req, res, next) => {
  req.log.error({ event: 'unhandled_error', message: err.message }, 'request failed');
  res.status(500).json({ error: 'Internal server error' });
});

let server;
store.init()
  .then(() => {
    server = app.listen(PORT, () => logger.info({ event: 'service_started', port: PORT, razorpay: RAZORPAY_ENABLED, storage: store.mode }, `${SERVICE_NAME} listening`));
  })
  .catch((err) => {
    logger.error({ event: 'startup_failed', message: err.message }, 'could not initialise storage');
    process.exit(1);
  });

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    logger.info({ event: 'shutdown', signal }, 'shutting down gracefully');
    if (server) server.close(() => process.exit(0)); else process.exit(0);
  });
}
