#!/usr/bin/env bash
# =============================================================================
# deploy-prod.sh — Deploy automático do Controle Share Videos (single-host)
# =============================================================================
# Executado NO HOST de produção via SSH pelo GitHub Actions (job `deploy` do
# .github/workflows/ci.yml). Faz: git fetch → backup pré-deploy → checkout do
# ref alvo → docker compose build → up -d → healthcheck → rollback em falha.
#
# Uso (no host) — deploy da última main com backup pré-deploy:
#   cd /opt/controle-share-videos-v1.0 && ./scripts/deploy/deploy-prod.sh
#
# Sobrescrevendo os padrões (opcional):
#   TARGET_REF=<sha|tag|branch> \
#   APP_DIR=/opt/controle-share-videos-v1.0 \
#   COMPOSE_FILE=docker-compose.prod.yml \
#   RUN_BACKUP=0 \
#   ./scripts/deploy/deploy-prod.sh
#
# Variáveis:
#   TARGET_REF   ref a deployar (default: origin/main — sempre atualizado via fetch).
#   APP_DIR      diretório do repo no host (default /opt/controle-share-videos-v1.0).
#   COMPOSE_FILE  compose de produção (default docker-compose.prod.yml).
#   COMPOSE_FILES lista separada por espaço para múltiplos overlays, ex.:
#     "docker-compose.prod.yml docker-compose.lan-prod.yml"
#   RUN_BACKUP   1 para executar scripts/backup.sh antes do deploy (default 1).
#                Em produção exige GPG_RECIPIENT no ambiente do usuário de deploy.
#   DEPLOY_CONFIG_FILE  arquivo opcional com VAR=valor (default
#                /etc/default/sigav-deploy) carregado antes dos defaults;
#                variáveis já presentes no ambiente têm precedência.
#   BACKUP_DIR   destino do backup (repassado ao backup.sh).
#   DEPLOY_USER  dono do deploy (default "deploy"; usado p/ ownership de git).
#
# Código de saída: 0 = sucesso; 1 = falha sem rollback possível; 2 = rollback
# executado (deploy falhou, serviço voltou à versão anterior).
# =============================================================================
set -euo pipefail

