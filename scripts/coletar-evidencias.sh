#!/usr/bin/env bash
# Gera arquivos de evidência (saídas reais dos comandos) em evidencias/<data>/.

source "$(dirname "$0")/lib/comum.sh"
iniciar_script "$@"

DESTINO="$RAIZ_PROJETO/evidencias/$(date +%Y%m%d-%H%M)"
mkdir -p "$DESTINO"

coletar() {
    local arquivo="$1"; shift
    {
        for cmd in "$@"; do
            echo "\$ $cmd"
            bash -c "$cmd" 2>&1
            echo
        done
    } > "$DESTINO/$arquivo"
    log_ok "evidencias/$(basename "$DESTINO")/$arquivo"
}

coletar 01-hostname.txt \
    "hostnamectl 2>/dev/null || hostname" \
    "cat /etc/hostname" \
    "hostname -f" \
    "sed -n '/>>> quorum/,/<<< quorum/p' /etc/hosts"

coletar 02-rede-dns.txt \
    "ip -4 -brief addr show" \
    "ip -4 route show" \
    "cat /etc/resolv.conf" \
    "cat /etc/netplan/60-quorum.yaml 2>/dev/null || systemctl cat quorum-rede.service" \
    "getent hosts $APP_HOST_PUBLICO $HOSTNAME_SERVIDOR.$DOMINIO db.$DOMINIO" \
    "dig +short github.com" \
    "ping -c 2 -W 2 $APP_HOST_PUBLICO"

coletar 03-usuarios-permissoes.txt \
    "id $USUARIO_APP" \
    "getent group $GRUPO_OPERADORES" \
    "ls -ld /opt/quorum $APP_DIR $APP_VENV $CONF_DIR $LOG_DIR" \
    "ls -l $CONF_DIR $LOG_DIR" \
    "cat /etc/sudoers.d/quorum-ops" \
    "ufw status verbose"

coletar 04-servicos.txt \
    "systemctl status quorum-rede quorum-api quorum-monitor postgresql nginx --no-pager -n 0" \
    "systemctl list-unit-files 'quorum-*' --no-pager" \
    "systemctl show quorum-monitor -p Restart -p RestartUSec -p WatchdogUSec -p NRestarts" \
    "systemctl show quorum-api -p Restart -p RestartUSec -p NRestarts -p User"

coletar 05-aplicacao.txt \
    "curl -s http://$APP_HOST_PUBLICO/health" \
    "curl -s 'http://$APP_HOST_PUBLICO/clientes?tamanho=3'" \
    "curl -s -o /dev/null -w 'GET /docs -> HTTP %{http_code}\n' http://$APP_HOST_PUBLICO/docs" \
    "curl -s http://$APP_HOST_PUBLICO/openapi.json | jq -r '.paths | keys[]'" \
    "runuser -u $USUARIO_APP -- bash -c 'set -a; . $CONF_DIR/quorum.env; cd $APP_DIR && $APP_VENV/bin/alembic history'" \
    "tail -n 5 $LOG_DIR/api.log"

coletar 06-monitoramento.txt \
    "/usr/local/bin/quorum-monitor --uma-vez; echo \"codigo de saida: \$?\"" \
    "tail -n 15 $LOG_DIR/monitor.log" \
    "tail -n 25 $LOG_DIR/alertas.log" \
    "journalctl -t quorum-monitor -n 15 --no-pager -o short-iso"

coletar 07-auditoria.txt \
    "tail -n 40 $LOG_AUDITORIA" \
    "tail -n 20 $LOG_INSTALACOES" \
    "tail -n 20 $LOG_DIR/testes-falha.log" \
    "ausearch -k quorum-config -i 2>/dev/null | tail -n 20 || echo 'auditd indisponível neste kernel'"

log_ok "Evidências em $DESTINO"
