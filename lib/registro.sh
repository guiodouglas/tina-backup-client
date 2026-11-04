# Registro do servidor no banco da TINA: pedido de registro (instalador) e aviso de desinstalação.
# Usa as variáveis do arquivo de configuração (carregar_env). A identidade do servidor é a impressão
# digital do SSH; o IP de saída é o que o banco vê na conexão (o instalador não o informa).

impressao_ssh() { ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}'; }
porta_ssh() { sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}'; }

# $1 = função de ingest; $2 = documento JSON. Imprime o resultado do banco (ou o erro).
chamar_ingest() {
  local doc rc
  doc="$(mktemp)" || return 1
  printf '%s' "$2" > "$doc"
  { printf '\\set doc `cat %q`\n' "$doc"; echo "SELECT ingest.$1(:'doc'::jsonb);"; } \
    | PGPASSWORD="$TINA_DB_PASSWORD" PGCONNECT_TIMEOUT=15 psql -X -q -t -A -v ON_ERROR_STOP=1 \
        "host=$TINA_DB_HOST port=$TINA_DB_PORT dbname=$TINA_DB_NAME user=$TINA_DB_USER sslmode=${TINA_DB_SSLMODE:-require}" 2>&1
  rc=${PIPESTATUS[1]}
  rm -f "$doc"
  return "$rc"
}

# Resultado: novo | troca | reativacao (a TINA registra o acesso em até 1 min) | ja_registrado | adotado.
pedir_registro_ao_banco() {
  local doc
  doc="$(jq -n --arg nome "$SERVER_NAME" --arg porta "$(porta_ssh)" --arg imp "$(impressao_ssh)" --arg ips "$(hostname -I 2>/dev/null)" \
    '{nome: $nome, porta: $porta, impressao: $imp, ips_internos: $ips}')" || return 1
  chamar_ingest pedir_registro "$doc"
}

# Resultado: desinstalado | ja_inativo.
avisar_desinstalacao_ao_banco() {
  local doc
  doc="$(jq -n --arg nome "$SERVER_NAME" --arg imp "$(impressao_ssh)" '{nome: $nome, impressao: $imp}')" || return 1
  chamar_ingest avisar_desinstalacao "$doc"
}
