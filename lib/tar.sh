# TAR.GZ: criação, validação (com tamanho por pasta) e limpeza de residuais.
# O TAR só é apagado depois de validado e confirmado no FTP.

TAR_JSON='{"status":"NAO_EXECUTADA"}'
RESIDUOS_JSON='{"encontrados":0,"removidos":0}'
ARQ_TAR=""

nome_tar() { echo "$DIR_TAR/${SERVER_NAME}_$(date +%Y-%m-%d).tar.gz"; }

# Remove TARs de execuções anteriores. $1 = arquivo a preservar (opcional).
limpar_residuos() {
  local preservar="${1:-}" f n=0 r=0
  mkdir -p "$DIR_TAR"; chmod 700 "$DIR_TAR"
  while IFS= read -r f; do
    [ "$f" = "$preservar" ] && continue
    n=$((n + 1))
    if rm -f -- "$f" "$f.sha256"; then
      r=$((r + 1))
    fi
  done < <(find "$DIR_TAR" -maxdepth 1 -type f -name "${SERVER_NAME}_*.tar.gz")
  [ $n -gt 0 ] && problema TAR_RESIDUAL_REMOVIDO INFO tar "$r de $n TAR(s) de execuções anteriores removido(s)"
  RESIDUOS_JSON="$(jq -n --argjson e $n --argjson r $r '{encontrados: $e, removidos: $r}')"
}

# Lista do TAR (tar -tv) → tamanho e quantidade por pasta, um nível abaixo de cada fonte.
pastas_da_listagem() {
  local fontes_rel
  fontes_rel="$(printf '%s\n' "${FONTES[@]#/}")"
  awk -v fontes="$fontes_rel" '
    BEGIN { n = split(fontes, F, "\n") }
    {
      tipo = substr($1, 1, 1); tam = $3
      linha = $0
      for (k = 1; k <= 5; k++) sub(/^[^ ]+ +/, "", linha)   # tira permissões, dono, tamanho, data, hora
      sub(/ -> .*$/, "", linha); sub(/ link to .*$/, "", linha); sub(/\/$/, "", linha)
      for (j = 1; j <= n; j++) {
        f = F[j]
        if (linha == f) { if (tipo != "d") { chave = f SUBSEP "(arquivo)"; T[chave] += tam; Q[chave]++ } ; break }
        if (index(linha, f "/") == 1) {
          resto = substr(linha, length(f) + 2)
          p = resto; sub(/\/.*$/, "", p)
          if (p == resto && tipo != "d") p = "(arquivos soltos)"
          chave = f SUBSEP p
          if (tipo != "d") { T[chave] += tam; Q[chave]++ } else if (!(chave in T)) { T[chave] = 0; Q[chave] = 0 }
          break
        }
      }
    }
    END { for (c in T) { split(c, x, SUBSEP); printf "/%s\t%s\t%d\t%d\n", x[1], x[2], T[c], Q[c] } }'
}

# $1 = "sim" para simular (não cria o TAR).
executar_tar() {
  local inicio rc status=OK duracao validacao tamanho sha pastas_json='[]'
  ARQ_TAR="$(nome_tar)"
  limpar_residuos
  argumentos_tar
  info "TAR: criando $(basename "$ARQ_TAR")"
  inicio=$(date +%s)
  tar -C / --ignore-failed-read "${TAR_EXCLUSOES[@]}" -czf "$ARQ_TAR" "${TAR_ITENS[@]}" 2>>"$LOG"
  rc=$?
  duracao=$(( $(date +%s) - inicio ))
  # GNU tar: 1 = algum arquivo mudou durante a leitura (o TAR é válido); 2 = erro.
  if [ $rc -eq 1 ]; then
    status=ATENCAO
    problema TAR_ARQUIVOS_ALTERADOS ATENCAO tar "Arquivos mudaram durante a cópia (ver backup.log)"
  elif [ $rc -ne 0 ] || [ ! -s "$ARQ_TAR" ]; then
    problema TAR_FALHOU CRITICO tar "tar terminou com código $rc"
    TAR_JSON="$(jq -n --argjson d $duracao '{status: "ERRO", duracao: $d}')"
    return 1
  fi

  info "TAR: validando (listagem completa) e medindo pastas"
  inicio=$(date +%s)
  local lista="$RAIZ/tmp/tar-lista.txt"
  if ! tar -tvzf "$ARQ_TAR" > "$lista" 2>>"$LOG"; then
    validacao=$(( $(date +%s) - inicio ))
    problema TAR_INVALIDO CRITICO tar "O TAR gerado não pôde ser lido por inteiro"
    rm -f "$lista"
    TAR_JSON="$(jq -n --argjson d $duracao --argjson v $validacao '{status: "ERRO", duracao: $d, duracao_validacao: $v}')"
    return 1
  fi
  pastas_json="$(pastas_da_listagem < "$lista" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
    | {fonte: .[0], pasta: .[1], tamanho: (.[2] | tonumber), arquivos: (.[3] | tonumber)})')"
  rm -f "$lista"
  tamanho=$(stat -c %s "$ARQ_TAR")
  sha=$(sha256sum "$ARQ_TAR" | awk '{print $1}')
  echo "$sha  $(basename "$ARQ_TAR")" > "$ARQ_TAR.sha256"
  validacao=$(( $(date +%s) - inicio ))

  TAR_JSON="$(jq -n --arg s "$status" --argjson d $duracao --argjson v $validacao --argjson t "$tamanho" \
    --arg h "$sha" --argjson p "$pastas_json" \
    '{status: $s, duracao: $d, duracao_validacao: $v, tamanho: $t, sha256: $h, pastas: $p}')"
  info "TAR: $status, $(numfmt --to=iec "$tamanho"), $(jq length <<<"$pastas_json") pastas, criado em $(tempo $duracao), validado em $(tempo $validacao)"
}

# --only-ftp: usa o TAR mais recente, conferindo o SHA-256 gravado na validação.
localizar_tar_existente() {
  ARQ_TAR="$(find "$DIR_TAR" -maxdepth 1 -type f -name "${SERVER_NAME}_*.tar.gz" -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -1 | cut -d' ' -f2-)"
  if [ -z "$ARQ_TAR" ] || [ ! -f "$ARQ_TAR.sha256" ]; then
    problema TAR_INEXISTENTE CRITICO ftp "Nenhum TAR validado para enviar (rode --only-tar antes)"
    return 1
  fi
  if ! (cd "$DIR_TAR" && sha256sum -c --status "$(basename "$ARQ_TAR").sha256"); then
    problema TAR_HASH_DIFERENTE CRITICO ftp "SHA-256 do TAR não confere com o da validação"
    return 1
  fi
  limpar_residuos "$ARQ_TAR"
  info "FTP: usando o TAR existente $(basename "$ARQ_TAR")"
}
