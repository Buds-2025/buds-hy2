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
    if [[ $EUID -ne 0 ]]; then
        error "请以 root 权限运行此脚本。"
        exit 1
    fi
}

generate_random_string() {
    local length=${1:-16}
    head /dev/urandom | tr -dc A-Za-z0-9 | head -c "$length" || true
}

generate_random_port() {
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 20000-50000 -n 1
    else
        awk -v min=20000 -v max=50000 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'
    fi
}

install_dependencies() {
    info "检测并安装必要依赖组件..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y -qq curl wget openssl ufw certbot python3-certbot-nginx ca-certificates iptables iproute2 dnsutils libcap2-bin >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q epel-release || true
        dnf install -y -q curl wget openssl certbot python3-certbot-nginx ca-certificates iptables iproute bind-utils libcap >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q epel-release || true
        yum install -y -q curl wget openssl certbot python3-certbot-nginx ca-certificates iptables iproute bind-utils libcap >/dev/null 2>&1
    else
        warn "未识别到主流包管理器，尝试继续使用现有系统环境。"
    fi
    success "基础依赖环境准备完毕。"
}

validate_domain() {
    info "正在校验域名解析..."
    local server_ip="" resolved_ip=""
    server_ip=$(curl -s4 --connect-timeout 3 https://api.ipify.org || curl -s4 --connect-timeout 3 https://ip.sb || curl -s4 --connect-timeout 3 https://icanhazip.com || echo "")
    
    if command -v getent >/dev/null 2>&1; then
        resolved_ip=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | head -n1 | awk '{print $1}')
    elif command -v nslookup >/dev/null 2>&1; then
        resolved_ip=$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: / { print $2 }' | tail -n1)
    fi

    if [[ -n "$server_ip" && -n "$resolved_ip" ]]; then
        if [[ "$server_ip" != "$resolved_ip" ]]; then
            warn "域名解析 IP (${resolved_ip}) 与本机公网 IP (${server_ip}) 不一致！"
            warn "若 DNS 尚未生效，向 Let's Encrypt 申请证书可能会失败。"
            read -rp "是否仍然强制继续？(y/N): " force_continue
            if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
                error "已取消安装，请待 DNS 解析生效后再运行。"
                exit 1
            fi
        else
            success "域名解析校验正常 (${DOMAIN} -> ${server_ip})。"
        fi
    fi
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
    read -rp "$(echo -e "${C_BOLD}请输入监听端口 [默认: ${DEFAULT_RANDOM_PORT}]: ${C_RESET}")" INPUT_PORT
    INPUT_PORT="${INPUT_PORT:-$DEFAULT_RANDOM_PORT}"

    if [[ "$INPUT_PORT" =~ ^([0-9]+)[:\-]([0-9]+)$ ]]; then
        IS_PORT_HOPPING=true
        HOP_START="${BASH_REMATCH[1]}"
        HOP_END="${BASH_REMATCH[2]}"
        
        if (( HOP_START >= HOP_END || HOP_START < 1024 || HOP_END > 65535 )); then
            error "端口范围无效 (${HOP_START}-${HOP_END})，范围应在 1024~65535 之间且起始小于结束。"
            exit 1
        fi
        LISTEN_STR=":${HOP_START}-${HOP_END}"
        UFW_PORT_RULE="${HOP_START}:${HOP_END}/udp"
        BASE_PORT="$HOP_START"
        CLIENT_PORT_STR="${HOP_START}-${HOP_END}"
        info "已选择端口跳跃: ${C_CYAN}${HOP_START} 至 ${HOP_END}${C_RESET} (基准监听端口: ${BASE_PORT})"
    elif [[ "$INPUT_PORT" =~ ^[0-9]+$ ]]; then
        IS_PORT_HOPPING=false
        SINGLE_PORT="$INPUT_PORT"
        if (( SINGLE_PORT < 1024 || SINGLE_PORT > 65535 )); then
            error "单端口应在 1024~65535 之间。"
            exit 1
        fi
        LISTEN_STR=":${SINGLE_PORT}"
        UFW_PORT_RULE="${SINGLE_PORT}/udp"
        BASE_PORT="$SINGLE_PORT"
        CLIENT_PORT_STR="${SINGLE_PORT}"
        info "已选择单端口: ${C_CYAN}${SINGLE_PORT}${C_RESET}"
    else
        error "无法识别输入的端口格式: ${INPUT_PORT}"
        exit 1
    fi

    AUTH_PASSWORD="Hy2Pass_$(generate_random_string 12)"
    OBFS_PASSWORD="Obfs_$(generate_random_string 12)"
}

