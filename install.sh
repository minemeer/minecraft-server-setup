#!/bin/bash
# Minecraft Server Setup for Ubuntu (with systemd + screen)
# Repository: https://github.com/minemeer/minecraft-server-setup

set -e  # Skript bei Fehlern abbrechen

REPO_BASE="https://raw.githubusercontent.com/minemeer/minecraft-server-setup/main/templates"
MC_USER="mc"
MC_BASE="/opt/minecraft"

# Farben für Ausgaben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Hilfe anzeigen
show_help() {
    echo "Verwendung: $0 [OPTION]"
    echo "Optionen:"
    echo "  --add-server NAME   Neuen Paper-Server mit Namen NAME anlegen"
    echo "  --help              Diese Hilfe anzeigen"
    exit 0
}

# Prüfen, ob Skript als root ausgeführt wird
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Dieses Skript muss als root ausgeführt werden!${NC}"
        exit 1
    fi
}

# Benutzer und Gruppen anlegen
setup_user() {
    if ! id -u "$MC_USER" &>/dev/null; then
        echo -e "${GREEN}Benutzer $MC_USER wird angelegt...${NC}"
        useradd --system --user-group --home-dir "$MC_BASE" --create-home "$MC_USER"
    else
        echo -e "${YELLOW}Benutzer $MC_USER existiert bereits.${NC}"
    fi
}

# Abhängigkeiten installieren
install_deps() {
    echo -e "${GREEN}Installiere Abhängigkeiten (openjdk-17, screen, wget)...${NC}"
    apt update
    apt install -y openjdk-17-jre-headless screen wget curl
}

# Basisverzeichnis erstellen und Besitzer setzen
setup_dirs() {
    mkdir -p "$MC_BASE"
    chown -R "$MC_USER:$MC_USER" "$MC_BASE"
}

# Template herunterladen und Platzhalter ersetzen
# Parameter: template_name, output_file, ersetzungen (als "KEY1=WERT1,KEY2=WERT2,...")
download_and_replace() {
    local template="$1"
    local output="$2"
    local replacements="$3"
    local tmp_file="/tmp/${template}.tmp"

    # Template herunterladen
    wget -q "${REPO_BASE}/${template}" -O "$tmp_file" || {
        echo -e "${RED}Fehler beim Herunterladen von ${template}${NC}"
        return 1
    }

    # Platzhalter ersetzen (z.B. {{NAME}} durch Wert)
    IFS=',' read -ra kv_pairs <<< "$replacements"
    for pair in "${kv_pairs[@]}"; do
        key=$(echo "$pair" | cut -d= -f1)
        val=$(echo "$pair" | cut -d= -f2-)
        # Escape Schrägstriche für sed
        val_escaped=$(echo "$val" | sed 's/[\/&]/\\&/g')
        sed -i "s/{{${key}}}/${val_escaped}/g" "$tmp_file"
    done

    # Zielverzeichnis erstellen, falls nötig
    mkdir -p "$(dirname "$output")"
    mv "$tmp_file" "$output"
    echo -e "${GREEN}✓ ${output} erstellt${NC}"
}

# Interaktive Abfrage einer Zahl
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

# Server installieren (Typ: paper oder velocity)
install_server() {
    local type="$1"       # "paper" oder "velocity"
    local name="$2"       # z.B. "lobby", "citybuild"
    local port="$3"       # Port (nur für Paper relevant)
    local ram_min="$4"    # z.B. 1024 (in MB)
    local ram_max="$5"    # z.B. 2048

    local server_dir="$MC_BASE/$name"
    local start_script="$server_dir/start.sh"
    local service_file="/etc/systemd/system/minecraft-${name}.service"

    # Prüfen, ob Server bereits existiert (Ordner)
    if [[ -d "$server_dir" && -f "$start_script" ]]; then
        echo -e "${YELLOW}Server $name existiert bereits.${NC}"
        read -p "Soll die bestehende Konfiguration durch die Vorlage ersetzt werden? (j/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Jj]$ ]]; then
            echo -e "${YELLOW}Überspringe $name.${NC}"
            return
        fi
    fi

    # Ordner anlegen
    mkdir -p "$server_dir"

    # Startskript erstellen
    if [[ "$type" == "paper" ]]; then
        download_and_replace "paper-start.sh" "$start_script" \
            "NAME=$name,RAM_MIN=$ram_min,RAM_MAX=$ram_max,PORT=$port"
    else
        download_and_replace "velocity-start.sh" "$start_script" \
            "NAME=$name,RAM_MIN=$ram_min,RAM_MAX=$ram_max"
    fi
    chmod +x "$start_script"
    chown -R "$MC_USER:$MC_USER" "$server_dir"

    # systemd Service anlegen
    if [[ "$type" == "paper" ]]; then
        download_and_replace "paper.service" "$service_file" "NAME=$name"
    else
        download_and_replace "velocity.service" "$service_file" "NAME=$name"
    fi

    # systemd neu laden und Dienst aktivieren/starten
    systemctl daemon-reload
    systemctl enable "minecraft-${name}.service"
    systemctl start "minecraft-${name}.service"

    echo -e "${GREEN}✓ Server $name wurde installiert und gestartet.${NC}"
}

# Hauptinstallation (Lobby + Velocity)
main_install() {
    echo -e "${GREEN}=== Minecraft Server Installation ===${NC}"
    
    # Lobby (Paper)
    echo -e "\n${YELLOW}--- Lobby Server (Paper) ---${NC}"
    local lobby_port=$(ask_number "Port für Lobby" "25565")
    local lobby_ram_min=$(ask_number "Min. RAM (MB) für Lobby" "1024")
    local lobby_ram_max=$(ask_number "Max. RAM (MB) für Lobby" "2048")
    install_server "paper" "lobby" "$lobby_port" "$lobby_ram_min" "$lobby_ram_max"

    # Velocity
    echo -e "\n${YELLOW}--- Velocity Proxy ---${NC}"
    local velocity_port=$(ask_number "Port für Velocity" "25577")
    local velocity_ram_min=$(ask_number "Min. RAM (MB) für Velocity" "512")
    local velocity_ram_max=$(ask_number "Max. RAM (MB) für Velocity" "1024")
    install_server "velocity" "velocity" "$velocity_port" "$velocity_ram_min" "$velocity_ram_max"

    # Weitere Paper-Server?
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
    echo "Du kannst dich mit folgenden Befehlen mit der Konsole verbinden:"
    echo "  sudo -u mc screen -r lobby"
    echo "  sudo -u mc screen -r velocity"
    echo "Weitere Server entsprechend ihrem Namen."
}

# Funktion für --add-server
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

# Parameter auswerten
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
    # Normale Installation
    setup_user
    install_deps
    setup_dirs
    main_install
fi
