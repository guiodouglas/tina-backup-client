#!/usr/bin/env bash
# Atualiza este servidor para a versão publicada no GitHub e confere com --check-config.
# Uso, como root: /opt/backup-client/scripts/atualizar.sh
#
# Roda o instalador único com --atualizar: troca só o código; mantém .env, listas, logs, fila e
# horário. Com backup em andamento, recusa sem alterar nada (código 3).
set -uo pipefail

URL=https://raw.githubusercontent.com/guiodouglas/tina-backup-client/main/instalar.sh
RAIZ="${RAIZ:-/opt/backup-client}"

[ "$(id -u)" = 0 ] || { echo "Rode como root." >&2; exit 1; }
# Com pipefail, uma falha do curl não passa por sucesso. O instalador troca este arquivo enquanto
# ele roda; o bash continua lendo a versão antiga até o exec, que já chama o código novo.
curl -fsSL "$URL" | bash -s -- --atualizar
rc=$?
[ "$rc" -eq 0 ] || { echo "Atualização não concluída (código $rc); versão atual: $(cat "$RAIZ/VERSION")." >&2; exit "$rc"; }
echo
echo "Conferência:"
exec "$RAIZ/scripts/backup.sh" --check-config
