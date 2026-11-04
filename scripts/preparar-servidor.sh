#!/usr/bin/env bash
# Prepara um servidor novo para o backup-client e para a TINA (kit do projeto TINA).
#
# Uso, como root, depois de copiar o kit do servidor de controle para /opt/backup-client
# (/opt/tina-agent/kit/backup-client, ver LEIA-ME.md do kit):
#
#   /opt/backup-client/scripts/preparar-servidor.sh [--horario "M H"]
#
# Pode rodar quantas vezes precisar: cada passo só age se faltar algo.
#   1. Dependências: sudo, sysstat, jq, curl, uuid-runtime, postgresql-client (instala as que faltam).
#   2. sysstat: liga a coleta de métricas (ENABLED="true", serviço e timers).
#   3. Docker: confere (obrigatório: o rclone roda em container; não é instalado por aqui).
#   4. Pastas logs, fila e tmp; permissões (.env 600).
#   5. Acesso da TINA: usuário "tina" (sudo, docker) e chaves (TINA, construtor e Mac do
#      responsável, as duas primeiras presas ao IP do servidor de controle). SSH não é alterado.
#   6. .env: SERVER_NAME e os 5 Shared Drives preenchidos e diferentes dos servidores que já
#      existem (o backup é um espelho: Drive repetido apagaria o backup de outro servidor).
#   7. Crontab: monitor a cada 5 min e o backup de segunda a sexta no horário escolhido.
#   8. --check-config do backup-client e os "Dados para o registro" (mandar ao construtor).
set -uo pipefail

RAIZ=/opt/backup-client
KIT="$RAIZ/kit"                 # arquivos do kit (chaves públicas, Drives e horários em uso)
IP_CONTROLE=177.170.20.101
HORARIO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --horario) HORARIO="$2"; shift 2 ;;
    *) sed -n '2,22p' "$0"; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "Rode como root." >&2; exit 1; }
[ "$(cd "$(dirname "$0")/.." && pwd)" = "$RAIZ" ] || { echo "A pasta precisa estar em $RAIZ." >&2; exit 1; }

problemas=0
ok() { printf 'OK     %s\n' "$*"; }
feito() { printf 'FEITO  %s\n' "$*"; }
falha() { printf 'FALHA  %s\n' "$*"; problemas=$((problemas + 1)); }
titulo() { printf '\n== %s ==\n' "$*"; }

titulo "1. Dependências"
faltam=()
for p in sudo sysstat jq curl uuid-runtime postgresql-client; do
  dpkg -s "$p" >/dev/null 2>&1 && ok "$p" || faltam+=("$p")
