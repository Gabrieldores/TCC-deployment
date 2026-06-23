#!/bin/bash
# ============================================================
# TCC — Canary vs Blue-Green: Script de Experimentos (Híbrido)
# Mantém ações manuais para editar YAMLs, mas corrige timing do caos
# ============================================================

set -euo pipefail

# ── Configurações ─────────────────────────────────────────────
BASE_URL="http://tcc-api.158.220.111.79.nip.io"
RESULTS_DIR="./results_hibrido"
NAMESPACE="app-tcc"
CHAOS_FILE="chaos/Experiments.yaml"
K6_SCRIPT="scripts/load-test.js"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }
log_phase()   { echo -e "\n${CYAN}════════════════════════════════════════${NC}"; \
                echo -e "${CYAN} $1${NC}"; \
                echo -e "${CYAN}════════════════════════════════════════${NC}\n"; }

# ── Funções auxiliares ─────────────────────────────────────────

# Aguarda o AnalysisRun específico do rollout entrar em Running
wait_for_specific_analysisrun() {
  local rollout=$1
  local max_wait=180
  local elapsed=0
  log_info "Aguardando AnalysisRun do rollout $rollout iniciar (Running)..."
  while [ $elapsed -lt $max_wait ]; do
    # Lista AnalysisRuns ordenados por criação, pega o último (mais recente)
    local ar_name=$(kubectl get analysisrun -n "$NAMESPACE" \
      -l "rollouts.argoproj.io/rollout=$rollout" \
      -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
    if [ -n "$ar_name" ]; then
      local phase=$(kubectl get analysisrun "$ar_name" -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null)
      if [ "$phase" = "Running" ]; then
        log_success "AnalysisRun $ar_name está Running. Injetando caos agora!"
        return 0
      fi
    fi
    sleep 3
    elapsed=$((elapsed + 3))
    echo -e "${YELLOW}  ... aguardando AnalysisRun (${elapsed}s)${NC}"
  done
  log_error "AnalysisRun não iniciou em ${max_wait}s"
}

# Aguarda o rollout retornar à v1 (rollback)
wait_for_rollback_to_v1() {
  local rollout=$1
  local timeout=120
  local elapsed=0
  log_info "Aguardando rollback automático para $rollout..."
  while [ $elapsed -lt $timeout ]; do
    local current_image=$(kubectl get rollout "$rollout" -n "$NAMESPACE" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    local healthy=$(kubectl get rollout "$rollout" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)
    if [[ "$current_image" == *":v1" ]] && [[ "$healthy" == "True" ]]; then
      log_success "Rollback para v1 confirmado!"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
    echo -e "${YELLOW}  ... aguardando rollback (${elapsed}s)${NC}"
  done
  log_error "Rollback não ocorreu em ${timeout}s"
}

# Coleta status do rollout e pods (para debug)
collect_rollout_status() {
  local rollout=$1
  local label=$2
  local dir="$RESULTS_DIR/rollout_${label}"
  mkdir -p "$dir"
  kubectl get rollout "$rollout" -n "$NAMESPACE" -o yaml > "$dir/rollout.yaml" 2>/dev/null || true
  kubectl describe rollout "$rollout" -n "$NAMESPACE" > "$dir/describe.txt" 2>/dev/null || true
  kubectl get pods -n "$NAMESPACE" > "$dir/pods.txt" 2>/dev/null || true
}

# ── Inicialização ──────────────────────────────────────────────
log_phase "EXPERIMENTOS TCC (HÍBRIDO) — $TIMESTAMP"

mkdir -p "$RESULTS_DIR"

for cmd in k6 kubectl curl; do
  command -v $cmd >/dev/null 2>&1 || log_error "$cmd não encontrado"
done

curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/health" | grep -q 200 || log_error "API não responde"

# ── FASE 1: BASELINE ──────────────────────────────────────────
log_phase "FASE 1 — BASELINE (Estado Estável)"
log_info "Executando k6 baseline por 3 minutos..."
k6 run -e BASE_URL="$BASE_URL" "$K6_SCRIPT" \
  --out json="$RESULTS_DIR/baseline_k6.json" \
  --summary-export="$RESULTS_DIR/baseline_summary.json" \
  2>&1 | tee "$RESULTS_DIR/baseline_output.txt"

log_success "Baseline concluído"
sleep 30

# ── EXPERIMENTO CANARY ────────────────────────────────────────
log_phase "EXPERIMENTO CANARY — Deploy da v2 com injeção de caos"

log_warn "AÇÃO MANUAL: Altere a imagem para v2 no arquivo rollouts/canary-rollout.yaml e faça git push"
echo ""
echo "  image: gabrieldores/tcc-api:v2"
echo "  APP_VERSION: v2.0.0"
echo "  APP_COLOR: green"
echo "  ERROR_RATE: 0.05"
echo "  SLOW_MS: 800"
echo ""
read -p "Pressione ENTER após fazer o git push..."

log_info "Forçando sincronização do ArgoCD..."
kubectl annotate application tcc-rollouts -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# Aguarda o AnalysisRun específico do canary
wait_for_specific_analysisrun "tcc-api-canary"

# Inicia k6 em background para capturar o período de caos
log_info "Iniciando k6 em background durante o experimento Canary..."
k6 run -e BASE_URL="$BASE_URL" "$K6_SCRIPT" \
  --out json="$RESULTS_DIR/canary_k6.json" \
  --summary-export="$RESULTS_DIR/canary_summary.json" \
  2>&1 | tee "$RESULTS_DIR/canary_output.txt" &
K6_PID=$!

# Injeta o caos AGORA
log_info "Injetando caos via Chaos Mesh..."
kubectl apply -f "$CHAOS_FILE"
log_success "Caos ativado (PodChaos, NetworkChaos, HTTPChaos, StressChaos)"

# Aguarda rollback automático
wait_for_rollback_to_v1 "tcc-api-canary"

# Remove caos imediatamente
log_info "Removendo caos..."
kubectl delete -f "$CHAOS_FILE" 2>/dev/null || true

# Aguarda k6 finalizar
wait $K6_PID 2>/dev/null || true

collect_rollout_status "tcc-api-canary" "canary"
log_success "Experimento Canary concluído"

# ── EXPERIMENTO BLUE-GREEN ────────────────────────────────────
log_phase "EXPERIMENTO BLUE-GREEN — Deploy da v2 com injeção de caos"

log_warn "AÇÃO MANUAL: Altere a imagem para v2 no arquivo rollouts/bluegreen-rollout.yaml e faça git push"
echo ""
echo "  image: gabrieldores/tcc-api:v2"
echo "  APP_VERSION: v2.0.0"
echo "  APP_COLOR: green"
echo "  ERROR_RATE: 0.05"
echo "  SLOW_MS: 800"
echo ""
read -p "Pressione ENTER após fazer o git push..."

log_info "Forçando sincronização do ArgoCD..."
kubectl annotate application tcc-rollouts -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# Aguarda o AnalysisRun específico do blue-green
wait_for_specific_analysisrun "tcc-api-bluegreen"

# Inicia k6 em background
log_info "Iniciando k6 em background durante o experimento Blue-Green..."
k6 run -e BASE_URL="$BASE_URL" "$K6_SCRIPT" \
  --out json="$RESULTS_DIR/bluegreen_k6.json" \
  --summary-export="$RESULTS_DIR/bluegreen_summary.json" \
  2>&1 | tee "$RESULTS_DIR/bluegreen_output.txt" &
K6_PID=$!

# Injeta o caos AGORA
log_info "Injetando caos via Chaos Mesh..."
kubectl apply -f "$CHAOS_FILE"
log_success "Caos ativado"

# Aguarda rollback automático
wait_for_rollback_to_v1 "tcc-api-bluegreen"

# Remove caos
log_info "Removendo caos..."
kubectl delete -f "$CHAOS_FILE" 2>/dev/null || true

wait $K6_PID 2>/dev/null || true

collect_rollout_status "tcc-api-bluegreen" "bluegreen"
log_success "Experimento Blue-Green concluído"

# ── RELATÓRIO FINAL ────────────────────────────────────────────
log_phase "RELATÓRIO FINAL"

REPORT="$RESULTS_DIR/relatorio_final_${TIMESTAMP}.txt"
cat > "$REPORT" << EOF
============================================================
 TCC — Canary vs Blue-Green
 Relatório Final (Híbrido)
============================================================
Data: $(date)
Base URL: $BASE_URL

RESUMO DAS MÉTRICAS:
EOF

for label in baseline canary bluegreen; do
  summary="$RESULTS_DIR/${label}_summary.json"
  if [ -f "$summary" ]; then
    echo "" >> "$REPORT"
    echo "--- $label ---" >> "$REPORT"
    if command -v jq >/dev/null 2>&1; then
      jq '.metrics | {http_reqs: .http_reqs.values.count, failed: .http_req_failed.values.rate, p95: .http_req_duration.values."p95", p99: .http_req_duration.values."p99"}' "$summary" >> "$REPORT"
    else
      cat "$summary" >> "$REPORT"
    fi
  fi
done

echo "" >> "$REPORT"
echo "Arquivos gerados em: $RESULTS_DIR/" >> "$REPORT"

cat "$REPORT"
log_success "Relatório salvo em $REPORT"

log_phase "EXPERIMENTOS CONCLUÍDOS"
echo "Resultados em: $RESULTS_DIR/"