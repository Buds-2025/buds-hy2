#!/usr/bin/env bash
# ==============================================================================
# 项目名称: buds-hy2
# 官方仓库: https://github.com/Buds-2025/buds-hy2
# 功能说明: 适用于 Linux (Ubuntu/Debian/CentOS/Rocky/Alma/Fedora) 的通用 Hysteria 2 自动化部署与运维脚本
# ==============================================================================

set -eo pipefail

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
CLIENT_CONFIG_FILE="${CONFIG_DIR}/client.yaml"
HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
HOOK_FILE="${HOOK_DIR}/hysteria-sync.sh"
OVERRIDE_DIR="/etc/systemd/system/hysteria-server.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"
SERVICE_FILE="/etc/systemd/system/hysteria-server.service"
SYSCTL_FILE="/etc/sysctl.d/99-hysteria-performance.conf"
BUDS_CLI="/usr/local/bin/buds"
HY2_CLI="/usr/local/bin/hy2"

# 优雅终端色彩 · MiMo Code 极客调色盘
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_ORANGE="\033[38;5;208m"       # MiMo 标志性暖橙
C_ORANGE_BOLD="\033[1;38;5;208m"
C_AMBER="\033[38;5;215m"        # 柔和琥珀黄
C_SPARK="\033[38;5;222m"        # 星芒香槟金
C_WHITE="\033[38;5;254m"        # 珍珠白文本
C_GRAY_LIGHT="\033[38;5;250m"   # 亮灰文本
C_GRAY_MID="\033[38;5;244m"     # 哑光灰注释
C_GRAY_DARK="\033[38;5;238m"    # 极暗分界
C_GREEN="\033[38;5;114m"        # 薄荷绿
C_RED="\033[38;5;203m"          # 珊瑚红
C_CYAN="\033[38;5;153m"         # 冰青色
C_YELLOW="\033[38;5;221m"       # 浅金黄
C_BAR="${C_ORANGE_BOLD}▌${C_RESET}"
C_SUBBAR="${C_ORANGE}▎${C_RESET}"

info() { echo -e "  ${C_ORANGE_BOLD}❯${C_RESET} $*"; }
success() { echo -e "  ${C_GREEN}✔${C_RESET} $*"; }
warn() { echo -e "  ${C_AMBER}⚠${C_RESET} $*"; }
error() { echo -e "  ${C_RED}✖${C_RESET} $*"; }

check_root() {
    if [[ $(id -u) -ne 0 ]]; then
        error "请以 root 权限运行此脚本。"
        exit 1
    fi
}

detect_virtualization() {
    IS_CONTAINER=false
    IS_NAT=false
    VIRT_TYPE="native"

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    fi

    if [[ "$VIRT_TYPE" =~ ^(lxc|docker|podman|openvz|containerd|proot|systemd-nspawn)$ ]]; then
        IS_CONTAINER=true
    elif [[ -f /.dockerenv || -f /run/.containerenv ]]; then
        IS_CONTAINER=true
        VIRT_TYPE="container"
    elif [[ -f /proc/1/environ ]] && grep -qa -E "container=(lxc|docker|podman)" /proc/1/environ 2>/dev/null; then
        IS_CONTAINER=true
        VIRT_TYPE="lxc"
    elif [[ "$(hostname 2>/dev/null)" =~ ^lxd ]]; then
        IS_CONTAINER=true
        VIRT_TYPE="lxd"
    fi

    # 获取公网出口 IPv4
    PUBLIC_IP=$(curl -s4 --connect-timeout 2 https://api.ipify.org 2>/dev/null || \
                curl -s4 --connect-timeout 2 https://ip.sb 2>/dev/null || \
                curl -s4 --connect-timeout 2 https://icanhazip.com 2>/dev/null || \
                curl -s4 --connect-timeout 2 https://ifconfig.me 2>/dev/null || echo "")

    # 检测是否为 NAT 环境 (通过对比本机网络接口 IP 与公网出口 IP)
    if [[ -n "$PUBLIC_IP" ]]; then
        local local_ips
        local_ips=$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || \
                    ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' || \
                    hostname -I 2>/dev/null || echo "")
        if ! echo "$local_ips" | grep -qw "$PUBLIC_IP"; then
            IS_NAT=true
        fi
    fi
}

has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

has_openrc() {
    command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 &&
        command -v openrc-run >/dev/null 2>&1 && [[ -f /run/openrc/softlevel ]]
}

detect_init_system() {
    if has_systemd; then
        INIT_SYSTEM="systemd"
    elif has_openrc; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="other"
    fi
}

generate_random_string() {
    local length=${1:-16}
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$length"
    elif [[ -r /dev/urandom ]]; then
        head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "$length" 2>/dev/null || true
    else
        awk -v len="$length" 'BEGIN{srand(); chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"; for(i=1;i<=len;i++) s=s substr(chars, int(rand()*length(chars)+1), 1); print s}'
    fi
}

check_port_available() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        if ss -ulpn 2>/dev/null | grep -E ":${port}\b" | grep -qv "hysteria"; then
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -ulpn 2>/dev/null | grep -E ":${port}\b" | grep -qv "hysteria"; then
            return 1
        fi
    fi
    return 0
}

generate_random_port() {
    local port
    local attempts=0
    while (( attempts < 100 )); do
        if command -v shuf >/dev/null 2>&1; then
            port=$(shuf -i 20000-50000 -n 1)
        else
            port=$(awk -v min=20000 -v max=50000 'BEGIN{srand(); print int(min+rand()*(max-min+1))}')
        fi
        if check_port_available "$port"; then
            echo "$port"
            return 0
        fi
        (( attempts++ ))
    done
    echo "38443"
}

install_dependencies() {
    info "检测并安装必要依赖组件..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y -qq curl wget openssl ufw certbot python3-certbot-nginx ca-certificates iptables iproute2 dnsutils libcap2-bin >/dev/null 2>&1 || \
        apt-get install -y -qq curl wget openssl ca-certificates iptables iproute2 dnsutils >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        # Alpine Linux 适配
        if [[ -f /etc/apk/repositories ]]; then
            sed -i 's/^#\(.*\/community\)/\1/' /etc/apk/repositories
        fi
        apk update >/dev/null 2>&1 || true
        apk add --no-cache curl wget openssl ca-certificates iptables iproute2 bind-tools certbot libcap shadow tzdata >/dev/null 2>&1 || \
        apk add --no-cache curl wget openssl ca-certificates >/dev/null 2>&1 || true
        if ! apk add --no-cache certbot-nginx >/dev/null 2>&1; then
            apk add --no-cache py3-pip >/dev/null 2>&1 || true
            pip install certbot-nginx --break-system-packages >/dev/null 2>&1 || true
        fi
        if command -v rc-update >/dev/null 2>&1; then
            rc-update add crond default >/dev/null 2>&1 || true
            rc-service crond start >/dev/null 2>&1 || true
        fi
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q epel-release || true
        dnf install -y -q curl wget openssl certbot python3-certbot-nginx ca-certificates iptables iproute bind-utils libcap >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q epel-release || true
        yum install -y -q curl wget openssl certbot python3-certbot-nginx ca-certificates iptables iproute bind-utils libcap >/dev/null 2>&1 || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl wget openssl certbot certbot-nginx ca-certificates iptables iproute2 bind-tools libcap >/dev/null 2>&1 || true
    else
        warn "未识别到主流包管理器，尝试继续使用现有系统环境。"
    fi

    # 兜底检测: 确保 certbot 可用
    HAVE_CERTBOT=true
    if ! command -v certbot >/dev/null 2>&1; then
        if command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1; then
            info "尝试通过 Python pip 安装 Certbot..."
            pip install certbot certbot-nginx --break-system-packages >/dev/null 2>&1 || pip3 install certbot certbot-nginx >/dev/null 2>&1 || true
        fi
    fi

    if ! command -v certbot >/dev/null 2>&1; then
        HAVE_CERTBOT=false
        warn "系统未安装 certbot 工具 (若申请 Let's Encrypt 官方证书需此工具；若使用自签名证书则不受影响)。"
    fi

    success "基础依赖环境准备完毕。"
}

validate_domain() {
    info "正在校验域名解析..."
    local server_ip="${PUBLIC_IP}"
    if [[ -z "$server_ip" ]]; then
        server_ip=$(curl -s4 --connect-timeout 3 https://api.ipify.org 2>/dev/null || \
                    curl -s4 --connect-timeout 3 https://ip.sb 2>/dev/null || \
                    curl -s4 --connect-timeout 3 https://icanhazip.com 2>/dev/null || \
                    curl -s4 --connect-timeout 3 https://ifconfig.me 2>/dev/null || echo "")
    fi
    
    local resolved_ip=""
    if command -v getent >/dev/null 2>&1; then
        resolved_ip=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | head -n1 | awk '{print $1}')
    elif command -v nslookup >/dev/null 2>&1; then
        resolved_ip=$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: / { print $2 }' | tail -n1)
    elif command -v dig >/dev/null 2>&1; then
        resolved_ip=$(dig +short "$DOMAIN" 2>/dev/null | head -n1)
    elif command -v host >/dev/null 2>&1; then
        resolved_ip=$(host "$DOMAIN" 2>/dev/null | awk '/has address/ { print $4 }' | head -n1)
    fi

    if [[ -n "$server_ip" && -n "$resolved_ip" ]]; then
        if [[ "$server_ip" != "$resolved_ip" ]]; then
            warn "域名解析 IP (${resolved_ip}) 与本机公网 IP (${server_ip}) 不一致！"
            warn "提示: 若申请 Let's Encrypt 证书可能会失败；若使用自签名证书则不受影响。"
            read -rp "是否仍然继续？(y/N) [默认 y]: " force_continue
            force_continue="${force_continue:-y}"
            if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
                error "已取消安装，请待 DNS 解析生效后再运行。"
                exit 1
            fi
        else
            success "域名解析校验正常 (${DOMAIN} -> ${server_ip})。"
        fi
    else
        info "已配置域名: ${C_CYAN}${DOMAIN}${C_RESET}。"
    fi
}

