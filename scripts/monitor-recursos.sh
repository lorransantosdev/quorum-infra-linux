#!/usr/bin/env bash
# Monitor de recursos do servidor Quorum (CPU, memória, disco, serviços e saúde da API).
# Uso: quorum-monitor --uma-vez | --servico | --registrar-parada

set -uo pipefail

CONF="${QUORUM_CONF:-/etc/quorum/quorum.conf}"
if [[ -r "$CONF" ]]; then
    # shellcheck source=/dev/null
    source "$CONF"
fi

LOG_DIR="${LOG_DIR:-/var/log/quorum}"
MONITOR_INTERVALO="${MONITOR_INTERVALO:-20}"
CPU_ALERTA="${CPU_ALERTA:-80}";   CPU_CRITICO="${CPU_CRITICO:-95}"
MEM_ALERTA="${MEM_ALERTA:-80}";   MEM_CRITICO="${MEM_CRITICO:-95}"
DISCO_ALERTA="${DISCO_ALERTA:-80}"; DISCO_CRITICO="${DISCO_CRITICO:-90}"
SERVICOS_MONITORADOS="${SERVICOS_MONITORADOS:-quorum-api postgresql nginx}"
FALHAS_SAUDE_ANTES_DE_REINICIAR="${FALHAS_SAUDE_ANTES_DE_REINICIAR:-3}"
URL_SAUDE="http://${APP_HOST_PUBLICO:-127.0.0.1}/health"
REALERTA_SEGUNDOS=300

LOG_MONITOR="$LOG_DIR/monitor.log"
LOG_ALERTAS="$LOG_DIR/alertas.log"

declare -A NIVEL_ANTERIOR=()
declare -A ULTIMO_ALERTA=()
FALHAS_SAUDE=0
CICLO=0
NIVEL=NORMAL
SAUDE=""

agora() { date '+%Y-%m-%dT%H:%M:%S%z'; }

registrar() {
    local arquivo="$1" nivel="$2" item="$3" mensagem="$4"
    printf '%s | %-8s | %-12s | %s\n' "$(agora)" "$nivel" "$item" "$mensagem" >> "$arquivo"
}

alertar() {
    local nivel="$1" item="$2" mensagem="$3" prioridade=user.warning
    [[ "$nivel" == "CRITICO" || "$nivel" == "FALHA" ]] && prioridade=user.crit
    [[ "$nivel" == "NORMAL" || "$nivel" == "RECUPERADO" ]] && prioridade=user.notice
    registrar "$LOG_ALERTAS" "$nivel" "$item" "$mensagem"
    registrar "$LOG_MONITOR" "$nivel" "$item" "$mensagem"
    logger -t quorum-monitor -p "$prioridade" "$nivel $item: $mensagem" 2>/dev/null || true
}

classificar() {
    local valor="$1" alerta="$2" critico="$3"
    if (( valor >= critico )); then echo CRITICO
    elif (( valor >= alerta )); then echo ALERTA
    else echo NORMAL
    fi
}

uso_cpu() {
    local _ u1 n1 s1 i1 w1 q1 sq1 st1 u2 n2 s2 i2 w2 q2 sq2 st2 total ocioso
    read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
    sleep 2
    read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
    ocioso=$(( (i2 + w2) - (i1 + w1) ))
    total=$(( (u2 + n2 + s2 + i2 + w2 + q2 + sq2 + st2) - (u1 + n1 + s1 + i1 + w1 + q1 + sq1 + st1) ))
    (( total > 0 )) || { echo 0; return; }
    echo $(( (100 * (total - ocioso)) / total ))
}

uso_memoria() {
    awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {d=$2} END {printf "%d %d %d\n", (t-d)*100/t, (t-d)/1024, t/1024}' /proc/meminfo
}

uso_discos() {
    df -P -T -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null \
        | awk 'NR>1 && $2 ~ /^(ext[234]|xfs|btrfs)$/ && $7 !~ /^\/(mnt\/wsl|usr\/lib\/wsl)/ {gsub("%","",$6); print $7, $6}' \
        | sort -u
}

