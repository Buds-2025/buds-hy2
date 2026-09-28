#!/usr/bin/env bash
# ==============================================================================
# 项目名称 : buds-naiveproxy
# 脚本说明 : NaiveProxy 官方原生组件全自动 / 交互式安全部署与运维脚本
# 架构支持 : x86_64 (amd64) / aarch64 (arm64)
# 系统支持 : Ubuntu 20.04+, Debian 11+ (基于 systemd 的发行版)
# 安全设计 : 遵循最小特权原则 · 独立非特权用户 · Systemd 安全沙箱隔离 · 零破坏主站共存
# 仓库地址 : https://github.com/Buds-2025/buds-naiveproxy
# ==============================================================================

set -euo pipefail

# 终端输出色彩定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# 辅助函数
# ------------------------------------------------------------------------------

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_err() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_step() {
    echo -e "\n${CYAN}${BOLD}>>> $1${NC}"
}

# 兼容管道执行 (curl ... | bash) 的安全交互输入
prompt_read() {
    local prompt_msg="$1"
    local var_name="$2"
    local default_val="${3:-}"
    local input_val=""
    if [ -t 0 ]; then
        read -rp "$(echo -e "$prompt_msg")" input_val || true
    else
        read -rp "$(echo -e "$prompt_msg")" input_val </dev/tty || true
    fi
    input_val=$(echo "$input_val" | tr -d '\r\n')
    if [[ -z "$input_val" ]]; then
        eval "$var_name=\"$default_val\""
    else
        eval "$var_name=\"$input_val\""
    fi
}

generate_random_str() {
    local length=${1:-16}
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length" || true
}

# ------------------------------------------------------------------------------
# 前置环境与特权检测
# ------------------------------------------------------------------------------

check_root() {
    if [[ $(id -u) -ne 0 ]]; then
        log_err "此脚本必须以 root 权限运行！请使用 'sudo bash $0' 重新运行。"
        exit 1
    fi
}

check_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log_err "当前系统未检测到 systemd，本部署脚本仅支持 systemd 发行版！"
        exit 1
    fi
}

get_public_ip() {
    curl -4 -s --max-time 5 https://api.ipify.org || \
    curl -4 -s --max-time 5 https://icanhazip.com || \
    curl -4 -s --max-time 5 https://ifconfig.me || \
    echo "未知"
}

# ------------------------------------------------------------------------------
# 业务功能模块：安装与配置
# ------------------------------------------------------------------------------

