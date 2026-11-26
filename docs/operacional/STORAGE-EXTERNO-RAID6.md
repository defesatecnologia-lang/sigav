# Storage externo em RAID6 — `/mnt/sstv-sigav`

**Aplicável a:** produção (`docker-compose.prod.yml`) e ensaio pré-produção
(`docker-compose.preprod.yml`, que herda o compose base).
**Estado:** banco SQLite, uploads, logs de auditoria WORM e imagens do frontend
passam a viver no volume RAID6 montado no host em `/mnt/sstv-sigav`.

---

## 1. Variáveis

A única variável de infraestrutura que precisa ser ajustada é `DATA_ROOT`.
Tudo o mais é derivado dela — não altere `DATABASE_URL`/`DATA_DIRECTORY` à mão.

| Variável | Valor em produção | Onde é usada |
| --- | --- | --- |
| `DATA_ROOT` | `/mnt/sstv-sigav` (default) | bind mounts no compose, scripts de host |
| `DATABASE_URL` | `file:/mnt/sstv-sigav/controle-videos.db` | Prisma / backend |
| `DATA_DIRECTORY` | `/mnt/sstv-sigav` | uploads, `audit-worm/`, `uploads/_temp/` |
| `DATA_ROOT/images` | `/mnt/sstv-sigav/images` | imagens servidas pelo frontend (bind compartilhado) |

Layout no RAID6:

```text
/mnt/sstv-sigav/
├── controle-videos.db          # SQLite (com WAL: -wal / -shm ao lado)
├── controle-videos.db-wal
├── controle-videos.db-shm
├── uploads/
│   ├── _temp/                  # chunks em andamento
│   └── shares/<shareId>/       # vídeos + PDFs de certificado
├── audit-worm/                 # trilha de auditoria append-only
└── images/                     # imagens do frontend (backend + frontend)
```

> **Começo do zero:** não há migração de dados do antigo `/opt/app/data`. O
> banco é criado pelas migrations/seeds no primeiro boot após o provisionamento.

---

## 2. Provisionamento do host (uma vez)

### 2.1 Montar o RAID6

O dispositivo montado deve ser um **bloco local** (`/dev/md0`, por exemplo).
SQLite em modo WAL **não** suporta NFS/SMB/CIFS como storage do banco — o
locking POSIX pode quebrar e causar corrupção. Se o acervo estiver num share de
rede, mantenha-o separado (via `libraries.yaml`, ver
`docs/PLANO-STORAGE-EXTERNO.md`) e nunca aponte `DATA_ROOT` para ele.

```bash
# Confirme o array e o filesystem
lsblk -f
sudo findmnt /mnt/sstv-sigav        # tem que retornar o /dev/md*/mapper, não o disco raiz
```

Exemplo de `fstab` (com LUKS2 opcional, recomendado para cifrar em repouso):

```fstab
/dev/mapper/sigav_crypt /mnt/sstv-sigav ext4 defaults,nofail,x-systemd.device-timeout=30 0 2
```

> Se optar por LUKS, o `/etc/crypttab` e o desbloqueio no boot seguem o modelo
> de `docs/operacional/HOST-PROVISIONING-ONPREMISE.md` §4, trocando apenas o
> ponto de montagem de `/opt/app` para `/mnt/sstv-sigav`.

### 2.2 Criar diretórios e permissões

O container roda como UID/GID **1002:1002** (`create-user.sh`). Crie a árvore
**antes** do `docker compose up`, senão o Docker cria os diretórios como root:

```bash
sudo mountpoint -q /mnt/sstv-sigav || { echo "RAID6 não montado — ABORTANDO"; exit 1; }
sudo mkdir -p /mnt/sstv-sigav/images /mnt/sstv-sigav/uploads/_temp /mnt/sstv-sigav/audit-worm
sudo chown -R 1002:1002 /mnt/sstv-sigav
sudo chmod 750 /mnt/sstv-sigav
sudo findmnt -T /mnt/sstv-sigav
```

O `create-user.sh` também corrige ownership no startup, mas a checagem acima
evita escrever no disco raiz caso o mount falhe.

### 2.3 Deploy

