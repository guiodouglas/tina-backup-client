#!/usr/bin/env bash
# Instala o backup-client 2.0 em /opt/backup-client, do zero.
#
# Uso (como root, a partir da pasta do pacote):
#   scripts/instalar.sh [--agendamento "M H * * DIAS"] [--senha-banco-stdin]
#   scripts/instalar.sh --atualizar   (troca só o código; mantém .env, listas, logs, fila e o horário do backup)
# Nos dois casos garante a linha do monitor contínuo no crontab (a cada 5 minutos).
#
# Se já existir uma instalação: guarda cópia em /root, aproveita só os valores
# necessários do .env antigo (sem exibir), backup_sources.txt e backup_excludes.txt,
# e apaga todo o resto (logs, estado, código antigo).
set -euo pipefail

DESTINO=/opt/backup-client
PACOTE="$(cd "$(dirname "$0")/.." && pwd)"
AGENDAMENTO=""; SENHA_STDIN=nao; ATUALIZAR=nao
while [ $# -gt 0 ]; do
  case "$1" in
    --agendamento) AGENDAMENTO="$2"; shift ;;
    --senha-banco-stdin) SENHA_STDIN=sim ;;
    --atualizar) ATUALIZAR=sim ;;
    *) echo "Opção desconhecida: $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$(id -u)" = 0 ] || { echo "Rode como root" >&2; exit 1; }

