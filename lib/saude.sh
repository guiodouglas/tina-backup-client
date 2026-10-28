# Saúde, containers e inventário: só números e fatos; quem decide os limites é o banco.

SAUDE_JSON='null'
CONTAINERS_JSON='[]'
INVENTARIO_JSON='null'

# Média e pico do dia no sysstat (sar), pela coluna de nome $2 no comando $1.
# $4 (opcional, HH:MM:SS): ignora as amostras a partir desse horário.
sar_media_pico() {
  local opcao="$1" coluna="$2" inverter="${3:-nao}" ate="${4:-99:99:99}"
  S_TIME_FORMAT=ISO LC_ALL=C sar "$opcao" 2>/dev/null | awk -v col="$coluna" -v inv="$inverter" -v opc="$opcao" -v ate="$ate" '
    /^[0-9][0-9]:/ { for (i = 1; i <= NF; i++) if ($i == col) { c = i; cab = 1 } }
    cab { cab = 0; next }
    c && /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ && (opc != "-u" || / all /) && $c ~ /^[0-9.]+$/ && $1 < ate {
      v = $c + 0; if (inv == "sim") v = 100 - v
      s += v; n++; if (n == 1 || v > m) { m = v; t = $1 }
    }
    END { if (n) printf "%.2f %.2f %d %s\n", s / n, m, n, t }'
}

coletar_saude() {
  local discos inodes mem swap carga nucleos desde cpu iow memd
  discos="$(df -P -B1 -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null | awk 'NR > 1 {
      gsub("%", "", $5); printf "{\"ponto\":\"%s\",\"total\":%s,\"usado\":%s,\"percentual\":%s}\n", $6, $2, $3, $5 }' | jq -s -c .)"
  inodes="$(df -Pi / | awk 'NR == 2 { gsub("%", "", $5); print ($5 == "-" ? "null" : $5) }')"
  mem="$(awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2} END { printf "%.2f", (t - a) * 100 / t }' /proc/meminfo)"
  swap="$(awk '/^SwapTotal:/ {t = $2} /^SwapFree:/ {f = $2} END { printf "%.2f", t ? (t - f) * 100 / t : 0 }' /proc/meminfo)"
  carga="$(awk '{ printf "[%s,%s,%s]", $1, $2, $3 }' /proc/loadavg)"
  nucleos="$(nproc)"
  desde="$(date -d "$(uptime -s)" +%Y-%m-%dT%H:%M:%S%:z)"

  read -r cpu_m cpu_p _ < <(sar_media_pico -u %idle sim)
  read -r iow_m iow_p _ < <(sar_media_pico -u %iowait)
  # Pico de memória sem as amostras desta execução: o próprio backup (TAR, Drive, FTP) puxa a
  # memória para cima e isso não é alerta (decisão de 27/10/2026). A média é a do dia todo.
  local ate="00:00:00"
  [ "${INICIO:0:10}" = "$(date +%F)" ] && ate="${INICIO:11:8}"
  read -r mem_m _ _ _ < <(sar_media_pico -r %memused)
  read -r _ mem_p _ mem_t < <(sar_media_pico -r %memused nao "$ate")
  local mem_em=""
  [ -n "${mem_t:-}" ] && mem_em="$(date -d "$(date +%F) $mem_t" +%Y-%m-%dT%H:%M:%S%:z 2>/dev/null)"
  if [ -z "${cpu_m:-}" ] || [ -z "${mem_m:-}" ]; then
    problema SYSSTAT_INDISPONIVEL ATENCAO saude "Sem amostras do sysstat hoje (sar); médias e picos do dia ausentes"
  fi

  SAUDE_JSON="$(jq -n --argjson d "$discos" --argjson i "${inodes:-null}" --argjson m "$mem" --argjson s "$swap" \
    --argjson c "$carga" --argjson n "$nucleos" --arg l "$desde" \
    --arg cm "${cpu_m:-}" --arg cp "${cpu_p:-}" --arg im "${iow_m:-}" --arg ip "${iow_p:-}" \
    --arg mm "${mem_m:-}" --arg mp "${mem_p:-}" --arg me "${mem_em:-}" \
    'def num: if . == "" then null else tonumber end;
     {disco: $d, inodes_percentual: $i, memoria_percentual: $m, swap_percentual: $s, carga: $c, nucleos: $n,
      cpu_media_dia: ($cm | num), cpu_pico_dia: ($cp | num), iowait_media_dia: ($im | num),
      iowait_pico_dia: ($ip | num), memoria_media_dia: ($mm | num), memoria_pico_dia: ($mp | num),
      memoria_pico_em: (if $me == "" then null else $me end),
      ligado_desde: $l}')"
}

