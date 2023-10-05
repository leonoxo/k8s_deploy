#!/bin/bash

# 檢測用於默認路由的界面名稱
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')

# 檢測當前使用的netplan設定檔名稱
NETPLAN_FILE=$(ls /etc/netplan/ | head -n 1)

# 獲取當前主機名稱、IP地址、子網掩碼、閘道和nameserver
CURRENT_HOSTNAME=$(hostname)
CURRENT_IP=$(hostname -I | awk '{print $1}')
CURRENT_SUBNETMASK_CIDR=$(ip -o -f inet addr show | grep $CURRENT_IP | awk '{split($4,a,"/"); print a[2]}')
CURRENT_GATEWAY=$(ip route | grep default | awk '{print $3}')
CURRENT_NAMESERVER=$(awk '/nameserver/ {print $2}' /etc/resolv.conf | head -n 1)

# 使用者輸入，並提供當前值作為預設值
read -p "請輸入主機名稱 (當前值: $CURRENT_HOSTNAME): " HOSTNAME
read -p "請輸入IP地址 (當前值: $CURRENT_IP): " IP
read -p "請輸入子網掩碼 (CIDR格式, 例如 24) (當前值: $CURRENT_SUBNETMASK_CIDR): " SUBNETMASK_CIDR
read -p "請輸入預設閘道 (當前值: $CURRENT_GATEWAY): " GATEWAY
read -p "請輸入nameserver (當前值: $CURRENT_NAMESERVER): " NAMESERVER

# 如果使用者未輸入新值，則使用當前值
HOSTNAME=${HOSTNAME:-$CURRENT_HOSTNAME}
hostnamectl set-hostname $HOSTNAME
IP=${IP:-$CURRENT_IP}
SUBNETMASK_CIDR=${SUBNETMASK_CIDR:-$CURRENT_SUBNETMASK_CIDR}
GATEWAY=${GATEWAY:-$CURRENT_GATEWAY}
NAMESERVER=${NAMESERVER:-$CURRENT_NAMESERVER}

# 使用檢測到的設定檔名稱進行更新
cat > /etc/netplan/$NETPLAN_FILE <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: no
      addresses: [$IP/$SUBNETMASK_CIDR]
      routes:
      - to: 0.0.0.0/0
        via: $GATEWAY
      nameservers:
        addresses: [$NAMESERVER]
EOF

sudo netplan apply

# 更新 /etc/hosts 以便節點可以互相解析
echo "$IP $HOSTNAME" >> /etc/hosts

# 禁用 swap
sudo swapoff -a
sudo sed -i '/ swap / s/^(.*)$/#1/g' /etc/fstab

# 修改內核參數
sudo tee /etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system

# 安装dependencies
sudo apt update -y && sudo apt install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates

# 添加docker repo
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/docker.gpg
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

# 安装containerd
sudo apt update -y && sudo apt install -y containerd.io

# 配置containerd使用systemd作为cgroup
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1
sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# 添加apt repo
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
sudo apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"

# 安装Kubectl, kubeadm & kubelet
sudo apt update -y && sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# 初始化Master节点
sudo kubeadm init --control-plane-endpoint="$IP"
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 查看集群資訊
kubectl cluster-info
kubectl get nodes