normalize_ports() {
    local input="$1" minimum="${2:-1}" first last
    if [[ "$input" =~ ^([0-9]{1,5})([:\-]([0-9]{1,5}))?$ ]]; then
        first=$((10#${BASH_REMATCH[1]}))
        last="$first"
        [[ -z "${BASH_REMATCH[3]}" ]] || last=$((10#${BASH_REMATCH[3]}))
        if (( first >= minimum && last <= 65535 && first <= last )); then
            if [[ -n "${BASH_REMATCH[3]}" ]]; then
                (( first < last )) || return 1
                echo "${first}-${last}"
            else
                echo "$first"
            fi
            return 0
        fi
    fi
    return 1
}

collect_parameters() {
    echo -e "\n  ${C_BAR}  ${C_WHITE}buds-hy2 · Hysteria 2 节点配置引导${C_RESET}\n"

    while true; do
        read -rp "$(echo -e "${C_BOLD}请输入已解析到本机 IP 的域名 (例如 your.domain.com): ${C_RESET}")" DOMAIN
        DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]')
        if [[ -n "$DOMAIN" ]]; then
            break
        fi
        error "域名不能为空，请输入有效域名！"
    done
    info "配置域名: ${C_CYAN}${DOMAIN}${C_RESET}"

    validate_domain

    DEFAULT_RANDOM_PORT=$(generate_random_port)
    echo -e "\n${C_BOLD}端口配置支持以下格式：${C_RESET}"
    echo -e "  - ${C_GRAY}直接回车${C_RESET} : 随机高位单端口 (如 ${C_CYAN}${DEFAULT_RANDOM_PORT}${C_RESET})"
    echo -e "  - ${C_GRAY}指定单端口${C_RESET}: 输入具体端口号 (如 ${C_CYAN}38443${C_RESET})"
    echo -e "  - ${C_GRAY}端口跳跃${C_RESET}  : 输入端口范围 (如 ${C_CYAN}28965:49652${C_RESET} 或 ${C_CYAN}28965-49652${C_RESET})"

    while true; do
        read -rp "$(echo -e "${C_BOLD}请输入监听端口 [默认: ${DEFAULT_RANDOM_PORT}]: ${C_RESET}")" INPUT_PORT
        INPUT_PORT="${INPUT_PORT:-$DEFAULT_RANDOM_PORT}"
        INPUT_PORT=$(echo "$INPUT_PORT" | tr -d '[:space:]')
        if ! INPUT_PORT=$(normalize_ports "$INPUT_PORT" 1024); then
            error "端口应为 1024~65535 的单端口或递增范围，请重新输入！"
            continue
        fi

        if [[ "$INPUT_PORT" =~ ^([0-9]+)[:\-]([0-9]+)$ ]]; then
            local hop_start="${BASH_REMATCH[1]}"
            local hop_end="${BASH_REMATCH[2]}"
            IS_PORT_HOPPING=true
            HOP_START="$hop_start"
            HOP_END="$hop_end"
            LISTEN_STR=":${HOP_START}-${HOP_END}"
            UFW_PORT_RULE="${HOP_START}:${HOP_END}/udp"
            BASE_PORT="$HOP_START"
            CLIENT_PORT_STR="${HOP_START}-${HOP_END}"
            info "已选择端口跳跃: ${C_CYAN}${HOP_START} 至 ${HOP_END}${C_RESET} (基准监听端口: ${BASE_PORT})"
            break
        else
            local single_port="$INPUT_PORT"
            if ! check_port_available "$single_port"; then
                warn "UDP 端口 ${single_port} 目前已被其他进程占用！"
                read -rp "是否仍然强制使用该端口？(y/N) [默认 N]: " force_use
                if [[ ! "$force_use" =~ ^[Yy]$ ]]; then
                    continue
                fi
            fi
            IS_PORT_HOPPING=false
            SINGLE_PORT="$single_port"
            LISTEN_STR=":${SINGLE_PORT}"
            UFW_PORT_RULE="${SINGLE_PORT}/udp"
            BASE_PORT="$SINGLE_PORT"
            CLIENT_PORT_STR="${SINGLE_PORT}"
            info "已选择单端口: ${C_CYAN}${SINGLE_PORT}${C_RESET}"
            break
        fi
    done

    if [[ "$IS_NAT" == "true" || "$IS_CONTAINER" == "true" ]]; then
        local public_input public_default="$CLIENT_PORT_STR"
        while true; do
            read -rp "公网 UDP 连接端口/范围 [默认: ${public_default}，与监听相同直接回车]: " public_input
            public_input=$(echo "${public_input:-$public_default}" | tr -d '[:space:]')
            if CLIENT_PORT_STR=$(normalize_ports "$public_input"); then
                break
            fi
            error "公网端口应为 1~65535 的单端口或递增范围，请重新输入！"
        done
        info "请在服务商面板将公网 UDP ${CLIENT_PORT_STR} 映射到本机监听 ${LISTEN_STR#:}。"
    fi

    AUTH_PASSWORD="Hy2Pass_$(generate_random_string 12)"
    OBFS_PASSWORD="Obfs_$(generate_random_string 12)"
}

is_nginx_running() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] && systemctl is-active --quiet nginx 2>/dev/null; then
        return 0
    elif has_openrc && rc-service nginx status 2>/dev/null | grep -q "started"; then
        return 0
    elif command -v pidof >/dev/null 2>&1 && pidof nginx >/dev/null 2>&1; then
        return 0
    elif pgrep -f "nginx" >/dev/null 2>&1; then
        return 0
    elif ps aux 2>/dev/null | grep -E "nginx(:| )" | grep -v grep >/dev/null 2>&1; then
        return 0
    elif (command -v ss >/dev/null 2>&1 && ss -tlpn 2>/dev/null | grep -E ':(80|http)\b' | grep -q nginx) || \
         (command -v netstat >/dev/null 2>&1 && netstat -tlpn 2>/dev/null | grep -E ':(80|http)\b' | grep -q nginx); then
        return 0
    fi
    return 1
}

is_port_80_listening() {
    if command -v ss >/dev/null 2>&1 && ss -tlpn 2>/dev/null | grep -qE ':(80|http)\b'; then
        return 0
    elif command -v netstat >/dev/null 2>&1 && netstat -tlpn 2>/dev/null | grep -qE ':(80|http)\b'; then
        return 0
    elif command -v fuser >/dev/null 2>&1 && fuser 80/tcp >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

find_nginx_webroot() {
    local root_dir=""
    root_dir=$(grep -h -E '^[[:space:]]*root[[:space:]]+' /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf /etc/nginx/http.d/*.conf 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';')
    if [[ -n "$root_dir" && -d "$root_dir" ]]; then
        echo "$root_dir"
        return
    fi
    for candidate in "/var/lib/nginx/html" "/usr/share/nginx/html" "/var/www/localhost/htdocs" "/var/www/html" "/var/www"; do
        if [[ -d "$candidate" ]]; then
            echo "$candidate"
            return
        fi
    done
    echo ""
}

is_cert_self_signed() {
    if [[ -f "${CONFIG_DIR}/server.crt" ]]; then
        local issuer subject
        issuer=$(openssl x509 -in "${CONFIG_DIR}/server.crt" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=[[:space:]]*//' || true)
        subject=$(openssl x509 -in "${CONFIG_DIR}/server.crt" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=[[:space:]]*//' || true)
        if [[ -n "$issuer" && "$issuer" == "$subject" ]]; then
            return 0
        fi
    fi
    return 1
}

generate_self_signed_cert() {
    local domain="$1"
    info "正在为域名 ${C_CYAN}${domain}${C_RESET} 生成高性能 ECC 自签名证书..."
    mkdir -p "$CONFIG_DIR"
    
    openssl ecparam -name prime256v1 -genkey -noout -out "${CONFIG_DIR}/server.key" 2>/dev/null || \
    openssl genrsa -out "${CONFIG_DIR}/server.key" 2048 2>/dev/null

    openssl req -new -x509 -days 36500 \
        -key "${CONFIG_DIR}/server.key" \
        -out "${CONFIG_DIR}/server.crt" \
        -subj "/CN=${domain}" \
        -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1 || \
    openssl req -new -x509 -days 36500 \
        -key "${CONFIG_DIR}/server.key" \
        -out "${CONFIG_DIR}/server.crt" \
        -subj "/CN=${domain}" >/dev/null 2>&1

    if id hysteria >/dev/null 2>&1; then
        chown root:hysteria "${CONFIG_DIR}/server.crt" "${CONFIG_DIR}/server.key" 2>/dev/null || true
    fi
    chmod 640 "${CONFIG_DIR}/server.crt" "${CONFIG_DIR}/server.key"
    success "自签名证书生成完毕 (ECC-P256 算法，有效期 100 年，全客户端通用免维护)。"
}

setup_certificates() {
    info "配置 SSL 证书..."

    mkdir -p "$CONFIG_DIR" "$HOOK_DIR"

    local default_mode="1"
    if [[ "$IS_NAT" == "true" || "$IS_CONTAINER" == "true" || "$HAVE_CERTBOT" != "true" ]]; then
        default_mode="2"
        warn "检测到当前处于 NAT / 容器虚拟化环境或未预装 Certbot。"
        info "提示: 容器/NAT 环境通常未直接映射外部 80 端口，默认推荐使用【选项 2】极速自签名证书。"
    fi

    echo -e "\n  ${C_SUBBAR}  ${C_WHITE}请选择 SSL 证书申请模式:${C_RESET}"
    echo -e "     ${C_ORANGE_BOLD}1.${C_RESET} ${C_WHITE}Let's Encrypt 官方权威证书${C_RESET} ${C_GRAY_MID}(需要公网 80 端口直接通达本机，支持现有网站零停机)${C_RESET}"
    echo -e "     ${C_ORANGE_BOLD}2.${C_RESET} ${C_WHITE}极速自签名 ECC 证书${C_RESET}        ${C_GRAY_MID}(无需 80 端口，专为 NAT VPS / LXD 容器 / 端口受限环境定制)${C_RESET}"
    
    local CERT_MODE
    if [[ "$default_mode" == "2" ]]; then
        read -rp "$(echo -e "  ${C_ORANGE_BOLD}❯${C_RESET} ${C_WHITE}请选择证书模式 [默认: 2 (NAT容器推荐)]: ${C_RESET}")" CERT_MODE
        CERT_MODE="${CERT_MODE:-2}"
    else
        read -rp "$(echo -e "  ${C_ORANGE_BOLD}❯${C_RESET} ${C_WHITE}请选择证书模式 [默认: 1]: ${C_RESET}")" CERT_MODE
        CERT_MODE="${CERT_MODE:-1}"
    fi

    if [[ "$CERT_MODE" == "2" ]]; then
        generate_self_signed_cert "$DOMAIN"
        return 0
    fi

    if [[ "$HAVE_CERTBOT" != "true" ]]; then
        warn "未检测到 certbot，无法申请 Let's Encrypt 证书，自动切换为极速自签名证书..."
        generate_self_signed_cert "$DOMAIN"
        return 0
    fi

    if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
        add_ufw_rule 80/tcp
    fi

    local cert_success=false
    local has_nginx=false
    if is_nginx_running; then
        has_nginx=true
    fi

    # 方案 1: 若检测到 Nginx，优先尝试 --nginx 插件 (零停机)
    if [[ "$has_nginx" == "true" ]]; then
        info "检测到运行中的 Nginx，尝试使用 --nginx 插件进行零停机证书申领..."
        if certbot certonly --nginx \
            -d "$DOMAIN" \
            --agree-tos \
            --register-unsafely-without-email \
            --keep-until-expiring \
            --non-interactive 2>/dev/null; then
            cert_success=true
        fi

        # 方案 2: 若 --nginx 插件未成功，尝试通过 --webroot 模式验证
        if [[ "$cert_success" != "true" ]]; then
            local webroot
            webroot=$(find_nginx_webroot)
            if [[ -n "$webroot" ]]; then
                info "尝试使用 Nginx 网站根目录 (${webroot}) 进行 --webroot 验证..."
                if certbot certonly --webroot -w "$webroot" \
                    -d "$DOMAIN" \
                    --agree-tos \
                    --register-unsafely-without-email \
                    --keep-until-expiring \
                    --non-interactive 2>/dev/null; then
                    cert_success=true
                fi
            fi
        fi

    elif ! is_port_80_listening; then
        info "使用 --standalone 独立模式申请证书..."
        if certbot certonly --standalone \
            -d "$DOMAIN" \
            --agree-tos \
            --register-unsafely-without-email \
            --keep-until-expiring \
            --non-interactive; then
            cert_success=true
        fi
    else
        warn "80 端口已被其他服务占用，保留现有服务，改用自签名证书。"
    fi

    if [[ "$cert_success" != "true" ]]; then
        warn "Let's Encrypt 证书验证未通过 (常见于 NAT VPS、容器网络受限、80 端口被拦截或未映射)。"
        info "自动切换为自签名 ECC 证书继续完成节点部署 (全客户端通用免维护)..."
        generate_self_signed_cert "$DOMAIN"
        return 0
    fi

    mkdir -p "$CONFIG_DIR" "$HOOK_DIR"

    cat <<EOF > "$HOOK_FILE"
#!/usr/bin/env bash
set -e
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    mkdir -p "${CONFIG_DIR}"
    cp -L "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${CONFIG_DIR}/server.crt"
    cp -L "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "${CONFIG_DIR}/server.key"
    if id hysteria >/dev/null 2>&1; then
        chown root:hysteria "${CONFIG_DIR}/server.crt" "${CONFIG_DIR}/server.key" 2>/dev/null || true
    fi
    chmod 640 "${CONFIG_DIR}/server.crt" "${CONFIG_DIR}/server.key"
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] && systemctl is-active --quiet hysteria-server 2>/dev/null; then
        systemctl restart hysteria-server
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 && command -v openrc-run >/dev/null 2>&1 && [[ -f /run/openrc/softlevel ]] && rc-service hysteria-server status >/dev/null 2>&1; then
        rc-service hysteria-server restart
    elif [[ -x /usr/local/bin/hysteria-service ]]; then
        /usr/local/bin/hysteria-service restart
    elif pgrep -f "hysteria (server|-c)" >/dev/null 2>&1; then
        pkill -f "hysteria server" 2>/dev/null || true
        nohup /usr/local/bin/hysteria server -c "${CONFIG_FILE}" >/var/log/hysteria.log 2>&1 &
    fi
fi
EOF
    chmod +x "$HOOK_FILE"
    "$HOOK_FILE"

    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        mkdir -p /etc/periodic/daily
        cat <<'CRON_EOF' > /etc/periodic/daily/certbot-renew
#!/bin/sh
certbot renew --quiet --run-deploy-hooks
CRON_EOF
        chmod +x /etc/periodic/daily/certbot-renew
    fi

    success "SSL 证书部署完成，已挂载自动续期同步钩子。"
}

install_official_core() {
    info "安装官方 Hysteria 2 主程序..."
    local installed=false

    if [[ "$INIT_SYSTEM" == "systemd" && ! -f /etc/alpine-release && "$IS_CONTAINER" != "true" ]]; then
        if bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1; then
            if [[ -x /usr/local/bin/hysteria ]] && /usr/local/bin/hysteria version >/dev/null 2>&1; then
                installed=true
            fi
        fi
    fi

    if [[ "$installed" != "true" || ! -x /usr/local/bin/hysteria ]]; then
        info "正在直接拉取官方静态编译内核 (兼容各发行版 glibc 与 musl)..."
        local arch
        arch=$(uname -m)
        local binary_name=""
        case "$arch" in
            x86_64|amd64) binary_name="hysteria-linux-amd64" ;;
            aarch64|arm64) binary_name="hysteria-linux-arm64" ;;
            armv7*|armhf) binary_name="hysteria-linux-arm" ;;
            i386|i686) binary_name="hysteria-linux-386" ;;
            s390x) binary_name="hysteria-linux-s390x" ;;
            mipsle) binary_name="hysteria-linux-mipsle" ;;
            *) binary_name="hysteria-linux-amd64" ;;
        esac

        mkdir -p /usr/local/bin
        local download_urls=(
            "https://github.com/apernet/hysteria/releases/latest/download/${binary_name}"
            "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/${binary_name}"
            "https://download.hysteria.network/app/latest/${binary_name}"
        )
        local temp_bin="/tmp/hysteria_bin_${RANDOM}"
        for url in "${download_urls[@]}"; do
            info "尝试从 ${url} 下载内核..."
            rm -f "$temp_bin"
            if curl -fsSL --connect-timeout 8 --max-time 120 --retry 2 "$url" -o "$temp_bin"; then
                # 校验是否为合法 ELF 二进制文件 (ELF 文件头 4 字节为 \x7fELF)
                local magic
                magic=$(head -c 4 "$temp_bin" 2>/dev/null || true)
                if [[ "$magic" == $'\x7fELF' ]]; then
                    mv -f "$temp_bin" /usr/local/bin/hysteria
                    chmod 755 /usr/local/bin/hysteria
                    installed=true
                    break
                else
                    warn "从 ${url} 获取的文件非有效 ELF 二进制 (可能为拦截页面或网络限制)，尝试下一个镜像源..."
                    rm -f "$temp_bin"
                fi
            fi
        done
        rm -f "$temp_bin"
    fi

    if [[ ! -x /usr/local/bin/hysteria ]]; then
        error "Hysteria 2 主程序下载失败，请检查服务器网络连接。"
        exit 1
    fi

    if ! /usr/local/bin/hysteria version >/dev/null 2>&1; then
        error "Hysteria 2 二进制文件在当前系统架构下无法执行，请确认系统环境。"
        exit 1
    fi

    if command -v setcap >/dev/null 2>&1; then
        setcap 'cap_net_bind_service,cap_net_admin,cap_net_raw=+ep' /usr/local/bin/hysteria >/dev/null 2>&1 || true
    fi
    success "Hysteria 2 内核安装完成 ($(/usr/local/bin/hysteria version 2>/dev/null | head -1 || echo '已就绪'))。"
}

