#!/bin/bash

RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

function configure_dns64() {
    local ipv4_address
    local ipv6_address

    ipv4_address=$(curl -s4 ifconfig.co)
    ipv6_address=$(curl -s6 ifconfig.co)
    
    if [[ -n $ipv4_address ]]; then
        return
    fi

    if [[ -n $ipv6_address ]]; then
        echo "检查到本机为 IPv6 单栈网络，配置 DNS64..."
        sed -i '/^nameserver /s/^/#/' /etc/resolv.conf 
        echo "nameserver 2001:67c:2b0::4" >> /etc/resolv.conf
        echo "nameserver 2001:67c:2b0::6" >> /etc/resolv.conf
        echo "DNS64 配置完成。"
    fi
}

function check_firewall_configuration() {
    local os_name=$(uname -s)
    local firewall

    if [[ $os_name == "Linux" ]]; then
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
            firewall="ufw"
        elif command -v iptables >/dev/null 2>&1 && iptables -S | grep -q "INPUT -j DROP"; then
            firewall="iptables"
        elif command -v firewalld >/dev/null 2>&1 && firewall-cmd --state | grep -q "running"; then
            firewall="firewalld"
        fi
    fi

    if [[ -z $firewall ]]; then
        echo "未检测到防火墙配置或防火墙未启用，跳过配置防火墙。"
        return
    fi

    echo "检查防火墙配置..."
    case $firewall in
        ufw)
            if ! ufw status | grep -q "Status: active"; then
                ufw enable
            fi

            if ! ufw status | grep -q " $listen_port"; then
                ufw allow "$listen_port"
            fi

            if ! ufw status | grep -q " $override_port"; then
                ufw allow "$override_port"
            fi

            if ! ufw status | grep -q " 80"; then
                ufw allow 80
            fi
            ufw reload

            echo "防火墙配置已更新。"
            ;;
       iptables)
            if ! iptables -C INPUT -p tcp --dport "$listen_port" -j ACCEPT >/dev/null 2>&1; then
                iptables -A INPUT -p tcp --dport "$listen_port" -j ACCEPT
            fi

            if ! iptables -C INPUT -p udp --dport "$listen_port" -j ACCEPT >/dev/null 2>&1; then
                iptables -A INPUT -p udp --dport "$listen_port" -j ACCEPT
            fi

            if ! iptables -C INPUT -p tcp --dport "$override_port" -j ACCEPT >/dev/null 2>&1; then
                iptables -A INPUT -p tcp --dport "$override_port" -j ACCEPT
            fi

            if ! iptables -C INPUT -p udp --dport "$override_port" -j ACCEPT >/dev/null 2>&1; then
                iptables -A INPUT -p udp --dport "$override_port" -j ACCEPT
            fi

            if ! iptables -C INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1; then
                iptables -A INPUT -p tcp --dport 80 -j ACCEPT
            fi

            if ! iptables -C INPUT -p udp --dport 80 -j ACCEPT >/dev/null 2>&1; then
                iptables -A INPUT -p udp --dport 80 -j ACCEPT
            fi

            iptables-save > /etc/sysconfig/iptables

            echo "iptables防火墙配置已更新。"
            ;;
        firewalld)
            if ! firewall-cmd --zone=public --list-ports | grep -q "$listen_port/tcp"; then
                firewall-cmd --zone=public --add-port="$listen_port/tcp" --permanent
            fi

            if ! firewall-cmd --zone=public --list-ports | grep -q "$listen_port/udp"; then
                firewall-cmd --zone=public --add-port="$listen_port/udp" --permanent
            fi

            if ! firewall-cmd --zone=public --list-ports | grep -q "$override_port/tcp"; then
                firewall-cmd --zone=public --add-port="$override_port/tcp" --permanent
            fi

            if ! firewall-cmd --zone=public --list-ports | grep -q "$override_port/udp"; then
                firewall-cmd --zone=public --add-port="$override_port/udp" --permanent
            fi

            if ! firewall-cmd --zone=public --list-ports | grep -q "80/tcp"; then
                firewall-cmd --zone=public --add-port=80/tcp --permanent
            fi

            if ! firewall-cmd --zone=public --list-ports | grep -q "80/udp"; then
                firewall-cmd --zone=public --add-port=80/udp --permanent
            fi

            firewall-cmd --reload

            echo "firewalld防火墙配置已更新。"
            ;;
    esac
}

function check_sing_box_folder() {
    local folder="/usr/local/etc/sing-box"
    if [[ ! -d "$folder" ]]; then
        mkdir -p "$folder"
    fi
}

function check_caddy_folder() {
    local folder="/usr/local/etc/caddy"
    if [[ ! -d "$folder" ]]; then
        mkdir -p "$folder"
    fi
}

function create_tuic_directory() {
    local tuic_directory="/usr/local/etc/tuic"
    local ssl_directory="/etc/ssl/private"
    
    if [[ ! -d "$tuic_directory" ]]; then
        mkdir -p "$tuic_directory"
    fi
    
    if [[ ! -d "$ssl_directory" ]]; then
        mkdir -p "$ssl_directory"
    fi
}

function enable_bbr() {
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "开启 BBR..."
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo "BBR 已开启"
    else
        echo "BBR 已经开启，跳过配置。"
    fi
}

function select_sing_box_install_option() {
    while true; do
        echo "请选择 sing-box 的安装方式："
        echo "  [1]. 编译安装sing-box（支持全部功能）"
        echo "  [2]. 下载安装sing-box（支持部分功能）"

        local install_option
        read -p "请选择 [1-2]: " install_option

        case $install_option in
            1)
                install_go
                compile_install_sing_box
                break
                ;;
            2)
                install_latest_sing_box
                break
                ;;
            *)
                echo -e "${RED}无效的选择，请重新输入。${NC}"
                ;;
        esac
    done
}

function install_go() {
    if ! command -v go &> /dev/null; then
        echo "正在下载 Go..."
        local go_arch
        case $(uname -m) in
            x86_64)
                go_arch="amd64"
                ;;
            i686)
                go_arch="386"
                ;;
            aarch64)
                go_arch="arm64"
                ;;
            armv6l)
                go_arch="armv6l"
                ;;
            *)
                echo -e "${RED}不支持的架构: $(uname -m)${NC}"
                exit 1
                ;;
        esac

        local go_version
        local go_download_url="https://go.dev/dl/go1.20.7.linux-$go_arch.tar.gz"

        wget -qO- "$go_download_url" | tar -xz -C /usr/local
        echo 'export PATH=$PATH:/usr/local/go/bin' |  tee -a /etc/profile >/dev/null
        source /etc/profile
        go version
        
        echo "Go 已安装"
    else
        echo "Go 已经安装，跳过安装步骤。"
    fi
}