```bash
cd /opt/controle-share-videos-v1.0
export DATA_ROOT=/mnt/sstv-sigav
docker compose -f docker-compose.prod.yml config | grep -E 'DATA_ROOT|DATABASE_URL|DATA_DIRECTORY|sstv-sigav'
docker compose -f docker-compose.prod.yml up -d --build
```

> O `scripts/deploy/deploy-prod.sh` repassa o ambiente do host ao `docker
> compose`; exporte `DATA_ROOT` no shell de deploy (ou no serviço systemd/CI)
> caso queira trocar o caminho padrão.

---

## 3. Validação pós-deploy

```bash
docker compose -f docker-compose.prod.yml exec backend \
  sh -lc 'echo "DATA_DIRECTORY=$DATA_DIRECTORY"; echo "DATABASE_URL=$DATABASE_URL"'
# DATA_DIRECTORY=/mnt/sstv-sigav
# DATABASE_URL=file:/mnt/sstv-sigav/controle-videos.db

sqlite3 /mnt/sstv-sigav/controle-videos.db "PRAGMA integrity_check;"   # ok
ls -ldn /mnt/sstv-sigav/uploads /mnt/sstv-sigav/images                 # 1002 1002
curl -fs http://127.0.0.1/api/health
```

Fazer um upload de teste e confirmar que o arquivo aparece em
`/mnt/sstv-sigav/uploads/shares/<shareId>/` e **não** em `/opt/app/data`.

---

## 4. Backup e monitoramento

Todos os scripts de host já derivam o caminho de `DATA_ROOT` (default
`/mnt/sstv-sigav`):

| Script | Caminho usado |
| --- | --- |
| `scripts/backup.sh` | `${DATA_ROOT}/controle-videos.db` |
| `scripts/backup/backup-sqlite.sh` | `${DATA_ROOT}/controle-videos.db` |
| `scripts/backup/backup-files.sh` | `${DATA_ROOT}/uploads` |
| `scripts/verify-db.sh` | `${DATA_ROOT}/controle-videos.db` |
| `scripts/backup/health-check.sh` | `df ${DATA_ROOT}` |
| `scripts/maintenance/cleanup-temp.sh` | `${DATA_ROOT}/uploads/_temp` |
| `scripts/provision/samba.sh` | `${DATA_ROOT}/uploads/shares` |
| `scripts/monitoring/alerts.yml` | alerta `DiskSpaceCritical` no mount `/mnt/sstv-sigav` |

Exemplo:

```bash
DATA_ROOT=/mnt/sstv-sigav \
NODE_ENV=production \
GPG_RECIPIENT=<chave> \
BACKUP_DIR=/opt/app/backups \
./scripts/backup.sh
```

> **RAID6 não é backup.** Mantenha o backup offsite (MinIO/S3/NAS em outro
> host) conforme `docs/operacional/BACKUP_RESTORE.md`.

---

## 5. Rollback para o disco local

Se o RAID6 precisar ser desmontado:

```bash
export DATA_ROOT=/opt/app/data
sudo mkdir -p /opt/app/data/images /opt/app/data/uploads/_temp
sudo chown -R 1002:1002 /opt/app/data && sudo chmod 750 /opt/app/data
docker compose -f docker-compose.prod.yml up -d --force-recreate
```

O banco voltará a ser criado do zero no caminho antigo; os dados gravados no
RAID6 continuam lá até decisão explícita de remoção.

---

## 6. Riscos e observações

- **Perda do mount:** o bind mount vira um diretório vazio no disco raiz e o
  backend pode recriar o banco vazio. Por isso o `mountpoint -q` no
  provisionamento é obrigatório; monitore o mount (`findmnt`) junto com o
  alerta de disco.
- **WAL no RAID6:** `controle-videos.db-wal`/`-shm` precisam estar no mesmo
  filesystem do `.db` — o compose garante isso ao montar a raiz inteira.
- **Desempenho:** RAID6 tem penalidade de escrita; manter `journal_mode=WAL`
  e discos com cache/BBU é recomendável.
- **Criptografia em repouso:** use LUKS no dispositivo do RAID6 (§2.1) para
  atender ao item de cifragem do checklist de segurança.