generate_server_config() {
    info "写入服务端安全加固与极致性能配置..."
    cat <<EOF > "$CONFIG_FILE"
listen: ${LISTEN_STR}

tls:
  cert: ${CONFIG_DIR}/server.crt
  key: ${CONFIG_DIR}/server.key

auth:
  type: password
  password: "${AUTH_PASSWORD}"

obfs:
  type: salamander
  salamander:
    password: "${OBFS_PASSWORD}"

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 41943040
  maxConnReceiveWindow: 41943040

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
EOF

    # 确保 hysteria 服务专属用户存在
    if ! id hysteria >/dev/null 2>&1; then
        if command -v useradd >/dev/null 2>&1; then
            useradd -r -s /sbin/nologin hysteria >/dev/null 2>&1 || true
        elif command -v adduser >/dev/null 2>&1; then
            adduser -S -D -H -s /sbin/nologin hysteria >/dev/null 2>&1 || true
        fi
    fi

    if id hysteria >/dev/null 2>&1; then
        chown -R root:hysteria "$CONFIG_DIR" 2>/dev/null || true
        chmod 750 "$CONFIG_DIR"
        chmod 640 "$CONFIG_FILE"
        success "服务端配置文件写入完毕 (权限 640，归属 root:hysteria)。"
    else
        chown -R root:root "$CONFIG_DIR" 2>/dev/null || true
        chmod 700 "$CONFIG_DIR"
        chmod 600 "$CONFIG_FILE"
        success "服务端配置文件写入完毕 (权限 600，归属 root:root)。"
    fi
}