function compile_install_sing_box() {
    local go_install_command="go install -v -tags \
with_quic,\
with_grpc,\
with_dhcp,\
with_wireguard,\
with_shadowsocksr,\
with_ech,\
with_utls,\
with_reality_server,\
with_acme,\
with_clash_api,\
with_v2ray_api,\
with_gvisor,\
with_lwip \
github.com/sagernet/sing-box/cmd/sing-box@latest"

    echo "正在编译安装 sing-box，请稍候..."
    $go_install_command

    if [[ $? -eq 0 ]]; then
        mv ~/go/bin/sing-box /usr/local/bin/
        chmod +x /usr/local/bin/sing-box
        echo "sing-box 编译安装成功"
    else
        echo -e "${RED}sing-box 编译安装失败${NC}"
        exit 1
    fi
}

function install_latest_sing_box() {
    local arch=$(uname -m)
    local url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local download_url

    case $arch in
        x86_64)
            download_url=$(curl -s $url | grep -o "https://github.com[^\"']*linux-amd64.tar.gz")
            ;;
        armv7l)
            download_url=$(curl -s $url | grep -o "https://github.com[^\"']*linux-armv7.tar.gz")
            ;;
        aarch64)
            download_url=$(curl -s $url | grep -o "https://github.com[^\"']*linux-arm64.tar.gz")
            ;;
        amd64v3)
            download_url=$(curl -s $url | grep -o "https://github.com[^\"']*linux-amd64v3.tar.gz")
            ;;
        *)
            echo -e "${RED}不支持的架构：$arch${NC}"
            return 1
            ;;
    esac

    if [ -n "$download_url" ]; then
        echo "正在下载 Sing-Box..."
        wget -qO sing-box.tar.gz "$download_url" 2>&1 >/dev/null
        tar -xzf sing-box.tar.gz -C /usr/local/bin --strip-components=1
        rm sing-box.tar.gz
        chmod +x /usr/local/bin/sing-box

        echo "Sing-Box 安装成功！"
    else
        echo -e "${RED}无法获取 Sing-Box 的下载 URL。${NC}"
        return 1
    fi
}

function install_caddy() {
    echo "安装 xcaddy..."
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
    ~/go/bin/xcaddy build --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive
    setcap cap_net_bind_service=+ep ./caddy

    mv caddy /usr/bin/
    echo "Caddy 安装完成。"
}

function download_tuic() {
    local repo="EAimTY/tuic"
    local arch=$(uname -m)

    case "$arch" in
        x86_64)
            arch="x86_64-unknown-linux-gnu"
            ;;
        i686)
            arch="i686-unknown-linux-gnu"
            ;;
        aarch64)
            arch="aarch64-unknown-linux-gnu"
            ;;
        armv7l)
            arch="armv7-unknown-linux-gnueabihf"
            ;;
        *)
            echo -e "${RED}不支持的架构: $arch${NC}"
            exit 1
            ;;
    esac

    local releases_url="https://api.github.com/repos/$repo/releases/latest"
    local download_url=$(curl -sL "$releases_url" | grep -Eo "https://github.com/[^[:space:]]+/releases/download/[^[:space:]]+$arch" | head -1)

    if [ -z "$download_url" ]; then
        echo -e "${RED}获取最新版 TUIC 程序下载链接失败。${NC}"
        exit 1
    fi

    echo "正在下载最新版 TUIC 程序..."
    wget -O /usr/local/bin/tuic "$download_url" >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 TUIC 程序失败。${NC}"
        exit 1
    fi

    chmod +x /usr/local/bin/tuic

    echo "TUIC 程序下载并安装完成。"
}

function configure_sing_box_service() {
    echo "配置 sing-box 开机自启服务..."
    local service_file="/etc/systemd/system/sing-box.service"

    if [[ -f $service_file ]]; then
        rm "$service_file"
    fi
    
       local service_config='[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target'

        echo "$service_config" >"$service_file"
        echo "sing-box 开机自启动服务已配置。"
}

function configure_caddy_service() {
    echo "配置 Caddy 开机自启动服务..."
    local service_file="/etc/systemd/system/caddy.service"

    if [[ -f $service_file ]]; then
        rm "$service_file"
    fi

        local service_config='[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/caddy run --environ --config /usr/local/etc/caddy/caddy.json
ExecReload=/usr/bin/caddy reload --config /usr/local/etc/caddy/caddy.json
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target'

        echo "$service_config" >"$service_file"
        echo "Caddy 开机自启动服务已配置。"
}

function configure_tuic_service() {
    echo "配置TUIC开机自启服务..."
    local service_file="/etc/systemd/system/tuic.service"

    if [[ -f $service_file ]]; then
        rm "$service_file"
    fi
    
        local service_config='[Unit]
Description=tuic service
Documentation=https://github.com/EAimTY/tuic
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/usr/local/etc/tuic/
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/tuic -c /usr/local/etc/tuic/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target'

        echo "$service_config" >"$service_file"
        echo "TUIC 开机自启动服务已配置。"
}

function set_listen_port() {
    while true; do
        read -p "请输入监听端口 (默认443): " listen_port
        listen_port=${listen_port:-443}

        if [[ $listen_port =~ ^[1-9][0-9]{0,4}$ && $listen_port -le 65535 ]]; then
            echo "监听端口设置成功：$listen_port" 
            break
        else
            echo -e "${RED}错误：监听端口范围必须在1-65535之间，请重新输入。${NC}" >&2
        fi
    done
}

function Direct_override_address() {
    local is_valid_address=false

    while [[ "$is_valid_address" == "false" ]]; do
        read -p "请输入目标地址: " override_address

        if [[ $override_address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            IFS='.' read -r -a address_fields <<< "$override_address"
            is_valid_ip=true
            for field in "${address_fields[@]}"; do
                if [[ "$field" -lt 0 || "$field" -gt 255 ]]; then
                    is_valid_ip=false
                    break
                fi
            done

            if [[ "$is_valid_ip" == "true" ]]; then
                is_valid_address=true
            else
                echo -e "${RED}错误：IP地址字段必须在0到255之间，请重新输入。${NC}"
            fi
        else
            echo -e "${RED}错误：请输入合法的IPv4地址，格式为 0.0.0.0${NC}"
        fi
    done
}

function Direct_override_port() {
    while true; do
        read -p "请输入目标端口 (默认443): " override_port
        override_port=${override_port:-443}

        if [[ $override_port =~ ^[1-9][0-9]{0,4}$ && $override_port -le 65535 ]]; then
            break
        else
            echo -e "${RED}错误：目标端口范围必须在1-65535之间，请重新输入。"
        fi
    done
}

function ss_encryption_method() {
    while true; do
        read -p "请选择加密方式：
[1]. 2022-blake3-aes-128-gcm
[2]. 2022-blake3-aes-256-gcm
[3]. 2022-blake3-chacha20-poly1305
请输入对应的数字 (默认3): " encryption_choice
        encryption_choice=${encryption_choice:-3}

        case $encryption_choice in
            1)
                ss_method="2022-blake3-aes-128-gcm"
                ss_password=$(sing-box generate rand --base64 16)
                echo "随机生成的密码：$ss_password"
                break
                ;;
            2)
                ss_method="2022-blake3-aes-256-gcm"
                ss_password=$(sing-box generate rand --base64 32)
                echo "随机生成的密码：$ss_password"
                break
                ;;
            3)
                ss_method="2022-blake3-chacha20-poly1305"
                ss_password=$(sing-box generate rand --base64 32)
                echo "随机生成的密码：$ss_password"
                break
                ;;
            *)
                echo -e "${RED}错误：无效的选择，请重新输入。${NC}"
                ;;
        esac
    done
}

