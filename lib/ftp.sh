# FTP: retenção, envio do TAR e conferência do tamanho remoto (o vsftpd não oferece hash).

FTP_JSON='{"status":"NAO_EXECUTADA"}'
RETENCAO_JSON='null'
RETENCAO_MINIMA=2   # com 1, uma falha no envio deixaria o FTP sem nenhum backup do servidor

# Padrão exato dos TARs do próprio servidor: <servidor>_AAAA-MM-DD.tar.gz.
# A pasta do FTP é compartilhada; nada fora deste padrão é contado nem apagado.
padrao_backup_ftp() {
  # Nome de servidor: letras, números, ".", "-", "_"; o ponto vira literal.
  printf '^%s_[0-9]{4}-[0-9]{2}-[0-9]{2}\\.tar\\.gz$' "${SERVER_NAME//./\\.}"
}

retencao_valida() {
  [[ "${FTP_BACKUP_RETENCAO:-}" =~ ^[0-9]+$ ]] && [ "$FTP_BACKUP_RETENCAO" -ge $RETENCAO_MINIMA ]
}

# Regra da retenção (sem rede, testada em testes/teste_retencao.sh).
# Entrada: lista de nomes do servidor no FTP (stdin), retenção e o nome do TAR novo.
# Saída: o nome a apagar (no máximo um), ou nada. O TAR novo não conta (reenvio o substitui).
escolher_para_apagar() {
  local n="$1" novo="$2" lista
  lista="$(grep -E "$(padrao_backup_ftp)" | grep -vxF -- "$novo" | sort -u)"
  [ -n "$lista" ] || return 0
  [ "$(wc -l <<<"$lista")" -ge "$n" ] || return 0
  head -1 <<<"$lista"
}

# Nomes do servidor no FTP, do mais antigo ao mais recente (a data no nome ordena).
listar_backups_ftp() {
  local lista
  lista="$(curl -K <(curl_cfg_ftp) --fail --silent --show-error --list-only --connect-timeout 30 \
    "$(url_ftp '')" 2>>"$LOG")" || return 1
  tr -d '\r' <<<"$lista" | grep -E "$(padrao_backup_ftp)" | sort -u
  return 0
}

tamanho_ftp() {
  curl -K <(curl_cfg_ftp) --fail --silent --head "$(url_ftp "$1")" 2>>"$LOG" \
    | awk 'tolower($1) == "content-length:" { gsub("\r", "", $2); print $2 }' | tail -1
}

# DELE depois do CWD na pasta (pós-comando do curl: vale o caminho relativo).
apagar_ftp() {
  curl -K <(curl_cfg_ftp) --fail --silent --show-error --list-only --connect-timeout 30 \
    -Q "-DELE $1" "$(url_ftp '')" >/dev/null 2>>"$LOG"
}

# Apaga o mais antigo do servidor para que, depois do envio, fiquem FTP_BACKUP_RETENCAO.
# Falha aqui não impede o envio: o problema é registrado e o envio é tentado.
aplicar_retencao_ftp() {
  local novo="$1" simular="${2:-nao}" n lista alvo tam restantes
  if ! retencao_valida; then
    problema FTP_RETENCAO_FALHOU ATENCAO ftp \
      "FTP_BACKUP_RETENCAO ausente ou inválida ('${FTP_BACKUP_RETENCAO:-}'; mínimo $RETENCAO_MINIMA): nada foi apagado"
    return 0
  fi
  n=$FTP_BACKUP_RETENCAO
  if ! lista="$(listar_backups_ftp)"; then
    problema FTP_RETENCAO_FALHOU ATENCAO ftp "Não foi possível listar o FTP: nada foi apagado"
    return 0
  fi
  alvo="$(escolher_para_apagar "$n" "$novo" <<<"$lista")"
  RETENCAO_JSON="$(jq -cn --argjson m "$n" --argjson a "$(grep -c . <<<"$lista")" \
    '{manter: $m, antes: $a, apagados: []}')"
  if [ -z "$alvo" ]; then
    info "FTP: retenção $n; $(grep -c . <<<"$lista") backup(s) do servidor no FTP, nada a apagar"
    return 0
  fi
  tam="$(tamanho_ftp "$alvo")"
  if [ "$simular" = sim ]; then
    info "FTP (simulação): retenção $n; apagaria $alvo (${tam:-?} bytes) antes de enviar $novo"
    RETENCAO_JSON="$(jq -c --arg nm "$alvo" --arg t "${tam:-}" \
      '.simulacao = true | .apagados = [{nome: $nm, tamanho: ($t | tonumber? // null)}]' <<<"$RETENCAO_JSON")"
    return 0
  fi
  info "FTP: retenção $n; apagando o mais antigo, $alvo"
  apagar_ftp "$alvo"
  # Confere pela listagem: o alvo saiu e os demais continuam lá.
  if ! restantes="$(listar_backups_ftp)"; then
    problema FTP_RETENCAO_FALHOU ATENCAO ftp "Não foi possível conferir a exclusão de $alvo"
    return 0
  fi
  if grep -qxF -- "$alvo" <<<"$restantes"; then
    problema FTP_RETENCAO_FALHOU ATENCAO ftp "$alvo continua no FTP após a exclusão"
    return 0
  fi
  if [ -n "$(comm -23 <(grep -vxF -- "$alvo" <<<"$lista" | grep . | sort) <(sort <<<"$restantes"))" ]; then
    problema FTP_RETENCAO_FALHOU CRITICO ftp "Além de $alvo, sumiram outros backups do servidor no FTP"
  fi
  RETENCAO_JSON="$(jq -c --arg nm "$alvo" --arg t "${tam:-}" \
    '.apagados = [{nome: $nm, tamanho: ($t | tonumber? // null)}]' <<<"$RETENCAO_JSON")"
  info "FTP: $alvo apagado e conferido"
}