tune_kernel_network() {
    info "优化系统内核网络栈与 64MB UDP 缓冲区..."

    # 容器环境或只读 proc 检测
    if [[ "$IS_CONTAINER" == "true" || ! -w /proc/sys/net/core/rmem_max ]]; then
        info "检测到容器虚拟化环境或内核参数受限，跳过底层内核网络栈修改 (保持容器兼容性)。"
        return 0
    fi

    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe sch_fq >/dev/null 2>&1 || true

    if [[ -f /etc/modules ]] && ! grep -q "^tcp_bbr" /etc/modules 2>/dev/null; then
        echo "tcp_bbr" >> /etc/modules 2>/dev/null || true
    fi
    if [[ -f /etc/modules ]] && ! grep -q "^sch_fq" /etc/modules 2>/dev/null; then
        echo "sch_fq" >> /etc/modules 2>/dev/null || true
    fi

    mkdir -p /etc/sysctl.d
    cat <<EOF > "$SYSCTL_FILE"
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=67108864
net.core.wmem_default=67108864
net.core.optmem_max=67108864
net.core.netdev_max_backlog=100000
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.all.rp_filter=2
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
    success "内核网络栈调优已生效 (64MB UDP 缓冲区 + BBR 拥塞控制)。"
}

configure_service() {
    info "设置服务守护进程与高可用自愈..."
    
    if command -v setcap >/dev/null 2>&1 && [[ -f /usr/local/bin/hysteria ]]; then
        setcap cap_net_bind_service,cap_net_admin,cap_net_raw=+ep /usr/local/bin/hysteria >/dev/null 2>&1 || true
    fi

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        mkdir -p "$(dirname "$SERVICE_FILE")" "$OVERRIDE_DIR"
        local service_user="root"
        if id hysteria >/dev/null 2>&1; then
            service_user="hysteria"
        fi
        cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Hysteria 2 Server Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config ${CONFIG_FILE}
WorkingDirectory=${CONFIG_DIR}
User=${service_user}
Group=${service_user}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
        cat <<EOF > "$OVERRIDE_FILE"
[Service]
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF
        systemctl daemon-reload
        success "systemd 自动重启与并发限制配置生效 (崩溃 3 秒自愈 + 104 万描述符)。"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        cat <<'INIT_EOF' > /etc/init.d/hysteria-server
#!/sbin/openrc-run
supervisor="supervise-daemon"
name="hysteria-server"
description="Hysteria 2 Server Service"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
capabilities="^cap_net_bind_service,^cap_net_admin"
respawn_delay=2
respawn_max=0

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0750 /etc/hysteria
    if [ ! -f /etc/hysteria/config.yaml ]; then
        eerror "Config file /etc/hysteria/config.yaml not found!"
        return 1
    fi
    touch /var/log/hysteria.log
    chmod 640 /var/log/hysteria.log
}
INIT_EOF
        chmod 755 /etc/init.d/hysteria-server
        rc-update add hysteria-server default >/dev/null 2>&1 || true
        success "OpenRC 守护服务已配置并设为开机自启 (崩溃自动重启)。"
    else
        # 容器 / 极简环境轻量服务管理包装器
        cat <<'RUNNER_EOF' > /usr/local/bin/hysteria-service
#!/usr/bin/env bash
case "$1" in
    start)
        if pgrep -f "hysteria (server|-c)" >/dev/null 2>&1; then
            echo "hysteria-server 正在运行。"
        else
            nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml >/var/log/hysteria.log 2>&1 &
            sleep 1
            if pgrep -f "hysteria (server|-c)" >/dev/null 2>&1; then
                echo "hysteria-server 启动成功。"
            fi
        fi
        ;;
    stop)
        pkill -f "hysteria server" 2>/dev/null || true
        echo "hysteria-server 已停止。"
        ;;
    restart)
        pkill -f "hysteria server" 2>/dev/null || true
        sleep 1
        nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml >/var/log/hysteria.log 2>&1 &
        sleep 1
        echo "hysteria-server 重启完成。"
        ;;
    status)
        if pgrep -f "hysteria (server|-c)" >/dev/null 2>&1; then
            echo "hysteria-server 正在运行。"
        else
            echo "hysteria-server 已停止。"
        fi
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
RUNNER_EOF
        chmod 755 /usr/local/bin/hysteria-service
        if [[ -f /etc/rc.local ]] && ! grep -q "hysteria-service" /etc/rc.local; then
            sed -i '/^exit 0/i /usr/local/bin/hysteria-service start' /etc/rc.local 2>/dev/null || true
        fi
        success "轻量进程服务管理器已配置 (/usr/local/bin/hysteria-service)。"
    fi
}

record_firewall_rule() {
    # 仅记录本次成功新增的规则：后端|区域/链|运行时/永久|端口协议。
    (umask 077; printf '%s|%s|%s|%s\n' "$@" >> "${CONFIG_DIR}/.firewall_rule")
    chmod 600 "${CONFIG_DIR}/.firewall_rule"
}

add_ufw_rule() {
    local rule="$1" rules
    if ! rules=$(LC_ALL=C ufw status 2>/dev/null); then
        warn "无法读取 UFW 规则，未自动修改 ${rule}。"
        return 0
    fi
    if echo "$rules" | awk -v rule="$rule" '$1==rule && $2=="ALLOW" {found=1} END {exit !found}'; then
        return 0
    fi
    if ufw allow "$rule" comment 'buds-hy2' >/dev/null 2>&1; then
        record_firewall_rule ufw - runtime "$rule"
    else
        warn "UFW 放行 ${rule} 失败，请在服务器或服务商面板检查。"
    fi
}

configure_firewall() {
    info "配置防火墙端口规则: ${UFW_PORT_RULE}..."
    if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
        add_ufw_rule "$UFW_PORT_RULE"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        local zone rule mode result
        zone=$(firewall-cmd --get-default-zone) || return 1
        rule="${UFW_PORT_RULE//:/-}"
        for mode in runtime permanent; do
            local options=(--zone="$zone")
            [[ "$mode" != permanent ]] || options+=(--permanent)
            if firewall-cmd "${options[@]}" --query-port="$rule" >/dev/null 2>&1; then
                continue
            else
                result=$?
            fi
            if [[ "$result" == 1 ]] && firewall-cmd "${options[@]}" --add-port="$rule" >/dev/null 2>&1; then
                record_firewall_rule firewalld "$zone" "$mode" "$rule"
            else
                warn "firewalld ${mode} 放行 ${rule} 失败，请检查防火墙权限。"
            fi
        done
    elif command -v iptables >/dev/null 2>&1; then
        local port="${UFW_PORT_RULE%/*}" result
        if iptables -C INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 ||
           iptables -C INPUT -p udp --dport "$port" -m comment --comment buds-hy2 -j ACCEPT >/dev/null 2>&1; then
            return 0
        else
            result=$?
        fi
        if [[ "$result" == 1 ]] && iptables -I INPUT -p udp --dport "$port" -m comment --comment buds-hy2 -j ACCEPT >/dev/null 2>&1; then
            record_firewall_rule iptables INPUT runtime "$UFW_PORT_RULE"
            if [[ -x /etc/init.d/iptables ]]; then
                /etc/init.d/iptables save >/dev/null 2>&1 || true
                rc-update add iptables default >/dev/null 2>&1 || true
            fi
        else
            warn "当前环境无法自动放行 UDP ${UFW_PORT_RULE}，请在服务器或服务商面板检查。"
        fi
    else
        info "未检测到可管理的防火墙，请确保服务商已放行 UDP ${UFW_PORT_RULE}。"
    fi
}