function generate_caddy_auth_user() {
    read -p "请输入用户名（默认自动生成）: " user_input

    if [[ -z $user_input ]]; then
        auth_user=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)
    else
        auth_user=$user_input
    fi

    echo "用户名: $auth_user"
}

function generate_caddy_auth_pass() {
    read -p "请输入密码（默认自动生成）: " pass_input

    if [[ -z $pass_input ]]; then
        auth_pass=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
    else
        auth_pass=$pass_input
    fi

    echo "密码: $auth_pass"
}

function get_caddy_fake_site() {
    while true; do
        read -p "请输入伪装网址（默认: www.fan-2000.com）: " fake_site
        fake_site=${fake_site:-"www.fan-2000.com"}

        # Validate the fake site URL
        if curl --output /dev/null --silent --head --fail "$fake_site"; then
            echo "伪装网址: $fake_site"
            break
        else
            echo -e "${RED}伪装网址无效或不可用，请重新输入。${NC}"
        fi
    done
}

function get_caddy_domain() {
    read -p "请输入域名（用于自动申请证书）: " domain
    while true; do
        if [[ -z $domain ]]; then
            echo -e "${RED}域名不能为空，请重新输入。${NC}"
        else
            if ping -c 1 $domain >/dev/null 2>&1; then
                break
            else
                echo -e "${RED}域名未绑定本机 IP，请重新输入。${NC}"
            fi
        fi
        read -p "请输入域名（用于自动申请证书）: " domain
    done

    echo "域名: $domain"
}

function test_caddy_config() {
    echo "测试 Caddy 配置是否正确..."
    local output
    local caddy_pid

    output=$(timeout 15 /usr/bin/caddy run --environ --config /usr/local/etc/caddy/caddy.json 2>&1 &)
    caddy_pid=$!

    wait $caddy_pid 2>/dev/null

    if echo "$output" | grep -i "error"; then
        echo -e "${RED}Caddy 配置测试未通过，请检查配置文件${NC}"
        echo "$output" | grep -i "error" --color=always 
    else
        echo "Caddy 配置测试通过"
    fi
}

function tuic_generate_uuid() {
    if [[ -n $(command -v uuidgen) ]]; then
        uuid=$(uuidgen)
    elif [[ -n $(command -v uuid) ]]; then
        uuid=$(uuid -v 4)
    else
        echo -e "${RED}错误：无法生成UUID，请手动设置。${NC}"
        exit 1
    fi
    echo "随机生成的UUID为：$uuid"
}

function tuic_set_password() {
    read -p "请输入密码（默认随机生成）: " password

    if [[ -z "$password" ]]; then
        password=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 12 | head -n 1)
        echo "随机生成的密码为：$password"
    fi
}

function tuic_add_multiple_users() {
    while true; do
        read -p "是否继续添加用户？(Y/N, 默认为N): " add_multiple_users

        if [[ -z "$add_multiple_users" || "$add_multiple_users" == "N" || "$add_multiple_users" == "n" ]]; then
            break
        elif [[ "$add_multiple_users" == "Y" || "$add_multiple_users" == "y" ]]; then

            tuic_generate_uuid

            tuic_set_password

            users+=",\n\"$uuid\": \"$password\""
        else
            echo -e "${RED}错误：无效的选择，请重新输入。${NC}"
        fi
    done
}

function set_certificate_and_private_key() {
    while true; do
        read -p "请输入证书路径 (默认/etc/ssl/private/cert.crt): " certificate_path
        certificate_path=${certificate_path:-"/etc/ssl/private/cert.crt"}

        if [[ "$certificate_path" != "/etc/ssl/private/cert.crt" && ! -f "$certificate_path" ]]; then
            echo -e "${RED}错误：证书文件不存在，请重新输入。${NC}"
        else
            break
        fi
    done

    while true; do
        read -p "请输入私钥路径 (默认/etc/ssl/private/private.key): " private_key_path
        private_key_path=${private_key_path:-"/etc/ssl/private/private.key"}

        if [[ "$private_key_path" != "/etc/ssl/private/private.key" && ! -f "$private_key_path" ]]; then
            echo -e "${RED}错误：私钥文件不存在，请重新输入。${NC}"
        else
            break
        fi
    done
}

function set_congestion_control() {
    local default_congestion_control="bbr"

    while true; do
        read -p "请选择拥塞控制算法 (默认$default_congestion_control):
 [1]. bbr
 [2]. cubic
 [3]. new_reno
请输入对应的数字: " congestion_control

        case $congestion_control in
            1)
                congestion_control="bbr"
                break
                ;;
            2)
                congestion_control="cubic"
                break
                ;;
            3)
                congestion_control="new_reno"
                break
                ;;
            "")
                congestion_control=$default_congestion_control
                break
                ;;
            *)
                echo -e "${RED}错误：无效的选择，请重新输入。${NC}"
                ;;
        esac
    done
}

function ask_certificate_option() {
    while true; do
        read -p "请选择证书来源：
 [1]. 自动申请证书
 [2]. 自备证书
请输入对应的数字: " certificate_option

        case $certificate_option in
            1)
                echo "已选择自动申请证书。"
                tuic_apply_certificate
                break
                ;;
            2)
                echo "已选择自备证书。"
                break
                ;;

            *)
                echo -e "${RED}错误：无效的选择，请重新输入。${NC}"
                ;;
        esac
    done
}

function tuic_apply_certificate() {
    local domain
    local has_ipv4=false

    if curl -s4 ifconfig.co &>/dev/null; then
        has_ipv4=true
    fi

    while true; do
        read -p "请输入您的域名: " domain

        if ping -c 1 "$domain" &>/dev/null; then
            break
        else
            echo -e "${RED}错误：域名未解析或输入错误，请重新输入。${NC}"
        fi
    done
    
    echo "正在申请证书..."
    curl -s https://get.acme.sh | sh -s email=example@gmail.com
    alias acme.sh=~/.acme.sh/acme.sh
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    if $has_ipv4; then
        ~/.acme.sh/acme.sh --issue -d "$domain" --standalone
    else
        ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --listen-v6
    fi

    echo "安装证书..."
    certificate_path=$(~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc --key-file "$private_key_path" --fullchain-file "$certificate_path")

    set_certificate_path="$certificate_path"
    set_private_key_path="$private_key_path"
}

