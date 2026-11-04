#!/usr/bin/env bash
# Instalador único do backup-client (projeto TINA). O mesmo comando implanta e atualiza.
#
# Como root:
#   curl -fsSL https://raw.githubusercontent.com/guiodouglas/tina-backup-client/main/instalar.sh | bash
#
# Servidor novo (sem instalação completa): implantação, com assistente. Pode rodar de novo
# quantas vezes precisar: cada passo só age se faltar algo e o que já foi respondido não é perguntado.
#   1. Dependências: sudo, sysstat, jq, curl, uuid-runtime, postgresql-client.
#   2. sysstat: liga a coleta de métricas.
#   3. Docker: confere (obrigatório: o rclone roda em container; não é instalado por aqui).
#   4. Código em /opt/backup-client.
#   5. Acesso da TINA: usuário "tina" (sudo, docker) e chaves (acesso/*.pub). SSH não é alterado.
#   6. .env: FTP, nome do servidor, credencial do Drive, 5 Shared Drives e senha do banco (senhas ocultas).
#   7. Listas do que entra no backup e exclusões.
#   8. Crontab: monitor a cada 5 min e backup de segunda a sexta no horário escolhido.
#   9. --check-config e os "Dados para o registro" (mandar ao construtor).
#
# Servidor já instalado: atualização. Troca só o código; mantém .env, listas, logs, fila e o horário
# do backup (acrescenta só o que versões novas exigem). Não pergunta nada. Quem já tem a 2.3.1 ou
# mais nova pode usar /opt/backup-client/scripts/atualizar.sh, que roda isto e o --check-config.
#
# Opções: --atualizar (só atualiza: sem instalação, para com erro; usado pelo servidor de controle)
#         --horario HH:MM (horário do backup na implantação)
#
# O que já está em uso sai das próprias fontes, sem lista neste repositório público:
#   - nome do servidor: há backup <nome>_AAAA-MM-DD.tar.gz no FTP?
#   - Shared Drive: tem conteúdo? O backup é um espelho, apagaria tudo. Drive vazio recebe um marcador
#     (.backup-client-reservado-<nome>), para o próximo servidor não o escolher antes da primeira
#     noite; o próprio espelho apaga o marcador no primeiro backup daquele Drive.
set -uo pipefail

REPOSITORIO=guiodouglas/tina-backup-client
DESTINO=/opt/backup-client
ENV_ARQ="$DESTINO/.env"
IP_CONTROLE=177.170.20.101       # IP de saída do servidor de controle, visto pelos servidores
RETENCAO_PADRAO=3
PREFIXO_MARCADOR=.backup-client-reservado-
ENTRADA="${ENTRADA_INSTALADOR:-/dev/tty}"   # de onde vêm as respostas (a entrada padrão é o próprio script)

ATUALIZAR=nao; HORARIO=""; TMP=""; problemas=0
RAIZ="$DESTINO"; export RAIZ

ok() { printf 'OK     %s\n' "$*"; }
feito() { printf 'FEITO  %s\n' "$*"; }
falha() { printf 'FALHA  %s\n' "$*"; problemas=$((problemas + 1)); }
titulo() { printf '\n== %s ==\n' "$*"; }
parar() { printf 'ERRO   %s\n' "$*" >&2; exit "${2:-1}"; }
limpar() { [ -n "$TMP" ] && rm -rf -- "$TMP"; rm -rf -- "$DESTINO"/.novo.* 2>/dev/null; }

# ---------- Pacote: a pasta deste script ou a versão publicada no GitHub ----------

obter_pacote() {
  if [ "$(basename "$0")" = instalar.sh ] && [ -f "$0" ]; then
    PACOTE="$(cd "$(dirname "$0")" && pwd)"
    [ "$PACOTE" != "$DESTINO" ] || parar "Rode a partir da pasta do pacote, não de $DESTINO"
  else
    command -v curl >/dev/null && command -v tar >/dev/null || parar "curl e tar são necessários"
    local versao
    versao="$(curl -fsSL "https://raw.githubusercontent.com/$REPOSITORIO/main/VERSION")" \
      || parar "Não consegui saber a versão publicada (github.com)"
    TMP="$(mktemp -d)"; PACOTE="$TMP"
    curl -fsSL "https://github.com/$REPOSITORIO/archive/refs/tags/v$versao.tar.gz" \
      | tar -xz --strip-components=1 -C "$TMP" || parar "Não consegui baixar a versão v$versao do GitHub"
    [ "$(cat "$TMP/VERSION" 2>/dev/null)" = "$versao" ] || parar "O pacote baixado não é da versão $versao"
  fi
  [ -f "$PACOTE/VERSION" ] && [ -d "$PACOTE/lib" ] && [ -d "$PACOTE/scripts" ] || parar "Pacote incompleto em $PACOTE"
}

