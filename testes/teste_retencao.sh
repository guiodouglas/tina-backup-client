#!/usr/bin/env bash
# Testes da retenção no FTP (sem rede). Uso: bash testes/teste_retencao.sh
# O FTP é simulado por uma pasta temporária; as funções de rede são substituídas.
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
. "$RAIZ/lib/comum.sh"
. "$RAIZ/lib/ftp.sh"

FALHAS=0; TOTAL=0
confere() {  # descrição, obtido, esperado
  TOTAL=$((TOTAL + 1))
  if [ "$2" = "$3" ]; then echo "ok     $1"; else echo "FALHA  $1: obtido '$2', esperado '$3'"; FALHAS=$((FALHAS + 1)); fi
}

# Pasta real do FTP em 28/10/2026 (compartilhada com outros servidores).
PASTA_REAL='app-srv-a01_2026-10-26.tar.gz
app-srv-a01_2026-10-27.tar.gz
dados-srv-c_20261026-2100.tar.gz
dados-srv-c_20261027-2100.tar.gz
dados-srv-d_20261026-2200.tar.gz
dados-srv-d_20261027-2200.tar.gz
dados-srv-e_20261026-2100.tar.gz
dados-srv-e_20261027-2100.tar.gz
dados-srv-f_20261026-2100.tar.gz
dados-srv-f_20261027-2100.tar.gz
dados-srv-g_20261026-2200.tar.gz
dados-srv-g_20261027-2200.tar.gz
dados-srv-h_20261027-0100.tar.gz
dados-srv-h_20261028-0100.tar.gz
srv-web-b01_2026-10-26.tar.gz
srv-web-b01_2026-10-27.tar.gz'

echo "== regra (escolher_para_apagar) =="
SERVER_NAME=app-srv-a01
confere "28/10: 2 do servidor, retenção 3: nada" "$(escolher_para_apagar 3 app-srv-a01_2026-10-28.tar.gz <<<"$PASTA_REAL")" ""
confere "29/10: 3 do servidor: apaga o 26" \
  "$(escolher_para_apagar 3 app-srv-a01_2026-10-29.tar.gz <<<"$PASTA_REAL"$'\napp-srv-a01_2026-10-28.tar.gz')" \
  "app-srv-a01_2026-10-26.tar.gz"
confere "reenvio do mesmo dia não conta (28 já no FTP)" \
  "$(escolher_para_apagar 3 app-srv-a01_2026-10-28.tar.gz <<<"$PASTA_REAL"$'\napp-srv-a01_2026-10-28.tar.gz')" ""
confere "nunca mais de um por noite (5 no FTP, retenção 3)" \
  "$(printf 'app-srv-a01_2026-10-2%s.tar.gz\n' 1 2 3 4 5 | escolher_para_apagar 3 app-srv-a01_2026-10-26.tar.gz)" \
  "app-srv-a01_2026-10-21.tar.gz"
confere "ordem pela data, não pela listagem" \
  "$(printf 'app-srv-a01_2026-11-02.tar.gz\napp-srv-a01_2026-10-30.tar.gz\napp-srv-a01_2026-10-31.tar.gz\n' \
     | escolher_para_apagar 3 app-srv-a01_2026-11-03.tar.gz)" "app-srv-a01_2026-10-30.tar.gz"
confere "nome antigo com pontos não entra" \
  "$(printf 'app.srv.a01_2026-10-20.tar.gz\napp-srv-a01_2026-10-26.tar.gz\napp-srv-a01_2026-10-27.tar.gz\n' \
     | escolher_para_apagar 3 app-srv-a01_2026-10-28.tar.gz)" ""
confere "variações do nome não entram (sufixo, cópia, .sha256)" \
  "$(printf 'app-srv-a01_2026-10-20.tar.gz.sha256\napp-srv-a01_2026-10-21-copia.tar.gz\nxapp-srv-a01_2026-10-22.tar.gz\napp-srv-a01_2026-10-26.tar.gz\napp-srv-a01_2026-10-27.tar.gz\n' \
     | escolher_para_apagar 3 app-srv-a01_2026-10-28.tar.gz)" ""
SERVER_NAME=srv-web-b01
confere "srv-web-b01 não vê os arquivos dados-srv-*" \
  "$(escolher_para_apagar 2 srv-web-b01_2026-10-28.tar.gz <<<"$PASTA_REAL")" "srv-web-b01_2026-10-26.tar.gz"
