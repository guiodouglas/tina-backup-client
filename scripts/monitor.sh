#!/usr/bin/env bash
# Monitor contínuo (backup-client 2.1): a cada 5 minutos (crontab), envia ao banco da TINA o
# estado atual do servidor: disco e inodes, memória em uso e containers. Leve e sem IA:
# quem decide limites, confirmação e alertas é o banco (ingest.registrar_monitor).
#
# Uso: monitor.sh [--dry-run]   (--dry-run mostra o documento sem enviar)
set -uo pipefail

RAIZ="${RAIZ:-/opt/backup-client}"
# shellcheck disable=SC1091
. "$RAIZ/lib/comum.sh"
carregar_env || exit 1

SIMULAR=nao
[ "${1:-}" = --dry-run ] && SIMULAR=sim

# Uma checagem por vez (se a anterior travou, esta não se acumula).
mkdir -p "$RAIZ/tmp"
exec 8>"$RAIZ/tmp/monitor.lock"
flock -n 8 || exit 0

LOG_MONITOR="$RAIZ/logs/$(date +%Y-%m-%d)/monitor.log"
mkdir -p "$(dirname "$LOG_MONITOR")"
registrar() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG_MONITOR"; }

FILTRO_DF=(-x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs)
discos="$(df -P "${FILTRO_DF[@]}" 2>/dev/null | awk 'NR > 1 { gsub("%", "", $5); if ($5 ~ /^[0-9]+$/)
  printf "{\"ponto\":\"%s\",\"percentual\":%s}\n", $6, $5 }' | jq -s -c . 2>/dev/null)"
inodes="$(df -Pi "${FILTRO_DF[@]}" 2>/dev/null | awk 'NR > 1 { gsub("%", "", $5); if ($5 ~ /^[0-9]+$/)
  printf "{\"ponto\":\"%s\",\"percentual\":%s}\n", $6, $5 }' | jq -s -c . 2>/dev/null)"
memoria="$(awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2} END { if (t) printf "%.2f", (t - a) * 100 / t }' /proc/meminfo)"

# Containers: sem resposta do Docker, a lista não vai (o banco então não conclui nada sobre eles).
containers=""
if timeout 30 docker info >/dev/null 2>&1; then
  ids="$(timeout 30 docker ps -aq 2>/dev/null)"
  if [ -z "$ids" ]; then
    containers='[]'
  else
    # shellcheck disable=SC2086
    containers="$(timeout 60 docker inspect $ids 2>/dev/null | jq -c '[.[] | {nome: (.Name | ltrimstr("/")),
      estado: .State.Status, saude: (.State.Health.Status // null), reinicios: .RestartCount}]' 2>/dev/null)"
  fi
fi

# Boot (para o banco saber se o servidor reiniciou) e reinícios agendados no crontab (reboot ou
# shutdown -r), para separar reinício programado de reinício sem planejamento.
ligado_desde="$(date -d "$(uptime -s)" +%Y-%m-%dT%H:%M:%S%:z 2>/dev/null)"
programados="$( { grep -hE '^[^#]' /etc/crontab /etc/cron.d/* 2>/dev/null | awk '{ $6 = ""; print }'
                  crontab -l -u root 2>/dev/null | grep -E '^[^#]'; } \
  | grep -E '(^|[ /])(reboot|shutdown[^;|&]*-r)' | awk '{ print $1, $2, $3, $4, $5 }' | sort -u | jq -R . | jq -s -c .)"

# Envios que não chegaram ao banco: o primeiro horário e quantos. Vão no próximo envio que
# chegar, para o banco saber que o servidor estava ligado (o problema era a conexão).
SEM_ENVIO="$RAIZ/tmp/monitor-sem-envio"
desde=""; perdidos=0
[ -s "$SEM_ENVIO" ] && read -r desde perdidos < "$SEM_ENVIO"

doc="$(jq -n -c --arg versao "$VERSAO" --arg nome "$SERVER_NAME" --arg host "$(hostname -f 2>/dev/null || hostname)" \
  --arg em "$(agora_iso)" --arg discos "${discos:-}" --arg inodes "${inodes:-}" --arg mem "${memoria:-}" \
  --arg cont "${containers:-}" --arg desde "$desde" --argjson perdidos "${perdidos:-0}" \
  --arg boot "${ligado_desde:-}" --argjson prog "${programados:-[]}" '
  {formato: 1, app_versao: $versao, servidor: {nome: $nome, hostname: $host}, coletado_em: $em,
   reinicios_programados: $prog}
  + (if $boot != "" then {ligado_desde: $boot} else {} end)
  + (if $desde != "" then {sem_conexao_desde: $desde, envios_perdidos: $perdidos} else {} end)
  + (if $discos != "" then {disco: ($discos | fromjson)} else {} end)
  + (if $inodes != "" then {inodes: ($inodes | fromjson)} else {} end)
  + (if $mem != "" then {memoria_percentual: ($mem | tonumber)} else {} end)
  + (if $cont != "" then {containers: ($cont | fromjson)} else {} end)')"

if [ "$SIMULAR" = sim ]; then
  echo "$doc" | jq .
  exit 0
fi

arq="$RAIZ/tmp/monitor.json"
printf '%s\n' "$doc" > "$arq"
enviar() {
  { printf '\\set doc `cat %q`\n' "$arq"; echo "SELECT ingest.registrar_monitor(:'doc'::jsonb);"; } \
    | PGPASSWORD="$TINA_DB_PASSWORD" PGCONNECT_TIMEOUT=15 timeout 60 psql -X -q -t -A -v ON_ERROR_STOP=1 \
        "host=$TINA_DB_HOST port=$TINA_DB_PORT dbname=$TINA_DB_NAME user=$TINA_DB_USER sslmode=$TINA_DB_SSLMODE" 2>&1
}

# Até 3 tentativas (uma queda curta da rede não vira "sem sinal"); cabe nos 5 minutos.
entregue=nao
for tentativa in 1 2 3; do
  if resposta="$(enviar)"; then entregue=sim; break; fi
  [ $tentativa -lt 3 ] && sleep 20
done
if [ "$entregue" = sim ]; then
  rm -f "$SEM_ENVIO"
  registrar "ok$([ $tentativa -gt 1 ] && echo " (na tentativa $tentativa)")$([ -n "$desde" ] && echo " (sem conexão desde $desde, $perdidos envio(s) perdido(s))")$([ -z "$containers" ] && echo " (sem lista de containers: docker não respondeu)")"
else
  printf '%s %s\n' "${desde:-$(agora_iso)}" "$((perdidos + 1))" > "$SEM_ENVIO"
  registrar "falha ao enviar (3 tentativas): $(echo "$resposta" | tail -1 | cut -c1-200)"
  exit 1
fi
