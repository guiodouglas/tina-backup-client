#!/usr/bin/env bash
# Testes do filtro do rclone para exclusões (usa o rclone da imagem se houver Docker).
# Uso: bash testes/teste_filtro.sh
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
. "$RAIZ/lib/fontes.sh"

FALHAS=0; TOTAL=0
confere() {  # descrição, obtido, esperado
  TOTAL=$((TOTAL + 1))
  if [ "$2" = "$3" ]; then echo "ok     $1"; else echo "FALHA  $1: obtido '$2', esperado '$3'"; FALHAS=$((FALHAS + 1)); fi
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src/pg/base/1" "$T/src/pg/log" "$T/src/pg/pg_wal"
touch "$T/src/pg/base/1/a" "$T/src/pg/base/solto" "$T/src/pg/log/l.log" "$T/src/pg/pg_wal/w" "$T/src/pg/f"

filtro() {  # exclusões...; imprime só as linhas de exclusão
  EXCLUSOES=("$@"); FONTES=()
  gerar_filtro_rclone "$T/f.txt"; grep '^- ' "$T/f.txt"
}

confere "pasta/** exclui o conteúdo e mantém a pasta" \
  "$(filtro "/pg/base/**")" $'- /pg/base/*\n- /pg/base/*/**\n- **'
confere "padrão no meio do caminho" \
  "$(filtro "/var/www/**/data/logs/**")" $'- /var/www/**/data/logs/*\n- /var/www/**/data/logs/*/**\n- **'
confere "arquivo por extensão não muda" "$(filtro "/pg/*.log")" $'- /pg/*.log\n- **'

if command -v docker >/dev/null 2>&1 && docker image inspect rclone/rclone:1.75.0 >/dev/null 2>&1; then
  EXCLUSOES=("/pg/base/**" "/pg/log/**"); FONTES=()
  gerar_filtro_rclone "$T/f.txt"; sed -i '/^- \*\*$/d' "$T/f.txt"
  docker run --rm -v "$T:/t" rclone/rclone:1.75.0 copy /t/src /t/dst --filter-from /t/f.txt --create-empty-src-dirs >/dev/null 2>&1
  confere "rclone: pastas ficam vazias e o resto vai" \
    "$(cd "$T/dst" && find . | sort | tr '\n' ' ')" ". pg pg/base pg/f pg/log pg/pg_wal pg/pg_wal/w "
fi

echo "total: $TOTAL, falhas: $FALHAS"; [ "$FALHAS" -eq 0 ]
