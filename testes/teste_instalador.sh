#!/usr/bin/env bash
# Testes do instalador num Ubuntu 24.04 descartável (precisa de Docker e de rede para o apt).
# Uso: bash testes/teste_instalador.sh  → "falhas: 0". Apaga o container no fim.
# Docker, systemctl, psql e o curl do FTP são simulados: Shared Drives = pastas em /drives; FTP = /ftp/lista.
set -uo pipefail
PACOTE="$(cd "$(dirname "$0")/.." && pwd)"
C="bc-teste-instalador-$$"
IMAGEM="${IMAGEM:-ubuntu:24.04}"
FALHAS=0; TOTAL=0
confere() {  # descrição, comando (roda no container)
  TOTAL=$((TOTAL + 1))
  if docker exec "$C" bash -c "$2" >/dev/null 2>&1; then echo "ok     $1"; else echo "FALHA  $1"; FALHAS=$((FALHAS + 1)); fi
}
trap 'docker rm -f "$C" >/dev/null 2>&1' EXIT

docker run -d --name "$C" "$IMAGEM" sleep 1800 >/dev/null || exit 1
docker exec "$C" bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl >/dev/null' || exit 1
docker exec "$C" mkdir -p /pacote /pacote-novo /stubs /drives/D1 /drives/D2 /drives/D3 /drives/D4 /drives/D5 \
  /drives/OCUPADO/home /drives/MARCADO /ftp
tar -C "$PACOTE" -cf - --exclude=.git . | docker exec -i "$C" tar -C /pacote -xf -
docker exec "$C" bash -c 'touch /drives/MARCADO/.backup-client-reservado-srv-outro
  printf "srv-ocupado_2026-11-01.tar.gz\r\nsrv-ocupado_2026-11-02.tar.gz\r\n" > /ftp/lista
  cp -R /pacote/. /pacote-novo/ && echo 9.9.9 > /pacote-novo/VERSION'

docker exec -i "$C" bash -c 'cat > /stubs/docker; chmod +x /stubs/docker' <<'EOF'
#!/bin/bash
case "$1" in
  info) exit 0 ;;
  --version) echo "Docker simulado"; exit 0 ;;
esac
id="$RCLONE_CONFIG_GDRIVE_TEAM_DRIVE"
[ -d "/drives/$id" ] || exit 3
for a in "$@"; do
  case "$a" in
    lsf) ls -Ap "/drives/$id"; exit 0 ;;
    touch) touch "/drives/$id/${!##gdrive:}"; exit 0 ;;
    deletefile) rm -f "/drives/$id/${!##gdrive:}"; exit 0 ;;
  esac
done
exit 0
EOF
docker exec -i "$C" bash -c 'cat > /stubs/systemctl; chmod +x /stubs/systemctl' <<'EOF'
#!/bin/bash
[ "$1" = is-active ] && echo active
exit 0
EOF
# timedatectl simulado: set-timezone aponta /etc/localtime para a zona (a imagem não traz tzdata).
docker exec -i "$C" bash -c 'cat > /stubs/timedatectl; chmod +x /stubs/timedatectl' <<'EOF'
#!/bin/bash
[ "$1" = set-timezone ] || exit 0
mkdir -p "/usr/share/zoneinfo/$(dirname "$2")" && touch "/usr/share/zoneinfo/$2" && ln -sf "/usr/share/zoneinfo/$2" /etc/localtime
EOF
# psql simulado: guarda o documento enviado às funções ingest.* em /tmp/psql-ingest (uma linha por chamada).
# /tmp/psql-resposta = resposta do pedir_registro (padrão ja_registrado); /tmp/psql-falha = banco fora.
docker exec -i "$C" bash -c 'cat > /stubs/psql; chmod +x /stubs/psql' <<'EOF'
#!/bin/bash
ent=""
[ -t 0 ] || ent="$(timeout 2 cat)"
case "$ent" in
  *"ingest."*)
    [ -e /tmp/psql-falha ] && { echo "psql: connection refused"; exit 2; }
    arq="$(grep -o 'cat [^`]*' <<<"$ent" | head -1 | cut -c5- | tr -d '\\')"
    echo "$(grep -o 'ingest\.[a-z_]*' <<<"$ent" | head -1) $(tr -d '\n' < "$arq")" >> /tmp/psql-ingest
    case "$ent" in
      *avisar_desinstalacao*) echo desinstalado ;;
      *) cat /tmp/psql-resposta 2>/dev/null || echo ja_registrado ;;
    esac ;;
