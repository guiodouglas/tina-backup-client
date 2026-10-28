#!/usr/bin/env bash
# Testa o código deste pacote no servidor, com a configuração instalada e sem instalar nada.
# Uso (a partir de uma cópia temporária do pacote):
#   bash testes/testar-no-servidor.sh                      --check-config e simulação da retenção
#   bash testes/testar-no-servidor.sh --criar-vazio DATA   cria <servidor>_DATA.tar.gz vazio no FTP
#   bash testes/testar-no-servidor.sh --apagar-de-verdade NOME
#        retenção real, sem envio (a mesma função da noite); só roda se a regra escolher
#        exatamente NOME; senão para sem apagar nada
# FTP_BACKUP_RETENCAO vem do .env instalado; se faltar (antes da 2.2.0), usa 3 só neste teste.
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
export RAIZ ARQUIVO_ENV=/opt/backup-client/.env MODO_TESTE="${1:-}" ARG_TESTE="${2:-}"
export FTP_BACKUP_RETENCAO_TESTE="${FTP_BACKUP_RETENCAO_TESTE:-3}"

if [ -z "$MODO_TESTE" ]; then
  echo "== check-config (código $(cat "$RAIZ/VERSION")) =="
  bash -c '. "$RAIZ/lib/comum.sh"; carregar_env || exit 1
    FTP_BACKUP_RETENCAO="${FTP_BACKUP_RETENCAO:-$FTP_BACKUP_RETENCAO_TESTE}"
    for lib in fontes drive tar ftp saude banco checar; do . "$RAIZ/lib/$lib.sh"; done
    iniciar_log; checar_configuracao' | grep -E 'FTP|SERVER_NAME|falhas'
fi

bash -c '. "$RAIZ/lib/comum.sh"; . "$RAIZ/lib/tar.sh"; . "$RAIZ/lib/ftp.sh"; carregar_env || exit 1
  FTP_BACKUP_RETENCAO="${FTP_BACKUP_RETENCAO:-$FTP_BACKUP_RETENCAO_TESTE}"
  iniciar_log
  NOVO="$(basename "$(nome_tar)")"
  case "$MODO_TESTE" in
    "")
      echo "== simulação da retenção =="
      aplicar_retencao_ftp "$NOVO" sim ;;
    --criar-vazio)
      [[ "$ARG_TESTE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "DATA inválida: $ARG_TESTE"; exit 2; }
      nome="${SERVER_NAME}_${ARG_TESTE}.tar.gz"
      echo "== criar $nome vazio =="
      if listar_backups_ftp | grep -qxF -- "$nome"; then echo "já existe: nada feito"; exit 2; fi
      curl -K <(curl_cfg_ftp) --fail --silent --show-error --connect-timeout 20 \
        --upload-file /dev/null "$(url_ftp "$nome")" && echo "criado: $nome (0 bytes)" ;;
    --apagar-de-verdade)
      alvo="$(listar_backups_ftp | escolher_para_apagar "$FTP_BACKUP_RETENCAO" "$NOVO")"
      echo "== retenção real (sem envio): a regra escolhe ${alvo:-nada} =="
      if [ -z "$ARG_TESTE" ] || [ "$alvo" != "$ARG_TESTE" ]; then
        echo "PARADO: esperado ${ARG_TESTE:-?}; nada foi apagado"; exit 2
      fi
      aplicar_retencao_ftp "$NOVO" ;;
    *) echo "Opção desconhecida: $MODO_TESTE"; exit 2 ;;
  esac
  echo "retencao: $RETENCAO_JSON"; echo "problemas: $PROBLEMAS_JSON"
  echo "no FTP agora: $(listar_backups_ftp | tr "\n" " ")"' 2>&1 | sed 's/^[0-9T:.+-]* //'
