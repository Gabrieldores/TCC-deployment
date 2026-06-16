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
  log "