#!/usr/bin/env bash
# Funções compartilhadas: configuração, logs de execução e trilha de auditoria.

RAIZ_PROJETO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QUORUM_CONF="${QUORUM_CONF:-$RAIZ_PROJETO/config/quorum.conf}"
NOME_SCRIPT="$(basename "${0}")"
EXEC_ID="${EXEC_ID:-$(date +%Y%m%d%H%M%S)-$$}"
export EXEC_ID

COR_OK=$'\e[32m'; COR_AVISO=$'\e[33m'; COR_ERRO=$'\e[31m'; COR_INFO=$'\e[36m'; COR_FIM=$'\e[0m'
[[ -t 1 ]] || { COR_OK=""; COR_AVISO=""; COR_ERRO=""; COR_INFO=""; COR_FIM=""; }

carregar_config() {
    if [[ ! -r "$QUORUM_CONF" ]]; then
        echo "Arquivo de configuração não encontrado: $QUORUM_CONF" >&2
        exit 2
    fi
    # shellcheck source=/dev/null
    source "$QUORUM_CONF"
    LOG_DIR="${LOG_DIR:-/var/log/quorum}"
    LOG_EXECUCAO="$LOG_DIR/provisionamento.log"
    LOG_AUDITORIA="$LOG_DIR/auditoria.log"
    LOG_INSTALACOES="$LOG_DIR/instalacoes.log"
}

exigir_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Este script precisa ser executado como root (use sudo)." >&2
        exit 1
    fi
}

preparar_logs() {
    install -d -m 2775 -o root -g root "$LOG_DIR"
    if getent group "${GRUPO_OPERADORES:-}" >/dev/null 2>&1; then
        chgrp "$GRUPO_OPERADORES" "$LOG_DIR"
    fi
    touch "$LOG_EXECUCAO" "$LOG_AUDITORIA" "$LOG_INSTALACOES"
    chmod 664 "$LOG_EXECUCAO" "$LOG_INSTALACOES"
    chmod 640 "$LOG_AUDITORIA"
}

quem_executa() {
    local usuario
    usuario="$(id -un)"
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "$usuario" ]]; then
        echo "$usuario(sudo:$SUDO_USER)"
    else
        echo "$usuario"
    fi
}

agora() { date '+%Y-%m-%dT%H:%M:%S%z'; }

auditar() {
    local resultado="$1" etapa="$2" detalhe="${3:-}"
    printf '%s | exec=%s | host=%s | usuario=%s | script=%s | etapa=%s | resultado=%s | %s\n' \
        "$(agora)" "$EXEC_ID" "$(hostname)" "$(quem_executa)" "$NOME_SCRIPT" "$etapa" "$resultado" "$detalhe" \
        >> "$LOG_AUDITORIA"
}

_log() {
    local nivel="$1" cor="$2"; shift 2
    local linha
    linha="$(agora) [$nivel] [$NOME_SCRIPT] $*"
    echo "${cor}${linha}${COR_FIM}"
    echo "$linha" >> "$LOG_EXECUCAO"
}

log_info()  { _log INFO  "$COR_INFO"  "$@"; }
log_ok()    { _log OK    "$COR_OK"    "$@"; }
log_aviso() { _log AVISO "$COR_AVISO" "$@"; }
log_erro()  { _log ERRO  "$COR_ERRO"  "$@" >&2; }

ETAPA_ATUAL="inicio"

etapa() {
    ETAPA_ATUAL="$1"
    log_info "==> $1"
}

executar() {
    local descricao="$1"; shift
    local inicio saida codigo
    inicio=$(date +%s)
    log_info "$descricao"
    trap - ERR
    set +e
    saida="$(set -e; "$@" 2>&1)"
    codigo=$?
    set -e
    trap _ao_falhar ERR
    if [[ -n "$saida" ]]; then
        echo "$saida" >> "$LOG_EXECUCAO"
    fi
    if [[ $codigo -eq 0 ]]; then
        log_ok "$descricao ($(( $(date +%s) - inicio ))s)"
        auditar OK "$ETAPA_ATUAL" "$descricao"
    else
        log_erro "$descricao falhou com código $codigo"
        echo "$saida" | tail -n 15 >&2
        auditar ERRO "$ETAPA_ATUAL" "$descricao | codigo=$codigo | $(echo "$saida" | tail -n 1)"
        return "$codigo"
    fi
}

tentar() {
    local descricao="$1"; shift
    if ! executar "$descricao" "$@"; then
        log_aviso "Seguindo sem: $descricao"
        auditar AVISO "$ETAPA_ATUAL" "ignorado: $descricao"
    fi
}

_ao_falhar() {
    local codigo=$? linha=${BASH_LINENO[0]} comando=$BASH_COMMAND
    if [[ "$comando" == 'return "$codigo"' ]]; then
        log_erro "Execução interrompida na etapa '$ETAPA_ATUAL' (linha $linha)"
        auditar ERRO "$ETAPA_ATUAL" "linha=$linha | execução interrompida pela falha acima"
    else
        log_erro "Falha na linha $linha: '$comando' (código $codigo)"
        auditar ERRO "$ETAPA_ATUAL" "linha=$linha | comando=$comando | codigo=$codigo"
    fi
    exit "$codigo"
}

_ao_sair() {
    local codigo=$?
    if [[ $codigo -eq 0 ]]; then
        auditar OK "fim" "script concluído"
    else
        auditar ERRO "fim" "script encerrado com código $codigo"
    fi
}

iniciar_script() {
    set -Eeuo pipefail
    carregar_config
    exigir_root
    preparar_logs
    trap _ao_falhar ERR
    trap _ao_sair EXIT
    auditar INICIO "inicio" "argumentos='$*' conf=$QUORUM_CONF"
    log_info "Execução $EXEC_ID iniciada por $(quem_executa)"
}

eh_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

interface_padrao() {
    if [[ -n "${REDE_INTERFACE:-}" ]]; then
        echo "$REDE_INTERFACE"
    else
        ip -4 route show default | awk '{print $5; exit}'
    fi
}

ip_sem_mascara() { echo "${1%%/*}"; }

validar_ipv4_cidr() {
    local valor="$1" ip mascara
    [[ "$valor" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || return 1
    ip="${valor%%/*}"; mascara="${valor##*/}"
    (( mascara >= 1 && mascara <= 32 )) || return 1
    local IFS=.
    for octeto in $ip; do
        (( octeto <= 255 )) || return 1
    done
}

registrar_pacotes() {
    local pacotes=("$@")
    local pkg versao
    for pkg in "${pacotes[@]}"; do
        versao="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "nao-instalado")"
        printf '%s | exec=%s | pacote=%s | versao=%s\n' "$(agora)" "$EXEC_ID" "$pkg" "$versao" >> "$LOG_INSTALACOES"
    done
}
