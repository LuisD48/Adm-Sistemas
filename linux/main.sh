#!/bin/bash
# =================================================================
#  main.sh - Despliegue Dinamico de Servicios HTTP
#  Alumno: Laurean Acosta Luis Donaldo
#  Practica 6 - Administracion de Sistemas
#
#  USO: sudo bash main.sh
#
#  Estructura:
#    main.sh           <- solo menu y llamadas a funciones
#    http_functions.sh <- toda la logica
#
#  Servidores soportados:
#    - Apache2  (zypper, versiones dinamicas)
#    - Nginx    (zypper, versiones dinamicas)
#    - Tomcat   (zypper, versiones dinamicas)
# =================================================================

# -- Verificar root -----------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Ejecuta el script como root: sudo bash main.sh"
    exit 1
fi

# -- Cargar funciones ---------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCTIONS="${SCRIPT_DIR}/http_functions.sh"

if [[ ! -f "$FUNCTIONS" ]]; then
    echo "[ERROR] No se encontro http_functions.sh en $SCRIPT_DIR"
    exit 1
fi

source "$FUNCTIONS"

# =================================================================
# MENU PRINCIPAL
# =================================================================
menu_principal() {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║  DESPLIEGUE HTTP - OpenSUSE Leap 16.0   ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║  1) Instalar Apache2                     ║${NC}"
        echo -e "${CYAN}║  2) Instalar Nginx                       ║${NC}"
        echo -e "${CYAN}║  3) Instalar Tomcat                      ║${NC}"
        echo -e "${CYAN}║  4) Estado de servicios                  ║${NC}"
        echo -e "${CYAN}║  5) Desinstalar servicio                 ║${NC}"
        echo -e "${CYAN}║  0) Salir                                ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
        echo ""
        read -rp "Opcion [0-5]: " opcion

        case "$opcion" in
            1) instalar_apache   ;;
            2) instalar_nginx    ;;
            3) instalar_tomcat   ;;
            4) estado_servicios  ;;
            5) desinstalar_servicio ;;
            0) echo -e "\n${GREEN}Saliendo...${NC}\n"; exit 0 ;;
            *) log_error "Opcion no valida." ;;
        esac

        echo ""
        read -rp "Presiona Enter para continuar..."
    done
}

# =================================================================
# PUNTO DE ENTRADA
# =================================================================
menu_principal
