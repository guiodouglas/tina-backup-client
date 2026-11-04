#!/usr/bin/env bash
# Desinstala o backup-client deste servidor: avisa o banco (o servidor fica INATIVO no monitoramento,
# com o histórico), remove o crontab, o usuário tina, as chaves de acesso e /opt/backup-client.
# Os backups já enviados ao FTP e aos Drives ficam. Reinstalar depois: o instalador compara a
# impressão digital do SSH (igual: só reativa; diferente: novo servidor, o antigo fica inativo).
#
# Uso, como root: /opt/backup-client/scripts/desinstalar.sh [--sim] [--sem-banco]
#   --sim         não pede a confirmação (digitar o nome do servidor)
#   --sem-banco   segue mesmo sem avisar o banco (avise o construtor: o servidor continuará ativo lá)
# Não remove pacotes (sudo, sysstat, jq, postgresql-client...) nem o Docker.
set -uo pipefail

RAIZ="${RAIZ:-/opt/backup-client}"
SIM=nao; SEM_BANCO=nao
for a in "$@"; do
  case "$a" in
    --sim) SIM=sim ;;
    --sem-banco) SEM_BANCO=sim ;;
    *) echo "Opção desconhecida: $a (ver o início de $0)" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "Rode como root." >&2; exit 1; }
[ -d "$RAIZ" ] || { echo "Não há instalação em $RAIZ." >&2; exit 1; }

# shellcheck disable=SC1091
. "$RAIZ/lib/comum.sh"; . "$RAIZ/lib/drive.sh"; . "$RAIZ/lib/registro.sh"
carregar_env || exit 1
LOG=/dev/null

mkdir -p "$RAIZ/tmp"
exec 9>"$RAIZ/tmp/backup.lock"
flock -n 9 || { echo "ERRO   Backup em andamento neste servidor: nada foi alterado; tente depois que ele terminar." >&2; exit 3; }

echo "Desinstalar o backup-client do servidor '$SERVER_NAME'."
echo "Será removido: o crontab do backup e do monitor, /opt/backup-client (logs, fila e arquivos temporários),"
echo "o usuário tina e as chaves do construtor e do Mac. Os backups no FTP e nos Drives ficam."
if [ "$SIM" != sim ]; then
  read -r -p "Digite o nome do servidor para confirmar: " resposta < /dev/tty || exit 1
  [ "$resposta" = "$SERVER_NAME" ] || { echo "Nome diferente: nada foi alterado."; exit 1; }
fi

# 1. Avisar o banco antes de tirar o acesso: depois disso a TINA não alcança mais o servidor.
if [ "$SEM_BANCO" = sim ]; then
  echo "AVISO  sem avisar o banco: o servidor continua ATIVO no monitoramento até o construtor desativá-lo."
else
  r="$(avisar_desinstalacao_ao_banco)" || {
    echo "ERRO   Não consegui avisar o banco: $r" >&2
    echo "       Nada foi alterado. Resolva a conexão ou use --sem-banco (e avise o construtor)." >&2
    exit 1; }
  echo "FEITO  banco avisado: $r (servidor inativo no monitoramento)"
fi

# 2. Marcador de reserva nos Shared Drives (só existe se ainda não houve backup naquele Drive).
for d in SEGUNDA TERCA QUARTA QUINTA SEXTA; do
  v="RCLONE_TEAM_DRIVE_$d"
  [ -n "${!v:-}" ] && TEMPO_LIMITE=120 rclone_em_container "${!v}" deletefile "${RCLONE_REMOTE}:.backup-client-reservado-$SERVER_NAME" >/dev/null 2>&1
done

# 3. Crontab: o comentário e as linhas do backup e do monitor.
sed -i -e "\#$RAIZ/scripts/#d" -e '/^# backup-client (TINA)/d' /etc/crontab && echo "FEITO  crontab limpo"

# 4. Acessos: chaves do construtor e do Mac no root, usuário tina e sudoers.
if [ -f /root/.ssh/authorized_keys ]; then
  for k in construtor mac-responsavel; do
    blob="$(awk '{print $2}' "$RAIZ/acesso/$k.pub" 2>/dev/null)"
    [ -n "$blob" ] && sed -i "\#$blob#d" /root/.ssh/authorized_keys
  done
  echo "FEITO  chaves do construtor e do Mac removidas do root"
fi
if id tina >/dev/null 2>&1; then
  pkill -KILL -u tina 2>/dev/null
  userdel -r tina >/dev/null 2>&1
  echo "FEITO  usuário tina removido"
fi
rm -f /etc/sudoers.d/tina

# 5. O código e os dados locais (por último: este script está dentro da pasta).
cd / && rm -rf -- "$RAIZ" && echo "FEITO  $RAIZ removido"
echo
echo "Desinstalado. Para voltar: rode o instalador único (curl ... | bash); a TINA reconhece o servidor."