# Containers: só os campos do marco zero (identidade = nome lógico).
coletar_containers() {
  local ids imgs digests
  if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
    problema DOCKER_INDISPONIVEL ATENCAO saude "Docker indisponível: containers não coletados"
    return 0
  fi
  ids="$(docker ps -aq)"
  [ -n "$ids" ] || { CONTAINERS_JSON='[]'; return 0; }
  # shellcheck disable=SC2086
  imgs="$(docker inspect $ids | jq -r '.[].Image' | sort -u)"
  # shellcheck disable=SC2086
  digests="$(docker image inspect $imgs 2>/dev/null \
    | jq -c 'map({key: .Id, value: ((.RepoDigests // [])[0] // "" | split("@") | .[1] // null)}) | from_entries')"
  [ -n "$digests" ] || digests='{}'
  # shellcheck disable=SC2086
  CONTAINERS_JSON="$(docker inspect $ids | jq -c --argjson dg "$digests" '
    map(
      (.Config.Image) as $ref
      | ($ref | if test("@") then split("@")[0] else . end) as $semdigest
      | ($semdigest | capture("^(?<i>.*?)(:(?<t>[^:/]+))?$")) as $p
      | {nome: (.Name | ltrimstr("/")), imagem: $p.i, tag: ($p.t // "latest"), digest: $dg[.Image],
         estado: .State.Status, saude: (.State.Health.Status // null),
         portas: [(.NetworkSettings.Ports // {}) | to_entries[] | .key as $k
                  | if .value == null then $k else (.value[] | "\($k)->\(.HostPort)") end] | unique,
         politica_reinicio: .HostConfig.RestartPolicy.Name, reinicios: .RestartCount,
         iniciado_em: .State.StartedAt})
    | sort_by(.nome)')"
  # shellcheck disable=SC2086
  conferir_inicio_automatico $ids
}

# Regra dos servidores (27/10/2026): container sem política de reinício sobe pelo /etc/rc.local,
# por "docker start NOME" ou pelo docker-compose do projeto dele (pasta ou arquivo citado lá).
# O que não sobe de nenhum jeito vira ponto de atenção: não volta se o servidor reiniciar.
conferir_inicio_automatico() {
  local rc="${RC_LOCAL:-/etc/rc.local}" nome politica pasta arquivos coberto
  local conteudo="" palavras=""
  if [ -x "$rc" ]; then
    conteudo="$(grep -v '^[[:space:]]*#' "$rc")"
    palavras="$(tr -s ' \t;&|' '\n' <<<"$conteudo")"   # nome do container só vale exato
  fi
  while IFS='|' read -r nome politica pasta arquivos; do   # '|': campo vazio não some (tab some)
    [ -z "$politica" ] || [ "$politica" = no ] || continue
    coberto=nao
    if [ -n "$conteudo" ]; then
      grep -qxF -- "$nome" <<<"$palavras" && coberto=sim
      [ -n "$pasta" ] && grep -qF -- "$pasta" <<<"$conteudo" && coberto=sim
      [ -n "$arquivos" ] && grep -qF -- "${arquivos%%,*}" <<<"$conteudo" && coberto=sim
    fi
    [ "$coberto" = sim ] || problema CONTAINER_SEM_INICIO_AUTOMATICO ATENCAO saude \
      "o container $nome não tem política de reinício nem está no /etc/rc.local: não volta sozinho se o servidor reiniciar"
  done < <(docker inspect "$@" | jq -r '.[] | [(.Name | ltrimstr("/")), (.HostConfig.RestartPolicy.Name // ""),
      (.Config.Labels["com.docker.compose.project.working_dir"] // ""),
      (.Config.Labels["com.docker.compose.project.config_files"] // "")] | join("|")')
}

coletar_inventario() {
  local so ver cpu memb ips
  so="$(. /etc/os-release 2>/dev/null; echo "${NAME:-}")"
  ver="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
  cpu="$(LC_ALL=C lscpu 2>/dev/null | awk -F: '/^Model name/ { gsub(/^ +/, "", $2); print $2; exit }')"
  memb="$(awk '/^MemTotal:/ { print $2 * 1024 }' /proc/meminfo)"
  ips="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sort | jq -R . | jq -s -c .)"
  INVENTARIO_JSON="$(jq -n --arg s "$so" --arg v "$ver" --arg c "$cpu" --argjson m "$memb" --argjson i "${ips:-[]}" \
    '{so: $s, versao_so: $v, cpu: $c, memoria: $m, ips: $i}')"
}
