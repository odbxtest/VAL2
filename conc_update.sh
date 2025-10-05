#!/bin/bash

RED='\033[0;31m'
GR='\033[0;32m'
YE='\033[0;33m'
NC='\033[0m'

info() {
    echo -e "${GR}$1${NC}"
}

warn() {
    echo -e "${YE}$1${NC}"
}

error() {
    echo -e "${RED}$1${NC}" 1>&2
    exit 1
}

set -euo pipefail
set -e
trap 'warn' ERR

cd /root/

apt_wait() {
  echo "Checking dpkg/apt locks"
  for i in $(seq 1 120); do
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
       || pgrep -x apt >/dev/null \
       || pgrep -x apt-get >/dev/null \
       || pgrep -x dpkg >/dev/null \
       || pgrep -x unattended-upgrade >/dev/null; then
      warn "[$i/120] lock/process active; waiting 5s..."
      sleep 5
    else
      echo "Lock is free. Proceed."
      return 0
    fi
  done
  return 1
}

apt_wait
sudo DEBIAN_FRONTEND=noninteractive apt-get -y -q update

apt_wait
sudo DEBIAN_FRONTEND=noninteractive \
    apt-get -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    upgrade

apt_wait
sudo DEBIAN_FRONTEND=noninteractive \
    apt-get -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install sudo curl ufw jq

warn "Configuring IPV6"
if ! grep -q "disable_ipv6" /etc/sysctl.conf; then
  echo -e "net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf
  sudo sysctl -p
  info "* IPV6 Disabled"
fi

getConfiguration=$(curl -s --connect-timeout 10 'https://raw.githubusercontent.com/odbxtest/VAL2/main/conc_info.json') || error "Failed to fetch configuration"
conc_url=$(echo "$getConfiguration" | jq -r '.url')
conc_port=$(echo "$getConfiguration" | jq -r '.conc_port')
awe_port=$(echo "$getConfiguration" | jq -r '.awe_port')
wg_port=$(echo "$getConfiguration" | jq -r '.wg_port')
ssh_ports=$(echo "$getConfiguration" | jq -r '."ssh_ports"[]' 2>/dev/null)
trafficCalculator=$(echo "$getConfiguration" | jq -c '.trafficCalculator')
onlineCheck=$(echo "$getConfiguration" | jq -c '.onlineCheck')
conc_path=$(echo "$getConfiguration" | jq -r '.path')
apt=$(echo "$getConfiguration" | jq -r '."apt"[]' 2>/dev/null)
pip=$(echo "$getConfiguration" | jq -r '."pip"[]' 2>/dev/null)