done
if [ ${#faltam[@]} -gt 0 ]; then
  if DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${faltam[@]}" >/dev/null; then
    feito "instalados: ${faltam[*]}"
  else
    falha "não foi possível instalar: ${faltam[*]} (apt-get)"
  fi
fi

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

titulo "3. Docker"
if docker info >/dev/null 2>&1; then ok "$(docker --version)"
else falha "Docker ausente ou parado: instale o Docker (obrigatório) e rode este script de novo"; fi

titulo "4. Pastas e permissões"
mkdir -p "$RAIZ/logs" "$RAIZ/tmp" "$RAIZ/fila" && chmod 700 "$RAIZ/tmp" "$RAIZ/fila" && ok "logs, fila, tmp"
chmod 755 "$RAIZ/scripts/"*.sh
[ -f "$RAIZ/.env" ] && chmod 600 "$RAIZ/.env" && ok ".env com permissão 600" || falha ".env não encontrado em $RAIZ"
for f in backup_sources.txt backup_excludes.txt; do [ -f "$RAIZ/$f" ] || : > "$RAIZ/$f"; done

titulo "5. Acesso da TINA"
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
  echo "from=\"$IP_CONTROLE\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding $(cat "$KIT/tina.pub")" \
    > /opt/tina-agent/.ssh/authorized_keys
  chown tina:tina /opt/tina-agent/.ssh/authorized_keys && chmod 600 /opt/tina-agent/.ssh/authorized_keys
  ok "tina: chave da TINA (só do servidor de controle)"
fi
install -d -m 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
for k in construtor mac-responsavel; do
  chave="$(cat "$KIT/$k.pub")"
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

titulo "6. .env do servidor"
valor() { grep -E "^$1=" "$RAIZ/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"'"; }
nome="$(valor SERVER_NAME)"
if [ -z "$nome" ]; then falha "SERVER_NAME vazio (ex.: SERVER_NAME=srv-novo)"
elif ! [[ "$nome" =~ ^[A-Za-z0-9._-]+$ ]]; then falha "SERVER_NAME só com letras, números, '.', '-', '_'"
elif grep -qxF "$nome" "$KIT/servidores-em-uso.txt" 2>/dev/null; then falha "SERVER_NAME=$nome já é de outro servidor: troque"
else ok "SERVER_NAME=$nome"; fi
for d in SEGUNDA TERCA QUARTA QUINTA SEXTA; do
  id_drive="$(valor "RCLONE_TEAM_DRIVE_$d")"
  if [ -z "$id_drive" ]; then falha "RCLONE_TEAM_DRIVE_$d vazio (Shared Drive deste servidor)"
  elif grep -qxF "$id_drive" "$KIT/drives-em-uso.txt" 2>/dev/null; then
    falha "RCLONE_TEAM_DRIVE_$d é o Shared Drive de outro servidor: o espelho apagaria o backup dele. Use um Drive novo."
  fi
done
[ "$(for d in SEGUNDA TERCA QUARTA QUINTA SEXTA; do valor "RCLONE_TEAM_DRIVE_$d"; done | grep . | sort -u | wc -l)" = 5 ] \
  && ok "5 Shared Drives diferentes, nenhum de outro servidor" \
  || falha "os 5 Shared Drives precisam ser diferentes entre si"

titulo "7. Crontab"
if grep -qE '^[^#].*/opt/backup-client/scripts/monitor\.sh' /etc/crontab; then ok "monitor a cada 5 min"
else printf '\n# backup-client (TINA): monitor contínuo\n*/5 * * * * root /opt/backup-client/scripts/monitor.sh\n' >> /etc/crontab && feito "monitor a cada 5 min"; fi
if grep -qE '^[^#].*/opt/backup-client/scripts/backup\.sh' /etc/crontab; then
  ok "backup: $(grep -E '^[^#].*/opt/backup-client/scripts/backup\.sh' /etc/crontab | awk '{print $1, $2, $5}')"
else
  echo "Horários já usados por outros servidores: $(tr '\n' ' ' < "$KIT/horarios-em-uso.txt" 2>/dev/null)"
  if [ -z "$HORARIO" ] && [ -t 0 ]; then read -r -p "Horário do backup, segunda a sexta (HH:MM): " HORARIO; fi
  if [[ "$HORARIO" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
    h=$((10#${BASH_REMATCH[1]})); m=$((10#${BASH_REMATCH[2]}))
    printf '\n# backup-client (TINA)\n%s %s * * 1-5 root /opt/backup-client/scripts/backup.sh --agendado\n' "$m" "$h" >> /etc/crontab \
      && feito "backup de segunda a sexta às $(printf '%02d:%02d' "$h" "$m")"
  else
    falha "horário do backup não definido: rode de novo com --horario HH:MM"
  fi
fi

titulo "8. Conferência"
if [ "$problemas" -eq 0 ]; then
  if "$RAIZ/scripts/backup.sh" --check-config; then
    echo; echo "Tudo certo. O servidor entra no backup na próxima noite e a primeira coleta é o marco zero."
  else
    echo; echo "Se a única falha for 'sysstat: sem amostras hoje', é normal logo após ligar: rode de novo em ~10 min."
  fi
else
  echo "$problemas problema(s) acima: corrija e rode este script de novo."
fi
echo
echo "=== Dados para o registro (mande ao construtor, para a TINA alcançar este servidor) ==="
echo "nome: ${nome:-?}"
echo "porta_ssh: $(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
echo "impressao: $(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}')"
echo "ips_internos: $(hostname -I 2>/dev/null)"
echo "ip_saida: $(curl -s --max-time 10 https://api.ipify.org || echo ?)"
echo "=== FIM ==="
[ "$problemas" -eq 0 ]
