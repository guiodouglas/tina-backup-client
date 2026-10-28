# --check-config: confere ferramentas, .env, listas, crontab e conexões (sem exibir segredos).

checar_configuracao() {
  local falhas=0 k c slot drive
  ok() { printf 'OK     %s\n' "$*"; }
  falha() { printf 'FALHA  %s\n' "$*"; falhas=$((falhas + 1)); }

  for c in jq psql docker curl uuidgen sar flock sha256sum tar numfmt; do
    command -v "$c" >/dev/null && ok "comando $c" || falha "comando $c não encontrado"
  done
  docker info >/dev/null 2>&1 && ok "docker em execução" || falha "docker não responde"

  for k in "${ENV_OBRIGATORIAS[@]}"; do
    [ -n "${!k:-}" ] && ok ".env: $k" || falha ".env: $k vazio ou ausente"
  done
  env | grep -q '^RCLONE_CONFIG_GDRIVE_' && ok ".env: credencial do rclone" || falha ".env: RCLONE_CONFIG_GDRIVE_* ausente"

  if carregar_fontes >/dev/null 2>&1; then
    ok "fontes: ${#FONTES[@]} disponível(is)$([ ${#FONTES_AUSENTES[@]} -gt 0 ] && echo ", ${#FONTES_AUSENTES[@]} ausente(s): ${FONTES_AUSENTES[*]}")"
  else
    falha "fontes: nenhuma disponível"
  fi
  ok "exclusões: ${#EXCLUSOES[@]}; impressão da configuração $(impressao_configuracao | cut -c1-12)"

  local ag; ag="$(agendamento_crontab)"
  if [ -z "$ag" ]; then
    falha "crontab: nenhuma linha ativa com /opt/backup-client/scripts/backup.sh"
  elif [[ "$ag" =~ ^[0-9]+\ [0-9]+\ \*\ \*\ [0-9,*-]+$ ]]; then
    ok "crontab: $ag"
  else
    falha "crontab: '$ag' fora do padrão 'M H * * DIAS' (o banco não saberia o horário esperado)"
  fi

  if grep -qE '^\*/5 \* \* \* \* root /opt/backup-client/scripts/monitor\.sh' /etc/crontab; then
    ok "crontab: monitor a cada 5 minutos"
  else
    falha "crontab: falta a linha do monitor (*/5 * * * * root /opt/backup-client/scripts/monitor.sh)"
  fi

  for slot in segunda terca quarta quinta sexta; do
    drive="$(drive_do_slot "$slot")"
    if TEMPO_LIMITE=120 rclone_em_container "$drive" lsf "${RCLONE_REMOTE}:" --max-depth 1 --dirs-only >/dev/null 2>&1; then
      ok "Drive: slot $slot acessível"
    else
      falha "Drive: slot $slot inacessível"
    fi
  done

  if curl -K <(curl_cfg_ftp) --fail --silent --list-only --connect-timeout 20 "$(url_ftp '')" >/dev/null 2>&1; then
    ok "FTP: ${FTP_BACKUP_HOST}:${FTP_BACKUP_PORT}${FTP_BACKUP_REMOTE_DIR} acessível"
  else
    falha "FTP: sem acesso a ${FTP_BACKUP_HOST}:${FTP_BACKUP_PORT}${FTP_BACKUP_REMOTE_DIR}"
  fi
  [[ "${SERVER_NAME:-}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || falha ".env: SERVER_NAME com caractere fora de letras, números, '.', '-', '_' (a retenção depende do nome)"
  if retencao_valida; then
    ok ".env: FTP_BACKUP_RETENCAO=$FTP_BACKUP_RETENCAO"
  else
    falha ".env: FTP_BACKUP_RETENCAO ausente ou inválida (número, mínimo $RETENCAO_MINIMA)"
  fi
  if testar_permissao_apagar_ftp; then
    ok "FTP: usuário pode enviar e apagar (marcador de teste removido)"
  else
    falha "FTP: não foi possível enviar e apagar o marcador ${SERVER_NAME}_teste-de-permissao.tmp (conferir se ficou no FTP)"
  fi
  local lista_ftp
  if lista_ftp="$(listar_backups_ftp)"; then
    ok "FTP: $(grep -c . <<<"$lista_ftp") backup(s) do servidor: $(tr '\n' ' ' <<<"$lista_ftp")"
  fi

  if PGPASSWORD="$TINA_DB_PASSWORD" PGCONNECT_TIMEOUT=15 psql -X -q -t -A -c 'SELECT 1' \
       "host=$TINA_DB_HOST port=$TINA_DB_PORT dbname=$TINA_DB_NAME user=$TINA_DB_USER sslmode=$TINA_DB_SSLMODE" >/dev/null 2>&1; then
    ok "banco: ${TINA_DB_USER}@${TINA_DB_HOST}:${TINA_DB_PORT}/${TINA_DB_NAME}"
  else
    falha "banco: sem conexão como ${TINA_DB_USER}@${TINA_DB_HOST}:${TINA_DB_PORT}/${TINA_DB_NAME}"
  fi

  if [ -n "$(sar_media_pico -u %idle sim)" ]; then ok "sysstat: amostras de hoje"; else falha "sysstat: sem amostras hoje"; fi

  echo "falhas: $falhas"
  [ $falhas -eq 0 ]
}
