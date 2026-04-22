#!/bin/bash
# =================================================================
#  http_functions.sh - Funciones HTTP para OpenSUSE Leap 16.0
#  Alumno: Laurean Acosta Luis Donaldo
#  Practica 6 - Administracion de Sistemas
# =================================================================

# -- Colores ------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
separador() { echo -e "${BLUE}$(printf '─%.0s' {1..52})${NC}"; }

# =================================================================
# VALIDACIONES
# =================================================================

# Valida que un puerto sea numero entre 1 y 65535
validar_puerto() {
    local puerto="$1"
    if ! [[ "$puerto" =~ ^[0-9]+$ ]]; then
        log_error "El puerto debe ser un numero."; return 1
    fi
    if (( puerto < 1 || puerto > 65535 )); then
        log_error "El puerto debe estar entre 1 y 65535."; return 1
    fi
    # Puertos reservados del sistema
    local reservados=(22 21 25 53 110 143 443 3306 5432 6379 27017)
    for r in "${reservados[@]}"; do
        if (( puerto == r )); then
            log_error "El puerto $puerto esta reservado para otro servicio."; return 1
        fi
    done
    return 0
}

# Valida que el puerto no este en uso
puerto_libre() {
    local puerto="$1"
    if ss -tlnp | grep -q ":${puerto} "; then
        log_error "El puerto $puerto ya esta en uso por otro proceso."
        ss -tlnp | grep ":${puerto} "
        return 1
    fi
    return 0
}

# Valida que el input no este vacio ni tenga caracteres peligrosos
validar_input() {
    local valor="$1" nombre="$2"
    if [[ -z "$valor" ]]; then
        log_error "$nombre no puede estar vacio."; return 1
    fi
    if [[ "$valor" =~ [^a-zA-Z0-9._\-] ]]; then
        log_error "$nombre contiene caracteres no permitidos."; return 1
    fi
    return 0
}

# =================================================================
# GESTION DE VERSIONES DINAMICA (zypper)
# =================================================================

# Obtiene versiones disponibles de un paquete desde el repositorio
obtener_versiones() {
    local paquete="$1"
    zypper search -s "$paquete" 2>/dev/null \
        | awk '/^\|/ && $4=="package" { print $6 }' \
        | sort -Vr \
        | uniq
}