esac
exit 0
EOF
docker exec -i "$C" bash -c 'cat > /stubs/ssh-keygen; chmod +x /stubs/ssh-keygen' <<'EOF'
#!/bin/bash
echo "256 SHA256:TESTEimpressao123 root@teste (ED25519)"
EOF
docker exec -i "$C" bash -c 'cat > /stubs/sshd; chmod +x /stubs/sshd' <<'EOF'
#!/bin/bash
echo "port 2281"
EOF
docker exec -i "$C" bash -c 'cat > /stubs/curl; chmod +x /stubs/curl' <<'EOF'
#!/bin/bash
[ -e /tmp/curl-falha ] && exit 22
case "$*" in
  *raw.githubusercontent.com*/instalar.sh*) cat /pacote-novo/instalar.sh; exit 0 ;;
  *raw.githubusercontent.com*/VERSION*) cat /pacote-novo/VERSION; exit 0 ;;
  *archive/refs/tags/*) tar -C / -czf - pacote-novo; exit 0 ;;
  *api.ipify*) echo 203.0.113.9; exit 0 ;;
  *ftp://errado*) exit 67 ;;
  *--list-only*) cat /ftp/lista; exit 0 ;;
esac
exit 0
EOF

roda() {  # arquivo de respostas (no container), argumentos do instalador
  local r="$1"; shift
  docker exec "$C" env PATH="/stubs:/usr/sbin:/usr/bin:/sbin:/bin" ENTRADA_INSTALADOR="$r" bash /pacote/instalar.sh "$@"
}

# --- Sem instalação: --atualizar recusa, sem criar nada.
confere "--atualizar sem instalação para com erro" '! ENTRADA_INSTALADOR=/dev/null bash /pacote/instalar.sh --atualizar'
confere "--atualizar sem instalação não cria a pasta" '[ ! -e /opt/backup-client ]'
SAIDA0="$(docker exec "$C" bash /pacote/instalar.sh 2>&1)"; RC0=$?
TOTAL=$((TOTAL + 1)); if [ "$RC0" -ne 0 ] && grep -q 'rode num terminal' <<<"$SAIDA0" && ! grep -q '/dev/tty' <<<"$SAIDA0"; then echo "ok     sem terminal: só a mensagem clara"; else echo "FALHA  sem terminal: rc=$RC0: $SAIDA0"; FALHAS=$((FALHAS + 1)); fi

# --- Implantação em duas partes: as respostas acabam no meio; a segunda rodada só pergunta o resto.
SENHA_FTP="a'b c\$d&e"
TOKEN='{"access_token":"tok-secreto-123","expiry":"2030-01-01T00:00:00Z"}'
{
  echo "errado.exemplo"; echo "usuario"; echo "senha\"recusada"; echo "qualquer"   # FTP inválido: pede de novo
  echo "ftp.exemplo"; echo "usuario"; printf '%s\n' "$SENHA_FTP"
  echo "nome com espaço"
  echo "srv-ocupado"; echo ""                                                       # nome com backup no FTP: recusa
  echo "srv-novo"
} | docker exec -i "$C" tee /tmp/respostas1 >/dev/null
{
  echo "nao-e-json"; printf '%s\n' "$TOKEN"; echo ""
  echo "inexistente"                                                                # inacessível
  echo "OCUPADO"; echo ""                                                           # com conteúdo: recusa
  echo "MARCADO"                                                                    # reservado para outro: recusa
  echo "D1"
  echo "D1"; echo "D2"                                                              # repetido: recusa
  echo "D3"; echo "D4"; echo "D5"
  echo "senha-banco-456"
  echo "/srv/dados"; echo "sem-barra"; echo ""
  echo "/srv/dados/cache/**"; echo ""
  echo ""                                                                     # fuso: padrão S
  echo "25:00"; echo "21:30"
} | docker exec -i "$C" tee /tmp/respostas2 >/dev/null

SAIDA1="$(roda /tmp/respostas1 2>&1)"; RC1=$?
TOTAL=$((TOTAL + 1)); if [ "$RC1" -ne 0 ] && grep -q 'o que já foi respondido fica guardado' <<<"$SAIDA1"; then echo "ok     respostas interrompidas: para com aviso"; else echo "FALHA  respostas interrompidas: rc=$RC1"; FALHAS=$((FALHAS + 1)); fi
confere "interrompido: sem linha de backup no crontab" '! grep -q scripts/backup.sh /etc/crontab'
confere "interrompido: .env com 600" '[ "$(stat -c %a /opt/backup-client/.env)" = 600 ]'

docker exec "$C" bash -c 'echo novo > /tmp/psql-resposta'
SAIDA2="$(roda /tmp/respostas2 2>&1)"; RC2=$?
docker exec "$C" rm -f /tmp/psql-resposta
echo "$SAIDA2" | tail -14
confere "dependências instaladas" 'command -v jq && command -v psql && command -v sar && command -v sudo && command -v uuidgen'
TOTAL=$((TOTAL + 1)); if grep -qE "tok-secreto|senha-banco-456|c\\\$d&e" <<<"$SAIDA1$SAIDA2"; then echo "FALHA  nenhuma senha na saída"; FALHAS=$((FALHAS + 1)); else echo "ok     nenhuma senha na saída"; fi
TOTAL=$((TOTAL + 1)); if [ "$(grep -c 'FALHA' <<<"$SAIDA2")" -le 2 ] && grep -q 'FALHA  sysstat: sem amostras hoje' <<<"$SAIDA2"; then echo "ok     --check-config: só o sysstat falta (normal logo após ligar)"; else echo "FALHA  --check-config: falhas inesperadas"; grep FALHA <<<"$SAIDA2"; FALHAS=$((FALHAS + 1)); fi
TOTAL=$((TOTAL + 1)); if grep -q '^nome: srv-novo' <<<"$SAIDA2" && grep -q '=== FIM ===' <<<"$SAIDA2"; then echo "ok     dados para o registro"; else echo "FALHA  dados para o registro"; FALHAS=$((FALHAS + 1)); fi

confere ".env: 600" '[ "$(stat -c %a /opt/backup-client/.env)" = 600 ]'
docker exec -i "$C" bash -c 'cat > /tmp/ler_env.sh' <<'EOF'
set -a; . /opt/backup-client/.env; set +a
[ "$SERVER_NAME" = srv-novo ] && [ "$FTP_BACKUP_HOST" = ftp.exemplo ] && [ "$FTP_BACKUP_PASSWORD" = "a'b c\$d&e" ] \
  && [ "$TINA_DB_PASSWORD" = senha-banco-456 ] && [ "$RCLONE_CONFIG_GDRIVE_TYPE" = drive ] \
  && [ "$(jq -r .access_token <<<"$RCLONE_CONFIG_GDRIVE_TOKEN")" = tok-secreto-123 ] \
  && [ "$RCLONE_TEAM_DRIVE_SEGUNDA $RCLONE_TEAM_DRIVE_TERCA $RCLONE_TEAM_DRIVE_QUARTA $RCLONE_TEAM_DRIVE_QUINTA $RCLONE_TEAM_DRIVE_SEXTA" = "D1 D2 D3 D4 D5" ] \
  && [ "$TINA_DB_HOST" = tina.ti9.com.br ] && [ "$FTP_BACKUP_RETENCAO" = 3 ]
EOF
confere ".env: valores certos, inclusive senha com aspas e símbolos" 'bash /tmp/ler_env.sh'
confere ".env: cada chave uma vez" '[ -z "$(grep -oE "^[A-Z_]+=" /opt/backup-client/.env | sort | uniq -d)" ]'
for d in D1 D2 D3 D4 D5; do confere "marcador em $d" "[ -f /drives/$d/.backup-client-reservado-srv-novo ]"; done
confere "Drive com conteúdo intocado" '[ "$(ls -A /drives/OCUPADO)" = home ]'
confere "Drive de outro servidor intocado" '[ "$(ls -A /drives/MARCADO)" = .backup-client-reservado-srv-outro ]'
TOTAL=$((TOTAL + 1)); if grep -q 'fuso alterado de .* para America/Sao_Paulo' <<<"$SAIDA2"; then echo "ok     implantação: fuso mudado para America/Sao_Paulo"; else echo "FALHA  implantação: fuso não mudou"; FALHAS=$((FALHAS + 1)); fi
confere "fuso: /etc/localtime em America/Sao_Paulo" '[ "$(readlink -f /etc/localtime)" = /usr/share/zoneinfo/America/Sao_Paulo ]'
confere "crontab: backup no horário" 'grep -qE "^30 21 \* \* 1-5 root /opt/backup-client/scripts/backup.sh --agendado$" /etc/crontab'
confere "crontab: monitor no formato do --check-config" 'grep -qE "^\*/5 \* \* \* \* root /opt/backup-client/scripts/monitor\.sh$" /etc/crontab'
confere "listas: padrão + acrescentados" 'grep -qx /opt /opt/backup-client/backup_sources.txt && grep -qx /srv/dados /opt/backup-client/backup_sources.txt && ! grep -q sem-barra /opt/backup-client/backup_sources.txt && grep -qxF "/srv/dados/cache/**" /opt/backup-client/backup_excludes.txt'
confere "código: só o necessário" '[ -x /opt/backup-client/scripts/backup.sh ] && [ -f /opt/backup-client/lib/comum.sh ] && [ ! -e /opt/backup-client/instalar.sh ] && [ ! -e /opt/backup-client/testes ] && [ -f /opt/backup-client/acesso/tina.pub ] && [ -z "$(ls -d /opt/backup-client/.novo.* 2>/dev/null)" ]'
confere "acesso: tina com chave presa ao IP do controle" 'id -nG tina >/dev/null && grep -q "^from=\"177.170.20.101\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 " /opt/tina-agent/.ssh/authorized_keys && [ "$(stat -c %U /opt/tina-agent/.ssh/authorized_keys)" = tina ] && visudo -cf /etc/sudoers.d/tina'
confere "acesso: root com construtor (preso) e Mac" '[ "$(grep -c ssh-ed25519 /root/.ssh/authorized_keys)" = 2 ] && grep -q "^from=\"177.170.20.101\"" /root/.ssh/authorized_keys'

