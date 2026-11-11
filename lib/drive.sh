# Google Drive: sync em espelho para o slot do dia e conferência por tamanho.
# O rclone roda em container (docker run, sem Compose), com / montado só leitura em /host.
# Só as variáveis RCLONE_* entram no container; os valores vêm do ambiente (já lido do
# .env pelo script) e não aparecem na linha de comando.

IMAGEM_RCLONE="rclone/rclone:1.75.0"
DRIVE_JSON='{"status":"NAO_EXECUTADA"}'

# TEMPO_LIMITE (segundos), opcional: interrompe o rclone se passar do tempo.
rclone_em_container() {
  local v vars=() limite=()
  export RCLONE_CONFIG_GDRIVE_TEAM_DRIVE="$1"; shift
  for v in $(compgen -e | grep '^RCLONE_'); do vars+=(-e "$v"); done
  [ -n "${TEMPO_LIMITE:-}" ] && limite=(timeout "$TEMPO_LIMITE")
  "${limite[@]}" docker run --rm --label "${ROTULO_BACKUP_CLIENT:-tina.backup-client}=rclone" "${vars[@]}" -v /:/host:ro -v "$RAIZ/logs:/backup-logs" -v "$RAIZ/tmp:/backup-tmp" \
    -w /host "$IMAGEM_RCLONE" "$@"
}

# Texto da falha da conferência para o relatório (o time lê): o que aconteceu e quais arquivos.
texto_conferencia() {
  local dif="$1" slot="$2" arquivos total nomes
  [ "$slot" = terca ] && slot="terça"
  arquivos="$(grep -E 'ERROR : ' "$DIR_LOG/rclone-check.log" 2>/dev/null | grep -v 'differences found' \
    | sed -E 's/.*ERROR : (.*): [^:]+$/\1/' | sed 's|^|/|')"
  total=$(grep -c . <<<"$arquivos")
  if [ "$dif" -gt 0 ] && [ "$total" -gt 0 ]; then
    nomes="$(head -3 <<<"$arquivos" | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')"
    [ "$total" -gt 3 ] && nomes="$nomes e mais $((total - 3))"
    echo "a cópia para o Google Drive (slot de $slot) terminou, mas na conferência $dif arquivo(s) estavam diferentes no Drive: $nomes"
  else
    echo "a conferência da cópia no Google Drive (slot de $slot) não pôde ser concluída"
  fi
}

# $1 = slot; $2 = "sim" para simular (--dry-run do rclone).
executar_drive() {
  local slot="$1" simular="${2:-nao}" drive inicio rc status combinado unico erros dif
  drive="$(drive_do_slot "$slot")"
  if [ -z "$drive" ]; then
    problema SLOT_INDEFINIDO CRITICO drive "Shared Drive não configurado para o slot $slot"
    DRIVE_JSON='{"status":"ERRO"}'
    return 1
  fi
  mkdir -p "$RAIZ/tmp"
  gerar_filtro_rclone "$RAIZ/tmp/filtro-rclone.txt"
  combinado="$RAIZ/tmp/rclone-combinado.txt"
  rm -f "$combinado"
  local extra=()
  [ "$simular" = sim ] && extra=(--dry-run)

  info "Drive: sync para o slot $slot${extra:+ (simulação)}"
  inicio=$(date +%s)
  rclone_em_container "$drive" sync /host "${RCLONE_REMOTE}:" \
    --filter-from /backup-tmp/filtro-rclone.txt --delete-excluded \
    --links --create-empty-src-dirs --fast-list --checkers 12 --transfers 6 --max-delete 10000 \
    --combined /backup-tmp/rclone-combinado.txt --stats 60s --stats-one-line \
    --log-level INFO --log-file "/backup-logs/$(basename "$DIR_LOG")/rclone-sync.log" "${extra[@]}"
  rc=$?
  local duracao=$(( $(date +%s) - inicio ))
  status=OK
  if [ $rc -ne 0 ]; then
    status=ERRO
    problema DRIVE_FALHOU CRITICO drive "rclone sync terminou com código $rc"
  fi
  erros=$(grep -c ' ERROR ' "$DIR_LOG/rclone-sync.log" 2>/dev/null || true)

  # Contagens do arquivo --combined: + criado, * atualizado, - excluído, = igual, ! erro.
  unico="$RAIZ/tmp/rclone-combinado-unico.txt"
  sort -u "$combinado" 2>/dev/null > "$unico" || : > "$unico"
  local c a e i x
  read -r c a e i x < <(awk '
    substr($0, length($0), 1) == "/" { next }
    $1 == "+" { c++ } $1 == "*" { a++ } $1 == "-" { e++ } $1 == "=" { i++ } $1 == "!" { x++ }
    END { print c+0, a+0, e+0, i+0, x+0 }' "$unico")
  awk '$1 != "="' "$unico" > "$DIR_LOG/rclone-mudancas.log"
  rm -f "$unico" "$combinado"

  # Conferência: cada arquivo da origem existe no slot com o mesmo tamanho.
  local conf_status=NAO_EXECUTADA conf_dif=null
  if [ "$status" = OK ] && [ "$simular" != sim ]; then
    info "Drive: conferência por tamanho"
    rclone_em_container "$drive" check /host "${RCLONE_REMOTE}:" \
      --filter-from /backup-tmp/filtro-rclone.txt --one-way --size-only --links --fast-list \
      --checkers 12 --log-level NOTICE --log-file "/backup-logs/$(basename "$DIR_LOG")/rclone-check.log"
    rc=$?
    dif=$(grep -oE '[0-9]+ differences found' "$DIR_LOG/rclone-check.log" 2>/dev/null | tail -1 | awk '{print $1}')
    conf_dif="${dif:-0}"
    if [ $rc -eq 0 ]; then
      conf_status=OK
    else
      conf_status=ERRO
      problema DRIVE_CONFERENCIA_DIFERENTE CRITICO drive "$(texto_conferencia "$conf_dif" "$slot")"
    fi
  fi
  duracao=$(( $(date +%s) - inicio ))

  DRIVE_JSON="$(jq -n --arg s "$status" --argjson d "$duracao" --argjson c "$c" --argjson a "$a" \
    --argjson e "$e" --argjson i "$i" --argjson x "$x" --argjson t "${erros:-0}" \
    --arg cs "$conf_status" --argjson cd "$conf_dif" \
    '{status: $s, duracao: $d, criados: $c, atualizados: $a, excluidos: $e, inalterados: $i,
      erros: $x, total_objetos: ($c + $a + $e + $i + $x), erros_transitorios: $t,
      conferencia: {status: $cs, diferencas: $cd}}')"
  info "Drive: $status em $(tempo $duracao) (criados $c, atualizados $a, excluídos $e, conferência $conf_status)"
  [ "$status" = OK ]
}
