'use strict';
const express = require('express');
const pino = require('pino');
const pinoHttp = require('pino-http');

const SERVICE_NAME = process.env.SERVICE_NAME || 'invoice-service';
const PORT = Number(process.env.PORT || 3000);

// All logs are structured JSON on stdout (12-factor), ready for
// Fluent Bit / Loki / ELK collection from the container runtime.
const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  timestamp: pino.stdTimeFunctions.isoTime,
  base: { service: SERVICE_NAME, version: process.env.SERVICE_VERSION || '1.0.0' },
  formatters: { level: (label) => ({ level: label }) }
});

const app = express();
app.use(express.json());
app.use(pinoHttp({
  logger,
  customProps: (req) => ({ requestId: req.headers['x-request-id'] || undefined })
}));

// --- Kubernetes probes -------------------------------------------------
app.get('/health', (req, res) => res.json({ status: 'ok', service: SERVICE_NAME }));
app.get('/ready', (req, res) => res.json({ ready: true, service: SERVICE_NAME }));

// --- PDF-less invoices for wholesale accounts ---
const invoices = new Map();
let n = 5000;

app.post('/invoices', (req, res) => {
  const { orderId, amount, customer } = req.body || {};
  if (!orderId || !amount) return res.status(400).json({ error: 'orderId and amount are required' });
  const id = 'inv-' + (++n);
  const invoice = { id, orderId, amount, customer: customer || 'walk-in', issuedAt: new Date().toISOString(), dueInDays: 14 };
  invoices.set(id, invoice);
  req.log.info({ event: 'invoice_issued', invoiceId: id, orderId, amount }, 'invoice created');
  res.status(201).json(invoice);
});

app.get('/invoices/:id', (req, res) => {
  const invoice = invoices.get(req.params.id);
  if (!invoice) return res.status(404).json({ error: 'Invoice not found' });
  res.json(invoice);
});

// --- 404 + error handling ----------------------------------------------
app.use((req, res) => res.status(404).json({ error: 'Route not found' }));
app.use((err, req, res, next) => {
  req.log.error({ event: 'unhandled_error', message: err.message }, 'request failed');
  res.status(500).json({ error: 'Internal server error' });
});

const server = app.listen(PORT, () => logger.info({ event: 'service_started', port: PORT }, `${SERVICE_NAME} listening`));

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    logger.info({ event: 'shutdown', signal }, 'shutting down gracefully');
    server.close(() => process.exit(0));
  });
}