SERVER_NAME=srv-web
confere "servidor com nome prefixo de outro (srv-web) não pega srv-web-b01" \
  "$(escolher_para_apagar 2 srv-web_2026-10-28.tar.gz <<<"$PASTA_REAL")" ""
SERVER_NAME=a.b
confere "ponto no nome é literal" \
  "$(printf 'aXb_2026-10-01.tar.gz\naXb_2026-10-02.tar.gz\n' | escolher_para_apagar 2 a.b_2026-10-03.tar.gz)" ""

echo "== retenção válida =="
for v in "" 0 1 abc 3x -3; do FTP_BACKUP_RETENCAO="$v"; retencao_valida; confere "inválida: '$v'" "$?" 1; done
for v in 2 3 10; do FTP_BACKUP_RETENCAO="$v"; retencao_valida; confere "válida: $v" "$?" 0; done

echo "== fluxo (aplicar_retencao_ftp com FTP simulado) =="
FTP_DIR="$(mktemp -d)"; LOG=/dev/null
trap 'rm -rf "$FTP_DIR"' EXIT
info() { :; }; aviso() { :; }; erro() { :; }
listar_backups_ftp() { [ "${FALHA_LISTA:-nao}" = nao ] || return 1; ls -1 "$FTP_DIR" | grep -E "$(padrao_backup_ftp)" | sort -u; }
tamanho_ftp() { stat -c %s "$FTP_DIR/$1" 2>/dev/null; }
apagar_ftp() { [ "${FALHA_APAGAR:-nao}" = nao ] && rm -f -- "$FTP_DIR/$1"; [ "${APAGA_DEMAIS:-nao}" = nao ] || rm -f -- "$FTP_DIR/$APAGA_DEMAIS"; }
preparar() { rm -f "$FTP_DIR"/*; for f in "$@"; do printf 'x%.0s' $(seq 1 ${#f}) > "$FTP_DIR/$f"; done; PROBLEMAS_JSON='[]'; RETENCAO_JSON=null; }
codigos() { jq -r '[.[].codigo] | join(",")' <<<"$PROBLEMAS_JSON"; }

SERVER_NAME=app-srv-a01; FTP_BACKUP_RETENCAO=3
preparar app-srv-a01_2026-10-26.tar.gz app-srv-a01_2026-10-27.tar.gz app-srv-a01_2026-10-28.tar.gz dados-srv-x_20261028-0100.tar.gz
aplicar_retencao_ftp app-srv-a01_2026-10-29.tar.gz
confere "apaga o 26" "$(ls "$FTP_DIR" | tr '\n' ' ')" "app-srv-a01_2026-10-27.tar.gz app-srv-a01_2026-10-28.tar.gz dados-srv-x_20261028-0100.tar.gz "
confere "sem problemas" "$(codigos)" ""
confere "registro" "$(jq -c '{manter, antes, apagados: [.apagados[].nome]}' <<<"$RETENCAO_JSON")" \
  '{"manter":3,"antes":3,"apagados":["app-srv-a01_2026-10-26.tar.gz"]}'
confere "tamanho do apagado registrado" "$(jq '.apagados[0].tamanho' <<<"$RETENCAO_JSON")" 29

preparar app-srv-a01_2026-10-26.tar.gz app-srv-a01_2026-10-27.tar.gz app-srv-a01_2026-10-28.tar.gz
aplicar_retencao_ftp app-srv-a01_2026-10-29.tar.gz sim
confere "simulação não apaga" "$(ls "$FTP_DIR" | wc -l)" 3
confere "simulação registra o que apagaria" "$(jq -c '[.simulacao, .apagados[0].nome]' <<<"$RETENCAO_JSON")" '[true,"app-srv-a01_2026-10-26.tar.gz"]'

preparar app-srv-a01_2026-10-26.tar.gz app-srv-a01_2026-10-27.tar.gz app-srv-a01_2026-10-28.tar.gz
FALHA_APAGAR=sim aplicar_retencao_ftp app-srv-a01_2026-10-29.tar.gz
confere "exclusão que não aconteceu vira problema" "$(codigos)" "FTP_RETENCAO_FALHOU"
confere "e não registra como apagado" "$(jq '.apagados | length' <<<"$RETENCAO_JSON")" 0

preparar app-srv-a01_2026-10-26.tar.gz app-srv-a01_2026-10-27.tar.gz app-srv-a01_2026-10-28.tar.gz
APAGA_DEMAIS=app-srv-a01_2026-10-28.tar.gz aplicar_retencao_ftp app-srv-a01_2026-10-29.tar.gz
confere "sumiço de outro backup é crítico" "$(jq -r '.[0] | .codigo + "/" + .gravidade' <<<"$PROBLEMAS_JSON")" "FTP_RETENCAO_FALHOU/CRITICO"

preparar app-srv-a01_2026-10-26.tar.gz app-srv-a01_2026-10-27.tar.gz app-srv-a01_2026-10-28.tar.gz
FALHA_LISTA=sim aplicar_retencao_ftp app-srv-a01_2026-10-29.tar.gz
confere "listagem falhou: nada apagado, problema" "$(ls "$FTP_DIR" | wc -l)/$(codigos)" "3/FTP_RETENCAO_FALHOU"

for v in "" 1; do
  preparar app-srv-a01_2026-10-26.tar.gz app-srv-a01_2026-10-27.tar.gz app-srv-a01_2026-10-28.tar.gz
  FTP_BACKUP_RETENCAO="$v"; aplicar_retencao_ftp app-srv-a01_2026-10-29.tar.gz
  confere "retenção '$v': nada apagado, problema" "$(ls "$FTP_DIR" | wc -l)/$(codigos)" "3/FTP_RETENCAO_FALHOU"
done

echo "== envio completo (executar_ftp com FTP simulado) =="
FTP_BACKUP_RETENCAO=3
# curl do envio: copia para a pasta simulada, ou falha como o servidor sem espaço.
curl() {
  local origem="" url=""
  while [ $# -gt 0 ]; do
    case "$1" in --upload-file) origem="$2"; shift ;; ftp://*) url="$1" ;; esac; shift
  done
  if [ "${SEM_ESPACO:-nao}" = sim ]; then echo "curl: (25) Failed FTP upload: 452" >&2; return 25; fi
  cp -- "$origem" "$FTP_DIR/${url##*/}"
}
TAR_DIR="$(mktemp -d)"; trap 'rm -rf "$FTP_DIR" "$TAR_DIR"' EXIT
novo_tar() { ARQ_TAR="$TAR_DIR/app-srv-a01_2026-10-29.tar.gz"; echo conteudo > "$ARQ_TAR"; touch "$ARQ_TAR.sha256"; }