# Configuração persistente do host, ex. /etc/default/sigav-deploy contendo:
#   GPG_RECIPIENT=chave-ou-email
#   BACKUP_DIR=/opt/app/backups
# O ambiente (exportado pelo CI ou pelo usuário) tem precedência sobre o arquivo.
DEPLOY_CONFIG_FILE="${DEPLOY_CONFIG_FILE:-/etc/default/sigav-deploy}"
if [ -r "${DEPLOY_CONFIG_FILE}" ]; then
  while IFS='=' read -r key value; do
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # Aceita COMPOSE_FILES="a b" (aspas do arquivo .env não devem chegar ao compose).
    case "${value}" in
      \"*\") value="${value:1:${#value}-2}" ;;
      \'*\') value="${value:1:${#value}-2}" ;;
    esac
    if [ -z "${!key+x}" ]; then
      export "${key}=${value}"
    fi
  done < "${DEPLOY_CONFIG_FILE}"
fi

TARGET_REF="${TARGET_REF:-origin/main}"
APP_DIR="${APP_DIR:-/opt/controle-share-videos-v1.0}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"
# COMPOSE_FILES aceita múltiplos arquivos (ex.: produção + overlay LAN).
# COMPOSE_FILE continua funcionando para compatibilidade com o CI atual.
COMPOSE_FILES="${COMPOSE_FILES:-${COMPOSE_FILE}}"
RUN_BACKUP="${RUN_BACKUP:-1}"
BACKUP_DIR="${BACKUP_DIR:-/opt/app/backups}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"

cd "${APP_DIR}"

read -r -a compose_files <<< "${COMPOSE_FILES}"
compose() {
  docker compose "${compose_files[@]/#/-f}" "$@"
}

if [ ! -d .git ]; then
  echo "[deploy] ERROR: ${APP_DIR} não é um repo git" >&2
  exit 1
fi

log() { printf '[deploy] %s\n' "$*"; }

# --- 1. Atualizar refs (necessário para resolver o default origin/main) ------
if ! git fetch --prune origin 2>&1 | tail -n2; then
  if [ "${TARGET_REF}" = "origin/main" ]; then
    log "ERROR: git fetch falhou — não é possível resolver origin/main" >&2
    exit 1
  fi
  log "AVISO: git fetch falhou — usando ref local ${TARGET_REF}"
fi

PREV_REF="$(git rev-parse --short HEAD)"
log "iniciando deploy de ${TARGET_REF} (atual: ${PREV_REF}) em ${APP_DIR}"

wait_for_health() {
  local retries="${HEALTH_RETRIES:-60}" interval="${HEALTH_INTERVAL:-5}"
  local i
  for i in $(seq 1 "${retries}"); do
    local backend_status
    backend_status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
      "$(compose ps -q backend 2>/dev/null | head -n1)" 2>/dev/null || echo "unknown")"
    if [ "${backend_status}" = "healthy" ]; then
      log "backend saudável (tentativa ${i})"
      return 0
    fi
    sleep "${interval}"
  done
  log "ERROR: backend não ficou saudável após ${retries} tentativas" >&2
  return 1
}

rollback() {
  log "ROLLBACK: voltando para ${PREV_REF}"
  git checkout --detach "${PREV_REF}" 2>/dev/null || git checkout --detach "origin/main"
  export APP_VERSION="$(git describe --tags --always --dirty 2>/dev/null || git rev-parse --short HEAD)"
  compose build || true
  compose up -d --remove-orphans || true
  wait_for_health || log "AVISO: healthcheck falhou após rollback — intervenção manual necessária"
  log "ROLLBACK concluído em ${PREV_REF}"
}

# --- 2. Backup pré-deploy (fail-closed quando GPG requerido) ----------------
if [ "${RUN_BACKUP}" = "1" ] && [ -f scripts/backup.sh ]; then
  log "executando backup pré-deploy (RUN_BACKUP=1)"
  if ! BACKUP_DIR="${BACKUP_DIR}" bash scripts/backup.sh; then
    log "ERROR: backup pré-deploy falhou — abortando deploy (não deploya sem backup)" >&2
    exit 1
  fi
fi

# --- 3. Resolver ref alvo ----------------------------------------------------
if git rev-parse --verify "${TARGET_REF}^{commit}" >/dev/null 2>&1; then
  TARGET_COMMIT="$(git rev-parse "${TARGET_REF}^{commit}")"
elif git rev-parse --verify "origin/${TARGET_REF}^{commit}" >/dev/null 2>&1; then
  TARGET_COMMIT="$(git rev-parse "origin/${TARGET_REF}^{commit}")"
else
  log "ERROR: ref ${TARGET_REF} não encontrado (local ou origin)" >&2
  exit 1
fi
log "ref resolvido: ${TARGET_COMMIT}"

# --- 4. Checkout do ref alvo (detached — deploy imutável) --------------------
git checkout --detach "${TARGET_COMMIT}"
TARGET_SHORT="$(git rev-parse --short HEAD)"
# A versão do rodapé é gerada em build-time e vai para o frontend via build-arg.
export APP_VERSION="$(git describe --tags --always --dirty 2>/dev/null || git rev-parse --short HEAD)"
log "checkout concluído: ${TARGET_SHORT} (versão ${APP_VERSION})"

# --- 5. Build + up -----------------------------------------------------------
log "build das imagens (${COMPOSE_FILES})..."
if ! compose build; then
  log "ERROR: build falhou" >&2
  rollback
  exit 2
fi

log "subindo serviços (${COMPOSE_FILES})..."
if ! compose up -d --remove-orphans; then
  log "ERROR: up falhou" >&2
  rollback
  exit 2
fi

# --- 6. Healthcheck ----------------------------------------------------------
if ! wait_for_health; then
  log "ERROR: healthcheck falhou — executando rollback" >&2
  rollback
  exit 2
fi

# --- 7. Saneamento pós-deploy (sem forçar migração manual) -------------------
log "verificando migrações pendentes (deploy automático no entrypoint)..."
if compose ps --format '{{.Service}}\t{{.Status}}' | grep -q "Restarting"; then
  log "AVISO: há serviço em estado Restarting — verificar docker compose -f ${COMPOSE_FILES} ps"
fi

log "deploy concluído com sucesso: ${TARGET_SHORT} (anterior: ${PREV_REF})"
exit 0