# Troca o código de uma vez; .env, listas, logs e fila não são tocados.
instalar_codigo() {
  local novo
  mkdir -p "$DESTINO" || parar "Não consegui criar $DESTINO"
  novo="$(mktemp -d "$DESTINO/.novo.XXXX")" || parar "Não consegui criar pasta temporária em $DESTINO"
  cp -R "$PACOTE/VERSION" "$PACOTE/scripts" "$PACOTE/lib" "$PACOTE/.env.example" "$novo/" || parar "Falha ao copiar o código"
  chmod 755 "$novo/scripts/"*.sh
  rm -rf -- "$DESTINO/scripts" "$DESTINO/lib" "$DESTINO/kit"   # kit: instalações até a 2.2.0
  rm -f -- "$DESTINO/docker-compose.yml"                       # saiu na 2.0.4 (rclone com docker run)
  mv -f "$novo/VERSION" "$novo/.env.example" "$DESTINO/" && mv "$novo/scripts" "$novo/lib" "$DESTINO/" \
    || parar "Falha ao trocar o código em $DESTINO"
  rm -rf -- "$novo"
  mkdir -p "$DESTINO/logs" "$DESTINO/tmp" "$DESTINO/fila" && chmod 700 "$DESTINO/tmp" "$DESTINO/fila"
}

# ---------- Crontab ----------

tem_linha_backup() {
  grep -qE "^[^#].*$DESTINO/scripts/backup\.sh" /etc/crontab /etc/cron.d/* 2>/dev/null && return 0
  crontab -l -u root 2>/dev/null | grep -qE "^[^#].*$DESTINO/scripts/backup\.sh"
}

garantir_monitor() {
  if grep -qE "^[^#].*$DESTINO/scripts/monitor\.sh" /etc/crontab; then ok "monitor a cada 5 min"
  else printf '\n# backup-client (TINA): monitor contínuo\n*/5 * * * * root %s/scripts/monitor.sh\n' "$DESTINO" >> /etc/crontab && feito "monitor a cada 5 min"; fi
}

# ---------- Atualização ----------

atualizar() {
  local antes
  antes="$(cat "$DESTINO/VERSION" 2>/dev/null || echo '?')"
  mkdir -p "$DESTINO/tmp"
  exec 9>"$DESTINO/tmp/backup.lock"
  flock -n 9 || parar "Backup em andamento neste servidor: nada foi alterado; atualize depois que ele terminar." 3
  instalar_codigo
  exec 9>&-
  garantir_monitor
  if ! grep -q '^FTP_BACKUP_RETENCAO=' "$ENV_ARQ"; then   # chave da 2.2.0
    printf '\n# Backups do servidor mantidos no FTP (mínimo 2); ver .env.example\nFTP_BACKUP_RETENCAO=%s\n' "$RETENCAO_PADRAO" >> "$ENV_ARQ"
    feito "FTP_BACKUP_RETENCAO=$RETENCAO_PADRAO no .env"
  fi
  echo "atualizado: backup-client $antes -> $(cat "$DESTINO/VERSION") (.env, listas, logs, fila e horário do backup mantidos)"
}

# ---------- Perguntas ----------

perguntar() {  # texto, padrão (opcional); resposta em RESPOSTA
  printf '%s%s: ' "$1" "${2:+ [$2]}"
  IFS= read -r RESPOSTA <&3 || { echo; parar "Respostas interrompidas: rode o comando de novo; o que já foi respondido fica guardado."; }
  RESPOSTA="${RESPOSTA:-${2:-}}"
}

perguntar_oculto() {
  printf '%s (não aparece ao digitar): ' "$1"
  IFS= read -r -s RESPOSTA <&3 || { echo; parar "Respostas interrompidas: rode o comando de novo; o que já foi respondido fica guardado."; }
  echo
}

