#!/bin/bash
# Minecraft Server Setup für Ubuntu (mit systemd + screen)
# Repository: https://github.com/minemeer/minecraft-server-setup

set -e

REPO_BASE="https://raw.githubusercontent.com/minemeer/minecraft-server-setup/main/templates"
MC_USER="mc"
MC_BASE="/opt/minecraft"

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

show_help() {
    echo "Verwendung: $0 [OPTION]"
    echo "Optionen:"
    echo "  --add-server NAME   Neuen Paper-Server mit Namen NAME anlegen"
    echo "  --help              Diese Hilfe anzeigen"
    exit 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Bitte als root ausführen (sudo).${NC}"
        exit 1
    fi
}

setup_user() {
    if ! id -u "$MC_USER" &>/dev/null; then
        echo -e "${GREEN}Benutzer $MC_USER wird angelegt...${NC}"
        useradd --system --user-group --home-dir "$MC_BASE" --create-home "$MC_USER"
    else
        echo -e "${YELLOW}Benutzer $MC_USER existiert bereits.${NC}"
    fi
}

install_deps() {
    echo -e "${GREEN}Installiere Abhängigkeiten...${NC}"
    apt update
    apt install -y openjdk-21-jre-headless screen wget curl
}

setup_dirs() {
    mkdir -p "$MC_BASE"
    chown -R "$MC_USER:$MC_USER" "$MC_BASE"
}

download_and_replace() {
    local template="$1"
    local output="$2"
    local replacements="$3"
    local tmp_file="/tmp/${template}.tmp"

    wget -q "${REPO_BASE}/${template}" -O "$tmp_file" || {
        echo -e "${RED}Fehler beim Herunterladen von ${template}${NC}"
        return 1
    }

    IFS=',' read -ra kv_pairs <<< "$replacements"
    for pair in "${kv_pairs[@]}"; do
        key=$(echo "$pair" | cut -d= -f1)
        val=$(echo "$pair" | cut -d= -f2-)
        val_escaped=$(echo "$val" | sed 's/[\/&]/\\&/g')
        sed -i "s/{{${key}}}/${val_escaped}/g" "$tmp_file"
    done

    mkdir -p "$(dirname "$output")"
    mv "$tmp_file" "$output"
    echo -e "${GREEN}✓ ${output} erstellt${NC}"
}

ask_number() {
    local prompt="$1"
    local default="$2"
    local var
    while true; do
        read -p "$prompt [$default]: " var
        var=${var:-$default}
        if [[ "$var" =~ ^[0-9]+$ ]]; then
            echo "$var"
            break
        else
            echo -e "${RED}Bitte eine gültige Zahl eingeben.${NC}"
        fi
    done
}

# Funktion zum Prüfen, ob ein Dienst läuft
check_service() {
    local service="minecraft-$1.service"
    if systemctl is-active --quiet "$service"; then
        echo -e "${GREEN}✓ $service läuft${NC}"
    else
        echo -e "${RED}✗ $service läuft NICHT! Bitte Logs prüfen: journalctl -u $service${NC}"
    fi
}

