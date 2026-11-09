# backup-client 2.0: funções comuns (ambiente, registro, problemas, utilidades).

RAIZ="${RAIZ:-/opt/backup-client}"
ARQUIVO_ENV="${ARQUIVO_ENV:-$RAIZ/.env}"
VERSAO="$(cat "$RAIZ/VERSION" 2>/dev/null || echo desconhecida)"

# Chaves obrigatórias do .env (só o que é próprio do servidor).
ENV_OBRIGATORIAS=(SERVER_NAME RCLONE_REMOTE
  RCLONE_TEAM_DRIVE_SEGUNDA RCLONE_TEAM_DRIVE_TERCA RCLONE_TEAM_DRIVE_QUARTA
  RCLONE_TEAM_DRIVE_QUINTA RCLONE_TEAM_DRIVE_SEXTA
  FTP_BACKUP_HOST FTP_BACKUP_PORT FTP_BACKUP_USER FTP_BACKUP_PASSWORD FTP_BACKUP_REMOTE_DIR
  TINA_DB_HOST TINA_DB_PORT TINA_DB_NAME TINA_DB_USER TINA_DB_PASSWORD)

carregar_env() {
  [ -f "$ARQUIVO_ENV" ] || { echo "ERRO: $ARQUIVO_ENV não encontrado" >&2; return 1; }
  set -a
  # shellcheck disable=SC1090
  . "$ARQUIVO_ENV"
  set +a
  DIR_TAR="${BACKUP_ARCHIVE_DIR:-/tmp/backup-client}"
  DIAS_LOG="${LOG_RETENTION_DAYS:-30}"
  TINA_DB_SSLMODE="${TINA_DB_SSLMODE:-require}"
}

# Fuso do servidor (o cron roda nele). readlink/arquivo em vez de "timedatectl show", que não existe
# nas versões antigas do systemd. Mesma lógica em instalar.sh (o instalador não carrega esta lib).
FUSO_PADRAO=America/Sao_Paulo
fuso_do_servidor() {
  local z; z="$(readlink -f /etc/localtime 2>/dev/null)"
  case "$z" in */zoneinfo/*) echo "${z#*/zoneinfo/}"; return ;; esac
  cat /etc/timezone 2>/dev/null || echo desconhecido
}

# Duração legível (mesmo formato do banco): 45 s, 3 min 9 s, 2 h 5 min, 1 dia e 3 h.
tempo() {
  local s=$1
  if [ "$s" -lt 60 ]; then echo "$s s"
  elif [ "$s" -lt 3600 ]; then echo "$((s / 60)) min$([ $((s % 60)) -gt 0 ] && echo " $((s % 60)) s")"
  elif [ "$s" -lt 86400 ]; then echo "$((s / 3600)) h$([ $((s % 3600 / 60)) -gt 0 ] && echo " $((s % 3600 / 60)) min")"
  else echo "$((s / 86400)) dia$([ $((s / 86400)) -gt 1 ] && echo s)$([ $((s % 86400 / 3600)) -gt 0 ] && echo " e $((s % 86400 / 3600)) h")"
  fi
}

agora_iso() { date +%Y-%m-%dT%H:%M:%S.%3N%:z; }

iniciar_log() {
  DIR_LOG="$RAIZ/logs/$(date +%Y-%m-%d)"
  mkdir -p "$DIR_LOG"
  LOG="$DIR_LOG/backup.log"
}

log() {
  local nivel="$1"; shift
  printf '%s [%s] %s\n' "$(agora_iso)" "$nivel" "$*" | tee -a "${LOG:-/dev/null}" >&2
}
info() { log INFO "$@"; }
aviso() { log AVISO "$@"; }
erro() { log ERRO "$@"; }

# Problemas da execução: lista fechada de códigos (contrato v1.1, seção 4).
PROBLEMAS_JSON='[]'
problema() {
  local codigo="$1" gravidade="$2" etapa="$3" mensagem="$4"
  PROBLEMAS_JSON="$(jq -c --arg c "$codigo" --arg g "$gravidade" --arg e "$etapa" --arg m "$mensagem" \
    '. + [{codigo: $c, gravidade: $g, etapa: $e, mensagem: $m}]' <<<"$PROBLEMAS_JSON")"
  case "$gravidade" in
    CRITICO) erro "$codigo: $mensagem" ;;
    ATENCAO) aviso "$codigo: $mensagem" ;;
    *) info "$codigo: $mensagem" ;;
  esac
}

status_da_execucao() {
  jq -r 'if any(.[]; .gravidade == "CRITICO") then "CRITICO"
         elif any(.[]; .gravidade == "ATENCAO") then "ATENCAO" else "OK" end' <<<"$PROBLEMAS_JSON"
}

# Slot do dia (segunda a sexta). Fim de semana: sem slot.
slot_do_dia() {
  case "$(date +%u)" in
    1) echo segunda ;; 2) echo terca ;; 3) echo quarta ;; 4) echo quinta ;; 5) echo sexta ;;
    *) return 1 ;;
  esac
}

drive_do_slot() {
  case "$1" in
    segunda) echo "${RCLONE_TEAM_DRIVE_SEGUNDA:-}" ;;
    terca)   echo "${RCLONE_TEAM_DRIVE_TERCA:-}" ;;
    quarta)  echo "${RCLONE_TEAM_DRIVE_QUARTA:-}" ;;
    quinta)  echo "${RCLONE_TEAM_DRIVE_QUINTA:-}" ;;
    sexta)   echo "${RCLONE_TEAM_DRIVE_SEXTA:-}" ;;
    *) return 1 ;;
  esac
}

# Agendamento lido do próprio crontab (fonte única do horário).
agendamento_crontab() {
  {
    grep -hE '^[^#].*/opt/backup-client/scripts/backup\.sh' /etc/crontab /etc/cron.d/* 2>/dev/null \
      | awk '{print $1, $2, $3, $4, $5}'
    crontab -l -u root 2>/dev/null | grep -E '^[^#].*/opt/backup-client/scripts/backup\.sh' \
      | awk '{print $1, $2, $3, $4, $5}'
  } | head -1
}

# Arquivo de configuração do curl com a senha do FTP (não aparece na lista de processos).
curl_cfg_ftp() {
  printf 'user = "%s:%s"\n' "$FTP_BACKUP_USER" "$FTP_BACKUP_PASSWORD"
}

url_ftp() {
  local dir="${FTP_BACKUP_REMOTE_DIR%/}"
  printf 'ftp://%s:%s%s/%s' "$FTP_BACKUP_HOST" "$FTP_BACKUP_PORT" "$dir" "$1"
}
