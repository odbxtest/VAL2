#!/usr/bin/bash

read -p "update and upgrade? (y/n): " updateQues

apt install sudo curl jq -y

if [[ "$updateQues" == "y" || "$updateQues" == "Y" ]]
then
  apt-get update -y && apt-get upgrade -y
fi

getINFO=$(curl -s 'https://raw.githubusercontent.com/odbxtest/VAL2/main/conc_install.json')
concUrl=$(echo $getINFO | jq -r '.VAL2.url')

aptPacks=$(echo $getINFO | jq -r '.SERVER.apt[]')
aptCMD="sudo apt install -y"
for aptPack in $aptPacks;do
  aptCMD="${aptCMD} $aptPack"
done
echo "${aptCMD}"
$aptCMD

pipPacks=$(echo $getINFO | jq -r '.SERVER.pip[]')
pipCMD="pip3 install"
for pipPack in $pipPacks;do
  pipCMD="${pipCMD} $pipPack"
done
echo "${pipCMD}"
$pipCMD

cat /usr/bin/badvpn-udpgw >> /dev/null 2>&1
if [[ $? != 0 ]];then
  wget -O /usr/bin/badvpn-udpgw "https://raw.githubusercontent.com/daybreakersx/premscript/master/badvpn-udpgw64"
  sudo touch /etc/rc.local
  echo -e '#!/bin/sh -e\nscreen -AmdS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7555 --max-clients 500\nexit 0' >> /etc/rc.local
  chmod +x /etc/rc.local
  sudo chmod +x /usr/bin/badvpn-udpgw
  sudo screen -AmdS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7555 --max-clients 500
  echo "+ badvpn-udpgw installed"
  echo "YOU MAY NEED TO REBOOT SERVER"
else
  echo "\n- badvpn-udpgw already exist\n"
fi

bashFilesPath=$(echo $getINFO | jq -r '.BASH.path')

ls $bashFilesPath
if [[ $? != 0 ]];then
  mkdir $bashFilesPath
  echo "\n+ Created dir [$bashFilesPath]\n"
fi

bashFiles=$(echo $getINFO | jq -r '.BASH.files[]')

for file in $bashFiles;do
  cat $bashFilesPath$file >> /dev/null 2>&1
  if [[ $? != 0 ]];then
    sudo curl -L -o $bashFilesPath$file $concUrl/bash/$file
    sudo chmod +x $bashFilesPath$file
    echo "\n+ Added file [$file] to $bashFilesPath\n"
  fi
done

sshPorts=$(echo $getINFO | jq -r '.SERVER.ssh_ports[]')

for port in $sshPorts;do
  sudo cat /etc/ssh/sshd_config | grep "Port $port" >> /dev/null 2>&1
  if [[ $? != 0 ]];then
    echo -e "\nPort $port" >> /etc/ssh/sshd_config
    echo "\n+ Added Port [$port] to sshd_config\n"
  fi
done

sudo systemctl restart sshd.service
sudo systemctl restart ssh

