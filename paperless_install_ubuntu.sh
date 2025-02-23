#!/bin/bash
set -euo pipefail

# Installiere sudo und dialog, falls nicht vorhanden
if ! command -v sudo &>/dev/null; then
    apt update
    apt install -y sudo
fi

if ! command -v dialog &>/dev/null; then
    apt update
    apt install -y dialog
fi

# Funktion zur sicheren Passworteingabe mit Dialog
function prompt_for_password() {
  local password password_confirm
  local field_name="$1"
  local var_name="$2"

  if [[ "$1" == "PAPERLESS_PASSWORD" ]]; then
    dialog --msgbox "Hinweis: Dieses Passwort wird für den Linux-Benutzer 'paperless' und den Samba-Server verwendet. Es wird für den Zugriff auf freigegebene Samba-Ordner benötigt." 10 50
  fi

  while true; do
    # Passworteingabe mit Dialog (insecure) und Behandlung von Sonderzeichen
    password=$(dialog --title "Passwort für $field_name" --insecure --passwordbox "Bitte geben Sie das Passwort für $field_name ein:" 10 50 3>&1 1>&2 2>&3)
    password_confirm=$(dialog --title "Bestätigung" --insecure --passwordbox "Bitte bestätigen Sie das Passwort:" 10 50 3>&1 1>&2 2>&3)

    # Überprüfung der Passworteingabe
    if [[ "$password" == "$password_confirm" ]]; then
      # Temporär setze 'set +u' um ungebundene Variablen zuzulassen
      set +u
      eval "$var_name='$password'"
      set -u  # Setze 'set -u' zurück

      dialog --msgbox "Passwort erfolgreich gesetzt für $field_name." 10 50
      break
    else
      dialog --msgbox "Die Passwörter stimmen nicht überein. Bitte erneut eingeben." 10 50
    fi
  done
}

# Funktion zur Eingabe des Admin-Benutzernamens
function prompt_for_admin_user() {
  ADMIN_USER=$(dialog --inputbox "Bitte geben Sie den Admin-Benutzernamen ein (Standard: paperless):" 10 50 "paperless" 3>&1 1>&2 2>&3)
  ADMIN_USER="${ADMIN_USER:-paperless}"
  dialog --msgbox "Admin-Benutzer wurde auf '$ADMIN_USER' gesetzt." 10 50
}

# Passwörter abfragen
prompt_for_password "PAPERLESS_PASSWORD" PAPERLESS_PASSWORD
prompt_for_admin_user
prompt_for_password "ADMIN_PASSWORD" ADMIN_PASSWORD

# Weitere Konfigurationen
SAMBA_PASSWORD="$PAPERLESS_PASSWORD"
DB_PASSWORD="paperless"

# System aktualisieren und benötigte Pakete installieren
update_and_install_dependencies() {
  sudo apt update
  sudo apt install -y apt-transport-https curl jq gnupg openssh-server samba samba-common-bin
}

# Docker-Repository hinzufügen
add_docker_repo() {
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  DOCKER_REPO="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable"
  echo "$DOCKER_REPO" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt update
}

# Paperless-Benutzer und Gruppe anlegen
ensure_paperless_user_and_group() {
  sudo groupadd -g 1002 paperless
  sudo useradd -m -s /bin/bash -u 1002 -g paperless paperless
  echo "paperless:$PAPERLESS_PASSWORD" | sudo chpasswd
}

# Docker installieren
install_docker() {
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
}