if [[ -d "$conc_path" && "$conc_path" == /root/* ]]; then
    echo "OK - $conc_path"
else
    error "Error: Invalid or unsafe path '$conc_path'."
fi

apt_wait
if [ -n "$apt" ]; then
  sudo DEBIAN_FRONTEND=noninteractive \
    apt-get -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install $apt || error "Failed to install apt packages"
fi

apt_wait
if [ -n "$pip" ]; then
  pipCMD="pip3 install $pip"
  warn "$pipCMD"
  $pipCMD || error "Failed to install pip packages"
fi

if [ -n "$(sudo lsof -t -i :"$conc_port")" ]; then
  sudo kill -9 $(sudo lsof -t -i :"$conc_port") && info "Killed process on port $conc_port"
else
  info "No process found on port $conc_port"
fi

for port in $ssh_ports; do
  sudo ufw allow $port
  if ! grep -q "^Port $port" /etc/ssh/sshd_config; then
    echo "Port $port" | sudo tee -a /etc/ssh/sshd_config
    info "+ Added Port [$port] to sshd_config"
  fi
done
sudo systemctl restart sshd || error "Failed to restart SSH service"

sudo ufw allow $conc_port
sudo ufw allow $awe_port
sudo ufw allow $wg_port
sudo ufw allow 7300
sudo ufw allow 7555
sudo ufw --force enable
sudo ufw reload

if [ ! -f /usr/bin/badvpn-udpgw ]; then
    curl -L -o /usr/bin/badvpn-udpgw "https://raw.githubusercontent.com/daybreakersx/premscript/master/badvpn-udpgw64" || { echo "Failed to download badvpn-udpgw"; }
    chmod +x /usr/bin/badvpn-udpgw || { echo "Failed to set executable permissions"; }
    info "+ badvpn-udpgw installed"
else
    warn "- badvpn-udpgw already exists"
fi

scSESSION="badvpn7300"
scCMD="badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500"
if screen -list | grep -q "[.]$scSESSION"; then
    echo "Screen session '$scSESSION' already running."
else
    echo "Starting screen session '$scSESSION'..."
    screen -dmS "$scSESSION" $scCMD
fi

scSESSION="badvpn7555"
scCMD="badvpn-udpgw --listen-addr 127.0.0.1:7555 --max-clients 500"
if screen -list | grep -q "[.]$scSESSION"; then
    echo "Screen session '$scSESSION' already running."
else
    echo "Starting screen session '$scSESSION'..."
    screen -dmS "$scSESSION" $scCMD
fi

CRON_JOB="@reboot screen -dmS badvpn7300 badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500"
(crontab -l 2>/dev/null | grep -v -F "$CRON_JOB"; echo "$CRON_JOB") | crontab -
CRON_JOB="@reboot screen -dmS badvpn7555 badvpn-udpgw --listen-addr 127.0.0.1:7555 --max-clients 500"
(crontab -l 2>/dev/null | grep -v -F "$CRON_JOB"; echo "$CRON_JOB") | crontab -

# -----------------------
for s in val2 concApp concTrraficCalculator; do
    systemctl stop "$s.service"
    systemctl disable "$s.service"
    rm -f "/etc/systemd/system/$s.service"
done

rm /usr/bin/val2.sh
rm -r /root/val2
rm -r $conc_path
# -----------------------

apt_wait
if [ -n "$(sudo lsof -t -i :"$conc_port")" ]; then
  sudo kill -9 $(sudo lsof -t -i :"$conc_port") && info "Killed process on port $conc_port"
else
  info "No process found on port $conc_port"
fi

if [ ! -d "$conc_path" ]; then
  sudo mkdir -p "$conc_path"
  sudo chmod 755 "$conc_path"
  info "+ Created dir [$conc_path]"
fi

if [ ! -f /usr/local/bin/valdoguard ]; then
  wget https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
  unzip Xray-linux-64.zip -d /tmp/xray
  install -m 755 /tmp/xray/xray /usr/local/bin/valdoguard
  rm -rf /tmp/xray Xray-linux-64.zip
fi

# if ! command -v nethogs >/dev/null 2>&1; then
#     SRC_PATH="/usr/local/src/nethogs"
#     sudo apt-get install -y libncurses5-dev libpcap-dev
#     sudo mkdir -p "$SRC_PATH"
#     sudo wget -O "$SRC_PATH/nethogs.zip" "https://raw.githubusercontent.com/odbxtest/VAL2/main/trrf.zip"
#     cd "$SRC_PATH"
#     sudo unzip nethogs.zip
#     sudo make install && hash -r
# fi

cd $conc_path
if [ ! -f app.py ]; then
  rm -rf "$conc_path"/*

  mkdir $conc_path/valdoguard
  wget -O $conc_path/valdoguard/valdoguard.json https://raw.githubusercontent.com/odbxtest/VAL2/main/valdoguard.json
  chmod 644 $conc_path/valdoguard/valdoguard.json
  mkdir -p $conc_path/valdoguard/configs
  chmod 755 $conc_path/valdoguard/configs
  chown root:root $conc_path/valdoguard/valdoguard.json
  chmod 644 $conc_path/valdoguard/valdoguard.json
  
  wget "$conc_url/files/VAL2CONC.zip" || error "Failed to download VAL2CONC.zip"
  unzip VAL2CONC.zip
  find . -type f -name "*.py" -exec sed -i -e 's/\r$//' {} \;
for file in "$conc_path"/systemd/*; do
    # Just for debug
    service_name=$(basename "$file")
    echo "Stopping and disabling: $service_name"
    sudo systemctl stop "$service_name".service >> /dev/null 2>&1
    sudo systemctl disable "$service_name".service >> /dev/null 2>&1
    sudo rm "/etc/systemd/system/$service_name.service" >> /dev/null 2>&1
    # ----------- #
    if [ ! -f /etc/systemd/system/$(basename $file) ]; then
      cp $file /etc/systemd/system/
    fi
  done
  chmod +x $conc_path/app.py
  chmod +x $conc_path/*.sh
  
  sudo systemctl daemon-reload
fi


services=("valdoguard" "concApp")
for service in "${services[@]}"; do
    echo "🔧 Managing service: $service"

    sudo systemctl enable "$service"

    if systemctl is-active --quiet "$service"; then
        echo "↻ Restarting $service (already running)"
        sudo systemctl restart "$service"
    else
        echo "▶️ Starting $service"
        sudo systemctl start "$service"
    fi
done

CRON_JOB="0 * * * * /usr/bin/systemctl restart concApp >/dev/null 2>&1"
(crontab -l 2>/dev/null | grep -v -F "$CRON_JOB"; echo "$CRON_JOB") | crontab -

# === CONFIGURATION === #
PY_SCRIPT="/root/VAL2CONC/sshOnline.py"
PY_ARGS=()  # optional arguments if needed later

# === CHECKS === #
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi

if [[ ! -f "$PY_SCRIPT" ]]; then
  echo "Python gate script not found at: $PY_SCRIPT" >&2
  exit 1
fi

chmod 700 "$(dirname "$PY_SCRIPT")" || true
chmod 700 "$PY_SCRIPT"

PAM_FILES=(
  "/etc/pam.d/sshd"
  "/etc/pam.d/login"
)

PAM_LINE="account required pam_exec.so quiet /usr/bin/python3 $PY_SCRIPT ${PY_ARGS[*]}"
timestamp="$(date +%Y%m%d-%H%M%S)"

# === APPLY ONLY IF NOT ALREADY PRESENT === #
for f in "${PAM_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    # Check if already configured
    if grep -Fq "$PAM_LINE" "$f"; then
      echo "Already configured in $f"
      continue
    fi

    # Backup before modification
    cp -a "$f" "$f.bak-$timestamp"

    # Insert our PAM line safely
    if grep -Eq '^[[:space:]]*account[[:space:]]+' "$f"; then
      awk -v pamline="$PAM_LINE" '
        { print }
        END { print pamline }
      ' "$f" > "$f.new"
      mv "$f.new" "$f"
    else
      echo "$PAM_LINE" >> "$f"
    fi

    echo "Configured: $f"
  else
    echo "Skipping missing PAM file: $f"
  fi
done

info "PAM will call your Python script ($PY_SCRIPT) to allow/deny logins."

hostname -I
echo ""

# warn "do a reboot? "
# read -s -n1 key

# if [[ "$key" == "" ]]; then
#     info "Rebooting..."
#     sudo reboot
# else
#     info "Cancelled."
# fi
trap - ERR

exit 0