install_server() {
    local type="$1"
    local name="$2"
    local port="$3"
    local ram_min="$4"
    local ram_max="$5"

    local server_dir="$MC_BASE/$name"
    local start_script="$server_dir/start.sh"
    local service_file="/etc/systemd/system/minecraft-${name}.service"

    if [[ -d "$server_dir" && -f "$start_script" ]]; then
        echo -e "${YELLOW}Server $name existiert bereits.${NC}"
        read -p "Soll die Konfiguration überschrieben werden? (j/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Jj]$ ]]; then
            echo -e "${YELLOW}Überspringe $name.${NC}"
            return
        fi
    fi

    mkdir -p "$server_dir"

    if [[ "$type" == "paper" ]]; then
        download_and_replace "paper-start.sh" "$start_script" \
            "NAME=$name,RAM_MIN=$ram_min,RAM_MAX=$ram_max,PORT=$port"
    else
        download_and_replace "velocity-start.sh" "$start_script" \
            "NAME=$name,RAM_MIN=$ram_min,RAM_MAX=$ram_max"
    fi
    chmod +x "$start_script"
    chown -R "$MC_USER:$MC_USER" "$server_dir"

    if [[ "$type" == "paper" ]]; then
        download_and_replace "paper.service" "$service_file" "NAME=$name"
    else
        download_and_replace "velocity.service" "$service_file" "NAME=$name"
    fi

    systemctl daemon-reload
    systemctl enable "minecraft-${name}.service"
    systemctl restart "minecraft-${name}.service"

    # Kurz warten und prüfen
    sleep 3
    check_service "$name"

    # Prüfen, ob screen-Session existiert
    if sudo -u "$MC_USER" screen -ls | grep -q "$name"; then
        echo -e "${GREEN}✓ screen-Session '$name' läuft${NC}"
    else
        echo -e "${RED}✗ screen-Session '$name' wurde nicht gefunden! Bitte Logs prüfen.${NC}"
    fi
}

main_install() {
    echo -e "${GREEN}=== Minecraft Server Installation ===${NC}"

    echo -e "\n${YELLOW}--- Lobby Server (Paper) ---${NC}"
    local lobby_port=$(ask_number "Port für Lobby" "25565")
    local lobby_ram_min=$(ask_number "Min. RAM (MB) für Lobby" "1024")
    local lobby_ram_max=$(ask_number "Max. RAM (MB) für Lobby" "2048")
    install_server "paper" "lobby" "$lobby_port" "$lobby_ram_min" "$lobby_ram_max"

    echo -e "\n${YELLOW}--- Velocity Proxy ---${NC}"
    local velocity_port=$(ask_number "Port für Velocity" "25577")
    local velocity_ram_min=$(ask_number "Min. RAM (MB) für Velocity" "512")
    local velocity_ram_max=$(ask_number "Max. RAM (MB) für Velocity" "1024")
    install_server "velocity" "velocity" "$velocity_port" "$velocity_ram_min" "$velocity_ram_max"

    while true; do
        echo
        read -p "Möchtest du einen weiteren Paper-Server hinzufügen? (j/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Jj]$ ]]; then
            break
        fi
        read -p "Name des Servers (z.B. citybuild): " server_name
        server_port=$(ask_number "Port für $server_name" "25566")
        ram_min=$(ask_number "Min. RAM (MB) für $server_name" "1024")
        ram_max=$(ask_number "Max. RAM (MB) für $server_name" "2048")
        install_server "paper" "$server_name" "$server_port" "$ram_min" "$ram_max"
    done

    echo -e "${GREEN}=== Installation abgeschlossen! ===${NC}"
    echo "Verfügbare screen-Sessions:"
    sudo -u "$MC_USER" screen -ls
    echo ""
    echo "Zugriff auf die Konsole:"
    echo "  sudo -u mc screen -r lobby"
    echo "  sudo -u mc screen -r velocity"
    echo "  (bei weiteren Servern entsprechend)"
}

add_server() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo -e "${RED}Bitte einen Servernamen angeben!${NC}"
        show_help
    fi
    echo -e "${GREEN}Neuen Paper-Server '$name' hinzufügen${NC}"
    local port=$(ask_number "Port für $name" "25565")
    local ram_min=$(ask_number "Min. RAM (MB) für $name" "1024")
    local ram_max=$(ask_number "Max. RAM (MB) für $name" "2048")
    install_server "paper" "$name" "$port" "$ram_min" "$ram_max"
}

# Hauptprogramm
check_root

if [[ $# -gt 0 ]]; then
    case "$1" in
        --add-server)
            add_server "$2"
            ;;
        --help)
            show_help
            ;;
        *)
            echo -e "${RED}Unbekannte Option: $1${NC}"
            show_help
            ;;
    esac
else
    setup_user
    install_deps
    setup_dirs
    main_install
fi
