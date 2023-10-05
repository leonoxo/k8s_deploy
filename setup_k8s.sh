#!/bin/bash

# 使用者輸入的變數
read -p "請輸入主機名稱: " HOSTNAME
read -p "請輸入IP地址: " IP
read -p "請輸入子網掩碼 (CIDR格式, 例如 24): " SUBNETMASK_CIDR
read -p "請輸入預設閘道: " GATEWAY
read -p "請輸入nameserver: " NAMESERVER

# 設定主機名稱
hostnamectl set-hostname $HOSTNAME

# 更新 /etc/hosts 以便節點可以互相解析
echo "$IP $HOSTNAME" >> /etc/hosts

# 自動檢測第一張可用網卡
NETCARD=$(ls /sys/class/net | grep -v lo | head -n 1)

# 使用檢測到的網卡生成 netplan 配置
cat > /etc/netplan/99-netcfg.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $NETCARD:
      dhcp4: no
      addresses: [$IP/$SUBNETMASK_CIDR]
      gateway4: $GATEWAY
      nameservers:
        addresses: [$NAMESERVER]
EOF

sudo netplan apply

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
sudo apt update && sudo apt install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates

# 添加docker repo
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/docker.gpg
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

# 安装containerd
sudo apt update && sudo apt install -y containerd.io

# 配置containerd使用systemd作为cgroup
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1
sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# 添加apt repo
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
sudo apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"

# 安装Kubectl, kubeadm & kubelet
sudo apt update && sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# 初始化Master节点
sudo kubeadm init --control-plane-endpoint="$IP"
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 查看集群資訊
kubectl cluster-info
kubectl get nodes
