#!/usr/bin/env bash
# Instala o monitoramento como serviço systemd, a rotação de logs e as regras de auditoria.

source "$(dirname "$0")/lib/comum.sh"
iniciar_script "$@"

WATCHDOG=$(( MONITOR_INTERVALO * 3 + 30 ))

instalar_monitor() {
    install -m 640 -o root -g "$GRUPO_OPERADORES" "$QUORUM_CONF" "$CONF_DIR/quorum.conf"
    install -m 755 "$RAIZ_PROJETO/scripts/monitor-recursos.sh" /usr/local/bin/quorum-monitor
    touch "$LOG_DIR/monitor.log" "$LOG_DIR/alertas.log"
    chgrp "$GRUPO_OPERADORES" "$LOG_DIR/monitor.log" "$LOG_DIR/alertas.log"
    chmod 664 "$LOG_DIR/monitor.log" "$LOG_DIR/alertas.log"
}

instalar_servico() {
    sed "s|@WATCHDOG@|${WATCHDOG}s|" "$RAIZ_PROJETO/systemd/quorum-monitor.service" \
        > /etc/systemd/system/quorum-monitor.service
    systemd-analyze verify /etc/systemd/system/quorum-monitor.service
    systemctl daemon-reload
    systemctl enable quorum-monitor.service
    systemctl restart quorum-monitor.service
    sleep 3
    systemctl is-active quorum-monitor.service
}

instalar_logrotate() {
    install -m 644 "$RAIZ_PROJETO/logrotate/quorum" /etc/logrotate.d/quorum
    logrotate -d /etc/logrotate.d/quorum
}

instalar_auditd() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -q auditd
    install -m 640 "$RAIZ_PROJETO/auditoria/quorum.rules" /etc/audit/rules.d/quorum.rules
    systemctl enable --now auditd
    augenrules --load
    auditctl -l | grep -c quorum
}

etapa "Monitor de recursos"
executar "Instalar /usr/local/bin/quorum-monitor e $CONF_DIR/quorum.conf" instalar_monitor
executar "Primeira verificação manual" bash -c "/usr/local/bin/quorum-monitor --uma-vez || [ \$? -le 2 ]"

etapa "Serviço systemd"
executar "Instalar e iniciar quorum-monitor.service (watchdog ${WATCHDOG}s)" instalar_servico

etapa "Rotação de logs"
executar "Instalar /etc/logrotate.d/quorum" instalar_logrotate

etapa "Auditoria do sistema"
if eh_wsl; then
    log_aviso "Kernel do WSL não tem o subsistema de auditoria; a trilha fica em $LOG_AUDITORIA"
    auditar AVISO "Auditoria do sistema" "auditd ignorado no WSL"
else
    tentar "Instalar auditd e regras de auditoria do Quorum" instalar_auditd
    registrar_pacotes auditd
fi
registrar_pacotes logrotate

etapa "Resumo"
log_ok "Monitor: $(systemctl is-active quorum-monitor) | habilitado no boot: $(systemctl is-enabled quorum-monitor)"
log_ok "Logs em $LOG_DIR: monitor.log, alertas.log, auditoria.log, provisionamento.log"
