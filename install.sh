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
SCRIPT_VERSION="1.6.2"
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
    PUBLIC_IP=$(curl -fsS4 --connect-timeout 2 --max-time 5 https://api.ipify.org 2>/dev/null || \
                curl -fsS4 --connect-timeout 2 --max-time 5 https://ip.sb 2>/dev/null || \
                curl -fsS4 --connect-timeout 2 --max-time 5 https://icanhazip.com 2>/dev/null || \
                curl -fsS4 --connect-timeout 2 --max-time 5 https://ifconfig.me 2>/dev/null || echo "")

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
        attempts=$((attempts + 1))
    done
    echo "38443"
}

install_dependencies() {
    info "检测并安装必要依赖组件..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y -qq curl openssl ca-certificates procps >/dev/null 2>&1 || true
        apt-get install -y -qq wget ufw iptables iproute2 dnsutils libcap2-bin >/dev/null 2>&1 || true
        apt-get install -y -qq python3 util-linux >/dev/null 2>&1 || true
        apt-get install -y -qq certbot python3-certbot-nginx >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk update >/dev/null 2>&1 || true
        apk add --no-cache curl openssl ca-certificates procps >/dev/null 2>&1 || true
        apk add --no-cache wget iptables iproute2 bind-tools libcap shadow tzdata >/dev/null 2>&1 || true
        apk add --no-cache certbot >/dev/null 2>&1 || true
        apk add --no-cache certbot-nginx >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        local manager
        manager=$(command -v dnf || command -v yum)
        "$manager" install -y -q curl openssl ca-certificates procps-ng >/dev/null 2>&1 || true
        "$manager" install -y -q wget iptables iproute bind-utils libcap >/dev/null 2>&1 || true
        "$manager" install -y -q python3 util-linux >/dev/null 2>&1 || true
        "$manager" install -y -q epel-release >/dev/null 2>&1 || true
        "$manager" install -y -q certbot python3-certbot-nginx >/dev/null 2>&1 || true
    elif command -v pacman >/dev/null 2>&1; then
        # 不刷新索引后仅升级部分软件，也不自动升级整机。
        pacman -S --needed --noconfirm curl openssl ca-certificates procps-ng >/dev/null 2>&1 || true
        pacman -S --needed --noconfirm wget iptables iproute2 bind libcap >/dev/null 2>&1 || true
        pacman -S --needed --noconfirm python util-linux >/dev/null 2>&1 || true
        pacman -S --needed --noconfirm certbot certbot-nginx >/dev/null 2>&1 || true
    else
        warn "未识别到主流包管理器，检查现有系统工具。"
    fi

    local tool missing=()
    for tool in curl openssl pgrep pkill nohup mktemp; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if (( ${#missing[@]} )); then
        error "缺少必需工具：${missing[*]}。请检查软件源和网络后重新安装。"
        return 1
    fi
    HAVE_CERTBOT=false
    if command -v certbot >/dev/null 2>&1; then
        HAVE_CERTBOT=true
    else
        warn "未安装 Certbot，仍可正常使用自签名证书。"
    fi
    success "必需工具检查通过。"
}

validate_domain() {
    info "正在校验域名解析..."
    local server_ip="${PUBLIC_IP}" resolved_ip="" answer=""
    if [[ -z "$server_ip" ]]; then
        server_ip=$(curl -fsS4 --connect-timeout 3 --max-time 6 https://api.ipify.org 2>/dev/null ||
                    curl -fsS4 --connect-timeout 3 --max-time 6 https://ip.sb 2>/dev/null || true)
    fi
    if command -v getent >/dev/null 2>&1; then
        answer=$(getent ahostsv4 "$DOMAIN" 2>/dev/null || true)
        resolved_ip=$(printf '%s\n' "$answer" | awk 'NR==1 {print $1}')
    fi
    if [[ -z "$resolved_ip" ]] && command -v dig >/dev/null 2>&1; then
        answer=$(dig +time=2 +tries=1 +short A "$DOMAIN" 2>/dev/null || true)
        resolved_ip=$(printf '%s\n' "$answer" | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print; exit}')
    fi
    if [[ -z "$resolved_ip" ]] && command -v host >/dev/null 2>&1; then
        answer=$(host -W 2 -t A "$DOMAIN" 2>/dev/null || true)
        resolved_ip=$(printf '%s\n' "$answer" | awk '/has address/ {print $4; exit}')
    fi
    if [[ -z "$resolved_ip" ]] && command -v nslookup >/dev/null 2>&1; then
        answer=$(nslookup "$DOMAIN" 2>/dev/null || true)
        # 排除输出前半部分的 DNS 服务器地址。
        resolved_ip=$(printf '%s\n' "$answer" | awk '
            /^Name:[[:space:]]/ {found=1}
            found && /^Address([[:space:]][0-9]+)?:[[:space:]]/ {
                sub(/^Address([[:space:]][0-9]+)?:[[:space:]]*/, "")
                if ($1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $1; exit}
            }')
    fi
    if [[ -z "$resolved_ip" ]]; then
        warn "暂未查询到 ${DOMAIN} 的 IPv4 解析。继续安装，连接前请确认域名解析正确。"
    elif [[ -n "$server_ip" && "$server_ip" != "$resolved_ip" ]]; then
        warn "域名解析 IP (${resolved_ip}) 与公网出口 IP (${server_ip}) 不一致。"
        warn "连接前请确认域名指向正确的公网入口；自签名证书不能代替正确的 DNS 解析。"
        read -rp "是否仍然继续？(Y/n) [默认 y]: " force_continue
        if [[ ! "${force_continue:-y}" =~ ^[Yy]$ ]]; then
            error "已取消安装，请待 DNS 解析生效后再运行。"
            return 1
        fi
    else
        success "域名解析: ${DOMAIN} -> ${resolved_ip}。"
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
        if [[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
            break
        fi
        error "域名格式无效，请输入标准域名 (例如 your.domain.com)，不要包含协议或特殊字符！"
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
            if command -v ss >/dev/null 2>&1; then
                local used_in_range
                used_in_range=$(ss -ulpn 2>/dev/null | grep -v "hysteria" | awk -v s="$hop_start" -v e="$hop_end" '
                    {
                        address = $4
                        if (match(address, /:[0-9]+$/)) {
                            p = substr(address, RSTART + 1) + 0
                            if (p >= s && p <= e) { print p; exit }
                        }
                    }' || true)
                if [[ -n "$used_in_range" ]]; then
                    warn "端口范围 ${hop_start}-${hop_end} 内检测到 UDP 端口 ${used_in_range} 已被其他进程占用。"
                fi
            fi
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

get_cert_pin() {
    local pin
    pin=$(openssl x509 -in "${CONFIG_DIR}/server.crt" -noout -fingerprint -sha256 2>/dev/null |
        sed 's/^[^=]*=//' | tr -d ':\r\n' | tr 'A-F' 'a-f') || return 1
    [[ "$pin" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$pin"
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
    success "自签名证书生成完毕 (ECC-P256 算法，有效期 100 年，客户端使用 SHA-256 指纹验证)。"
}

read_root_crontab() {
    local contents
    if contents=$(LC_ALL=C crontab -l 2>&1); then
        printf '%s\n' "$contents"
    elif [[ "$contents" == *"no crontab"* || "$contents" == *"No such file"* ]]; then
        return 0
    else
        echo "无法读取 root 定时任务，未覆盖已有任务。" >&2
        return 1
    fi
}

ensure_cron_running() {
    local daemon
    if has_systemd; then
        for daemon in cron crond; do
            if systemctl cat "$daemon.service" >/dev/null 2>&1 &&
               systemctl enable --now "$daemon.service" >/dev/null 2>&1; then
                return 0
            fi
        done
    elif has_openrc; then
        for daemon in crond cron; do
            if [[ -f "/etc/init.d/$daemon" ]] &&
               rc-update add "$daemon" default >/dev/null 2>&1 &&
               rc-service "$daemon" start >/dev/null 2>&1; then
                return 0
            fi
        done
    else
        if pgrep -x 'cron|crond' >/dev/null 2>&1; then return 0; fi
        if command -v crond >/dev/null 2>&1; then
            crond && pgrep -x crond >/dev/null 2>&1 && return 0
        elif command -v cron >/dev/null 2>&1; then
            cron && pgrep -x cron >/dev/null 2>&1 && return 0
        fi
    fi
    return 1
}

configure_renewal() {
    local timer cron_contents="" certbot_bin
    certbot_bin=$(command -v certbot) || return 1
    if has_systemd; then
        for timer in certbot.timer certbot-renew.timer snap.certbot.renew.timer; do
            if systemctl cat "$timer" >/dev/null 2>&1 &&
               systemctl enable --now "$timer" >/dev/null 2>&1; then
                success "已启用现有证书续签定时器：$timer。"
                return 0
            fi
        done
    fi
    if command -v crontab >/dev/null 2>&1; then
        cron_contents=$(read_root_crontab) || return 1
    fi
    if printf '%s\n' "$cron_contents" | grep -Eq '^[^#]*certbot[[:space:]]+renew' ||
       grep -ERq '^[^#]*certbot[[:space:]]+renew' /etc/crontab /etc/cron.d /etc/cron.daily /etc/periodic 2>/dev/null; then
        if ! ensure_cron_running; then
            error "已有续签任务，但无法启动 cron 服务，请检查当前容器或系统的服务管理。"
            return 1
        fi
        success "已使用现有 cron 续签任务。"
        return 0
    fi
    if has_systemd; then
        cat > /etc/systemd/system/buds-hy2-renew.service <<EOF
[Unit]
Description=Buds HY2 certificate renewal
[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$certbot_bin renew --quiet --run-deploy-hooks
EOF
        cat > /etc/systemd/system/buds-hy2-renew.timer <<'TIMER_EOF'
[Unit]
Description=Buds HY2 certificate renewal timer
[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
TIMER_EOF
        systemctl daemon-reload
        systemctl enable --now buds-hy2-renew.timer
    else
        if ! command -v crontab >/dev/null 2>&1; then
            if command -v apt-get >/dev/null 2>&1; then
                apt-get install -y -qq cron >/dev/null 2>&1 || true
            elif command -v apk >/dev/null 2>&1; then
                apk add --no-cache dcron >/dev/null 2>&1 || true
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y -q cronie >/dev/null 2>&1 || true
            elif command -v yum >/dev/null 2>&1; then
                yum install -y -q cronie >/dev/null 2>&1 || true
            elif command -v pacman >/dev/null 2>&1; then
                pacman -S --needed --noconfirm cronie >/dev/null 2>&1 || true
            fi
        fi
        if ! command -v crontab >/dev/null 2>&1 || ! ensure_cron_running; then
            error "无法配置证书定期续签，请检查 cron 服务；可重新选择自签名模式。"
            return 1
        fi
        cron_contents=$(read_root_crontab) || return 1
        { printf '%s\n' "$cron_contents"
          printf '0 3,15 * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin %s renew --quiet --run-deploy-hooks # buds-hy2-renew\n' "$certbot_bin"
        } | crontab -
    fi
    success "证书自动续签任务已启用。"
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
        info "自动切换为自签名 ECC 证书继续完成节点部署 (自动导出证书指纹)..."
        generate_self_signed_cert "$DOMAIN"
        return 0
    fi

    mkdir -p "$CONFIG_DIR" "$HOOK_DIR"

    {
        printf '#!/usr/bin/env bash\nset -e\n'
        printf 'DOMAIN=%q\n' "$DOMAIN"
        printf 'CONFIG_DIR=%q\n' "$CONFIG_DIR"
        printf 'CONFIG_FILE=%q\n' "$CONFIG_FILE"
        cat <<'HOOK_EOF'
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
    elif pgrep -fx "/usr/local/bin/hysteria server (-c|--config) /etc/hysteria/config[.]yaml" >/dev/null 2>&1; then
        pkill -fx "/usr/local/bin/hysteria server (-c|--config) /etc/hysteria/config[.]yaml"
        stopped=false
        for _ in 1 2 3 4 5; do
            if ! pgrep -fx "/usr/local/bin/hysteria server (-c|--config) /etc/hysteria/config[.]yaml" >/dev/null 2>&1; then
                stopped=true
                break
            fi
            sleep 1
        done
        if [[ "$stopped" != true ]]; then
            echo "Hysteria 2 旧进程未停止，证书已同步，取消重新启动。" >&2
            exit 1
        fi
        nohup /usr/local/bin/hysteria server -c "${CONFIG_FILE}" >/var/log/hysteria.log 2>&1 &
    fi
fi
HOOK_EOF
    } > "$HOOK_FILE"
    chmod +x "$HOOK_FILE"
    "$HOOK_FILE"

    configure_renewal || warn "证书已部署，但自动续签定时任务配置失败，请稍后手动检查系统 cron 或 systemd timer。"

    success "SSL 证书部署完成，已挂载自动续期同步钩子。"
}

validate_core_binary() {
    local magic
    magic=$(head -c 4 "$1" 2>/dev/null || true)
    [[ "$magic" == $'\x7fELF' ]] && "$1" version >/dev/null 2>&1
}

install_official_core() (
    # 子 Shell 将临时目录的退出清理限制在本次下载，不改变安装器的其他 trap。
    info "下载并校验官方 Hysteria 2 内核..."
    local arch binary_name headers release_url version base_url download_dir expected actual
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) binary_name="hysteria-linux-amd64" ;;
        aarch64|arm64) binary_name="hysteria-linux-arm64" ;;
        armv7*|armhf|armv6*) binary_name="hysteria-linux-arm" ;;
        armv5*) binary_name="hysteria-linux-armv5" ;;
        i386|i686) binary_name="hysteria-linux-386" ;;
        s390x) binary_name="hysteria-linux-s390x" ;;
        mipsle) binary_name="hysteria-linux-mipsle" ;;
        riscv64) binary_name="hysteria-linux-riscv64" ;;
        loongarch64) binary_name="hysteria-linux-loong64" ;;
        *) error "不支持的 CPU 架构：$arch，停止安装。"; return 1 ;;
    esac
    mkdir -p /usr/local/bin
    local target_parent
    target_parent=$(cd /usr/local/bin && pwd -P)
    download_dir=$(mktemp -d "$target_parent/.buds-hy2-download.XXXXXXXX") || return 1
    [[ "$download_dir" == "$target_parent"/.buds-hy2-download.* && -d "$download_dir" ]] || return 1
    trap 'rm -rf -- "$download_dir"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # 只解析官方 HTTPS 重定向的版本；摘要和内核随后使用同一个固定版本。
    if ! headers=$(curl -fsSI --connect-timeout 8 --max-time 20 --retry 1 \
        --proto '=https' https://github.com/HyNetworks/hysteria/releases/latest); then
        error "无法获取官方内核版本，请检查服务器网络。"
        return 1
    fi
    release_url=$(printf '%s\n' "$headers" | tr -d '\r' | awk 'tolower($1)=="location:" {print $2; exit}')
    version="${release_url#https://github.com/HyNetworks/hysteria/releases/tag/}"
    if [[ ! "$version" =~ ^app/v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "官方版本信息无效，未执行任何下载文件。"
        return 1
    fi
    base_url="https://github.com/HyNetworks/hysteria/releases/download/${version}"
    if ! curl -fsSL --connect-timeout 8 --max-time 30 --retry 1 \
        --proto '=https' --proto-redir '=https' "$base_url/hashes.txt" -o "$download_dir/hashes.txt"; then
        error "无法获取官方 SHA-256 摘要，停止安装。"
        return 1
    fi
    expected=$(awk -v name="$binary_name" '
        {file=$2; sub(/^\*/, "", file); sub(/^.*\//, "", file)}
        file==name {print tolower($1); exit}' "$download_dir/hashes.txt")
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        error "官方摘要中未找到当前架构的内核，停止安装。"
        return 1
    fi
    if ! curl -fSL --connect-timeout 8 --max-time 120 --retry 2 \
        --proto '=https' --proto-redir '=https' "$base_url/$binary_name" -o "$download_dir/hysteria"; then
        error "官方内核下载失败，请检查服务器网络。"
        return 1
    fi
    actual=$(openssl dgst -sha256 "$download_dir/hysteria" | awk '{print tolower($NF)}')
    if [[ "$actual" != "$expected" ]]; then
        error "内核 SHA-256 校验失败，已拒绝执行和安装。"
        return 1
    fi
    chmod 755 "$download_dir/hysteria"
    if ! validate_core_binary "$download_dir/hysteria"; then
        error "已校验的内核无法在当前系统运行，原有二进制保持不变。"
        return 1
    fi
    mv -f "$download_dir/hysteria" /usr/local/bin/hysteria
    success "官方内核 ${version#app/} 安装完成，SHA-256 校验通过。"
)

service_group_exists() {
    if command -v getent >/dev/null 2>&1; then
        getent group hysteria >/dev/null 2>&1
    else
        grep -q '^hysteria:' /etc/group
    fi
}

ensure_service_account() {
    if ! service_group_exists; then
        if command -v groupadd >/dev/null 2>&1; then
            groupadd -r hysteria || return 1
        else
            addgroup -S hysteria || return 1
        fi
    fi
    if id hysteria >/dev/null 2>&1; then
        return 0
    fi
    if command -v useradd >/dev/null 2>&1; then
        useradd -r -M -g hysteria -s /sbin/nologin hysteria
    else
        adduser -S -D -H -G hysteria -s /sbin/nologin hysteria
    fi
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

    if ensure_service_account; then
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
        printf '\ntcp_bbr\n' >> /etc/modules 2>/dev/null || true
    fi
    if [[ -f /etc/modules ]] && ! grep -q "^sch_fq" /etc/modules 2>/dev/null; then
        printf '\nsch_fq\n' >> /etc/modules 2>/dev/null || true
    fi

    mkdir -p /etc/sysctl.d
    cat <<EOF > "$SYSCTL_FILE"
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.optmem_max=65536
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
    
    local service_caps="CAP_NET_BIND_SERVICE"
    if [[ "$IS_PORT_HOPPING" == true ]]; then
        # Hysteria 原生端口范围通过 nftables/iptables 重定向，需要网络管理权限。
        service_caps+=" CAP_NET_ADMIN"
    fi

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        mkdir -p "$(dirname "$SERVICE_FILE")" "$OVERRIDE_DIR"
        local service_user="root"
        if id hysteria >/dev/null 2>&1 && service_group_exists; then
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
CapabilityBoundingSet=${service_caps}
AmbientCapabilities=${service_caps}
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
        local openrc_user="root" openrc_group="root" openrc_caps="" supervise_help
        if id hysteria >/dev/null 2>&1 && service_group_exists; then
            openrc_user="hysteria"
            openrc_group="hysteria"
            if [[ "$IS_PORT_HOPPING" == true ]]; then
                supervise_help=$(RC_SVCNAME=hysteria-server supervise-daemon hysteria-server --help 2>&1 || true)
                if [[ "$supervise_help" == *--capabilities* ]]; then
                    openrc_caps="^cap_net_admin"
                else
                    warn "当前 OpenRC 无法为服务进程设置 CAP_NET_ADMIN，端口跳跃服务将以 root 运行。"
                    openrc_user="root"
                    openrc_group="root"
                fi
            fi
        fi
        {
            cat <<'INIT_EOF'
#!/sbin/openrc-run
supervisor="supervise-daemon"
name="hysteria-server"
description="Hysteria 2 Server Service"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background="yes"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"
respawn_delay=2
respawn_max=0

depend() {
    need net
    after firewall
}
INIT_EOF
            printf 'command_user="%s:%s"\n' "$openrc_user" "$openrc_group"
            if [[ -n "$openrc_caps" ]]; then
                printf 'capabilities="%s"\n' "$openrc_caps"
            fi
            cat <<INIT_EOF

start_pre() {
    checkpath -d -m 0750 /etc/hysteria
    if [ ! -f /etc/hysteria/config.yaml ]; then
        eerror "Config file /etc/hysteria/config.yaml not found!"
        return 1
    fi
    touch /var/log/hysteria.log
    chown ${openrc_user}:${openrc_group} /var/log/hysteria.log 2>/dev/null || true
    chmod 640 /var/log/hysteria.log
}
INIT_EOF
        } > /etc/init.d/hysteria-server
        chmod 755 /etc/init.d/hysteria-server
        rc-update add hysteria-server default >/dev/null 2>&1 || true
        success "OpenRC 守护服务已配置并设为开机自启 (崩溃自动重启)。"
    else
        # 容器 / 极简环境轻量服务管理包装器
        cat <<'RUNNER_EOF' > /usr/local/bin/hysteria-service
#!/usr/bin/env bash
pattern='/usr/local/bin/hysteria server -c /etc/hysteria/config[.]yaml'
running() { pgrep -fx "$pattern" >/dev/null 2>&1; }
start_server() {
    if running; then
        echo "hysteria-server 正在运行。"
        return 0
    fi
    nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml >/var/log/hysteria.log 2>&1 &
    sleep 1
    if running; then
        echo "hysteria-server 启动成功。"
    else
        echo "hysteria-server 启动失败，请检查配置及日志。" >&2
        tail -n 20 /var/log/hysteria.log >&2
        return 1
    fi
}
stop_server() {
    local attempt
    if running; then
        pkill -fx "$pattern" || return 1
        for attempt in 1 2 3 4 5; do
            running || break
            sleep 1
        done
        if running; then
            echo "hysteria-server 尚未停止。" >&2
            return 1
        fi
    fi
    echo "hysteria-server 已停止。"
}
case "$1" in
    start) start_server ;;
    stop) stop_server ;;
    restart) stop_server && start_server ;;
    status)
        if running; then
            echo "hysteria-server 正在运行。"
        else
            echo "hysteria-server 已停止。"
            exit 1
        fi
        ;;
    *) echo "用法: $0 {start|stop|restart|status}"; exit 1 ;;
esac
RUNNER_EOF
        chmod 755 /usr/local/bin/hysteria-service
        if [[ -f /etc/rc.local ]] && ! grep -q "hysteria-service" /etc/rc.local; then
            sed -i '/^exit 0/i /usr/local/bin/hysteria-service start' /etc/rc.local 2>/dev/null || true
        fi
        success "轻量进程服务管理器已配置 (/usr/local/bin/hysteria-service)。"
    fi

    if [[ "$INIT_SYSTEM" != "systemd" && -d /etc/logrotate.d ]]; then
        cat <<'LOGROTATE_EOF' > /etc/logrotate.d/hysteria
/var/log/hysteria.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
LOGROTATE_EOF
    fi
}

record_firewall_rule() {
    # 仅记录本次成功新增的规则：后端|区域/链|运行时/永久|端口协议。
    (umask 077; printf '%s|%s|%s|%s\n' "$@" >> "${CONFIG_DIR}/.firewall_rule")
    chmod 600 "${CONFIG_DIR}/.firewall_rule"
}

add_ufw_rule() {
    local rule="$1" rules family source
    if ! rules=$(LC_ALL=C ufw status 2>/dev/null); then
        warn "无法读取 UFW 规则，未自动修改 ${rule}。"
        return 0
    fi
    local families=(4)
    if grep -Eq "^[[:space:]]*IPV6=[\"']?yes" /etc/default/ufw 2>/dev/null; then
        families+=(6)
    fi
    for family in "${families[@]}"; do
        if echo "$rules" | awk -v rule="$rule" -v family="$family" '
            {is6=($0 ~ /\(v6\)/); gsub(/ \(v6\)/, "")}
            is6==(family==6) && $1==rule && $2=="ALLOW" &&
                ($3=="Anywhere" || ($3=="IN" && $4=="Anywhere")) {found=1}
            END {exit !found}'; then
            continue
        fi
        source=0.0.0.0/0
        [[ "$family" != 6 ]] || source=::/0
        if ufw allow in proto "${rule#*/}" from "$source" to any port "${rule%/*}" comment buds-hy2 >/dev/null 2>&1; then
            record_firewall_rule ufw "$family" runtime "$rule"
        else
            warn "UFW IPv${family} 放行 ${rule} 失败，请检查服务器或服务商端口规则。"
        fi
    done
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
        systemctl enable hysteria-server
        systemctl restart hysteria-server
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
        if pgrep -fx "/usr/local/bin/hysteria server (-c|--config) /etc/hysteria/config[.]yaml" >/dev/null 2>&1; then
            success "Hysteria 2 服务已正常运行。"
        else
            error "服务未能正常启动，请查看日志: cat /var/log/hysteria.log"
            exit 1
        fi
    else
        pkill -fx "/usr/local/bin/hysteria server (-c|--config) /etc/hysteria/config[.]yaml" >/dev/null 2>&1 || true
        nohup /usr/local/bin/hysteria server -c "$CONFIG_FILE" >/var/log/hysteria.log 2>&1 &
        sleep 2
        if pgrep -fx "/usr/local/bin/hysteria server (-c|--config) /etc/hysteria/config[.]yaml" >/dev/null 2>&1; then
            success "Hysteria 2 服务已正常运行。"
        else
            error "服务未能正常启动，请查看日志: cat /var/log/hysteria.log"
            exit 1
        fi
    fi
}

setup_cli() {
    local client_insecure="false" client_pin="" pin_line=""
    if is_cert_self_signed; then
        client_insecure="true"
        client_pin=$(get_cert_pin) || { error "无法计算证书指纹，停止导出。"; return 1; }
        pin_line="  pinSHA256: ${client_pin}"
    fi

    printf '%s\n' "$CLIENT_PORT_STR" > "${CONFIG_DIR}/.public_port"
    chmod 600 "${CONFIG_DIR}/.public_port"
    if [[ "${IS_NAT:-false}" == true || "${IS_CONTAINER:-false}" == true ]]; then
        touch "${CONFIG_DIR}/.nat-mode"
        chmod 600 "${CONFIG_DIR}/.nat-mode"
    fi

    cat <<EOF > "$CLIENT_CONFIG_FILE"
server: ${DOMAIN}:${CLIENT_PORT_STR}
auth: "${AUTH_PASSWORD}"
tls:
  sni: ${DOMAIN}
  insecure: ${client_insecure}
${pin_line}
obfs:
  type: salamander
  salamander:
    password: "${OBFS_PASSWORD}"
# 带宽配置（Brutal 拥塞控制）：填入本地实际上下行速率；如在 TUN 模式遇 QoS 偶发断流，可注释此段以平滑走标准 BBR
bandwidth:
  up: 100 mbps
  down: 300 mbps
EOF
    chown root:root "$CLIENT_CONFIG_FILE" 2>/dev/null || true
    chmod 600 "$CLIENT_CONFIG_FILE"

    # 生成极客优雅的全局管理命令 /usr/local/bin/buds
    cat <<'BUDS_CLI_EOF' > "$BUDS_CLI"
#!/usr/bin/env bash
set -e

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
CLIENT_CONFIG_FILE="${CONFIG_DIR}/client.yaml"
SCRIPT_VERSION="1.6.2"
BUDS_CLI="/usr/local/bin/buds"
HY2_CLI="/usr/local/bin/hy2"
UPDATE_REPO_URL="https://raw.githubusercontent.com/Buds-2025/buds-hy2/updates"
UPDATE_PUBLIC_KEY="/etc/buds-hy2/update.pub"
VERSION_CACHE_FILE="${CONFIG_DIR}/.version_cache"
PROCESS_PATTERN='/usr/local/bin/hysteria server (-c|--config) /etc/hysteria/config[.]yaml'

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
        listen=$(sed -n 's/^[[:space:]]*listen:[[:space:]]*\(.*\)/\1/p' "$CONFIG_FILE" 2>/dev/null | tr -d ' "\047\r' | head -1)
        if [[ "$listen" == :* ]]; then
            listen="${listen#:}"
        elif [[ "$listen" =~ ^\[[^]]+\]:(.*)$ ]]; then
            listen="${BASH_REMATCH[1]}"
        elif [[ "$listen" =~ ^[^:]+:([0-9]+(-[0-9]+)?)$ ]]; then
            listen="${BASH_REMATCH[1]}"
        fi
    fi
    if [[ -z "$listen" && -f "$CLIENT_CONFIG_FILE" ]]; then
        listen=$(sed -n 's/^[[:space:]]*server:[[:space:]]*\(.*\)/\1/p' "$CLIENT_CONFIG_FILE" 2>/dev/null | tr -d ' "\047\r' | head -1)
        if [[ "$listen" =~ ^\[[^]]+\]:(.*)$ ]]; then
            listen="${BASH_REMATCH[1]}"
        else
            listen="${listen##*:}"
        fi
    fi
    echo "$listen"
}

get_public_ports() {
    local ports=""
    if [[ -f "$CLIENT_CONFIG_FILE" ]]; then
        ports=$(sed -n 's/^[[:space:]]*server:[[:space:]]*\(.*\)/\1/p' "$CLIENT_CONFIG_FILE" 2>/dev/null | tr -d ' "\047\r' | head -1)
        if [[ "$ports" =~ ^\[[^]]+\]:(.*)$ ]]; then
            ports="${BASH_REMATCH[1]}"
        elif [[ "$ports" == *:* ]]; then
            ports="${ports##*:}"
        else
            ports=""
        fi
    fi
    if [[ -z "$ports" && -f "${CONFIG_DIR}/.public_port" ]]; then
        ports=$(cat "${CONFIG_DIR}/.public_port")
    fi
    [[ -n "$ports" ]] || ports=$(get_listen)
    echo "$ports"
}

get_masquerade_url() {
    local url=""
    if [[ -f "$CONFIG_FILE" ]]; then
        url=$(awk '
          /^[[:space:]]*masquerade:/ { in_masq=1; next }
          in_masq && /^[^[:space:]#]/ { in_masq=0 }
          in_masq && /^[[:space:]]*url:[[:space:]]*/ {
            sub(/^[[:space:]]*url:[[:space:]]*/, "");
            gsub(/^["\047 ]+|["\047 \r]+$/, "");
            print;
            exit;
          }
        ' "$CONFIG_FILE" 2>/dev/null)
    fi
    [[ -n "$url" ]] || url="https://news.ycombinator.com/"
    echo "$url"
}

urlencode() {
    local s="$1" out="" i c hex
    local LC_ALL=C
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'	'/\\t}"
    printf '%s' "$s"
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

get_cert_pin() {
    local pin
    pin=$(openssl x509 -in "${CONFIG_DIR}/server.crt" -noout -fingerprint -sha256 2>/dev/null |
        sed 's/^[^=]*=//' | tr -d ':\r\n' | tr 'A-F' 'a-f') || return 1
    [[ "$pin" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$pin"
}

get_spki_pin() (
    set -o pipefail
    [[ -f "${CONFIG_DIR}/server.crt" ]] || return 1
    local spki
    spki=$(openssl x509 -in "${CONFIG_DIR}/server.crt" -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -outform der 2>/dev/null |
        openssl dgst -sha256 -binary 2>/dev/null |
        openssl enc -base64 2>/dev/null | tr -d '\r\n') || return 1
    [[ -n "$spki" ]] || return 1
    printf '%s\n' "$spki"
)

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
        pgrep -fx "$PROCESS_PATTERN" >/dev/null 2>&1 && is_running=true
    else
        local pids
        pids=$(pgrep -fx "$PROCESS_PATTERN" 2>/dev/null || true)
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
            echo -e "     ${C_GRAY_MID}证书类型:${C_RESET} ${C_CYAN}自签名 ECC 证书 (SHA-256 指纹固定)${C_RESET}"
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
        systemctl restart hysteria-server || return 1
    elif has_openrc; then
        rc-service hysteria-server restart || return 1
    elif [[ -x /usr/local/bin/hysteria-service ]]; then
        /usr/local/bin/hysteria-service restart || return 1
    else
        stop || return 1
        start || return 1
    fi
    echo -e "\n  ${C_BAR}  ${C_GREEN}✔ Hysteria 2 服务已成功重启。${C_RESET}\n"
}

stop() {
    if has_systemd; then
        systemctl stop hysteria-server || return 1
    elif has_openrc; then
        rc-service hysteria-server stop || return 1
    elif [[ -x /usr/local/bin/hysteria-service ]]; then
        /usr/local/bin/hysteria-service stop || return 1
    else
        if pgrep -fx "$PROCESS_PATTERN" >/dev/null 2>&1; then
            pkill -fx "$PROCESS_PATTERN"
            sleep 1
            if pgrep -fx "$PROCESS_PATTERN" >/dev/null 2>&1; then
                echo "Hysteria 2 尚未停止，请检查进程。" >&2
                return 1
            fi
        fi
    fi
    echo -e "\n  ${C_BAR}  ${C_AMBER}✔ Hysteria 2 服务已停止。${C_RESET}\n"
}

start() {
    if has_systemd; then
        systemctl start hysteria-server || return 1
    elif has_openrc; then
        rc-service hysteria-server start || return 1
    elif [[ -x /usr/local/bin/hysteria-service ]]; then
        /usr/local/bin/hysteria-service start || return 1
    else
        if ! pgrep -fx "$PROCESS_PATTERN" >/dev/null 2>&1; then
            nohup /usr/local/bin/hysteria server -c "${CONFIG_FILE}" >/var/log/hysteria.log 2>&1 &
            sleep 1
        fi
        if ! pgrep -fx "$PROCESS_PATTERN" >/dev/null 2>&1; then
            echo "Hysteria 2 启动失败，请检查 /var/log/hysteria.log。" >&2
            return 1
        fi
    fi
    echo -e "\n  ${C_BAR}  ${C_GREEN}✔ Hysteria 2 服务已启动。${C_RESET}\n"
}

link() {
    if [[ ! -f "$CONFIG_FILE" && ! -f "$CLIENT_CONFIG_FILE" ]]; then
        echo -e "\n  ${C_RED}✖ 未检测到 Hysteria 2 配置文件。${C_RESET}\n"
        return 1
    fi

    local domain password obfs_pwd listen public_ports base_port label
    domain=$(get_domain)
    password=$(get_password)
    obfs_pwd=$(get_obfs_pwd)
    listen=$(get_listen)
    public_ports=$(get_public_ports)
    base_port=$(echo "$public_ports" | grep -o '^[0-9]\+' || echo "443")
    [[ -n "$base_port" ]] || base_port=443
    label="$domain"
    [[ -z "${NODE_LABEL:-}" ]] || label="$domain-$NODE_LABEL"

    local enc_password enc_obfs_pwd
    enc_password=$(urlencode "$password")
    enc_obfs_pwd=$(urlencode "$obfs_pwd")
    local obfs_param=""
    if [[ -n "$obfs_pwd" ]]; then
        obfs_param="&obfs=salamander&obfs-password=${enc_obfs_pwd}"
    fi

    local pin_param=""
    local cert_badge="${C_GREEN}CA 权威证书 (标准安全校验)${C_RESET}"
    local pin=""
    if is_cert_self_signed; then
        pin=$(get_cert_pin) || { echo "无法计算证书指纹，停止导出。"; return 1; }
        pin_param="&pinSHA256=${pin}"
        cert_badge="${C_CYAN}自签名 ECC 证书 (SHA-256 指纹锁定 · 免 80 端口)${C_RESET}"
    fi

    echo -e "\n  ${C_BAR}  ${C_WHITE}节点连接凭据 · CONNECTION CREDENTIALS${C_RESET}"
    echo -e "     ${C_GRAY_MID}域名 (SNI)  :${C_RESET} ${C_WHITE}${domain}${C_RESET}"
    echo -e "     ${C_GRAY_MID}证书类型    :${C_RESET} ${cert_badge}"
    if is_cert_self_signed && [[ -n "$pin" ]]; then
        echo -e "     ${C_GRAY_MID}证书指纹    :${C_RESET} ${C_YELLOW}${pin}${C_RESET}"
    fi
    echo -e "     ${C_GRAY_MID}监听端口    :${C_RESET} ${C_CYAN}${listen}${C_RESET}"
    echo -e "     ${C_GRAY_MID}公网端口    :${C_RESET} ${C_CYAN}${public_ports}${C_RESET} ${C_GRAY_MID}(连接基准端口: ${base_port})${C_RESET}"
    echo -e "     ${C_GRAY_MID}认证密码    :${C_RESET} ${C_WHITE}${password}${C_RESET}"
    echo -e "     ${C_GRAY_MID}协议混淆    :${C_RESET} ${C_AMBER}salamander${C_RESET}"
    echo -e "     ${C_GRAY_MID}混淆密钥    :${C_RESET} ${C_WHITE}${obfs_pwd}${C_RESET}"
    local masq_url; masq_url=$(get_masquerade_url)
    echo -e "     ${C_GRAY_MID}伪装反代    :${C_RESET} ${C_GRAY_LIGHT}${masq_url}${C_RESET}\n"

    if [[ -n "$pin" || "$public_ports" == *-* ]]; then
        local native_tls="$pin_param"
        [[ -z "$pin" ]] || native_tls+="&insecure=1"
        printf '  Hysteria 2 原生链接（用作客户端的 server，自签名请用 2.6.4 或更新版本）\n'
        printf '     hysteria2://%s@%s:%s/?sni=%s%s%s#%s-Hy2\n\n' \
            "$enc_password" "$domain" "$public_ports" "$domain" "$native_tls" "$obfs_param" "$label"
    fi

    if [[ "$public_ports" == *-* ]]; then
        local link_hop="hysteria2://${enc_password}@${domain}:${base_port}?sni=${domain}${pin_param}${obfs_param}&mport=${public_ports}#${label}-Hy2"
        local link_single="hysteria2://${enc_password}@${domain}:${base_port}?sni=${domain}${pin_param}${obfs_param}#${label}-Hy2-Single"

        echo -e "  ${C_SUBBAR}  ${C_ORANGE_BOLD}第三方导入链接（需确认客户端支持 mport）${C_RESET}"
        echo -e "     ${C_YELLOW}${link_hop}${C_RESET}\n"

        echo -e "  ${C_SUBBAR}  ${C_ORANGE_BOLD}格式 2 · 基准单端口链接${C_RESET} ${C_GRAY_MID}(固定单端口 · 固定端口备用)${C_RESET}"
        echo -e "     ${C_YELLOW}${link_single}${C_RESET}\n"
    else
        local link_main="hysteria2://${enc_password}@${domain}:${base_port}?sni=${domain}${pin_param}${obfs_param}#${label}-Hy2"

        echo -e "  ${C_SUBBAR}  ${C_ORANGE_BOLD}节点连接链接${C_RESET}"
        echo -e "     ${C_YELLOW}${link_main}${C_RESET}\n"
    fi

    if [[ -n "$pin" ]]; then
        echo "     自签名节点仅用于能强制验证指纹的客户端。可用 buds hy2 client 获取对应配置。"
    fi
}

client() {
    if [[ ! -f "$CONFIG_FILE" && ! -f "$CLIENT_CONFIG_FILE" ]]; then
        echo -e "\n  ${C_RED}✖ 未检测到服务端配置文件 $CONFIG_FILE。${C_RESET}\n"
        return 1
    fi

    local client_insecure="false" client_pin="" pin_line=""
    if is_cert_self_signed; then
        client_insecure="true"
        client_pin=$(get_cert_pin) || { echo "无法计算证书指纹，停止导出。"; return 1; }
        pin_line="  pinSHA256: ${client_pin}"
    fi

    local domain password obfs_pwd public_ports base_port
    domain=$(get_domain)
    password=$(get_password)
    obfs_pwd=$(get_obfs_pwd)
    public_ports=$(get_public_ports)
    base_port=$(echo "$public_ports" | grep -o '^[0-9]\+' || echo "443")
    [[ -n "$base_port" ]] || base_port=443

    if [[ ! -f "$CLIENT_CONFIG_FILE" ]]; then
        cat <<CLIENT_YAML_EOF > "$CLIENT_CONFIG_FILE"
server: ${domain}:${public_ports}
auth: "${password}"
tls:
  sni: ${domain}
  insecure: ${client_insecure}
${pin_line}
obfs:
  type: salamander
  salamander:
    password: "${obfs_pwd}"
# 带宽配置（Brutal 拥塞控制）：填入本地实际上下行速率；如在 TUN 模式遇 QoS 偶发断流，可注释此段以平滑走标准 BBR
bandwidth:
  up: 100 mbps
  down: 300 mbps
CLIENT_YAML_EOF
        chown root:root "$CLIENT_CONFIG_FILE" 2>/dev/null || true
        chmod 600 "$CLIENT_CONFIG_FILE"
    else
        local updated
        updated=$(mktemp "${CLIENT_CONFIG_FILE}.XXXXXX") || return 1
        if ! awk -v insecure="$client_insecure" -v pin="$client_pin" -v domain="$(get_domain)" '
            function security() {
                print "  insecure: " insecure
                if (pin!="") print "  pinSHA256: " pin
            }
            /^tls:[[:space:]]*$/ {found=1; in_tls=1; print; security(); next}
            /^[^[:space:]#]/ {in_tls=0}
            in_tls && /^[[:space:]]*(insecure|pinSHA256):/ {next}
            {print}
            END {if (!found) {print "tls:"; print "  sni: " domain; security()}}
        ' "$CLIENT_CONFIG_FILE" > "$updated"; then
            rm -f "$updated"
            return 1
        fi
        mv -f "$updated" "$CLIENT_CONFIG_FILE"
    fi
    chown root:root "$CLIENT_CONFIG_FILE" 2>/dev/null || true
    chmod 600 "$CLIENT_CONFIG_FILE"

    echo -e "\n  ${C_BAR}  ${C_WHITE}配置 1 · Hysteria 2 原生客户端配置 (${CLIENT_CONFIG_FILE})${C_RESET}\n"
    cat "$CLIENT_CONFIG_FILE"
    echo ""

    echo -e "  ${C_BAR}  ${C_WHITE}配置 2 · sing-box 1.14+ 原生 Outbound JSON 片段${C_RESET} ${C_GRAY_MID}(适配 v2rayN 自定义配置 / sing-box)${C_RESET}\n"
    local spki_pin=""
    if [[ -n "$client_pin" ]]; then
        spki_pin=$(get_spki_pin 2>/dev/null || true)
    fi

    local j_domain j_password j_obfs
    j_domain=$(json_escape "$domain")
    j_password=$(json_escape "$password")
    j_obfs=$(json_escape "$obfs_pwd")
    if [[ -n "$client_pin" && -z "$spki_pin" ]]; then
        echo "  无法计算公钥指纹，已跳过 sing-box 配置。"
    else
        printf '{\n  "type": "hysteria2",\n  "tag": "hy2-out",\n  "server": "%s",\n' "$j_domain"
        if [[ "$public_ports" == *-* ]]; then
            printf '  "server_ports": ["%s"],\n  "hop_interval": "30s",\n' "${public_ports//-/:}"
        else
            printf '  "server_port": %s,\n' "$base_port"
        fi
        printf '  "password": "%s",\n' "$j_password"
        if [[ -n "$obfs_pwd" ]]; then
            printf '  "obfs": {"type": "salamander", "password": "%s"},\n' "$j_obfs"
        fi
        printf '  "tls": {\n    "enabled": true,\n    "server_name": "%s",\n    "insecure": false' "$j_domain"
        if [[ -n "$spki_pin" ]]; then
            printf ',\n    "certificate_public_key_sha256": ["%s"]' "$spki_pin"
        fi
        printf '\n  }\n}\n\n'
    fi

    echo -e "  ${C_BAR}  ${C_WHITE}配置 3 · Mihomo 节点配置片段${C_RESET}\n"
    echo -e "  ${C_YELLOW}- name: \"Hy2-${domain}${NODE_LABEL:+-$NODE_LABEL}\""
    echo -e "    type: hysteria2"
    echo -e "    server: ${domain}"
    echo -e "    port: ${base_port}"
    if [[ "$public_ports" == *-* ]]; then
        echo -e "    ports: ${public_ports}"
    fi
    printf '    password: "%s"\n' "$j_password"
    echo -e "    sni: ${domain}"
    echo -e "    skip-cert-verify: false"
    if is_cert_self_signed && [[ -n "$client_pin" ]]; then
        echo -e "    fingerprint: \"${client_pin}\""
    fi
    if [[ -n "$obfs_pwd" ]]; then
        echo -e "    obfs: salamander"
        printf '    obfs-password: "%s"\n' "$j_obfs"
    fi
    echo -e "${C_RESET}"
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
    local rule="$1" family="${2:--}" rules numbers number
    rules=$(LC_ALL=C ufw status numbered 2>/dev/null) || return 1
    if [[ "$rules" == *"Status: active"* ]]; then
        # 按编号倒序删除带本项目注释的条目，分别保护 IPv4/IPv6 的其他规则。
        numbers=$(echo "$rules" | awk -v rule="$rule" -v family="$family" '
          /# buds-hy2[[:space:]]*$/ {
            is6=($0 ~ /\(v6\)/)
            if ((family==4 && is6) || (family==6 && !is6)) next
            line=$0; sub(/^\[[[:space:]]*[0-9]+\][[:space:]]*/, "", line)
            split(line, fields, /[[:space:]]+/)
            if (fields[1]==rule) {sub(/^\[[[:space:]]*/, ""); sub(/\].*$/, ""); print}
          }' | sort -rn)
        for number in $numbers; do
            ufw --force delete "$number" >/dev/null 2>&1 || return 1
        done
    else
        # UFW 停用时，show added 仍可读取持久规则；同时兼容旧格式与带 proto/from 的规则格式。
        rules=$(LC_ALL=C ufw show added 2>/dev/null) || return 1
        local port="${rule%/*}" proto="${rule#*/}"
        local owned_simple="ufw allow ${rule} comment 'buds-hy2'"
        local owned_v4="ufw allow in proto ${proto} from 0.0.0.0/0 to any port ${port} comment 'buds-hy2'"
        local owned_v6="ufw allow in proto ${proto} from ::/0 to any port ${port} comment 'buds-hy2'"
        local has_other=false
        if echo "$rules" | awk -v rule="$rule" -v port="$port" -v proto="$proto" -v tag="comment 'buds-hy2'" '
            /^ufw allow / {
                is_target = ($0 ~ "^ufw allow " rule "([[:space:]]|$)" || ($0 ~ "proto " proto " " && $0 ~ "to any port " port "([[:space:]]|$)"))
                if (is_target && (length($0) < length(tag) || substr($0, length($0)-length(tag)+1) != tag)) {found=1}
            }
            END {exit !found}'; then
            has_other=true
        fi
        if echo "$rules" | grep -Fxq "$owned_simple"; then
            [[ "$has_other" == false ]] || return 1
            ufw --force delete allow "$rule" comment buds-hy2 >/dev/null 2>&1 || return 1
        fi
        if [[ "$family" != 6 ]] && echo "$rules" | grep -Fxq "$owned_v4"; then
            [[ "$has_other" == false ]] || return 1
            ufw --force delete allow in proto "$proto" from 0.0.0.0/0 to any port "$port" comment buds-hy2 >/dev/null 2>&1 || return 1
        fi
        if [[ "$family" != 4 ]] && echo "$rules" | grep -Fxq "$owned_v6"; then
            [[ "$has_other" == false ]] || return 1
            ufw --force delete allow in proto "$proto" from ::/0 to any port "$port" comment buds-hy2 >/dev/null 2>&1 || return 1
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
                remove_ufw_rule "$rule" "$zone" || result=1
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
            if ! printf '%s|%s|%s|%s\n' "$backend" "$zone" "$mode" "$rule" >> "$remaining"; then
                rm -f -- "$remaining"
                return 1
            fi
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
    if ! mv -f "$remaining" "$rule_file"; then
        rm -f -- "$remaining"
        return 1
    fi
    if [[ "$failed" == true ]]; then
        echo "  部分防火墙规则未能安全清理，已保留配置和规则记录，请检查权限后重试卸载。"
        return 1
    fi
    rm -f "$rule_file"
}

read_root_crontab() {
    local contents
    if contents=$(LC_ALL=C crontab -l 2>&1); then
        printf '%s\n' "$contents"
    elif [[ "$contents" == *"no crontab"* || "$contents" == *"No such file"* ]]; then
        return 0
    else
        echo "无法读取 root 定时任务，未覆盖已有任务。" >&2
        return 1
    fi
}

cleanup_renewal() {
    if [[ -f /etc/systemd/system/buds-hy2-renew.timer ]]; then
        if has_systemd; then
            systemctl disable --now buds-hy2-renew.timer || return 1
        fi
        rm -f /etc/systemd/system/buds-hy2-renew.timer /etc/systemd/system/buds-hy2-renew.service || return 1
        if has_systemd; then systemctl daemon-reload || return 1; fi
    fi
    if command -v crontab >/dev/null 2>&1; then
        local contents
        contents=$(read_root_crontab) || return 1
        if printf '%s\n' "$contents" | grep -q '# buds-hy2-renew$'; then
            printf '%s\n' "$contents" | sed '/# buds-hy2-renew$/d' | crontab - || return 1
        fi
    fi
    if [[ -f /etc/periodic/daily/certbot-renew ]] &&
       grep -q '^# buds-hy2-renew$' /etc/periodic/daily/certbot-renew; then
        rm -f /etc/periodic/daily/certbot-renew
    fi
}

# 专用虚拟地址与公网 CDN 地址分离，同一公网 IP 可同时承载原生和 WARP 连接。
WARP_DIR=/etc/buds-hy2/warp-split
WARP_UNIT=buds-warp-split.service
WARP_LIST=/etc/buds-hy2/warp-domains
WARP_GEMINI_FAMILY=/etc/buds-hy2/warp-gemini-family
WARP_TOOLS=/etc/buds-hy2/warp-tools
WARP_DNS_STATE=/etc/buds-hy2/warp-dns
WARP_DNS_DROPIN=/etc/systemd/resolved.conf.d/90-buds-warp-static-dns.conf
WARP_STUB=/run/systemd/resolve/stub-resolv.conf

warp_exec_safe() {
    local path=$1 info mode
    while :; do
        info=$(stat -Lc '%u %a' -- "$path") || return 1
        mode=${info##* }
        [[ "$info" == '0 '* && "$mode" =~ ^[0-7]{3,4}$ ]] &&
            (( (8#$mode & 022) == 0 )) || return 1
        [[ "$path" == / ]] && return 0
        path=${path%/*}
        [[ -n "$path" ]] || path=/
    done
}

warp_find_binary() {
    local pid live candidate path version
    pid=$(systemctl show -p MainPID --value sing-box.service 2>/dev/null) || pid=
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then live=$(readlink -e "/proc/$pid/exe") || live=; fi
    for candidate in "${BUDS_SING_BOX_BIN:-}" "$WARP_TOOLS/sing-box" "$live" /etc/s-box/sing-box "$(type -P sing-box || true)" \
        /usr/local/bin/sing-box /usr/bin/sing-box; do
        [[ -n "$candidate" && -f "$candidate" && -x "$candidate" ]] || continue
        path=$(readlink -e -- "$candidate") || continue
        [[ "$path" =~ ^/[a-zA-Z0-9_./-]+$ ]] && warp_exec_safe "$path" || continue
        version=$("$path" version 2>/dev/null | awk 'NR==1 && $1=="sing-box" && $2=="version" {print $3}')
        if [[ "$version" =~ ^1\.([0-9]+)\.[0-9]+$ && ${BASH_REMATCH[1]} -ge 12 ]]; then
            printf '%s %s\n' "$path" "$version"
            return 0
        fi
    done
    echo "没有找到可用的 sing-box 1.12+。可运行 buds hy2 warp setup 下载独立内核。" >&2
    return 1
}

warp_find_profile() {
    local path
    for path in "$WARP_TOOLS/wgcf-profile.conf" /etc/warp/wgcf-profile.conf \
        /etc/warp-unlock/wgcf-profile.conf /etc/wireguard/warp.conf; do
        if [[ -f "$path" && -r "$path" ]]; then printf '%s\n' "$path"; return 0; fi
    done
    echo "缺少独立的 WARP WireGuard 配置。可运行 buds hy2 warp setup 注册并生成。" >&2
    return 1
}

warp_resolve_profile() {
    if [[ -z "${1:-}" ]]; then warp_find_profile; return; fi
    [[ -f "$1" && -r "$1" ]] || { echo "无法读取 WireGuard 配置文件：$1" >&2; return 1; }
    printf '%s\n' "$1"
}

warp_runtime_binary() {
    local path
    path=$(sed -n 's|^ExecStart=\(/[-a-zA-Z0-9_./]*\) run -c .*|\1|p' "$WARP_DIR/$WARP_UNIT") || return 1
    [[ "$path" =~ ^/[a-zA-Z0-9_./-]+$ && -x "$path" ]] && warp_exec_safe "$(readlink -e -- "$path")" ||
        { echo "已配置的 sing-box 无法使用，请检查服务定义。" >&2; return 1; }
    printf '%s\n' "$path"
}

warp_download_tool() (
    local tool=$1 arch url digest member dir
    arch=$(uname -m)
    case "$tool/$arch" in
        sing-box/x86_64|sing-box/amd64)
            arch=amd64; digest=699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968 ;;
        sing-box/aarch64|sing-box/arm64)
            arch=arm64; digest=436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26 ;;
        wgcf/x86_64|wgcf/amd64)
            arch=amd64; digest=4fb7a136aa470ece11d17949c7db07b040ec9c604742dc8680bcf1889f85d0c8 ;;
        wgcf/aarch64|wgcf/arm64)
            arch=arm64; digest=710ab2d8ac145d81a4cf0c11bdb0e05914f77ae2a45f67b87e718d84b4cb7301 ;;
        *) echo "此架构需要手动安装 $tool，详见 README。" >&2; return 1 ;;
    esac
    if [[ "$tool" == sing-box ]]; then
        member="sing-box-1.14.4-linux-$arch/sing-box"
        url="https://github.com/SagerNet/sing-box/releases/download/v1.14.4/${member%/*}.tar.gz"
    else
        url="https://github.com/ViRb3/wgcf/releases/download/v2.3.1/wgcf_2.3.1_linux_${arch}"
    fi
    dir=$(mktemp -d "$WARP_TOOLS/.download.XXXXXX") || return 1
    trap 'rm -rf -- "$dir"' EXIT
    curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --max-time 180 \
        --max-filesize 67108864 "$url" -o "$dir/package" || return 1
    if ! printf '%s  %s\n' "$digest" "$dir/package" | sha256sum --check --status; then
        echo "$tool 下载文件校验失败。" >&2
        return 1
    fi
    if [[ "$tool" == sing-box ]]; then
        tar -xOzf "$dir/package" -- "$member" > "$dir/$tool" || return 1
    else
        mv -- "$dir/package" "$dir/$tool" || return 1
    fi
    chmod 700 "$dir/$tool" && "$dir/$tool" --help >/dev/null && mv -f -- "$dir/$tool" "$WARP_TOOLS/$tool"
)

warp_setup() (
    local detected profile wgcf
    umask 077
    [[ ! -L "$WARP_TOOLS" ]] && mkdir -p -- "$WARP_TOOLS" && warp_exec_safe "$WARP_TOOLS" || return 1
    if [[ "${1:-}" == --managed-core && ! -x "$WARP_TOOLS/sing-box" ]]; then
        warp_download_tool sing-box || return 1
    fi
    detected=$(warp_find_binary 2>/dev/null) || {
        warp_download_tool sing-box || return 1
        detected=$(warp_find_binary) || return 1
    }
    printf 'sing-box：%s\n' "$detected"
    if [[ "${1:-}" == --new-profile && ! -s "$WARP_TOOLS/wgcf-profile.conf" ]] ||
        ! profile=$(warp_find_profile 2>/dev/null); then
        wgcf=$(type -P wgcf) || wgcf="$WARP_TOOLS/wgcf"
        if [[ ! -x "$wgcf" ]]; then warp_download_tool wgcf || return 1; fi
        wgcf=$(readlink -e -- "$wgcf") && warp_exec_safe "$wgcf" || return 1
        cd "$WARP_TOOLS" || return 1
        if [[ ! -s wgcf-account.toml ]]; then
            [[ -t 0 ]] || { echo "请在服务器终端运行此命令并阅读 wgcf 的条款提示。" >&2; return 1; }
            if ! "$wgcf" register; then
                echo "WARP 注册未完成。可重新选择「准备依赖」，已有注册记录会自动复用。" >&2
                return 1
            fi
        fi
        "$wgcf" generate || { echo "生成 WireGuard 配置失败，请检查上方 wgcf 输出。" >&2; return 1; }
        profile=$(warp_find_profile) || return 1
        chmod 600 "$profile" || return 1
    fi
    printf 'WARP 配置：%s\n' "$profile"
    if warp_check_stub 2>/dev/null; then
        echo "依赖已准备。可以选择「启用」。"
    else
        echo "依赖已准备。静态 DNS 主机请选择「迁移 DNS」，再启用分流。"
    fi
)

warp_dns_replace() (
    local source=$1 work
    work=$(mktemp -d /etc/.buds-resolv.XXXXXX) || return 1
    trap 'rm -rf -- "$work"' EXIT
    cp -a -- "$source" "$work/resolv.conf" && mv -Tf -- "$work/resolv.conf" /etc/resolv.conf
)

warp_dns_restore() {
    [[ -d "$WARP_DNS_STATE" ]] || { echo "没有由 buds 切换的 DNS 配置。"; return 0; }
    local original="$WARP_DNS_STATE/resolv.conf" expected="$WARP_DNS_STATE/resolved.conf"
    [[ -f "$original" && -f "$expected" ]] || return 1
    if [[ -L /etc/resolv.conf && $(readlink -- /etc/resolv.conf) == "$WARP_STUB" ]]; then
        :
    elif [[ ! -L /etc/resolv.conf ]] && cmp -s -- /etc/resolv.conf "$original"; then
        :
    else
        echo "/etc/resolv.conf 已被其他程序修改，请先检查 $original。" >&2
        return 1
    fi
    if [[ -e "$WARP_DNS_DROPIN" || -L "$WARP_DNS_DROPIN" ]]; then
        [[ ! -L "$WARP_DNS_DROPIN" ]] && cmp -s -- "$expected" "$WARP_DNS_DROPIN" ||
            { echo "DNS 配置片段已被修改，请检查 $WARP_DNS_DROPIN。" >&2; return 1; }
    fi
    warp_dns_replace "$original" && rm -f -- "$WARP_DNS_DROPIN" &&
        systemctl restart systemd-resolved &&
        rm -f -- "$original" "$expected" &&
        rmdir -- "$WARP_DNS_STATE" || return 1
    echo "已恢复切换前的 DNS 配置。"
}

warp_dns_switch() (
    warp_check_stub 2>/dev/null && { echo "系统已使用 systemd-resolved 存根。"; return 0; }
    systemctl is-active --quiet systemd-resolved && [[ -f "$WARP_STUB" ]] ||
        { echo "需要已运行并开启 127.0.0.53 存根的 systemd-resolved。" >&2; return 1; }
    [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf && ! -e "$WARP_DNS_STATE" &&
        ! -e "$WARP_DNS_DROPIN" && ! -L "$WARP_DNS_DROPIN" ]] ||
        { echo "检测到已有的 DNS 管理或迁移状态，请先检查 /etc/resolv.conf。" >&2; return 1; }
    local upstream dropin_dir mode
    upstream=$(python3 -I - /etc/resolv.conf <<'PY'
from ipaddress import ip_address
import sys
servers = []
try:
    with open(sys.argv[1]) as source:
        for line in source:
            words = line.partition("#")[0].split()
            if not words:
                continue
            if len(words) != 2 or words[0] != "nameserver" or "%" in words[1]:
                raise ValueError()
            address = ip_address(words[1])
            if not address.is_global:
                raise ValueError()
            servers.append(str(address))
    if not servers:
        raise ValueError()
except ValueError:
    sys.exit("自动切换仅支持由公网 nameserver 组成的静态文件；自定义 DNS、search 和 options 需由管理员迁移。")
print(" ".join(dict.fromkeys(servers)))
PY
    ) || return 1
    dropin_dir=$(dirname "$WARP_DNS_DROPIN") || return 1
    mkdir -p -m 0755 -- "$dropin_dir" || return 1
    mode=$(stat -Lc %a -- "$dropin_dir") || return 1
    if (( (8#$mode & 001) == 0 )); then
        echo "解析服务可能无法读取 $dropin_dir。请检查目录是否允许 systemd-resolved 访问。" >&2
        return 1
    fi
    umask 077
    mkdir -p -- "$(dirname "$WARP_DNS_STATE")" &&
        mkdir -- "$WARP_DNS_STATE" || return 1
    if ! cp -a -- /etc/resolv.conf "$WARP_DNS_STATE/resolv.conf" ||
        ! printf '[Resolve]\nDNS=\nDNS=%s\n' "$upstream" > "$WARP_DNS_STATE/resolved.conf"; then
        rm -f -- "$WARP_DNS_STATE"/{resolv.conf,resolved.conf}
        rmdir -- "$WARP_DNS_STATE"
        return 1
    fi
    trap 'rc=$?; if ((rc)); then warp_dns_restore || echo "DNS 自动恢复失败，备份在 $WARP_DNS_STATE。" >&2; fi' EXIT
    local work
    work=$(mktemp -d /etc/.buds-resolv-link.XXXXXX) || return 1
    if ! install -m 0644 -- "$WARP_DNS_STATE/resolved.conf" "$work/resolved.conf" ||
        ! ln -- "$work/resolved.conf" "$WARP_DNS_DROPIN" ||
        ! ln -s -- "$WARP_STUB" "$work/resolv.conf" || ! warp_dns_replace "$work/resolv.conf"; then
        rm -f -- "$work"/{resolv.conf,resolved.conf}; rmdir -- "$work"
        return 1
    fi
    rm -f -- "$work"/{resolv.conf,resolved.conf}; rmdir -- "$work"
    systemctl restart systemd-resolved &&
        warp_check_stub &&
        timeout 15 getent ahostsv4 github.com >/dev/null ||
        { echo "切换后 DNS 查询失败，正在恢复原配置。" >&2; return 1; }
    echo "系统已使用本机存根，原上游已保留：$upstream。可用 buds hy2 warp dns-restore 撤销。"
)

warp_domains() {
    cat <<'DOMAINS'
google.com google.ad google.ae google.com.af google.com.ag google.al google.am google.co.ao
google.com.ar google.as google.at google.com.au google.az google.ba google.com.bd google.be
google.bf google.bg google.com.bh google.bi google.bj google.com.bn google.com.bo google.com.br
google.bs google.bt google.co.bw google.by google.com.bz google.ca google.cd google.cf
google.cg google.ch google.ci google.co.ck google.cl google.cm google.cn google.com.co
google.co.cr google.com.cu google.cv google.com.cy google.cz google.de google.dj google.dk
google.dm google.com.do google.dz google.com.ec google.ee google.com.eg google.es google.com.et
google.fi google.com.fj google.fm google.fr google.ga google.ge google.gg google.com.gh
google.com.gi google.gl google.gm google.gr google.com.gt google.gy google.com.hk google.hn
google.hr google.ht google.hu google.co.id google.ie google.co.il google.im google.co.in
google.iq google.is google.it google.je google.com.jm google.jo google.co.jp google.co.ke
google.com.kh google.ki google.kg google.co.kr google.com.kw google.kz google.la google.com.lb
google.li google.lk google.co.ls google.lt google.lu google.lv google.com.ly google.co.ma
google.md google.me google.mg google.mk google.ml google.com.mm google.mn google.com.mt
google.mu google.mv google.mw google.com.mx google.com.my google.co.mz google.com.na google.com.ng
google.com.ni google.ne google.nl google.no google.com.np google.nr google.nu google.co.nz
google.com.om google.com.pa google.com.pe google.com.pg google.com.ph google.com.pk google.pl google.pn
google.com.pr google.ps google.pt google.com.py google.com.qa google.ro google.ru google.rw
google.com.sa google.com.sb google.sc google.se google.com.sg google.sh google.si google.sk
google.com.sl google.sn google.so google.sm google.sr google.st google.com.sv google.td
google.tg google.co.th google.com.tj google.tl google.tm google.tn google.to google.com.tr
google.tt google.com.tw google.co.tz google.com.ua google.co.ug google.co.uk google.com.uy google.co.uz
google.com.vc google.co.ve google.co.vi google.com.vn google.vu google.ws google.rs google.co.za
google.co.zm google.co.zw google.cat
googleapis.com googleapis.cn gstatic.com gstatic.cn googleusercontent.com ggpht.com
googleplay.com play.googleapis.cn gvt1.com gvt2.com gvt3.com android.com android.clients.google.com
gmail.com googlemail.com drive.google docs.google goo.gl chrome.com chromecast.com
youtube.com youtu.be yt.be googlevideo.com ytimg.com youtube-nocookie.com youtubei.googleapis.com
youtubekids.com youtubeeducation.com withyoutube.com
gemini.google gemini.app.google deepmind.google deepmind.com ai.google.dev ai.studio
antigravity.google notebooklm.google generativeai.google
DOMAINS
}

# 同一份校验逻辑用于命令行编辑和服务启动。base.json 保留隧道参数。
warp_policy_tool() {
    cat <<'PY'
import json
from ipaddress import ip_address, ip_interface, ip_network
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile

def domain(value):
    if value.endswith("."):
        value = value[:-1]
    if not value or "*" in value:
        raise ValueError("请输入域名，子域名会自动匹配")
    name = value.encode("idna").decode("ascii").lower()
    labels = name.split(".")
    if (len(name) > 253 or len(labels) < 2 or labels[-1].isdigit() or
            not all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", x) for x in labels)):
        raise ValueError("域名格式无效：" + value)
    return name

def names(path):
    def parse(lines):
        return {domain(token) for line in lines for token in line.partition("#")[0].split()}
    if path == "-":
        return parse(sys.stdin)
    with open(path, encoding="utf-8-sig") as source:
        return parse(source)

def atomic(path, data):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as f:
        try:
            f.write(data)
            f.close()
            os.replace(f.name, path)
        finally:
            if os.path.exists(f.name):
                os.unlink(f.name)

def gemini_resolver(cfg, selected, family_path):
    if not family_path or not os.path.isfile(family_path):
        return
    family = Path(family_path).read_text(encoding="utf-8").strip()
    if family == "auto":
        return
    if family not in ("ipv4", "ipv6"):
        raise ValueError("Gemini 出口地址族须为 auto、ipv4 或 ipv6。")
    gemini = ("gemini.google.com", "gemini.google", "gemini.app.google", "geminiweb-pa.clients6.google.com")
    targets = [host for host in gemini if any(host == d or host.endswith("." + d) for d in selected)]
    if not targets:
        return
    endpoint = cfg["endpoints"][0]
    version = int(family[-1])
    families = {ip_interface(address).version for address in endpoint["address"]}
    allowed = {ip_network(net).version for peer in endpoint["peers"] for net in peer["allowed_ips"]}
    if version not in families & allowed:
        raise ValueError(f"当前 WireGuard 配置没有可用的 {family.upper()} 隧道地址和 AllowedIPs。")
    wanted, suppressed = ("AAAA", "A") if version == 6 else ("A", "AAAA")
    dns_rules = cfg["dns"]["rules"]
    if wanted not in dns_rules[0].get("query_type", []):
        raise ValueError(f"当前 WARP 分流无法发布 {wanted} 地址。")
    # TUN 入站和 WireGuard 出站使用同一地址族，让客户端直接选择可用的虚拟地址。
    dns_rules.insert(0, {"inbound": "split", "domain_suffix": targets, "query_type": [suppressed],
                         "action": "predefined", "rcode": "NOERROR"})
    rules = cfg["route"]["rules"]
    for i, rule in enumerate(rules):
        if rule.get("action") == "resolve" and "domain_suffix" in rule:
            rules[i:i] = [
                dict(rule, domain_suffix=targets, strategy=family + "_only"),
                {"domain_suffix": targets, "action": "route", "outbound": "warp"},
            ]
            return
    raise ValueError("现有 WARP 配置缺少域名解析规则，请检查配置后重试。")


def render(template, policy, dest, family_path=None):
    with open(template, encoding="utf-8") as f:
        cfg = json.load(f)
    if os.path.isfile(policy):
        selected = sorted(names(policy))
    else:
        selected = sorted(set(cfg["dns"]["rules"][0]["domain_suffix"]))
    for peer in cfg["endpoints"][0]["peers"]:
        host = peer["address"].rstrip(".").lower()
        if any(host == d or host.endswith("." + d) for d in selected):
            raise ValueError("清单覆盖了 WireGuard 服务器域名，无法通过原生 DNS 建立隧道：" + host)
    for section in ("dns", "route"):
        rules = cfg[section]["rules"]
        if selected:
            for rule in rules:
                if "domain_suffix" in rule:
                    rule["domain_suffix"] = selected
        else:
            cfg[section]["rules"] = [] if section == "dns" else [{"action": "reject"}]
    if selected:
        gemini_resolver(cfg, selected, family_path)
        trace_address = next(s["server"] for s in cfg["dns"]["servers"] if s["tag"] == "real")
        cfg["route"]["rules"].insert(0, {
            "inbound": "split", "network": "tcp", "ip_cidr": "198.18.240.3/32", "port": 443,
            "action": "route", "outbound": "warp", "override_address": trace_address})
    out = Path(dest)
    atomic(out / "config.json", json.dumps(cfg))
    atomic(out / "domains", "".join(d + "\n" for d in selected))

def check_resolved_domains(path):
    selected = names(path)
    scope = None
    for line in sys.stdin:
        if not line.strip():
            continue
        header = re.fullmatch(r"\s*(Global|Link \d+ \(([^()]+)\)):\s*(.*)", line.rstrip())
        if header:
            scope, interface, entries = header.groups()
        elif scope and line[0].isspace():
            entries = line.strip()
        else:
            raise ValueError("无法识别 resolvectl domain 输出：" + line.strip())
        if interface == "buds-warp0":
            continue
        for entry in entries.split():
            # 普通搜索域和 ~ 路由域均参与 resolved 的最长后缀匹配。
            suffix = entry.lstrip("~").rstrip(".").lower()
            labels = suffix.split(".")
            if any(".".join(labels[i:]) in selected for i in range(len(labels))):
                raise ValueError(f"DNS 路由域冲突：{scope} 的 {entry} 会匹配 WARP 清单内的查询")
    if scope is None:
        raise ValueError("无法读取 systemd-resolved 的 DNS 路由域")

def resolve_endpoints(path):
    path = Path(path)
    cfg = json.loads(path.read_text())
    for endpoint in cfg["endpoints"]:
        for peer in endpoint["peers"]:
            host = peer["address"]
            try:
                ip_address(host)
                continue
            except ValueError:
                pass
            try:
                infos = socket.getaddrinfo(host, peer["port"], type=socket.SOCK_DGRAM)
            except socket.gaierror:
                raise ValueError(f"无法使用当前系统 DNS 解析 WireGuard 端点：{host}")
            candidates = dict.fromkeys(info[4][0] for info in infos)
            for ip in candidates:
                result = subprocess.run(["ip", "-j", "route", "get", ip],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if result.returncode == 0:
                    routes = json.loads(result.stdout)
                    if routes and routes[0].get("dev") not in (None, "buds-warp0"):
                        peer["address"] = ip
                        break
            else:
                raise ValueError(f"WireGuard 端点没有可用的原有网络路由：{host}")
    atomic(path, json.dumps(cfg))

def edit(action, current, args):
    if action == "import" and len(args) == 1:
        return names(args[0])
    selected = names(current)
    if action == "add" and args:
        selected.update(map(domain, args))
    elif action == "remove" and args:
        removed = set(map(domain, args))
        missing = removed - selected
        if missing:
            raise ValueError("清单没有此条目：" + ", ".join(sorted(missing)))
        selected -= removed
    elif action == "replace" and len(args) == 2:
        old, new = map(domain, args)
        if old not in selected:
            raise ValueError("清单没有此条目：" + old)
        selected.remove(old)
        selected.add(new)
    elif action != "list" or args:
        raise ValueError("用法：domains list | add 域名… | remove 域名… | replace 旧域名 新域名 | import 文件 | reset")
    return selected

try:
    action, *args = sys.argv[1:]
    if action == "render":
        render(*args)
    elif action == "check-resolved":
        check_resolved_domains(*args)
    elif action == "resolve-endpoints":
        resolve_endpoints(*args)
    else:
        for item in sorted(edit(action, args[0], args[1:])):
            print(item)
except (ValueError, OSError, UnicodeError) as error:
    sys.exit(str(error))
PY
}

warp_current_domains() {
    if [[ -f "$WARP_LIST" ]]; then
        cat -- "$WARP_LIST"
    elif [[ -f "$WARP_DIR/.buds-managed" && -f "$WARP_DIR/domains" ]]; then
        cat -- "$WARP_DIR/domains"
    else
        warp_domains
    fi
}

# v1.4 已安装的单元也运行 preflight 和 link-up，更新这两个文件即可接入域名管理。
warp_prepare_policy() (
    local stage
    stage=$(mktemp -d "${WARP_DIR}.setup.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    if [[ ! -f "$WARP_DIR/base.json" ]]; then
        cp -- "$WARP_DIR/config.json" "$stage/base.json" &&
            mv -- "$stage/base.json" "$WARP_DIR/base.json" || return 1
    fi
    warp_policy_tool > "$stage/policy.py" &&
        warp_link_up_file > "$stage/link-up" &&
        warp_preflight_file > "$stage/preflight" || return 1
    local file
    for file in policy.py link-up preflight; do
        mv -f -- "$stage/$file" "$WARP_DIR/$file" || return 1
    done
)

warp_edit_domains() (
    local action=${1:-list} work binary active=false had_previous=false
    local changed="$WARP_LIST" domains="$WARP_LIST" family="$WARP_GEMINI_FAMILY" label="域名清单" previous="原清单"
    if (( $# )); then shift; fi
    if [[ "$action" == list ]]; then
        set -o pipefail
        warp_current_domains | python3 -I -c "$(warp_policy_tool)" list - "$@"
        return
    fi
    case "$action" in
        add|remove|replace|import|reset) ;;
        gemini-family)
            if [[ $# == 0 ]]; then
                printf 'Gemini 出口地址族：%s\n' "$(cat "$family" 2>/dev/null || printf auto)"
                return 0
            fi
            [[ $# == 1 && "$1" =~ ^(auto|ipv4|ipv6)$ ]] || { echo '用法：warp gemini-family [auto|ipv4|ipv6]' >&2; return 2; }
            changed="$family"
            label="Gemini 出口地址族"
            previous="原设置"
            ;;
        *) echo "用法：domains {list|add|remove|replace|import|reset}" >&2; return 2 ;;
    esac
    umask 077
    mkdir -p -- "$(dirname "$WARP_LIST")" || return 1
    work=$(mktemp -d "${WARP_LIST}.XXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    warp_current_domains > "$work/current" || return 1
    if [[ "$action" == gemini-family ]]; then
        printf '%s\n' "$1" > "$work/next" || return 1
        domains="$work/current"
        family="$work/next"
    elif [[ "$action" == reset && $# == 0 ]]; then
        warp_domains > "$work/defaults" || return 1
        python3 -I - list "$work/defaults" < <(warp_policy_tool) > "$work/next" || return 1
        domains="$work/next"
    else
        python3 -I -c "$(warp_policy_tool)" "$action" "$work/current" "$@" > "$work/next" || return 1
        domains="$work/next"
    fi
    if [[ -d "$WARP_DIR" ]]; then
        [[ ! -L "$WARP_DIR" && -f "$WARP_DIR/.buds-managed" &&
            "$WARP_DIR/$WARP_UNIT" -ef "/etc/systemd/system/$WARP_UNIT" ]] ||
            { echo "分流服务未完成安装或由其他程序管理，请先检查状态。" >&2; return 1; }
        warp_prepare_policy || return 1
        binary=$(warp_runtime_binary) || return 1
        python3 -I "$WARP_DIR/policy.py" render "$WARP_DIR/base.json" "$domains" "$work" "$family" &&
            (cd "$work" && "$binary" check -c config.json) || return 1
        if systemctl is-active --quiet "$WARP_UNIT"; then
            if cmp -s "$work/domains" "$WARP_DIR/domains" && cmp -s "$work/config.json" "$WARP_DIR/config.json"; then
                mv -f -- "$work/next" "$changed" || return 1
                echo "$label 已保存，当前选路无需重载。"
                return 0
            fi
            active=true
        fi
    fi
    if [[ -f "$changed" ]]; then
        cp -- "$changed" "$work/previous" || return 1
        had_previous=true
    fi
    mv -f -- "$work/next" "$changed" || return 1
    if [[ "$active" == true ]] && ! { systemctl restart "$WARP_UNIT" &&
            { warp_tunnel_probe || { sleep 2; warp_tunnel_probe; }; }; }; then
        if [[ "$had_previous" == true ]]; then
            mv -f -- "$work/previous" "$changed" || return 1
        else
            rm -f -- "$changed" || return 1
        fi
        if ! systemctl restart "$WARP_UNIT"; then
            if [[ $(systemctl show -p Result --value "$WARP_UNIT") != start-limit-hit ]] ||
                ! systemctl reset-failed "$WARP_UNIT" || ! systemctl start "$WARP_UNIT"; then
                echo "已还原${previous}，分流服务恢复失败，请检查日志。" >&2
                return 1
            fi
        fi
        echo "新规则启动失败，已恢复${previous}和服务。" >&2
        return 1
    fi
    if [[ "$active" == true ]]; then
        echo "$label 已生效。"
    else
        echo "$label 已保存，下次启动 WARP 分流时生效。"
    fi
)

warp_config() {
    python3 -I - "$1" "$2" "$3" <<'PY'
import configparser
import ipaddress
import json
from pathlib import Path
import sys
from urllib.parse import urlsplit

profile, domain_file, version = sys.argv[1:]
# wgcf 可为 IPv4、IPv6 分别写一行 Address。只读取参数，不执行配置中的钩子。
wg = configparser.ConfigParser(interpolation=None, strict=True, inline_comment_prefixes=("#",))
addresses = []
allowed = []
lines = []
section = ""
with open(profile, encoding="utf-8-sig") as f:
    for line in f:
        value = line.split("#", 1)[0].strip()
        if value.startswith("["):
            section = value
        key, sep, items = value.partition("=")
        if section == "[Interface]" and sep and key.strip().lower() == "address":
            addresses.extend(str(ipaddress.ip_interface(x.strip())) for x in items.split(","))
        elif section == "[Peer]" and sep and key.strip().lower() == "allowedips":
            allowed.extend(str(ipaddress.ip_network(x.strip())) for x in items.split(","))
        elif sep and key.strip().lower() not in {"privatekey", "publickey", "mtu", "endpoint",
                                                "presharedkey", "reserved", "persistentkeepalive"}:
            continue
        else:
            lines.append(line)
try:
    wg.read_string("".join(lines))
    peer = wg["Peer"]
    endpoint = urlsplit("//" + peer["Endpoint"])
    if not addresses or not allowed or not endpoint.hostname or not endpoint.port:
        raise ValueError
    wg_peer = {"address": endpoint.hostname, "port": endpoint.port, "public_key": peer["PublicKey"],
               "allowed_ips": allowed}
    if peer.get("PersistentKeepalive", "0").lower() != "off":
        wg_peer["persistent_keepalive_interval"] = int(peer.get("PersistentKeepalive", "0"))
    if "PresharedKey" in peer:
        wg_peer["pre_shared_key"] = peer["PresharedKey"]
    if "Reserved" in peer:
        wg_peer["reserved"] = [int(x) for x in peer["Reserved"].split(",")]
    warp = {"type": "wireguard", "tag": "warp", "system": False, "address": addresses,
            "private_key": wg["Interface"]["PrivateKey"], "mtu": int(wg["Interface"].get("MTU", 1280)),
            "domain_resolver": "bootstrap", "peers": [wg_peer]}
except (ValueError, KeyError, configparser.Error):
    sys.exit("无法读取 WARP 单 Peer WireGuard 配置，请检查 Address、密钥、Endpoint 和 AllowedIPs。")
for existing in (Path("/etc/s-box/sb.json"), Path("/etc/sing-box/config.json")):
    if not existing.is_file():
        continue
    try:
        config = json.loads(existing.read_text())
    except (OSError, ValueError):
        continue
    for entry in config.get("endpoints", []) + config.get("outbounds", []):
        if entry.get("type") == "wireguard" and entry.get("private_key") == warp["private_key"]:
            sys.exit(f"此 WireGuard 身份已配置在 {existing}。请运行 buds hy2 warp setup --new-profile 生成独立身份。")
with open(domain_file) as f:
    domains = f.read().split()
families = {ipaddress.ip_interface(a).version for a in addresses}
families &= {ipaddress.ip_network(n).version for n in allowed}
if not families:
    sys.exit("WireGuard 地址与 AllowedIPs 的协议族不一致。")
strategy = "prefer_ipv4"
if len(families) == 1:
    strategy = "ipv4_only" if 4 in families else "ipv6_only"
tun = {"type": "tun", "tag": "split", "interface_name": "buds-warp0", "stack": "gvisor",
       "address": ["198.18.240.1/32", "fd42:6275:6473::1/128"], "auto_route": False}
ipv6_status = Path("/proc/sys/net/ipv6/conf/all/disable_ipv6")
ipv6 = not (ipv6_status.is_file() and ipv6_status.read_text().strip() == "1")
if tuple(map(int, version.split(".")[:2])) >= (1, 14):
    tun["dns_mode"] = "disabled"
dns = {"servers": [
    {"type": "fakeip", "tag": "virtual", "inet4_range": "198.18.248.0/21",
     "inet6_range": "fd42:6275:6473:1::/96"},
    {"type": "local", "tag": "bootstrap"},
    {"type": "udp", "server": "1.1.1.1" if 4 in families else "2606:4700:4700::1111",
     "tag": "real", "detour": "warp"}],
    "rules": [
        {"inbound": "split", "domain_suffix": domains, "query_type": ["A", "AAAA"],
         "action": "route", "server": "virtual", "rewrite_ttl": 5},
        {"inbound": "split", "query_type": ["HTTPS", "SVCB"], "action": "predefined", "rcode": "NOERROR"}],
    "final": "real"}
route = {"default_domain_resolver": "real", "rules": [
    {"ip_cidr": "198.18.240.2/32", "port": 53, "action": "hijack-dns"},
    {"domain_suffix": domains, "action": "resolve", "server": "real", "strategy": strategy},
    {"domain_suffix": domains, "action": "route", "outbound": "warp"},
    {"action": "reject"}]}
if not ipv6:
    tun["address"].pop()
    del dns["servers"][0]["inet6_range"]
    dns["rules"][0]["query_type"] = ["A"]
    dns["rules"][1]["query_type"].append("AAAA")
json.dump({"inbounds": [tun], "endpoints": [warp], "dns": dns, "route": route,
           "experimental": {"cache_file": {"enabled": True, "store_fakeip": True,
                                           "path": "fakeip.db"}}}, sys.stdout)
PY
}

warp_link_up_file() {
    cat <<'LINK_UP'
#!/usr/bin/env bash
set -eu
[[ -s domains ]] || exit 0
link=buds-warp0
for ((i=0; i<100; i++)); do
    ip -o link show up dev "$link" 2>/dev/null | grep -q . && break
    sleep 0.1
done
ip route add 198.18.240.2/32 dev "$link"
ip route add 198.18.240.3/32 dev "$link"
ip route add 198.18.248.0/21 dev "$link"
if grep -Fq 'fd42:6275:6473::1/128' config.json; then
    ip -6 route add fd42:6275:6473:1::/96 dev "$link"
fi
resolvectl default-route "$link" no
resolvectl dns "$link" 198.18.240.2
resolvectl dnssec "$link" no
resolvectl dnsovertls "$link" no
mapfile -t domains < <(tr -s '[:space:]' '\n' < domains | sed '/^$/d;s/^/~/')
resolvectl domain "$link" "${domains[@]}"
resolvectl flush-caches
LINK_UP
}

warp_files() {
    local profile=$1 binary=$2 version=$3
    warp_domains > "$WARP_DIR/domains" || return 1
    warp_config "$profile" "$WARP_DIR/domains" "$version" > "$WARP_DIR/config.json" || return 1
    (cd "$WARP_DIR" && "$binary" check -c config.json) || return 1
    warp_prepare_policy || return 1

    cat > "$WARP_DIR/$WARP_UNIT" <<UNIT
[Unit]
Description=Buds WARP domain split routing
After=network-online.target systemd-resolved.service
Wants=network-online.target
Requires=systemd-resolved.service

[Service]
WorkingDirectory=$WARP_DIR
UMask=0077
ExecStartPre=/usr/bin/env bash $WARP_DIR/preflight
ExecStart=$binary run -c $WARP_DIR/config.json
ExecStartPost=/usr/bin/env bash $WARP_DIR/link-up
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
}

warp_check_stub() {
    awk '$1=="nameserver" {count++; if ($2!="127.0.0.53") other=1}
         END {exit !(count && !other)}' /etc/resolv.conf ||
        { echo "系统 DNS 必须仅使用 127.0.0.53；混用其他 nameserver 会绕过域名分流。" >&2; return 1; }
}

warp_check_routes() {
if ip link show dev buds-warp0 >/dev/null 2>&1; then
    echo "接口 buds-warp0 已被占用。" >&2
    exit 1
fi
python3 -I - <<'PY'
import ipaddress
import json
import subprocess
import sys
from pathlib import Path
ipv6_status = Path("/proc/sys/net/ipv6/conf/all/disable_ipv6")
for family, ranges in [("-4", ["198.18.240.0/30", "198.18.248.0/21"]),
                       ("-6", ["fd42:6275:6473::/126", "fd42:6275:6473:1::/96"])]:
    if family == "-6" and ipv6_status.is_file() and ipv6_status.read_text().strip() == "1":
        continue
    routes = json.loads(subprocess.check_output(["ip", "-j", family, "route", "show", "table", "all"]))
    for r in routes:
        dst = r.get("dst", "default")
        if dst != "default" and any(ipaddress.ip_network(dst, strict=False).overlaps(ipaddress.ip_network(n)) for n in ranges):
            sys.exit("虚拟地址与已有路由冲突：" + dst)
PY
}

warp_preflight_file() {
    printf '#!/usr/bin/env bash\nset -eu\n'
    declare -f warp_check_stub warp_check_routes
    cat <<'PREFLIGHT'
warp_check_stub
warp_check_routes
python3 -I policy.py render base.json ../warp-domains . ../warp-gemini-family
python3 -I policy.py resolve-endpoints config.json
if [[ -s domains ]]; then
    set -o pipefail
    LC_ALL=C SYSTEMD_COLORS=0 resolvectl --no-pager domain | python3 -I policy.py check-resolved domains
fi
PREFLIGHT
}

warp_requirements() {
    local tool failed=0
    has_systemd || { echo "此主机未运行 systemd；当前 WARP 路由需要 systemd 和 systemd-resolved。" >&2; return 1; }
    for tool in resolvectl ip python3 curl flock; do
        command -v "$tool" >/dev/null || { echo "缺少 $tool。" >&2; failed=1; }
    done
    [[ -c /dev/net/tun && -r /dev/net/tun && -w /dev/net/tun ]] ||
        { echo "无法访问 /dev/net/tun。容器需要宿主机映射 TUN 并授予 CAP_NET_ADMIN。" >&2; failed=1; }
    systemctl is-active --quiet systemd-resolved ||
        { echo "systemd-resolved 未运行。请先检查发行版的 DNS 管理方式。" >&2; failed=1; }
    if [[ "${1:-}" != before-dns ]] && ! warp_check_stub; then
        echo "静态公网 DNS 可用 buds hy2 warp dns-switch 迁移。其他 DNS 布局请按 README 配置。" >&2
        failed=1
    fi
    return "$failed"
}

warp_doctor() (
    local detected profile binary version work failed=0
    warp_requirements || failed=1
    if [[ -f "$WARP_DIR/.buds-managed" ]] && systemctl is-active --quiet "$WARP_UNIT"; then
        warp_runtime_binary || return 1
        echo "WARP 服务已运行。可使用 buds hy2 warp check 检查实际出口。"
        return "$failed"
    fi
    detected=$(warp_find_binary) || failed=1
    profile=$(warp_resolve_profile "${1:-}") || failed=1
    [[ -z "$detected" ]] || printf '已找到 sing-box：%s\n' "$detected"
    [[ -z "$profile" ]] || printf '已找到 WARP 配置：%s\n' "$profile"
    if command -v ip >/dev/null && command -v python3 >/dev/null; then
        warp_check_routes || failed=1
    fi
    if [[ -n "$detected" && -n "$profile" ]] && command -v python3 >/dev/null; then
        read -r binary version <<< "$detected"
        umask 077
        work=$(mktemp -d) || return 1
        trap 'rm -rf -- "$work"' EXIT
        if warp_domains > "$work/default-domains" &&
            warp_config "$profile" "$work/default-domains" "$version" > "$work/base.json" &&
            python3 -I -c "$(warp_policy_tool)" render "$work/base.json" "$WARP_LIST" "$work" "$WARP_GEMINI_FAMILY" &&
            (cd "$work" && "$binary" check -c config.json); then
            echo "配置校验通过。"
        else
            failed=1
        fi
    fi
    if (( !failed )); then echo "启用前检查通过。"; fi
    return "$failed"
)

warp_domain_selected() {
    awk -v host="$1" '{for (i=1; i<=NF; i++) {
        suffix="." $i
        if (host==$i || (length(host)>length(suffix) && substr(host,length(host)-length(suffix)+1)==suffix)) found=1
    }} END {exit !found}' "$WARP_DIR/domains"
}

warp_verify() {
    python3 -I - "$WARP_DIR/domains" <<'PY' || return 1
import ipaddress
import json
import socket
import subprocess
import sys
nets = [ipaddress.ip_network(n) for n in ("198.18.248.0/21", "fd42:6275:6473:1::/96")]
with open(sys.argv[1], encoding="utf-8") as source:
    domains = set(source.read().split())
def matches(host):
    return any(host == d or host.endswith("." + d) for d in domains)
probes = ["play.google.com", "scholar.google.com", "www.youtube.com", "gemini.google.com",
          "chatgpt.com", "claude.ai"]
hosts = [h for h in probes if matches(h)]
if domains and not hosts:
    hosts.append(min(domains))
for host in dict.fromkeys(hosts + ["github.com", "x.com"]):
    split = matches(host)
    ips = {r[4][0] for r in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)}
    if not ips or any(any(ipaddress.ip_address(ip) in n for n in nets) != split for ip in ips):
        sys.exit(host + " 的系统解析结果与分流策略不符")
    reachable = []
    for ip in sorted(ips):
        result = subprocess.run(["ip", "-j", "route", "get", ip], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode and not split:
            continue
        result.check_returncode()
        route = json.loads(result.stdout)[0]
        if (route.get("dev") == "buds-warp0") != split:
            sys.exit(host + " 的内核出口与分流策略不符：" + ip)
        reachable.append(ip)
    if not reachable:
        sys.exit(host + " 没有可用的内核路由")
    print(host, "→", "buds-warp0" if split else "原有出口", ", ".join(reachable))
PY
    if warp_domain_selected www.google.com; then
        curl -q --noproxy '*' -fsS --max-time 15 -o /dev/null https://www.google.com/generate_204 ||
            { echo "Google HTTPS 连通测试失败。" >&2; return 1; }
    fi
}

warp_remove() {
    [[ -d "$WARP_DIR" ]] || return 0
    [[ ! -L "$WARP_DIR" && -f "$WARP_DIR/.buds-managed" ]] ||
        { echo "目录缺少 buds 管理标记，已保留：$WARP_DIR" >&2; return 1; }
    if [[ "$WARP_DIR/$WARP_UNIT" -ef "/etc/systemd/system/$WARP_UNIT" ]]; then
        systemctl stop "$WARP_UNIT" && systemctl disable "$WARP_UNIT" || return 1
    elif [[ $(systemctl show -p LoadState --value "$WARP_UNIT") != not-found ]]; then
        echo "检测到同名系统服务，已保留配置，请检查 $WARP_UNIT。" >&2
        return 1
    fi
    rm -f -- "$WARP_DIR"/{domains,config.json,base.json,policy.py,preflight,link-up,fakeip.db} "$WARP_DIR/$WARP_UNIT" || return 1
    rm -f -- "$WARP_DIR/.buds-managed" || return 1
    if ! rmdir -- "$WARP_DIR"; then
        touch "$WARP_DIR/.buds-managed"
        return 1
    fi
    systemctl daemon-reload
}

warp_tunnel_probe() {
    [[ -s "$WARP_DIR/domains" ]] || return 0
    local trace
    if trace=$(curl -q --noproxy '*' --resolve one.one.one.one:443:198.18.240.3 \
        -fsS --max-time 15 https://one.one.one.one/cdn-cgi/trace) &&
        tr -d '\r' <<< "$trace" | grep -Eq '^warp=(on|plus)$'; then
        printf 'WARP 隧道 HTTPS 出口验证通过。'
        awk -F= '/^loc=[A-Z][A-Z]\r?$/ {sub(/\r$/, "", $2); printf " 地区 %s（Cloudflare）", $2} END {print ""}' <<< "$trace"
        return 0
    fi
    echo "无法通过 WARP 隧道确认 Cloudflare 出口，请检查 WireGuard 配置和 UDP 连通性。" >&2
    return 1
}

warp_gemini_check() {
    warp_domain_selected gemini.google.com || return 0
    python3 -I - "$WARP_GEMINI_FAMILY" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

path = Path(sys.argv[1])
selected = path.read_text().strip() if path.is_file() else "auto"

for family in ("4", "6"):
    if selected in ("ipv4", "ipv6") and selected != "ipv" + family:
        print(f"Gemini IPv{family} 入口：当前地址族设置未发布此类虚拟地址。")
        continue
    try:
        result = subprocess.run(["curl", "-q", "-" + family, "--noproxy", "*", "-sS",
                                 "--max-time", "10", "--max-filesize", "4194304",
                                 "-H", "Accept-Language: en-US,en", "-w", "\n%{http_code}",
                                 "https://gemini.google.com/app"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=12)
    except subprocess.TimeoutExpired:
        print(f"Gemini IPv{family} 入口：探测超时。")
        continue
    if result.returncode:
        print(f"Gemini IPv{family} 入口：无可用连接或请求失败。")
        continue
    page, status = result.stdout.rsplit(b"\n", 1)
    region = sorted(set(re.findall(rb'\[1,null,null,\d+,\d+,"([A-Z]{3})"', page)))
    code = ", ".join(tag.decode("ascii") for tag in region) or "未知"
    print(f"Gemini IPv{family} 入口：HTTP {status.decode('ascii')} · 页面地区标记 {code}")
print("以上是未登录页面的检测结果。登录后的实际服务可用性请在 Gemini 中确认。")
PY
}

warp_trace() {
    local host result reported split failed=0
    local hosts=(www.cloudflare.com)
    if warp_domain_selected chatgpt.com; then hosts+=(chatgpt.com); fi
    for host in "${hosts[@]}"; do
        split=false
        if warp_domain_selected "$host"; then split=true; fi
        if result=$(curl -q --noproxy '*' -fsS --max-time 8 "https://$host/cdn-cgi/trace") &&
            grep -q '^warp=' <<< "$result"; then
            printf '%s  ' "$host"
            awk -F= '/^(ip|loc|warp)=/ {printf "%s ", $0} END {print ""}' <<< "$result"
            reported=$(sed -n 's/^warp=//p' <<< "$result" | tr -d '\r')
            if [[ "$split" == true && "$reported" == off ]] ||
                [[ "$split" == false && "$reported" != off ]]; then
                echo "出口标记与预期不符，请检查 WARP 配置和 VPS 原有默认出口。" >&2
                failed=1
            fi
        else
            printf '%s 未返回出口诊断信息。\n' "$host"
        fi
    done
    return "$failed"
}

warp_manage() (
    local action=${1:-status} profile=${2:-} detected binary version
    if [[ "$action" == status ]]; then
        if [[ ! -d "$WARP_DIR" ]]; then echo "WARP 分流未启用。"; return 0; fi
        systemctl status "$WARP_UNIT" --no-pager
        return
    fi
    if [[ "$action" == domains || "$action" == gemini-family ]]; then
        shift
        exec 9>/run/buds-warp-split.lock && flock -x 9 || return 1
        if [[ "$action" == gemini-family ]]; then
            warp_edit_domains gemini-family "$@"
            return
        fi
        warp_edit_domains "$@"
        return
    fi
    if [[ "$action" == doctor ]]; then warp_doctor "$profile"; return; fi
    has_systemd || { echo "WARP 分流需要 systemd 和 systemd-resolved。"; return 1; }
    exec 9>/run/buds-warp-split.lock || return 1
    flock -x 9 || return 1
    case "$action" in
        setup)
            [[ -z "$profile" || "$profile" == --new-profile || "$profile" == --managed-core ]] || return 2
            warp_setup "$profile"; return ;;
        dns-switch)
            [[ ! -d "$WARP_DIR" ]] || { echo "请先运行 buds hy2 warp disable。" >&2; return 1; }
            warp_dns_switch; return ;;
        dns-restore)
            [[ ! -d "$WARP_DIR" ]] || { echo "请先运行 buds hy2 warp disable。" >&2; return 1; }
            warp_dns_restore; return ;;
        disable) warp_remove && echo "WARP 分流已关闭。" ; return ;;
        check)
            if ! systemctl is-active --quiet "$WARP_UNIT"; then
                if [[ -d "$WARP_DIR" ]]; then
                    echo "WARP 服务未运行。请用 buds hy2 warp status 查看状态和启动日志。" >&2
                else
                    echo "WARP 分流未启用。请先选择「启用」，再检测实际出口。" >&2
                fi
                return 1
            fi
            warp_verify && warp_trace || return 1
            if grep -Fq '"198.18.240.3/32"' "$WARP_DIR/config.json" || [[ ! -s "$WARP_DIR/domains" ]]; then
                warp_tunnel_probe || return 1
                if [[ -s "$WARP_DIR/domains" ]]; then
                    echo "分流规则和 WARP 隧道连通检查通过。"
                    warp_gemini_check
                else
                    echo "检测通过。域名清单为空，当前流量使用原有出口。"
                fi
            else
                echo "旧版运行配置没有专用出口探针；隧道出口尚未验证。" >&2
                return 1
            fi
            return ;;
        enable) ;;
        *) echo "用法：buds hy2 warp {doctor|setup [--new-profile|--managed-core]|dns-switch|dns-restore|enable [配置路径]|status|check|disable|domains|gemini-family [auto|ipv4|ipv6]}"; return 2 ;;
    esac
    if [[ -d "$WARP_DIR" ]]; then
        systemctl is-active --quiet "$WARP_UNIT" && { echo "WARP 分流已启用。"; return 0; }
        echo "已有未运行的分流配置，请检查 status，或 disable 后重试。"; return 1
    fi
    warp_requirements || return 1
    [[ $(systemctl show -p LoadState --value "$WARP_UNIT") == not-found ]] ||
        { echo "$WARP_UNIT 已被占用。"; return 1; }
    detected=$(warp_find_binary) && profile=$(warp_resolve_profile "$profile") || return 1
    read -r binary version <<< "$detected"
    umask 077
    mkdir -p "$(dirname "$WARP_DIR")" && mkdir "$WARP_DIR" || return 1
    touch "$WARP_DIR/.buds-managed" || { rmdir "$WARP_DIR"; return 1; }
    trap 'rc=$?; if ((rc)); then warp_remove || echo "清理未完成，请运行 buds hy2 warp disable。" >&2; fi' EXIT
    warp_files "$profile" "$binary" "$version" || return 1
    if ! systemctl enable "$WARP_DIR/$WARP_UNIT" || ! systemctl start "$WARP_UNIT"; then
        echo "WARP 服务启动失败。正在撤销本次启用，可用 journalctl -u $WARP_UNIT 查看原因。" >&2
        return 1
    fi
    if ! { warp_verify && warp_tunnel_probe && warp_trace; }; then
        echo "选路或出口验证失败，正在撤销本次启用。" >&2
        return 1
    fi
    echo "WARP 分流已启用，当前清单选路检查通过。"
)

nodes_source() {
    cat <<'PY'
import argparse
import getpass
import grp
import ipaddress
import json
import os
import pwd
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


BASE = Path(sys.argv[1])
PRIMARY_LISTEN, PRIMARY_PUBLIC, PRIMARY_DOMAIN = sys.argv[2:5]
ROOT = BASE / "nodes"
UNITS = Path("/etc/systemd/system")
CORE = "/usr/local/bin/hysteria"
NODE_NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,30}")
FIREWALL_PREFIX = "buds-hy2-node-"


def run(*args, check=True):
    return subprocess.run(args, check=check, universal_newlines=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=40, env={**os.environ, "LC_ALL": "C"})


def active(unit):
    return run("systemctl", "is-active", "--quiet", unit, check=False).returncode == 0


def ports(text):
    found = re.fullmatch(r"([0-9]{1,5})(?:[-:]([0-9]{1,5}))?", text)
    if found:
        start = int(found[1])
        end = int(found[2] or found[1])
        if 1 <= start <= end <= 65535:
            return start, end
    raise ValueError(f"无效 UDP 端口或范围：{text}")


def port_text(span):
    return str(span[0]) if span[0] == span[1] else f"{span[0]}-{span[1]}"


def node_name(value):
    if not NODE_NAME.fullmatch(value) or value == "main":
        raise ValueError("节点名称须使用 1–31 位小写字母、数字、下划线或短横线，main 为主节点。")
    return value


def domain_name(value):
    try:
        value = value.rstrip(".").encode("idna").decode("ascii").lower()
    except UnicodeError:
        raise ValueError("请输入有效域名或 IPv4 地址。") from None
    try:
        address = ipaddress.ip_address(value)
        if address.version == 4:
            return str(address)
        raise ValueError("此入口请为 IPv6 主机填入域名。")
    except ValueError:
        if ":" in value:
            raise ValueError("此入口请为 IPv6 主机填入域名。")
    labels = value.split(".")
    if (len(value) > 253 or len(labels) < 2 or labels[-1].isdigit() or
            any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in labels)):
        raise ValueError("请输入有效域名或 IPv4 地址。")
    return value


def unit_name(name):
    return f"buds-hy2-node-{name}.service"


def load_node(path):
    if ROOT.is_symlink() or path.is_symlink() or not (path / "node.json").is_file():
        raise ValueError(f"找不到托管节点 {path.name}。")
    data = json.loads((path / "node.json").read_text())
    if data.get("name") != path.name:
        raise ValueError(f"节点记录与目录不匹配：{path.name}")
    return data


def nodes():
    if ROOT.is_symlink():
        raise ValueError("节点目录不能是符号链接。")
    if ROOT.is_dir():
        for path in sorted(ROOT.iterdir()):
            if path.is_dir() and NODE_NAME.fullmatch(path.name):
                yield load_node(path)


def listeners():
    for line in run("ss", "-H", "-lunp").stdout.splitlines():
        fields = line.split()
        if len(fields) >= 5:
            port = fields[3].rsplit(":", 1)[-1]
            if port.isdigit():
                yield int(port), set(re.findall(r"\bpid=([0-9]+)", line))


def nft_ports(value):
    if isinstance(value, int):
        yield value, value
    elif isinstance(value, dict) and "range" in value and len(value["range"]) == 2:
        if all(isinstance(n, int) for n in value["range"]):
            yield tuple(value["range"])
    elif isinstance(value, dict) and "set" in value:
        for item in value["set"]:
            yield from nft_ports(item)


def udp_redirects():
    if shutil.which("nft"):
        result = run("nft", "-j", "list", "ruleset", check=False)
        if result.returncode == 0:
            for item in json.loads(result.stdout).get("nftables", []):
                rule = item.get("rule", {})
                expressions = rule.get("expr", [])
                if not any("redirect" in expr or "dnat" in expr for expr in expressions):
                    continue
                for expr in expressions:
                    match = expr.get("match", {})
                    if match.get("op") in ("==", "in") and match.get("left", {}).get("payload") == {
                            "protocol": "udp", "field": "dport"}:
                        for span in nft_ports(match.get("right")):
                            yield span, rule.get("table", "")
    for command in ("iptables-save", "ip6tables-save"):
        if shutil.which(command):
            result = run(command, "-t", "nat", check=False)
            for line in result.stdout.splitlines():
                if " -p udp " not in line:
                    continue
                target = re.search(r" -j (DNAT|REDIRECT|HYSTERIA-PR-[a-f0-9]+)(?: |$)", line)
                match = re.search(r" --dports? ([0-9:,]+)(?: |$)", line)
                if target and match and " ! --dport" not in line:
                    for span in match[1].split(","):
                        first, separator, last = span.partition(":")
                        yield ports(f"{first or 1}-{last or 65535}" if separator else first), target[1]


def port_conflicts(name):
    if not (BASE / "config.yaml").is_file():
        raise ValueError("请先配置主节点，再新增节点。")
    primary = PRIMARY_LISTEN.partition("#")[0].strip() or "443"
    configured_public = PRIMARY_PUBLIC.partition("#")[0].strip() or primary
    reserves = [(ports(p), "主节点监听范围") for p in primary.split(",")]
    public = [(ports(p), "主节点公网范围") for p in configured_public.split(",")]
    own_span = None
    for node in nodes():
        if node["name"] != name:
            reserves.append((ports(node["ports"]), node["name"]))
            public.append((ports(node["public_ports"]), node["name"]))
        else:
            own_span = ports(node["ports"])

    own_pid = run("systemctl", "show", unit_name(name), "-p", "MainPID", "--value", check=False).stdout.strip()
    for port, pids in listeners():
        if not own_pid or own_pid == "0" or pids != {own_pid}:
            reserves.append(((port, port), f"已监听 UDP {port}"))
    for span, table in udp_redirects():
        if (own_span and re.fullmatch(r"hysteria_[a-f0-9]{8}|HYSTERIA-PR-[a-f0-9]{8}", table) and
                own_span[0] < span[0] <= span[1] <= own_span[1]):
            continue
        reserves.append((span, "现有 UDP 转发规则"))
    return reserves, public


def overlaps(span, other):
    return span[0] <= other[1] and other[0] <= span[1]


def choose_ports(value, reservations):
    auto = re.fullmatch(r"auto(?::([0-9]{1,3}))?", value)
    if auto:
        count = int(auto[1] or "1")
        if not 1 <= count <= 512:
            raise ValueError("自动跳跃范围长度应为 1–512。")
        first, last = 20000, 60999
        choices = []
        for (start, end), _ in sorted(reservations + [((last + 1, last + 1), "")]):
            if min(start - 1, last) - first + 1 >= count:
                choices.append((first, min(start - count, last - count + 1)))
            first = max(first, end + 1)
        candidates = sum(end - start + 1 for start, end in choices)
        if candidates:
            offset = secrets.randbelow(candidates)
            for start, end in choices:
                if offset <= end - start:
                    return start + offset, start + offset + count - 1
                offset -= end - start + 1
        raise ValueError("未找到可用端口范围，请手动指定。")
    span = ports(value)
    for used, owner in reservations:
        if overlaps(span, used):
            raise ValueError(f"端口 {port_text(span)} 与 {owner}（{port_text(used)}）重叠。")
    return span


def secret(action, previous, label):
    if action == "keep" and previous:
        return previous
    if action == "custom":
        if not sys.stdin.isatty():
            raise ValueError("输入自定义密码需要交互终端。")
        value = getpass.getpass(f"{label}（至少 8 个字符）：")
        if not re.fullmatch(r"[A-Za-z0-9_.@+!%*=-]{8,128}", value):
            raise ValueError("密码长度 8–128，支持字母、数字和 _.@+!%*=-。")
        if value != getpass.getpass(f"再次输入{label}："):
            raise ValueError("两次输入不一致。")
        return value
    return secrets.token_hex(16)


def apply_preferences(args, old):
    data = {"name": args.name}
    domain = args.domain or old.get("domain") or PRIMARY_DOMAIN
    if domain == "your.domain.com" and not args.domain:
        raise ValueError("未识别到主节点地址，请为此节点指定域名或 IPv4 地址。")
    data["domain"] = domain_name(domain)
    reserved, public = port_conflicts(args.name)
    requested = args.ports or old.get("ports") or "auto"
    # 自动选择时同时排除公网映射端口；固定端口分别核查本地监听和公网映射。
    local_span = choose_ports(requested, reserved + public if requested.startswith("auto") else reserved)
    previous_public = old.get("public_ports")
    mapped = args.public_ports or (previous_public if previous_public != old.get("ports") else None)
    public_span = choose_ports(port_text(local_span) if mapped in (None, "same") else mapped, public)
    data["ports"], data["public_ports"] = port_text(local_span), port_text(public_span)
    data["auth"] = secret(args.auth, old.get("auth"), "认证密码")
    data["obfs"] = secret(args.obfs, old.get("obfs"), "混淆密码")
    data["tls"] = args.tls or (old.get("tls") if data["domain"] == old.get("domain") else None) or "auto"
    return data


def make_certificate(data, old, stage, path):
    domain = data["domain"]
    old_data = load_node(old) if old else {}
    if data["tls"] == "auto":
        cert = BASE / "server.crt"
        key = BASE / "server.key"
        is_ip = bool(re.fullmatch(r"[0-9.]+", domain))
        verification = run("openssl", "verify", "-purpose", "sslserver",
                           "-verify_ip" if is_ip else "-verify_hostname", domain,
                           "-untrusted", str(cert), str(cert), check=False)
        data["tls"] = "shared" if verification.returncode == 0 and key.is_file() else "self"
    if data["tls"] == "shared":
        cert, key = BASE / "server.crt", BASE / "server.key"
        verify = run("openssl", "verify", "-purpose", "sslserver",
                     "-verify_ip" if re.fullmatch(r"[0-9.]+", domain) else "-verify_hostname", domain,
                     "-untrusted", str(cert), str(cert), check=False)
        if verify.returncode or not key.is_file():
            raise ValueError("主节点的 CA 证书未覆盖此地址，或证书文件不可用。请选择自签名。")
        (stage / "server.crt").symlink_to(cert)
        return cert, key
    if old_data.get("tls") == "self" and old_data.get("domain") == domain:
        for name in ("server.crt", "server.key"):
            shutil.copyfile(old / name, stage / name)
    else:
        san = ("IP:" if re.fullmatch(r"[0-9.]+", domain) else "DNS:") + domain
        openssl_config = stage / "openssl.cnf"
        openssl_config.write_text("[req]\nprompt=no\ndistinguished_name=subject\n"
                                  "x509_extensions=extensions\n[subject]\n"
                                  f"CN={domain}\n[extensions]\nsubjectAltName={san}\n")
        run("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-nodes", "-days", "3650", "-config", str(openssl_config),
            "-keyout", str(stage / "server.key"), "-out", str(stage / "server.crt"))
        openssl_config.unlink()
    return path / "server.crt", path / "server.key"


def check_hopping(span):
    if span[0] == span[1]:
        return
    version = run(CORE, "version").stdout
    match = re.search(r"^Version:\s*v?(\d+)\.(\d+)\.(\d+)\s*$", version, re.M)
    if not match or tuple(map(int, match.groups())) < (2, 12, 3):
        raise ValueError("新增端口跳跃需要 Hysteria 2.12.3 或更新版本，以免本机其他 UDP 流量被重定向。可先选用单端口。")
    if not (shutil.which("nft") or shutil.which("iptables")):
        raise ValueError("端口跳跃需要 nftables 或 iptables。")


def write_files(data, old, stage, path):
    cert, key = make_certificate(data, old, stage, path)
    (stage / "node.json").write_text(json.dumps(data, indent=2) + "\n")
    (stage / "config.yaml").write_text(
        f'listen: :{data["ports"]}\n'
        f'tls:\n  cert: "{cert}"\n  key: "{key}"\n'
        f'auth:\n  type: password\n  password: "{data["auth"]}"\n'
        f'obfs:\n  type: salamander\n  salamander:\n    password: "{data["obfs"]}"\n'
        'quic:\n'
        '  initStreamReceiveWindow: 16777216\n'
        '  maxStreamReceiveWindow: 16777216\n'
        '  initConnReceiveWindow: 41943040\n'
        '  maxConnReceiveWindow: 41943040\n'
        'masquerade:\n  type: proxy\n  proxy:\n    url: https://news.ycombinator.com/\n'
        '    rewriteHost: true\n')
    client_tls = "  insecure: false\n"
    if data["tls"] == "self":
        fingerprint = run("openssl", "x509", "-in", str(stage / "server.crt"),
                          "-noout", "-sha256", "-fingerprint").stdout.split("=", 1)[-1].strip()
        if not re.fullmatch(r"(?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}", fingerprint):
            raise ValueError("无法读取节点证书的 SHA-256 指纹。")
        client_tls = f'  insecure: true\n  pinSHA256: "{fingerprint.replace(":", "")}"\n'
    (stage / "client.yaml").write_text(
        f'server: {data["domain"]}:{data["public_ports"]}\n'
        f'auth: "{data["auth"]}"\ntls:\n  sni: {data["domain"]}\n'
        f'{client_tls}'
        f'obfs:\n  type: salamander\n  salamander:\n    password: "{data["obfs"]}"\n'
        'socks5:\n  listen: 127.0.0.1:1080\n')
    start, end = ports(data["ports"])
    caps = []
    if start < 1024:
        caps.append("CAP_NET_BIND_SERVICE")
    if start != end:
        caps.append("CAP_NET_ADMIN")
    capabilities = " ".join(caps)
    (stage / unit_name(data["name"])).write_text(f"""[Unit]
Description=Buds Hysteria 2 node {data['name']}
After=network.target buds-hysteria-egress.service

[Service]
Type=simple
ExecStart={CORE} server --config {path}/config.yaml
WorkingDirectory={path}
User=hysteria
Group=hysteria
UMask=0077
NoNewPrivileges=yes
CapabilityBoundingSet={capabilities}
AmbientCapabilities={capabilities}
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
""")
    gid = grp.getgrnam("hysteria").gr_gid
    for filename in ("config.yaml", "server.crt", "server.key"):
        file = stage / filename
        if file.exists() and not file.is_symlink():
            os.chown(file, 0, gid)
            file.chmod(0o640)
    os.chown(stage, 0, gid)
    stage.chmod(0o750)


def ufw_rules():
    if not shutil.which("ufw"):
        return None
    result = run("ufw", "status", "numbered").stdout
    if "Status: active" not in result:
        return None
    for line in result.splitlines():
        match = re.fullmatch(r"\[\s*(\d+)\]\s+(\d+(?::\d+)?/udp)( \(v6\))?\s+ALLOW(?: IN)?\s+Anywhere(?: \(v6\))?\s*(?:#\s*(.*))?", line)
        if match:
            yield int(match[1]), match[2], 6 if match[3] else 4, (match[4] or "").strip()


def ufw_active():
    return bool(shutil.which("ufw")) and "Status: active" in run("ufw", "status").stdout


def firewall_port(port):
    return port.replace("-", ":") + "/udp"


def open_firewall(name, port):
    if not ufw_active():
        print(f"请确认主机防火墙和服务商面板已放行 UDP {port}。")
        return
    tag = FIREWALL_PREFIX + name
    requested = firewall_port(port)
    ufw_default = Path("/etc/default/ufw")
    ipv6 = ufw_default.is_file() and re.search(r'^\s*IPV6=["\x27]?yes', ufw_default.read_text(), re.M)
    for family, source in [(4, "0.0.0.0/0")] + ([(6, "::/0")] if ipv6 else []):
        if not any(rule == requested and f == family for _, rule, f, _ in ufw_rules()):
            run("ufw", "allow", "in", "proto", "udp", "from", source,
                "to", "any", "port", requested.split("/")[0], "comment", tag)
            if not any(rule == requested and f == family and owner == tag for _, rule, f, owner in ufw_rules()):
                raise ValueError(f"UFW 未确认 IPv{family} 入站规则 {requested}，请检查现有规则。")


def clean_firewall(name, keep=None):
    if not shutil.which("ufw"):
        return
    tag = FIREWALL_PREFIX + name
    if not ufw_active():
        if f"comment '{tag}'" in run("ufw", "show", "added").stdout:
            raise ValueError("UFW 已停用。请启用 UFW 后重试清除此节点的规则。")
        return
    for number, port, _, owner in sorted(ufw_rules(), reverse=True):
        if owner == tag and port != keep:
            run("ufw", "--force", "delete", str(number))


def unit_link(path):
    return UNITS / unit_name(path.name)


def check_unit_link(path):
    link = unit_link(path)
    if not link.is_symlink() or os.readlink(link) != str(path / link.name):
        raise ValueError(f"{unit_name(path.name)} 不属于此节点，请检查服务文件。")


def start_node(data):
    unit = unit_name(data["name"])
    port = ports(data["ports"])[0]
    run("systemctl", "start", unit)
    for _ in range(30):
        pid = run("systemctl", "show", unit, "-p", "MainPID", "--value").stdout.strip()
        if pid and pid != "0" and any(port == current and pid in pids for current, pids in listeners()):
            if active(unit):
                return
        time.sleep(0.2)
    raise ValueError(f"节点未开始监听 UDP {port}。请查看 journalctl -u {unit}。")


def add_node(args, path, data, stage):
    link = unit_link(path)
    if path.exists() or path.is_symlink() or link.exists() or link.is_symlink():
        raise ValueError(f"节点或服务已存在：{args.name}")
    stage.rename(path)
    unit = unit_name(args.name)
    try:
        link.symlink_to(path / link.name)
    except (OSError, KeyboardInterrupt):
        shutil.rmtree(path)
        raise
    try:
        run("systemctl", "daemon-reload")
        open_firewall(args.name, data["ports"])
        run("systemctl", "enable", unit)
        start_node(data)
    except (Exception, KeyboardInterrupt):
        try:
            remove_node(path)
        except Exception as error:
            raise ValueError(f"新增失败，清理中断，已保留 {args.name} 的配置以便重试删除。{error}") from error
        raise


def remove_node(path):
    unit = unit_name(path.name)
    link = unit_link(path)
    if link.exists() or link.is_symlink():
        check_unit_link(path)
        run("systemctl", "stop", unit)
        clean_firewall(path.name)
        run("systemctl", "disable", unit)
        if link.is_symlink():
            check_unit_link(path)
            link.unlink()
    else:
        run("systemctl", "daemon-reload")
        if run("systemctl", "show", unit, "-p", "LoadState", "--value", check=False).stdout.strip() != "not-found":
            raise ValueError(f"无法确认 {unit} 已移除，请检查系统服务。")
        clean_firewall(path.name)
    run("systemctl", "daemon-reload")
    shutil.rmtree(path)


def edit_node(data, old, path, stage, previous):
    check_unit_link(path)
    unit = unit_name(path.name)
    was_active = active(unit)
    if data == old:
        open_firewall(path.name, data["ports"])
        clean_firewall(path.name, firewall_port(data["ports"]))
        return
    run("systemctl", "stop", unit)
    try:
        path.rename(previous)
        stage.rename(path)
        run("systemctl", "daemon-reload")
        open_firewall(path.name, data["ports"])
        if was_active:
            start_node(data)
    except (Exception, KeyboardInterrupt):
        run("systemctl", "stop", unit)
        if previous.exists():
            if path.exists():
                path.rename(stage)
            previous.rename(path)
        run("systemctl", "daemon-reload")
        if was_active:
            start_node(old)
        clean_firewall(path.name, firewall_port(old["ports"]))
        raise
    shutil.rmtree(previous)
    clean_firewall(path.name, firewall_port(data["ports"]))


def save_node(args):
    node_name(args.name)
    path = ROOT / args.name
    old = load_node(path) if args.action == "edit" else {}
    data = apply_preferences(args, old)
    check_hopping(ports(data["ports"]))
    ROOT.mkdir(exist_ok=True)
    if ROOT.is_symlink():
        raise ValueError("节点目录不能是符号链接。")
    gid = grp.getgrnam("hysteria").gr_gid
    os.chown(ROOT, 0, gid)
    ROOT.chmod(0o750)
    work = Path(tempfile.mkdtemp(prefix=f".{args.name}-", dir=ROOT))
    stage = work / "next"
    previous = work / "previous"
    stage.mkdir()
    try:
        write_files(data, path if old else None, stage, path)
        if old:
            edit_node(data, old, path, stage, previous)
        else:
            add_node(args, path, data, stage)
    finally:
        if not previous.exists():
            shutil.rmtree(work)
        else:
            print(f"原配置保存在 {previous}，请核对服务后再清理。", file=sys.stderr)
    print(f"节点 {args.name} 已保存 · 本地 UDP {data['ports']} · 公网 UDP {data['public_ports']}")
    print(f"查看连接信息：buds hy2 nodes link {args.name}")


def quick_add_preferences(name):
    node_name(name)
    path = ROOT / name
    link = unit_link(path)
    if path.exists() or path.is_symlink() or link.exists() or link.is_symlink():
        print(f"节点或服务已存在：{name}。请换一个名称。", file=sys.stderr)
        sys.exit(3)
    reserved, public = port_conflicts(name)
    default_domain = "" if PRIMARY_DOMAIN == "your.domain.com" else PRIMARY_DOMAIN
    hint = f"（回车沿用 {default_domain}）" if default_domain else ""
    while True:
        try:
            domain = domain_name(input(f"访问域名或 IPv4{hint}：").strip() or default_domain)
            break
        except ValueError as error:
            print(error, file=sys.stderr)

    local_main = PRIMARY_LISTEN.partition("#")[0].strip() or "443"
    public_main = PRIMARY_PUBLIC.partition("#")[0].strip() or local_main
    mapped = (BASE / ".nat-mode").is_file() or public_main.replace(":", "-") != local_main.replace(":", "-")
    while True:
        requested = input("本地 UDP 端口（回车自动；单端口、范围或 auto:32）：").strip() or "auto"
        try:
            span = choose_ports(requested, reserved + public if requested.startswith("auto") else reserved)
            check_hopping(span)
            local = port_text(span)
            if not mapped:
                choose_ports(local, public)
            break
        except ValueError as error:
            print(error, file=sys.stderr)

    external = local
    if mapped:
        while True:
            requested = input(f"公网 UDP 端口或范围（回车使用 {local}，需在服务商处映射）：").strip() or local
            try:
                external = port_text(choose_ports(requested, public))
                break
            except ValueError as error:
                print(error, file=sys.stderr)

    return argparse.Namespace(action="add", name=name, domain=domain, ports=local,
                              public_ports=external, auth="random", obfs="random", tls=None)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(prog="buds hy2 nodes")
    actions = parser.add_subparsers(dest="action")
    actions.add_parser("list")
    actions.add_parser("names")
    actions.add_parser("quick-add").add_argument("name")
    for verb in ("add", "edit"):
        command = actions.add_parser(verb)
        command.add_argument("name")
        command.add_argument("--domain")
        command.add_argument("--ports")
        command.add_argument("--public-ports")
        command.add_argument("--auth", choices=("keep", "random", "custom"), default="keep")
        command.add_argument("--obfs", choices=("keep", "random", "custom"), default="keep")
        command.add_argument("--tls", choices=("auto", "self", "shared"))
    for verb in ("detail", "status", "start", "stop", "restart", "log", "delete"):
        command = actions.add_parser(verb)
        command.add_argument("name")
        if verb == "delete":
            command.add_argument("--yes", action="store_true")
    args = parser.parse_args(sys.argv[5:])
    if not args.action:
        parser.error("请选择一个多节点命令，或使用 --help 查看帮助。")
    if args.action in ("list", "names"):
        entries = list(nodes())
        if args.action == "names":
            for data in entries:
                print(data["name"])
            return
        rows = []
        if (BASE / "config.yaml").is_file():
            state = "运行中" if active("hysteria-server.service") else "已停止"
            rows.append(("main", state, PRIMARY_LISTEN or "443", PRIMARY_PUBLIC or PRIMARY_LISTEN or "443", PRIMARY_DOMAIN))
        for data in entries:
            state = "运行中" if active(unit_name(data["name"])) else "已停止"
            rows.append((data["name"], state, data["ports"], data["public_ports"], data["domain"]))
        if not rows:
            print("尚未配置节点。")
            return
        width = max(len(row[0]) for row in rows)
        width = max(width, 4)
        print(f"{'名称':<{width - 2}}  {'状态':<4}  {'本地 UDP':<11}  {'公网 UDP':<11}  地址")
        for name, state, local, public, domain in rows:
            print(f"{name:<{width}}  {state}  {local:<13}  {public:<13}  {domain}")
        return
    if args.action in ("add", "edit", "quick-add"):
        if pwd.getpwnam("hysteria").pw_gid != grp.getgrnam("hysteria").gr_gid:
            raise ValueError("请检查现有 hysteria 服务账户和用户组。")
        if args.action == "quick-add":
            import fcntl
            args = quick_add_preferences(args.name)
            print("正在生成认证密码、混淆密码和证书，并启动节点…", flush=True)
            fcntl.flock(9, fcntl.LOCK_EX)
        save_node(args)
        return
    if args.name == "main":
        raise ValueError("请在主菜单管理原有主节点。")
    name = node_name(args.name)
    path = ROOT / name
    data = load_node(path)
    unit = unit_name(name)
    if args.action == "detail":
        print(f"{name} · {data['domain']} · 本地 UDP {data['ports']} · 公网 UDP {data['public_ports']} · TLS {data['tls']}")
        return
    if args.action == "delete":
        if not args.yes:
            raise ValueError("删除节点须加 --yes。")
        remove_node(path)
        print(f"已删除节点 {name}。")
        return
    check_unit_link(path)
    if args.action == "log":
        subprocess.run(["journalctl", "-u", unit, "-n", "50", "--no-pager"], check=True)
    elif args.action == "status":
        r = run("systemctl", "status", unit, "--no-pager", check=False)
        print(r.stdout, end="")
    elif args.action == "stop":
        run("systemctl", "stop", unit)
        print(f"已停止节点 {name}。")
    else:
        reserved, public = port_conflicts(name)
        check_hopping(choose_ports(data["ports"], reserved))
        choose_ports(data["public_ports"], public)
        open_firewall(name, data["ports"])
        if args.action == "restart":
            run("systemctl", "stop", unit)
        start_node(data)
        print(f"节点 {name} 正在运行。")


try:
    main()
except (ValueError, OSError, KeyError) as error:
    sys.exit(str(error))
except subprocess.CalledProcessError as error:
    sys.exit((error.stderr or error.stdout or "系统命令执行失败。").strip())
except subprocess.TimeoutExpired:
    sys.exit("系统命令超时，请检查节点和防火墙状态。")
except (EOFError, KeyboardInterrupt):
    sys.exit("操作已取消。")
PY
}

nodes_tool() {
    python3 -I -c "$(nodes_source)" "$CONFIG_DIR" "$(get_listen)" "$(get_public_ports)" "$(get_domain)" "$@"
}

nodes_manage() (
    local action=${1:-list} name=${2:-}
    if [[ "$name" == main && ( "$action" == link || "$action" == client || "$action" == status ) ]]; then
        "$action"
        return
    fi
    has_systemd || { echo "多节点管理需要 systemd。原有节点可继续在主菜单管理。" >&2; return 1; }
    local dependency
    for dependency in python3 flock ss openssl; do
        command -v "$dependency" >/dev/null || { echo "多节点管理缺少 $dependency。" >&2; return 1; }
    done
    exec 9>/run/buds-hy2-nodes.lock || return 1
    if [[ "$action" != quick-add ]]; then flock -x 9 || return 1; fi
    if [[ "$action" == link || "$action" == client ]]; then
        nodes_tool detail "$name" || return 1
        CONFIG_DIR="$CONFIG_DIR/nodes/$name"
        CONFIG_FILE="$CONFIG_DIR/config.yaml"
        CLIENT_CONFIG_FILE="$CONFIG_DIR/client.yaml"
        NODE_LABEL="$name"
        "$action"
    elif (( $# )); then
        nodes_tool "$@"
    else
        nodes_tool list
    fi
)

panel_clear() {
    if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then printf '\033[H\033[2J'; fi
}

panel_pause() {
    if [[ -t 0 && -t 1 ]]; then
        local key
        printf '\n'
        IFS= read -rp "按回车返回$1… " key
    fi
}

nodes_quick_add() {
    local name rc
    printf '\nHysteria 2 新节点安装\n\n'
    while true; do
        read -rp '节点名称（回车自动，输入 0 取消）：' name || return 0
        if [[ "$name" == 0 ]]; then return 0; fi
        name=${name:-node-$(date +%m%d%H%M%S)-$RANDOM}
        if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]{0,30}$ || "$name" == main ]]; then
            echo '请输入 1–31 位小写字母、数字、下划线或短横线，名称以字母或数字开头。'
            continue
        fi
        if nodes_manage quick-add "$name"; then break; else rc=$?; fi
        if (( rc != 3 )); then return "$rc"; fi
    done
    nodes_manage link "$name" || printf '节点已启动。可在节点菜单重新查看 %s 的连接链接。\n' "$name"
}

nodes_edit_menu() {
    local name=$1 choice flag value prompt
    while true; do
        panel_clear
        printf '\n编辑节点 %s\n\n' "$name"
        printf '%s\n' '1. 访问地址      2. 本地 UDP 端口' \
            '3. 公网端口映射  4. 重新生成认证和混淆密码' \
            '5. 自定义密码    6. TLS 证书' '0. 返回节点菜单'
        read -rp '请选择要修改的设置：' choice || return 0
        case "$choice" in
            1) flag=--domain; prompt='新域名或 IPv4 地址（回车取消）：' ;;
            2) flag=--ports; prompt='新本地 UDP 单端口、范围或 auto:32（回车取消）：' ;;
            3) flag=--public-ports; prompt='公网 UDP 端口或范围（same 与本地相同，回车取消）：' ;;
            4)
                read -rp '替换两种密码后需重新导入客户端配置。确认？[y/N] ' value || return 0
                if [[ "${value,,}" == y ]]; then
                    nodes_manage edit "$name" --auth random --obfs random || echo '密码更新未完成。'
                    panel_pause '编辑菜单' || return 0
                fi
                continue ;;
            5)
                read -rp '1. 认证密码  2. 混淆密码  0. 取消：' value || return 0
                case "$value" in
                    1) nodes_manage edit "$name" --auth custom || echo '密码更新未完成。' ;;
                    2) nodes_manage edit "$name" --obfs custom || echo '密码更新未完成。' ;;
                    *) continue ;;
                esac
                panel_pause '编辑菜单' || return 0
                continue ;;
            6) flag=--tls; prompt='auto 自动 / self 自签名 / shared 复用主证书（回车取消）：' ;;
            0|'') return 0 ;;
            *) echo '请输入有效编号。'; panel_pause '编辑菜单' || return 0; continue ;;
        esac
        read -rp "$prompt" value || return 0
        if [[ -z "$value" ]]; then continue; fi
        nodes_manage edit "$name" "$flag" "$value" || echo '修改未完成，请检查提示。'
        panel_pause '编辑菜单' || return 0
    done
}

nodes_selected_menu() {
    local name=$1 choice action confirm
    while true; do
        panel_clear
        printf '\n管理节点 %s\n\n' "$name"
        if ! nodes_manage detail "$name"; then
            panel_pause '多节点管理' || true
            return 0
        fi
        printf '\n%s\n' '1. 连接链接  2. 客户端配置  3. 运行状态  4. 最近日志'
        printf '%s\n' '5. 启动  6. 停止  7. 重启  8. 编辑设置  9. 删除' '0. 返回多节点管理'
        read -rp '请选择节点操作：' choice || return 0
        case "$choice" in
            1) action=link ;;
            2) action=client ;;
            3) action=status ;;
            4) action=log ;;
            5) action=start ;;
            6) action=stop ;;
            7) action=restart ;;
            8) nodes_edit_menu "$name"; continue ;;
            9)
                read -rp "输入 $name 确认删除（回车取消）：" confirm || return 0
                if [[ "$confirm" == "$name" ]]; then
                    if nodes_manage delete "$name" --yes; then
                        panel_pause '多节点管理' || true
                        return 0
                    fi
                    echo '删除未完成，请检查提示。'
                else
                    echo '已取消删除。'
                fi
                panel_pause '节点菜单' || return 0
                continue ;;
            0|'') return 0 ;;
            *) echo '请输入有效编号。'; panel_pause '节点菜单' || return 0; continue ;;
        esac
        nodes_manage "$action" "$name" || echo '操作未完成，请检查提示。'
        panel_pause '节点菜单' || return 0
    done
}

nodes_pick() {
    local listed choice i
    local -a names
    if ! listed=$(nodes_manage names); then
        panel_pause '多节点管理' || true
        return 0
    fi
    if [[ -z "$listed" ]]; then
        echo '还没有新增节点。可选择 2 一键新增，原有主节点由主菜单管理。'
        panel_pause '多节点管理' || true
        return 0
    fi
    mapfile -t names <<< "$listed"
    printf '\n选择一个新增节点\n\n'
    for i in "${!names[@]}"; do printf '%s. %s\n' "$((i+1))" "${names[i]}"; done
    while read -rp '输入节点编号（回车取消）：' choice && [[ -n "$choice" && "$choice" != 0 ]]; do
        if [[ "$choice" =~ ^[1-9][0-9]{0,5}$ ]] && (( choice <= ${#names[@]} )); then
            nodes_selected_menu "${names[choice-1]}"
            return 0
        fi
        echo '请从列表中选择一个节点编号。'
    done
}

nodes_menu() {
    local choice
    while true; do
        panel_clear
        printf '\nHysteria 2 多节点管理\n\n'
        printf '%s\n' '1. 节点列表' '2. 一键新增节点' '3. 管理已有节点' '0. 返回主菜单'
        read -rp '请选择多节点操作：' choice || return 0
        case "$choice" in
            1) nodes_manage list || true ;;
            2) nodes_quick_add || echo '新增未完成，请检查提示。' ;;
            3) nodes_pick; continue ;;
            0|'') return 0 ;;
            *) echo '请输入有效编号。' ;;
        esac
        panel_pause '多节点管理' || return 0
    done
}

uninstall() (
    echo -e "\n  ${C_RED}⚠ 警告: 即将卸载 Hysteria 2 服务！${C_RESET}"
    read -rp "  确认彻底卸载吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if command -v flock >/dev/null; then
            exec 9>/run/buds-hy2-nodes.lock && flock -x 9 || return 1
        fi
        if [[ -L "$CONFIG_DIR/nodes" ]] ||
            { [[ -d "$CONFIG_DIR/nodes" ]] && [[ -n "$(find "$CONFIG_DIR/nodes" -mindepth 1 -maxdepth 1 -print -quit)" ]]; }; then
            echo "还有附加节点或待恢复的节点配置。请在多节点管理中逐个处理后再卸载。" >&2
            return 1
        fi
        if [[ -f "$WARP_DIR/.buds-managed" ]]; then warp_manage disable || return 1; fi
        if ! cleanup_renewal; then
            echo "  卸载已停止：续签任务未能清理，请处理后重试。" >&2
            return 1
        fi
        # 历史版本可能已删除服务定义。停止失败时，仅在服务仍活动时中止清理。
        if ! stop && { (has_systemd && systemctl is-active --quiet hysteria-server) ||
            (has_openrc && rc-service hysteria-server status >/dev/null 2>&1) ||
            pgrep -fx "$PROCESS_PATTERN" >/dev/null 2>&1; }; then
            echo "  卸载已停止：服务未能停止，请处理后重试。" >&2
            return 1
        fi
        if ! cleanup_firewall; then
            echo "  服务已停止，卸载尚未完成：防火墙清理失败，已保留服务定义、节点配置和待清理规则。" >&2
            return 1
        fi
        if has_systemd; then
            if [[ -f /etc/systemd/system/hysteria-server.service ]] ||
                systemctl is-enabled --quiet hysteria-server; then
                systemctl disable hysteria-server || return 1
            fi
            rm -rf /etc/systemd/system/hysteria-server.service.d || return 1
            rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service || return 1
            systemctl daemon-reload || return 1
        fi
        if has_openrc; then
            if [[ -e /etc/runlevels/default/hysteria-server || -L /etc/runlevels/default/hysteria-server ]]; then
                rc-update del hysteria-server default || return 1
            fi
            rm -f /etc/init.d/hysteria-server || return 1
        fi
        if [[ -f /etc/rc.local ]]; then
            sed -i '\|^/usr/local/bin/hysteria-service start$|d' /etc/rc.local
        fi
        rm -f /usr/local/bin/hysteria /usr/local/bin/buds /usr/local/bin/hy2 /usr/local/bin/hysteria-service
        rm -rf /etc/hysteria /var/log/hysteria.log /etc/logrotate.d/hysteria
        rm -f /etc/letsencrypt/renewal-hooks/deploy/hysteria-sync.sh
        rm -f /etc/sysctl.d/99-hysteria-performance.conf
        echo -e "\n  ${C_BAR}  ${C_GREEN}✔ Hysteria 2 服务已卸载，本项目创建的防火墙规则已清理，原有 Nginx 及其他系统服务未作修改。${C_RESET}\n"
    else
        echo -e "\n  已取消卸载。\n"
        if [[ "${1:-}" == menu ]]; then return 1; fi
    fi
)

is_version_newer() {
    local remote="$1" current="$2"
    [[ -z "$remote" || -z "$current" || "$remote" == "$current" ]] && return 1

    local -a r_parts c_parts
    IFS='.' read -r -a r_parts <<< "$remote"
    IFS='.' read -r -a c_parts <<< "$current"

    local max_len=${#r_parts[@]}
    [[ ${#c_parts[@]} -gt $max_len ]] && max_len=${#c_parts[@]}

    local i
    for ((i=0; i<max_len; i++)); do
        local r="${r_parts[i]:-0}"
        local c="${c_parts[i]:-0}"
        r="${r//[^0-9]/}"
        c="${c//[^0-9]/}"
        [[ -z "$r" ]] && r=0
        [[ -z "$c" ]] && c=0
        if (( 10#$r > 10#$c )); then
            return 0
        elif (( 10#$r < 10#$c )); then
            return 1
        fi
    done
    return 1
}

valid_release_version() {
    [[ "$1" =~ ^(0|[1-9][0-9]{0,8})(\.(0|[1-9][0-9]{0,8})){2}$ ]]
}

read_script_version() {
    sed -n 's/^SCRIPT_VERSION="\([0-9][0-9.]*\)"$/\1/p' "$1"
}

fetch_repo_version() (
    [[ -s "$UPDATE_PUBLIC_KEY" ]] || return 1
    local tmp version
    tmp=$(mktemp -d) || return 2
    trap 'rm -rf -- "$tmp"' EXIT
    curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 3 --max-time 6 --max-filesize 128 \
        "$UPDATE_REPO_URL/buds.version" -o "$tmp/version" 2>/dev/null || return 1
    curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 3 --max-time 6 --max-filesize 16384 \
        "$UPDATE_REPO_URL/buds.version.sig" -o "$tmp/version.sig" 2>/dev/null &&
        openssl dgst -sha256 -verify "$UPDATE_PUBLIC_KEY" -signature "$tmp/version.sig" "$tmp/version" >/dev/null 2>&1 ||
        { echo "仓库更新版本验签失败。" >&2; return 2; }
    version=$(cat "$tmp/version") || return 2
    valid_release_version "$version" || return 2
    printf '%s\n' "$version"
)

check_remote_version() {
    local force="${1:-false}" now cache_time remote_ver
    now=$(date +%s) || return 1

    if [[ "$force" != true && -f "$VERSION_CACHE_FILE" ]]; then
        IFS=: read -r cache_time remote_ver < "$VERSION_CACHE_FILE" || true
        if [[ "$cache_time" =~ ^[1-9][0-9]{0,11}$ ]] &&
            valid_release_version "$remote_ver" && (( now >= cache_time && now - cache_time < 1800 )); then
            printf '%s\n' "$remote_ver"
            return 0
        fi
    fi

    remote_ver=$(fetch_repo_version) || return 1
    if [[ -d "$CONFIG_DIR" ]]; then
        (umask 077; printf '%s:%s\n' "$now" "$remote_ver" > "$VERSION_CACHE_FILE") 2>/dev/null || true
    fi
    printf '%s\n' "$remote_ver"
}

update_script() (
    if [[ ! -s "$UPDATE_PUBLIC_KEY" ]]; then
        printf '缺少可信发布公钥 %s，请按 README 安装。\n' "$UPDATE_PUBLIC_KEY" >&2
        return 1
    fi
    local remote_ver
    if ! remote_ver=$(check_remote_version true); then
        echo "无法获取有效的仓库更新版本，请检查网络、更新分支和签名。" >&2
        return 1
    fi
    if ! is_version_newer "$remote_ver" "$SCRIPT_VERSION"; then
        printf '当前已是最新版本（v%s）。\n' "$SCRIPT_VERSION"
        return 0
    fi
    if ! command -v flock >/dev/null 2>&1; then
        echo "更新需要 flock，请安装系统提供的 flock 工具。" >&2
        return 1
    fi

    local target_dir installed_ver tmp_dir release_url downloaded_ver lock_fd
    target_dir=$(dirname "$BUDS_CLI") || return 1
    # 持锁重新检查已安装版本，避免并发更新用较旧版本覆盖新版本。
    (umask 077; : >> "${UPDATE_PUBLIC_KEY}.lock") || return 1
    exec {lock_fd}<> "${UPDATE_PUBLIC_KEY}.lock" || return 1
    flock -x "$lock_fd" || return 1
    if [[ -f "$BUDS_CLI" ]]; then
        installed_ver=$(read_script_version "$BUDS_CLI") || return 1
        if valid_release_version "$installed_ver" && ! is_version_newer "$remote_ver" "$installed_ver"; then
            printf '已安装 v%s，无需替换。\n' "$installed_ver"
            return 0
        fi
    fi

    tmp_dir=$(mktemp -d "${target_dir}/.buds_update.XXXXXX") || return 1
    trap 'rm -rf -- "$tmp_dir"' EXIT
    release_url="$UPDATE_REPO_URL/releases/$remote_ver"
    if ! curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 20 --max-filesize 1048576 \
        "${release_url}/buds" -o "${tmp_dir}/buds" ||
        ! curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 20 --max-filesize 16384 \
        "${release_url}/buds.sig" -o "${tmp_dir}/buds.sig"; then
        echo "下载发布脚本或签名失败，已保留现有脚本。" >&2
        return 1
    fi
    if ! openssl dgst -sha256 -verify "$UPDATE_PUBLIC_KEY" \
        -signature "${tmp_dir}/buds.sig" "${tmp_dir}/buds" >/dev/null 2>&1; then
        echo "发布签名验证失败，已保留现有脚本。" >&2
        return 1
    fi

    downloaded_ver=$(read_script_version "${tmp_dir}/buds") || return 1
    if [[ "$downloaded_ver" != "$remote_ver" ]]; then
        echo "下载脚本版本不匹配，已保留现有脚本。" >&2
        return 1
    fi
    if [[ "$(head -n 1 "${tmp_dir}/buds")" != '#!/usr/bin/env bash' ]] ||
        ! bash -n "${tmp_dir}/buds" 2>/dev/null; then
        echo "新脚本语法校验未通过，已保留现有脚本。" >&2
        return 1
    fi
    if [[ -d "$BUDS_CLI" ]] ||
        ! chmod 755 "${tmp_dir}/buds" || ! mv -f "${tmp_dir}/buds" "$BUDS_CLI"; then
        echo "无法替换管理脚本，已保留现有脚本。" >&2
        return 1
    fi
    if ! ln -sf "$BUDS_CLI" "$HY2_CLI"; then
        echo "主脚本已更新，hy2 快捷链接创建失败，可继续使用 buds。" >&2
    fi
    rm -f "$VERSION_CACHE_FILE" 2>/dev/null || true
    printf '脚本已成功更新至 v%s！\n' "$remote_ver"
)

warp_domains_menu() {
    local choice old new file confirm
    local -a items
    while true; do
        panel_clear
        printf '\n域名清单：1 查看　2 添加　3 删除　4 修改　5 导入整份清单　6 恢复 Google 默认清单　0 返回\n'
        read -rp "请选择： " choice || return
        case "$choice" in
            1) warp_manage domains list || true ;;
            2|3)
                read -ra items -p "输入域名，多个域名用空格分隔： " || return
                if [[ "$choice" == 2 ]]; then warp_manage domains add "${items[@]}" || true
                else warp_manage domains remove "${items[@]}" || true; fi ;;
            4)
                read -rp "原域名： " old && read -rp "新域名： " new || return
                warp_manage domains replace "$old" "$new" || true ;;
            5)
                read -rp "输入用于替换整份清单的文件路径（回车取消）： " file || return
                if [[ -n "$file" ]]; then warp_manage domains import "$file" || true; fi ;;
            6)
                read -rp "用 Google 默认域名替换当前全部条目？[y/N] " confirm || return
                if [[ "$confirm" =~ ^[Yy]$ ]]; then warp_manage domains reset || true; fi ;;
            0|"") return 0 ;;
            *) echo "请输入 0 至 6。" ;;
        esac
        panel_pause '域名管理' || return 0
    done
}

warp_menu_begin() {
    local confirm switched=false
    if systemctl is-active --quiet "$WARP_UNIT" 2>/dev/null; then
        echo "WARP 分流已经启用，开始检测。"
        warp_manage check
        return
    fi
    warp_requirements before-dns && warp_manage setup || return 1
    if ! warp_check_stub 2>/dev/null; then
        read -rp "首次启用需迁移 DNS，会短暂重启解析服务。确认？[y/N] " confirm || return 1
        if [[ "${confirm,,}" != y ]]; then echo "已取消启用，已准备的依赖可下次复用。"; return 0; fi
        warp_manage dns-switch || return 1
        switched=true
    fi
    if ! warp_manage enable; then
        if [[ "$switched" == true ]]; then warp_manage dns-restore || true; fi
        return 1
    fi
}

warp_menu() {
    local choice profile confirm
    while true; do
        panel_clear
        printf '\nWARP 定向分流\n'
        if systemctl is-active --quiet "$WARP_UNIT" 2>/dev/null; then
            echo "WARP 分流正在运行。"
        elif [[ -d "$WARP_DIR" ]]; then
            echo "WARP 服务未运行，可选择 p 检查或用 buds hy2 warp status 查看日志。"
        else
            echo "WARP 分流未启用。首次使用可选择 a 按提示完成，也可分步操作。"
        fi
        printf '%s\n' 'a  引导安装并启用' \
            'p  启用前诊断    s  准备依赖      i  安装独立内核' \
            'n  迁移 DNS      r  恢复 DNS' \
            'e  启用分流      c  检测出口      d  关闭分流' \
            'm  管理域名      g  Gemini 出口地址族      0  返回主菜单'
        read -rp "请选择： " choice || return 0
        case "${choice,,}" in
            a) warp_menu_begin || echo "引导未完成，可选择 p 检查并按提示重试。" ;;
            p) warp_manage doctor || true ;;
            s) warp_manage setup || echo "准备依赖未完成，请参照上方提示。" ;;
            i) warp_manage setup --managed-core || echo "独立内核准备未完成，请参照上方提示。" ;;
            n|r)
                if [[ "${choice,,}" == n ]]; then
                    read -rp "迁移系统 DNS 到本机存根，会短暂重启解析服务。确认？[y/N] " confirm || return 0
                    if [[ "${confirm,,}" == y ]]; then
                        warp_manage dns-switch || echo "DNS 迁移未完成，请参照上方提示。"
                    else
                        echo "已取消 DNS 迁移。"
                    fi
                else
                    read -rp "恢复迁移前的 DNS，会短暂重启解析服务。确认？[y/N] " confirm || return 0
                    if [[ "${confirm,,}" == y ]]; then
                        warp_manage dns-restore || echo "DNS 恢复未完成，请参照上方提示。"
                    else
                        echo "已取消 DNS 恢复。"
                    fi
                fi
                ;;
            e)
                read -rp "WireGuard 配置路径（回车自动查找）： " profile || return 0
                warp_manage enable "$profile" || echo "启用未完成，可选择 p 查看启用条件。"
                ;;
            c) warp_manage check || true ;;
            d) warp_manage disable || echo "关闭未完成，请参照上方提示。" ;;
            m) warp_domains_menu; continue ;;
            g)
                warp_manage gemini-family || true
                read -rp '输入 auto、ipv4 或 ipv6（更改需要短暂重启 WARP，回车返回）: ' profile || return 0
                if [[ -n "$profile" ]]; then warp_manage gemini-family "$profile" || true; fi
                ;;
            0|"") return 0 ;;
            *) echo "选项无效，请重新选择。" ;;
        esac
        panel_pause 'WARP 菜单' || return 0
    done
}

show_menu() {
    local remote_ver choice
    remote_ver=$(check_remote_version 2>/dev/null) || remote_ver=""
    while true; do
        local status_badge domain listen has_update
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
            if pgrep -fx "$PROCESS_PATTERN" >/dev/null 2>&1; then
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
        has_update=false
        if is_version_newer "$remote_ver" "$SCRIPT_VERSION"; then
            has_update=true
        fi

        panel_clear
        echo -e "       ${C_SPARK}✧${C_RESET}                                      ${C_SPARK}✦${C_RESET}"
        echo -e "  ${C_ORANGE_BOLD}█▀▀█ █  █ █▀▀▄ █▀▀▀${C_RESET}   ${C_GRAY_LIGHT}█  █ █  █ █▀▀█${C_RESET}"
        echo -e "  ${C_ORANGE_BOLD}█▀▀▄ █  █ █  █ ▀▀▀█${C_RESET}   ${C_GRAY_LIGHT}█▀▀█ ▀██▀   ▄▀${C_RESET}"
        echo -e "  ${C_ORANGE_BOLD}█  █ █  █ █  █    █${C_RESET}   ${C_GRAY_LIGHT}█  █   █  ▄▀  ${C_RESET}"
        echo -e "  ${C_ORANGE_BOLD}▀▀▀▀ ▀▀▀▀ ▀▀▀  ▀▀▀▀${C_RESET}   ${C_GRAY_LIGHT}▀  ▀   ▀  ▀▀▀▀${C_RESET}"
        echo -e "  ${C_GRAY_MID}Hysteria 2 High-Performance Protocol Suite${C_RESET}  ${C_CYAN}v${SCRIPT_VERSION}${C_RESET}\n"

        echo -e "  ${C_BAR}  ${C_WHITE}节点状态${C_RESET}  ${status_badge}    ${C_WHITE}监听端口${C_RESET}  ${C_CYAN}${listen}${C_RESET}"
        echo -e "  ${C_BAR}  ${C_GRAY_MID}解析域名${C_RESET}  ${C_GRAY_LIGHT}${domain}${C_RESET}    ${C_GRAY_MID}协议混淆${C_RESET}  ${C_AMBER}Salamander${C_RESET}"
        if [[ "$has_update" == "true" ]]; then
            echo -e "  ${C_BAR}  ${C_SPARK}✦ 发现脚本新版本  v${remote_ver} (当前: v${SCRIPT_VERSION})  ▶ 输入 8 或 u 即可一键更新${C_RESET}"
        fi
        echo ""

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
        if [[ "$has_update" == "true" ]]; then
            echo -e "     ${C_ORANGE_BOLD}8.${C_RESET} ${C_SPARK}更新脚本${C_RESET}      ${C_GRAY_MID}Update buds CLI to Latest${C_RESET} ${C_SPARK}(新版本: v${remote_ver})${C_RESET}"
        else
            echo -e "     ${C_ORANGE_BOLD}8.${C_RESET} ${C_WHITE}更新脚本${C_RESET}      ${C_GRAY_MID}Update buds CLI to Latest${C_RESET}"
        fi
        echo -e "     ${C_ORANGE_BOLD}9.${C_RESET} ${C_WHITE}模拟续签${C_RESET}      ${C_GRAY_MID}Let's Encrypt SSL Dry-Run${C_RESET}"
        echo -e "    ${C_ORANGE_BOLD}10.${C_RESET} ${C_WHITE}卸载节点${C_RESET}      ${C_GRAY_MID}Uninstall & Clean Firewall${C_RESET}"
        echo -e "    ${C_ORANGE_BOLD}11.${C_RESET} ${C_WHITE}WARP 定向分流${C_RESET}"
        echo -e "    ${C_ORANGE_BOLD}12.${C_RESET} ${C_WHITE}新增节点 / 多节点管理${C_RESET}"
        echo -e "     ${C_GRAY_MID}0.${C_RESET} ${C_GRAY_MID}退出脚本${C_RESET}      ${C_GRAY_MID}Exit${C_RESET}\n"

        read -rp "$(echo -e "  ${C_ORANGE_BOLD}❯${C_RESET} ${C_WHITE}请选择操作编号 [0-12]: ${C_RESET}")" choice || return 0
        case "$choice" in
            1) status || true ;;
            2) link || true ;;
            3) client || true ;;
            4) log || true ;;
            5) restart || echo -e "  ${C_RED}✖ 重启服务失败，请检查状态或日志。${C_RESET}" ;;
            6) start || echo -e "  ${C_RED}✖ 启动服务失败，请检查状态或日志。${C_RESET}" ;;
            7) stop || echo -e "  ${C_RED}✖ 停止服务失败，请检查进程状态。${C_RESET}" ;;
            8|[uU]|update)
                if update_script && [[ -x "$BUDS_CLI" ]]; then
                    panel_pause '主菜单' || return 0
                    exec "$BUDS_CLI" hy2
                fi
                ;;
            9) renew_test || echo -e "  ${C_RED}✖ 证书续签模拟失败，请检查日志。${C_RESET}" ;;
            10) if uninstall menu; then break; fi ;;
            11) warp_menu; continue ;;
            12) nodes_menu; continue ;;
            0) exit 0 ;;
            *) echo "输入无效，请重新选择。" ;;
        esac
        panel_pause '主菜单' || return 0
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
    warp) shift; warp_manage "$@" ;;
    nodes|node) shift; nodes_manage "$@" ;;
    renew-test) renew_test ;;
    uninstall) uninstall ;;
    update) update_script ;;
    check-update)
        if [[ ! -s "$UPDATE_PUBLIC_KEY" ]]; then
            printf '缺少可信发布公钥 %s，请按 README 安装。\n' "$UPDATE_PUBLIC_KEY" >&2
            exit 1
        fi
        if ! r_ver=$(check_remote_version true); then
            echo "无法获取有效的仓库更新版本，请检查网络、更新分支和签名。" >&2
            exit 1
        fi
        if is_version_newer "$r_ver" "$SCRIPT_VERSION"; then
            echo "新版本可用: v${r_ver} (当前: v${SCRIPT_VERSION})"
            exit 0
        else
            echo "已是最新版本: v${SCRIPT_VERSION}"
            exit 0
        fi
        ;;
    version|-v|--version)
        echo "buds-hy2 v${SCRIPT_VERSION}"
        exit 0
        ;;
    *) show_menu ;;
esac
BUDS_CLI_EOF
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
    echo -e "     ${C_ORANGE_BOLD}buds hy2 restart${C_RESET}  ${C_GRAY_MID}重启服务${C_RESET}"
    echo -e "     ${C_ORANGE_BOLD}buds hy2 update${C_RESET}   ${C_GRAY_MID}检查并更新管理脚本到最新版本${C_RESET}\n"
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