maiores_processos() {
    local campo="$1"
    ps -eo comm,pid,%cpu,%mem --sort=-"$campo" 2>/dev/null | awk 'NR>1 && NR<=4 {printf "%s(pid %s cpu %s%% mem %s%%) ", $1, $2, $3, $4}'
}

avaliar() {
    local item="$1" valor="$2" alerta="$3" critico="$4" detalhe="$5"
    local nivel anterior agora_s
    nivel="$(classificar "$valor" "$alerta" "$critico")"
    anterior="${NIVEL_ANTERIOR[$item]:-NORMAL}"
    agora_s=$(date +%s)
    if [[ "$nivel" != "NORMAL" ]]; then
        if [[ "$nivel" != "$anterior" ]] || (( agora_s - ${ULTIMO_ALERTA[$item]:-0} >= REALERTA_SEGUNDOS )); then
            alertar "$nivel" "$item" "uso ${valor}% (limite alerta ${alerta}% / crítico ${critico}%) $detalhe"
            ULTIMO_ALERTA[$item]=$agora_s
        fi
    elif [[ "$anterior" != "NORMAL" ]]; then
        alertar NORMAL "$item" "uso voltou ao normal: ${valor}%"
    fi
    NIVEL_ANTERIOR[$item]="$nivel"
    NIVEL="$nivel"
}

esquecer_discos_removidos() {
    local vistos=" $1" item ponto
    for item in "${!NIVEL_ANTERIOR[@]}"; do
        [[ "$item" == disco:* ]] || continue
        ponto="${item#disco:}"
        [[ "$vistos" == *" $ponto="* ]] && continue
        if [[ "${NIVEL_ANTERIOR[$item]}" != "NORMAL" ]]; then
            alertar NORMAL "$item" "ponto de montagem removido"
        fi
        unset "NIVEL_ANTERIOR[$item]" "ULTIMO_ALERTA[$item]"
    done
}

verificar_servicos() {
    local corrigir="$1" svc estado
    for svc in $SERVICOS_MONITORADOS; do
        estado="$(systemctl is-active "$svc" 2>/dev/null)"
        if [[ "$estado" == "active" ]]; then
            continue
        fi
        alertar FALHA "svc:$svc" "serviço $estado"
        if [[ "$corrigir" == "sim" ]]; then
            systemctl restart "$svc" 2>/dev/null
            sleep 3
            if systemctl is-active --quiet "$svc"; then
                alertar RECUPERADO "svc:$svc" "serviço reiniciado pelo monitor"
            else
                alertar FALHA "svc:$svc" "reinício pelo monitor não resolveu"
            fi
        fi
    done
}

verificar_saude_api() {
    local corrigir="$1" resposta
    if resposta="$(curl -fsS -m 5 "$URL_SAUDE" 2>&1)"; then
        if (( FALHAS_SAUDE > 0 )); then
            alertar RECUPERADO "api:saude" "API respondendo novamente: $resposta"
        fi
        FALHAS_SAUDE=0
        SAUDE="ok"
        return
    fi
    FALHAS_SAUDE=$(( FALHAS_SAUDE + 1 ))
    alertar FALHA "api:saude" "falha $FALHAS_SAUDE/$FALHAS_SAUDE_ANTES_DE_REINICIAR em $URL_SAUDE: $resposta"
    if [[ "$corrigir" == "sim" ]] && (( FALHAS_SAUDE >= FALHAS_SAUDE_ANTES_DE_REINICIAR )); then
        systemctl restart quorum-api 2>/dev/null
        alertar AVISO "api:saude" "quorum-api reiniciado após $FALHAS_SAUDE falhas seguidas"
        FALHAS_SAUDE=0
    fi
    SAUDE="falha"
}