# --- Registro na TINA: a implantação pede o registro com nome, porta e impressão digital do SSH.
TOTAL=$((TOTAL + 1)); if grep -q 'pedido de registro enviado' <<<"$SAIDA2"; then echo "ok     implantação: pedido de registro enviado"; else echo "FALHA  implantação: sem pedido de registro"; FALHAS=$((FALHAS + 1)); fi
confere "registro: documento com nome, porta e impressão do SSH" 'grep "^ingest.pedir_registro " /tmp/psql-ingest | head -1 | cut -d" " -f2- | jq -e ".nome == \"srv-novo\" and .porta == \"2281\" and .impressao == \"SHA256:TESTEimpressao123\""'
confere "registro: nenhuma senha no documento" '! grep -q senha-banco /tmp/psql-ingest'

# --- Atualização pelo mesmo comando: sem perguntas, nada além do código muda.
docker exec "$C" bash -c 'mkdir -p /opt/backup-client/logs/2026-11-01 && echo x > /opt/backup-client/logs/2026-11-01/backup.log && echo y > /opt/backup-client/fila/item.json
  mkdir -p /opt/backup-client/kit && touch /opt/backup-client/scripts/preparar-servidor.sh
  cd /opt/backup-client && sha256sum .env backup_sources.txt backup_excludes.txt logs/2026-11-01/backup.log fila/item.json /etc/crontab /root/.ssh/authorized_keys > /tmp/antes.sha'
