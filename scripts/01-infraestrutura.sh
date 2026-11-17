#!/usr/bin/env bash
# Provisiona a base do servidor: hostname, rede, DNS, fuso, usuários, permissões e firewall.

source "$(dirname "$0")/lib/comum.sh"
iniciar_script "$@"

MARCA_INICIO="# >>> quorum (gerenciado por 01-infraestrutura.sh)"
MARCA_FIM="# <<< quorum"
FQDN="$HOSTNAME_SERVIDOR.$DOMINIO"

validar_config() {
    [[ "$HOSTNAME_SERVIDOR" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "hostname inválido: $HOSTNAME_SERVIDOR"; return 1; }
    validar_ipv4_cidr "$IP_SERVICO" || { echo "IP_SERVICO inválido: $IP_SERVICO"; return 1; }
    if [[ -n "$IP_ESTATICO" ]]; then
        validar_ipv4_cidr "$IP_ESTATICO" || { echo "IP_ESTATICO inválido: $IP_ESTATICO"; return 1; }
        [[ -n "$GATEWAY" ]] || { echo "IP_ESTATICO exige GATEWAY"; return 1; }
    fi
    [[ -n "$DNS_SERVIDORES" ]] || { echo "DNS_SERVIDORES vazio"; return 1; }
}

instalar_base() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q iproute2 dnsutils iputils-ping ufw sudo curl ca-certificates tzdata
}

configurar_fuso() {
    if timedatectl set-timezone "$FUSO_HORARIO" 2>/dev/null; then
        return 0
    fi
    ln -sf "/usr/share/zoneinfo/$FUSO_HORARIO" /etc/localtime
    echo "$FUSO_HORARIO" > /etc/timezone
}

ajustar_wsl_conf() {
    local secao="$1" chave="$2" valor="$3" arquivo=/etc/wsl.conf
    touch "$arquivo"
    grep -q "^\[$secao\]" "$arquivo" || printf '\n[%s]\n' "$secao" >> "$arquivo"
    if grep -q "^$chave *=" "$arquivo"; then
        sed -i "s|^$chave *=.*|$chave=$valor|" "$arquivo"
    else
        sed -i "/^\[$secao\]/a $chave=$valor" "$arquivo"
    fi
}

configurar_hostname() {
    echo "$HOSTNAME_SERVIDOR" > /etc/hostname
    hostnamectl set-hostname "$HOSTNAME_SERVIDOR" 2>/dev/null || hostname "$HOSTNAME_SERVIDOR"
    if eh_wsl; then
        ajustar_wsl_conf network hostname "$HOSTNAME_SERVIDOR"
        ajustar_wsl_conf network generateHosts false
    fi
}

configurar_hosts() {
    local ip
    ip="$(ip_sem_mascara "$IP_SERVICO")"
    sed -i "/^$MARCA_INICIO/,/^$MARCA_FIM/d" /etc/hosts
    sed -i "/[[:space:]]$HOSTNAME_SERVIDOR\$/d" /etc/hosts
    cat >> /etc/hosts <<EOF
$MARCA_INICIO
127.0.1.1   $FQDN $HOSTNAME_SERVIDOR
$ip  $APP_HOST_PUBLICO
127.0.0.1   db.$DOMINIO
$MARCA_FIM
EOF
}

rede_por_servico() {
    local iface="$1"
    cat > /etc/systemd/system/quorum-rede.service <<EOF
[Unit]
Description=Quorum - IP de serviço $IP_SERVICO em $iface
After=network.target
Before=quorum-api.service nginx.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ip addr replace $IP_SERVICO dev $iface label $iface:quorum
ExecStop=/usr/sbin/ip addr del $IP_SERVICO dev $iface

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable quorum-rede.service
    systemctl restart quorum-rede.service
}

rede_por_netplan() {
    local iface="$1" arquivo=/etc/netplan/60-quorum.yaml dns_lista
    dns_lista="$(echo "$DNS_SERVIDORES" | sed 's/ /, /g')"
    if [[ -n "$IP_ESTATICO" ]]; then
        cat > "$arquivo" <<EOF
network:
  version: 2
  ethernets:
    $iface:
      dhcp4: false
      addresses: [$IP_ESTATICO, $IP_SERVICO]
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [$dns_lista]
        search: [$DOMINIO]
EOF
    else
        cat > "$arquivo" <<EOF
network:
  version: 2
  ethernets:
    $iface:
      dhcp4: true
      addresses: [$IP_SERVICO]
      nameservers:
        addresses: [$dns_lista]
        search: [$DOMINIO]
EOF
    fi
    chmod 600 "$arquivo"
    netplan generate
    netplan apply
}

