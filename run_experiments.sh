#!/bin/bash
# =============================================================================
# run_experiments.sh — Automação das 10 rodadas experimentais do TCC
# Canary vs. Blue-Green sob Chaos Engineering
#
# USO:
#   chmod +x run_experiments.sh
#   ./run_experiments.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURAÇÃO — edite aqui antes de rodar
# =============================================================================
NAMESPACE="app-tcc"
ROLLOUT_NAME=""                             # definido dinamicamente por rodada
APP_NAME="tcc-deployment"                   # Nome correto da app no ArgoCD
IMAGE_V1="gabrieldores/tcc-api:v1"
IMAGE_V2="gabrieldores/tcc-api:v2"
CONTAINER_NAME="tcc-api"
K6_SCRIPT="./scripts/load-test.js"
CHAOS_DIR="./chaos"                    # diretório com Experiments.yaml
CHAOS_FILE="Experiments.yaml"              # arquivo único com todos os cenários
RESULTS_DIR="./resultados"
REPORT_FILE="./resultados/relatorio-final.md"
COOLDOWN_SECONDS=120                        # pausa entre rodadas
BASELINE_WAIT=30                            # segundos para baseline estabilizar
CHAOS_WAIT=60                               # segundos com caos ativo antes de checar rollback
RECOVERY_WAIT=90                            # segundos para aguardar recovery após rollback

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# DEFINIÇÃO DAS 10 RODADAS
# Format: "ESTRATEGIA|CENARIO|ARQUIVO_CHAOS"
# =============================================================================
declare -a RODADAS=(
  "canary|PodChaos|PodChaos"
  "blue-green|PodChaos|PodChaos"
  "canary|NetworkChaos|NetworkChaos"
  "blue-green|NetworkChaos|NetworkChaos"
  "canary|HTTPChaos|HTTPChaos"
  "blue-green|HTTPChaos|HTTPChaos"
  "canary|StressChaos|StressChaos"
  "blue-green|StressChaos|StressChaos"
  "canary|Mix-Pod-Network|PodChaos NetworkChaos"
  "blue-green|Mix-Pod-Network|PodChaos NetworkChaos"
)

# =============================================================================
# FUNÇÕES AUXILIARES
# =============================================================================

log() {
  echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
}

log_ok() {
  echo -e "${GREEN}[$(date '+%H:%M:%S')] ✅ $1${NC}"
}

log_warn() {
  echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠️  $1${NC}"
}

log_err() {
  echo -e "${RED}[$(date '+%H:%M:%S')] ❌ $1${NC}"
}

log_section() {
  echo ""
  echo -e "${YELLOW}═══════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  $1${NC}"
  echo -e "${YELLOW}═══════════════════════════════════════════${NC}"
}

wait_rollout_stable() {
  log "Aguardando rollout estabilizar..."
  local timeout=120
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    STATUS=$(kubectl argo rollouts get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" \
      --no-headers 2>/dev/null | awk '{print $2}' | head -1 || echo "unknown")
    if [[ "$STATUS" == "Healthy" || "$STATUS" == "Degraded" || "$STATUS" == "Paused" ]]; then
      log "Status do rollout: $STATUS"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  log_warn "Timeout aguardando rollout. Continuando..."
}

wait_rollback_complete() {
  log "Aguardando rollback completar..."
  local timeout=180
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    CURRENT_IMAGE=$(kubectl get pods -n "$NAMESPACE" \
      -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo "")
    if [[ "$CURRENT_IMAGE" == "$IMAGE_V1" ]]; then
      log_ok "Rollback confirmado — pods rodando $IMAGE_V1"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  log_warn "Timeout aguardando rollback. Verifique manualmente."
}

reset_cluster() {
  log "Limpando o cluster e resetando para a v1..."
  
  # 1. Aborta qualquer rollout que tenha travado
  kubectl argo rollouts abort "$ROLLOUT_NAME" -n "$NAMESPACE" 2>/dev/null || true
  
  # 2. Força o ArgoCD a puxar a versão oficial (v1) do Git
  kubectl patch application "$APP_NAME" -n argocd --type merge --patch '{"operation": {"sync": {"prune": true}}}' 2>/dev/null || true
  
  # 3. Mata todos os pods para subir o ambiente estéril e limpo
  kubectl delete pods --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
  
  log "Aguardando 45s para os pods da v1 estabilizarem..."
  sleep 45
  log_ok "Cluster esterilizado e resetado para v1"
}

apply_chaos() {
  local kinds="$1"
  log "Aplicando caos para kinds: $kinds"
  for kind in $kinds; do
    python3 -c "
import sys, re
kinds_target = sys.argv[1].split()
with open('$CHAOS_DIR/$CHAOS_FILE') as f:
    docs = f.read().split('---')
for doc in docs:
    doc = doc.strip()
    if not doc:
        continue
    for k in kinds_target:
        if 'kind: ' + k in doc:
            print(doc)
            print('---')
            break
" "$kinds" | kubectl apply -f - -n chaos-testing 2>&1 || true
  done
}

cleanup_chaos() {
  local kinds="$1"
  log "Removendo caos para kinds: $kinds"
  for kind in $kinds; do
    case "$kind" in
      PodChaos)     kubectl delete podchaos     --all -n chaos-testing 2>/dev/null || true ;;
      NetworkChaos) kubectl delete networkchaos --all -n chaos-testing 2>/dev/null || true ;;
      HTTPChaos)    kubectl delete httpchaos    --all -n chaos-testing 2>/dev/null || true ;;
      StressChaos)  kubectl delete stresschaos  --all -n chaos-testing 2>/dev/null || true ;;
    esac
  done
  sleep 5
  log_ok "Caos removido"
}