# Samba Konfiguration
configure_samba() {
  sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

  # Verzeichnisse und Freigaben, die erstellt werden sollen
  directories=("consume" "backup" "restore")
  
  # Erstelle die Verzeichnisse
  for dir in "${directories[@]}"; do
    sudo mkdir -p "/data/paperless/$dir"
    sudo chown -R paperless:paperless "/data/paperless/$dir"
    sudo chmod -R 770 "/data/paperless/$dir"
  done

  # Überprüfen, ob die Freigaben bereits in smb.conf existieren und hinzufügen, falls nicht
  if ! grep -q "^\[consume\]" /etc/samba/smb.conf; then
    for dir in "${directories[@]}"; do
      sudo tee -a /etc/samba/smb.conf > /dev/null <<EOF
[$dir]
   comment = Paperless $dir Daten
   path = /data/paperless/$dir
   browsable = yes
   writable = yes
   guest ok = no
   create mask = 0770
   directory mask = 0770
   valid users = paperless
EOF
    done
  fi

  # Samba-Dienst neu starten, um Änderungen zu übernehmen
  sudo systemctl restart smbd

  # Bestätigung, dass Freigaben konfiguriert wurden
  echo "Samba Shares [consume], [backup] und [restore] wurden konfiguriert."

  # Samba-Benutzer und Passwort setzen
  (echo "$SAMBA_PASSWORD"; echo "$SAMBA_PASSWORD") | sudo smbpasswd -a paperless -s

  # Samba-Dienst erneut starten
  sudo systemctl restart smbd
}

# Docker-Compose-Datei erstellen und Container starten
deploy_containers() {
  sudo mkdir -p /home/paperless
  cat <<EOL | sudo tee /home/paperless/docker-compose.yml > /dev/null
services:
  broker:
    image: redis:7
    container_name: broker
    restart: unless-stopped
    volumes:
      - /data/paperless/redis/_data:/data

  db:
    image: postgres:16
    container_name: db
    restart: unless-stopped
    volumes:
      - /data/paperless/postgresql/_data:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: 'paperless'
      POSTGRES_USER: 'paperless'
      POSTGRES_PASSWORD: '$DB_PASSWORD'

  webserver:
    image: ghcr.io/paperless-ngx/paperless-ngx:latest
    container_name: webserver
    restart: unless-stopped
    depends_on:
      - db
      - broker
      - gotenberg
      - tika
    ports:
      - "8001:8000"
    volumes:
      - /data/paperless/consume:/usr/src/paperless/consume
      - /data/paperless/data:/usr/src/paperless/data
      - /data/paperless/media:/usr/src/paperless/media
      - /data/paperless/export:/usr/src/paperless/export
    environment:
      PAPERLESS_ADMIN_USER: '$ADMIN_USER'
      PAPERLESS_ADMIN_PASSWORD: '$ADMIN_PASSWORD'
      PAPERLESS_REDIS: 'redis://broker:6379'
      PAPERLESS_DBHOST: 'db'
      PAPERLESS_TIKA_ENABLED: '1'
      PAPERLESS_TIKA_GOTENBERG_ENDPOINT: 'http://gotenberg:3000'
      PAPERLESS_TIKA_ENDPOINT: 'http://tika:9998'
      PAPERLESS_OCR_LANGUAGE: 'deu'
      PAPERLESS_TIME_ZONE: 'Europe/Berlin'
      PAPERLESS_CONSUMER_ENABLE_BARCODES: 'true'
      PAPERLESS_CONSUMER_ENABLE_ASN_BARCODE: 'true'
      PAPERLESS_CONSUMER_BARCODE_SCANNER: 'ZXING'
      PAPERLESS_EMAIL_TASK_CRON: '*/10 * * * *'
      USERMAP_UID: '1002'
      USERMAP_GID: '1002'

  gotenberg:
    image: gotenberg/gotenberg:8.8
    restart: unless-stopped
    command:
      - 'gotenberg'
      - '--chromium-disable-javascript=false'
      - '--chromium-allow-list=.*'

  tika:
    image: ghcr.io/paperless-ngx/tika:latest
    container_name: tika
    restart: unless-stopped
EOL
  cd /home/paperless
  sudo docker compose up -d
}

# Hauptprogramm
update_and_install_dependencies
add_docker_repo
ensure_paperless_user_and_group
install_docker
configure_samba
deploy_containers

# Lokale IP-Adresse ermitteln
LOCAL_IP=$(hostname -I | awk '{print $1}')

# Ausgabe in einer Dialog-Box
dialog --title "Paperless Installation abgeschlossen" --msgbox "\
**Zugriff im Browser:** http://$LOCAL_IP:8001

**Anmeldung Paperless WebGUI:** 
Benutzer: $ADMIN_USER
Passwort: $PAPERLESS_PASSWORD

Das System wird in 1 Minute neugestartet." 15 50

# System neustarten
sleep 60
sudo reboot