function read_up_speed() {
    while true; do
        read -p "请输入上行速度 (默认50): " up_mbps
        up_mbps=${up_mbps:-50}

        if [[ $up_mbps =~ ^[0-9]+$ ]]; then
            echo "上行速度设置成功：$up_mbps Mbps"
            break
        else
            echo -e "${RED}错误：请输入数字作为上行速度。${NC}"
        fi
    done
}

function read_down_speed() {
    while true; do
        read -p "请输入下行速度 (默认100): " down_mbps
        down_mbps=${down_mbps:-100}

        if [[ $down_mbps =~ ^[0-9]+$ ]]; then
            echo "下行速度设置成功：$down_mbps Mbps"
            break
        else
            echo -e "${RED}错误：请输入数字作为下行速度。${NC}"
        fi
    done
}

function read_auth_password() {
    read -p "请输入认证密码 (默认随机生成): " auth_password
    auth_password=${auth_password:-$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 12 | head -n 1)}
    echo "认证密码设置成功：$auth_password"
}

function read_users() {
    users="[
        {
          \"auth_str\": \"$auth_password\"
        }"

    while true; do
        read -p "是否继续添加用户？(Y/N，默认N): " -e add_multiple_users

        if [[ -z "$add_multiple_users" ]]; then
            add_multiple_users="N"
        fi

        if [[ "$add_multiple_users" == "Y" || "$add_multiple_users" == "y" ]]; then
            read_auth_password
            users+=",
        {
          \"auth_str\": \"$auth_password\"
        }"
        elif [[ "$add_multiple_users" == "N" || "$add_multiple_users" == "n" ]]; then
            break
        else
            echo -e "${RED}无效的输入，请重新输入。${NC}"
        fi
    done

    users+=$'\n      ]'
}

function validate_domain() {
    while true; do
        read -p "请输入您的域名: " domain

        if ping -c 1 "$domain" &>/dev/null; then
            break
        else
            echo -e "${RED}错误：域名未解析或输入错误，请重新输入。${NC}"
        fi
    done
}

function set_shadowtls_username() {
    read -p "请输入用户名 (默认随机生成): " new_username
    username=${new_username:-$(generate_shadowtls_random_username)}
    echo "用户名: $username"
}

function generate_shadowtls_random_username() {
    local username=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
    echo "$username"
}

function generate_shadowtls_password() {
    read -p "请选择 Shadowsocks 加密方式：
[1]. 2022-blake3-chacha20-poly1305
[2]. 2022-blake3-aes-256-gcm
[3]. 2022-blake3-aes-128-gcm
请输入对应的数字 (默认1): " encryption_choice
    encryption_choice=${encryption_choice:-1}

    case $encryption_choice in
        1)
            ss_method="2022-blake3-chacha20-poly1305"
            shadowtls_password=$(openssl rand -base64 32)
            ss_password=$(openssl rand -base64 32)
            ;;
        2)
            ss_method="2022-blake3-aes-256-gcm"
            shadowtls_password=$(openssl rand -base64 32)
            ss_password=$(openssl rand -base64 32)
            ;;
        3)
            ss_method="2022-blake3-aes-128-gcm"
            shadowtls_password=$(openssl rand -base64 16)
            ss_password=$(openssl rand -base64 16)
            ;;
        *)
            echo -e "${RED}无效的选择，使用默认加密方式。${NC}"
            ss_method="2022-blake3-chacha20-poly1305"
            shadowtls_password=$(openssl rand -base64 32)
            ss_password=$(openssl rand -base64 32)
            ;;
    esac

    echo "加密方式: $ss_method"
}

function add_shadowtls_user() {
    local user_password=""
    if [[ $encryption_choice == 1 || $encryption_choice == 2 ]]; then
        user_password=$(openssl rand -base64 32)
    elif [[ $encryption_choice == 3 ]]; then
        user_password=$(openssl rand -base64 16)
    fi

    read -p "请输入用户名 (默认随机生成): " new_username
    local new_user=${new_username:-$(generate_shadowtls_random_username)}

    users+=",{
      \"name\": \"$new_user\",
      \"password\": \"$user_password\"
    }"

    echo "用户名: $new_user"
    echo "ShadowTLS 密码: $user_password"
}

function set_shadowtls_handshake_server() {
    local handshake_server=""
    local openssl_output=""

    read -p "请输入握手服务器地址 (默认www.apple.com): " handshake_server
    handshake_server=${handshake_server:-www.apple.com}

    echo "正在验证握手服务器支持的TLS版本..."

    local is_supported="false"

    if command -v openssl >/dev/null 2>&1; then
        local openssl_version=$(openssl version)

        if [[ $openssl_version == *"OpenSSL"* ]]; then
            while true; do
                openssl_output=$(timeout 90s openssl s_client -connect "$handshake_server:443" -tls1_3 2>&1)

                if [[ $openssl_output == *"Protocol  : TLSv1.3"* ]]; then
                    is_supported="true"
                    echo "握手服务器支持TLS 1.3。"
                    break
                else
                    echo -e "${RED}错误：握手服务器不支持TLS 1.3，请重新输入握手服务器地址。${NC}"
                    read -p "请输入握手服务器地址 (默认www.apple.com): " handshake_server
                    handshake_server=${handshake_server:-www.apple.com}
                    echo "正在验证握手服务器支持的TLS版本..."
                fi
            done
        fi
    fi

    if [[ $is_supported == "false" ]]; then
        echo -e "${YELLOW}警告：无法验证握手服务器支持的TLS版本。请确保握手服务器支持TLS 1.3。${NC}"
    fi
    handshake_server_global=$handshake_server
}

function reality_generate_uuid() {
    local uuid=$(uuidgen)
    echo "$uuid"
}

function generate_short_id() {
    local length=$1
    local short_id=$(openssl rand -hex "$length")
    echo "$short_id"
}

function select_flow_type() {
    local flow_type="xtls-rprx-vision"

    while true; do
        read -p "请选择流控类型：
 [1]. xtls-rprx-vision（vless+vision+reality)
 [2]. 留空(vless+h2/grpc+reality)
请输入选项 (默认为 xtls-rprx-vision): " flow_option

        case $flow_option in
            "" | 1)
                flow_type="xtls-rprx-vision"
                break
                ;;
            2)
                flow_type=""
                break
                ;;
            *)
                echo -e "${RED}错误的选项，请重新输入！${NC}" >&2
                ;;
        esac
    done

    echo "$flow_type"
}

function validate_tls13_support() {
    local server="$1"
    local tls13_supported="false"

    if command -v openssl >/dev/null 2>&1; then
        local openssl_output=$(timeout 90s openssl s_client -connect "$server:443" -tls1_3 2>&1)
        if [[ $openssl_output == *"Protocol  : TLSv1.3"* ]]; then
            tls13_supported="true"
        fi
    fi

    echo "$tls13_supported"
}