executar_ftp() {
  local nome inicio rc remoto local_tam duracao erros lista
  nome="$(basename "$ARQ_TAR")"
  local_tam=$(stat -c %s "$ARQ_TAR")
  inicio=$(date +%s)
  aplicar_retencao_ftp "$nome"
  info "FTP: enviando $nome"
  erros="$(curl -K <(curl_cfg_ftp) --fail --show-error --silent --ftp-create-dirs --connect-timeout 30 \
    --retry 2 --retry-delay 10 --upload-file "$ARQ_TAR" "$(url_ftp "$nome")" 2>&1 >/dev/null)"
  rc=$?
  [ -n "$erros" ] && printf '%s\n' "$erros" >>"$LOG"
  if [ $rc -ne 0 ]; then
    duracao=$(( $(date +%s) - inicio ))
    if grep -qE '\b(452|552)\b' <<<"$erros"; then
      problema FTP_SEM_ESPACO CRITICO ftp "Envio recusado por falta de espaço no FTP (curl código $rc)"
    else
      problema FTP_FALHOU CRITICO ftp "Envio falhou (curl código $rc)"
    fi
    FTP_JSON="$(jq -n --argjson d $duracao --argjson r "$RETENCAO_JSON" \
      '{status: "ERRO", duracao: $d} + (if $r then {retencao: $r} else {} end)')"
    return 1
  fi
  remoto="$(tamanho_ftp "$nome")"
  duracao=$(( $(date +%s) - inicio ))
  if [ "$remoto" != "$local_tam" ]; then
    problema FTP_TAMANHO_DIFERENTE CRITICO ftp "Tamanho remoto ${remoto:-desconhecido}, local $local_tam"
    FTP_JSON="$(jq -n --argjson d $duracao --arg r "${remoto:-}" --argjson rt "$RETENCAO_JSON" \
      '{status: "ERRO", duracao: $d, tamanho_remoto: ($r | tonumber? // null)}
       + (if $rt then {retencao: $rt} else {} end)')"
    return 1
  fi
  # Quantos backups do servidor ficaram no FTP depois do envio.
  if [ "$RETENCAO_JSON" != null ] && lista="$(listar_backups_ftp)"; then
    RETENCAO_JSON="$(jq -c --argjson d "$(grep -c . <<<"$lista")" '.depois = $d' <<<"$RETENCAO_JSON")"
    if [ "$(grep -c . <<<"$lista")" -lt "$FTP_BACKUP_RETENCAO" ]; then
      problema FTP_POUCOS_BACKUPS ATENCAO ftp \
        "$(grep -c . <<<"$lista") backup(s) do servidor no FTP; a retenção é $FTP_BACKUP_RETENCAO"
    fi
  fi
  FTP_JSON="$(jq -n --argjson d $duracao --argjson r "$remoto" --argjson rt "$RETENCAO_JSON" \
    '{status: "OK", duracao: $d, tamanho_remoto: $r} + (if $rt then {retencao: $rt} else {} end)')"
  info "FTP: OK, tamanho conferido ($local_tam bytes) em $(tempo $duracao)"

  # Validado e transferido: só agora o TAR local sai.
  if ! rm -f -- "$ARQ_TAR" "$ARQ_TAR.sha256"; then
    problema TAR_NAO_REMOVIDO ATENCAO ftp "TAR enviado, mas não foi possível apagá-lo localmente"
  fi
}

# --check-config: o usuário do FTP precisa poder enviar e apagar (marcador fora do padrão).
testar_permissao_apagar_ftp() {
  local marcador="${SERVER_NAME}_teste-de-permissao.tmp"
  curl -K <(curl_cfg_ftp) --fail --silent --connect-timeout 20 --upload-file /dev/null \
    "$(url_ftp "$marcador")" 2>>"${LOG:-/dev/null}" || return 1
  apagar_ftp "$marcador" 2>/dev/null
  ! curl -K <(curl_cfg_ftp) --fail --silent --list-only --connect-timeout 20 "$(url_ftp '')" 2>/dev/null \
    | tr -d '\r' | grep -qxF -- "$marcador"
}
