#!/usr/bin/env bash
# backup-client 2.0: backup do servidor (Google Drive, TAR.GZ no FTP), saúde e
# entrega ao banco da TINA. O horário fica só no crontab.
#
# Uso: backup.sh [modo] [--slot DIA]
#   (sem modo)        completo: Drive, TAR, FTP, saúde
#   --dry-run         simula: Drive em simulação, sem TAR, envio nem banco; lista o FTP e
#                     mostra o que a retenção apagaria; mostra o documento
#   --only-sync       só o Drive
#   --only-tar        só cria e valida o TAR (fica guardado para um --only-ftp)
#   --only-ftp        só envia o TAR deixado pelo --only-tar
#   --only-tar-ftp    cria, valida e envia o TAR
#   --only-monitoring só saúde, containers e inventário
#   --check-config    confere configuração, ferramentas e conexões
#   --slot DIA        força o slot do Drive (segunda..sexta); não vira referência
#   --agendado        usado só pelo crontab

RAIZ="${RAIZ:-/opt/backup-client}"
for lib in comum fontes drive tar ftp saude banco; do
  # shellcheck disable=SC1090
  . "$RAIZ/lib/$lib.sh"
done

MODO=completo; SIMULAR=nao; CHECAR=nao; SLOT=""; SLOT_FORCADO=false; MANUAL=true
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) SIMULAR=sim ;;
    --only-sync|--only-tar|--only-ftp|--only-tar-ftp|--only-monitoring)
      [ "$MODO" = completo ] || { echo "Use apenas um --only-*" >&2; exit 2; }
      MODO="${1#--}" ;;
    --check-config) CHECAR=sim ;;
    --slot) shift; SLOT="${1:-}"; SLOT_FORCADO=true ;;
    --agendado) MANUAL=false ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Opção desconhecida: $1" >&2; exit 2 ;;
  esac
  shift
done
if [ "$SIMULAR" = sim ] && [ "$MODO" != completo ]; then
  echo "--dry-run não se combina com --only-*" >&2; exit 2
fi
case "$SLOT" in ''|segunda|terca|quarta|quinta|sexta) ;; *) echo "Slot inválido: $SLOT" >&2; exit 2 ;; esac

carregar_env || exit 1
iniciar_log

if [ "$CHECAR" = sim ]; then
  # shellcheck disable=SC1091
  . "$RAIZ/lib/checar.sh"
  checar_configuracao
  exit $?
fi

# Uma execução por vez.
mkdir -p "$RAIZ/tmp"
exec 9>"$RAIZ/tmp/backup.lock"
flock -n 9 || { erro "Outra execução do backup-client está em andamento"; exit 3; }

RUN_ID="$(uuidgen)"
INICIO="$(agora_iso)"
AGENDAMENTO="$(agendamento_crontab)"
[ "$MANUAL" = true ] && [ -n "$AGENDAMENTO" ] && info "Execução manual (agendamento: $AGENDAMENTO)"
CONFIG_JSON="$(configuracao_json)"
FONTES_JSON='{"status":"NAO_EXECUTADA"}'

faz() { case "$1:$MODO" in
  drive:completo|drive:only-sync) return 0 ;;
  tar:completo|tar:only-tar|tar:only-tar-ftp) return 0 ;;
  ftp:completo|ftp:only-ftp|ftp:only-tar-ftp) return 0 ;;
  saude:completo|saude:only-monitoring) return 0 ;;
  *) return 1 ;; esac; }

info "backup-client $VERSAO | $SERVER_NAME | modo $MODO$([ "$SIMULAR" = sim ] && echo ' (simulação)') | run $RUN_ID"
find "$RAIZ/logs" -mindepth 1 -maxdepth 1 -type d -mtime +"$DIAS_LOG" -exec rm -rf -- {} + 2>/dev/null

if [ "$SIMULAR" = nao ]; then
  entregar inicio || true
fi

# Fontes (Drive e TAR).
if faz drive || faz tar; then
  inicio_etapa=$(date +%s)
  if carregar_fontes; then
    st=OK; [ ${#FONTES_AUSENTES[@]} -gt 0 ] && st=ATENCAO
  else
    st=ERRO
  fi
  FONTES_JSON="$(jq -n --arg s "$st" --argjson d $(( $(date +%s) - inicio_etapa )) \
    --argjson a "$(printf '%s\n' "${FONTES_AUSENTES[@]}" | grep -v '^$' | jq -R . | jq -s -c .)" \
    '{status: $s, duracao: $d, ausentes: $a}')"
fi
FONTES_OK=sim; [ "$(jq -r .status <<<"$FONTES_JSON")" = ERRO ] && FONTES_OK=nao

# Google Drive.
if faz drive && [ "$FONTES_OK" = sim ]; then
  if [ -z "$SLOT" ]; then
    if ! SLOT="$(slot_do_dia)"; then
      problema SLOT_INDEFINIDO CRITICO drive "Hoje não há slot (use --slot)"
      DRIVE_JSON='{"status":"ERRO"}'
    fi
  fi
  [ -n "$SLOT" ] && executar_drive "$SLOT" "$SIMULAR"
fi

# TAR e FTP.
if [ "$SIMULAR" = nao ]; then
  TAR_PRONTO=nao
  if faz tar && [ "$FONTES_OK" = sim ]; then
    executar_tar && TAR_PRONTO=sim
  elif [ "$MODO" = only-ftp ]; then
    if localizar_tar_existente; then TAR_PRONTO=sim; else FTP_JSON='{"status":"ERRO"}'; fi
  fi
  if faz ftp && [ "$TAR_PRONTO" = sim ]; then
    executar_ftp
  fi
elif faz ftp; then
  # Simulação: mostra o que a retenção apagaria hoje (só lista o FTP).
  aplicar_retencao_ftp "$(basename "$(nome_tar)")" sim
  FTP_JSON="$(jq -cn --argjson r "$RETENCAO_JSON" '{status: "NAO_EXECUTADA"} + (if $r then {retencao: $r} else {} end)')"
fi

# Saúde, containers, inventário.
if faz saude; then
  coletar_saude
  coletar_containers
  coletar_inventario
fi

STATUS="$(status_da_execucao)"
if [ "$SIMULAR" = sim ]; then
  montar_documento fim | tee "$DIR_LOG/dry-run-$RUN_ID.json"
  info "Simulação concluída: status $STATUS (nada foi enviado ao FTP nem ao banco)"
  exit 0
fi
entregar fim || true
info "Fim: status $STATUS"
[ "$STATUS" = CRITICO ] && exit 1
exit 0
