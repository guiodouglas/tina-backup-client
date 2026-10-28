# Entrega ao banco da TINA: documento do contrato (formato 1), fila local e envio.
# O backup nunca depende do banco: se ele estiver fora, o documento espera na fila.

DIR_FILA="$RAIZ/fila"

# $1 = inicio | fim
montar_documento() {
  local envio="$1" fim=null status=EM_ANDAMENTO
  if [ "$envio" = fim ]; then
    fim="\"$(agora_iso)\""
    status="$(status_da_execucao)"
  fi
  jq -n --arg envio "$envio" --arg versao "$VERSAO" --arg nome "$SERVER_NAME" --arg host "$(hostname -f 2>/dev/null || hostname)" \
    --arg run "$RUN_ID" --arg modo "$MODO" --arg slot "${SLOT:-}" --argjson forcado "$SLOT_FORCADO" \
    --argjson manual "$MANUAL" --arg agenda "$AGENDAMENTO" --arg inicio "$INICIO" --argjson fim "$fim" \
    --arg status "$status" --argjson cfg "$CONFIG_JSON" \
    --argjson fontes "$FONTES_JSON" --argjson drive "$DRIVE_JSON" --argjson tar "$TAR_JSON" \
    --argjson ftp "$FTP_JSON" --argjson residuos "$RESIDUOS_JSON" --argjson saude "$SAUDE_JSON" \
    --argjson containers "$CONTAINERS_JSON" --argjson inventario "$INVENTARIO_JSON" --argjson problemas "$PROBLEMAS_JSON" '
    {formato: 1, app_versao: $versao, envio: $envio,
     servidor: {nome: $nome, hostname: $host},
     execucao: {run_id: $run, modo: $modo, slot: (if $slot == "" then null else $slot end),
                slot_forcado: $forcado, manual: $manual,
                agendamento_crontab: (if $agenda == "" then null else $agenda end),
                inicio: $inicio, fim: $fim, status: $status},
     configuracao: $cfg}
    + if $envio == "fim" then
        {etapas: {fontes: $fontes, drive: $drive, tar: $tar, ftp: $ftp, residuos: $residuos},
         problemas: $problemas}
        + (if $saude != null then {saude: $saude, containers: $containers} else {} end)
        + (if $inventario != null then {inventario: $inventario} else {} end)
      else {} end'
}

enviar_ao_banco() {
  local arq="$1" r
  r="$( { printf '\\set doc `cat %q`\n' "$arq"; echo "SELECT ingest.registrar_execucao(:'doc'::jsonb);"; } \
    | PGPASSWORD="$TINA_DB_PASSWORD" PGCONNECT_TIMEOUT=15 psql -X -q -t -A -v ON_ERROR_STOP=1 \
        "host=$TINA_DB_HOST port=$TINA_DB_PORT dbname=$TINA_DB_NAME user=$TINA_DB_USER sslmode=$TINA_DB_SSLMODE" 2>&1)"
  local rc=$?
  [ $rc -eq 0 ] || echo "$r" | tail -2 >> "$LOG"
  return $rc
}

# Grava o documento na fila e tenta entregar tudo o que estiver nela (mais antigo primeiro).
entregar() {
  local envio="$1" arq f
  mkdir -p "$DIR_FILA"; chmod 700 "$DIR_FILA"
  arq="$DIR_FILA/$(date +%Y%m%d-%H%M%S)-${RUN_ID}-${envio}.json"
  montar_documento "$envio" > "$arq"
  for f in $(ls -1 "$DIR_FILA"/*.json 2>/dev/null | sort); do
    if enviar_ao_banco "$f"; then
      rm -f -- "$f"
    else
      aviso "Banco indisponível: $(ls -1 "$DIR_FILA"/*.json | wc -l) envio(s) aguardando na fila"
      return 1
    fi
  done
  info "Banco: envio de $envio entregue"
}
