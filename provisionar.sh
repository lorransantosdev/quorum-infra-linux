#!/usr/bin/env bash
# Provisiona o servidor Quorum do zero: infraestrutura, aplicação e monitoramento.
# Uso: sudo ./provisionar.sh [--infra] [--app] [--monitor]   (sem argumentos executa tudo)

source "$(dirname "$0")/scripts/lib/comum.sh"
iniciar_script "$@"

DIR_SCRIPTS="$RAIZ_PROJETO/scripts"
ETAPAS=()

for arg in "$@"; do
    case "$arg" in
        --infra)   ETAPAS+=(01-infraestrutura.sh) ;;
        --app)     ETAPAS+=(02-aplicacao.sh) ;;
        --monitor) ETAPAS+=(03-monitoramento.sh) ;;
        -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
        *) log_erro "Argumento desconhecido: $arg"; exit 64 ;;
    esac
done
[[ ${#ETAPAS[@]} -eq 0 ]] && ETAPAS=(01-infraestrutura.sh 02-aplicacao.sh 03-monitoramento.sh)

INICIO=$(date +%s)
for script in "${ETAPAS[@]}"; do
    etapa "$script"
    if bash "$DIR_SCRIPTS/$script"; then
        auditar OK "$script" "etapa concluída"
    else
        codigo=$?
        log_erro "$script terminou com erro ($codigo). Veja $LOG_EXECUCAO e $LOG_AUDITORIA"
        auditar ERRO "$script" "etapa falhou com código $codigo"
        exit "$codigo"
    fi
done

etapa "Estado final"
bash "$DIR_SCRIPTS/status.sh" || true
log_ok "Provisionamento $EXEC_ID concluído em $(( $(date +%s) - INICIO ))s"
