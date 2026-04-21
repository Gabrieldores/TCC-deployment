const express = require('express');
const client = require('prom-client');
const app = express();
const PORT = process.env.PORT || 3000;

// ── Configuração de métricas Prometheus ───────────────────────────────────────
const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total de requisições HTTP',
  labelNames: ['method', 'path', 'status']
});

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_ms',
  help: 'Duração das requisições HTTP em milissegundos',
  labelNames: ['method', 'path', 'status'],
  buckets: [10, 50, 100, 200, 500, 1000, 2000]
});

const errorsTotal = new client.Counter({
  name: 'app_errors_total',
  help: 'Total de erros simulados pela aplicação',
  labelNames: ['path', 'version']
});

const activeRequests = new client.Gauge({
  name: 'app_active_requests',
  help: 'Requisições ativas no momento'
});

register.registerMetric(httpRequestsTotal);
register.registerMetric(httpRequestDuration);
register.registerMetric(errorsTotal);
register.registerMetric(activeRequests);

// ── Variáveis de ambiente ─────────────────────────────────────────────────────
const APP_VERSION = process.env.APP_VERSION || 'v1.0.0';
const APP_COLOR   = process.env.APP_COLOR   || 'blue';
const ERROR_RATE  = parseFloat(process.env.ERROR_RATE  || '0');
const SLOW_MS     = parseInt(process.env.SLOW_MS       || '0');

// ── Middleware de observabilidade ─────────────────────────────────────────────
app.use((req, res, next) => {
  const start = Date.now();
  activeRequests.inc();
  res.on('finish', () => {
    const duration = Date.now() - start;
    activeRequests.dec();
    httpRequestsTotal.inc({
      method: req.method,
      path: req.path,
      status: res.statusCode
    });
    httpRequestDuration.observe(
      { method: req.method, path: req.path, status: res.statusCode },
      duration
    );
  });
  next();
});

// ── Endpoints base ────────────────────────────────────────────────────────────
app.get('/', (req, res) => {
  res.json({
    app:     'TCC API',
    version: APP_VERSION,
    color:   APP_COLOR,
    status:  'running'
  });
});

app.get('/info', (req, res) => {
  res.json({
    version:    APP_VERSION,
    color:      APP_COLOR,
    error_rate: ERROR_RATE,
    slow_ms:    SLOW_MS,
    message:    'Rodando no cluster K3s da Contabo!'
  });
});

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy', version: APP_VERSION });
});

app.get('/ready', (req, res) => {
  res.status(200).json({ ready: true, version: APP_VERSION });
});

// ── Endpoint de métricas (Prometheus) ────────────────────────────────────────
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// ── Endpoints de stress ───────────────────────────────────────────────────────

// Simula latência configurável — usado pelo k6 e NetworkChaos
app.get('/slow', (req, res) => {
  const delay = SLOW_MS || parseInt(req.query.ms || '500');
  setTimeout(() => {
    res.json({
      version:  APP_VERSION,
      delay_ms: delay,
      status:   'ok'
    });
  }, delay);
});

// Simula falhas aleatórias — usado pelo AnalysisTemplate do Argo Rollouts
app.get('/unstable', (req, res) => {
  if (Math.random() < ERROR_RATE) {
    errorsTotal.inc({ path: '/unstable', version: APP_VERSION });
    return res.status(500).json({
      error:   'Simulated failure',
      version: APP_VERSION,
      rate:    ERROR_RATE
    });
  }
  res.json({ version: APP_VERSION, status: 'ok' });
});

// Simula carga de CPU — usado pelo StressChaos
app.get('/stress/cpu', (req, res) => {
  const duration = parseInt(req.query.ms || '500');
  const start = Date.now();
  while (Date.now() - start < duration) {
    Math.sqrt(Math.random() * 99999);
  }
  res.json({ version: APP_VERSION, duration_ms: duration, status: 'done' });
});

// Simula alocação de memória — usado pelo StressChaos
app.get('/stress/memory', (req, res) => {
  const mb = parseInt(req.query.mb || '10');
  const data = Buffer.alloc(mb * 1024 * 1024);
  setTimeout(() => {
    data.fill(0);
    res.json({ version: APP_VERSION, allocated_mb: mb, status: 'done' });
  }, 200);
});

// Simula múltiplas chamadas encadeadas — usado pelo k6
app.get('/stress/chain', async (req, res) => {
  const steps = parseInt(req.query.steps || '5');
  const results = [];
  for (let i = 0; i < steps; i++) {
    await new Promise(r => setTimeout(r, SLOW_MS || 50));
    results.push({ step: i + 1, ok: true });
  }
  res.json({ version: APP_VERSION, steps: results, status: 'done' });
});

// ── Endpoints de dados simulados ──────────────────────────────────────────────
const products = [
  { id: '1', name: 'Notebook Pro',    price: 4999.99, stock: 10 },
  { id: '2', name: 'Monitor 4K',      price: 2199.99, stock: 25 },
  { id: '3', name: 'Teclado Mecânico',price:  599.99, stock: 50 },
  { id: '4', name: 'Mouse Gamer',     price:  299.99, stock: 80 },
];

app.get('/products', (req, res) => {
  if (Math.random() < ERROR_RATE) {
    errorsTotal.inc({ path: '/products', version: APP_VERSION });
    return res.status(500).json({ error: 'Database unavailable', version: APP_VERSION });
  }
  setTimeout(() => {
    res.json({ version: APP_VERSION, count: products.length, data: products });
  }, SLOW_MS);
});

app.get('/products/:id', (req, res) => {
  const product = products.find(p => p.id === req.params.id);
  if (!product) return res.status(404).json({ error: 'Not found', version: APP_VERSION });
  setTimeout(() => {
    res.json({ version: APP_VERSION, data: product });
  }, SLOW_MS);
});

// ── Start ─────────────────────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`[${APP_VERSION}] API ativa na porta ${PORT}`);
  console.log(`[${APP_VERSION}] Color: ${APP_COLOR} | Error rate: ${ERROR_RATE} | Slow: ${SLOW_MS}ms`);
});