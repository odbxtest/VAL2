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

# Ensure required tools are installed
apt update && apt install -y sudo curl jq screen

# Configure IPV6
warn "Configuring IPV6"
if ! grep -q "disable_ipv6" /etc/sysctl.conf; then
  echo -e "net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf
  sudo sysctl -p
  info "* IPV6 Disabled"
fi

# Fetch configuration
getINFO=$(curl -s --connect-timeout 10 'https://raw.githubusercontent.com/odbxtest/VAL2/main/info.json') || error "Failed to fetch configuration"
concUrl=$(echo "$getINFO" | jq -r ".VAL2.url")

# Install apt packages
aptPacks=$(echo "$getINFO" | jq -r '.SERVER.apt[]')
if [ -n "$aptPacks" ]; then
  aptCMD="sudo apt install -y $aptPacks"
  warn "$aptCMD"
  $aptCMD || error "Failed to install apt packages"
fi

# Install pip packages
pipPacks=$(echo "$getINFO" | jq -r '.SERVER.pip[]')
if [ -n "$pipPacks" ]; then
  pipCMD="pip3 install $pipPacks"
  warn "$pipCMD"
  $pipCMD || error "Failed to install pip packages"
fi

# Ensure val2.sh exists
if [ ! -f /usr/bin/val2.sh ]; then
  sudo touch /usr/bin/val2.sh
  sudo chmod +x /usr/bin/val2.sh
fi

# Manage port process
concPort=$(echo "$getINFO" | jq -r ".SERVER.conc_port")
if [ -n "$(sudo lsof -t -i :"$concPort")" ]; then
  sudo kill -9 $(sudo lsof -t -i :"$concPort") && info "Killed process on port $concPort"
else
  info "No process found on port $concPort"
fi

# Setup val2 service
if [ ! -f /etc/systemd/system/val2.service ]; then
  echo -e "[Unit]\nDescription=VAL2-Service\n[Service]\nType=simple\nExecStart=/bin/bash /usr/bin/val2.sh\nRestart=always\nRestartSec=5\n[Install]\nWantedBy=multi-user.target" | sudo tee /etc/systemd/system/val2.service
  sudo systemctl daemon-reload
  sudo systemctl enable val2
fi

# Ensure rc.local exists
if [ ! -f /etc/rc.local ]; then
  echo -e '#!/bin/sh -e' | sudo tee /etc/rc.local
  sudo chmod +x /etc/rc.local
fi

# Install badvpn-udpgw
if [ ! -f /usr/bin/badvpn-udpgw ]; then
  sudo curl -L -o /usr/bin/badvpn-udpgw "https://raw.githubusercontent.com/daybreakersx/premscript/master/badvpn-udpgw64"
  sudo chmod +x /usr/bin/badvpn-udpgw
  if ! screen -list | grep -q "badvpn"; then
    sudo screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7555 --max-clients 500
  fi
  if ! grep -q "badvpn-udpgw" /etc/rc.local; then
    sed -i '/exit 0/d' /etc/rc.local
    echo -e '\nscreen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7555 --max-clients 500\nexit 0' | sudo tee -a /etc/rc.local
  fi
  info "+ badvpn-udpgw installed"
  warn "YOU MAY NEED TO REBOOT SERVER"
else
  if ! screen -list | grep -q "badvpn"; then
    sudo screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7555 --max-clients 500
    info "+ badvpn-udpgw restarted"
  fi
  warn "- badvpn-udpgw already exists"
fi

# Create directories
bashFilesPath=$(echo "$getINFO" | jq -r '.BASH.path')
if [ ! -d "$bashFilesPath" ]; then
  sudo mkdir -p "$bashFilesPath"
  sudo chmod 755 "$bashFilesPath"
  info "+ Created dir [$bashFilesPath]"
fi

concFilesPath=$(echo "$getINFO" | jq -r '.CONC.path')
if [ ! -d "$concFilesPath" ]; then
  sudo mkdir -p "$concFilesPath"
  sudo chmod 755 "$concFilesPath"
  info "+ Created dir [$concFilesPath]"
fi

# Configure SSH ports
sshPorts=$(echo "$getINFO" | jq -r '.SERVER.ssh_ports[]')
for port in $sshPorts; do
  if ! grep -q "^Port $port" /etc/ssh/sshd_config; then
    echo "Port $port" | sudo tee -a /etc/ssh/sshd_config
    info "+ Added Port [$port] to sshd_config"
  fi
done
sudo systemctl restart sshd || error "Failed to restart SSH service"

# Download bash files
bashFiles=$(echo "$getINFO" | jq -r '.BASH.files[]')
for bashFile in $bashFiles; do
  if [ ! -f "$bashFilesPath$bashFile" ]; then
    sudo curl -L -o "$bashFilesPath$bashFile" "$concUrl/bash/$bashFile"
    sudo chmod +x "$bashFilesPath$bashFile"
    sudo sed -i -e 's/\r$//' "$bashFilesPath$bashFile"
    info "+ Added bash file [$bashFile] to $bashFilesPath"
  fi
done

# Download conc files
concFiles=$(echo "$getINFO" | jq -r '.CONC.files[]')
for concFile in $concFiles; do
  if [ ! -f "$concFilesPath$concFile" ]; then
    sudo curl -L -o "$concFilesPath$concFile" "$concUrl/conc/$concFile.txt"
    sudo chmod +x "$concFilesPath$concFile"
    info "+ Added conc file [$concFile] to $concFilesPath"
  fi
done

# Update val2.sh with screen commands
concFilesToScreen=$(echo "$getINFO" | jq -r '.CONC.screen[]')
for screenFile in $concFilesToScreen; do
  if ! grep -q "python3 ${concFilesPath}${screenFile}" /usr/bin/val2.sh; then
    echo "python3 ${concFilesPath}${screenFile}" | sudo tee -a /usr/bin/val2.sh
    info "+ Added ${screenFile} in /usr/bin/val2.sh"
  fi
done

# Monitor and restart val2 service
sudo systemctl restart val2 || error "Failed to restart val2 service"
sleep 5
if ! systemctl is-active --quiet val2; then
  sudo systemctl start val2
  info "+ Restarted val2 service"
fi

AUTH_LINE="auth required pam_exec.so ${concFilesPath}app.py"
SESSION_LINE="session optional pam_exec.so ${concFilesPath}app.py"

# Add auth line if not already present
if ! grep -Fxq "$AUTH_LINE" "/etc/pam.d/sshd"; then
    sudo sed -i "/@include common-auth/i $AUTH_LINE" "/etc/pam.d/sshd"
    echo "Added auth line."
else
    echo "Auth line already present."
fi

# Add session line if not already present
if ! grep -Fxq "$SESSION_LINE" "/etc/pam.d/sshd"; then
    echo "$SESSION_LINE" | sudo tee -a "/etc/pam.d/sshd" > /dev/null
    echo "Added session line."
else
    echo "Session line already present."
fi

# Display server IP
hostname -I

exit 0
