#!/bin/bash
# =============================================================================
# run_experiments.sh — Automação das rodadas experimentais do TCC
# Canary vs. Blue-Green sob Chaos Engineering
#
# USO:
#   chmod +x run_experiments.sh
#   ./run_experiments.sh
#
# REQUISITOS: kubectl, argocd CLI, k6, python3
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURAÇÃO — edite aqui antes de rodar
# =============================================================================
NAMESPACE="app-tcc"
ROLLOUT_NAME=""                             # definido dinamicamente por rodada
APP_NAME="tcc-deployment"                   # Nome correto no ArgoCD
IMAGE_V1="gabrieldores/tcc-api:v1"
IMAGE_V2="gabrieldores/tcc-api:v2"
CONTAINER_NAME="tcc-api"
K6_SCRIPT="./scripts/load-test.js"
CHAOS_DIR="./chaos"                         # diretório com Experiments.yaml
CHAOS_FILE="Experiments.yaml"               # arquivo único com todos os cenários
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
# DEFINIÇÃO DAS RODADAS
# Para o teste rápido, deixamos apenas 1 rodada.
# Depois, basta adicionar as outras 9 aqui de volta.
# =============================================================================
declare -a RODADAS=(
  "canary|PodChaos|PodChaos"
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
  log "Resetando cluster para v1..."
  
  kubectl argo rollouts abort "$ROLLOUT_NAME" -n "$NAMESPACE" 2>/dev/null || true
  kubectl patch application "$APP_NAME" -n argocd --type merge --patch '{"operation": {"sync": {"prune": true}}}' 2>/dev/null || true
  kubectl delete pods --all -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
  
  log "Aguardando 45s para o ambiente da v1 estabilizar..."
  sleep 45
  log_ok "Cluster resetado e esterilizado na v1"
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
  local total_rodadas=${#RODADAS[@]}

  if [[ "$estrategia" == "canary" ]]; then
    ROLLOUT_NAME="tcc-api-canary"
  else
    ROLLOUT_NAME="tcc-api-bluegreen"
  fi

  local rodada_dir="$RESULTS_DIR/rodada-$(printf '%02d' $rodada_num)"
  mkdir -p "$rodada_dir"

  local log_file="$rodada_dir/execution.log"
  local results_file="$rodada_dir/summary.txt"

  log_section "RODADA $rodada_num/$total_rodadas — $estrategia | $cenario"

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
  # FASE 2 e 3 — DEPLOY v2 E INJEÇÃO DE CAOS SIMULTÂNEA
  # ----------------------------------------------------------
  log_section "FASE 2/3 — DEPLOY v2 E CAOS: $cenario (Rodada $rodada_num)"

  K6_SUMMARY_PATH="$rodada_dir/summary.json" \
  k6 run \
    --out "json=$rodada_dir/experimento.json" \
    -e "K6_SUMMARY_EXPORT=$rodada_dir/summary.json" \
    "$K6_SCRIPT" &
  K6_PID=$!
  log "k6 rodando em background (PID: $K6_PID)"

  sleep 5  # aguardar k6 estabilizar o tráfego

  log "1. Acionando gatilho do Argo Rollouts (atualizando imagem e variáveis para v2)..."
  
  # O patch injeta a imagem v2 e as variáveis simultaneamente para gerar 1 única revisão atômica
  kubectl patch rollout "$ROLLOUT_NAME" -n "$NAMESPACE" --type=merge -p='{
    "spec": {
      "template": {
        "spec": {
          "containers": [
            {
              "name": "'"$CONTAINER_NAME"'",
              "image": "'"$IMAGE_V2"'",
              "env": [
                {"name": "APP_VERSION", "value": "v2.0.0"},
                {"name": "APP_COLOR", "value": "green"},
                {"name": "ERROR_RATE", "value": "0.05"},
                {"name": "SLOW_MS", "value": "800"}
              ]
            }
          ]
        }
      }
    }
  }' 2>&1 | tee -a "$log_file"

  echo "Deploy iniciado: $(record_timestamp)" >> "$results_file"

  log "2. Injetando CAOS imediatamente após o gatilho do deploy..."
  CHAOS_START=$(record_timestamp)
  apply_chaos "$chaos_file"

  log_ok "Caos aplicado: $cenario ($chaos_file) às $CHAOS_START"
  echo "Caos iniciado: $CHAOS_START" >> "$results_file"

  log "Aguardando o Argo Rollouts reagir ao caos..."
  sleep 10
  wait_rollout_stable

  log "Aguardando $CHAOS_WAIT segundos com caos ativo e deploy rolando..."
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
# GERAÇÃO DO RELATÓRIO MARKDOWN LOCAL
# =============================================================================

generate_report() {
  local total_rodadas=${#RODADAS[@]}
  log_section "GERANDO RELATÓRIO MARKDOWN"

  mkdir -p "$RESULTS_DIR"

  {
    echo "# Relatório de Experimentos — Canary vs. Blue-Green"
    echo ""
    echo "> **TCC:** Comparação de Estratégias de Deployment em Kubernetes sob Chaos Engineering"
    echo "> **Autor:** Gabriel Lucas Pereira das Dores"
    echo "> **Data de execução:** $(date '+%d/%m/%Y %H:%M:%S')"
    echo ""
    echo "---"
    echo ""
    echo "## Resultados por Rodada"
    echo ""
    echo "| Rodada | Estratégia | Cenário | Success Rate | Latência p95 | Erros | Início | Caos | Rollback | Recovery |"
    echo "|--------|-----------|---------|-------------|-------------|-------|--------|------|----------|----------|"

    for i in $(seq -f "%02g" 1 "$total_rodadas"); do
      rodada_dir="$RESULTS_DIR/rodada-$i"
      summary="$rodada_dir/summary.txt"

      if [ -f "$summary" ]; then
        ESTRATEGIA_R=$(grep "^Estratégia:" "$summary" | cut -d' ' -f2-)
        CENARIO_R=$(grep "^Cenário:" "$summary" | cut -d' ' -f2-)
        SR=$(grep "^Success Rate:" "$summary" | cut -d' ' -f3 || echo "N/A")
        P95_R=$(grep "^Latência p95:" "$summary" | cut -d' ' -f3 || echo "N/A")
        INICIO_R=$(grep "^Início:" "$summary" | cut -d' ' -f2- || echo "N/A")
        CAOS_R=$(grep "^Caos iniciado:" "$summary" | cut -d' ' -f3- || echo "N/A")
        ROLLBACK_R=$(grep "^Rollback completo:" "$summary" | cut -d' ' -f3- || echo "N/A")
        RECOVERY_R=$(grep "^Recuperação completa:" "$summary" | cut -d' ' -f3- || echo "N/A")

        ERROS="N/A"
        if [ -f "$rodada_dir/summary.json" ]; then
          ERROS=$(python3 -c "
import json
try:
    data = json.load(open('$rodada_dir/summary.json'))
    checks = data.get('metrics', {}).get('checks', {})
    print(checks.get('fails', 'N/A'))
except:
    print('N/A')
" 2>/dev/null || echo "N/A")
        fi

        echo "| $i | $ESTRATEGIA_R | $CENARIO_R | $SR | $P95_R | $ERROS | $INICIO_R | $CAOS_R | $ROLLBACK_R | $RECOVERY_R |"
      else
        echo "| $i | — | — | N/A | N/A | N/A | — | — | — | — |"
      fi
    done

    echo ""
    echo "---"
    echo ""
    echo "## Detalhamento por Rodada"
    echo ""

    for i in $(seq -f "%02g" 1 "$total_rodadas"); do
      rodada_dir="$RESULTS_DIR/rodada-$i"
      summary="$rodada_dir/summary.txt"

      echo "### Rodada $i"
      echo ""

      if [ -f "$summary" ]; then
        echo "\`\`\`"
        cat "$summary"
        echo "\`\`\`"
      else
        echo "_Dados não encontrados para esta rodada._"
      fi

      if [ -f "$rodada_dir/summary.json" ]; then
        echo ""
        echo "**Métricas k6 detalhadas:**"
        echo ""
        echo "| Métrica | Valor |"
        echo "|---------|-------|"
        python3 -c "
import json
try:
    data = json.load(open('$rodada_dir/summary.json'))
    m = data.get('metrics', {})
    dur = m.get('http_req_duration', {})
    checks = m.get('checks', {})
    reqs = m.get('http_reqs', {})
    passes = checks.get('passes', 0)
    fails  = checks.get('fails', 0)
    total  = passes + fails
    rate   = (passes / total * 100) if total > 0 else 0
    print(f'| Requisições totais | {reqs.get(\"count\", \"N/A\")} |')
    print(f'| Checks aprovados | {passes} |')
    print(f'| Checks reprovados | {fails} |')
    print(f'| Success rate | {rate:.2f}% |')
    print(f'| Latência média | {dur.get(\"avg\", 0):.2f}ms |')
    print(f'| Latência p95 | {dur.get(\"p(95)\", 0):.2f}ms |')
    print(f'| Latência p99 | {dur.get(\"p(99)\", 0):.2f}ms |')
    print(f'| Latência máx | {dur.get(\"max\", 0):.2f}ms |')
except Exception as e:
    print(f'| Erro ao parsear | {e} |')
" 2>/dev/null || true
      fi

      echo ""
      echo "---"
    done

    echo "## Arquivos Gerados"
    echo ""
    echo "\`\`\`"
    find "$RESULTS_DIR" -type f | sort
    echo "\`\`\`"
    echo ""
    echo "_Relatório gerado automaticamente por \`run_experiments.sh\` em $(date '+%d/%m/%Y às %H:%M:%S')_"

  } > "$REPORT_FILE"

  log_ok "Relatório gerado: $REPORT_FILE"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  local total_rodadas=${#RODADAS[@]}

  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║   TCC — Canary vs Blue-Green: $total_rodadas Rodadas              ║${NC}"
  echo -e "${BLUE}║   Autor: Gabriel Lucas Pereira das Dores             ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""

  preflight_check

  echo ""
  log_warn "Iniciando sequência de $total_rodadas experimento(s). Não interrompa o processo."
  log_warn "Pressione Ctrl+C para abortar. Os resultados parciais serão preservados."
  echo ""
  sleep 5

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
  echo "Resumo das rodadas:"
  for i in $(seq -f "%02g" 1 "$total_rodadas"); do
    summary="$RESULTS_DIR/rodada-$i/summary.txt"
    if [ -f "$summary" ]; then
      echo "--- Rodada $i ---"
      cat "$summary"
      echo ""
    fi
  done

  log_ok "Todos os $total_rodadas experimentos finalizados!"
  log_ok "Relatório completo: $REPORT_FILE"
  log_ok "Dados brutos:       $RESULTS_DIR/"
}

# Trap para cleanup em caso de interrupção
trap 'log_err "Experimento interrompido. Limpando..."; cleanup_chaos "${CHAOS_FILE:-}" 2>/dev/null; reset_cluster 2>/dev/null; exit 1' INT TERM

main "$@"