preparar app-srv-a01_2026-10-26.tar.gz app-srv-a01_2026-10-27.tar.gz app-srv-a01_2026-10-28.tar.gz; novo_tar
executar_ftp
confere "envio: ficam 27, 28, 29" "$(ls "$FTP_DIR" | tr '\n' ' ')" \
  "app-srv-a01_2026-10-27.tar.gz app-srv-a01_2026-10-28.tar.gz app-srv-a01_2026-10-29.tar.gz "
confere "envio: documento" "$(jq -c '[.status, .retencao.antes, .retencao.depois, .retencao.apagados[0].nome]' <<<"$FTP_JSON")" \
  '["OK",3,3,"app-srv-a01_2026-10-26.tar.gz"]'
confere "envio: sem problemas e TAR local removido" "$(codigos)/$(ls "$TAR_DIR" | wc -l)" "/0"

preparar app-srv-a01_2026-10-28.tar.gz; novo_tar
executar_ftp
confere "poucos backups depois do envio: atenção" "$(codigos)/$(jq .retencao.depois <<<"$FTP_JSON")" "FTP_POUCOS_BACKUPS/2"

preparar app-srv-a01_2026-10-26.tar.gz app-srv-a01_2026-10-27.tar.gz app-srv-a01_2026-10-28.tar.gz; novo_tar
SEM_ESPACO=sim executar_ftp
confere "sem espaço: problema próprio, retenção no documento, TAR local fica" \
  "$(codigos)/$(jq -c '[.status, .retencao.apagados[0].nome]' <<<"$FTP_JSON")/$(ls "$TAR_DIR" | wc -l)" \
  'FTP_SEM_ESPACO/["ERRO","app-srv-a01_2026-10-26.tar.gz"]/2'

preparar app-srv-a01_2026-10-27.tar.gz app-srv-a01_2026-10-28.tar.gz; novo_tar
FTP_BACKUP_RETENCAO=""; executar_ftp
confere "retenção ausente: envia mesmo assim, sem campo retencao" \
  "$(codigos)/$(jq -c '[.status, has("retencao")]' <<<"$FTP_JSON")" 'FTP_RETENCAO_FALHOU/["OK",false]'

echo "testes: $TOTAL, falhas: $FALHAS"
[ $FALHAS -eq 0 ]
