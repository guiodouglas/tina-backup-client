#!/usr/bin/env bash
# Testes da lista de containers do monitor e da saúde: o rclone temporário do próprio backup-client
# (label tina.backup-client) fica fora (2.6.2). Precisa de Docker; cria e apaga containers de teste.
# Uso: bash testes/teste_containers.sh  → "falhas: 0".
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
. "$RAIZ/lib/comum.sh"
. "$RAIZ/lib/drive.sh"

FALHAS=0; TOTAL=0
confere() {  # descrição, comando
  TOTAL=$((TOTAL + 1))
  if eval "$2"; then echo "ok     $1"; else echo "FALHA  $1"; FALHAS=$((FALHAS + 1)); fi
}
P="bc-teste-ctr-$$"
trap 'docker rm -f "$P-servidor" "$P-rclone" >/dev/null 2>&1' EXIT

docker run -d --name "$P-servidor" "$IMAGEM_RCLONE" rcd --rc-no-auth >/dev/null || exit 1
# O mesmo docker run do rclone_em_container (mesma label), mas em segundo plano e com nome, para o teste achá-lo.
docker run -d --name "$P-rclone" --label "$ROTULO_BACKUP_CLIENT=rclone" "$IMAGEM_RCLONE" rcd --rc-no-auth >/dev/null || exit 1
id_srv="$(docker ps -aq --filter "name=$P-servidor")"; id_rcl="$(docker ps -aq --filter "name=$P-rclone")"
lista="$(ids_containers)"

confere "container do servidor entra na lista" 'grep -qx "$id_srv" <<<"$lista"'
confere "rclone do backup-client fica fora" '! grep -qx "$id_rcl" <<<"$lista"'
confere "nenhum container com a label na lista" \
  '[ -z "$(comm -12 <(sort <<<"$lista") <(docker ps -aq --filter label=$ROTULO_BACKUP_CLIENT | sort))" ]'
confere "rclone_em_container põe a label" \
  'grep -q -- "--label \"\${ROTULO_BACKUP_CLIENT:-tina.backup-client}=rclone\"" "$RAIZ/lib/drive.sh"'
docker rm -f "$P-servidor" >/dev/null
lista2="$(ids_containers)"
confere "sem o container do servidor, a lista não traz o rclone" '! grep -qx "$id_rcl" <<<"$lista2"'

echo "testes: $TOTAL, falhas: $FALHAS"
[ "$FALHAS" -eq 0 ]
