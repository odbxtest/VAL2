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

apt update && apt install -y sudo curl jq screen

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

aptPacks=$(echo "$getINFO" | jq -r '.apt-get[]')
if [ -n "$aptPacks" ]; then
  aptCMD="sudo apt-get install -y $aptPacks"
  warn "$aptCMD"
  $aptCMD || error "Failed to install apt packages"
fi

pipPacks=$(echo "$getINFO" | jq -r '.pip[]')
if [ -n "$pipPacks" ]; then
  pipCMD="pip3 install $pipPacks"
  warn "$pipCMD"
  $pipCMD || error "Failed to install pip packages"
fi

if [ ! -f /usr/bin/val2.sh ]; then
  sudo touch /usr/bin/val2.sh
  sudo chmod +x /usr/bin/val2.sh
fi

if [ -n "$(sudo lsof -t -i :"$concPort")" ]; then
  sudo kill -9 $(sudo lsof -t -i :"$concPort") && info "Killed process on port $concPort"
else
  info "No process found on port $concPort"
fi

if [ ! -f /etc/systemd/system/val2.service ]; then
  echo -e "[Unit]\nDescription=VAL2-Service\n[Service]\nType=simple\nExecStart=/bin/bash /usr/bin/val2.sh\nRestart=always\nRestartSec=5\n[Install]\nWantedBy=multi-user.target" | sudo tee /etc/systemd/system/val2.service
  sudo systemctl daemon-reload
  sudo systemctl enable val2
fi

if [ ! -f /etc/rc.local ]; then
  echo -e '#!/bin/sh -e' | sudo tee /etc/rc.local
  sudo chmod +x /etc/rc.local
fi

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

if [ ! -d "$concPath" ]; then
  sudo mkdir -p "$concPath"
  sudo chmod 755 "$concPath"
  info "+ Created dir [$concPath]"
fi

sshPorts=$(echo "$getINFO" | jq -r '.ssh_ports[]')
for port in $sshPorts; do
  if ! grep -q "^Port $port" /etc/ssh/sshd_config; then
    echo "Port $port" | sudo tee -a /etc/ssh/sshd_config
    info "+ Added Port [$port] to sshd_config"
  fi
done
sudo systemctl restart sshd || error "Failed to restart SSH service"

sleep 5

if ! systemctl is-active --quiet val2; then
  sudo systemctl start val2
  info "+ Restarted val2 service"
fi

AUTH_LINE="auth required pam_exec.so ${concPath}app.py check_login"
if ! grep -Fxq "$AUTH_LINE" "/etc/pam.d/sshd"; then
    sudo sed -i "/@include common-auth/i $AUTH_LINE" "/etc/pam.d/sshd"
    echo "Added auth line."
else
    echo "Auth line already present."
fi

installNethogs=true
if command -v nethogs &> /dev/null
then
    VERSION=$(nethogs -V)

    if [[ $VERSION == *"8.7"* ]]
    then
        installNethogs=false
    else
        sudo apt-get remove nethogs -y && sudo apt-get autoremove -y && sudo apt-get purge nethogs -y
    fi
fi

if [[ $installNethogs == true ]]
then
    sudo apt-get install libncurses5-dev libpcap-dev -y
    mkdir $concPath/nethogs
    sudo wget -O $concPath/nethogs/nethogs.zip $concUrl/files/nethogs.zip
    unzip $concPath/nethogs/nethogs.zip
    chmod 744 $concPath/nethogs/determineVersion.sh
    cd $concPath/nethogs/ && ./configure && make && sudo make install
fi

hostname -I

exit 0