docker exec "$C" bash -c 'mkdir -p /tmp/p && cp -R /pacote-novo/. /tmp/p/'
atualiza() { docker exec "$C" env PATH="/stubs:/usr/sbin:/usr/bin:/sbin:/bin" ENTRADA_INSTALADOR=/dev/null bash /pacote-novo/instalar.sh "$@"; }
SAIDA3="$(atualiza 2>&1)"; RC3=$?
TOTAL=$((TOTAL + 1)); if [ "$RC3" -eq 0 ] && grep -q 'atualizado: backup-client .* -> 9.9.9' <<<"$SAIDA3"; then echo "ok     mesmo comando atualiza, sem perguntas"; else echo "FALHA  atualização: rc=$RC3: $SAIDA3"; FALHAS=$((FALHAS + 1)); fi
confere "atualização: versão nova" '[ "$(cat /opt/backup-client/VERSION)" = 9.9.9 ]'
confere "atualização: confirma a identidade no banco (servidores antigos adotam a impressão)" '[ "$(grep -c "^ingest.pedir_registro " /tmp/psql-ingest)" = 2 ]'
docker exec "$C" touch /tmp/psql-falha
SAIDA3B="$(atualiza 2>&1)"; RC3B=$?
docker exec "$C" rm -f /tmp/psql-falha
TOTAL=$((TOTAL + 1)); if [ "$RC3B" -eq 0 ] && grep -q 'registro automático não concluído' <<<"$SAIDA3B"; then echo "ok     banco fora: atualiza e avisa que o registro não foi feito"; else echo "FALHA  banco fora na atualização: rc=$RC3B: $SAIDA3B"; FALHAS=$((FALHAS + 1)); fi
confere "atualização: .env, listas, logs, fila, crontab e chaves iguais" 'cd /opt/backup-client && sha256sum -c /tmp/antes.sha'
confere "atualização: resíduos antigos removidos" '[ ! -e /opt/backup-client/kit ] && [ ! -e /opt/backup-client/scripts/preparar-servidor.sh ]'

