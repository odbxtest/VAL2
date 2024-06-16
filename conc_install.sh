#!/usr/bin/bash

apt install sudo -y
apt-get update -y && apt-get upgrade -y
sudo apt install -y curl openssl jq screen iptables cron wget nano zip python3-pip
pip3 install requests

cat /usr/bin/badvpn-udpgw
if [[ $? != 0 ]];then
  wget -O /usr/bin/badvpn-udpgw "https://raw.githubusercontent.com/daybreakersx/premscript/master/badvpn-udpgw64"
  sudo touch /etc/rc.local
  echo -e '#!/bin/sh -e\nscreen -AmdS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7555 --max-clients 500\nexit 0' >> /etc/rc.local
  chmod +x /etc/rc.local
  sudo chmod +x /usr/bin/badvpn-udpgw
  sudo screen -AmdS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7555 --max-clients 500
  echo "- badvpn-udpgw installed"
  echo "YOU MAY NEED TO REBOOT SERVER"
else
  echo "+ badvpn-udpgw already exist"
fi

getINFO=$(curl -s 'https://raw.githubusercontent.com/odbxtest/VAL2/main/info.json')

concUrl=$(echo $getINFO | jq -r '.VAL2.url')

bashFilesPath=$(echo $getINFO | jq -r '.BASH.path')

ls $bashFilesPath
if [[ $? != 0 ]];then
  mkdir $bashFilesPath
  echo "+ Created dir [$bashFilesPath]"
fi

bashFiles=$(echo $getINFO | jq -r '.BASH.files[]')

for file in $bashFiles;do
  cat $bashFilesPath$file >> /dev/null 2>&1
  if [[ $? != 0 ]];then
    sudo curl -L -o $bashFilesPath$file $concUrl/bash/$file
    sudo chmod +x $bashFilesPath$file
    echo "+ Added file [$file] to $bashFilesPath"
  fi
done

sshPorts=$(echo $getINFO | jq -r '.SERVER.ssh_ports[]')

for port in $sshPorts;do
  sudo cat /etc/ssh/sshd_config | grep "Port $port" >> /dev/null 2>&1
  if [[ $? != 0 ]];then
    echo -e "\nPort $port" >> /etc/ssh/sshd_config
    echo "+ Added Port [$port] to sshd_config"
  fi
done

sudo systemctl restart sshd.service
sudo systemctl restart ssh

