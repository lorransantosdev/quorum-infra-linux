#!/usr/bin/env bash
# Simulações de falha controlada e verificação da recuperação.
# Uso: sudo ./scripts/testes-falha.sh <teste>
#   monitor-kill | monitor-travado | api-kill | api-parada | cpu | memoria | disco | script | pos-boot | todos

source "$(dirname "$0")/lib/comum.sh"
iniciar_script "$@"

LOG_TESTES="$LOG_DIR/testes-falha.log"
ESPERA_MONITOR=$(( MONITOR_INTERVALO * 2 + 10 ))
APROVADOS=0
REPROVADOS=0

resultado() {
    local teste="$1" ok="$2" detalhe="$3"
    if [[ "$ok" == "sim" ]]; then
        APROVADOS=$(( APROVADOS + 1 ))
        log_ok "[PASSOU] $teste: $detalhe"
        auditar PASSOU "teste:$teste" "$detalhe"
        echo "$(agora) | PASSOU     | $teste | $detalhe" >> "$LOG_TESTES"
    else
        REPROVADOS=$(( REPROVADOS + 1 ))
        log_erro "[NAO PASSOU] $teste: $detalhe"
        auditar NAO_PASSOU "teste:$teste" "$detalhe"
        echo "$(agora) | NAO_PASSOU | $teste | $detalhe" >> "$LOG_TESTES"
    fi
}

aguardar() {
    local segundos="$1" condicao="$2"
    for _ in $(seq 1 "$segundos"); do
        if eval "$condicao"; then return 0; fi
        sleep 1
    done
    return 1
}

linhas_alerta() { wc -l < "$LOG_DIR/alertas.log"; }

alertas_desde() { tail -n +"$(( $1 + 1 ))" "$LOG_DIR/alertas.log"; }

teste_monitor_kill() {
    etapa "Teste: matar o serviço de monitoramento (SIGKILL)"
    local pid_antes pid_depois reinicios_antes reinicios_depois
    pid_antes="$(systemctl show -p MainPID --value quorum-monitor)"
    reinicios_antes="$(systemctl show -p NRestarts --value quorum-monitor)"
    log_info "quorum-monitor PID=$pid_antes reinícios=$reinicios_antes. Enviando kill -9..."
    kill -9 "$pid_antes"
    if aguardar 30 '[[ "$(systemctl is-active quorum-monitor)" == active && "$(systemctl show -p MainPID --value quorum-monitor)" != "$pid_antes" && "$(systemctl show -p MainPID --value quorum-monitor)" != 0 ]]'; then
        pid_depois="$(systemctl show -p MainPID --value quorum-monitor)"
        reinicios_depois="$(systemctl show -p NRestarts --value quorum-monitor)"
        resultado monitor-kill sim "systemd reiniciou o monitor: PID $pid_antes -> $pid_depois, reinícios $reinicios_antes -> $reinicios_depois"
    else
        resultado monitor-kill nao "monitor não voltou em 30s"
    fi
    journalctl -u quorum-monitor -n 6 --no-pager -o short-iso || true
}

teste_monitor_travado() {
    etapa "Teste: monitor travado (SIGSTOP) e watchdog do systemd"
    local pid_antes limite
    pid_antes="$(systemctl show -p MainPID --value quorum-monitor)"
    limite=$(( MONITOR_INTERVALO * 3 + 30 + 40 ))
    log_info "Congelando o monitor (PID $pid_antes) com kill -STOP. Watchdog deve agir em até ${limite}s..."
    kill -STOP "$pid_antes"
    if aguardar "$limite" '[[ "$(systemctl show -p MainPID --value quorum-monitor)" != "$pid_antes" && "$(systemctl is-active quorum-monitor)" == active ]]'; then
        resultado monitor-travado sim "watchdog derrubou o processo congelado e o systemd subiu o PID $(systemctl show -p MainPID --value quorum-monitor)"
    else
        kill -CONT "$pid_antes" 2>/dev/null || true
        resultado monitor-travado nao "watchdog não reagiu em ${limite}s"
    fi
    journalctl -u quorum-monitor -n 8 --no-pager -o short-iso | grep -iE "watchdog|start|stop" || true
}

