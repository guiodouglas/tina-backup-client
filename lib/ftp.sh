# FTP: envio do TAR e conferência do tamanho remoto (o vsftpd não oferece hash).

FTP_JSON='{"status":"NAO_EXECUTADA"}'

executar_ftp() {
  local nome inicio rc remoto local_tam duracao
  nome="$(basename "$ARQ_TAR")"
  local_tam=$(stat -c %s "$ARQ_TAR")
  info "FTP: enviando $nome"
  inicio=$(date +%s)
  curl -K <(curl_cfg_ftp) --fail --show-error --silent --ftp-create-dirs --connect-timeout 30 \
    --retry 2 --retry-delay 10 --upload-file "$ARQ_TAR" "$(url_ftp "$nome")" 2>>"$LOG"
  rc=$?
  if [ $rc -ne 0 ]; then
    duracao=$(( $(date +%s) - inicio ))
    problema FTP_FALHOU CRITICO ftp "Envio falhou (curl código $rc)"
    FTP_JSON="$(jq -n --argjson d $duracao '{status: "ERRO", duracao: $d}')"
    return 1
  fi
  remoto="$(curl -K <(curl_cfg_ftp) --fail --silent --head "$(url_ftp "$nome")" 2>>"$LOG" \
    | awk 'tolower($1) == "content-length:" { gsub("\r", "", $2); print $2 }' | tail -1)"
  duracao=$(( $(date +%s) - inicio ))
  if [ "$remoto" != "$local_tam" ]; then
    problema FTP_TAMANHO_DIFERENTE CRITICO ftp "Tamanho remoto ${remoto:-desconhecido}, local $local_tam"
    FTP_JSON="$(jq -n --argjson d $duracao --arg r "${remoto:-}" \
      '{status: "ERRO", duracao: $d, tamanho_remoto: ($r | tonumber? // null)}')"
    return 1
  fi
  FTP_JSON="$(jq -n --argjson d $duracao --argjson r "$remoto" '{status: "OK", duracao: $d, tamanho_remoto: $r}')"
  info "FTP: OK, tamanho conferido ($local_tam bytes) em $(tempo $duracao)"

  # Validado e transferido: só agora o TAR local sai.
  if ! rm -f -- "$ARQ_TAR" "$ARQ_TAR.sha256"; then
    problema TAR_NAO_REMOVIDO ATENCAO ftp "TAR enviado, mas não foi possível apagá-lo localmente"
  fi
}
