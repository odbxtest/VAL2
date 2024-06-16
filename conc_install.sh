#!/usr/bin/bash

RED='\033[0;31m'
GR='\033[0;32m'
YE='\033[0;33m'
NC='\033[0m'

info() {
    echo -e "${GR}INFO${NC}: $1"
}

warn() {
    echo -e "${YE}WARNING${NC}: $1"
}

error() {
    echo -e "${RED}ERROR${NC}: $1" 1>&2
    exit 1
}



apt install sudo curl jq -y

read -p "update and upgrade? (y/n): " updateQues
if [[ "$updateQues" == "y" || "$updateQues" == "Y" ]]
then
  apt-get update -y && apt-get upgrade -y
fi

getINFO=$(curl -s 'https://raw.githubusercontent.com/odbxtest/VAL2/main/info.json')
concUrl=$(echo $getINFO | jq -r '.VAL2.url')

aptPacks=$(echo $getINFO | jq -r '.SERVER.apt[]')
for aptPack in $aptPacks;do
  sudo apt install -y $aptPack
done

pipPacks=$(echo $getINFO | jq -r '.SERVER.pip[]')
for pipPack in $pipPacks;do
  sudo pip3 install $pipPack
done


pip3 install requests

cat /usr/bin/badvpn-udpgw
if [[ $? != 0 ]];then
  wget -O /usr/bin/badvpn-udpgw "https://raw.githubusercontent.com/daybreakersx/premscript/master/badvpn-udpgw64"
  sudo touch /etc/rc.local
  echo -e '#!/bin/sh -e\nscreen -AmdS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7555 --max-clients 500\nexit 0' >> /etc/rc.local
  chmod +x /etc/rc.local
  sudo chmod +x /usr/bin/badvpn-udpgw
  sudo screen -AmdS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7555 --max-clients 500
  info "+ badvpn-udpgw installed"
  warn "YOU MAY NEED TO REBOOT SERVER"
else
  warn "\n- badvpn-udpgw already exist\n"
fi

bashFilesPath=$(echo $getINFO | jq -r '.BASH.path')

ls $bashFilesPath
if [[ $? != 0 ]];then
  mkdir $bashFilesPath
  info "\n+ Created dir [$bashFilesPath]\n"
fi

bashFiles=$(echo $getINFO | jq -r '.BASH.files[]')

for file in $bashFiles;do
  cat $bashFilesPath$file >> /dev/null 2>&1
  if [[ $? != 0 ]];then
    sudo curl -L -o $bashFilesPath$file $concUrl/bash/$file
    sudo chmod +x $bashFilesPath$file
    info "\n+ Added file [$file] to $bashFilesPath\n"
  fi
done

sshPorts=$(echo $getINFO | jq -r '.SERVER.ssh_ports[]')

for port in $sshPorts;do
  sudo cat /etc/ssh/sshd_config | grep "Port $port" >> /dev/null 2>&1
  if [[ $? != 0 ]];then
    echo -e "\nPort $port" >> /etc/ssh/sshd_config
    info "\n+ Added Port [$port] to sshd_config\n"
  fi
done

sudo systemctl restart sshd.service
sudo systemctl restart ssh