function generate_server_name_config() {
    local server_name="www.gov.hk"

    read -p "请输入可用的 serverName 列表 (默认为 www.gov.hk): " user_input
    
    echo "正在验证服务器支持的TLS版本..." >&2
    
    if [[ -n "$user_input" ]]; then
        server_name="$user_input"
        local tls13_support=$(validate_tls13_support "$server_name")

        if [[ "$tls13_support" == "false" ]]; then
            echo -e "${RED}该网址不支持 TLS 1.3，请重新输入！${NC}" >&2
            generate_server_name_config
            return
        fi
    fi

    echo "$server_name"
}

function generate_target_server_config() {
    local target_server="www.gov.hk"

    read -p "请输入目标网站地址(默认为 www.gov.hk): " user_input
    
    echo "正在验证服务器支持的TLS版本..." >&2
    
    if [[ -n "$user_input" ]]; then
        target_server="$user_input"
        local tls13_support=$(validate_tls13_support "$target_server")

        if [[ "$tls13_support" == "false" ]]; then
            echo -e "${RED}该目标网站地址不支持 TLS 1.3，请重新输入！${NC}" >&2
            generate_target_server_config
            return
        fi
    fi

    echo "$target_server"
}

function generate_private_key_config() {
    local private_key

    while true; do
        read -p "请输入私钥 (默认随机生成私钥): " private_key

        if [[ -z "$private_key" ]]; then
            local keypair_output=$(sing-box generate reality-keypair)
            private_key=$(echo "$keypair_output" | awk -F: '/PrivateKey/{gsub(/ /, "", $2); print $2}')
            echo "$keypair_output" | awk -F: '/PublicKey/{gsub(/ /, "", $2); print $2}' > /tmp/public_key_temp.txt
            break
        fi

        if openssl pkey -inform PEM -noout -text -in <(echo "$private_key") >/dev/null 2>&1; then
            break
        else
            echo -e "${RED}无效的私钥，请重新输入！${NC}" >&2
        fi
    done
    
    echo "$private_key"
}

function generate_short_ids_config() {
    local short_ids=()
    local add_more_short_ids="y"
    local length=8

    while [[ "$add_more_short_ids" == "y" ]]; do
        if [[ ${#short_ids[@]} -eq 8 ]]; then
            echo -e "${YELLOW}已达到最大 shortId 数量限制！${NC}" >&2
            break
        fi

        local short_id=$(generate_short_id "$length")
        short_ids+=("$short_id")

        while true; do
            read -p "是否继续添加 shortId？(Y/N，默认为 N): " add_more_short_ids
            add_more_short_ids=${add_more_short_ids:-n}
            case $add_more_short_ids in
                [yY])
                    add_more_short_ids="y"
                    break
                    ;;
                [nN])
                    add_more_short_ids="n"
                    break
                    ;;
                *)
                    echo -e "${RED}错误的选项，请重新输入！${NC}" >&2
                    ;;
            esac
        done

        if [[ "$add_more_short_ids" == "y" ]]; then
            length=$((length - 1))
        fi
    done

    local short_ids_config=$(printf '            "%s",\n' "${short_ids[@]}")
    short_ids_config=${short_ids_config%,}  

    echo "$short_ids_config"
}

function generate_flow_config() {
    local flow_type="$1"
    local transport_config=""

    if [[ "$flow_type" != "" ]]; then
        return  
    fi

    local transport_type=""

    while true; do
        read -p "请选择传输层协议：
 [1]. http
 [2]. grpc
请输入选项 (默认为 http): " transport_option

        case $transport_option in
            1)
                transport_type="http"
                break
                ;;
            2)
                transport_type="grpc"
                break
                ;;
            "")
                transport_type="http"
                break
                ;;                
            *)
                echo -e "${RED}错误的选项，请重新输入！${NC}" >&2
                ;;
        esac
    done

    transport_config='
      "transport": {
        "type": "'"$transport_type"'"
      },'

    echo "$transport_config"
}

function generate_user_config() {
    local flow_type="$1"
    local users=()
    local add_more_users="y"

    while [[ "$add_more_users" == "y" ]]; do
        local user_uuid

        while true; do
            read -p "请输入用户 UUID (默认随机生成 UUID): " user_uuid

            if [[ -z "$user_uuid" ]]; then
                user_uuid=$(reality_generate_uuid)
                break
            fi

            if [[ $user_uuid =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
                break
            else
                echo -e "${RED}无效的 UUID，请重新输入！${NC}" >&2
            fi
        done

        users+=('
        {
          "uuid": "'"$user_uuid"'",
          "flow": "'"$flow_type"'"
        },')

        while true; do
            read -p "是否继续添加用户？(Y/N，默认为 N): " add_more_users
            add_more_users=${add_more_users:-n}
            case $add_more_users in
                [yY])
                    add_more_users="y"
                    break
                    ;;
                [nN])
                    add_more_users="n"
                    break
                    ;;
                *)
                    echo -e "${RED}错误的选项，请重新输入！${NC}" >&2
                    ;;
            esac
        done
    done

    users[-1]=${users[-1]%,}

    echo "${users[*]}"
}

function Direct_write_config_file() {
    local config_file="/usr/local/etc/sing-box/config.json"

    echo "{
  \"log\": {
    \"disabled\": false,
    \"level\": \"info\",
    \"timestamp\": true
  },
  \"inbounds\": [
    {
      \"type\": \"direct\",
      \"tag\": \"direct-in\",
      \"listen\": \"0.0.0.0\",
      \"listen_port\": $listen_port,
      \"sniff\": true,
      \"sniff_override_destination\": true,
      \"sniff_timeout\": \"300ms\",
      \"proxy_protocol\": false,
      \"network\": \"tcp\",
      \"override_address\": \"$override_address\",
      \"override_port\": $override_port
    }
  ],
  \"outbounds\": [
    {
      \"type\": \"direct\",
      \"tag\": \"direct\"
    },
    {
      \"type\": \"block\",
      \"tag\": \"block\"
    }
  ]
}" > "$config_file"

    echo "配置文件 $config_file 写入成功。"
}

function ss_write_sing_box_config() {
    local config_file="/usr/local/etc/sing-box/config.json"

    echo "{
  \"log\": {
    \"disabled\": false,
    \"level\": \"info\",
    \"timestamp\": true
  },
  \"inbounds\": [
    {
      \"type\": \"shadowsocks\",
      \"tag\": \"ss-in\",
      \"listen\": \"::\",
      \"listen_port\": $listen_port,
      \"method\": \"$ss_method\",
      \"password\": \"$ss_password\"
    }
  ],
  \"outbounds\": [
    {
      \"type\": \"direct\",
      \"tag\": \"direct\"
    },
    {
      \"type\": \"block\",
      \"tag\": \"block\"
    }
  ]
}" > "$config_file"

    echo "配置文件 $config_file 创建成功。"
}