record_timestamp() {
  echo "$(date '+%Y-%m-%d %H:%M:%S')"
}

# =============================================================================
# PRÉ-FLIGHT CHECK
# =============================================================================

preflight_check() {
  log_section "PRÉ-FLIGHT CHECK"

  log "Verificando dependências CLI..."
  for cmd in kubectl k6 python3; do
    if command -v "$cmd" &>/dev/null; then
      log_ok "$cmd disponível"
    else
      log_err "$cmd não encontrado. Instale antes de continuar."
      exit 1
    fi
  done

  log "Verificando cluster Kubernetes..."
  kubectl get nodes -o wide || { log_err "Cluster inacessível."; exit 1; }

  log "Verificando arquivo de caos..."
  if [ -f "$CHAOS_DIR/$CHAOS_FILE" ]; then
    log_ok "$CHAOS_FILE encontrado"
  else
    log_err "$CHAOS_FILE NÃO encontrado em $CHAOS_DIR/"
    exit 1
  fi

  log "Verificando script k6..."
  [ -f "$K6_SCRIPT" ] && log_ok "Script k6 encontrado" \
    || { log_err "Script k6 não encontrado em $K6_SCRIPT"; exit 1; }

  mkdir -p "$RESULTS_DIR"
  log_ok "Diretório de resultados: $RESULTS_DIR"
  log_ok "Pré-flight OK. Iniciando experimentos..."
}

# =============================================================================
# FUNÇÃO PRINCIPAL — 1 RODADA COMPLETA
# =============================================================================