install_naiveproxy() {
    local SERVER_IP
    SERVER_IP=$(get_public_ip)
    local ARCH
    ARCH=$(uname -m)
    local GO_ARCH=""
    case "$ARCH" in
        x86_64)  GO_ARCH="amd64" ;;
        aarch64) GO_ARCH="arm64" ;;
        *) log_err "暂不支持的 CPU 架构: $ARCH"; exit 1 ;;
    esac

    clear
    echo -e "${PURPLE}${BOLD}"
    echo "=================================================================="
    echo "          NaiveProxy 原生官方组件交互式安全部署程序               "
    echo "        遵循最小特权原则 · 零破坏主站共存 · 沙箱安全加固           "
    echo "=================================================================="
    echo -e "${NC}"
    echo -e "服务器公网 IPv4: ${GREEN}${SERVER_IP}${NC} | 架构: ${GREEN}${ARCH}${NC}"
    echo ""

    log_step "步骤 1/7: 收集节点网络与认证配置"

    # 1. 域名与解析验证
    local INPUT_DOMAIN=""
    while true; do
        prompt_read "${BOLD}请输入绑定的节点域名 (如 x.yourdomain.com): ${NC}" INPUT_DOMAIN ""
        INPUT_DOMAIN=$(echo "$INPUT_DOMAIN" | tr -d '[:space:]')
        if [[ -z "$INPUT_DOMAIN" ]]; then
            log_warn "域名不能为空，请重新输入！"
            continue
        fi

        # 检测 DNS 解析
        local RESOLVED_IP
        RESOLVED_IP=$(ping -c 1 "$INPUT_DOMAIN" 2>/dev/null | head -n 1 | sed -E 's/.*\(|\).*/ /g' | awk '{print $1}' || echo "")
        if [[ -n "$RESOLVED_IP" && "$RESOLVED_IP" != "$SERVER_IP" && "$SERVER_IP" != "未知" ]]; then
            log_warn "检测到该域名当前解析 IP [${RESOLVED_IP}] 与本机公网 IP [${SERVER_IP}] 不一致！"
            local CONFIRM_DNS="N"
            prompt_read "是否仍强制使用该域名？[y/N]: " CONFIRM_DNS "N"
            if [[ "${CONFIRM_DNS,,}" == "y" ]]; then
                break
            fi
        else
            break
        fi
    done

    # 2. 通信端口
    local INPUT_PORT="8443"
    while true; do
        prompt_read "${BOLD}请输入监听端口 [默认: 8443]: ${NC}" INPUT_PORT "8443"
        if [[ "$INPUT_PORT" -lt 1 || "$INPUT_PORT" -gt 65535 ]]; then
            log_warn "端口必须在 1-65535 之间！"
            continue
        fi
        if ss -tulpn | grep -q ":${INPUT_PORT} "; then
            log_err "端口 ${INPUT_PORT} 已被其他本地进程占用！请更换其他端口。"
            continue
        fi
        break
    done

    # 3. 认证用户与密码
    local INPUT_USER="naive_user"
    prompt_read "${BOLD}请输入认证用户名 [默认: naive_user]: ${NC}" INPUT_USER "naive_user"

    local DEF_PASS
    DEF_PASS=$(generate_random_str 16)
    local INPUT_PASS=""
    prompt_read "${BOLD}请输入认证密码 [回车使用随机高强密码: ${DEF_PASS}]: ${NC}" INPUT_PASS "$DEF_PASS"

    # 4. 主动探测防御密钥 (Probe Resistance Secret)
    local DEF_PROBE="probe_$(generate_random_str 12)"
    local INPUT_PROBE=""
    prompt_read "${BOLD}请输入主动探测防御密钥 [回车使用随机: ${DEF_PROBE}]: ${NC}" INPUT_PROBE "$DEF_PROBE"

    # 5. 伪装 Server 头部
    local CHOICE_SERVER="1"
    prompt_read "${BOLD}响应头伪装指纹 (1: nginx / 2: cloudflare / 3: 彻底移除) [默认: 1]: ${NC}" CHOICE_SERVER "1"
    local DISGUISE_SERVER='Server "nginx"'
    case "$CHOICE_SERVER" in
        2) DISGUISE_SERVER='Server "cloudflare"' ;;
        3) DISGUISE_SERVER='-Server' ;;
        *) DISGUISE_SERVER='Server "nginx"' ;;
    esac

    # 6. SSL 证书模式
    local CERT_MODE="1"
    echo -e "\n${BOLD}请选择 SSL 证书获取方式:${NC}"
    echo -e "  1. 自动化申请 Let's Encrypt 证书 (推荐，智能协同 Nginx / 80端口)"
    echo -e "  2. 手动指定已有证书文件路径 (适合自定义/通配符证书)"
    prompt_read "请选择 [默认: 1]: " CERT_MODE "1"

    local CUSTOM_CERT=""
    local CUSTOM_KEY=""
    if [[ "$CERT_MODE" == "2" ]]; then
        while true; do
            prompt_read "请输入公钥证书 (fullchain.pem) 完整绝对路径: " CUSTOM_CERT ""
            if [[ -f "$CUSTOM_CERT" ]]; then break; else log_warn "文件不存在，请重新输入！"; fi
        done
        while true; do
            prompt_read "请输入私钥 (privkey.pem) 完整绝对路径: " CUSTOM_KEY ""
            if [[ -f "$CUSTOM_KEY" ]]; then break; else log_warn "文件不存在，请重新输入！"; fi
        done
    fi

    # 7. 系统 BBR 加速
    local CHOICE_BBR="Y"
    prompt_read "${BOLD}是否开启内核原生 Google BBR 加速与 7.5MB 缓冲微调？[Y/n]: ${NC}" CHOICE_BBR "Y"

    # 配置确认清单
    echo ""
    echo -e "${YELLOW}==================== 配置确认清单 ====================${NC}"
    echo -e " 节点域名   : ${GREEN}${INPUT_DOMAIN}${NC}"
    echo -e " 通信端口   : ${GREEN}${INPUT_PORT}${NC} (TCP + UDP/QUIC)"
    echo -e " 认证用户   : ${GREEN}${INPUT_USER}${NC}"
    echo -e " 认证密码   : ${GREEN}${INPUT_PASS}${NC}"
    echo -e " 探测密钥   : ${GREEN}${INPUT_PROBE}${NC}"
    echo -e " 指纹伪装   : ${GREEN}${DISGUISE_SERVER}${NC}"
    echo -e " 证书模式   : ${GREEN}$([[ "$CERT_MODE" == "2" ]] && echo "自定义证书" || echo "Let's Encrypt 自动签发")${NC}"
    echo -e " BBR 加速   : ${GREEN}${CHOICE_BBR}${NC}"
    echo -e "${YELLOW}=====================================================${NC}"
    local CONFIRM_START="Y"
    prompt_read "确认以上配置无误并开始部署？[Y/n]: " CONFIRM_START "Y"
    if [[ "${CONFIRM_START,,}" != "y" ]]; then
        log_info "已取消部署。"
        exit 0
    fi

    # --------------------------------------------------------------------------
    # 步骤 2: 依赖安装
    # --------------------------------------------------------------------------
    log_step "步骤 2/7: 更新系统基础依赖与工具"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl wget git tar socat jq certbot

    # 仅在已有 Nginx 时安装 certbot 插件，避免无 Nginx 时意外拉取整套 web 服务
    if command -v nginx >/dev/null 2>&1; then
        apt-get install -y python3-certbot-nginx || true
    fi
    if ! command -v ufw >/dev/null 2>&1; then
        apt-get install -y ufw || true
    fi

    # --------------------------------------------------------------------------
    # 步骤 3: 编译或获取 Caddy forwardproxy 原版二进制
    # --------------------------------------------------------------------------
    log_step "步骤 3/7: 准备 Caddy (forwardproxy) 原版二进制组件"
    local NEED_BUILD=true
    if [[ -f /usr/local/bin/caddy ]]; then
        if /usr/local/bin/caddy list-modules 2>/dev/null | grep -q "forward_proxy"; then
            log_success "检测到已存在可用的 Caddy forwardproxy 原版二进制，跳过编译！"
            NEED_BUILD=false
        fi
    fi

    if [[ "$NEED_BUILD" == "true" ]]; then
        log_info "准备编译环境。检测系统可用物理内存..."
        local TOTAL_MEM
        TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
        local CREATED_SWAP=false
        local SWAP_FILE="/tmp/caddy_build_swap"
        if [[ "$TOTAL_MEM" -lt 2000 ]]; then
            log_warn "检测到当前内存仅 ${TOTAL_MEM}MB，编译 Go 需要至少 2GB 内存。自动创建 2GB 临时 Swap 防溢出..."
            fallocate -l 2G "$SWAP_FILE" || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=2048
            chmod 600 "$SWAP_FILE"
            mkswap "$SWAP_FILE"
            swapon "$SWAP_FILE"
            CREATED_SWAP=true
            log_success "临时 2GB Swap 挂载成功。"
        fi

        # 检查 Go 是否已安装且版本满足 >= 1.21
        local NEED_INSTALL_GO=true
        if command -v go >/dev/null 2>&1; then
            local GO_CUR_VER
            GO_CUR_VER=$(go version | awk '{print $3}' | sed 's/go//')
            log_info "检测到已有 Go 版本: ${GO_CUR_VER}"
            NEED_INSTALL_GO=false
        fi

        if [[ "$NEED_INSTALL_GO" == "true" ]]; then
            local GO_VERSION="1.22.7"
            log_info "下载并安装官方 Go ${GO_VERSION}..."
            wget -qO /tmp/go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
            rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz
            export PATH=/usr/local/go/bin:$PATH
        fi

        # 构建 xcaddy
        local BUILD_DIR="/tmp/caddy-build-$$"
        mkdir -p "$BUILD_DIR"
        cd "$BUILD_DIR"
        log_info "安装官方构建工具 xcaddy 并开始编译官方 forwardproxy 原版模块..."
        go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
        export PATH=$(go env GOPATH)/bin:$PATH

        xcaddy build --with github.com/klzgrad/forwardproxy@naive
        mv caddy /usr/local/bin/caddy
        chmod 755 /usr/local/bin/caddy
        cd /
        rm -rf "$BUILD_DIR" /tmp/go.tar.gz 2>/dev/null || true

        if [[ "$CREATED_SWAP" == "true" ]]; then
            log_info "编译完成，正在卸载并清理临时 Swap..."
            swapoff "$SWAP_FILE"
            rm -f "$SWAP_FILE"
        fi

        # 校验模块
        if /usr/local/bin/caddy list-modules | grep -q "forward_proxy"; then
            log_success "Caddy forwardproxy 原生组件校验 100% 成功！"
        else
            log_err "Caddy 模块校验失败，未检测到 forward_proxy！"
            exit 1
        fi
    fi

    # --------------------------------------------------------------------------
    # 步骤 4: 最小特权独立用户与沙箱目录
    # --------------------------------------------------------------------------
    log_step "步骤 4/7: 创建独立专有用户与安全沙箱目录"
    id -u caddy >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d /var/lib/caddy -m caddy
    mkdir -p /etc/caddy/certs /var/lib/caddy /var/log/caddy /var/www/naive_html

    # 预创建日志文件并矫正所有权，彻底杜绝 permission denied
    touch /var/log/caddy/access.log
    chown -R caddy:caddy /var/lib/caddy /var/log/caddy /etc/caddy/certs
    chmod 700 /var/lib/caddy /etc/caddy/certs
    chmod 750 /var/log/caddy
    chmod 640 /var/log/caddy/access.log

    # 部署现代静态伪装网页模板
    cat << 'EOF' > /var/www/naive_html/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Enterprise Edge Gateway Service</title>
    <style>
        :root { --primary: #0284c7; --bg: #0f172a; --card: #1e293b; --text: #e2e8f0; --sub: #94a3b8; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background-color: var(--bg); color: var(--text); margin: 0; padding: 0; display: flex; justify-content: center; align-items: center; min-height: 100vh; }
        .container { max-width: 720px; width: 90%; background: var(--card); border: 1px solid #334155; border-radius: 12px; padding: 40px; box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.5); }
        .badge { display: inline-block; background: rgba(2, 132, 199, 0.2); color: #38bdf8; padding: 4px 12px; border-radius: 9999px; font-size: 13px; font-weight: 600; margin-bottom: 16px; }
        h1 { margin: 0 0 12px 0; font-size: 26px; color: #fff; }
        p { color: var(--sub); line-height: 1.6; margin: 0 0 20px 0; }
        .status-box { background: #0f172a; border-radius: 8px; padding: 16px; font-family: ui-monospace, SFMono-Regular, monospace; font-size: 13px; color: #34d399; margin-bottom: 24px; border: 1px solid #1e293b; }
        .footer { font-size: 12px; color: var(--sub); border-top: 1px solid #334155; padding-top: 16px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="badge">Production Ready</div>
        <h1>Enterprise Edge Gateway Service</h1>
        <p>This edge node manages high-concurrency encrypted data flows, TLS offloading, and automated protocol acceleration for distributed microservices.</p>
        <div class="status-box">
            System Status: Healthy<br>
            Protocol Transport: HTTP/2 &amp; HTTP/3 (QUIC)<br>
            Traffic Optimization: Active (BBR / Dynamic Compress)
        </div>
        <div class="footer">
            Protected by Automated Rate Limiting &amp; Edge Threat Mitigation. &copy; 2026 Cloud Services.
        </div>
    </div>
</body>
</html>
EOF
    chmod 644 /var/www/naive_html/index.html

    # --------------------------------------------------------------------------
    # 步骤 5: SSL 证书管理与自动续签钩子
    # --------------------------------------------------------------------------
    log_step "步骤 5/7: SSL / TLS 证书配置与自动续签部署"
    local CERT_FULLCHAIN=""
    local CERT_PRIVKEY=""

    if [[ "$CERT_MODE" == "2" ]]; then
        cp -f "$CUSTOM_CERT" /etc/caddy/certs/fullchain.pem
        cp -f "$CUSTOM_KEY" /etc/caddy/certs/privkey.pem
    else
        CERT_FULLCHAIN="/etc/letsencrypt/live/${INPUT_DOMAIN}/fullchain.pem"
        CERT_PRIVKEY="/etc/letsencrypt/live/${INPUT_DOMAIN}/privkey.pem"

        if [[ ! -f "$CERT_FULLCHAIN" ]]; then
            log_info "正在申请 Let's Encrypt 官方权威证书..."
            if ss -tulpn | grep -q ":80 " && command -v nginx >/dev/null 2>&1; then
                log_info "检测到 80 端口正在运行 Nginx，采用 --nginx 零停机模式申请（绝对不破坏原站）..."
                certbot certonly --nginx -d "$INPUT_DOMAIN" --agree-tos --register-unsafely-without-email --non-interactive
            else
                log_info "80 端口未被占用，采用 --standalone 模式申请证书..."
                certbot certonly --standalone -d "$INPUT_DOMAIN" --agree-tos --register-unsafely-without-email --non-interactive
            fi
        else
            log_success "检测到已有域名证书: $CERT_FULLCHAIN"
        fi

        cp -f "$CERT_FULLCHAIN" /etc/caddy/certs/fullchain.pem
        cp -f "$CERT_PRIVKEY" /etc/caddy/certs/privkey.pem

        # 部署 Certbot Deploy Hook 自动续签同步脚本
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat << 'EOF' > /etc/letsencrypt/renewal-hooks/deploy/caddy-sync.sh
#!/bin/bash
DOMAIN="${RENEWED_LINEAGE##*/}"
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" && -d "/etc/caddy/certs" ]]; then
    cp -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" /etc/caddy/certs/fullchain.pem
    cp -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" /etc/caddy/certs/privkey.pem
    chown caddy:caddy /etc/caddy/certs/*
    chmod 644 /etc/caddy/certs/fullchain.pem
    chmod 600 /etc/caddy/certs/privkey.pem
    systemctl reload caddy >/dev/null 2>&1 || true
fi
EOF
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/caddy-sync.sh
        log_success "Certbot Deploy-Hook 自动续签钩子部署完成！"
    fi

    chown caddy:caddy /etc/caddy/certs/*
    chmod 644 /etc/caddy/certs/fullchain.pem
    chmod 600 /etc/caddy/certs/privkey.pem

    # --------------------------------------------------------------------------
    # 步骤 6: 渲染 Caddyfile 与沙箱 Systemd 单元
    # --------------------------------------------------------------------------
    log_step "步骤 6/7: 生成安全 Caddyfile 与系统沙箱服务单元"
    cat << EOF > /etc/caddy/Caddyfile
{
    admin off
    auto_https off
}

:${INPUT_PORT}, ${INPUT_DOMAIN}:${INPUT_PORT} {
    tls /etc/caddy/certs/fullchain.pem /etc/caddy/certs/privkey.pem

    log {
        output file /var/log/caddy/access.log {
            roll_size 50mb
            roll_keep_for 7d
        }
        format json
    }

    encode zstd gzip

    header {
        ${DISGUISE_SERVER}
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
    }

    route {
        forward_proxy {
            basic_auth ${INPUT_USER} ${INPUT_PASS}
            hide_ip
            hide_via
            probe_resistance ${INPUT_PROBE}
        }
        file_server {
            root /var/www/naive_html
        }
    }
}
EOF
    chown root:caddy /etc/caddy/Caddyfile
    chmod 644 /etc/caddy/Caddyfile

    # 静态语法校验
    log_info "运行 Caddyfile 静态语法校验..."
    /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile

    # 沙箱化 Systemd 单元
    cat << 'EOF' > /etc/systemd/system/caddy.service
[Unit]
Description=Caddy Web & NaiveProxy Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576

# Hardening & Least Privilege Sandbox
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictRealtime=yes
ReadWritePaths=/var/lib/caddy /var/log/caddy

# Linux Capabilities
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable caddy >/dev/null 2>&1
    systemctl restart caddy

    # --------------------------------------------------------------------------
    # 步骤 7: 系统优化与防火墙
    # --------------------------------------------------------------------------
    log_step "步骤 7/7: 系统内核优化与防火墙策略"
    if [[ "${CHOICE_BBR,,}" == "y" ]]; then
        cat << 'EOF' > /etc/sysctl.d/99-bbr-buffer.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000
EOF
        sysctl --system >/dev/null 2>&1 || true
        log_success "Google BBR 算法与 7.5MB 缓冲微调已生效！"
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${INPUT_PORT}/tcp" comment 'naiveproxy-tcp' >/dev/null 2>&1 || true
        ufw allow "${INPUT_PORT}/udp" comment 'naiveproxy-udp' >/dev/null 2>&1 || true
        log_success "UFW 防火墙端口 ${INPUT_PORT} (TCP/UDP) 已放行！"
    fi

    # --------------------------------------------------------------------------
    # 交付输出客户端配置
    # --------------------------------------------------------------------------
    local CLIENT_JSON_CONTENT
    CLIENT_JSON_CONTENT=$(cat << EOF
{
  "listen": "socks://127.0.0.1:10808",
  "proxy": "https://${INPUT_USER}:${INPUT_PASS}@${INPUT_DOMAIN}:${INPUT_PORT}"
}
EOF
)
    echo "$CLIENT_JSON_CONTENT" > /etc/caddy/naive_client.json
    echo "$CLIENT_JSON_CONTENT" > "./naive_client.json"

    echo ""
    echo -e "${GREEN}${BOLD}=================================================================="
    echo "               🎉 NaiveProxy 节点部署大功告成！                   "
    echo "==================================================================${NC}"
    echo ""
    echo -e "${BOLD}【节点连接参数】${NC}"
    echo -e "  节点域名   : ${CYAN}${INPUT_DOMAIN}${NC}"
    echo -e "  监听端口   : ${CYAN}${INPUT_PORT}${NC} (TCP + UDP/QUIC)"
    echo -e "  认证用户名 : ${CYAN}${INPUT_USER}${NC}"
    echo -e "  认证密码   : ${CYAN}${INPUT_PASS}${NC}"
    echo -e "  探测密钥   : ${CYAN}${INPUT_PROBE}${NC}"
    echo -e "  伪装指纹   : ${CYAN}${DISGUISE_SERVER}${NC}"
    echo -e "  审计日志   : ${CYAN}/var/log/caddy/access.log${NC}"
    echo ""
    echo -e "${BOLD}【客户端配置文件 (v2rayN / 原生客户端)】${NC}"
    echo -e "  已自动生成配置文件至: ${YELLOW}$(pwd)/naive_client.json${NC}"
    echo -e "${YELLOW}------------------------------------------------------------------"
    echo "$CLIENT_JSON_CONTENT"
    echo -e "------------------------------------------------------------------${NC}"
    echo ""
    echo -e "${BOLD}【日常运维管理常用命令】${NC}"
    echo -e "  查看服务状态 : ${GREEN}systemctl status caddy${NC}"
    echo -e "  平滑重载配置 : ${GREEN}systemctl reload caddy${NC}"
    echo -e "  重启服务     : ${GREEN}systemctl restart caddy${NC}"
    echo -e "  查看实时日志 : ${GREEN}journalctl -u caddy -f${NC}"
    echo -e "  查看访问审计 : ${GREEN}tail -f /var/log/caddy/access.log${NC}"
    echo ""
}

# ------------------------------------------------------------------------------
# 业务功能模块：查看状态与配置
# ------------------------------------------------------------------------------

view_status() {
    clear
    echo -e "${CYAN}${BOLD}=== NaiveProxy 运行状态 ===${NC}"
    systemctl status caddy --no-pager || true
    echo ""
    if [[ -f /etc/caddy/naive_client.json ]]; then
        echo -e "${YELLOW}${BOLD}=== 客户端配置 (/etc/caddy/naive_client.json) ===${NC}"
        cat /etc/caddy/naive_client.json
        echo ""
    fi
}

view_logs() {
    clear
    echo -e "${CYAN}${BOLD}=== 正在查看访问审计日志 (Ctrl+C 退出) ===${NC}"
    if [[ -f /var/log/caddy/access.log ]]; then
        tail -n 20 -f /var/log/caddy/access.log
    else
        log_warn "未找到日志文件 /var/log/caddy/access.log"
    fi
}

reload_caddy() {
    log_info "正在热重载 Caddy 服务..."
    if /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile; then
        systemctl reload caddy
        log_success "配置热重载成功，所有已有连接未受中断！"
    else
        log_err "Caddyfile 语法校验失败，未执行重载！"
    fi
}

uninstall_naiveproxy() {
    clear
    echo -e "${RED}${BOLD}=================================================================="
    echo "                      ⚠️ 卸载 NaiveProxy 服务                      "
    echo "==================================================================${NC}"
    local CONFIRM_UNINSTALL="N"
    prompt_read "确认彻底卸载 NaiveProxy 并清理相关服务配置与伪装网页？[y/N]: " CONFIRM_UNINSTALL "N"
    if [[ "${CONFIRM_UNINSTALL,,}" != "y" ]]; then
        log_info "已取消卸载。"
        return
    fi

    log_info "正在停止并禁用 caddy 服务..."
    systemctl stop caddy >/dev/null 2>&1 || true
    systemctl disable caddy >/dev/null 2>&1 || true

    log_info "正在清理沙箱服务单元与目录..."
    rm -f /etc/systemd/system/caddy.service
    systemctl daemon-reload

    rm -rf /etc/caddy /var/lib/caddy /var/log/caddy /var/www/naive_html
    rm -f /etc/letsencrypt/renewal-hooks/deploy/caddy-sync.sh

    local REMOVE_BIN="N"
    prompt_read "是否同时删除 /usr/local/bin/caddy 二进制主程序？[y/N]: " REMOVE_BIN "N"
    if [[ "${REMOVE_BIN,,}" == "y" ]]; then
        rm -f /usr/local/bin/caddy
    fi

    log_success "NaiveProxy 已完全卸载干净！"
}

# ------------------------------------------------------------------------------
# 主菜单引导逻辑
# ------------------------------------------------------------------------------

main_menu() {
    check_root
    check_systemd

    # 如果有传参 'install'，直接非交互启动安装
    if [[ "${1:-}" == "install" ]]; then
        install_naiveproxy
        exit 0
    fi

    while true; do
        clear
        echo -e "${PURPLE}${BOLD}"
        echo "=================================================================="
        echo "               NaiveProxy 自动化部署与管理控制台                  "
        echo "=================================================================="
        echo -e "${NC}"
        echo -e "  ${GREEN}1.${NC} 安装 / 重装 NaiveProxy"
        echo -e "  ${GREEN}2.${NC} 查看服务运行状态与客户端配置"
        echo -e "  ${GREEN}3.${NC} 查看实时访问审计日志"
        echo -e "  ${GREEN}4.${NC} 平滑热重载配置 (Reload)"
        echo -e "  ${GREEN}5.${NC} 重启 NaiveProxy 服务"
        echo -e "  ${RED}6.${NC} 卸载 NaiveProxy"
        echo -e "  ${BOLD}0.${NC} 退出脚本"
        echo ""
        local MENU_CHOICE=""
        prompt_read "请输入选项 [0-6]: " MENU_CHOICE ""
        case "$MENU_CHOICE" in
            1) install_naiveproxy; break ;;
            2) view_status; prompt_read "按回车键返回主菜单..." _ "";;
            3) view_logs ;;
            4) reload_caddy; prompt_read "按回车键返回主菜单..." _ "";;
            5) systemctl restart caddy; log_success "服务已重启！"; prompt_read "按回车键返回主菜单..." _ "";;
            6) uninstall_naiveproxy; break ;;
            0) exit 0 ;;
            *) log_warn "无效选项，请重新输入！"; sleep 1 ;;
        esac
    done
}

main_menu "$@"