function create_caddy_config() {
    local config_file="/usr/local/etc/caddy/caddy.json"

    echo "{
  \"apps\": {
    \"http\": {
      \"servers\": {
        \"https\": {
          \"listen\": [\":$listen_port\"],
          \"routes\": [
            {
              \"handle\": [
                {
                  \"handler\": \"forward_proxy\",
                  \"auth_user_deprecated\": \"$auth_user\",
                  \"auth_pass_deprecated\": \"$auth_pass\",
                  \"hide_ip\": true,
                  \"hide_via\": true,
                  \"probe_resistance\": {}
                }
              ]
            },
            {
              \"handle\": [
                {
                  \"handler\": \"headers\",
                  \"response\": {
                    \"set\": {
                      \"Strict-Transport-Security\": [\"max-age=31536000; includeSubDomains; preload\"]
                    }
                  }
                },
                {
                  \"handler\": \"reverse_proxy\",
                  \"headers\": {
                    \"request\": {
                      \"set\": {
                        \"Host\": [
                          \"{http.reverse_proxy.upstream.hostport}\"
                        ],
                        \"X-Forwarded-Host\": [\"{http.request.host}\"]
                      }
                    }
                  },
                  \"transport\": {
                    \"protocol\": \"http\",
                    \"tls\": {}
                  },
                  \"upstreams\": [
                    {\"dial\": \"$fake_site:443\"}
                  ]
                }
              ]
            }
          ],
          \"tls_connection_policies\": [
            {
              \"match\": {
                \"sni\": [\"$domain\"]
              },
              \"protocol_min\": \"tls1.2\",
              \"protocol_max\": \"tls1.2\",
              \"cipher_suites\": [\"TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256\"],
              \"curves\": [\"secp521r1\",\"secp384r1\",\"secp256r1\"]
            }
          ],
          \"protocols\": [\"h1\",\"h2\"]
        }
      }
    },
    \"tls\": {
      \"certificates\": {
        \"automate\": [\"$domain\"]
      },
      \"automation\": {
        \"policies\": [
          {
            \"issuers\": [
              {
                \"module\": \"acme\"
              }
            ]
          }
        ]
      }
    }
  }
}" > "$config_file"

    echo "配置文件 $config_file 写入成功。"
}

function generate_tuic_config() {
    local config_file="/usr/local/etc/tuic/config.json"
    local users=""
    local certificate=""
    local private_key=""
    
    set_listen_port
    tuic_generate_uuid
    tuic_set_password
    users="\"$uuid\": \"$password\""

    tuic_add_multiple_users
    users=$(echo -e "$users" | sed -e 's/^/        /')

    set_certificate_and_private_key
    certificate_path="$certificate_path"
    private_key_path="$private_key_path"
    set_congestion_control

    echo "{
    \"server\": \"[::]:$listen_port\",
    \"users\": {
$users
    },
    \"certificate\": \"$certificate_path\",
    \"private_key\": \"$private_key_path\",
    \"congestion_control\": \"$congestion_control\",
    \"alpn\": [\"h3\", \"spdy/3.1\"],
    \"udp_relay_ipv6\": true,
    \"zero_rtt_handshake\": false,
    \"dual_stack\": true,
    \"auth_timeout\": \"3s\",
    \"task_negotiation_timeout\": \"3s\",
    \"max_idle_time\": \"10s\",
    \"max_external_packet_size\": 1500,
    \"send_window\": 16777216,
    \"receive_window\": 8388608,
    \"gc_interval\": \"3s\",
    \"gc_lifetime\": \"15s\",
    \"log_level\": \"warn\"
}" > "$config_file"
}

function generate_Hysteria_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local certificate=""
    local private_key=""
 
    set_listen_port
    read_up_speed
    read_down_speed
    read_auth_password
    read_users
    validate_domain
    set_certificate_and_private_key
    certificate_path="$certificate_path"
    private_key_path="$private_key_path"

    echo "生成 Hysteria 配置文件..."
    echo "{
  \"log\": {
    \"disabled\": false,
    \"level\": \"info\",
    \"timestamp\": true
  },
  \"inbounds\": [
    {
      \"type\": \"hysteria\",
      \"tag\": \"hysteria-in\",
      \"listen\": \"::\",
      \"listen_port\": $listen_port,
      \"sniff\": true,
      \"sniff_override_destination\": true,
      \"up_mbps\": $up_mbps,
      \"down_mbps\": $down_mbps,
      \"users\": $users,
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"$domain\",
        \"alpn\": [
          \"h3\"
        ],
        \"min_version\": \"1.2\",
        \"max_version\": \"1.3\",
        \"certificate_path\": \"$certificate_path\",
        \"key_path\": \"$private_key_path\"
      }
    }
  ],
  \"outbounds\": [
    {
      \"type\": \"direct\",
      \"tag\": \"direct\"
    },
    {
      \"type\": \"block\",
      \"tag\": \"block\"
    }
  ]
}" > "$config_file"
}

function configure_shadowtls_config_file() {
    local config_file="/usr/local/etc/sing-box/config.json"

    set_listen_port
    set_shadowtls_username
    generate_shadowtls_password

    local users="{
          \"name\": \"$username\",
          \"password\": \"$shadowtls_password\"
        }"

    local add_multiple_users="Y"

    while [[ $add_multiple_users == [Yy] ]]; do
        read -p "是否添加多用户？(Y/N，默认为N): " add_multiple_users

        if [[ $add_multiple_users == [Yy] ]]; then
            add_shadowtls_user
        fi
    done

    set_shadowtls_handshake_server

    echo "{
  \"inbounds\": [
    {
      \"type\": \"shadowtls\",
      \"tag\": \"st-in\",
      \"listen\": \"::\",
      \"listen_port\": $listen_port,
      \"version\": 3,
      \"users\": [
        $users
      ],
      \"handshake\": {
        \"server\": \"$handshake_server_global\",
        \"server_port\": 443
      },
      \"strict_mode\": true,
      \"detour\": \"ss-in\"
    },
    {
      \"type\": \"shadowsocks\",
      \"tag\": \"ss-in\",
      \"listen\": \"127.0.0.1\",
      \"network\": \"tcp\",
      \"method\": \"$ss_method\",
      \"password\": \"$ss_password\"
    }
  ],
  \"outbounds\": [
    {
      \"type\": \"direct\",
      \"tag\": \"direct\"
    },
    {
      \"type\": \"block\",
      \"tag\": \"block\"
    }
  ]
}" | jq '.' > "$config_file"
}