# Fuso fora do padrão: a atualização só avisa (não muda o fuso) e o --check-config acusa.
docker exec "$C" bash -c 'mkdir -p /usr/share/zoneinfo/Etc && touch /usr/share/zoneinfo/Etc/UTC && ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime'
SAIDA3C="$(atualiza 2>&1)"
TOTAL=$((TOTAL + 1)); if grep -q 'AVISO  fuso do servidor: Etc/UTC' <<<"$SAIDA3C"; then echo "ok     atualização: avisa fuso fora do padrão"; else echo "FALHA  atualização: sem aviso de fuso"; FALHAS=$((FALHAS + 1)); fi
confere "atualização: fuso não foi mudado" '[ "$(readlink -f /etc/localtime)" = /usr/share/zoneinfo/Etc/UTC ]'
CHK="$(docker exec "$C" env PATH="/stubs:/usr/sbin:/usr/bin:/sbin:/bin" /opt/backup-client/scripts/backup.sh --check-config 2>&1)"
TOTAL=$((TOTAL + 1)); if grep -q 'FALHA  fuso: Etc/UTC' <<<"$CHK"; then echo "ok     --check-config: acusa fuso fora do padrão"; else echo "FALHA  --check-config: não acusou o fuso"; FALHAS=$((FALHAS + 1)); fi
docker exec "$C" ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
CHK="$(docker exec "$C" env PATH="/stubs:/usr/sbin:/usr/bin:/sbin:/bin" /opt/backup-client/scripts/backup.sh --check-config 2>&1)"
TOTAL=$((TOTAL + 1)); if grep -q 'OK     fuso: America/Sao_Paulo' <<<"$CHK"; then echo "ok     --check-config: fuso certo"; else echo "FALHA  --check-config: fuso certo não apareceu"; FALHAS=$((FALHAS + 1)); fi