# Grava CHAVE=valor no .env (uma linha, com aspas se preciso) e no ambiente deste script.
gravar_env() {
  local chave="$1" valor="$2" linha q="'\\''"
  if [[ "$valor" =~ ^[A-Za-z0-9._:/@%+=,-]*$ ]]; then linha="$chave=$valor"
  else linha="$chave='${valor//\'/$q}'"; fi
  ( umask 077
    CHAVE="$chave" LINHA="$linha" awk '
      index($0, ENVIRON["CHAVE"] "=") == 1 { if (!f) { print ENVIRON["LINHA"]; f = 1 } next }
      { print }
      END { if (!f) print ENVIRON["LINHA"] }' "$ENV_ARQ" > "$ENV_ARQ.novo" && mv "$ENV_ARQ.novo" "$ENV_ARQ" ) \
    || parar "Não consegui gravar $ENV_ARQ"
  export "$chave=$valor"
}

# Pergunta só se a chave estiver vazia.
pedir() {  # chave, texto, padrão (opcional)
  [ -n "${!1:-}" ] && return 0
  while :; do
    perguntar "$2" "${3:-}"
    [ -n "$RESPOSTA" ] && break
    echo "Obrigatório."
  done
  gravar_env "$1" "$RESPOSTA"
}

pedir_oculto() {  # chave, texto
  [ -n "${!1:-}" ] && return 0
  while :; do
    perguntar_oculto "$2"
    [ -n "$RESPOSTA" ] && break
    echo "Obrigatório."
  done
  gravar_env "$1" "$RESPOSTA"
}

# ---------- Conferências do .env ----------

lista_ftp() {
  curl -K <(curl_cfg_ftp) --fail --silent --list-only --connect-timeout 30 "$(url_ftp '')" 2>/dev/null | tr -d '\r'
  [ "${PIPESTATUS[0]}" -eq 0 ]
}

assistente_ftp() {
  local fp
  while :; do
    pedir FTP_BACKUP_HOST "Servidor FTP (endereço)"
    pedir FTP_BACKUP_USER "Usuário do FTP"
    while [ -z "${FTP_BACKUP_PASSWORD:-}" ]; do
      perguntar_oculto "Senha do FTP"
      case "$RESPOSTA" in
        *\"*|*\\*) echo "A senha do FTP não pode ter aspas duplas nem barra invertida (o envio usa um arquivo de configuração do curl)." ;;
        '') echo "Obrigatório." ;;
        *) gravar_env FTP_BACKUP_PASSWORD "$RESPOSTA" ;;
      esac
    done
    if LISTA_FTP="$(lista_ftp)"; then ok "FTP acessível"; return 0; fi
    echo "FTP sem acesso com esses dados ($FTP_BACKUP_HOST:$FTP_BACKUP_PORT$FTP_BACKUP_REMOTE_DIR). Informe de novo."
    for fp in FTP_BACKUP_HOST FTP_BACKUP_USER FTP_BACKUP_PASSWORD; do gravar_env "$fp" ""; done
  done
}