start_service() {
    info "启动 Hysteria 2 服务..."
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now hysteria-server
        sleep 2

        if systemctl is-active --quiet hysteria-server; then
            success "Hysteria 2 服务已正常运行。"
        else
            error "服务未能正常启动，请查看日志："
            journalctl -u hysteria-server -n 20 --no-pager
            exit 1
        fi
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service hysteria-server restart
        sleep 2
        if rc-service hysteria-server status | grep -q "started"; then
            success "Hysteria 2 服务已正常运行 (OpenRC)。"
        else
            error "服务未能正常启动，请查看日志："
            tail -n 20 /var/log/hysteria.log 2>/dev/null || true
            exit 1
        fi
    elif [[ -x /usr/local/bin/hysteria-service ]]; then
        /usr/local/bin/hysteria-service restart
        sleep 2
        if pgrep -f "hysteria (server|-c)" >/dev/null 2>&1; then
            success "Hysteria 2 服务已正常运行。"
        else
            error "服务未能正常启动，请查看日志: cat /var/log/hysteria.log"
            exit 1
        fi
    else
        pkill -f "hysteria server" >/dev/null 2>&1 || true
        nohup /usr/local/bin/hysteria server -c "$CONFIG_FILE" >/var/log/hysteria.log 2>&1 &
        sleep 2
        if pgrep -f "hysteria (server|-c)" >/dev/null 2>&1; then
            success "Hysteria 2 服务已正常运行。"
        else
            error "服务未能正常启动，请查看日志: cat /var/log/hysteria.log"
            exit 1
        fi
    fi
}

setup_cli() {
    local client_insecure="false"
    if is_cert_self_signed; then
        client_insecure="true"
    fi

    printf '%s\n' "$CLIENT_PORT_STR" > "${CONFIG_DIR}/.public_port"
    chmod 600 "${CONFIG_DIR}/.public_port"

    cat <<EOF > "$CLIENT_CONFIG_FILE"
server: ${DOMAIN}:${CLIENT_PORT_STR}
auth: "${AUTH_PASSWORD}"
tls:
  sni: ${DOMAIN}
  insecure: ${client_insecure}
obfs:
  type: salamander
  salamander:
    password: "${OBFS_PASSWORD}"
bandwidth:
  up: 100 mbps
  down: 300 mbps
EOF
    chown root:root "$CLIENT_CONFIG_FILE" 2>/dev/null || true
    chmod 600 "$CLIENT_CONFIG_FILE"

    # 生成极客优雅的全局管理命令 /usr/local/bin/buds
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [[ -f "${script_dir}/buds" ]]; then
        cp -f "${script_dir}/buds" "$BUDS_CLI"
    else
        cat <<'EOF' > "$BUDS_CLI"
#!/usr/bin/env bash
set -e

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
CLIENT_CONFIG_FILE="${CONFIG_DIR}/client.yaml"

# 优雅终端色彩 · MiMo Code 极客调色盘
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_ORANGE="\033[38;5;208m"       # MiMo 标志性暖橙
C_ORANGE_BOLD="\033[1;38;5;208m"
C_AMBER="\033[38;5;215m"        # 柔和琥珀黄
C_SPARK="\033[38;5;222m"        # 星芒香槟金
C_WHITE="\033[38;5;254m"        # 珍珠白文本
C_GRAY_LIGHT="\033[38;5;250m"   # 亮灰文本
C_GRAY_MID="\033[38;5;244m"     # 哑光灰注释
C_GRAY_DARK="\033[38;5;238m"    # 极暗分界
C_GREEN="\033[38;5;114m"        # 薄荷绿 (运行中)
C_RED="\033[38;5;203m"          # 珊瑚红 (已停止)
C_CYAN="\033[38;5;153m"         # 冰青色 (端口/参数)
C_YELLOW="\033[38;5;221m"       # 浅金黄 (链接)
C_BAR="${C_ORANGE_BOLD}▌${C_RESET}"
C_SUBBAR="${C_ORANGE}▎${C_RESET}"

if [[ "$1" == "hy2" ]]; then
    shift
fi

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\n  ${C_RED}✖ 请以 root 权限运行此命令 (例如: sudo buds hy2)${C_RESET}\n"
        exit 1
    fi
}