teste_api_kill() {
    etapa "Teste: derrubar o processo da API (SIGKILL)"
    local pid_antes
    pid_antes="$(systemctl show -p MainPID --value quorum-api)"
    log_info "quorum-api PID=$pid_antes. Enviando kill -9..."
    kill -9 "$pid_antes"
    if aguardar 40 'curl -fsS -m 3 "http://$APP_HOST_PUBLICO/health" >/dev/null 2>&1 && [[ "$(systemctl show -p MainPID --value quorum-api)" != "$pid_antes" ]]'; then
        resultado api-kill sim "API voltou com PID $(systemctl show -p MainPID --value quorum-api) (reinícios: $(systemctl show -p NRestarts --value quorum-api))"
    else
        resultado api-kill nao "API não respondeu em 40s"
    fi
}

teste_api_parada() {
    etapa "Teste: API parada (systemd não religa sozinho) e o monitor recupera"
    local marca
    marca="$(linhas_alerta)"
    systemctl stop quorum-api
    log_info "quorum-api parado. Aguardando o monitor perceber (até ${ESPERA_MONITOR}s)..."
    if aguardar "$ESPERA_MONITOR" 'alertas_desde "$marca" | grep "RECUPERADO.*svc:quorum-api" >/dev/null'; then
        resultado api-parada sim "monitor detectou e religou a API"
    else
        resultado api-parada nao "monitor não religou a API a tempo"
        systemctl start quorum-api
    fi
    alertas_desde "$marca" | grep -E "quorum-api|api:saude" || true
}

teste_cpu() {
    etapa "Teste: consumo elevado de CPU"
    local marca duracao=$(( ESPERA_MONITOR + 10 ))
    marca="$(linhas_alerta)"
    log_info "stress-ng em $(nproc) núcleos por ${duracao}s"
    stress-ng --cpu 0 --cpu-load 100 --timeout "${duracao}s" --quiet &
    local pid=$!
    if aguardar "$duracao" 'alertas_desde "$marca" | grep -E "(ALERTA|CRITICO) +\| cpu" >/dev/null'; then
        resultado cpu sim "alerta de CPU gerado"
    else
        resultado cpu nao "nenhum alerta de CPU"
    fi
    wait "$pid" || true
    aguardar "$ESPERA_MONITOR" 'alertas_desde "$marca" | grep -E "NORMAL +\| cpu" >/dev/null' && log_ok "CPU normalizada"
    alertas_desde "$marca" | grep "| cpu" || true
}

teste_memoria() {
    etapa "Teste: consumo elevado de memória"
    local marca duracao=$(( ESPERA_MONITOR + 10 ))
    marca="$(linhas_alerta)"
    local total_kb livre_kb alvo_kb
    total_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    livre_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    alvo_kb=$(( total_kb * 90 / 100 - (total_kb - livre_kb) ))
    (( alvo_kb > livre_kb * 95 / 100 )) && alvo_kb=$(( livre_kb * 95 / 100 ))
    log_info "stress-ng alocando $(( alvo_kb / 1024 ))MB para levar a memória a ~90% por ${duracao}s"
    stress-ng --vm 1 --vm-bytes "${alvo_kb}k" --vm-keep --timeout "${duracao}s" --quiet &
    local pid=$!
    if aguardar "$duracao" 'alertas_desde "$marca" | grep -E "(ALERTA|CRITICO) +\| memoria" >/dev/null'; then
        resultado memoria sim "alerta de memória gerado"
    else
        resultado memoria nao "nenhum alerta de memória"
    fi
    wait "$pid" || true
    aguardar "$ESPERA_MONITOR" 'alertas_desde "$marca" | grep -E "NORMAL +\| memoria" >/dev/null' && log_ok "Memória normalizada"
    alertas_desde "$marca" | grep "| memoria" || true
}

teste_disco() {
    etapa "Teste: disco quase cheio (volume de teste de 200 MB)"
    local marca imagem=/var/tmp/quorum-teste-disco.img ponto=/mnt/quorum-teste-disco
    marca="$(linhas_alerta)"
    umount "$ponto" 2>/dev/null || true
    truncate -s 200M "$imagem"
    mkfs.ext4 -q -F -m 0 "$imagem"
    mkdir -p "$ponto"
    mount -o loop "$imagem" "$ponto"
    local total usado
    read -r total usado < <(df -k --output=size,used "$ponto" | tail -1)
    fallocate -l "$(( total * 93 / 100 - usado ))K" "$ponto/lotando.bin"
    log_info "Uso do volume: $(df -h --output=pcent "$ponto" | tail -1)"
    if aguardar "$ESPERA_MONITOR" 'alertas_desde "$marca" | grep -E "(ALERTA|CRITICO) +\| disco:$ponto" >/dev/null'; then
        resultado disco sim "alerta de disco gerado para $ponto"
    else
        resultado disco nao "nenhum alerta de disco"
    fi
    umount "$ponto"
    rm -f "$imagem"
    rmdir "$ponto"
    aguardar "$ESPERA_MONITOR" 'alertas_desde "$marca" | grep -E "NORMAL +\| disco:$ponto" >/dev/null' && log_ok "Volume de teste removido e alerta encerrado"
    alertas_desde "$marca" | grep "disco:" || true
}

