#!/usr/bin/env bash
# Desfaz o provisionamento para testar a reprodução do zero. Mantém os logs.
# Uso: sudo ./scripts/remover.sh --confirmar

source "$(dirname "$0")/lib/comum.sh"
iniciar_script "$@"

if [[ "${1:-}" != "--confirmar" ]]; then
    log_aviso "Nada removido. Rode com --confirmar para apagar serviços, código, banco e configurações."
    exit 0
fi

parar_servicos() {
    for svc in quorum-monitor quorum-api quorum-rede; do
        systemctl disable --now "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/$svc.service"
    done
    systemctl daemon-reload
}

remover_banco() {
    if systemctl is-active --quiet postgresql; then
        runuser -u postgres -- dropdb --if-exists "$DB_NOME"
        runuser -u postgres -- psql -q -c "DROP ROLE IF EXISTS $DB_USUARIO"
    fi
}

remover_arquivos() {
    rm -f /etc/nginx/sites-enabled/quorum.conf /etc/nginx/sites-available/quorum.conf
    systemctl reload nginx 2>/dev/null || true
    rm -rf /opt/quorum "$CONF_DIR" /usr/local/bin/quorum-monitor /etc/logrotate.d/quorum \
        /etc/sudoers.d/quorum-ops /etc/audit/rules.d/quorum.rules /etc/netplan/60-quorum.yaml \
        /etc/systemd/resolved.conf.d/quorum.conf
    sed -i '/^# >>> quorum/,/^# <<< quorum/d' /etc/hosts
    userdel "$USUARIO_APP" 2>/dev/null || true
}

etapa "Remoção"
executar "Parar e remover serviços quorum-*" parar_servicos
executar "Remover banco $DB_NOME e usuário $DB_USUARIO" remover_banco
executar "Remover código, configurações e usuário $USUARIO_APP" remover_arquivos
log_ok "Ambiente limpo. Logs preservados em $LOG_DIR"
