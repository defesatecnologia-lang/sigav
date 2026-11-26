# Manual de Operação — SIGAV

Este documento reúne os comandos principais para desenvolvimento, teste de hardening, produção e manutenção Docker.

---

## 1. Visão Rápida dos Docker Compose

| Arquivo | Finalidade | TLS | Hardening |
|---------|------------|-----|-----------|
| `docker-compose.local.yml` | **Desenvolvimento local** (padrão) | ❌ HTTP :3000 | ❌ Básico |
| `docker-compose.staging.yml` | **Overlay hardening** (sobe em cima do local) | ❌ HTTP :3000 | ✅ Completo |
| `docker-compose.yml` | **Produção** (domínio real + Let's Encrypt) | ✅ HTTPS :443 | ✅ Completo |
| `docker-compose.prod.yml` | **Produção Swarm/disco local** (secrets externos, bind mounts `/opt/app`) | ✅ HTTPS :443 | ✅ Completo |
| `docker-compose.preprod.yml` | **Overlay de ensaio pré-produção** (sobe em cima do prod, TLS interno por IP) | ✅ HTTPS interno | ✅ Completo |
| `docker-compose.monitoring.yml` | **Observabilidade** (Prometheus, Grafana, Loki, Promtail, node-exporter) | — | — |

---

## 2. Desenvolvimento Local (sem hardening)

### Pré-requisitos

```bash
# 1. Copiar e editar variáveis
cp .env.local.example .env.local
# Editar .env.local:
#   ADMIN_PASSWORD=<openssl rand -base64 32>
#   JWT_SECRET=<openssl rand -base64 32>
#   ADMIN_EMAIL=admin@empresa.local (opcional)
#   ADMIN_USERNAME=admin (opcional)
```

### Subir ambiente

```bash
docker compose --env-file .env.local -f docker-compose.local.yml up -d --build

docker compose -f docker-compose.prod.yml -f docker-compose.preprod.yml up -d --build
```

Ou em duas etapas (build e depois subir):

```bash
docker compose -f docker-compose.local.yml --env-file .env.local build
docker compose -f docker-compose.local.yml --env-file .env.local up -d
```

### Acessar

- **Frontend + API unificada:** http://localhost:3000
- **Backend direto (Swagger):** http://localhost:8080/api/swagger (se `SWAGGER_ENABLED=true`)
- **Frontend direto:** http://localhost:3333

### Parar e limpar

```bash
docker compose --env-file .env.local -f docker-compose.local.yml down
# Para apagar banco de dados (reset total):
docker compose --env-file .env.local -f docker-compose.local.yml down -v
```

---

## 3. Testar Hardening Localmente (valida config de produção)

O `docker-compose.staging.yml` é um **overlay** — sobe **em cima** do `docker-compose.local.yml`, aplicando:

- `read_only: true` + `tmpfs` nos 3 serviços
- `cap_drop: ALL` (+ `NET_BIND_SERVICE` no Caddy)
- `security_opt: [no-new-privileges:true, seccomp=./docker/seccomp/default.json]`
- `pids_limit: 512` + limites de CPU/memória (`deploy.resources`)
- `logging: json-file` com rotação (10m × 5)
- Rede `internal: true` (sem internet nos containers)

### Subir com hardening

```bash
docker compose --env-file .env.local \
  -f docker-compose.local.yml \
  -f docker-compose.staging.yml \
  up -d --build
```

### Acessar

- **Frontend + API unificada:** http://localhost:3000

### Validar hardening aplicado

```bash
# Verificar read_only, capabilities, seccomp, pids_limit
docker inspect controle-videos-local-backend | grep -A5 '"ReadOnly\|CapDrop\|CapAdd\|SecurityOpt\|PidsLimit"'

# Verificar se rede é internal
docker network inspect controle-videos-local | grep -A2 '"Internal"'

# Verificar logs com rotação
docker logs controle-videos-local-backend 2>&1 | head -5
```

### Parar

```bash
docker compose --env-file .env.local \
  -f docker-compose.local.yml \
  -f docker-compose.staging.yml \
  down
```

---

## 4. Produção (domínio real + Let's Encrypt)

### Variáveis obrigatórias

```bash
export DOMAIN=seu-dominio.com
export ACME_EMAIL=voce@email.com
export ADMIN_EMAIL=admin@email.com
export ADMIN_PASSWORD=$(openssl rand -base64 32)
export JWT_SECRET=$(openssl rand -base64 32)
# Opcionais:
export CORS_ORIGIN=https://${DOMAIN}
export API_URL=https://${DOMAIN}/api
```

### Subir

```bash
docker compose up -d --build
```

### Acessar

- **HTTPS:** https://${DOMAIN}
- **Healthcheck:** https://${DOMAIN}/api/health

### Modo acesso por IP (sem domínio / homologação)

```bash
export CADDYFILE=ip
export ADMIN_EMAIL=admin@empresa.local
export ADMIN_PASSWORD=$(openssl rand -base64 32)
export JWT_SECRET=$(openssl rand -base64 32)
export CORS_ORIGIN=http://192.168.1.50
export API_URL=http://192.168.1.50/api
docker compose up -d --build
# Acessar: http://192.168.1.50:3000 (ou porta 80 se Caddyfile.ip usa :80)
```

Ver guia completo em `docs/operacional/DEPLOY.md` e `docs/PLANO-DOMINIO.md`.

---

## 5. Produção com Docker Swarm / RAID6 externo (`/mnt/sstv-sigav`)

Usa `docker-compose.prod.yml` com:

- **Secrets file-based** (arquivos 0600 em `./scripts/secrets`, lidos via `*_FILE`): `domain`, `acme_email`, `admin_email`, `admin_username`, `admin_password`, `jwt_secret`, `smtp_password`
- **Bind mounts** para `/mnt/sstv-sigav` (RAID6 externo; host = container via `DATA_ROOT`)
- **UID/GID 1002:1002** consistente host↔container

> O nome de apresentação do sistema é **SIGAV**. Os nomes `controle-share-videos*`
> (diretório do repo, arquivos compose, containers, volumes e secrets) são
> internos e foram mantidos de propósito para não quebrar o sistema — não os
> renomeie sem atualizar compose, scripts, mounts e healthchecks.

### Pré-deploy no host (executar antes do `up`)

```bash
# 1. O RAID6 precisa estar montado ANTES de criar os diretórios —
#    caso contrário o Docker cria tudo como root no disco raiz.
sudo mountpoint -q /mnt/sstv-sigav || { echo "RAID6 não montado — abortando"; exit 1; }

# 2. Diretórios persistidos (banco, uploads, auditoria WORM e imagens do frontend)
sudo mkdir -p /mnt/sstv-sigav/{images,uploads/_temp,audit-worm}

# 3. Permissões: host 1002:1002 = usuário controle-user do container
sudo chown -R 1002:1002 /mnt/sstv-sigav
sudo chmod 750 /mnt/sstv-sigav

# 4. Secrets em arquivo (valores NOVOS — nunca reutilize .env.local).
#    `external: true` só funciona em Swarm/`docker stack deploy`; com
#    `docker compose up` falha com "unsupported external secret".
mkdir -p scripts/secrets && chmod 700 scripts/secrets
printf '%s' 'admin@empresa.local' > scripts/secrets/admin_email
printf '%s' 'admin'               > scripts/secrets/admin_username
openssl rand -base64 48          > scripts/secrets/admin_password
openssl rand -base64 48          > scripts/secrets/jwt_secret
printf '%s' '10.10.10.153'        > scripts/secrets/domain
printf '%s' 'admin@empresa.local' > scripts/secrets/acme_email
printf '%s' '<senha-smtp>'        > scripts/secrets/smtp_password
chmod 644 scripts/secrets/*   # o Docker preserva o mode no mount; containers leem como 1002/caddy

# 5. Copiar o .env e subir a stack em LAN sem domínio
cp .env /opt/sistemas/sigav/.env
chmod 600 /opt/sistemas/sigav/.env
cd /opt/sistemas/sigav
docker compose -f docker-compose.prod.yml \
               -f docker-compose.lan-prod.yml up -d --build
curl -kfsS https://10.10.10.153:5000/api/health
```

> Os arquivos em `scripts/secrets/` precisam ser legíveis pelo usuário que executa `docker compose` e nunca devem ser commitados (já estão no `.gitignore` e no `.dockerignore`). `domain` e `acme_email` são exigidos pelo compose mesmo em LAN sem domínio (o Caddyfile.lan-prod não os usa). As imagens padrão são copiadas automaticamente para `/mnt/sstv-sigav/images` pelo entrypoint no primeiro boot. Após trocar qualquer secret: `docker compose ... up -d --force-recreate`.

Ver `docs/operacional/HOST-PROVISIONING-ONPREMISE.md` §5 e `docs/operacional/DEPLOY.md` §4 e §6.4.

---

## 6. Monitoramento (Opcional)

```bash
# Sobe stack de observabilidade junto com a app
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d

# Acessos (rede interna, configurar proxy ou SSH tunnel):
# Grafana:      http://localhost:3001  (admin / senha em scripts/secrets/grafana_admin_password)
# Prometheus:   http://localhost:9090
# Loki:         http://localhost:3100
```

Ver `docs/operacional/MONITORAMENTO.md`.

---

## 7. Comandos de Inspeção e Debug

```bash
# Status dos containers da stack local
docker compose --env-file .env.local -f docker-compose.local.yml ps

# Status com staging (hardening)
docker compose --env-file .env.local -f docker-compose.local.yml -f docker-compose.staging.yml ps

# Logs em tempo real
docker compose --env-file .env.local -f docker-compose.local.yml logs -f backend
docker compose --env-file .env.local -f docker-compose.local.yml logs -f frontend
docker compose --env-file .env.local -f docker-compose.local.yml logs -f caddy

# Healthcheck status
docker ps --filter name=controle-videos --format "{{.Names}}: {{.Status}}"

# Entrar no container (debug)
docker exec -it controle-videos-local-backend sh
docker exec -it controle-videos-local-frontend sh
docker exec -it controle-videos-local-caddy sh

# Verificar variáveis de ambiente ativas
docker exec controle-videos-local-backend env | grep -E 'JWT_SECRET|DATABASE_URL|ADMIN_'
```

---

## 8. Limpeza e Recuperação de Espaço Docker

> **Atenção:** Muitos comandos removem dados permanentemente. Certifique-se de que não há contêineres, imagens ou volumes importantes antes de executá-los.

### Verificar uso de espaço

```bash
docker system df
```

### Limpeza seletiva (segura)

```bash
# Remover containers parados
docker container prune -f

# Remover imagens não referenciadas (dangling)
docker image prune -f

# Remover todas as imagens não usadas por containers
docker image prune -a -f

# Remover volumes não usados
docker volume prune -f

# Remover redes não usadas
docker network prune -f

# Limpar cache de build
docker builder prune -a -f
```

### Limpeza completa (apaga tudo não usado)

```bash
docker system prune -a --volumes -f
```

### Limpeza específica do projeto

```bash
# Parar e remover containers, redes, volumes do projeto local
docker compose --env-file .env.local -f docker-compose.local.yml down -v --remove-orphans

# Parar e remover projeto com staging
docker compose --env-file .env.local -f docker-compose.local.yml -f docker-compose.staging.yml down -v --remove-orphans

# Produção
docker compose down -v --remove-orphans
```

---

## 9. Backup e Restore (Produção)

```bash
# Backup manual (executa scripts/backup.sh no host)
sudo /opt/sistemas/sigav/scripts/backup.sh

# Restore test (valida backup em DB temporário)
sudo /opt/sistemas/sigav/scripts/restore-test.sh

# Ver integridade do SQLite (host = container no compose.prod)
sqlite3 /mnt/sstv-sigav/controle-videos.db "PRAGMA integrity_check;"
```

Ver `docs/operacional/BACKUP_RESTORE.md`.

---

## 10. Atualização do Sistema (Produção)

```bash
cd /opt/sistemas/sigav

# 1. Backup antes de atualizar
sudo ./scripts/backup.sh

# 2. Pull + rebuild
git pull --ff-only origin main
docker compose up -d --build

# 3. Verificar saúde
docker ps --filter name=controle-share-videos --format "{{.Names}}: {{.Status}}"
docker exec controle-share-videos-backend curl -fs http://127.0.0.1:8080/api/health
```

> **Rollback:** `git checkout <tag-anterior> && docker compose up -d --build`
> Ver `docs/operacional/RUNBOOKS.md`.

---

## 11. Resumo de Comandos por Objetivo

| Objetivo | Comando |
|----------|---------|
| **Dev rápido (HTTP)** | `docker compose --env-file .env.local -f docker-compose.local.yml up -d --build` |
| **Testar hardening (HTTP)** | `docker compose --env-file .env.local -f docker-compose.local.yml -f docker-compose.staging.yml up -d --build` |
| **Produção (HTTPS + domínio)** | `DOMAIN=... ACME_EMAIL=... ADMIN_PASSWORD=... JWT_SECRET=... docker compose up -d --build` |
| **Produção IP (HTTP)** | `CADDYFILE=ip ADMIN_PASSWORD=... JWT_SECRET=... docker compose up -d --build` |
| **Produção Swarm/disco local** | `docker compose -f docker-compose.prod.yml up -d` |
| **Monitoramento** | `docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d` |
| **Parar dev** | `docker compose --env-file .env.local -f docker-compose.local.yml down` |
| **Parar dev + staging** | `docker compose --env-file .env.local -f docker-compose.local.yml -f docker-compose.staging.yml down` |
| **Parar produção** | `docker compose down` |
| **Reset total dev (apaga DB)** | `docker compose --env-file .env.local -f docker-compose.local.yml down -v` |
| **Logs backend** | `docker compose --env-file .env.local -f docker-compose.local.yml logs -f backend` |
| **Validar hardening** | `docker inspect controle-videos-local-backend \| grep -A5 '"ReadOnly\|CapDrop\|SecurityOpt\|PidsLimit"'` |
| **Ver espaço Docker** | `docker system df` |
| **Limpeza segura** | `docker system prune -f` |
| **Limpeza completa** | `docker system prune -a --volumes -f` |

---

## 12. Boas Práticas

- Execute `docker system df` antes e depois da limpeza para verificar espaço recuperado
- Utilize `docker system prune -a --volumes -f` periodicamente em ambientes de desenvolvimento
- **Não remova volumes** se eles contiverem bancos de dados ou arquivos importantes
- Antes de apagar imagens, confirme se elas não serão reutilizadas por projetos ativos
- Faça backup de dados importantes antes de realizar limpezas completas
- Em produção, **sempre faça backup antes de atualizar** (`scripts/backup.sh`)
- Valide o hardening no staging **antes** de promover para produção

---

## 13. Semântica de Views e Previews de Vídeo

Como o contador de visualizações funciona (server-side, `StreamViewCounterService` + `ShareSecurityGuard`):

| Ação | Conta view? | Observação |
|------|-------------|------------|
| Visitante abre o link e o player inicia | ✅ Sim (1 por abertura) | Incremento atômico; excedido `maxViews` → `403 share_max_views_exceeded` |
| Chunks/seeks durante o playback (`Range`) | ❌ Não | Renova sessão deslizante de 2 min do mesmo playback |
| Dono/admin pré-visualizando (listagem ou player) | ❌ Não | Ilimitado — decisão server-side (`isPrivilegedAccess`), independe do cliente |
| Download único ou ZIP | — | Conta em `downloads` (limite próprio, anti-TOCTOU) |

Notas operacionais:

- Com limites esgotados: abertura nova é bloqueada (token e stream), mas o
  playback já iniciado continua até fechar a aba (sessão de 2 min).
- O certificado de autenticidade permanece acessível mesmo com limites esgotados.
- Cada evento (sucesso/falha) aparece em `/admin/download-logs` (IP, UA, timestamp).
- Para testar: crie um share com `maxViews` baixo (ex.: 2) e abra o link público
  em navegadores/sessões anônimas diferentes.

  Para editar os slides, altere o .md e regenere:
CHROME_PATH=~/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome \
  npx @marp-team/marp-cli docs/APRESENTACAO-ANALISTA-TI.md --pdf -o docs/APRESENTACAO-ANALISTA-TI.pdf

  docker compose --env-file .env.local \
  -f docker-compose.local.yml \
  -f docker-compose.staging.yml \
  -f docker-compose.lan.yml up --build
Ou em background (sem logs no terminal):
docker compose --env-file .env.local \
  -f docker-compose.local.yml \
  -f docker-compose.staging.yml \
  -f docker-compose.lan.yml up -d --build
Acesso: https://192.168.0.246 (ou https://localhost na própria máquina). Se reiniciar o WSL antes, rode primeiro o wsl-lan-expose.ps1 no Windows.
