#!/usr/bin/env bash
# Prepara e publica a API Quorum: dependências, banco, código, variáveis, serviço systemd e nginx.

source "$(dirname "$0")/lib/comum.sh"
iniciar_script "$@"

PACOTES=(python3 python3-venv python3-pip postgresql postgresql-contrib nginx git rsync jq openssl stress-ng sysstat logrotate acl)
ARQUIVO_ENV="$CONF_DIR/quorum.env"

instalar_pacotes() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q "${PACOTES[@]}"
}

iniciar_postgres() {
    systemctl enable --now postgresql
    for _ in $(seq 1 30); do
        runuser -u postgres -- pg_isready -q && return 0
        sleep 1
    done
    return 1
}

senha_do_banco() {
    if [[ -f "$ARQUIVO_ENV" ]] && grep -q '^DB_SENHA=' "$ARQUIVO_ENV"; then
        grep '^DB_SENHA=' "$ARQUIVO_ENV" | cut -d= -f2-
    else
        openssl rand -hex 16
    fi
}

criar_banco() {
    local existe
    existe="$(runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USUARIO'")"
    if [[ "$existe" == "1" ]]; then
        runuser -u postgres -- psql -q -c "ALTER ROLE $DB_USUARIO WITH LOGIN PASSWORD '$DB_SENHA'"
    else
        runuser -u postgres -- psql -q -c "CREATE ROLE $DB_USUARIO WITH LOGIN PASSWORD '$DB_SENHA'"
    fi
    existe="$(runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NOME'")"
    if [[ "$existe" != "1" ]]; then
        runuser -u postgres -- createdb -O "$DB_USUARIO" "$DB_NOME"
    fi
}

gravar_env() {
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
AMBIENTE=producao
TZ=$FUSO_HORARIO
APP_PORTA=$APP_PORTA
DB_HOST=db.$DOMINIO
DB_NOME=$DB_NOME
DB_USUARIO=$DB_USUARIO
DB_SENHA=$DB_SENHA
DATABASE_URL=postgresql+psycopg://$DB_USUARIO:$DB_SENHA@db.$DOMINIO:5432/$DB_NOME
EOF
    install -m 640 -o root -g "$USUARIO_APP" "$tmp" "$ARQUIVO_ENV"
    rm -f "$tmp"
}

baixar_codigo() {
    install -d -m 750 -o "$USUARIO_APP" -g "$USUARIO_APP" "$APP_DIR"
    if [[ -n "$APP_ORIGEM_LOCAL" ]]; then
        rsync -a --delete --exclude .git --exclude .venv --exclude .env --exclude __pycache__ \
            "$APP_ORIGEM_LOCAL"/ "$APP_DIR"/
        chown -R "$USUARIO_APP:$USUARIO_APP" "$APP_DIR"
    elif [[ -d "$APP_DIR/.git" ]]; then
        runuser -u "$USUARIO_APP" -- git -C "$APP_DIR" fetch -q origin "$APP_BRANCH"
        runuser -u "$USUARIO_APP" -- git -C "$APP_DIR" reset -q --hard "origin/$APP_BRANCH"
    else
        find "$APP_DIR" -mindepth 1 -delete
        runuser -u "$USUARIO_APP" -- git clone -q --branch "$APP_BRANCH" "$APP_REPO_URL" "$APP_DIR"
    fi
    test -f "$APP_DIR/requirements.txt"
    test -f "$APP_DIR/main.py"
}

instalar_dependencias() {
    if [[ ! -x "$APP_VENV/bin/python" ]]; then
        install -d -m 750 -o "$USUARIO_APP" -g "$USUARIO_APP" "$APP_VENV"
        runuser -u "$USUARIO_APP" -- python3 -m venv "$APP_VENV"
    fi
    runuser -u "$USUARIO_APP" -- "$APP_VENV/bin/pip" install -q --upgrade pip
    runuser -u "$USUARIO_APP" -- "$APP_VENV/bin/pip" install -q -r "$APP_DIR/requirements.txt"
    runuser -u "$USUARIO_APP" -- "$APP_VENV/bin/pip" freeze > "$LOG_DIR/dependencias-python.txt"
}

aplicar_migracoes() {
    runuser -u "$USUARIO_APP" -- bash -c "set -a; source '$ARQUIVO_ENV'; set +a; cd '$APP_DIR' && '$APP_VENV/bin/alembic' upgrade head && '$APP_VENV/bin/alembic' current"
}

instalar_servico_api() {
    sed -e "s|@USUARIO@|$USUARIO_APP|g" \
        -e "s|@APP_DIR@|$APP_DIR|g" \
        -e "s|@APP_VENV@|$APP_VENV|g" \
        -e "s|@ENV@|$ARQUIVO_ENV|g" \
        -e "s|@LOG_DIR@|$LOG_DIR|g" \
        "$RAIZ_PROJETO/systemd/quorum-api.service" > /etc/systemd/system/quorum-api.service
    touch "$LOG_DIR/api.log"
    chown "$USUARIO_APP:$GRUPO_OPERADORES" "$LOG_DIR/api.log"
    chmod 664 "$LOG_DIR/api.log"
    systemctl daemon-reload
    systemctl enable quorum-api.service
    systemctl restart quorum-api.service
}

configurar_nginx() {
    sed -e "s|@HOST@|$APP_HOST_PUBLICO|g" \
        -e "s|@FQDN@|$HOSTNAME_SERVIDOR.$DOMINIO|g" \
        -e "s|@PORTA@|$APP_PORTA|g" \
        "$RAIZ_PROJETO/nginx/quorum.conf" > /etc/nginx/sites-available/quorum.conf
    ln -sf /etc/nginx/sites-available/quorum.conf /etc/nginx/sites-enabled/quorum.conf
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl enable nginx
    systemctl reload-or-restart nginx
}

aguardar_api() {
    for _ in $(seq 1 30); do
        if curl -fsS "http://$APP_HOST_PUBLICO/health"; then
            echo
            return 0
        fi
        sleep 2
    done
    systemctl status quorum-api --no-pager || true
    return 1
}

etapa "Dependências do sistema"
executar "Instalar pacotes: ${PACOTES[*]}" instalar_pacotes
registrar_pacotes "${PACOTES[@]}"

etapa "Banco de dados"
executar "Iniciar PostgreSQL" iniciar_postgres
DB_SENHA="$(senha_do_banco)"
executar "Criar usuário e banco $DB_NOME" criar_banco

etapa "Variáveis de ambiente"
executar "Gravar $ARQUIVO_ENV (640, root:$USUARIO_APP)" gravar_env

etapa "Código da aplicação"
if [[ -n "$APP_ORIGEM_LOCAL" ]]; then
    executar "Copiar código de $APP_ORIGEM_LOCAL" baixar_codigo
else
    executar "Baixar código de $APP_REPO_URL ($APP_BRANCH)" baixar_codigo
fi
executar "Criar venv e instalar dependências Python" instalar_dependencias

etapa "Migrações"
executar "Aplicar migrações Alembic" aplicar_migracoes

etapa "Serviço da aplicação"
executar "Instalar e iniciar quorum-api.service" instalar_servico_api
executar "Publicar API no nginx ($APP_HOST_PUBLICO:80)" configurar_nginx

etapa "Verificação"
executar "Checar http://$APP_HOST_PUBLICO/health" aguardar_api
log_ok "Documentação: http://$APP_HOST_PUBLICO/docs"
log_ok "Aplicação Quorum publicada"
