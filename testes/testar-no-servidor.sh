#!/usr/bin/env bash
# Testa o código deste pacote no servidor, com a configuração instalada e sem instalar nada.
# Uso (a partir de uma cópia temporária do pacote): bash testes/testar-no-servidor.sh
#   1. --check-config (inclui o marcador de permissão de apagar no FTP)
#   2. simulação da retenção no FTP (só lista; nada é apagado)
#   3. com --apagar-de-verdade: a retenção real, sem envio (apaga o mais antigo se houver N)
# FTP_BACKUP_RETENCAO vem do .env instalado; se faltar (antes da 2.2.0), usa 3 só neste teste.
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
export RAIZ ARQUIVO_ENV=/opt/backup-client/.env
FTP_BACKUP_RETENCAO_TESTE="${FTP_BACKUP_RETENCAO_TESTE:-3}"

echo "== check-config (código $(cat "$RAIZ/VERSION")) =="
bash -c '. "$RAIZ/lib/comum.sh"; carregar_env || exit 1
  FTP_BACKUP_RETENCAO="${FTP_BACKUP_RETENCAO:-'"$FTP_BACKUP_RETENCAO_TESTE"'}"
  for lib in fontes drive tar ftp saude banco checar; do . "$RAIZ/lib/$lib.sh"; done
  iniciar_log; checar_configuracao' | grep -E 'FTP|SERVER_NAME|falhas'

echo "== simulação da retenção =="
bash -c '. "$RAIZ/lib/comum.sh"; . "$RAIZ/lib/tar.sh"; . "$RAIZ/lib/ftp.sh"; carregar_env || exit 1
  FTP_BACKUP_RETENCAO="${FTP_BACKUP_RETENCAO:-'"$FTP_BACKUP_RETENCAO_TESTE"'}"
  iniciar_log
  aplicar_retencao_ftp "$(basename "$(nome_tar)")" sim
  echo "retencao: $RETENCAO_JSON"; echo "problemas: $PROBLEMAS_JSON"' 2>&1 | sed 's/^[0-9T:.+-]* //'

# --apagar-de-verdade: roda a retenção real (a mesma função da noite, sem o envio) e lista o FTP.
if [ "${1:-}" = --apagar-de-verdade ]; then
  echo "== retenção real (sem envio) =="
  bash -c '. "$RAIZ/lib/comum.sh"; . "$RAIZ/lib/tar.sh"; . "$RAIZ/lib/ftp.sh"; carregar_env || exit 1
    FTP_BACKUP_RETENCAO="${FTP_BACKUP_RETENCAO:-'"$FTP_BACKUP_RETENCAO_TESTE"'}"
    iniciar_log
    aplicar_retencao_ftp "$(basename "$(nome_tar)")"
    echo "retencao: $RETENCAO_JSON"; echo "problemas: $PROBLEMAS_JSON"
    echo "no FTP agora: $(listar_backups_ftp | tr "\n" " ")"' 2>&1 | sed 's/^[0-9T:.+-]* //'
fi
