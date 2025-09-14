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

apt-get update -y &&  apt-get upgrade -y && apt-get install -y sudo curl jq

warn "Configuring IPV6"
if ! grep -q "disable_ipv6" /etc/sysctl.conf; then
  echo -e "net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1" | sudo tee -a /etc/sysctl.conf
  sudo sysctl -p
  info "* IPV6 Disabled"
fi

getINFO=$(curl -s --connect-timeout 10 'https://raw.githubusercontent.com/odbxtest/VAL2/main/info_v2.json') || error "Failed to fetch configuration"
concPath=$(echo "$getINFO" | jq -r '.path')
concUrl=$(echo "$getINFO" | jq -r '.url')
concPort=$(echo "$getINFO" | jq -r ".conc_port")

aptPacks=$(echo "$getINFO" | jq -r '."apt"[]' 2>/dev/null) || error "Failed to parse apt packages from JSON"
if [ -n "$aptPacks" ]; then
  aptCMD="sudo apt-get install -y $aptPacks"
  warn "$aptCMD"
  $aptCMD || error "Failed to install apt packages"
fi

pipPacks=$(echo "$getINFO" | jq -r '.pip[]' 2>/dev/null) || error "Failed to parse pip packages from JSON"
if [ -n "$pipPacks" ]; then
  pipCMD="pip3 install $pipPacks"
  warn "$pipCMD"
  $pipCMD || error "Failed to install pip packages"
fi

if [ -n "$(sudo lsof -t -i :"$concPort")" ]; then
  sudo kill -9 $(sudo lsof -t -i :"$concPort") && info "Killed process on port $concPort"
else
  info "No process found on port $concPort"
fi

sudo ufw allow $concPort
sudo ufw allow 7300
sudo ufw allow 7555

sshPorts=$(echo "$getINFO" | jq -r '.ssh_ports[]')
for port in $sshPorts; do
  ufw allow $port
  if ! grep -q "^Port $port" /etc/ssh/sshd_config; then
    echo "Port $port" | sudo tee -a /etc/ssh/sshd_config
    info "+ Added Port [$port] to sshd_config"
  fi
done
sudo systemctl restart sshd || error "Failed to restart SSH service"

if [ ! -f /usr/bin/badvpn-udpgw ]; then
    curl -L -o /usr/bin/badvpn-udpgw "https://raw.githubusercontent.com/daybreakersx/premscript/master/badvpn-udpgw64" || { echo "Failed to download badvpn-udpgw"; }
    chmod +x /usr/bin/badvpn-udpgw || { echo "Failed to set executable permissions"; }
    info "+ badvpn-udpgw installed"
else
    warn "- badvpn-udpgw already exists"
fi

CRON_JOB="@reboot screen -dmS badvpn7300 badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500"
(crontab -l 2>/dev/null | grep -v -F "$CRON_JOB"; echo "$CRON_JOB") | crontab -
CRON_JOB="@reboot screen -dmS badvpn7555 badvpn-udpgw --listen-addr 127.0.0.1:7555 --max-clients 500"
(crontab -l 2>/dev/null | grep -v -F "$CRON_JOB"; echo "$CRON_JOB") | crontab -

if [ ! -d "$concPath" ]; then
  sudo mkdir -p "$concPath"
  sudo chmod 755 "$concPath"
  info "+ Created dir [$concPath]"
fi

cd $concPath
if [ ! -f app.py ]; then
  rm -rf "$concPath"/*
  wget $concUrl/files/VAL2CONC.zip
  unzip VAL2CONC.zip
  find . -type f -name "*.py" -exec sed -i -e 's/\r$//' {} \;
  for file in $concPath/systemd/*; do
    if [ ! -f /etc/systemd/system/$(basename $file) ]; then
      cp $file /etc/systemd/system/
    fi
  done
  chmod +x $concPath/app.py
  chmod +x $concPath/trraficCalculator.py
  sudo systemctl daemon-reload
  for service in $concPath/systemd/*.service; do
    sudo systemctl enable $(basename $service)
    sudo systemctl start $(basename $service)
  done
fi

warn "REBOOT SERVER NOW"

# AUTH_LINE="auth required pam_exec.so ${concPath}/app.py"
# if ! grep -Fxq "$AUTH_LINE" "/etc/pam.d/sshd"; then
#     sudo sed -i "/@include common-auth/i $AUTH_LINE" "/etc/pam.d/sshd"
#     echo "Added auth line."
# else
#     echo "Auth line already present."
# fi

hostname -I

echo "\n"
info "Press Enter to reboot, or any other key to cancel."
read -s -n1 key

if [[ "$key" == "" ]]; then
    info "Rebooting..."
    sudo reboot
else
    info "Cancelled."
fi

exit 0