configurar_rede() {
    local iface modo="$REDE_MODO"
    iface="$(interface_padrao)"
    [[ -n "$iface" ]] || { echo "nenhuma interface com rota padrão"; return 1; }
    if [[ "$modo" == "auto" ]]; then
        if eh_wsl; then
            modo="servico"
        elif command -v netplan >/dev/null; then
            modo="netplan"
        else
            modo="servico"
        fi
    fi
    echo "interface=$iface modo=$modo"
    case "$modo" in
        netplan) rede_por_netplan "$iface" ;;
        servico) rede_por_servico "$iface" ;;
        *) echo "REDE_MODO desconhecido: $modo"; return 1 ;;
    esac
    ip -4 addr show dev "$iface" | grep -q "$(ip_sem_mascara "$IP_SERVICO")/"
}

configurar_dns() {
    if eh_wsl; then
        ajustar_wsl_conf network generateResolvConf false
    fi
    if systemctl is-active --quiet systemd-resolved; then
        install -d /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/quorum.conf <<EOF
[Resolve]
DNS=$DNS_SERVIDORES
Domains=$DOMINIO
EOF
        systemctl restart systemd-resolved
        ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        resolvectl dns
    else
        rm -f /etc/resolv.conf
        {
            echo "# gerado por 01-infraestrutura.sh"
            for servidor in $DNS_SERVIDORES; do echo "nameserver $servidor"; done
            echo "search $DOMINIO"
            echo "options timeout:2 attempts:2"
        } > /etc/resolv.conf
    fi
}

testar_resolucao() {
    getent hosts "$APP_HOST_PUBLICO"
    getent hosts "$FQDN"
    getent hosts "db.$DOMINIO"
    getent hosts github.com
}

configurar_usuarios() {
    getent group "$GRUPO_OPERADORES" >/dev/null || groupadd "$GRUPO_OPERADORES"
    if ! id "$USUARIO_APP" >/dev/null 2>&1; then
        useradd --system --home-dir /opt/quorum --shell /usr/sbin/nologin --user-group "$USUARIO_APP"
    fi
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        usermod -aG "$GRUPO_OPERADORES" "$SUDO_USER"
    fi
    local sudoers=/etc/sudoers.d/quorum-ops
    cat > "$sudoers.tmp" <<EOF
%$GRUPO_OPERADORES ALL=(root) NOPASSWD: /usr/bin/systemctl start quorum-*, /usr/bin/systemctl stop quorum-*, /usr/bin/systemctl restart quorum-*, /usr/bin/systemctl status quorum-*, /usr/bin/journalctl -u quorum-*
EOF
    visudo -cf "$sudoers.tmp"
    install -m 440 "$sudoers.tmp" "$sudoers"
    rm -f "$sudoers.tmp"
}

configurar_diretorios() {
    install -d -m 750 -o "$USUARIO_APP" -g "$USUARIO_APP" /opt/quorum
    install -d -m 750 -o root -g "$USUARIO_APP" "$CONF_DIR"
    install -d -m 2775 -o root -g "$GRUPO_OPERADORES" "$LOG_DIR"
    chgrp "$GRUPO_OPERADORES" "$LOG_DIR"/*.log
}

configurar_firewall() {
    for porta in $PORTAS_LIBERADAS; do
        ufw allow "$porta/tcp"
    done
    ufw --force enable
    ufw status verbose
}

etapa "Validação da configuração"
executar "Validar parâmetros de $QUORUM_CONF" validar_config

etapa "Pacotes base"
executar "Instalar ferramentas de rede e sistema" instalar_base
registrar_pacotes iproute2 dnsutils ufw sudo curl tzdata

etapa "Fuso horário"
executar "Definir fuso $FUSO_HORARIO" configurar_fuso

etapa "Hostname"
executar "Definir hostname $HOSTNAME_SERVIDOR ($FQDN)" configurar_hostname

etapa "Rede"
executar "Configurar IP de serviço $IP_SERVICO" configurar_rede

etapa "Resolução de nomes"
executar "Registrar nomes locais em /etc/hosts" configurar_hosts
executar "Configurar servidores DNS ($DNS_SERVIDORES)" configurar_dns
executar "Testar resolução local e externa" testar_resolucao

etapa "Usuários e permissões"
executar "Criar usuário $USUARIO_APP e grupo $GRUPO_OPERADORES" configurar_usuarios
executar "Criar diretórios com permissões" configurar_diretorios

if [[ "$FIREWALL" == "sim" ]]; then
    etapa "Firewall"
    tentar "Liberar portas $PORTAS_LIBERADAS no ufw" configurar_firewall
fi

etapa "Resumo"
log_ok "Hostname: $(hostname) | FQDN: $FQDN"
log_ok "Endereços: $(hostname -I)"
if command -v resolvectl >/dev/null && systemctl is-active --quiet systemd-resolved; then
    log_ok "DNS: $(resolvectl status | awk -F': ' '/DNS Servers|DNS Domain/ {print $2}' | sort -u | tr '\n' ' ')"
else
    log_ok "DNS: $(grep -E '^(nameserver|search)' /etc/resolv.conf | tr '\n' ' ')"
fi
log_ok "Infraestrutura base pronta"
