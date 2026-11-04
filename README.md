# tina-backup-client

Backup de servidores Linux (Ubuntu/Debian) e entrega do resultado ao banco da TINA, a agente de
infraestrutura da Ti9. Toda noite: espelho no Google Drive (um Shared Drive por dia útil) e um
TAR.GZ no FTP, com retenção. A cada 5 minutos: monitor de saúde e containers.

## Instalar ou atualizar

O mesmo comando, como root:

```bash
curl -fsSL https://raw.githubusercontent.com/guiodouglas/tina-backup-client/main/instalar.sh | bash
```

- **Servidor novo:** instala as dependências, confere o Docker, cria o acesso da TINA e pergunta o
  que falta (FTP, nome, credencial do Drive, 5 Shared Drives, senha do banco, listas e horário).
  Pode rodar de novo: o que já foi respondido fica guardado.
- **Servidor já instalado:** troca só o código, sem perguntar nada. Mantém `.env`,
  `backup_sources.txt`, `backup_excludes.txt`, logs, fila e crontab.

Em servidor com a versão 2.3.1 ou mais nova, atualizar é só rodar
`/opt/backup-client/scripts/atualizar.sh`, que também confere com `--check-config` no fim.

No fim da implantação o instalador pede ao banco da TINA o **registro do servidor**: a identidade é a
impressão digital do SSH. A TINA registra o acesso sozinha em até 1 min e avisa no Chat. Reinstalar o
mesmo servidor só o reativa; um servidor diferente com o mesmo nome fica como entrada nova (a antiga
fica inativa, com o histórico).

**Desinstalar:** `/opt/backup-client/scripts/desinstalar.sh` (pede o nome do servidor para confirmar).
Avisa o banco (o servidor fica inativo no monitoramento) e remove crontab, usuário `tina`, chaves de
acesso e `/opt/backup-client`. Os backups já enviados ao FTP e aos Drives ficam.

Antes de implantar: Docker instalado e 5 Shared Drives **vazios e só deste servidor**, com a conta
do backup como membro. O backup é um espelho: um Drive que já tem conteúdo teria tudo apagado, e por
isso o instalador o recusa.

Detalhes no início de [`instalar.sh`](instalar.sh). Os segredos ficam só no `.env` de cada servidor
(permissão 600) e nunca neste repositório.

## Uso no servidor

```bash
/opt/backup-client/scripts/backup.sh --check-config   # confere configuração e conexões
/opt/backup-client/scripts/backup.sh --dry-run        # simula, sem enviar nada
/opt/backup-client/scripts/backup.sh --help           # todos os modos
```

## Testes

```bash
bash testes/teste_retencao.sh     # retenção no FTP, sem rede
bash testes/teste_instalador.sh   # instalador num Ubuntu 24.04 descartável (precisa de Docker)
```