# Monitor contínuo: a cada 5 minutos (padrão em todo servidor; 2.1).
garantir_monitor_no_crontab() {
  local linha="*/5 * * * * root $DESTINO/scripts/monitor.sh"
  if ! grep -qE "^[^#].*$DESTINO/scripts/monitor\.sh" /etc/crontab; then
    cp -p /etc/crontab "/etc/crontab.bkp-$(date +%Y%m%d-%H%M)"
    printf '%s\n' "$linha" >> /etc/crontab
  fi
  echo "crontab: $(grep -E "^[^#].*$DESTINO/scripts/monitor\.sh" /etc/crontab)"
}
[ "$PACOTE" != "$DESTINO" ] || { echo "Rode a partir da pasta do pacote, não de $DESTINO" >&2; exit 1; }

if [ "$ATUALIZAR" = sim ]; then
  [ -f "$DESTINO/.env" ] || { echo "Não há instalação em $DESTINO para atualizar" >&2; exit 1; }
  ANTES="$(cat "$DESTINO/VERSION" 2>/dev/null || echo ?)"
  rm -rf -- "$DESTINO/scripts" "$DESTINO/lib"
  rm -f -- "$DESTINO/docker-compose.yml"   # saiu na 2.0.4 (rclone com docker run)
  cp -R "$PACOTE/VERSION" "$PACOTE/scripts" "$PACOTE/lib" "$PACOTE/.env.example" "$DESTINO/"
  rm -f "$DESTINO/scripts/instalar.sh"
  chmod 755 "$DESTINO/scripts/"*.sh
  garantir_monitor_no_crontab
  echo "atualizado: backup-client $ANTES -> $(cat "$DESTINO/VERSION") (.env, listas, logs, fila e crontab mantidos)"
  exit 0
fi

SENHA=""
if [ "$SENHA_STDIN" = sim ]; then
  IFS= read -r SENHA || true
  [ -n "$SENHA" ] || { echo "Senha do banco não recebida pela entrada padrão" >&2; exit 1; }
fi

TMP="$(mktemp -d)"; chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

# Valores do .env antigo que continuam valendo (linhas copiadas como estão).
MANTIDAS='^(SERVER_NAME|TZ|RCLONE_REMOTE|RCLONE_TEAM_DRIVE_(SEGUNDA|TERCA|QUARTA|QUINTA|SEXTA)|RCLONE_CONFIG_GDRIVE_[A-Z_]+|FTP_BACKUP_(HOST|PORT|USER|PASSWORD|REMOTE_DIR)|TINA_DB_(HOST|PORT|NAME|SSLMODE)|BACKUP_ARCHIVE_DIR|LOG_RETENTION_DAYS)='

if [ -d "$DESTINO" ]; then
  COPIA="/root/backup-client-antigo-$(date +%Y%m%d-%H%M).tar.gz"
  tar -C / -czf "$COPIA" "${DESTINO#/}"
  chmod 600 "$COPIA"
  echo "cópia da instalação anterior: $COPIA"
  [ -f "$DESTINO/.env" ] && grep -E "$MANTIDAS" "$DESTINO/.env" > "$TMP/env.mantido" || true
  for f in backup_sources.txt backup_excludes.txt; do
    [ -f "$DESTINO/$f" ] && cp -p "$DESTINO/$f" "$TMP/$f"
  done
  rm -rf -- "$DESTINO"
fi

mkdir -p "$DESTINO"
cp -R "$PACOTE/VERSION" "$PACOTE/scripts" "$PACOTE/lib" "$PACOTE/.env.example" "$DESTINO/"
[ -f "$PACOTE/README.md" ] && cp "$PACOTE/README.md" "$DESTINO/"
rm -f "$DESTINO/scripts/instalar.sh"
mkdir -p "$DESTINO/logs" "$DESTINO/tmp" "$DESTINO/fila"
chmod 700 "$DESTINO/fila" "$DESTINO/tmp"
chmod 755 "$DESTINO/scripts/"*.sh

for f in backup_sources.txt backup_excludes.txt; do
  if [ -f "$TMP/$f" ]; then cp -p "$TMP/$f" "$DESTINO/$f"; else : > "$DESTINO/$f"; fi
done

# .env novo: cabeçalho, valores mantidos e o usuário do banco novo.
if [ -s "$TMP/env.mantido" ]; then
  {
    echo "# backup-client $(cat "$PACOTE/VERSION"): gerado em $(date '+%d/%m/%Y %H:%M') a partir da instalação anterior."
    echo "# Modelo documentado: .env.example"
    cat "$TMP/env.mantido"
    grep -q '^TINA_DB_PORT=' "$TMP/env.mantido" || echo "TINA_DB_PORT=54323"
    grep -q '^TINA_DB_NAME=' "$TMP/env.mantido" || echo "TINA_DB_NAME=tina"
    echo "TINA_DB_USER=backup_client"
    echo "TINA_DB_PASSWORD=$SENHA"
  } > "$DESTINO/.env"
else
  cp "$PACOTE/.env.example" "$DESTINO/.env"
  [ -n "$SENHA" ] && sed -i "s|^TINA_DB_PASSWORD=.*|TINA_DB_PASSWORD=$SENHA|" "$DESTINO/.env"
  echo "ATENÇÃO: .env novo criado a partir do modelo; preencha os valores do servidor."
fi
chmod 600 "$DESTINO/.env"
echo ".env: $(grep -cE '^[A-Z_]+=' "$DESTINO/.env") chaves ($(grep -oE '^[A-Z_]+' "$DESTINO/.env" | tr '\n' ' '))"

# Crontab: uma linha só, com o horário pedido.
if [ -n "$AGENDAMENTO" ]; then
  cp -p /etc/crontab "/etc/crontab.bkp-$(date +%Y%m%d-%H%M)"
  LINHA="$AGENDAMENTO root $DESTINO/scripts/backup.sh --agendado"
  if grep -qE "^[^#].*$DESTINO/scripts/backup\.sh" /etc/crontab; then
    sed -i -E "s|^[^#].*$DESTINO/scripts/backup\.sh.*$|$LINHA|" /etc/crontab
  else
    printf '\n# backup-client (TINA)\n%s\n' "$LINHA" >> /etc/crontab
  fi
  echo "crontab: $(grep -E "^[^#].*$DESTINO/scripts/backup\.sh" /etc/crontab)"
fi
garantir_monitor_no_crontab
echo "instalado: backup-client $(cat "$DESTINO/VERSION") em $DESTINO"
