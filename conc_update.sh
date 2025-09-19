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
    install sudo curl jq

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

apt_wait
aptPacks=$(echo "$getINFO" | jq -r '."apt"[]' 2>/dev/null) || error "Failed to parse apt packages from JSON"
if [ -n "$aptPacks" ]; then
  sudo DEBIAN_FRONTEND=noninteractive \
    apt-get -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install $aptPacks || error "Failed to install apt packages"
fi

apt_wait
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
systemctl stop val2.service
systemctl stop concApp.service
systemctl stop concTrafficCalculator.service
systemctl disable val2.service
systemctl disable concApp.service
systemctl disable concTrafficCalculator.service
rm /etc/systemd/system/val2.service
rm /etc/systemd/system/concApp.service
rm /etc/systemd/system/concTrafficCalculator.service
rm /usr/bin/val2.sh
rm -r /root/val2
# rm $concPath/$concDBfile
concDBfile=$(echo "$getINFO" | jq -r ".database")
if [ -f $concPath/$concDBfile ]; then
  warn "Saving database file."
  mv $concPath/$concDBfile /root/$concDBfile
fi
rm -r $concPath
# -----------------------

apt_wait
ufw disable
if [ -n "$(sudo lsof -t -i :"$concPort")" ]; then
  sudo kill -9 $(sudo lsof -t -i :"$concPort") && info "Killed process on port $concPort"
else
  info "No process found on port $concPort"
fi

if [ ! -d "$concPath" ]; then
  sudo mkdir -p "$concPath"
  sudo chmod 755 "$concPath"
  info "+ Created dir [$concPath]"
fi

cd $concPath
if [ ! -f app.py ]; then
  rm -rf "$concPath"/*

  wget https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
  unzip Xray-linux-64.zip -d /tmp/xray
  install -m 755 /tmp/xray/xray /usr/local/bin/valdoguard
  rm -rf /tmp/xray Xray-linux-64.zip
  
  mkdir $concPath/valdoguard
  touch $concPath/valdoguard/valdoguard.json
  chmod 644 $concPath/valdoguard/valdoguard.json
  mkdir -p $concPath/valdoguard/configs
  chmod 755 $concPath/valdoguard/configs
  chown root:root $concPath/valdoguard/valdoguard.json
  chmod 644 $concPath/valdoguard/valdoguard.json
  
  wget $concUrl/files/VAL2CONC.zip
  unzip VAL2CONC.zip
  find . -type f -name "*.py" -exec sed -i -e 's/\r$//' {} \;
  if [ -f /root/$concDBfile ]; then
    warn "Restoring database file."
    rm $concPath/$concDBfile
    mv /root/$concDBfile $concPath/$concDBfile
  fi
  for file in $concPath/systemd/*; do
    if [ ! -f /etc/systemd/system/$(basename $file) ]; then
      cp $file /etc/systemd/system/
    fi
  done
  chmod +x $concPath/app.py
  chmod +x $concPath/trafficCalculator.py
  chmod +x $concPath/sessionCalculator.py
  sudo systemctl daemon-reload
  for service in $concPath/systemd/*.service; do
    sudo systemctl enable $(basename $service)
    sudo systemctl start $(basename $service)
  done
fi

for service in $concPath/systemd/*.service; do
  sudo systemctl restart $(basename $service)
done

# AUTH_LINE="auth required pam_exec.so ${concPath}/app.py"
# if ! grep -Fxq "$AUTH_LINE" "/etc/pam.d/sshd"; then
#     sudo sed -i "/@include common-auth/i $AUTH_LINE" "/etc/pam.d/sshd"
#     echo "Added auth line."
# else
#     echo "Auth line already present."
# fi

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

exit 0