run_experiment() {
  local rodada_num="$1"
  local estrategia="$2"
  local cenario="$3"
  local chaos_file="$4"

  if [[ "$estrategia" == "canary" ]]; then
    ROLLOUT_NAME="tcc-api-canary"
  else
    ROLLOUT_NAME="tcc-api-bluegreen"
  fi

  local rodada_dir="$RESULTS_DIR/rodada-$(printf '%02d' $rodada_num)"
  mkdir -p "$rodada_dir"

  local log_file="$rodada_dir/execution.log"
  local results_file="$rodada_dir/summary.txt"

  log_section "RODADA $rodada_num/10 — $estrategia | $cenario"

  {
    echo "=== RODADA $rodada_num ==="
    echo "Estratégia: $estrategia"
    echo "Cenário: $cenario"
    echo "Arquivo Chaos: $chaos_file"
    echo "Início: $(record_timestamp)"
  } > "$results_file"

  # ----------------------------------------------------------
  # FASE 1 — BASELINE
  # ----------------------------------------------------------
  log_section "FASE 1 — BASELINE (Rodada $rodada_num)"
  log "Coletando baseline com k6..."

  k6 run \
    --out "json=$rodada_dir/baseline.json" \
    --summary-export="$rodada_dir/baseline-summary.json" \
    "$K6_SCRIPT" 2>&1 | tee -a "$log_file" || log_warn "k6 baseline concluído com alertas"

  log_ok "Baseline coletado → $rodada_dir/baseline.json"
  echo "Baseline coletado: $(record_timestamp)" >> "$results_file"

  sleep "$BASELINE_WAIT"

  # ----------------------------------------------------------
  # FASE 2 — INÍCIO DO DEPLOY DA VERSÃO 2
  # ----------------------------------------------------------
  log_section "FASE 2 — DEPLOY v2 com $estrategia (Rodada $rodada_num)"

  K6_SUMMARY_PATH="$rodada_dir/summary.json" \
  k6 run \
    --out "json=$rodada_dir/experimento.json" \
    -e "K6_SUMMARY_EXPORT=$rodada_dir/summary.json" \
    "$K6_SCRIPT" &
  K6_PID=$!
  log "k6 rodando em background (PID: $K6_PID)"

  sleep 10  # aguardar k6 estabilizar antes do rollout

  log "Acionando gatilho do Argo Rollouts para atualizar para a v2..."
  # Este é o comando que altera a versão e inicia o deploy da v2
  kubectl argo rollouts set image "$ROLLOUT_NAME" \
    "$CONTAINER_NAME"="$IMAGE_V2" -n "$NAMESPACE" \
    2>&1 | tee -a "$log_file"

  echo "Deploy iniciado: $(record_timestamp)" >> "$results_file"

  wait_rollout_stable
  log_ok "Rollout iniciado e pausado na v2"

  # ----------------------------------------------------------
  # FASE 3 — INJEÇÃO DE CAOS
  # ----------------------------------------------------------
  log_section "FASE 3 — INJEÇÃO DE CAOS: $cenario (Rodada $rodada_num)"

  CHAOS_START=$(record_timestamp)
  apply_chaos "$chaos_file"

  log_ok "Caos aplicado: $cenario ($chaos_file) às $CHAOS_START"
  echo "Caos iniciado: $CHAOS_START" >> "$results_file"

  log "Aguardando $CHAOS_WAIT segundos com caos ativo..."
  sleep "$CHAOS_WAIT"

  # ----------------------------------------------------------
  # FASE 4+5 — DEGRADAÇÃO E ROLLBACK
  # ----------------------------------------------------------
  log_section "FASE 4/5 — AGUARDANDO DEGRADAÇÃO E ROLLBACK (Rodada $rodada_num)"

  DEGRADATION_TIME=$(record_timestamp)
  log "Verificando status do rollout após caos..."
  kubectl argo rollouts get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" \
    2>&1 | tee -a "$log_file"

  echo "Degradação detectada: $DEGRADATION_TIME" >> "$results_file"

  log "Aguardando rollback automático pelo Argo Rollouts..."
  wait_rollback_complete

  ROLLBACK_TIME=$(record_timestamp)
  echo "Rollback completo: $ROLLBACK_TIME" >> "$results_file"

  cleanup_chaos "$chaos_file"

  # ----------------------------------------------------------
  # FASE 6 — RECUPERAÇÃO
  # ----------------------------------------------------------
  log_section "FASE 6 — RECUPERAÇÃO (Rodada $rodada_num)"

  log "Aguardando $RECOVERY_WAIT segundos para métricas normalizarem..."
  sleep "$RECOVERY_WAIT"

  RECOVERY_TIME=$(record_timestamp)
  echo "Recuperação completa: $RECOVERY_TIME" >> "$results_file"

  log "Aguardando k6 finalizar..."
  wait $K6_PID 2>/dev/null || true
  log_ok "k6 finalizado"

  # ----------------------------------------------------------
  # PÓS-RODADA
  # ----------------------------------------------------------
  log_section "PÓS-RODADA $rodada_num — Coletando resultados"

  SUMMARY_JSON="$rodada_dir/summary.json"
  if [ -f "$SUMMARY_JSON" ]; then
    SUCCESS_RATE=$(python3 -c "
import json
try:
    data = json.load(open('$SUMMARY_JSON'))
    rate = data.get('metrics', {}).get('tcc_success_rate', {}).get('values', {}).get('rate', None)
    print(f'{float(rate)*100:.2f}%' if rate is not None else 'N/A')
except Exception as e:
    print('N/A')
" 2>/dev/null || echo "N/A")

    P95=$(python3 -c "
import json
try:
    data = json.load(open('$SUMMARY_JSON'))
    p95 = data.get('metrics', {}).get('tcc_response_time', {}).get('values', {}).get('p(95)', None)
    print(f'{float(p95):.2f}ms' if p95 is not None else 'N/A')
except:
    print('N/A')
" 2>/dev/null || echo "N/A")

    P99=$(python3 -c "
import json
try:
    data = json.load(open('$SUMMARY_JSON'))
    p99 = data.get('metrics', {}).get('tcc_response_time', {}).get('values', {}).get('p(99)', None)
    print(f'{float(p99):.2f}ms' if p99 is not None else 'N/A')
except:
    print('N/A')
" 2>/dev/null || echo "N/A")

    ERRORS=$(python3 -c "
import json
try:
    data = json.load(open('$SUMMARY_JSON'))
    errs = data.get('metrics', {}).get('tcc_errors_total', {}).get('values', {}).get('count', None)
    print(int(errs) if errs is not None else 'N/A')
except:
    print('N/A')
" 2>/dev/null || echo "N/A")

    REQS=$(python3 -c "
import json
try:
    data = json.load(open('$SUMMARY_JSON'))
    reqs = data.get('metrics', {}).get('http_reqs', {}).get('values', {}).get('count', None)
    print(int(reqs) if reqs is not None else 'N/A')
except:
    print('N/A')
" 2>/dev/null || echo "N/A")

    log_ok "Success Rate: $SUCCESS_RATE | p95: $P95 | p99: $P99 | Erros: $ERRORS | Reqs: $REQS"
    echo "Success Rate: $SUCCESS_RATE"  >> "$results_file"
    echo "Latência p95: $P95"           >> "$results_file"
    echo "Latência p99: $P99"           >> "$results_file"
    echo "Erros totais: $ERRORS"        >> "$results_file"
    echo "Requisições: $REQS"           >> "$results_file"
  else
    log_warn "summary.json não encontrado em $rodada_dir — verifique o handleSummary do k6"
  fi

  echo "Fim da rodada: $(record_timestamp)" >> "$results_file"
  cat "$results_file"

  log_ok "Rodada $rodada_num concluída. Resultados em: $rodada_dir"

  reset_cluster

  log "Cooldown de ${COOLDOWN_SECONDS}s antes da próxima rodada..."
  sleep "$COOLDOWN_SECONDS"
}

# =============================================================================
# GERAÇÃO DO RELATÓRIO MARKDOWN LOCAL (Removida desta mensagem para não ficar gigante, o seu original está perfeito, mantive a chamada dele no MAIN)
# =============================================================================
generate_report() {
  log_section "GERANDO RELATÓRIO MARKDOWN"
  mkdir -p "$RESULTS_DIR"
  echo "# Relatório de Experimentos — Canary vs. Blue-Green" > "$REPORT_FILE"
  echo "_Relatório gerado em $(date '+%d/%m/%Y às %H:%M:%S')_" >> "$REPORT_FILE"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║   TCC — Canary vs Blue-Green: 10 Rodadas             ║${NC}"
  echo -e "${BLUE}║   Autor: Gabriel Lucas Pereira das Dores             ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""

  preflight_check

  echo ""
  log_warn "Iniciando sequência de 10 experimentos. Não interrompa o processo."
  log_warn "Pressione Ctrl+C para abortar. Os resultados parciais serão preservados."
  echo ""
  sleep 5

  local total=${#RODADAS[@]}
  local rodada_num=1

  for rodada in "${RODADAS[@]}"; do
    ESTRATEGIA=$(echo "$rodada" | cut -d'|' -f1)
    CENARIO=$(echo "$rodada" | cut -d'|' -f2)
    CHAOS_FILE=$(echo "$rodada" | cut -d'|' -f3)

    run_experiment "$rodada_num" "$ESTRATEGIA" "$CENARIO" "$CHAOS_FILE"

    rodada_num=$((rodada_num + 1))
  done

  # Gerar relatório Markdown local
  generate_report

  # Resumo final
  log_section "EXPERIMENTOS CONCLUÍDOS"
  echo ""
  echo "Resultados salvos em: $RESULTS_DIR"
  echo ""
  log_ok "Todos os 10 experimentos finalizados!"
}

trap 'log_err "Experimento interrompido. Limpando..."; cleanup_chaos "${CHAOS_FILE:-}" 2>/dev/null; reset_cluster 2>/dev/null; exit 1' INT TERM

main "$@"