assistente_nome() {
  local padrao; padrao="$(hostname -s 2>/dev/null)"
  while :; do
    pedir SERVER_NAME "Nome do servidor (letras, números, '.', '-', '_')" "$padrao"
    if ! [[ "$SERVER_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "Nome inválido."; gravar_env SERVER_NAME ""; continue
    fi
    if ! grep -qE "$(padrao_backup_ftp)" <<<"$LISTA_FTP"; then ok "SERVER_NAME=$SERVER_NAME"; return 0; fi
    echo "Já existem backups de '$SERVER_NAME' no FTP: esse nome é de outro servidor."
    echo "Se é a reinstalação DESTE servidor, digite o nome de novo; Enter escolhe outro nome."
    perguntar "Confirmação"
    if [ "$RESPOSTA" = "$SERVER_NAME" ]; then ok "SERVER_NAME=$SERVER_NAME (reinstalação confirmada)"; return 0; fi
    gravar_env SERVER_NAME ""
  done
}

assistente_credencial() {
  gravar_env RCLONE_CONFIG_GDRIVE_TYPE drive
  gravar_env RCLONE_CONFIG_GDRIVE_SCOPE drive
  while [ -z "${RCLONE_CONFIG_GDRIVE_TOKEN:-}" ]; do
    perguntar_oculto "Token do rclone da conta do Drive (o JSON inteiro, em uma linha)"
    if jq -e 'type == "object"' <<<"$RESPOSTA" >/dev/null 2>&1; then
      gravar_env RCLONE_CONFIG_GDRIVE_TOKEN "$RESPOSTA"
      perguntar "Client ID próprio do rclone (Enter se a conta não usa)"
      if [ -n "$RESPOSTA" ]; then
        gravar_env RCLONE_CONFIG_GDRIVE_CLIENT_ID "$RESPOSTA"
        perguntar_oculto "Client Secret"
        gravar_env RCLONE_CONFIG_GDRIVE_CLIENT_SECRET "$RESPOSTA"
      fi
    else
      echo "Isso não é um JSON válido."
    fi
  done
}

# 0: Drive livre (agora reservado para este servidor) ou reinstalação confirmada; 1: escolher outro.
conferir_drive() {
  local id="$1" dia="$2" lista marcador outro conteudo
  marcador="$PREFIXO_MARCADOR$SERVER_NAME"
  if ! lista="$(TEMPO_LIMITE=300 rclone_em_container "$id" lsf "${RCLONE_REMOTE}:" --max-depth 1 2>/dev/null)"; then
    echo "Shared Drive inacessível: ID errado, a conta do backup não é membro, ou credencial inválida."
    return 1
  fi
  outro="$(grep -F "$PREFIXO_MARCADOR" <<<"$lista" | grep -vxF "$marcador" | head -1)"
  if [ -n "$outro" ]; then
    echo "Esse Shared Drive está reservado para o servidor '${outro#"$PREFIXO_MARCADOR"}'. Use outro."
    return 1
  fi
  conteudo="$(grep -vxF "$marcador" <<<"$lista" | grep -c .)"
  if [ "$conteudo" -gt 0 ]; then
    echo "Esse Shared Drive tem $conteudo item(ns) na raiz. O backup é um espelho: APAGARIA tudo o que está lá, inclusive o backup de outro servidor."
    echo "Se é a reinstalação DESTE servidor, digite o nome dele; Enter escolhe outro Drive."
    perguntar "Confirmação"
    [ "$RESPOSTA" = "$SERVER_NAME" ] && { ok "Drive de $dia: reinstalação confirmada"; return 0; }
    return 1
  fi
  if ! grep -qxF "$marcador" <<<"$lista"; then
    TEMPO_LIMITE=300 rclone_em_container "$id" touch "${RCLONE_REMOTE}:$marcador" >/dev/null 2>&1 \
      || { echo "Não consegui gravar no Shared Drive: a conta do backup precisa poder editar."; return 1; }
  fi
  ok "Drive de $dia: vazio e reservado para $SERVER_NAME"
}

assistente_drives() {
  local d k vistos=""
  for d in SEGUNDA TERCA QUARTA QUINTA SEXTA; do
    k="RCLONE_TEAM_DRIVE_$d"
    while :; do
      if [ -z "${!k:-}" ]; then
        perguntar "ID do Shared Drive de ${d,,} (fim da URL; 'credencial' redigita a credencial do Drive)"
        if [ "$RESPOSTA" = credencial ]; then
          gravar_env RCLONE_CONFIG_GDRIVE_TOKEN ""
          assistente_credencial
          continue
        fi
        if ! [[ "$RESPOSTA" =~ ^[A-Za-z0-9_-]+$ ]]; then echo "ID inválido."; continue; fi
        gravar_env "$k" "$RESPOSTA"
      fi
      if [[ " $vistos " == *" ${!k} "* ]]; then
        echo "Esse Shared Drive já foi usado em outro dia: são 5 Drives diferentes."
      elif conferir_drive "${!k}" "${d,,}"; then
        vistos="$vistos ${!k}"
        break
      fi
      gravar_env "$k" ""
    done
  done
}

assistente_env() {
  if [ ! -f "$ENV_ARQ" ]; then
    ( umask 077; cp "$DESTINO/.env.example" "$ENV_ARQ" ) || parar "Não consegui criar $ENV_ARQ"
  fi
  chmod 600 "$ENV_ARQ"
  # shellcheck disable=SC1091
  . "$DESTINO/lib/comum.sh"; . "$DESTINO/lib/drive.sh"; . "$DESTINO/lib/ftp.sh"
  carregar_env || parar "Não consegui ler $ENV_ARQ"

  assistente_ftp
  assistente_nome
  assistente_credencial
  assistente_drives
  pedir_oculto TINA_DB_PASSWORD "Senha do banco da TINA (usuário $TINA_DB_USER)"
  ok ".env completo, com permissão 600"
}

# ---------- Listas ----------

acrescentar_na_lista() {  # arquivo, texto
  local arq="$1"
  echo "$2 (uma por linha, começando com /; Enter vazio segue):"
  while :; do
    perguntar "  acrescentar"
    [ -z "$RESPOSTA" ] && return 0
    if [ "${RESPOSTA:0:1}" != / ]; then echo "  Precisa começar com /."; continue; fi
    grep -qxF -- "$RESPOSTA" "$arq" || printf '%s\n' "$RESPOSTA" >> "$arq"
  done
}

assistente_listas() {
  [ -f "$DESTINO/backup_sources.txt" ] || cat > "$DESTINO/backup_sources.txt" <<'EOF'
# Pastas que entram no backup (uma por linha). Ajuste para o servidor; linhas com # são ignoradas.
/etc/netplan
/etc/passwd
/etc/crontab
/etc/systemd/system
/home
/opt
EOF
  [ -f "$DESTINO/backup_excludes.txt" ] || cat > "$DESTINO/backup_excludes.txt" <<'EOF'
# Exclusões (uma por linha; ** vale qualquer subpasta). Logs que mudam durante o backup também
# entram aqui, senão a conferência do Drive acusa diferença.
/opt/backup-client/logs
/opt/backup-client/fila
/opt/backup-client/tmp
EOF
  echo "Entram no backup: $(grep -v '^#' "$DESTINO/backup_sources.txt" | tr '\n' ' ')"
  acrescentar_na_lista "$DESTINO/backup_sources.txt" "Outras pastas para o backup"
  echo "Exclusões: $(grep -v '^#' "$DESTINO/backup_excludes.txt" | tr '\n' ' ')"
  acrescentar_na_lista "$DESTINO/backup_excludes.txt" "Outras exclusões"
}

# ---------- Implantação ----------

passo_dependencias() {
  titulo "1. Dependências"
  local p faltam=()
  command -v apt-get >/dev/null || parar "Este instalador é para Ubuntu/Debian (apt-get não encontrado)."
  for p in sudo sysstat jq curl uuid-runtime postgresql-client; do
    dpkg -s "$p" >/dev/null 2>&1 && ok "$p" || faltam+=("$p")
  done
  if [ ${#faltam[@]} -gt 0 ]; then
    if DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null >/dev/null \
       && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${faltam[@]}" </dev/null >/dev/null; then
      feito "instalados: ${faltam[*]}"
    else
      parar "Não foi possível instalar: ${faltam[*]} (apt-get)"
    fi
  fi
}

passo_sysstat() {
  titulo "2. sysstat (métricas do dia)"
  if [ -f /etc/default/sysstat ]; then
    if grep -q '^ENABLED="true"' /etc/default/sysstat; then ok 'ENABLED="true"'
    else sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat && feito 'ENABLED="true"'; fi
  fi
  if command -v systemctl >/dev/null && systemctl list-unit-files sysstat.service >/dev/null 2>&1; then
    systemctl enable --now sysstat >/dev/null 2>&1
    systemctl enable --now sysstat-collect.timer sysstat-summary.timer >/dev/null 2>&1 || true
    [ "$(systemctl is-active sysstat 2>/dev/null)" = active ] && ok "sysstat ativo" || falha "sysstat não ficou ativo"
  else
    falha "systemd/sysstat indisponível: ligue a coleta do sysstat manualmente"
  fi
}

passo_docker() {
  titulo "3. Docker"
  docker info >/dev/null 2>&1 || parar "Docker ausente ou parado: instale o Docker (obrigatório) e rode este comando de novo."
  ok "$(docker --version)"
}

passo_acesso() {
  titulo "5. Acesso da TINA"
  local k chave
  if ! id tina >/dev/null 2>&1; then
    if [ -e /opt/tina-agent ]; then
      falha "/opt/tina-agent já existe sem o usuário tina: confira com o construtor"
    else
      useradd -m -d /opt/tina-agent -s /bin/bash tina && feito "usuário tina criado"
    fi
  fi
  if id tina >/dev/null 2>&1; then
    getent group docker >/dev/null && usermod -aG docker tina
    echo 'tina ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tina && chmod 440 /etc/sudoers.d/tina
    visudo -cf /etc/sudoers.d/tina >/dev/null && ok "tina: sudo e grupo docker" || falha "sudoers da tina inválido"
    install -d -m 700 -o tina -g tina /opt/tina-agent/.ssh
    echo "from=\"$IP_CONTROLE\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding $(cat "$PACOTE/acesso/tina.pub")" \
      > /opt/tina-agent/.ssh/authorized_keys
    chown tina:tina /opt/tina-agent/.ssh/authorized_keys && chmod 600 /opt/tina-agent/.ssh/authorized_keys
    ok "tina: chave da TINA (só do servidor de controle)"
  fi
  install -d -m 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
  for k in construtor mac-responsavel; do
    chave="$(cat "$PACOTE/acesso/$k.pub")"
    if grep -qF "$(awk '{print $2}' <<<"$chave")" /root/.ssh/authorized_keys; then ok "root: chave $k"
    else
      if [ "$k" = construtor ]; then
        echo "from=\"$IP_CONTROLE\",no-agent-forwarding,no-X11-forwarding $chave" >> /root/.ssh/authorized_keys
      else
        echo "$chave" >> /root/.ssh/authorized_keys
      fi
      feito "root: chave $k"
    fi
  done
  grep -Eiq '^\s*(AllowUsers|AllowGroups)\b' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
    && falha "o SSH tem AllowUsers/AllowGroups: inclua tina e root, senão a TINA não entra"
}

passo_crontab() {
  titulo "8. Crontab"
  garantir_monitor
  if tem_linha_backup; then ok "backup já agendado"; return 0; fi
  while ! [[ "$HORARIO" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; do
    perguntar "Horário do backup, segunda a sexta (HH:MM)"
    HORARIO="$RESPOSTA"
  done
  local h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]}))
  printf '\n# backup-client (TINA)\n%s %s * * 1-5 root %s/scripts/backup.sh --agendado\n' "$m" "$h" "$DESTINO" >> /etc/crontab \
    && feito "backup de segunda a sexta às $(printf '%02d:%02d' "$h" "$m")"
}

implantar() {
  { exec 3<"$ENTRADA"; } 2>/dev/null || parar "A implantação faz perguntas: rode num terminal."
  echo "Implantação do backup-client $(cat "$PACOTE/VERSION")"
  passo_dependencias
  passo_sysstat
  passo_docker
  titulo "4. Código"
  instalar_codigo && ok "backup-client $(cat "$DESTINO/VERSION") em $DESTINO"
  passo_acesso
  titulo "6. Configuração (.env)"
  assistente_env
  titulo "7. O que entra no backup"
  assistente_listas
  # O agendamento vem por último: é ele que marca a instalação como completa.
  if [ "$problemas" -gt 0 ]; then
    echo; echo "$problemas problema(s) acima: corrija e rode o comando de novo (o que já foi respondido fica guardado)."
    exit 1
  fi
  passo_crontab
  titulo "9. Conferência"
  if "$DESTINO/scripts/backup.sh" --check-config; then
    echo; echo "Tudo certo. O servidor entra no backup na próxima noite e a primeira coleta é o marco zero."
  else
    falha "--check-config acusou as falhas acima"
    echo "Se a única falha for 'sysstat: sem amostras hoje', é normal logo após ligar: confira em ~10 min com"
    echo "  $DESTINO/scripts/backup.sh --check-config"
    echo "Para corrigir outro valor, edite $ENV_ARQ e rode a mesma conferência."
  fi
  echo
  echo "=== Dados para o registro (mande ao construtor, para a TINA alcançar este servidor) ==="
  echo "nome: $SERVER_NAME"
  echo "porta_ssh: $(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
  echo "impressao: $(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}')"
  echo "ips_internos: $(hostname -I 2>/dev/null)"
  echo "ip_saida: $(curl -s --max-time 10 https://api.ipify.org || echo '?')"
  echo "=== FIM ==="
  [ "$problemas" -eq 0 ]
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --atualizar) ATUALIZAR=sim ;;
      --horario) HORARIO="${2:-}"; shift ;;
      *) parar "Opção desconhecida: $1 (ver o início de instalar.sh)" 2 ;;
    esac
    shift
  done
  [ "$(id -u)" = 0 ] || parar "Rode como root."
  trap limpar EXIT
  if [ "$ATUALIZAR" = sim ] && [ ! -f "$ENV_ARQ" ]; then
    parar "Não há instalação em $DESTINO para atualizar."
  fi
  obter_pacote
  if [ "$ATUALIZAR" = sim ] || { [ -f "$ENV_ARQ" ] && tem_linha_backup; }; then
    atualizar
  else
    implantar
  fi
}

# Numa linha só, no fim: com "curl | bash", nada roda se o download vier cortado.
main "$@"; exit $?