# Muestra versiones y pide al usuario que elija una
elegir_version() {
    local paquete="$1"
    local -a versiones
    log_info "Consultando versiones disponibles de $paquete en el repositorio..."

    mapfile -t versiones < <(obtener_versiones "$paquete")

    if [[ ${#versiones[@]} -eq 0 ]]; then
        log_error "No se encontraron versiones de $paquete en el repositorio."
        return 1
    fi

    echo ""
    echo -e "${BOLD}Versiones disponibles de $paquete:${NC}"
    for i in "${!versiones[@]}"; do
        local tag=""
        if (( i == 0 )); then tag="${GREEN}[LTS/Estable]${NC}"; fi
        if (( i == 1 )); then tag="${YELLOW}[Desarrollo]${NC}"; fi
        echo -e "  $((i+1))) ${versiones[$i]} $tag"
    done
    echo ""

    local opcion version_elegida
    while true; do
        read -rp "Elige una version [1-${#versiones[@]}]: " opcion
        if [[ "$opcion" =~ ^[0-9]+$ ]] && (( opcion >= 1 && opcion <= ${#versiones[@]} )); then
            version_elegida="${versiones[$((opcion-1))]}"
            log_ok "Version seleccionada: $version_elegida"
            echo "$version_elegida"
            return 0
        fi
        log_error "Opcion invalida."
    done
}

# Pide puerto al usuario con validacion completa
pedir_puerto() {
    local puerto
    while true; do
        read -rp "Ingresa el puerto de escucha: " puerto
        if validar_puerto "$puerto" && puerto_libre "$puerto"; then
            echo "$puerto"
            return 0
        fi
    done
}

# =================================================================
# FIREWALL
# =================================================================

configurar_firewall() {
    local puerto="$1" puerto_anterior="$2"
    log_info "Configurando firewall..."

    # Abrir nuevo puerto
    firewall-cmd --permanent --add-port="${puerto}/tcp" &>/dev/null
    log_ok "Puerto $puerto abierto en firewall."

    # Cerrar puerto anterior si es diferente y no es el 22
    if [[ -n "$puerto_anterior" && "$puerto_anterior" != "$puerto" && "$puerto_anterior" != "22" ]]; then
        firewall-cmd --permanent --remove-port="${puerto_anterior}/tcp" &>/dev/null
        log_ok "Puerto $puerto_anterior cerrado en firewall."
    fi

    firewall-cmd --reload &>/dev/null
    log_ok "Firewall recargado."
}

# =================================================================
# USUARIO DEDICADO
# =================================================================

crear_usuario_servicio() {
    local usuario="$1" directorio="$2"
    if ! id "$usuario" &>/dev/null; then
        useradd -r -s /sbin/nologin -d "$directorio" -M "$usuario"
        log_ok "Usuario de servicio '$usuario' creado."
    else
        log_ok "Usuario de servicio '$usuario' ya existe."
    fi
    # Permisos limitados al directorio del servicio
    chown -R "${usuario}:${usuario}" "$directorio" 2>/dev/null
    chmod 750 "$directorio" 2>/dev/null
}

# =================================================================
# APACHE2
# =================================================================

instalar_apache() {
    separador
    log_info "=== INSTALACION DE APACHE2 ==="

    local version puerto
    version=$(elegir_version "apache2") || return 1
    echo ""
    puerto=$(pedir_puerto) || return 1

    log_info "Instalando apache2-${version}..."
    zypper install -y "apache2=${version}" &>/dev/null
    if ! command -v httpd &>/dev/null && ! systemctl list-unit-files | grep -q apache2; then
        zypper install -y apache2 &>/dev/null
    fi
    log_ok "Apache2 instalado."

    # Crear usuario dedicado
    crear_usuario_servicio "wwwrun" "/srv/www"

    # Configurar puerto
    local ports_conf="/etc/apache2/listen.conf"
    [[ ! -f "$ports_conf" ]] && ports_conf="/etc/apache2/ports.conf"
    if [[ -f "$ports_conf" ]]; then
        sed -i "s/Listen [0-9]*/Listen $puerto/g" "$ports_conf"
        log_ok "Puerto configurado en $ports_conf"
    fi

    # VirtualHost en puerto correcto
    local vhost="/etc/apache2/vhosts.d/practica6.conf"
    cat > "$vhost" <<EOF
<VirtualHost *:${puerto}>
    DocumentRoot /srv/www/htdocs
    <Directory /srv/www/htdocs>
        Options -Indexes
        AllowOverride None
        Require all granted
    </Directory>
    # Seguridad: deshabilitar metodos peligrosos
    <LimitExcept GET POST HEAD>
        Require all denied
    </LimitExcept>
    # Encabezados de seguridad
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
</VirtualHost>
EOF
    log_ok "VirtualHost configurado."

    # Ocultar version del servidor
    local sec_conf="/etc/apache2/conf.d/security.conf"
    [[ ! -f "$sec_conf" ]] && sec_conf="/etc/apache2/httpd.conf"
    if [[ -f "$sec_conf" ]]; then
        sed -i "s/^ServerTokens.*/ServerTokens Prod/" "$sec_conf"
        sed -i "s/^ServerSignature.*/ServerSignature Off/" "$sec_conf"
    else
        echo -e "ServerTokens Prod\nServerSignature Off" >> /etc/apache2/httpd.conf
    fi
    log_ok "Version del servidor ocultada (ServerTokens Prod)."

    # Habilitar mod_headers para encabezados de seguridad
    a2enmod headers &>/dev/null || true

    # Crear index.html personalizado
    mkdir -p /srv/www/htdocs
    cat > /srv/www/htdocs/index.html <<EOF
<!DOCTYPE html>
<html>
<head><title>Practica 6</title></head>
<body>
<h1>Servidor: Apache2 - Version: ${version} - Puerto: ${puerto}</h1>
</body>
</html>
EOF
    log_ok "index.html creado."

    # Habilitar y arrancar servicio
    systemctl enable apache2 &>/dev/null
    systemctl restart apache2
    if systemctl is-active --quiet apache2; then
        log_ok "Apache2 corriendo en puerto $puerto."
    else
        log_error "Apache2 no pudo iniciarse. Revisa: journalctl -xe"
        return 1
    fi

    configurar_firewall "$puerto" "80"
    echo ""
    log_ok "Verifica con: curl -I http://localhost:${puerto}"
}

# =================================================================
# NGINX
# =================================================================

instalar_nginx() {
    separador
    log_info "=== INSTALACION DE NGINX ==="

    local version puerto
    version=$(elegir_version "nginx") || return 1
    echo ""
    puerto=$(pedir_puerto) || return 1

    log_info "Instalando nginx-${version}..."
    zypper install -y "nginx=${version}" &>/dev/null || zypper install -y nginx &>/dev/null
    log_ok "Nginx instalado."

    # Crear usuario dedicado
    crear_usuario_servicio "nginx" "/srv/www/nginx"
    mkdir -p /srv/www/nginx

    # Configurar nginx.conf con puerto y seguridad
    cat > /etc/nginx/nginx.conf <<EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Ocultar version del servidor
    server_tokens off;

    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       ${puerto};
        server_name  localhost;
        root         /srv/www/nginx;
        index        index.html;

        # Deshabilitar metodos peligrosos
        if (\$request_method !~ ^(GET|POST|HEAD)$) {
            return 405;
        }

        # Encabezados de seguridad
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;

        location / {
            try_files \$uri \$uri/ =404;
        }

        # Bloquear acceso a archivos ocultos
        location ~ /\. {
            deny all;
        }
    }
}
EOF
    log_ok "nginx.conf configurado en puerto $puerto."

    # Crear index.html personalizado
    cat > /srv/www/nginx/index.html <<EOF
<!DOCTYPE html>
<html>
<head><title>Practica 6</title></head>
<body>
<h1>Servidor: Nginx - Version: ${version} - Puerto: ${puerto}</h1>
</body>
</html>
EOF
    log_ok "index.html creado."

    chown -R nginx:nginx /srv/www/nginx

    # Habilitar y arrancar
    systemctl enable nginx &>/dev/null
    systemctl restart nginx
    if systemctl is-active --quiet nginx; then
        log_ok "Nginx corriendo en puerto $puerto."
    else
        log_error "Nginx no pudo iniciarse. Revisa: journalctl -xe"
        nginx -t
        return 1
    fi

    configurar_firewall "$puerto" "80"
    echo ""
    log_ok "Verifica con: curl -I http://localhost:${puerto}"
}

# =================================================================
# TOMCAT
# =================================================================

instalar_tomcat() {
    separador
    log_info "=== INSTALACION DE TOMCAT ==="

    local version puerto
    version=$(elegir_version "tomcat") || return 1
    echo ""
    puerto=$(pedir_puerto) || return 1

    log_info "Instalando tomcat-${version}..."
    zypper install -y "tomcat=${version}" &>/dev/null || zypper install -y tomcat &>/dev/null
    log_ok "Tomcat instalado."

    # Usuario dedicado (tomcat ya crea su usuario)
    crear_usuario_servicio "tomcat" "/var/lib/tomcat"

    # Detectar server.xml
    local server_xml=""
    for ruta in /etc/tomcat/server.xml /usr/share/tomcat/conf/server.xml; do
        [[ -f "$ruta" ]] && server_xml="$ruta" && break
    done

    if [[ -z "$server_xml" ]]; then
        log_error "No se encontro server.xml de Tomcat."
        return 1
    fi

    # Cambiar puerto en server.xml
    sed -i "s/port=\"8080\"/port=\"${puerto}\"/g" "$server_xml"
    sed -i "s/port=\"8005\"/port=\"8006\"/g"      "$server_xml"  # evitar conflicto shutdown
    log_ok "Puerto configurado en $server_xml"

    # Variables de entorno para Tomcat
    local catalina_env="/etc/tomcat/tomcat.conf"
    [[ ! -f "$catalina_env" ]] && catalina_env="/usr/share/tomcat/conf/tomcat.conf"
    if [[ -f "$catalina_env" ]]; then
        grep -q "CATALINA_HOME" "$catalina_env" || \
            echo 'export CATALINA_HOME=/usr/share/tomcat' >> "$catalina_env"
        grep -q "CATALINA_BASE" "$catalina_env" || \
            echo 'export CATALINA_BASE=/var/lib/tomcat' >> "$catalina_env"
        log_ok "Variables de entorno configuradas."
    fi

    # Ocultar version en encabezados HTTP (ServerInfo)
    local catalina_prop=""
    for ruta in /usr/share/tomcat/lib /var/lib/tomcat/lib; do
        [[ -d "$ruta" ]] && catalina_prop="$ruta" && break
    done
    # Crear archivo de override de ServerInfo
    mkdir -p /tmp/catalina_override/org/apache/catalina/util
    echo "server.info=Apache Tomcat" > /tmp/catalina_override/org/apache/catalina/util/ServerInfo.properties
    echo "server.number=" >> /tmp/catalina_override/org/apache/catalina/util/ServerInfo.properties
    echo "server.built=" >> /tmp/catalina_override/org/apache/catalina/util/ServerInfo.properties
    if [[ -n "$catalina_prop" ]]; then
        cd /tmp/catalina_override && jar cf "${catalina_prop}/catalina_override.jar" org/ 2>/dev/null || true
        cd - &>/dev/null
    fi
    log_ok "Version de Tomcat ocultada en encabezados."

    # Crear index.jsp personalizado
    local webroot=""
    for ruta in /var/lib/tomcat/webapps/ROOT /usr/share/tomcat/webapps/ROOT; do
        [[ -d "$ruta" ]] && webroot="$ruta" && break
    done
    [[ -z "$webroot" ]] && webroot="/var/lib/tomcat/webapps/ROOT" && mkdir -p "$webroot"

    cat > "$webroot/index.html" <<EOF
<!DOCTYPE html>
<html>
<head><title>Practica 6</title></head>
<body>
<h1>Servidor: Tomcat - Version: ${version} - Puerto: ${puerto}</h1>
</body>
</html>
EOF
    log_ok "index.html creado en $webroot"

    # Permisos
    chown -R tomcat:tomcat /var/lib/tomcat 2>/dev/null || true
    chmod 750 /var/lib/tomcat 2>/dev/null || true

    # Habilitar y arrancar
    systemctl enable tomcat &>/dev/null
    systemctl restart tomcat
    sleep 3
    if systemctl is-active --quiet tomcat; then
        log_ok "Tomcat corriendo en puerto $puerto."
    else
        log_error "Tomcat no pudo iniciarse. Revisa: journalctl -xe"
        return 1
    fi

    configurar_firewall "$puerto" "8080"
    echo ""
    log_ok "Verifica con: curl -I http://localhost:${puerto}"
}

# =================================================================
# ESTADO DE SERVICIOS
# =================================================================

estado_servicios() {
    separador
    echo -e "${BOLD}Estado de servicios HTTP:${NC}"
    echo ""
    for svc in apache2 nginx tomcat; do
        if systemctl list-unit-files | grep -q "^${svc}"; then
            local estado
            estado=$(systemctl is-active "$svc" 2>/dev/null)
            if [[ "$estado" == "active" ]]; then
                echo -e "  ${GREEN}●${NC} $svc: ${GREEN}activo${NC}"
                # Mostrar puerto en uso
                ss -tlnp | grep -E "httpd|nginx|java" | awk '{print "    Puerto: "$4}' | head -3
            else
                echo -e "  ${RED}●${NC} $svc: ${RED}inactivo${NC}"
            fi
        fi
    done
    echo ""
}

# =================================================================
# DESINSTALAR SERVICIO
# =================================================================

desinstalar_servicio() {
    separador
    echo -e "${BOLD}Servicios instalados:${NC}"
    echo "  1) Apache2"
    echo "  2) Nginx"
    echo "  3) Tomcat"
    echo ""
    local opcion
    read -rp "Elige servicio a desinstalar [1-3]: " opcion

    local svc pkg
    case "$opcion" in
        1) svc="apache2"; pkg="apache2" ;;
        2) svc="nginx";   pkg="nginx"   ;;
        3) svc="tomcat";  pkg="tomcat"  ;;
        *) log_error "Opcion invalida."; return 1 ;;
    esac

    local confirm
    read -rp "¿Confirmar desinstalacion de $svc? (s/N): " confirm
    [[ ! "$confirm" =~ ^[Ss]$ ]] && log_warn "Cancelado." && return 0

    systemctl stop "$svc" &>/dev/null
    systemctl disable "$svc" &>/dev/null
    zypper remove -y "$pkg" &>/dev/null
    log_ok "$svc desinstalado."
}