# Backup em andamento: recusa sem tocar em nada.
docker exec -d "$C" flock /opt/backup-client/tmp/backup.lock sleep 20
sleep 1
docker exec "$C" bash -c 'echo 8.8.8 > /pacote-novo/VERSION'
atualiza >/dev/null 2>&1; RC4=$?
TOTAL=$((TOTAL + 1)); if [ "$RC4" -eq 3 ]; then echo "ok     backup em andamento: recusa (código 3)"; else echo "FALHA  backup em andamento: rc=$RC4"; FALHAS=$((FALHAS + 1)); fi
confere "backup em andamento: versão não muda" '[ "$(cat /opt/backup-client/VERSION)" = 9.9.9 ]'

# Instalação até a 2.2.0: sem retenção e sem monitor; a atualização acrescenta.
docker exec "$C" bash -c 'pkill -f "sleep 20"; sleep 0.5; sed -i "/^FTP_BACKUP_RETENCAO=/d" /opt/backup-client/.env; sed -i "/scripts\/monitor.sh/d" /etc/crontab'
atualiza --atualizar >/dev/null 2>&1
confere "2.2.0: retenção acrescentada" 'grep -qx "FTP_BACKUP_RETENCAO=3" /opt/backup-client/.env'
confere "2.2.0: monitor acrescentado" 'grep -q "^\*/5 .*monitor.sh$" /etc/crontab'
confere "versão publicada: VERSION da fonte é X.Y.Z" 'grep -qE "^[0-9]+\.[0-9]+\.[0-9]+$" /pacote/VERSION'

# scripts/atualizar.sh: baixa o instalador e a tag, troca o próprio arquivo e confere com o código novo.
confere "atualizar.sh vem no pacote, executável" '[ -x /opt/backup-client/scripts/atualizar.sh ]'
atualizar_sh() { docker exec "$C" env PATH="/stubs:/usr/sbin:/usr/bin:/sbin:/bin" bash -c 'cd /opt/backup-client && scripts/atualizar.sh'; }
docker exec "$C" bash -c 'echo 7.7.7 > /pacote-novo/VERSION; echo "# código novo" >> /pacote-novo/scripts/atualizar.sh'
SAIDA5="$(atualizar_sh 2>&1)"
TOTAL=$((TOTAL + 1)); if grep -q 'atualizado: backup-client .* -> 7.7.7' <<<"$SAIDA5" && grep -q '^falhas: ' <<<"$SAIDA5"; then echo "ok     atualizar.sh: baixa, atualiza e confere"; else echo "FALHA  atualizar.sh: $SAIDA5"; FALHAS=$((FALHAS + 1)); fi
confere "atualizar.sh: trocou a si mesmo" 'grep -q "código novo" /opt/backup-client/scripts/atualizar.sh && [ "$(cat /opt/backup-client/VERSION)" = 7.7.7 ]'
docker exec "$C" bash -c 'touch /tmp/curl-falha; echo 6.6.6 > /pacote-novo/VERSION'
SAIDA6="$(atualizar_sh 2>&1)"; RC6=$?
docker exec "$C" rm -f /tmp/curl-falha
TOTAL=$((TOTAL + 1)); if [ "$RC6" -ne 0 ] && grep -q 'Atualização não concluída' <<<"$SAIDA6" && ! grep -q '^falhas: ' <<<"$SAIDA6"; then echo "ok     atualizar.sh: sem GitHub, acusa e não confere"; else echo "FALHA  atualizar.sh sem GitHub: rc=$RC6: $SAIDA6"; FALHAS=$((FALHAS + 1)); fi
confere "atualizar.sh: sem GitHub, versão não muda" '[ "$(cat /opt/backup-client/VERSION)" = 7.7.7 ]'
docker exec -d "$C" flock /opt/backup-client/tmp/backup.lock sleep 20
sleep 1
atualizar_sh >/dev/null 2>&1; RC7=$?
TOTAL=$((TOTAL + 1)); if [ "$RC7" -eq 3 ]; then echo "ok     atualizar.sh: backup em andamento devolve o código 3"; else echo "FALHA  atualizar.sh com backup em andamento: rc=$RC7"; FALHAS=$((FALHAS + 1)); fi
confere "atualizar.sh: backup em andamento, versão não muda" '[ "$(cat /opt/backup-client/VERSION)" = 7.7.7 ]'