teste_script() {
    etapa "Teste: falha controlada em script"
    local conf_ruim marca_aud
    conf_ruim="$(mktemp)"
    sed 's|^IP_SERVICO=.*|IP_SERVICO="300.10.0.1/24"|' "$QUORUM_CONF" > "$conf_ruim"
    marca_aud="$(wc -l < "$LOG_AUDITORIA")"
    log_info "Rodando 01-infraestrutura.sh com IP_SERVICO inválido (300.10.0.1/24)"
    if QUORUM_CONF="$conf_ruim" EXEC_ID="$EXEC_ID-falha1" bash "$RAIZ_PROJETO/scripts/01-infraestrutura.sh" >/dev/null 2>&1; then
        resultado script-config nao "script aceitou configuração inválida"
    elif tail -n +"$(( marca_aud + 1 ))" "$LOG_AUDITORIA" | grep "resultado=ERRO.*IP_SERVICO\|resultado=ERRO.*Validar" >/dev/null; then
        resultado script-config sim "erro de validação registrado na auditoria"
    else
        resultado script-config nao "erro não apareceu na auditoria"
    fi
    rm -f "$conf_ruim"

    local falho
    falho="$(mktemp --suffix=.sh)"
    cat > "$falho" <<EOF
source "$RAIZ_PROJETO/scripts/lib/comum.sh"
NOME_SCRIPT=script-com-defeito.sh
iniciar_script
etapa "Copiar arquivo inexistente"
cp /etc/quorum/arquivo-que-nao-existe.conf /tmp/
EOF
    marca_aud="$(wc -l < "$LOG_AUDITORIA")"
    log_info "Rodando script com um comando que falha (cp de arquivo inexistente)"
    EXEC_ID="$EXEC_ID-falha2" bash "$falho" >/dev/null 2>&1 || true
    if tail -n +"$(( marca_aud + 1 ))" "$LOG_AUDITORIA" | grep "script-com-defeito.sh.*resultado=ERRO.*arquivo-que-nao-existe" >/dev/null; then
        resultado script-trap sim "trap ERR registrou linha, comando e código"
    else
        resultado script-trap nao "falha não registrada"
    fi
    rm -f "$falho"
    tail -n +"$(( marca_aud - 3 ))" "$LOG_AUDITORIA" | grep ERRO || true
}

teste_pos_boot() {
    etapa "Teste: estado após reinicialização"
    log_info "Sistema ligado desde $(uptime -s)"
    local svc todos=sim
    for svc in quorum-rede quorum-api quorum-monitor postgresql nginx; do
        if systemctl is-active --quiet "$svc" && systemctl is-enabled --quiet "$svc"; then
            log_ok "$svc ativo e habilitado no boot"
        else
            log_erro "$svc: $(systemctl is-active "$svc")/$(systemctl is-enabled "$svc")"
            todos=nao
        fi
    done
    curl -fsS -m 5 "http://$APP_HOST_PUBLICO/health" >/dev/null || todos=nao
    grep "monitor iniciado" "$LOG_DIR/monitor.log" | tail -n 3
    resultado pos-boot "$todos" "serviços de pé após boot de $(uptime -s)"
}

case "${1:-}" in
    monitor-kill) teste_monitor_kill ;;
    monitor-travado) teste_monitor_travado ;;
    api-kill)     teste_api_kill ;;
    api-parada)   teste_api_parada ;;
    cpu)          teste_cpu ;;
    memoria)      teste_memoria ;;
    disco)        teste_disco ;;
    script)       teste_script ;;
    pos-boot)     teste_pos_boot ;;
    todos)
        teste_monitor_kill; teste_monitor_travado; teste_api_kill; teste_api_parada
        teste_cpu; teste_memoria; teste_disco; teste_script ;;
    *) sed -n '2,4p' "$0"; exit 64 ;;
esac

etapa "Resultado"
log_info "Aprovados: $APROVADOS | Não aprovados: $REPROVADOS | detalhes em $LOG_TESTES"
if (( REPROVADOS > 0 )); then
    exit 1
fi