function generate_reality_config() {
    local config_file="/usr/local/etc/sing-box/config.json"

    local listen_port_output=$(set_listen_port)
    local listen_port=$(echo "$listen_port_output" | grep -oP '\d+$')
    local flow_type=$(select_flow_type)

    transport_config=$(generate_flow_config "$flow_type")

    users=$(generate_user_config "$flow_type")

    local server_name=$(generate_server_name_config)
    local target_server=$(generate_target_server_config)
    local private_key=$(generate_private_key_config)
    local short_ids=$(generate_short_ids_config)

    local config_content="{
  \"log\": {
    \"disabled\": false,
    \"level\": \"info\",
    \"timestamp\": true
  },
  \"inbounds\": [
    {
      \"type\": \"vless\",
      \"tag\": \"vless-in\",
      \"listen\": \"::\",
      \"listen_port\": $listen_port,
      \"users\": [$users
      ],$transport_config
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"$server_name\",
        \"reality\": {
          \"enabled\": true,
          \"handshake\": {
            \"server\": \"$target_server\",
            \"server_port\": 443
          },
          \"private_key\": \"$private_key\",
          \"short_id\": [
$short_ids
          ]
        }
      }
    }
  ],
  \"outbounds\": [
    {
      \"type\": \"direct\",
      \"tag\": \"direct\"
    },
    {
      \"type\": \"block\",
      \"tag\": \"block\"
    }
  ]
}"

    echo "$config_content" > "$config_file"
    echo "Sing-Box 配置文件已生成并保存至 $config_file"
    
    check_firewall_configuration       
}

function display_reality_config() {
    local config_file="/usr/local/etc/sing-box/config.json"

        local listen_port=$(jq -r '.inbounds[0].listen_port' "$config_file")
        local users=$(jq -r '.inbounds[0].users[].uuid' "$config_file")
        local flow_type=$(jq -r '.inbounds[0].users[].flow' "$config_file")
        local transport_type=$(jq -r '.inbounds[0].transport.type' "$config_file")
        local server_name=$(jq -r '.inbounds[0].tls.server_name' "$config_file")
        local target_server=$(jq -r '.inbounds[0].tls.reality.handshake.server' "$config_file")
        local short_ids=$(jq -r '.inbounds[0].tls.reality.short_id[]' "$config_file")
        local public_key=$(cat /tmp/public_key_temp.txt)

        echo -e "${CYAN}Vless+Reality 节点配置信息：${NC}"
        echo -e "${CYAN}==================================================================${NC}"  
        echo "监听端口: $listen_port"
        echo -e "${CYAN}------------------------------------------------------------------${NC}"  
        echo "用户 UUID:"
        echo "$users"
        echo -e "${CYAN}------------------------------------------------------------------${NC}"  
        echo "流控类型: $flow_type"
        echo -e "${CYAN}------------------------------------------------------------------${NC}"  
        echo "传输层协议: $transport_type"
        echo -e "${CYAN}------------------------------------------------------------------${NC}"  
        echo "ServerName: $server_name"
        echo -e "${CYAN}------------------------------------------------------------------${NC}"  
        echo "目标网站地址: $target_server"
        echo -e "${CYAN}------------------------------------------------------------------${NC}"  
        echo "Short ID:"
        echo "$short_ids"
        echo -e "${CYAN}------------------------------------------------------------------${NC}"  
        echo "PublicKey: $public_key"
       echo -e "${CYAN}==================================================================${NC}" 
}

function display_tuic_config() {
    local config_file="/usr/local/etc/tuic/config.json"

echo -e "${CYAN}TUIC 节点配置信息：${NC}"    
echo -e "${CYAN}==================================================================${NC}" 
    echo "监听端口: $(jq -r '.server' "$config_file" | sed 's/\[::\]://')"
echo -e "${CYAN}------------------------------------------------------------------${NC}" 
    echo "UUID和密码列表:"
    jq -r '.users | to_entries[] | "UUID:\(.key)\t密码:\(.value)"' "$config_file"
echo -e "${CYAN}------------------------------------------------------------------${NC}" 
    echo "拥塞控制算法: $(jq -r '.congestion_control' "$config_file")"
echo -e "${CYAN}------------------------------------------------------------------${NC}" 
    echo "ALPN协议:$(jq -r '.alpn[] | select(. != "")' "$config_file" | sed ':a;N;$!ba;s/\n/, /g')"
echo -e "${CYAN}==================================================================${NC}"    
}

function display_Hysteria_config_info() {

    echo -e "${CYAN}Hysteria 节点配置信息：${NC}"
    echo -e "${CYAN}==================================================================${NC}" 
    echo "域名：$domain"
    echo -e "${CYAN}------------------------------------------------------------------${NC}" 
    echo "监听端口：$listen_port"
    echo -e "${CYAN}------------------------------------------------------------------${NC}" 
    echo "上行速度：${up_mbps}Mbps"
    echo -e "${CYAN}------------------------------------------------------------------${NC}" 
    echo "下行速度：${down_mbps}Mbps"
    echo -e "${CYAN}------------------------------------------------------------------${NC}" 
    echo "用户密码："
    local user_count=$(echo "$users" | jq length)
    for ((i = 0; i < user_count; i++)); do
        local auth_str=$(echo "$users" | jq -r ".[$i].auth_str")
        echo "用户$i: $auth_str"
    done
    echo -e "${CYAN}==================================================================${NC}"  
}

function display_shadowtls_config() {
    local config_file="/usr/local/etc/sing-box/config.json"

    echo -e "${CYAN}ShadowTLS 节点配置信息：${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo "监听端口: $listen_port"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    jq -r '.inbounds[0].users[] | "ShadowTLS 密码: \(.password)"' "$config_file" | while IFS= read -r line; do
    echo "$line"
done  
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo "Shadowsocks 密码: $ss_password"
    echo -e "${CYAN}================================================================${NC}"
}