get_domain() {
    local domain=""
    if [[ -f "$CLIENT_CONFIG_FILE" ]]; then
        domain=$(awk -F': *' '/^[[:space:]]*sni:/ {gsub(/^["'\'' ]+|["'\'' \r]+$/, "", $2); print $2; exit}' "$CLIENT_CONFIG_FILE" 2>/dev/null)
    fi
    if [[ -z "$domain" ]]; then
        domain=$(grep -o 'live/[^/]*' /etc/letsencrypt/renewal-hooks/deploy/hysteria-sync.sh 2>/dev/null | cut -d'/' -f2 | head -1)
    fi
    if [[ -z "$domain" && -f "${CONFIG_DIR}/server.crt" ]]; then
        domain=$(openssl x509 -in "${CONFIG_DIR}/server.crt" -noout -subject -nameopt RFC2253 2>/dev/null |
            sed -n 's/^subject=.*CN=\([^,]*\).*$/\1/p' || true)
    fi
    [[ -z "$domain" ]] && domain="your.domain.com"
    echo "$domain"
}

get_password() {
    local pwd=""
    if [[ -f "$CONFIG_FILE" ]]; then
        pwd=$(awk '
          /^[[:space:]]*auth:/ { in_auth=1; in_obfs=0 }
          /^[[:space:]]*obfs:/ { in_auth=0; in_obfs=1 }
          in_auth && /^[[:space:]]*password:/ {
            sub(/^[[:space:]]*password:[[:space:]]*/, "");
            gsub(/^["'\'' ]+|["'\'' \r]+$/, "");
            print;
            exit;
          }
        ' "$CONFIG_FILE" 2>/dev/null)
    fi
    if [[ -z "$pwd" && -f "$CLIENT_CONFIG_FILE" ]]; then
        pwd=$(awk '
          /^[[:space:]]*auth:/ {
            sub(/^[[:space:]]*auth:[[:space:]]*/, "");
            gsub(/^["'\'' ]+|["'\'' \r]+$/, "");
            print;
            exit;
          }
        ' "$CLIENT_CONFIG_FILE" 2>/dev/null)
    fi
    echo "$pwd"
}

get_obfs_pwd() {
    local obfs=""
    if [[ -f "$CONFIG_FILE" ]]; then
        obfs=$(awk '
          /^[[:space:]]*obfs:/ { in_obfs=1; in_auth=0 }
          /^[[:space:]]*auth:/ { in_obfs=0 }
          in_obfs && /^[[:space:]]*password:/ {
            sub(/^[[:space:]]*password:[[:space:]]*/, "");
            gsub(/^["'\'' ]+|["'\'' \r]+$/, "");
            print;
            exit;
          }
        ' "$CONFIG_FILE" 2>/dev/null)
    fi
    if [[ -z "$obfs" && -f "$CLIENT_CONFIG_FILE" ]]; then
        obfs=$(awk '
          /^[[:space:]]*obfs:/ { in_obfs=1 }
          in_obfs && /^[[:space:]]*password:/ {
            sub(/^[[:space:]]*password:[[:space:]]*/, "");
            gsub(/^["'\'' ]+|["'\'' \r]+$/, "");
            print;
            exit;
          }
        ' "$CLIENT_CONFIG_FILE" 2>/dev/null)
    fi
    echo "$obfs"
}

get_listen() {
    local listen=""
    if [[ -f "$CONFIG_FILE" ]]; then
        listen=$(sed -n 's/^[[:space:]]*listen:[[:space:]]*\(.*\)/\1/p' "$CONFIG_FILE" 2>/dev/null | tr -d ' :\r' | head -1)
    fi
    if [[ -z "$listen" && -f "$CLIENT_CONFIG_FILE" ]]; then
        listen=$(sed -n 's/^[[:space:]]*server:[[:space:]]*[^:]*:\(.*\)/\1/p' "$CLIENT_CONFIG_FILE" 2>/dev/null | tr -d ' \r' | head -1)
    fi
    echo "$listen"
}

get_public_ports() {
    local ports=""
    if [[ -f "$CLIENT_CONFIG_FILE" ]]; then
        ports=$(sed -n 's/^[[:space:]]*server:[[:space:]]*[^:]*:\(.*\)/\1/p' "$CLIENT_CONFIG_FILE" | tr -d ' "\r' | head -1)
    fi
    if [[ -z "$ports" && -f "${CONFIG_DIR}/.public_port" ]]; then
        ports=$(cat "${CONFIG_DIR}/.public_port")
    fi
    [[ -n "$ports" ]] || ports=$(get_listen)
    echo "$ports"
}

has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

has_openrc() {
    command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 &&
        command -v openrc-run >/dev/null 2>&1 && [[ -f /run/openrc/softlevel ]]
}

is_cert_self_signed() {
    if [[ -f "${CONFIG_DIR}/server.crt" ]]; then
        local issuer subject
        issuer=$(openssl x509 -in "${CONFIG_DIR}/server.crt" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=[[:space:]]*//' || true)
        subject=$(openssl x509 -in "${CONFIG_DIR}/server.crt" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=[[:space:]]*//' || true)
        if [[ -n "$issuer" && "$issuer" == "$subject" ]]; then
            return 0
        fi
    fi
    return 1
}

status() {
    echo -e "\n  ${C_BAR}  ${C_WHITE}服务运行状态与 UDP 端口监听 · SERVICE STATUS${C_RESET}\n"
    local is_running=false
    if has_systemd; then
        systemctl status hysteria-server --no-pager || true
        systemctl is-active --quiet hysteria-server 2>/dev/null && is_running=true
    elif has_openrc; then
        rc-service hysteria-server status || true
        rc-service hysteria-server status 2>/dev/null | grep -q "started" && is_running=true
    elif [[ -x /usr/local/bin/hysteria-service ]]; then
        /usr/local/bin/hysteria-service status || true
        pgrep -f "hysteria (server|-c)" >/dev/null 2>&1 && is_running=true
    else
        local pids
        pids=$(pgrep -f "hysteria (server|-c)" 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            is_running=true
            echo -e "     ${C_GREEN}● 运行中 (Running)${C_RESET} - PID: ${C_CYAN}${pids}${C_RESET}"
            ps aux 2>/dev/null | grep -E "hysteria (server|-c)" | grep -v grep || true
        else
            echo -e "     ${C_RED}● 已停止 (Stopped)${C_RESET}"
        fi
    fi

    echo -e "\n  ${C_SUBBAR}  ${C_ORANGE_BOLD}证书信息与有效期 · CERTIFICATE INFO${C_RESET}"
    if [[ -f "${CONFIG_DIR}/server.crt" ]]; then
        local cert_subject cert_enddate
        cert_subject=$(openssl x509 -in "${CONFIG_DIR}/server.crt" -noout -subject 2>/dev/null | sed 's/subject=//' || echo "未知")
        cert_enddate=$(openssl x509 -in "${CONFIG_DIR}/server.crt" -noout -enddate 2>/dev/null | sed 's/notAfter=//' || echo "未知")
        if is_cert_self_signed; then
            echo -e "     ${C_GRAY_MID}证书类型:${C_RESET} ${C_CYAN}极速自签名 ECC 证书 (全客户端通用免维护)${C_RESET}"
        else
            echo -e "     ${C_GRAY_MID}证书类型:${C_RESET} ${C_GREEN}CA 签发证书${C_RESET}"
        fi
        echo -e "     ${C_GRAY_MID}证书主题:${C_RESET} ${cert_subject}"
        echo -e "     ${C_GRAY_MID}有效期限:${C_RESET} ${cert_enddate}"
    else
        echo -e "     ${C_GRAY_MID}未检测到活动证书文件${C_RESET}"
    fi

    echo -e "\n  ${C_SUBBAR}  ${C_ORANGE_BOLD}UDP 端口监听详情 · UDP LISTEN DETAILS${C_RESET}"
    local udp_found=false
    if command -v ss >/dev/null 2>&1; then
        if ss -ulpn 2>/dev/null | grep -q hysteria; then
            ss -ulpn 2>/dev/null | grep hysteria
            udp_found=true
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -ulpn 2>/dev/null | grep -q hysteria; then
            netstat -ulpn 2>/dev/null | grep hysteria
            udp_found=true
        fi
    fi
    if [[ "$udp_found" != "true" ]]; then
        echo -e "     ${C_GRAY_MID}暂无活动 UDP 监听 (若刚启动请稍候 1-2 秒刷新)${C_RESET}"
    fi
    echo ""
}

log() {
    echo -e "\n  ${C_BAR}  ${C_ORANGE_BOLD}跟踪实时运行日志 · LIVE LOG${C_RESET} ${C_GRAY_MID}(按 Ctrl+C 可退出)...${C_RESET}\n"
    if command -v journalctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        journalctl -u hysteria-server -f -o cat
    elif [[ -f "/var/log/hysteria.log" ]]; then
        tail -f -n 50 /var/log/hysteria.log
    else
        echo -e "  ${C_GRAY_MID}未检测到活动日志 (journalctl 或 /var/log/hysteria.log)${C_RESET}\n"
    fi
}

restart() {
    if has_systemd; then
        systemctl restart hysteria-server
    elif has_openrc; then
        rc-service hysteria-server restart
    elif [[ -x /usr/local/bin/hysteria-service ]]; then
        /usr/local/bin/hysteria-service restart
    else
        pkill -f "hysteria server" 2>/dev/null || true
        sleep 1
        nohup /usr/local/bin/hysteria server -c "${CONFIG_FILE}" >/var/log/hysteria.log 2>&1 &
    fi
    echo -e "\n  ${C_BAR}  ${C_GREEN}✔ Hysteria 2 服务已成功重启。${C_RESET}\n"
}

stop() {
    if has_systemd; then
        systemctl stop hysteria-server
    elif has_openrc; then
        rc-service hysteria-server stop
    elif [[ -x /usr/local/bin/hysteria-service ]]; then
        /usr/local/bin/hysteria-service stop
    else
        pkill -f "hysteria server" 2>/dev/null || true
    fi
    echo -e "\n  ${C_BAR}  ${C_AMBER}✔ Hysteria 2 服务已停止。${C_RESET}\n"
}

start() {
    if has_systemd; then
        systemctl start hysteria-server
    elif has_openrc; then
        rc-service hysteria-server start
    elif [[ -x /usr/local/bin/hysteria-service ]]; then
        /usr/local/bin/hysteria-service start
    else
        nohup /usr/local/bin/hysteria server -c "${CONFIG_FILE}" >/var/log/hysteria.log 2>&1 &
    fi
    echo -e "\n  ${C_BAR}  ${C_GREEN}✔ Hysteria 2 服务已启动。${C_RESET}\n"
}

link() {
    if [[ ! -f "$CONFIG_FILE" && ! -f "$CLIENT_CONFIG_FILE" ]]; then
        echo -e "\n  ${C_RED}✖ 未检测到 Hysteria 2 配置文件。${C_RESET}\n"
        return 1
    fi

    local domain password obfs_pwd listen public_ports base_port
    domain=$(get_domain)
    password=$(get_password)
    obfs_pwd=$(get_obfs_pwd)
    listen=$(get_listen)
    public_ports=$(get_public_ports)
    base_port=${public_ports%%-*}

    local obfs_param=""
    if [[ -n "$obfs_pwd" ]]; then
        obfs_param="&obfs=salamander&obfs-password=${obfs_pwd}"
    fi

    local insecure=0
    local cert_badge="${C_GREEN}CA 签发证书${C_RESET}"
    if is_cert_self_signed; then
        insecure=1
        cert_badge="${C_CYAN}极速自签名 ECC 证书 (全客户端通用免维护)${C_RESET}"
    fi

    echo -e "\n  ${C_BAR}  ${C_WHITE}节点连接凭据 · CONNECTION CREDENTIALS${C_RESET}"
    echo -e "     ${C_GRAY_MID}域名 (SNI)  :${C_RESET} ${C_WHITE}${domain}${C_RESET}"
    echo -e "     ${C_GRAY_MID}证书类型    :${C_RESET} ${cert_badge}"
    echo -e "     ${C_GRAY_MID}监听端口    :${C_RESET} ${C_CYAN}${listen}${C_RESET}"
    echo -e "     ${C_GRAY_MID}公网端口    :${C_RESET} ${C_CYAN}${public_ports}${C_RESET} ${C_GRAY_MID}(连接基准端口: ${base_port})${C_RESET}"
    echo -e "     ${C_GRAY_MID}认证密码    :${C_RESET} ${C_WHITE}${password}${C_RESET}"
    echo -e "     ${C_GRAY_MID}协议混淆    :${C_RESET} ${C_AMBER}salamander${C_RESET}"
    echo -e "     ${C_GRAY_MID}混淆密钥    :${C_RESET} ${C_WHITE}${obfs_pwd}${C_RESET}"
    echo -e "     ${C_GRAY_MID}伪装反代    :${C_RESET} ${C_GRAY_LIGHT}https://news.ycombinator.com/${C_RESET}\n"

    if [[ "$public_ports" == *-* ]]; then
        local link_hop="hysteria2://${password}@${domain}:${base_port}?sni=${domain}&insecure=${insecure}&allowInsecure=${insecure}${obfs_param}&mport=${public_ports}#${domain}-Hy2"
        local link_single="hysteria2://${password}@${domain}:${base_port}?sni=${domain}&insecure=${insecure}&allowInsecure=${insecure}${obfs_param}#${domain}-Hy2-Single"

        echo -e "  ${C_SUBBAR}  ${C_ORANGE_BOLD}格式 1 · 专属主节点链接${C_RESET} ${C_GRAY_MID}(端口跳跃 · v2rayN 兼容 · 防限速)${C_RESET}"
        echo -e "     ${C_YELLOW}${link_hop}${C_RESET}\n"

        echo -e "  ${C_SUBBAR}  ${C_ORANGE_BOLD}格式 2 · 基准单端口链接${C_RESET} ${C_GRAY_MID}(固定单端口 · 全客户端兼容备用)${C_RESET}"
        echo -e "     ${C_YELLOW}${link_single}${C_RESET}\n"
    else
        local link_main="hysteria2://${password}@${domain}:${base_port}?sni=${domain}&insecure=${insecure}&allowInsecure=${insecure}${obfs_param}#${domain}-Hy2"

        echo -e "  ${C_SUBBAR}  ${C_ORANGE_BOLD}节点连接链接${C_RESET} ${C_GRAY_MID}(v2rayN / Clash Verge / 全客户端通用)${C_RESET}"
        echo -e "     ${C_YELLOW}${link_main}${C_RESET}\n"
    fi

    echo -e "  ${C_ORANGE}●${C_RESET} ${C_GRAY_MID}提示: 在客户端中按 Ctrl+V 即可直接导入链接${C_RESET}\n"
}

client() {
    if [[ ! -f "$CONFIG_FILE" && ! -f "$CLIENT_CONFIG_FILE" ]]; then
        echo -e "\n  ${C_RED}✖ 未检测到服务端配置文件 $CONFIG_FILE。${C_RESET}\n"
        return 1
    fi

    local client_insecure="false"
    if is_cert_self_signed; then
        client_insecure="true"
    fi

    if [[ ! -f "$CLIENT_CONFIG_FILE" ]]; then
        local domain password obfs_pwd listen
        domain=$(get_domain)
        password=$(get_password)
        obfs_pwd=$(get_obfs_pwd)
        listen=$(get_public_ports)

        cat <<CLIENT_YAML_EOF > "$CLIENT_CONFIG_FILE"
server: ${domain}:${listen}
auth: "${password}"
tls:
  sni: ${domain}
  insecure: ${client_insecure}
obfs:
  type: salamander
  salamander:
    password: "${obfs_pwd}"
bandwidth:
  up: 100 mbps
  down: 300 mbps
CLIENT_YAML_EOF
        chown root:root "$CLIENT_CONFIG_FILE" 2>/dev/null || true
        chmod 600 "$CLIENT_CONFIG_FILE"
    else
        sed -i "s/^[[:space:]]*insecure:[[:space:]]*.*/  insecure: ${client_insecure}/" "$CLIENT_CONFIG_FILE" 2>/dev/null || true
    fi

    echo -e "\n  ${C_BAR}  ${C_WHITE}客户端 YAML 配置 (${CLIENT_CONFIG_FILE})${C_RESET}\n"
    cat "$CLIENT_CONFIG_FILE"
    echo ""
}

renew_test() {
    if is_cert_self_signed; then
        echo -e "\n  ${C_BAR}  ${C_GREEN}✔ 当前节点使用极速自签名 ECC 证书 (100 年超长有效)，无需执行续签。${C_RESET}\n"
    elif [[ -f "/etc/letsencrypt/renewal-hooks/deploy/hysteria-sync.sh" ]] && command -v certbot >/dev/null 2>&1; then
        echo -e "\n  ${C_BAR}  ${C_ORANGE_BOLD}模拟执行 Let's Encrypt 证书自动续签与挂钩同步...${C_RESET}\n"
        certbot renew --dry-run --run-deploy-hooks
    else
        echo -e "\n  ${C_BAR}  ${C_AMBER}未检测到 Let's Encrypt 自动续签配置。${C_RESET}\n"
    fi
}

remove_ufw_rule() {
    local rule="$1" rules numbers number
    rules=$(LC_ALL=C ufw status numbered 2>/dev/null) || return 1
    if [[ "$rules" == *"Status: active"* ]]; then
        # 按编号倒序删除带本项目注释的条目，分别保护 IPv4/IPv6 的其他规则。
        numbers=$(echo "$rules" | awk -v rule="$rule" '
          /# buds-hy2[[:space:]]*$/ {
            line=$0; sub(/^\[[[:space:]]*[0-9]+\][[:space:]]*/, "", line)
            split(line, fields, /[[:space:]]+/)
            if (fields[1]==rule) {sub(/^\[[[:space:]]*/, ""); sub(/\].*$/, ""); print}
          }' | sort -rn)
        for number in $numbers; do
            ufw --force delete "$number" >/dev/null 2>&1 || return 1
        done
    else
        # UFW 停用时，show added 仍可读取持久规则；仅接受本项目原样新增的条目。
        rules=$(LC_ALL=C ufw show added 2>/dev/null) || return 1
        local owned="ufw allow ${rule} comment 'buds-hy2'"
        if echo "$rules" | grep -Fxq "$owned"; then
            if echo "$rules" | awk -v prefix="ufw allow ${rule}" -v owned="$owned" '
                index($0,prefix)==1 && $0!=owned {found=1} END {exit !found}'; then
                return 1
            fi
            ufw --force delete allow "$rule" comment buds-hy2 >/dev/null 2>&1 || return 1
        fi
    fi
}

cleanup_firewall() {
    local rule_file="${CONFIG_DIR}/.firewall_rule"
    [[ -f "$rule_file" ]] || return 0
    local remaining backend zone mode rule result failed=false changed_iptables=false
    remaining=$(mktemp "${rule_file}.XXXXXX") || return 1
    while IFS='|' read -r backend zone mode rule; do
        result=0
        case "$backend" in
            ufw)
                remove_ufw_rule "$rule" || result=1
                ;;
            firewalld)
                local options=(--zone="$zone")
                [[ "$mode" != permanent ]] || options+=(--permanent)
                if firewall-cmd "${options[@]}" --query-port="$rule" >/dev/null 2>&1; then
                    firewall-cmd "${options[@]}" --remove-port="$rule" >/dev/null 2>&1 || result=1
                else
                    [[ "$?" == 1 ]] || result=1
                fi
                ;;
            iptables)
                changed_iptables=true
                if iptables -C "$zone" -p udp --dport "${rule%/*}" -m comment --comment buds-hy2 -j ACCEPT >/dev/null 2>&1; then
                    iptables -D "$zone" -p udp --dport "${rule%/*}" -m comment --comment buds-hy2 -j ACCEPT >/dev/null 2>&1 || result=1
                else
                    [[ "$?" == 1 ]] || result=1
                fi
                ;;
            *)
                # 旧版本只记端口，无法证明未带注释的规则归属，保留这些规则。
                if [[ "$backend" =~ ^[0-9]+(:[0-9]+)?/udp$ ]]; then
                    if command -v ufw >/dev/null 2>&1; then
                        remove_ufw_rule "$backend" || result=1
                    fi
                    if command -v iptables >/dev/null 2>&1 &&
                       iptables -C INPUT -p udp --dport "${backend%/*}" -m comment --comment buds-hy2 -j ACCEPT >/dev/null 2>&1; then
                        iptables -D INPUT -p udp --dport "${backend%/*}" -m comment --comment buds-hy2 -j ACCEPT >/dev/null 2>&1 || result=1
                        changed_iptables=true
                    fi
                    echo "  旧版本防火墙记录缺少归属信息，仅清理带 buds-hy2 标记的规则。"
                else
                    result=1
                fi
                ;;
        esac
        if [[ "$result" != 0 ]]; then
            printf '%s|%s|%s|%s\n' "$backend" "$zone" "$mode" "$rule" >> "$remaining"
            failed=true
        fi
    done < "$rule_file"
    if [[ "$changed_iptables" == true && -x /etc/init.d/iptables ]]; then
        if ! /etc/init.d/iptables save >/dev/null 2>&1; then
            rm -f "$remaining"
            echo "  保存 iptables 清理结果失败，已保留规则记录，请重试卸载。"
            return 1
        fi
    fi
    mv -f "$remaining" "$rule_file"
    if [[ "$failed" == true ]]; then
        echo "  部分防火墙规则未能安全清理，已保留配置和规则记录，请检查权限后重试卸载。"
        return 1
    fi
    rm -f "$rule_file"
}

uninstall() {
    echo -e "\n  ${C_RED}⚠ 警告: 即将卸载 Hysteria 2 服务！${C_RESET}"
    read -rp "  确认彻底卸载吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if has_systemd; then
            systemctl disable --now hysteria-server 2>/dev/null || true
            rm -rf /etc/systemd/system/hysteria-server.service.d
            rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service
            systemctl daemon-reload 2>/dev/null || true
        fi
        if has_openrc; then
            rc-service hysteria-server stop 2>/dev/null || true
            rc-update del hysteria-server default 2>/dev/null || true
            rm -f /etc/init.d/hysteria-server
        fi
        pkill -f "hysteria server" 2>/dev/null || true

        cleanup_firewall
        rm -f /usr/local/bin/hysteria /usr/local/bin/buds /usr/local/bin/hy2 /usr/local/bin/hysteria-service
        rm -rf /etc/hysteria /var/log/hysteria.log
        rm -f /etc/letsencrypt/renewal-hooks/deploy/hysteria-sync.sh
        rm -f /etc/periodic/daily/certbot-renew
        rm -f /etc/sysctl.d/99-hysteria-performance.conf
        echo -e "\n  ${C_BAR}  ${C_GREEN}✔ Hysteria 2 服务及防火墙规则已安全卸载，原有 Nginx 及网站保持原样。${C_RESET}\n"
    else
        echo -e "\n  已取消卸载。\n"
    fi
}

show_menu() {
    while true; do
        local status_badge domain listen
        local is_running=false
        if has_systemd; then
            if systemctl is-active --quiet hysteria-server 2>/dev/null; then
                is_running=true
            fi
        elif has_openrc; then
            if rc-service hysteria-server status 2>/dev/null | grep -q "started"; then
                is_running=true
            fi
        else
            if pgrep -f "hysteria (server|-c)" >/dev/null 2>&1; then
                is_running=true
            fi
        fi

        if [[ "$is_running" == "true" ]]; then
            status_badge="${C_GREEN}● 运行中 (Running)${C_RESET}"
        else
            status_badge="${C_RED}● 已停止 (Stopped)${C_RESET}"
        fi

        domain=$(get_domain)
        listen=$(get_listen)
        [[ -z "$listen" ]] && listen="未配置"

        clear 2>/dev/null || true
        echo -e "       ${C_SPARK}✧${C_RESET}                                      ${C_SPARK}✦${C_RESET}"
        echo -e "  ${C_ORANGE_BOLD}█▀▀█ █  █ █▀▀▄ █▀▀▀${C_RESET}   ${C_GRAY_LIGHT}█  █ █  █ █▀▀█${C_RESET}"
        echo -e "  ${C_ORANGE_BOLD}█▀▀▄ █  █ █  █ ▀▀▀█${C_RESET}   ${C_GRAY_LIGHT}█▀▀█ ▀██▀   ▄▀${C_RESET}"
        echo -e "  ${C_ORANGE_BOLD}█  █ █  █ █  █    █${C_RESET}   ${C_GRAY_LIGHT}█  █   █  ▄▀  ${C_RESET}"
        echo -e "  ${C_ORANGE_BOLD}▀▀▀▀ ▀▀▀▀ ▀▀▀  ▀▀▀▀${C_RESET}   ${C_GRAY_LIGHT}▀  ▀   ▀  ▀▀▀▀${C_RESET}"
        echo -e "  ${C_GRAY_MID}Hysteria 2 High-Performance Protocol Suite${C_RESET}\n"

        echo -e "  ${C_BAR}  ${C_WHITE}节点状态${C_RESET}  ${status_badge}    ${C_WHITE}监听端口${C_RESET}  ${C_CYAN}${listen}${C_RESET}"
        echo -e "  ${C_BAR}  ${C_GRAY_MID}解析域名${C_RESET}  ${C_GRAY_LIGHT}${domain}${C_RESET}    ${C_GRAY_MID}协议混淆${C_RESET}  ${C_AMBER}Salamander${C_RESET}\n"

        echo -e "  ${C_SUBBAR}  ${C_ORANGE_BOLD}核心业务${C_RESET} ${C_GRAY_MID}· CORE ACTIONS${C_RESET}"
        echo -e "     ${C_ORANGE_BOLD}1.${C_RESET} ${C_WHITE}运行状态${C_RESET}      ${C_GRAY_MID}Service Status & UDP Socket${C_RESET}"
        echo -e "     ${C_ORANGE_BOLD}2.${C_RESET} ${C_WHITE}节点链接${C_RESET}      ${C_GRAY_MID}Connection URIs & v2rayN Link${C_RESET}"
        echo -e "     ${C_ORANGE_BOLD}3.${C_RESET} ${C_WHITE}客户端配置${C_RESET}    ${C_GRAY_MID}Client Config (client.yaml)${C_RESET}"
        echo -e "     ${C_ORANGE_BOLD}4.${C_RESET} ${C_WHITE}实时日志${C_RESET}      ${C_GRAY_MID}Live Journal Log (Ctrl+C 退出)${C_RESET}\n"

        echo -e "  ${C_SUBBAR}  ${C_ORANGE_BOLD}服务控制${C_RESET} ${C_GRAY_MID}· SERVICE CONTROL${C_RESET}"
        echo -e "     ${C_ORANGE_BOLD}5.${C_RESET} ${C_WHITE}重启服务${C_RESET}      ${C_GRAY_MID}Restart Hysteria 2${C_RESET}"
        echo -e "     ${C_ORANGE_BOLD}6.${C_RESET} ${C_WHITE}启动服务${C_RESET}      ${C_GRAY_MID}Start Hysteria 2${C_RESET}"
        echo -e "     ${C_ORANGE_BOLD}7.${C_RESET} ${C_WHITE}停止服务${C_RESET}      ${C_GRAY_MID}Stop Hysteria 2${C_RESET}\n"

        echo -e "  ${C_SUBBAR}  ${C_ORANGE_BOLD}系统维护${C_RESET} ${C_GRAY_MID}· MAINTENANCE${C_RESET}"
        echo -e "     ${C_ORANGE_BOLD}8.${C_RESET} ${C_WHITE}模拟续签${C_RESET}      ${C_GRAY_MID}Let's Encrypt SSL Dry-Run${C_RESET}"
        echo -e "     ${C_ORANGE_BOLD}9.${C_RESET} ${C_WHITE}卸载节点${C_RESET}      ${C_GRAY_MID}Uninstall & Clean Firewall${C_RESET}"
        echo -e "     ${C_GRAY_MID}0.${C_RESET} ${C_GRAY_MID}退出脚本${C_RESET}      ${C_GRAY_MID}Exit${C_RESET}\n"

        read -rp "$(echo -e "  ${C_ORANGE_BOLD}❯${C_RESET} ${C_WHITE}请选择操作编号 [0-9]: ${C_RESET}")" choice
        case "$choice" in
            1) status; read -rp "按回车键返回主菜单..." ;;
            2) link; read -rp "按回车键返回主菜单..." ;;
            3) client; read -rp "按回车键返回主菜单..." ;;
            4) log ;;
            5) restart; read -rp "按回车键返回主菜单..." ;;
            6) start; read -rp "按回车键返回主菜单..." ;;
            7) stop; read -rp "按回车键返回主菜单..." ;;
            8) renew_test; read -rp "按回车键返回主菜单..." ;;
            9) uninstall; break ;;
            0) exit 0 ;;
            *) echo "输入无效，请重新选择。" ;;
        esac
    done
}

