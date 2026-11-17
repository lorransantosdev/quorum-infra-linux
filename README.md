# Quorum · Infraestrutura Linux

Global Solution 2026.2 · **Operating Systems** · Engenharia de Software, 3º ano

Infraestrutura Linux automatizada em Shell Script para hospedar a API da **Quorum**, a CitizenTech da equipe. Um único comando prepara o servidor do zero: hostname, rede, DNS, usuários, dependências, banco, aplicação, serviços systemd, monitoramento com alertas e trilha de auditoria.

## Integrantes

| Nome | RM |
|------|----|
| Lorran ‹sobrenome› | RM ‹preencher› |
| Pedro ‹sobrenome› | RM ‹preencher› |
| Fabiano ‹sobrenome› | RM ‹preencher› |
| Gardim ‹nome completo› | RM ‹preencher› |

## A CitizenTech hospedada

| | |
|---|---|
| **Nome** | Quorum · *Milhares de pontos. Uma só usina.* |
| **Cidade** | São Paulo – SP |
| **Cidadão beneficiado** | Pequenos e médios comércios (supermercados, academias, clínicas) e quem depende da rede no fim da tarde |
| **Problema** | No fim da tarde a rede elétrica fica no limite e o comércio paga multa de ultrapassagem de demanda, enquanto baterias, carros elétricos e ar-condicionados ficam parados, sem coordenação |
| **Como funciona** | A Quorum conecta esses equipamentos e os aciona juntos, como uma usina virtual, na hora em que a rede precisa |
| **Aplicação** | API REST em Python/FastAPI + PostgreSQL ([repositório da API](https://github.com/lorransantosdev/quorum-api)) |
| **ODS** | 7 (energia limpa), 9 (infraestrutura), 11 (cidades sustentáveis), 13 (clima) |

## Arquitetura do servidor

```
                       ┌──────────────────────── quorum-srv01 (Ubuntu 24.04) ────────────────────────┐
 cliente HTTP ──:80──▶ │ nginx ──▶ quorum-api.service (uvicorn 127.0.0.1:8000, usuário quorum)       │
 api.quorum.local      │                   │                                                         │
 (10.77.0.10)          │                   └──▶ postgresql (db.quorum.local:5432, banco quorum)      │
                       │                                                                             │
                       │ quorum-monitor.service ── CPU / RAM / disco / serviços / GET /health        │
                       │        │ alerta, reinicia o que caiu                                        │
                       │        ▼                                                                    │
                       │ /var/log/quorum: monitor.log · alertas.log · auditoria.log · api.log ...   │
                       └─────────────────────────────────────────────────────────────────────────────┘
```

## Estrutura do repositório

```
provisionar.sh                 orquestrador: roda 01, 02 e 03 e mostra o status final
config/quorum.conf             todas as variáveis (hostname, IPs, DNS, limites, repositório da app)
scripts/
  lib/comum.sh                 logs, auditoria, trap de erro, validações
  01-infraestrutura.sh         hostname, fuso, IP, /etc/hosts, DNS, usuários, sudoers, diretórios, firewall
  02-aplicacao.sh              pacotes, PostgreSQL, código, venv, .env, migrações, systemd, nginx
  03-monitoramento.sh          monitor como serviço, logrotate, regras do auditd
  monitor-recursos.sh          o monitor (instalado como /usr/local/bin/quorum-monitor)
  testes-falha.sh              simulações de falha e verificação da recuperação
  status.sh                    painel do servidor
  coletar-evidencias.sh        gera as evidências em texto em evidencias/
  remover.sh                   desfaz tudo para reproduzir do zero
systemd/                       quorum-api.service, quorum-monitor.service
nginx/quorum.conf              proxy reverso
logrotate/quorum               rotação dos logs
auditoria/quorum.rules         regras do auditd
evidencias/                    saídas reais e capturas de tela
```

## Requisitos

- Ubuntu Server 24.04 LTS (VM local no VirtualBox/Hyper-V, VM na Azure) **ou** Ubuntu 24.04 no WSL2 com systemd.
- Usuário com `sudo` e acesso à internet.

## Como reproduzir o ambiente

### Opção 1 · Máquina virtual (VirtualBox ou Azure)

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/lorransantosdev/quorum-infra-linux.git
cd quorum-infra-linux
sudo ./provisionar.sh
```

Na VM o script detecta o `netplan` e grava `/etc/netplan/60-quorum.yaml` com o IP de serviço `10.77.0.10/24` e os servidores DNS. Para IP fixo em vez de DHCP, preencha `IP_ESTATICO` e `GATEWAY` em `config/quorum.conf` antes de rodar. **Na Azure deixe `IP_ESTATICO` vazio**: o IP da VM é entregue pelo DHCP da própria Azure.

### Opção 2 · WSL2

No PowerShell do Windows:

```powershell
wsl --install -d Ubuntu-24.04
```

Dentro do Ubuntu, habilite o systemd (uma vez só) e reinicie a distro:

```bash
printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf
exit
```

```powershell
wsl --shutdown
wsl -d Ubuntu-24.04
```

Depois é igual à VM:

```bash
git clone https://github.com/lorransantosdev/quorum-infra-linux.git
cd quorum-infra-linux
sudo ./provisionar.sh
```

No WSL o script grava o hostname e o DNS em `/etc/wsl.conf` (`hostname`, `generateHosts=false`, `generateResolvConf=false`) e cria o serviço `quorum-rede.service`, que sobe o IP de serviço `10.77.0.10/24` como alias da `eth0` a cada boot. Para o hostname novo aparecer no prompt, reinicie a distro com `wsl --terminate Ubuntu-24.04`.

### Etapas separadas

```bash
sudo ./provisionar.sh --infra      # só 01-infraestrutura.sh
sudo ./provisionar.sh --app        # só 02-aplicacao.sh
sudo ./provisionar.sh --monitor    # só 03-monitoramento.sh
```

Todos os scripts são idempotentes: rodar de novo não duplica nada, só confere e corrige.

### Do zero, de novo

```bash
sudo ./scripts/remover.sh --confirmar
sudo ./provisionar.sh
```

## O que cada script faz

### 01-infraestrutura.sh · rede, DNS, hostname, usuários

| Item | Como |
|------|------|
| Validação | confere hostname, CIDR dos IPs e DNS antes de mexer no sistema |
| Fuso | `timedatectl set-timezone America/Sao_Paulo` |
| Hostname | `hostnamectl set-hostname quorum-srv01` (+ `/etc/wsl.conf` no WSL) |
| IP | `netplan` na VM; `quorum-rede.service` (`ip addr replace 10.77.0.10/24 dev eth0`) no WSL |
| Nomes | bloco gerenciado no `/etc/hosts`: `api.quorum.local`, `quorum-srv01.quorum.local`, `db.quorum.local` |
| DNS | `systemd-resolved` com `DNS=1.1.1.1 8.8.8.8` e `Domains=quorum.local`; teste de resolução local e externa |
| Usuários | usuário de sistema `quorum` (sem shell, roda a API) e grupo `quorum-ops` (operadores) |
| Permissões | `/opt/quorum` 750 `quorum`, `/etc/quorum` 750 `root:quorum`, `/var/log/quorum` 2775 `root:quorum-ops` |
| sudo | `quorum-ops` pode `start/stop/restart/status` dos serviços `quorum-*` sem senha (validado com `visudo -c`) |
| Firewall | `ufw` liberando 22 e 80 |

### 02-aplicacao.sh · aplicação CitizenTech

1. Instala `python3`, `python3-venv`, `postgresql`, `nginx`, `git`, `stress-ng`, `sysstat`, `jq`... e registra as versões em `instalacoes.log`.
2. Cria o usuário e o banco `quorum` no PostgreSQL com senha aleatória (`openssl rand`), reaproveitada nas próximas execuções.
3. Grava as variáveis de ambiente em `/etc/quorum/quorum.env` (permissão 640, só root e o usuário `quorum` leem).
4. Clona a API em `/opt/quorum/app`, cria o venv em `/opt/quorum/venv` e instala o `requirements.txt`.
5. Aplica as migrações (`alembic upgrade head`).
6. Instala o `quorum-api.service` (`Restart=always`, usuário sem privilégio, `ProtectSystem=full`) e o site do nginx.
7. Só termina quando `GET http://api.quorum.local/health` responde `{"status":"ok","banco":"ok"}`.

### 03-monitoramento.sh · monitor como serviço

Instala o monitor em `/usr/local/bin/quorum-monitor`, a configuração em `/etc/quorum/quorum.conf`, o `quorum-monitor.service`, o `logrotate` e as regras do `auditd`.

## Monitoramento

O `quorum-monitor` mede, a cada `MONITOR_INTERVALO` (20 s):

| Recurso | Como mede | Alerta | Crítico |
|---------|-----------|--------|---------|
| CPU | duas leituras de `/proc/stat` com 2 s de intervalo | 80% | 95% |
| Memória | `(MemTotal − MemAvailable) / MemTotal` em `/proc/meminfo` | 80% | 95% |
| Disco | `df` de cada sistema de arquivos ext4/xfs/btrfs | 80% | 90% |
| Serviços | `systemctl is-active` de `quorum-api`, `postgresql`, `nginx` | — | serviço parado |
| API | `GET http://api.quorum.local/health` | — | 3 falhas seguidas |

Comportamento:
- Alerta quando muda de nível e repete a cada 5 min enquanto o problema continua; avisa quando volta ao normal.
- O alerta de CPU e de memória traz os 3 processos que mais consomem (ex.: `stress-ng`).
- Serviço parado é religado pelo próprio monitor; API sem responder 3 vezes seguidas é reiniciada.
- Tudo vai para `/var/log/quorum/alertas.log`, `/var/log/quorum/monitor.log` e para o journal (`journalctl -t quorum-monitor`).

Uso manual:

```bash
quorum-monitor --uma-vez        # uma verificação; código de saída 0 normal, 1 alerta, 2 crítico
```

### Serviço systemd tolerante a falhas

| Recurso | Configuração |
|---------|--------------|
| Inicia com o sistema | `systemctl enable quorum-monitor` (`WantedBy=multi-user.target`) |
| Execução periódica | laço interno a cada 20 s |
| Recuperação | `Restart=always`, `RestartSec=5` |
| Travamento | `WatchdogSec=90s`: se o laço parar de avisar o systemd, ele mata e reinicia o serviço |
| Proteção contra laço de falhas | `StartLimitBurst=10` em `StartLimitIntervalSec=300` |
| Registro da parada | `ExecStopPost` grava o motivo (`SERVICE_RESULT`, `EXIT_CODE`) em `alertas.log` |

```bash
sudo systemctl start quorum-monitor
sudo systemctl stop quorum-monitor
sudo systemctl restart quorum-monitor
systemctl status quorum-monitor
journalctl -u quorum-monitor -f
```

## Logs e auditoria

| Arquivo | Conteúdo |
|---------|----------|
| `/var/log/quorum/auditoria.log` | quem executou, quando, qual script, qual etapa e o resultado (`INICIO`, `OK`, `ERRO`, `AVISO`, `PASSOU`) |
| `/var/log/quorum/provisionamento.log` | saída completa de cada comando executado pelos scripts |
| `/var/log/quorum/instalacoes.log` | pacotes instalados e versões |
| `/var/log/quorum/dependencias-python.txt` | `pip freeze` da aplicação |
| `/var/log/quorum/monitor.log` | um registro por ciclo do monitor + início/parada |
| `/var/log/quorum/alertas.log` | alertas de consumo, falhas, recuperações e normalizações |
| `/var/log/quorum/testes-falha.log` | resultado dos testes de falha |
| `/var/log/quorum/api.log` | saída da API (uvicorn) |
| `ausearch -k quorum-config` | alterações em arquivos de configuração vigiadas pelo `auditd` (em VM; o kernel do WSL não tem auditoria) |

Exemplo real de `auditoria.log`:

```
2026-11-16T23:19:39-0300 | exec=20261116231906-926 | host=quorum-srv01 | usuario=root(sudo:aluno) | script=01-infraestrutura.sh | etapa=Hostname | resultado=OK | Definir hostname quorum-srv01 (quorum-srv01.quorum.local)
```

Toda execução tem um `exec` único; o `provisionar.sh` repassa o mesmo identificador para os scripts filhos, então dá para filtrar uma execução inteira:

```bash
grep 'exec=20261116231906-926' /var/log/quorum/auditoria.log
```

Erros são capturados por `trap ERR`: a linha, o comando e o código de saída vão para a auditoria e o script para na hora.

Os logs giram diariamente (14 dias, compactados) por `/etc/logrotate.d/quorum`.

## Testes de falha

```bash
sudo ./scripts/testes-falha.sh monitor-kill   # kill -9 no monitor -> systemd religa
sudo ./scripts/testes-falha.sh monitor-travado  # kill -STOP no monitor -> watchdog mata e systemd religa (~90 s)
sudo ./scripts/testes-falha.sh api-kill       # kill -9 na API -> systemd religa
sudo ./scripts/testes-falha.sh api-parada     # systemctl stop na API -> o monitor detecta e religa
sudo ./scripts/testes-falha.sh cpu            # stress-ng em todos os núcleos -> alerta de CPU
sudo ./scripts/testes-falha.sh memoria        # stress-ng levando a RAM a ~90% -> alerta de memória
sudo ./scripts/testes-falha.sh disco          # volume de 200 MB lotado -> alerta de disco
sudo ./scripts/testes-falha.sh script         # configuração inválida e comando com erro -> registrados na auditoria
sudo ./scripts/testes-falha.sh todos          # todos acima, em sequência
```

Reinicialização da máquina:

```bash
sudo reboot                                   # VM
# ou, no PowerShell: wsl --terminate Ubuntu-24.04 e abrir a distro de novo
sudo ./scripts/testes-falha.sh pos-boot       # confere serviços ativos, API respondendo e o registro de início do monitor
```

Cada teste diz se passou ou não e grava o resultado em `testes-falha.log` e em `auditoria.log`.

## Verificação rápida

```bash
./scripts/status.sh
curl http://api.quorum.local/health
```

Documentação da API: `http://api.quorum.local/docs` (no Windows com WSL, `http://localhost/docs` também abre, pois o WSL encaminha a porta 80).

## Evidências

As saídas reais dos comandos ficam em [`evidencias/`](evidencias/), geradas com:

```bash
sudo ./scripts/coletar-evidencias.sh
```

| Evidência | Arquivo |
|-----------|---------|
| Provisionamento completo | [`evidencias/provisionamento.txt`](evidencias/provisionamento.txt) |
| Hostname, rede e DNS | `evidencias/<data>/01-hostname.txt`, `02-rede-dns.txt` |
| Usuários e permissões | `evidencias/<data>/03-usuarios-permissoes.txt` |
| Serviços systemd | `evidencias/<data>/04-servicos.txt` |
| Aplicação respondendo | `evidencias/<data>/05-aplicacao.txt` |
| Monitoramento e alertas | `evidencias/<data>/06-monitoramento.txt` |
| Auditoria e testes de falha | `evidencias/<data>/07-auditoria.txt`, [`evidencias/testes-falha.txt`](evidencias/testes-falha.txt) |
| Pós-reinicialização | [`evidencias/pos-boot.txt`](evidencias/pos-boot.txt) |
| Capturas de tela | [`evidencias/prints/`](evidencias/prints/) |

## Roteiro do vídeo (até 7 min)

1. `cat config/quorum.conf` e a estrutura do repositório (30 s).
2. `sudo ./provisionar.sh` rodando do zero; acelerar a instalação de pacotes na edição (2 min).
3. `./scripts/status.sh`: hostname, IP 10.77.0.10, DNS, serviços (40 s).
4. Navegador em `http://localhost/docs` criando um cliente e uma medição na Quorum (40 s).
5. `quorum-monitor --uma-vez`, `systemctl status quorum-monitor`, `tail -f /var/log/quorum/monitor.log` (40 s).
6. `testes-falha.sh monitor-kill`, `api-parada` e `cpu` mostrando o alerta e a recuperação (1 min 30 s).
7. Reiniciar a máquina e rodar `testes-falha.sh pos-boot` (40 s).
8. `auditoria.log` e `alertas.log` filtrando a execução (20 s).
