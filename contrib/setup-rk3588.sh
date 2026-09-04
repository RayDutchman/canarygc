#!/bin/bash

# setup-rk3588.sh — CanaryGC 部署脚本（RK3588 / Armbian / Rockchip）
#
# 原项目 contrib/setup.sh 面向 Raspberry Pi（/boot/firmware/config.txt、
# dtoverlay=uartx、rpiCamera、libcamera-hello、ModemManager 4G 等）。
# 本脚本是它在 RK3588 (Armbian, aarch64, vendor 6.1 内核) 上的对应版本：
# 保留相同的主流程（Docker 安装、防火墙、Docker 组、IP 转发、compose 启动），
# 但去掉树莓派特化逻辑，改为 Rockchip/Armbian 的路径与设备约定。
#
# 用法（与原 setup.sh 一致）：
#   # 完整安装（Docker、防火墙、串口权限）+ 生产模式启动
#   bash -s -- < setup-rk3588.sh
#   # 仅启动应用（假设 Docker 已装好）
#   bash -s -- --install-only < setup-rk3588.sh
#   # 本地 SITL 仿真测试
#   bash -s -- --simulation < setup-rk3588.sh

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
NC='\033[0m' # No Color

#### SETUP ####
if [[ "$1" != "--install-only" && "$1" != "--simulation" ]]; then
    sudo apt-get update
    # docker.io 自带 compose 插件；network-manager 供 WiFi/蜂窝连接管理。
    sudo apt-get -y install docker.io docker-compose-v2 ufw wget network-manager

    sudo systemctl enable docker
    sudo systemctl start docker
    sudo systemctl status docker --no-pager

    # Enable and start the firewall
    echo "y" | sudo ufw enable
    sudo ufw allow 22
    sudo ufw allow 80
    sudo ufw allow 8090
    sudo ufw allow 8189
    sudo ufw allow 8889
    sudo ufw allow 5173
    sudo ufw allow 3000
    echo "y" | sudo ufw reload

    # Keep the WiFi control link responsive: disable power management on wlan0.
    wlan_con=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: '$2=="wlan0"{print $1; exit}')
    if [ -n "$wlan_con" ]; then
        sudo nmcli connection modify "$wlan_con" 802-11-wireless.powersave 2
    fi

    # 串口权限：让当前用户与容器都能访问 RK3588 的板载 UART (ttyS*)、
    # USB 串口 (ttyUSB*) 与 USB CDC 虚拟串口 (ttyACM*)。
    sudo usermod -aG dialout $(whoami)
    sudo usermod -aG tty $(whoami)
    # 摄像头：把当前用户加入 video 组，便于 V4L2 设备 (/dev/video*) 访问。
    sudo usermod -aG video $(whoami)
    echo -e "${BLUE}已将 $(whoami) 加入 dialout/tty/video 组（部分组需重新登录生效）${NC}"

    # May need to logout and login to apply docker group changes
    if ! docker ps >/dev/null 2>&1; then
        echo "Docker installed. Adding $(whoami) to the 'docker' group..."
        sudo usermod -aG docker $(whoami)
        echo -e "${RED}User added to \`docker\` group but the session must be reloaded to access the Docker daemon. Please log out, log back in, and rerun the script. Exiting...${NC}"
        exit 0
    fi

    # Enable IP forwarding
    echo "Enabling IP forwarding..."
    echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
        sudo sysctl -p > /dev/null
    fi

    # Add UFW rules for Docker
    echo "Adding UFW rules for Docker..."
    sudo ufw allow in on docker0 from 192.168.1.0/24 to any
    sudo ufw allow out on docker0 from 192.168.1.0/24 to any

    # Save iptables rules using ufw
    echo "Saving iptables rules using ufw..."
    echo "y" | sudo ufw disable
    echo "y" | sudo ufw enable

    # 提示：RK3588 板载 UART 需在 Armbian 里启用对应 overlay。
    # 默认载板可能未开启，飞控若接在板载 UART 上，请在 /boot/armbianEnv.txt
    # 的 overlays= 中追加对应串口（例如 uart4-m2），然后 reboot，并把
    # 生成的 /dev/ttyS* 填到 .env 的 MAVLINK_SERIAL_PATH。
    echo -e "${YELLOW}提示：请确认 RK3588 板载串口 overlay 已启用（见 docs/DEPLOY_RK3588.md），否则 MAVLink autodetect 可能扫不到 /dev/ttyS*。${NC}"
fi

#### INSTALL ####
if [[ "$1" != "--setup-only" ]]; then
    cd ~
    # 克隆本仓库。若运行的是 fork，可先将 REPO_URL 指向你的 fork。
    REPO_URL=${REPO_URL:-https://github.com/judahpaul16/canarygc.git}
    sudo rm -rf canarygc
    git clone "$REPO_URL"
    cd canarygc
    sudo chmod +x contrib/setup-rk3588.sh
    cp -n .env.example .env 2>/dev/null || true

    # Every profile's app shares the canarygc_app name; tear all down before up.
    docker compose \
        --profile development \
        --profile development-px4 \
        --profile development-betaflight \
        --profile development-inav \
        --profile production \
        down --remove-orphans

    if [[ "$1" == "--simulation" ]]; then
        docker system prune -f
        docker compose --profile development up -d
    else
        docker system prune -af
        # RK3588 无 rpiCamera；检测是否有 V4L2 摄像头 (/dev/video*)。
        # 有则带上 webrtc（需先在 .env 配好 WEBRTC_SOURCE），否则只起 app + nginx。
        if ls /dev/video* >/dev/null 2>&1; then
            echo "Detected V4L2 camera(s). Starting app, nginx and webrtc."
            docker compose --profile production up app webrtc nginx -d
        else
            echo "No cameras found."
            docker compose --profile production up app nginx -d
        fi
    fi
    sleep 5
    docker ps
fi