check_root

case "$1" in
    status) status ;;
    log) log ;;
    restart) restart ;;
    stop) stop ;;
    start) start ;;
    link) link ;;
    client) client ;;
    renew-test) renew_test ;;
    uninstall) uninstall ;;
    *) show_menu ;;
esac
EOF
    fi
    chmod 755 "$BUDS_CLI"
    ln -sf "$BUDS_CLI" "$HY2_CLI"
    success "已配置快捷管理命令：'buds hy2' 或 'hy2'。"
}

display_summary() {
    echo -e "\n  ${C_BAR}  ${C_GREEN}✔ Hysteria 2 节点部署完成 · DEPLOYMENT SUCCESSFUL${C_RESET}"
    /usr/local/bin/buds hy2 link
    echo -e "  ${C_SUBBAR}  ${C_ORANGE_BOLD}常用管理命令${C_RESET} ${C_GRAY_MID}· CLI COMMANDS${C_RESET}"
    echo -e "     ${C_ORANGE_BOLD}buds hy2${C_RESET}          ${C_GRAY_MID}随时打开 MiMo 极客交互式管理面板${C_RESET}"
    echo -e "     ${C_ORANGE_BOLD}buds hy2 status${C_RESET}   ${C_GRAY_MID}查看服务运行状态与监听端口${C_RESET}"
    echo -e "     ${C_ORANGE_BOLD}buds hy2 link${C_RESET}     ${C_GRAY_MID}查看节点连接链接与导入凭据${C_RESET}"
    echo -e "     ${C_ORANGE_BOLD}buds hy2 log${C_RESET}      ${C_GRAY_MID}查看实时日志 (Ctrl+C 退出)${C_RESET}"
    echo -e "     ${C_ORANGE_BOLD}buds hy2 restart${C_RESET}  ${C_GRAY_MID}重启服务${C_RESET}\n"
}

main() {
    check_root
    if [[ -f "$CONFIG_FILE" ]]; then
        if [[ -x "$BUDS_CLI" ]]; then
            info "检测到已有节点，打开管理菜单。"
            exec "$BUDS_CLI" hy2
        fi
        error "已有 Hysteria 配置，但管理命令缺失；为避免覆盖现有节点，停止安装。"
        exit 1
    fi
    detect_virtualization
    detect_init_system
    install_dependencies
    collect_parameters
    setup_certificates
    install_official_core
    generate_server_config
    tune_kernel_network
    configure_service
    configure_firewall
    start_service
    setup_cli
    display_summary
}

main "$@"
