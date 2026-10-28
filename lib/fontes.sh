# Fontes e exclusões: o que entra no backup (Drive e TAR usam a mesma regra).

FONTES=()
EXCLUSOES=()
FONTES_AUSENTES=()

ler_lista() {
  local linha
  while IFS= read -r linha || [ -n "$linha" ]; do
    linha="${linha%$'\r'}"
    case "$linha" in ''|\#*) continue ;; esac
    printf '%s\n' "$linha"
  done < "$1"
}

e_padrao() { case "$1" in *[\*\?\[]*) return 0 ;; *) return 1 ;; esac; }

carregar_fontes() {
  local f
  FONTES=(); EXCLUSOES=(); FONTES_AUSENTES=()
  [ -f "$RAIZ/backup_sources.txt" ] || { problema SEM_FONTES CRITICO fontes "backup_sources.txt não encontrado"; return 1; }
  while IFS= read -r f; do
    if [ "${f:0:1}" != / ] || [ ! -e "$f" ]; then
      FONTES_AUSENTES+=("$f")
      problema FONTE_AUSENTE ATENCAO fontes "Fonte não encontrada: $f"
    else
      FONTES+=("$f")
    fi
  done < <(ler_lista "$RAIZ/backup_sources.txt")
  if [ -f "$RAIZ/backup_excludes.txt" ]; then
    while IFS= read -r f; do
      [ "${f:0:1}" = / ] && EXCLUSOES+=("$f")
    done < <(ler_lista "$RAIZ/backup_excludes.txt")
  fi
  if [ ${#FONTES[@]} -eq 0 ]; then
    problema SEM_FONTES CRITICO fontes "Nenhuma fonte disponível"
    return 1
  fi
}

# Impressão digital da configuração: muda só quando fontes ou exclusões mudam.
impressao_configuracao() {
  { ler_lista "$RAIZ/backup_sources.txt"; echo "--"; ler_lista "$RAIZ/backup_excludes.txt" 2>/dev/null; } \
    | sha256sum | awk '{print $1}'
}

configuracao_json() {
  jq -n --arg i "$(impressao_configuracao)" \
    --argjson f "$(ler_lista "$RAIZ/backup_sources.txt" | jq -R . | jq -s .)" \
    --argjson e "$( (ler_lista "$RAIZ/backup_excludes.txt" 2>/dev/null || true) | jq -R . | jq -s .)" \
    '{impressao: $i, fontes: $f, exclusoes: $e}'
}

# Filtro do rclone (caminhos relativos a /, que no container é /host).
gerar_filtro_rclone() {
  local saida="$1" x rel
  : > "$saida"
  for x in "${EXCLUSOES[@]}"; do
    rel="${x#/}"
    if e_padrao "$x"; then
      case "$rel" in
        *\*.[[:alnum:]_]*|*\?.[[:alnum:]_]*|*/\*\*) printf -- '- /%s\n' "$rel" >> "$saida" ;;
        *) printf -- '- /%s/**\n- /%s/\n' "$rel" "$rel" >> "$saida" ;;
      esac
    elif [ -d "$x" ]; then
      printf -- '- /%s/**\n- /%s/\n' "$rel" "$rel" >> "$saida"
    else
      printf -- '- /%s\n' "$rel" >> "$saida"
    fi
  done
  for x in "${FONTES[@]}"; do
    rel="${x#/}"
    if [ -d "$x" ]; then
      printf -- '+ /%s/\n+ /%s/**\n' "$rel" "$rel" >> "$saida"
    else
      printf -- '+ /%s\n' "$rel" >> "$saida"
    fi
  done
  printf -- '- **\n' >> "$saida"
}

argumentos_tar() {
  local x rel
  TAR_EXCLUSOES=(); TAR_ITENS=()
  for x in "${EXCLUSOES[@]}"; do
    rel="${x#/}"
    if e_padrao "$x"; then
      case "$rel" in
        */\*\*) TAR_EXCLUSOES+=("--exclude=$rel") ;;
        *) TAR_EXCLUSOES+=("--exclude=$rel" "--exclude=$rel/**") ;;
      esac
    else
      TAR_EXCLUSOES+=("--exclude=$rel" "--exclude=$rel/*")
    fi
  done
  for x in "${FONTES[@]}"; do TAR_ITENS+=("${x#/}"); done
}
