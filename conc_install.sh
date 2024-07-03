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

apt install sudo curl jq -y

warn "configure IPV6"
cat /etc/sysctl.conf | grep "disable_ipv6"
if [[ $? != 0 ]];then
  echo -e "net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
  sudo sysctl -p
  info "* IPV6 Disabled"
fi

getINFO=$(curl -s 'https://raw.githubusercontent.com/odbxtest/VAL2/main/info.json')
concUrl=$(echo $getINFO | jq -r ".VAL2.url")

aptPacks=$(echo $getINFO | jq -r '.SERVER.apt[]')
aptCMD="sudo apt install -y"
for aptPack in $aptPacks;do
  aptCMD="${aptCMD} $aptPack"
done
warn "${aptCMD}"
$aptCMD

pipPacks=$(echo $getINFO | jq -r '.SERVER.pip[]')
pipCMD="pip3 install"
for pipPack in $pipPacks;do
  pipCMD="${pipCMD} $pipPack"
done
warn "${pipCMD}"
$pipCMD

cat /usr/bin/val2.sh >> /dev/null 2>&1
if [[ $? != 0 ]];then
  sudo touch /usr/bin/val2.sh
fi

cat /etc/systemd/system/val2.service >> /dev/null 2>&1
if [[ $? != 0 ]];then
  echo -e "[Unit]\nDescription=VAL2-Service\n[Service]\nType=simple\nExecStart=/bin/bash /usr/bin/val2.sh\nRestart=always\n[Install]\nWantedBy=multi-user.target" >> /etc/systemd/system/val2.service
  systemctl enable val2 && systemctl start val2 && sleep 1 && systemctl restart val2
fi

cat /etc/rc.local >> /dev/null 2>&1
if [[ $? != 0 ]];then
  sudo touch /etc/rc.local
  echo -e '#!/bin/sh -e' >> /etc/rc.local
  chmod +x /etc/rc.local
fi

cat /usr/bin/badvpn-udpgw >> /dev/null 2>&1
if [[ $? != 0 ]];then
  wget -O /usr/bin/badvpn-udpgw "https://raw.githubusercontent.com/daybreakersx/premscript/master/badvpn-udpgw64"
  sudo chmod +x /usr/bin/badvpn-udpgw
  sudo screen -AmdS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7555 --max-clients 500
  sed -i '/exit 0/d' /etc/rc.local
  echo -e '\nscreen -AmdS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7555 --max-clients 500\nexit 0' >> /etc/rc.local
  info "+ badvpn-udpgw installed"
  warn "YOU MAY NEED TO REBOOT SERVER"
else
  warn "- badvpn-udpgw already exist"
fi

bashFilesPath=$(echo $getINFO | jq -r '.BASH.path')

ls $bashFilesPath >> /dev/null 2>&1
if [[ $? != 0 ]];then
  mkdir $bashFilesPath
  info "+ Created dir [$bashFilesPath]"
  sudo chmod 755 $bashFilesPath
fi

concFilesPath=$(echo $getINFO | jq -r '.CONC.path')

ls $concFilesPath >> /dev/null 2>&1
if [[ $? != 0 ]];then
  mkdir $concFilesPath
  info "+ Created dir [$concFilesPath]"
  sudo chmod 755 $concFilesPath
fi


sshPorts=$(echo $getINFO | jq -r '.SERVER.ssh_ports[]')

for port in $sshPorts;do
  sudo cat /etc/ssh/sshd_config | grep "Port $port" | grep -v "#"
  if [[ $? != 0 ]];then
    echo -e "\nPort $port" >> /etc/ssh/sshd_config
    info "+ Added Port [$port] to sshd_config"
  fi
done

sudo systemctl restart sshd.service
sudo systemctl restart ssh

bashFiles=$(echo $getINFO | jq -r '.BASH.files[]')

for bashFile in $bashFiles;do
  cat $bashFilesPath$bashFile >> /dev/null 2>&1
  if [[ $? != 0 ]];then
    sudo curl -L -o $bashFilesPath$bashFile $concUrl/bash/$bashFile
    sudo chmod +x $bashFilesPath$bashFile
    sed -i -e 's/\r$//' $bashFilesPath$bashFile
    info "+ Added bash file [$bashFile] to $bashFilesPath"
  fi
done


concFiles=$(echo $getINFO | jq -r '.CONC.files[]')
concFilesPath=$(echo $getINFO | jq -r '.CONC.path')

for concFile in $concFiles;do
  cat $concFilesPath$concFile >> /dev/null 2>&1
  if [[ $? != 0 ]];then
    sudo curl -L -o $concFilesPath$concFile $concUrl/conc/$concFile
    sudo chmod +x $concFilesPath$concFile
    info "+ Added conc file [$concFile] to $concFilesPath"
  fi
done

concFilesToScreen=$(echo $getINFO | jq -r '.CONC.screen[]')

for screenFile in $concFilesToScreen;do
  cat /usr/bin/val2.sh | grep "${screenFile}"
  if [[ $? != 0 ]];then
    echo -e "\npython3 ${concFilesPath}${screenFile}" >> /usr/bin/val2.sh
    info "+ Added ${screenFile} in /usr/bin/val2.sh"
  fi
done

sleep 3
sudo systemctl restart val2

hostname -I

exit 0