ciclo() {
    local corrigir="$1" cpu mem mem_usado mem_total nc nm nd n ponto pct piores="NORMAL" discos_txt="" saude
    CICLO=$(( CICLO + 1 ))

    cpu="$(uso_cpu)"
    avaliar cpu "$cpu" "$CPU_ALERTA" "$CPU_CRITICO" "load=$(cut -d' ' -f1-3 /proc/loadavg) top: $(maiores_processos %cpu)"
    nc="$NIVEL"

    read -r mem mem_usado mem_total < <(uso_memoria)
    avaliar memoria "$mem" "$MEM_ALERTA" "$MEM_CRITICO" "${mem_usado}MB de ${mem_total}MB top: $(maiores_processos %mem)"
    nm="$NIVEL"

    for n in "$nc" "$nm"; do
        [[ "$n" == "CRITICO" ]] && piores="CRITICO"
        [[ "$n" == "ALERTA" && "$piores" == "NORMAL" ]] && piores="ALERTA"
    done

    while read -r ponto pct; do
        [[ -z "$ponto" ]] && continue
        avaliar "disco:$ponto" "$pct" "$DISCO_ALERTA" "$DISCO_CRITICO" ""
        nd="$NIVEL"
        discos_txt+="$ponto=${pct}% "
        [[ "$nd" == "CRITICO" ]] && piores="CRITICO"
        [[ "$nd" == "ALERTA" && "$piores" == "NORMAL" ]] && piores="ALERTA"
    done < <(uso_discos)
    esquecer_discos_removidos "$discos_txt"

    verificar_servicos "$corrigir"
    verificar_saude_api "$corrigir"
    saude="$SAUDE"

    registrar "$LOG_MONITOR" "$piores" "ciclo#$CICLO" "cpu=${cpu}% mem=${mem}% (${mem_usado}/${mem_total}MB) disco: ${discos_txt}api=$saude"
    RESUMO="CPU ${cpu}% [$nc] | Memória ${mem}% [$nm] | Disco ${discos_txt}| API $saude"
    PIOR_NIVEL="$piores"
}

notificar_systemd() {
    [[ -n "${NOTIFY_SOCKET:-}" ]] && systemd-notify "$@" 2>/dev/null
    return 0
}

modo_servico() {
    trap 'registrar "$LOG_MONITOR" INFO monitor "sinal de parada recebido (ciclo $CICLO)"; exit 0' TERM INT
    registrar "$LOG_MONITOR" INFO monitor "monitor iniciado pid=$$ intervalo=${MONITOR_INTERVALO}s boot=$(date -d "$(ps -o lstart= -p 1 2>/dev/null)" '+%Y-%m-%d %H:%M:%S')"
    logger -t quorum-monitor -p user.notice "monitor iniciado pid=$$" 2>/dev/null || true
    notificar_systemd --ready
    while true; do
        ciclo sim
        notificar_systemd WATCHDOG=1
        sleep "$MONITOR_INTERVALO" &
        wait $!
    done
}

modo_uma_vez() {
    ciclo nao
    echo "$(agora) $PIOR_NIVEL :: $RESUMO"
    case "$PIOR_NIVEL" in
        NORMAL) exit 0 ;;
        ALERTA) exit 1 ;;
        *) exit 2 ;;
    esac
}

registrar_parada() {
    local resultado="${SERVICE_RESULT:-desconhecido}" codigo="${EXIT_CODE:-}" status="${EXIT_STATUS:-}"
    if [[ "$resultado" == "success" ]]; then
        registrar "$LOG_MONITOR" INFO monitor "serviço parado normalmente"
    else
        alertar FALHA "monitor" "serviço de monitoramento interrompido: resultado=$resultado codigo=$codigo status=$status (systemd vai reiniciar)"
    fi
}

mkdir -p "$LOG_DIR"
case "${1:---uma-vez}" in
    --servico) modo_servico ;;
    --uma-vez) modo_uma_vez ;;
    --registrar-parada) registrar_parada ;;
    *) echo "uso: $0 [--uma-vez|--servico|--registrar-parada]" >&2; exit 64 ;;
esac
