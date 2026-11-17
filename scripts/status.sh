#!/usr/bin/env bash
# Painel rápido do servidor: identidade, rede, serviços, saúde da API e últimos alertas.

source "$(dirname "$0")/lib/comum.sh"
carregar_config

titulo() { printf '\n%s== %s ==%s\n' "$COR_INFO" "$1" "$COR_FIM"; }

titulo "Servidor"
echo "Hostname:   $(hostname)  ($(hostname -f 2>/dev/null || hostname))"
echo "Sistema:    $(. /etc/os-release && echo "$PRETTY_NAME") | kernel $(uname -r)"
echo "Ligado em:  $(inicio_do_sistema)"
echo "Fuso:       $(date +%Z) $(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"

titulo "Rede e DNS"
ip -4 -brief addr show | grep -v '^lo'
echo "Rota padrão: $(ip -4 route show default | head -1)"
grep -E '^(nameserver|search)' /etc/resolv.conf 2>/dev/null
for nome in "$APP_HOST_PUBLICO" "$HOSTNAME_SERVIDOR.$DOMINIO" "db.$DOMINIO"; do
    printf '%-24s -> %s\n' "$nome" "$(getent hosts "$nome" | awk '{print $1}')"
done

titulo "Serviços"
for svc in quorum-rede quorum-api quorum-monitor postgresql nginx; do
    printf '%-16s ativo=%-9s boot=%-9s reinícios=%s\n' "$svc" \
        "$(systemctl is-active "$svc" 2>/dev/null)" \
        "$(systemctl is-enabled "$svc" 2>/dev/null)" \
        "$(systemctl show -p NRestarts --value "$svc" 2>/dev/null)"
done

titulo "API"
curl -s -m 5 -o /dev/null -w "GET http://$APP_HOST_PUBLICO/health -> HTTP %{http_code} em %{time_total}s\n" "http://$APP_HOST_PUBLICO/health"
curl -s -m 5 "http://$APP_HOST_PUBLICO/health"; echo

titulo "Recursos agora"
QUORUM_CONF="${CONF_DIR}/quorum.conf" /usr/local/bin/quorum-monitor --uma-vez 2>/dev/null \
    || echo "(monitor ainda não instalado ou recursos acima do limite)"

titulo "Últimos alertas"
tail -n 5 "$LOG_DIR/alertas.log" 2>/dev/null || echo "sem alertas"