function Direct_extract_config_info() {
    local local_ip
    local_ip=$(curl -s http://ifconfig.me)

    echo -e "${CYAN}Direct 节点配置信息：${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo "中转地址: $local_ip"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo "监听端口: $listen_port"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo "目标地址: $override_address"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo "目标端口: $override_port"
    echo -e "${CYAN}================================================================${NC}"
}

function Shadowsocks_extract_config_info() {
    local local_ip
    local_ip=$(curl -s http://ifconfig.me)

    echo -e "${CYAN}Shadowsocks 节点配置信息：${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo "服务器地址: $local_ip"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo "监听端口: $listen_port"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo "加密方式: $ss_method"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo "密码: $ss_password"
    echo -e "${CYAN}================================================================${NC}"
}

function NaiveProxy_extract_config_info() {

    echo -e "${CYAN}NaiveProxy 节点配置信息：${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo "监听端口: $listen_port"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo "用 户 名: $auth_user"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo "密    码: $auth_pass"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"
    echo "域    名: $domain"   
    echo -e "${CYAN}================================================================${NC}"
}

function restart_sing_box_service() {
    echo "重启 sing-box 服务..."
    systemctl restart sing-box

    if [[ $? -eq 0 ]]; then
        echo "sing-box 服务已重启。"
    else
        echo -e "${RED}重启 sing-box 服务失败。${NC}"
    fi

    systemctl status sing-box
}

function restart_naiveproxy_service() {
    echo "重启 naiveproxy 服务..."
    systemctl reload caddy

    if [[ $? -eq 0 ]]; then
        echo "naiveproxy 服务已重启。"
    else
        echo -e "${RED}重启 naiveproxy 服务失败。${NC}"
    fi

    systemctl status caddy
}

function restart_tuic() {
    echo "重启 TUIC 服务..."
    systemctl restart tuic.service

    if [[ $? -eq 0 ]]; then
        echo "TUIC 服务已重启。"
    else
        echo -e "${RED}重启 TUIC 服务失败。${NC}"
    fi

    systemctl status tuic.service   
}

function uninstall_sing_box() {
    echo "开始卸载 sing-box..."
    systemctl stop sing-box
    systemctl disable sing-box
    rm -rf /usr/local/bin/sing-box
    rm -rf /usr/local/etc/sing-box
    rm -rf /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    echo "sing-box 卸载完成。"
}

function uninstall_naiveproxy() {
    echo "开始卸载 NaiveProxy..."
    systemctl stop caddy
    systemctl disable caddy
    rm -rf /etc/systemd/system/caddy.service
    rm -rf /usr/local/etc/caddy
    rm -rf /usr/bin/caddy
    systemctl daemon-reload
    echo "NaiveProxy 卸载完成。"
}

function uninstall_tuic() {
    echo "卸载 TUIC 服务..."
    systemctl stop tuic.service
    systemctl disable tuic.service
    rm -rf /etc/systemd/system/tuic.service
    rm -rf /usr/local/etc/tuic
    rm -rf /usr/local/bin/tuic
    echo "TUIC 服务已卸载..."
}

function Direct_install() {
    configure_dns64
    enable_bbr
    select_sing_box_install_option
    configure_sing_box_service
    check_sing_box_folder
    set_listen_port
    Direct_override_address
    Direct_override_port
    Direct_write_config_file
    check_firewall_configuration    
    systemctl enable sing-box   
    systemctl start sing-box
    Direct_extract_config_info
}

function Shadowsocks_install() {
    configure_dns64
    enable_bbr
    select_sing_box_install_option
    configure_sing_box_service
    check_sing_box_folder
    set_listen_port
    ss_encryption_method
    ss_write_sing_box_config
    check_firewall_configuration    
    systemctl enable sing-box   
    systemctl start sing-box
    Shadowsocks_extract_config_info
}

function NaiveProxy_install() {
    configure_dns64
    enable_bbr
    install_go
    install_caddy
    check_caddy_folder
    set_listen_port
    generate_caddy_auth_user
    generate_caddy_auth_pass
    get_caddy_fake_site
    get_caddy_domain    
    create_caddy_config
    check_firewall_configuration    
    test_caddy_config
    configure_caddy_service
    systemctl daemon-reload 
    systemctl enable caddy
    systemctl start caddy
    systemctl reload caddy
    NaiveProxy_extract_config_info
}

function tuic_install() {
    configure_dns64
    enable_bbr
    create_tuic_directory   
    download_tuic
    generate_tuic_config
    check_firewall_configuration 
    ask_certificate_option
    configure_tuic_service
    systemctl daemon-reload
    systemctl enable tuic.service
    systemctl start tuic.service
    systemctl restart tuic.service
    display_tuic_config
}

function Hysteria_install() {
    configure_dns64
    enable_bbr
    select_sing_box_install_option      
    check_sing_box_folder
    generate_Hysteria_config
    check_firewall_configuration 
    ask_certificate_option 
    configure_sing_box_service
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    display_Hysteria_config_info
}

function shadowtls_install() {
    configure_dns64
    enable_bbr
    select_sing_box_install_option      
    check_sing_box_folder
    configure_shadowtls_config_file
    check_firewall_configuration      
    configure_sing_box_service
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    display_shadowtls_config
}

function reality_install() {
    configure_dns64
    enable_bbr
    select_sing_box_install_option      
    check_sing_box_folder    
    generate_reality_config            
    configure_sing_box_service    
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    display_reality_config
}

function main_menu() {
        echo -e "${CYAN}               ------------------------------------------------------------------------------------ ${NC}"
        echo -e "${CYAN}               |                          欢迎使用 Mr. xiao 安装脚本                              |${NC}"
        echo -e "${CYAN}               |                      项目地址:https://github.com/TinrLin                         |${NC}"
        echo -e "${CYAN}               |                 YouTube频道地址:https://youtube.com/@Mr_xiao502                  |${NC}" 
        echo -e "${CYAN}               |                             转载请注明出处，谢谢！                               |${NC}"       
        echo -e "${CYAN}               ------------------------------------------------------------------------------------${NC}"
        echo -e "${CYAN}请选择要执行的操作：${NC}"
        echo -e "  ${CYAN}[01]. TUIC V5${NC}"         
        echo -e "  ${CYAN}[02]. Vless${NC}"
        echo -e "  ${CYAN}[03]. Direct${NC}" 
        echo -e "  ${CYAN}[04]. Hysteria${NC}"                   
        echo -e "  ${CYAN}[05]. ShadowTLS V3${NC}"
        echo -e "  ${CYAN}[06]. NaiveProxy${NC}"            
        echo -e "  ${CYAN}[07]. Shadowsocks${NC}"
        echo -e "  ${CYAN}[08]. 重启   TUIC   服务${NC}"
        echo -e "  ${CYAN}[09]. 重启   Caddy  服务${NC}"
        echo -e "  ${CYAN}[10]. 重启 sing-box 服务${NC}"
        echo -e "  ${CYAN}[11]. 卸载   TUIC   服务${NC}"
        echo -e "  ${CYAN}[12]. 卸载   Caddy  服务${NC}"
        echo -e "  ${CYAN}[13]. 卸载 sing-box 服务${NC}"
        echo -e "  ${CYAN}[00]. 退出脚本${NC}"

        local choice
        read -p "请选择 [0-13]: " choice

        case $choice in
            1)
                tuic_install
                ;;
            2)
                reality_install
                ;;
            3)
                Direct_install
                ;;
            4)
                Hysteria_install
                ;;
            5)
                shadowtls_install
                ;;
            6)
                NaiveProxy_install
                ;;
            7)
                Shadowsocks_install
                ;;                
            8)
                restart_tuic
                ;;

            9)
                restart_naiveproxy_service
                ;;
            10)
                restart_sing_box_service
                ;;
            11)
                uninstall_tuic
                ;;
            12)
                uninstall_naiveproxy
                ;;
            13)
                uninstall_sing_box
                ;;         
            0)
                echo "感谢使用 Mr. xiao 安装脚本！再见！"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择，请重新输入。${NC}"
                main_menu
                ;;
        esac
}

main_menu
