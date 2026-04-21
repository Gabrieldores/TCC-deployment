const express = require('express');
const client = require('prom-client'); // Biblioteca para métricas
const app = express();
const PORT = process.env.PORT || 3000;

// Configuração de métricas para o Prometheus
const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total de requisições HTTP',
  labelNames: ['method', 'path', 'status']
});
register.registerMetric(httpRequestsTotal);

// Variáveis que vamos mudar no Deploy (v1 vs v2)
const APP_VERSION = process.env.APP_VERSION || "v1.0.0";
const APP_COLOR = process.env.APP_COLOR || "blue";

app.get('/info', (req, res) => {
  httpRequestsTotal.inc({ method: 'GET', path: '/info', status: 200 });
  res.json({
    version: APP_VERSION,
    color: APP_COLOR,
    message: "Rodando no cluster K3s da Contabo!"
  });
});

app.get('/health', (req, res) => {
  res.status(200).send('Healthy');
});

// Endpoint que o Prometheus vai ler
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

app.listen(PORT, () => {
  console.log(`API ${APP_VERSION} ativa na porta ${PORT}`);
});