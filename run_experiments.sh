#!/bin/bash
# ============================================================
# TCC — Canary vs Blue-Green: Script de Experimentos Completo
# Executa: Baseline → Canary → Blue-Green
# Coleta: k6 + Prometheus + Argo Rollouts
# ============================================================

set -e

# ── Configurações ─────────────────────────────────────────────
BASE_URL="http://tcc-api.158.220.111.79.nip.io"
RESULTS_DIR="./results"
NAMESPACE="app-tcc"
PROMETHEUS_URL="http://10.43.28.62:9090"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Funções utilitárias ───────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_phase()   { echo -e "\n${CYAN}════════════════════════════════════════${NC}"; \
                echo -e "${CYAN} $1${NC}"; \
                echo -e "${CYAN}════════════════════════════════════════${NC}\n"; }

pause() {
  local seconds=$1
  local msg=$2
  echo -e "${YELLOW}⏳ Aguardando ${seconds}s — ${msg}...${NC}"
  sleep "$seconds"
}

# ── Coleta de métricas do Prometheus ─────────────────────────
collect_prometheus() {
  local label=$1
  local output_dir="$RESULTS_DIR/prometheus_${label}"
  mkdir -p "$output_dir"

  log_info "Coletando métricas do Prometheus para: $label"

  curl -s --globoff \
    "${PROMETHEUS_URL}/api/v1/query?query=sum(rate(http_requests_total{status=~\"2..\"}[2m]))/sum(rate(http_requests_total[2m]))" \
    > "$output_dir/success_rate.json"

  curl -s --globoff \
    "${PROMETHEUS_URL}/api/v1/query?query=histogram_quantile(0.95,sum(rate(http_request_duration_ms_bucket[2m]))by(le))" \
    > "$output_dir/latency_p95.json"

  curl -s --globoff \
    "${PROMETHEUS_URL}/api/v1/query?query=histogram_quantile(0.99,sum(rate(http_request_duration_ms_bucket[2m]))by(le))" \
    > "$output_dir/latency_p99.json"

  curl -s --globoff \
    "${PROMETHEUS_URL}/api/v1/query?query=sum(rate(http_requests_total{status=~\"5..\"}[2m]))by(path)" \
    > "$output_dir/errors_per_second.json"

  curl -s --globoff \
    "${PROMETHEUS_URL}/api/v1/query?query=sum(app_errors_total)" \
    > "$output_dir/errors_total.json"

  curl -s --globoff \
    "${PROMETHEUS_URL}/api/v1/query?query=sum(app_active_requests)" \
    > "$output_dir/active_requests.json"

  curl -s --globoff \
    "${PROMETHEUS_URL}/api/v1/query?query=sum(rate(http_requests_total[2m]))by(path)" \
    > "$output_dir/requests_by_path.json"

  log_success "Métricas Prometheus salvas em $output_dir"
}

# ── Coleta de status do Argo Rollouts ────────────────────────
collect_rollout_status() {
  local rollout_name=$1
  local label=$2
  local output_dir="$RESULTS_DIR/rollout_${label}"
  mkdir -p "$output_dir"

  log_info "Coletando status do rollout: $rollout_name"

  kubectl get rollout "$rollout_name" -n "$NAMESPACE" -o yaml \
    > "$output_dir/rollout_status.yaml"

  kubectl describe rollout "$rollout_name" -n "$NAMESPACE" \
    > "$output_dir/rollout_describe.txt"

  kubectl get analysisrun -n "$NAMESPACE" -o yaml \
    > "$output_dir/analysisrun.yaml"

  kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' \
    > "$output_dir/events.txt"

  kubectl get pods -n "$NAMESPACE" \
    > "$output_dir/pods.txt"

  log_success "Status do rollout salvo em $output_dir"
}

# ── Aguarda AnalysisRun iniciar ───────────────────────────────
wait_for_analysisrun() {
  local rollout_name=$1
  local max_wait=120
  local elapsed=0
  log_info "Aguardando AnalysisRun iniciar para $rollout_name..."
  while [ $elapsed -lt $max_wait ]; do
    STATUS=$(kubectl get analysisrun -n "$NAMESPACE" \
      --no-headers 2>/dev/null | grep -i "running" | wc -l)
    if [ "$STATUS" -gt "0" ]; then
      log_success "AnalysisRun iniciado!"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    echo -e "${YELLOW}  ... aguardando AnalysisRun (${elapsed}s/${max_wait}s)${NC}"
  done
  log_warn "AnalysisRun não iniciou em ${max_wait}s — injetando caos mesmo assim"
}