# --- desinstalar.sh
desinstala() { docker exec "$C" env PATH="/stubs:/usr/sbin:/usr/bin:/sbin:/bin" bash -c 'cd /opt/backup-client && scripts/desinstalar.sh "$@"' _ "$@"; }
confere "desinstalar.sh vem no pacote, executável" '[ -x /opt/backup-client/scripts/desinstalar.sh ]'
docker exec -d "$C" flock /opt/backup-client/tmp/backup.lock sleep 20
sleep 1
desinstala --sim >/dev/null 2>&1; RC8=$?
TOTAL=$((TOTAL + 1)); if [ "$RC8" -eq 3 ]; then echo "ok     desinstalar: backup em andamento devolve o código 3"; else echo "FALHA  desinstalar com backup em andamento: rc=$RC8"; FALHAS=$((FALHAS + 1)); fi
confere "desinstalar: backup em andamento, nada muda" '[ -d /opt/backup-client ] && id tina'
docker exec "$C" pkill -f "^sleep 20"
docker exec "$C" bash -c 'for i in $(seq 25); do flock -n /opt/backup-client/tmp/backup.lock true && exit 0; sleep 1; done; exit 1'
docker exec "$C" touch /tmp/psql-falha
SAIDA9="$(desinstala --sim 2>&1)"; RC9=$?
TOTAL=$((TOTAL + 1)); if [ "$RC9" -ne 0 ] && grep -q 'Não consegui avisar o banco' <<<"$SAIDA9"; then echo "ok     desinstalar: banco fora não desinstala"; else echo "FALHA  desinstalar com banco fora: rc=$RC9: $SAIDA9"; FALHAS=$((FALHAS + 1)); fi
confere "desinstalar: banco fora, nada foi removido" '[ -d /opt/backup-client ] && id tina && grep -q "scripts/backup.sh" /etc/crontab && [ -f /etc/sudoers.d/tina ]'
docker exec "$C" rm -f /tmp/psql-falha
SAIDA10="$(desinstala --sim 2>&1)"; RC10=$?
echo "$SAIDA10" | tail -8
TOTAL=$((TOTAL + 1)); if [ "$RC10" -eq 0 ] && grep -q 'banco avisado: desinstalado' <<<"$SAIDA10"; then echo "ok     desinstalar: avisa o banco e conclui"; else echo "FALHA  desinstalar: rc=$RC10"; FALHAS=$((FALHAS + 1)); fi
confere "desinstalar: documento com nome e impressão do SSH" 'grep "^ingest.avisar_desinstalacao " /tmp/psql-ingest | tail -1 | cut -d" " -f2- | jq -e ".nome == \"srv-novo\" and .impressao == \"SHA256:TESTEimpressao123\""'
confere "desinstalar: pasta removida" '[ ! -e /opt/backup-client ]'
confere "desinstalar: crontab sem backup-client" '! grep -q "backup-client" /etc/crontab'
confere "desinstalar: usuário tina, sudoers e pasta removidos" '! id tina && [ ! -e /etc/sudoers.d/tina ] && [ ! -e /opt/tina-agent ]'
confere "desinstalar: chaves do construtor e do Mac removidas" '[ "$(grep -c ssh-ed25519 /root/.ssh/authorized_keys)" = 0 ]'
confere "desinstalar: marcadores dos Drives removidos" '[ -z "$(find /drives/D1 /drives/D2 /drives/D3 /drives/D4 /drives/D5 -name ".backup-client-reservado-*")" ]'
confere "desinstalar: Drive com conteúdo de outro intocado" '[ "$(ls -A /drives/OCUPADO)" = home ]'

echo "testes: $TOTAL, falhas: $FALHAS"
[ "$FALHAS" -eq 0 ]
