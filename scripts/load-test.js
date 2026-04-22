import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// ── Métricas customizadas ─────────────────────────────────────────────────────
const errorCount    = new Counter('tcc_errors_total');
const successRate   = new Rate('tcc_success_rate');
const responseTrend = new Trend('tcc_response_time', true);

// ── Configuração do teste ─────────────────────────────────────────────────────
export const options = {
  stages: [
    { duration: '30s', target: 10  }, // ramp-up
    { duration: '60s', target: 50  }, // estado estável
    { duration: '60s', target: 100 }, // carga máxima
    { duration: '30s', target: 0   }, // ramp-down
  ],
  thresholds: {
    'tcc_success_rate':              ['rate>0.95'],
    'tcc_response_time':             ['p(95)<1000', 'p(99)<2000'],
    'http_req_duration':             ['p(95)<1000'],
    'http_req_failed':               ['rate<0.05'],
  },
};

// ── URL base da API ───────────────────────────────────────────────────────────
const BASE_URL = __ENV.BASE_URL || 'http://tcc-api.158.220.111.79.nip.io';

// ── Cenários de requisição ────────────────────────────────────────────────────
const endpoints = [
  { path: '/',           weight: 10 },
  { path: '/info',       weight: 20 },
  { path: '/health',     weight: 15 },
  { path: '/products',   weight: 25 },
  { path: '/products/1', weight: 15 },
  { path: '/unstable',   weight: 10 },
  { path: '/slow',       weight: 5  },
];

function pickEndpoint() {
  const total = endpoints.reduce((s, e) => s + e.weight, 0);
  let rand = Math.random() * total;
  for (const e of endpoints) {
    rand -= e.weight;
    if (rand <= 0) return e.path;
  }
  return '/info';
}

// ── Função principal ──────────────────────────────────────────────────────────
export default function () {
  const path = pickEndpoint();
  const url  = `${BASE_URL}${path}`;
  const res  = http.get(url, { timeout: '5s' });

  const success = check(res, {
    'status 2xx':       (r) => r.status >= 200 && r.status < 300,
    'response < 1000ms':(r) => r.timings.duration < 1000,
  });

  successRate.add(success);
  responseTrend.add(res.timings.duration);

  if (!success) {
    errorCount.add(1);
    console.log(`ERRO [${res.status}] ${url} — ${res.timings.duration}ms`);
  }

  sleep(Math.random() * 0.5 + 0.1);
}

// ── Resumo final ──────────────────────────────────────────────────────────────
export function handleSummary(data) {
  return {
    'stdout': JSON.stringify({
      success_rate:  data.metrics.tcc_success_rate?.values?.rate,
      p95_ms:        data.metrics.tcc_response_time?.values?.['p(95)'],
      p99_ms:        data.metrics.tcc_response_time?.values?.['p(99)'],
      errors_total:  data.metrics.tcc_errors_total?.values?.count,
      requests_total:data.metrics.http_reqs?.values?.count,
    }, null, 2),
    'summary.json': JSON.stringify(data, null, 2),
  };
}