# ── Aguarda Tráfego do Canary ─────────────────────────────────
wait_for_canary_weight() {
  local rollout_name=$1
  local target_weight=$2
  local max_wait=120
  local elapsed=0
  log_info "Aguardando Canary ($rollout_name) atingir ${target_weight}% de tráfego..."
  
  while [ $elapsed -lt $max_wait ]; do
    WEIGHT=$(kubectl argo rollouts get rollout "$rollout_name" -n "$NAMESPACE" 2>/dev/null | grep "Weight:" | awk '{print $2}' | tr -d '%' || true)
    
    if [ "$WEIGHT" == "$target_weight" ]; then
      log_success "Tráfego redirecionado! Canary bateu ${target_weight}% exatos."
      return 0
    fi
    
    sleep 5
    elapsed=$((elapsed + 5))
    echo -e "${YELLOW}  ... monitorando roteamento (${elapsed}s/${max_wait}s) - Atual: ${WEIGHT:-0}%${NC}"
  done
  log_warn "Timeout aguardando 20%. Injetando caos mesmo assim..."
}

# ── Inicialização ─────────────────────────────────────────────
log_phase "INICIANDO EXPERIMENTOS TCC — $TIMESTAMP"

mkdir -p "$RESULTS_DIR"

log_info "Verificando dependências..."
command -v k6      >/dev/null 2>&1 || { log_warn "k6 não encontrado"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { log_warn "kubectl não encontrado"; exit 1; }
command -v curl    >/dev/null 2>&1 || { log_warn "curl não encontrado"; exit 1; }

log_info "Verificando API..."
API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/health")
if [ "$API_STATUS" != "200" ]; then
  log_warn "API não está respondendo (status: $API_STATUS)"
  exit 1
fi
log_success "API respondendo normalmente"

# ── FASE 1: BASELINE ──────────────────────────────────────────
log_phase "FASE 1 — BASELINE (Estado Estável)"

collect_prometheus "baseline_antes"

pause 10 "preparando geração de carga"

log_info "Executando k6 — Baseline (3 minutos)..."
k6 run \
  --out json="$RESULTS_DIR/baseline_k6.json" \
  --summary-export="$RESULTS_DIR/baseline_summary.json" \
  -e BASE_URL="$BASE_URL" \
  scripts/load-test.js 2>&1 | tee "$RESULTS_DIR/baseline_k6_output.txt"

log_success "Baseline concluído"
collect_prometheus "baseline_depois"

pause 30 "estabilizando o sistema antes dos experimentos"

# ── FASE 2-6: EXPERIMENTO CANARY ─────────────────────────────
log_phase "EXPERIMENTO CANARY — Deploy da v2 com injeção de caos"

collect_rollout_status "tcc-api-canary" "canary_antes"

log_warn "AÇÃO MANUAL: Altere a imagem para v2 no arquivo rollouts/canary-rollout.yaml e faça git push"
echo ""
echo "  image: gabrieldores/tcc-api:v2"
echo "  APP_VERSION: v2.0.0"
echo "  APP_COLOR: green"
echo "  ERROR_RATE: 0.05"
echo "  SLOW_MS: 800"
echo ""
read -p "Pressione ENTER após fazer o git push..."

pause 10 "aguardando ArgoCD reconhecer o commit"

log_info "Forçando sincronização do ArgoCD..."
kubectl annotate application tcc-rollouts -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

log_info "Iniciando k6 em background durante o experimento Canary..."
k6 run \
  --out json="$RESULTS_DIR/canary_k6.json" \
  --summary-export="$RESULTS_DIR/canary_summary.json" \
  -e BASE_URL="$BASE_URL" \
  scripts/load-test.js 2>&1 | tee "$RESULTS_DIR/canary_k6_output.txt" &
K6_PID=$!

# Aguarda EXATAMENTE bater 20% do tráfego antes de injetar o Caos!
wait_for_canary_weight "tcc-api-canary" "20"
collect_prometheus "canary_antes_caos"

log_info "Injetando caos via Chaos Mesh (durante roteamento de 20%)..."
kubectl apply -f chaos/Experiments.yaml
log_success "Chaos Mesh ativado — PodChaos + NetworkChaos + HTTPChaos + StressChaos"

collect_prometheus "canary_durante_caos"
pause 60 "aguardando degradação das métricas"
collect_prometheus "canary_durante_caos_2"
pause 60 "aguardando rollback automático do Argo Rollouts"

collect_rollout_status "tcc-api-canary" "canary_rollback"
collect_prometheus "canary_apos_rollback"

wait $K6_PID 2>/dev/null || true

log_info "Removendo experimentos de caos..."
if ! kubectl delete -f chaos/Experiments.yaml --timeout=45s 2>/dev/null; then
  log_warn "O Chaos Mesh engasgou (Timeout). Forçando a remoção dos finalizadores..."
  for i in $(kubectl get podchaos,networkchaos,httpchaos,stresschaos -n chaos-testing -o name 2>/dev/null); do
    kubectl patch $i -n chaos-testing -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
  done
fi

log_info "Recriando pods da API para esterilizar o ambiente..."
kubectl delete pods --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true

log_success "Experimento Canary concluído"

pause 60 "estabilizando sistema antes do Blue-Green"

log_warn "AÇÃO MANUAL: Reverta canary-rollout.yaml para v1 e faça git push"
echo ""
echo "  image: gabrieldores/tcc-api:v1"
echo "  APP_VERSION: v1.0.0"
echo "  APP_COLOR: blue"
echo "  ERROR_RATE: 0"
echo "  SLOW_MS: 0"
echo ""
read -p "Pressione ENTER após fazer o git push..."

pause 20 "aguardando reset do Canary"

# ── FASE 2-6: EXPERIMENTO BLUE-GREEN ─────────────────────────
log_phase "EXPERIMENTO BLUE-GREEN — Deploy da v2 com injeção de caos"

collect_rollout_status "tcc-api-bluegreen" "bluegreen_antes"

log_warn "AÇÃO MANUAL: Altere a imagem para v2 no arquivo rollouts/bluegreen-rollouts.yaml e faça git push"
echo ""
echo "  image: gabrieldores/tcc-api:v2"
echo "  APP_VERSION: v2.0.0"
echo "  APP_COLOR: green"
echo "  ERROR_RATE: 0.05"
echo "  SLOW_MS: 800"
echo ""
read -p "Pressione ENTER após fazer o git push..."

pause 10 "aguardando ArgoCD reconhecer o commit"

kubectl annotate application tcc-rollouts -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

log_info "Iniciando k6 em background durante o experimento Blue-Green..."
k6 run \
  --out json="$RESULTS_DIR/bluegreen_k6.json" \
  --summary-export="$RESULTS_DIR/bluegreen_summary.json" \
  -e BASE_URL="$BASE_URL" \
  scripts/load-test.js 2>&1 | tee "$RESULTS_DIR/bluegreen_k6_output.txt" &
K6_PID=$!

# Aguarda AnalysisRun iniciar antes de injetar o caos no Blue-Green (pois o BG usa Preview pre-promotion)
wait_for_analysisrun "tcc-api-bluegreen"
collect_prometheus "bluegreen_antes_caos"

log_info "Injetando caos via Chaos Mesh..."
kubectl apply -f chaos/Experiments.yaml
log_success "Chaos Mesh ativado — PodChaos + NetworkChaos + HTTPChaos + StressChaos"

collect_prometheus "bluegreen_durante_caos"
pause 60 "aguardando degradação das métricas"
collect_prometheus "bluegreen_durante_caos_2"
pause 60 "aguardando rollback automático do Argo Rollouts"

collect_rollout_status "tcc-api-bluegreen" "bluegreen_rollback"
collect_prometheus "bluegreen_apos_rollback"

wait $K6_PID 2>/dev/null || true

log_info "Removendo experimentos de caos..."
if ! kubectl delete -f chaos/Experiments.yaml --timeout=45s 2>/dev/null; then
  log_warn "O Chaos Mesh engasgou (Timeout). Forçando a remoção dos finalizadores..."
  for i in $(kubectl get podchaos,networkchaos,httpchaos,stresschaos -n chaos-testing -o name 2>/dev/null); do
    kubectl patch $i -n chaos-testing -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
  done
fi

log_info "Recriando pods da API para esterilizar o ambiente..."
kubectl delete pods --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true

log_success "Experimento Blue-Green concluído"

# ── RELATÓRIO FINAL ───────────────────────────────────────────
log_phase "GERANDO RELATÓRIO FINAL"

REPORT="$RESULTS_DIR/relatorio_final_${TIMESTAMP}.txt"

cat > "$REPORT" << 'REPORT_EOF'
============================================================
 TCC — Canary vs Blue-Green
 Relatório Final de Experimentos
============================================================

REPORT_EOF

echo "Gerado em: $(date)" >> "$REPORT"
echo "Base URL: $BASE_URL" >> "$REPORT"
echo "" >> "$REPORT"

echo "============================================================" >> "$REPORT"
echo " BASELINE" >> "$REPORT"
echo "============================================================" >> "$REPORT"
if [ -f "$RESULTS_DIR/baseline_summary.json" ]; then
  echo "Resumo k6:" >> "$REPORT"
  cat "$RESULTS_DIR/baseline_summary.json" | python3 -m json.tool >> "$REPORT" 2>/dev/null || \
  cat "$RESULTS_DIR/baseline_summary.json" >> "$REPORT"
fi

echo "" >> "$REPORT"
echo "============================================================" >> "$REPORT"
echo " CANARY" >> "$REPORT"
echo "============================================================" >> "$REPORT"
if [ -f "$RESULTS_DIR/canary_summary.json" ]; then
  echo "Resumo k6:" >> "$REPORT"
  cat "$RESULTS_DIR/canary_summary.json" | python3 -m json.tool >> "$REPORT" 2>/dev/null || \
  cat "$RESULTS_DIR/canary_summary.json" >> "$REPORT"
fi
echo "" >> "$REPORT"
echo "Status Argo Rollouts:" >> "$REPORT"
if [ -f "$RESULTS_DIR/rollout_canary_rollback/rollout_describe.txt" ]; then
  grep -A 5 "Message\|Phase\|Status\|Images" \
    "$RESULTS_DIR/rollout_canary_rollback/rollout_describe.txt" >> "$REPORT" 2>/dev/null || true
fi

echo "" >> "$REPORT"
echo "============================================================" >> "$REPORT"
echo " BLUE-GREEN" >> "$REPORT"
echo "============================================================" >> "$REPORT"
if [ -f "$RESULTS_DIR/bluegreen_summary.json" ]; then
  echo "Resumo k6:" >> "$REPORT"
  cat "$RESULTS_DIR/bluegreen_summary.json" | python3 -m json.tool >> "$REPORT" 2>/dev/null || \
  cat "$RESULTS_DIR/bluegreen_summary.json" >> "$REPORT"
fi
echo "" >> "$REPORT"
echo "Status Argo Rollouts:" >> "$REPORT"
if [ -f "$RESULTS_DIR/rollout_bluegreen_rollback/rollout_describe.txt" ]; then
  grep -A 5 "Message\|Phase\|Status\|Images" \
    "$RESULTS_DIR/rollout_bluegreen_rollback/rollout_describe.txt" >> "$REPORT" 2>/dev/null || true
fi

echo "" >> "$REPORT"
echo "============================================================" >> "$REPORT"
echo " ARQUIVOS GERADOS" >> "$REPORT"
echo "============================================================" >> "$REPORT"
find "$RESULTS_DIR" -type f | sort >> "$REPORT"

log_success "Relatório final salvo em: $REPORT"

log_phase "ESTRUTURA DOS RESULTADOS"
find "$RESULTS_DIR" -type f | sort | sed 's|./results/||'

log_phase "EXPERIMENTOS CONCLUÍDOS COM SUCESSO"
echo -e "${GREEN}Todos os arquivos estão em: $RESULTS_DIR/${NC}"
echo ""
echo "Arquivos principais para o TCC:"
echo "  baseline_summary.json       → métricas do baseline"
echo "  canary_summary.json         → métricas do canary"
echo "  bluegreen_summary.json      → métricas do blue-green"
echo "  relatorio_final_*.txt       → relatório consolidado"
echo "  prometheus_*/               → métricas do Prometheus"
echo "  rollout_*/                  → status do Argo Rollouts"