setup_certificates() {
    info "配置 SSL 证书..."

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 80/tcp comment 'certbot-http' >/dev/null 2>&1 || true
    fi

    if systemctl is-active --quiet nginx 2>/dev/null; then
        info "检测到运行中的 Nginx，使用 --nginx 插件进行零停机证书申领..."
        certbot certonly --nginx \
            -d "$DOMAIN" \
            --agree-tos \
            --register-unsafely-without-email \
            --keep-until-expiring \
            --non-interactive
    else
        info "使用 --standalone 独立模式申请证书..."
        certbot certonly --standalone \
            -d "$DOMAIN" \
            --agree-tos \
            --register-unsafely-without-email \
            --keep-until-expiring \
            --non-interactive
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
        chown root:hysteria "${CONFIG_DIR}/server.crt" "${CONFIG_DIR}/server.key"
    fi
    chmod 640 "${CONFIG_DIR}/server.crt" "${CONFIG_DIR}/server.key"
    if systemctl is-active --quiet hysteria-server; then
        systemctl restart hysteria-server
    fi
fi
EOF
    chmod +x "$HOOK_FILE"
    "$HOOK_FILE"
    success "SSL 证书部署完成，已挂载自动续期同步钩子。"
}

install_official_core() {
    info "安装官方 Hysteria 2 主程序..."
    bash <(curl -fsSL https://get.hy2.sh/)
    success "Hysteria 2 安装完成。"
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

    chown root:hysteria "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"
    chown root:hysteria "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    success "服务端配置文件写入完毕 (权限 640，归属 root:hysteria)。"
}

tune_kernel_network() {
    info "优化系统内核网络栈与 64MB UDP 缓冲区..."
    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe sch_fq >/dev/null 2>&1 || true

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

configure_systemd_override() {
    info "设置 systemd 高可用守护与特权补偿..."
    
    if command -v setcap >/dev/null 2>&1 && [[ -f /usr/local/bin/hysteria ]]; then
        setcap cap_net_bind_service,cap_net_admin,cap_net_raw=+ep /usr/local/bin/hysteria >/dev/null 2>&1 || true
    fi

    mkdir -p "$OVERRIDE_DIR"
    cat <<EOF > "$OVERRIDE_FILE"
[Service]
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF
    systemctl daemon-reload
    success "自动重启与并发限制配置生效 (崩溃 3 秒自愈 + 104 万描述符)。"
}

configure_firewall() {
    info "配置防火墙端口规则: ${UFW_PORT_RULE}..."
    
    # 记录防火墙规则，以便在卸载时精准撤销，避免破坏系统原有配置
    echo "${UFW_PORT_RULE}" > "${CONFIG_DIR}/.firewall_rule" 2>/dev/null || true
    chmod 600 "${CONFIG_DIR}/.firewall_rule" 2>/dev/null || true

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${UFW_PORT_RULE}" comment 'buds-hy2' >/dev/null 2>&1 || true
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        local fw_port="${UFW_PORT_RULE%/*}"
        local fw_proto="${UFW_PORT_RULE#*/}"
        fw_port="${fw_port//:/-}"
        firewall-cmd --permanent --add-port="${fw_port}/${fw_proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    if command -v iptables >/dev/null 2>&1; then
        if [[ "$IS_PORT_HOPPING" == "true" ]]; then
            iptables -I INPUT -p udp --dport "${HOP_START}:${HOP_END}" -m comment --comment "buds-hy2" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p udp --dport "${HOP_START}:${HOP_END}" -j ACCEPT >/dev/null 2>&1 || true
        else
            iptables -I INPUT -p udp --dport "${SINGLE_PORT}" -m comment --comment "buds-hy2" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p udp --dport "${SINGLE_PORT}" -j ACCEPT >/dev/null 2>&1 || true
        fi
    fi

    success "防火墙规则配置完成。"
}

start_service() {
    info "启动 Hysteria 2 服务..."
    systemctl enable --now hysteria-server
    sleep 2

    if systemctl is-active --quiet hysteria-server; then
        success "Hysteria 2 服务已正常运行。"
    else
        error "服务未能正常启动，请查看日志："
        journalctl -u hysteria-server -n 20 --no-pager
        exit 1
    fi
}

setup_cli() {
    cat <<EOF > "$CLIENT_CONFIG_FILE"
server: ${DOMAIN}:${CLIENT_PORT_STR}
auth: "${AUTH_PASSWORD}"
tls:
  sni: ${DOMAIN}
  insecure: false
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

status() {
    echo -e "\n  ${C_BAR}  ${C_WHITE}服务运行状态与 UDP 端口监听 · SERVICE STATUS${C_RESET}\n"
    systemctl status hysteria-server --no-pager || true
    echo -e "\n  ${C_SUBBAR}  ${C_ORANGE_BOLD}UDP 端口监听详情 · UDP LISTEN DETAILS${C_RESET}"
    ss -ulpn | grep hysteria || echo -e "     ${C_GRAY_MID}暂无活动 UDP 监听${C_RESET}"
    echo ""
}

log() {
    echo -e "\n  ${C_BAR}  ${C_ORANGE_BOLD}跟踪实时运行日志 · LIVE JOURNAL${C_RESET} ${C_GRAY_MID}(按 Ctrl+C 可退出)...${C_RESET}\n"
    journalctl -u hysteria-server -f -o cat
}

restart() {
    systemctl restart hysteria-server
    echo -e "\n  ${C_BAR}  ${C_GREEN}✔ Hysteria 2 服务已成功重启。${C_RESET}\n"
}

stop() {
    systemctl stop hysteria-server
    echo -e "\n  ${C_BAR}  ${C_AMBER}✔ Hysteria 2 服务已停止。${C_RESET}\n"
}

start() {
    systemctl start hysteria-server
    echo -e "\n  ${C_BAR}  ${C_GREEN}✔ Hysteria 2 服务已启动。${C_RESET}\n"
}

link() {
    if [[ ! -f "$CONFIG_FILE" && ! -f "$CLIENT_CONFIG_FILE" ]]; then
        echo -e "\n  ${C_RED}✖ 未检测到 Hysteria 2 配置文件。${C_RESET}\n"
        return 1
    fi

    local domain password obfs_pwd listen base_port
    domain=$(get_domain)
    password=$(get_password)
    obfs_pwd=$(get_obfs_pwd)
    listen=$(get_listen)
    base_port=$(echo "$listen" | cut -d '-' -f 1)

    local obfs_param=""
    if [[ -n "$obfs_pwd" ]]; then
        obfs_param="&obfs=salamander&obfs-password=${obfs_pwd}"
    fi

    echo -e "\n  ${C_BAR}  ${C_WHITE}节点连接凭据 · CONNECTION CREDENTIALS${C_RESET}"
    echo -e "     ${C_GRAY_MID}域名 (SNI)  :${C_RESET} ${C_WHITE}${domain}${C_RESET}"
    echo -e "     ${C_GRAY_MID}监听端口    :${C_RESET} ${C_CYAN}${listen}${C_RESET} ${C_GRAY_MID}(基准端口: ${base_port})${C_RESET}"
    echo -e "     ${C_GRAY_MID}认证密码    :${C_RESET} ${C_WHITE}${password}${C_RESET}"
    echo -e "     ${C_GRAY_MID}协议混淆    :${C_RESET} ${C_AMBER}salamander${C_RESET}"
    echo -e "     ${C_GRAY_MID}混淆密钥    :${C_RESET} ${C_WHITE}${obfs_pwd}${C_RESET}"
    echo -e "     ${C_GRAY_MID}伪装反代    :${C_RESET} ${C_GRAY_LIGHT}https://news.ycombinator.com/${C_RESET}\n"

    if [[ "$listen" =~ "-" ]]; then
        local link_hop="hysteria2://${password}@${domain}:${base_port}?sni=${domain}&insecure=1&allowInsecure=1${obfs_param}&mport=${listen}#${domain}-Hy2"
        local link_single="hysteria2://${password}@${domain}:${base_port}?sni=${domain}&insecure=1&allowInsecure=1${obfs_param}#${domain}-Hy2-Single"

        echo -e "  ${C_SUBBAR}  ${C_ORANGE_BOLD}格式 1 · 专属主节点链接${C_RESET} ${C_GRAY_MID}(端口跳跃 · v2rayN 兼容 · 防限速)${C_RESET}"
        echo -e "     ${C_YELLOW}${link_hop}${C_RESET}\n"

        echo -e "  ${C_SUBBAR}  ${C_ORANGE_BOLD}格式 2 · 基准单端口链接${C_RESET} ${C_GRAY_MID}(固定单端口 · 全客户端兼容备用)${C_RESET}"
        echo -e "     ${C_YELLOW}${link_single}${C_RESET}\n"
    else
        local link_main="hysteria2://${password}@${domain}:${base_port}?sni=${domain}&insecure=1&allowInsecure=1${obfs_param}#${domain}-Hy2"

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

    if [[ ! -f "$CLIENT_CONFIG_FILE" ]]; then
        local domain password obfs_pwd listen
        domain=$(get_domain)
        password=$(get_password)
        obfs_pwd=$(get_obfs_pwd)
        listen=$(get_listen)

        cat <<CLIENT_YAML_EOF > "$CLIENT_CONFIG_FILE"
server: ${domain}:${listen}
auth: "${password}"
tls:
  sni: ${domain}
  insecure: false
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
    fi

    echo -e "\n  ${C_BAR}  ${C_WHITE}客户端 YAML 配置 (${CLIENT_CONFIG_FILE})${C_RESET}\n"
    cat "$CLIENT_CONFIG_FILE"
    echo ""
}

renew_test() {
    echo -e "\n  ${C_BAR}  ${C_ORANGE_BOLD}模拟执行 Let's Encrypt 证书自动续签与挂钩同步...${C_RESET}\n"
    certbot renew --dry-run --run-deploy-hooks
}

cleanup_firewall() {
    local rule_file="${CONFIG_DIR}/.firewall_rule"
    local rule=""
    if [[ -f "$rule_file" ]]; then
        rule=$(tr -d '[:space:]' < "$rule_file" 2>/dev/null)
    fi
    if [[ -z "$rule" ]]; then
        local listen
        listen=$(get_listen)
        if [[ "$listen" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            rule="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}/udp"
        elif [[ "$listen" =~ ^[0-9]+$ ]]; then
            rule="${listen}/udp"
        fi
    fi

    if [[ -n "$rule" ]]; then
        # 1. 精准清理 UFW 规则
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw delete allow "$rule" comment 'buds-hy2' >/dev/null 2>&1 || ufw delete allow "$rule" >/dev/null 2>&1 || true
        fi

        # 2. 精准清理 firewalld 规则
        if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
            local fw_port="${rule%/*}"
            local fw_proto="${rule#*/}"
            fw_port="${fw_port//:/-}"
            firewall-cmd --permanent --remove-port="${fw_port}/${fw_proto}" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        fi

        # 3. 精准清理 iptables 规则
        if command -v iptables >/dev/null 2>&1; then
            local port_spec="${rule%/*}"
            iptables -D INPUT -p udp --dport "$port_spec" -m comment --comment "buds-hy2" -j ACCEPT >/dev/null 2>&1 || iptables -D INPUT -p udp --dport "$port_spec" -j ACCEPT >/dev/null 2>&1 || true
        fi
    fi
}

uninstall() {
    echo -e "\n  ${C_RED}⚠ 警告: 即将卸载 Hysteria 2 服务！${C_RESET}"
    read -rp "  确认彻底卸载吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        systemctl disable --now hysteria-server 2>/dev/null || true
        cleanup_firewall
        rm -f /usr/local/bin/hysteria /usr/local/bin/buds /usr/local/bin/hy2
        rm -rf /etc/hysteria /etc/systemd/system/hysteria-server.service.d
        rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service
        rm -f /etc/letsencrypt/renewal-hooks/deploy/hysteria-sync.sh
        rm -f /etc/sysctl.d/99-hysteria-performance.conf
        systemctl daemon-reload
        echo -e "\n  ${C_BAR}  ${C_GREEN}✔ Hysteria 2 服务及防火墙规则已安全卸载，原有 Nginx 及网站保持原样。${C_RESET}\n"
    else
        echo -e "\n  已取消卸载。\n"
    fi
}

show_menu() {
    while true; do
        local status_badge domain listen
        if systemctl is-active --quiet hysteria-server 2>/dev/null; then
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
    install_dependencies
    collect_parameters
    setup_certificates
    install_official_core
    generate_server_config
    tune_kernel_network
    configure_systemd_override
    configure_firewall
    start_service
    setup_cli
    display_summary
}

main "$@"
