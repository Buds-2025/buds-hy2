# buds-naiveproxy

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu%20%7C%20Debian-orange.svg)](#系统与架构支持)
[![Protocol](https://img.shields.io/badge/Protocol-HTTP%2F2%20%7C%20HTTP%2F3%20QUIC-success.svg)](#协议优势)

一个工业级、遵循**最小特权原则**（Least Privilege）与 **Systemd 严格沙箱隔离**的 NaiveProxy 官方原版组件自动化交互式部署与运维控制台。

---

## ⚡ 极速开始 (One-Line Quick Start)

在任意全新的 Ubuntu / Debian 服务器（或已有 Nginx 网站的服务器）上，以 root 权限执行以下单行命令即可启动交互式安装控制台：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Buds-2025/buds-naiveproxy/main/install.sh)
```

> [!TIP]
> 脚本支持通过管道免下载直接执行，内置完整的交互式控制台，支持安装、状态监控、客户端配置导出、实时日志审计与一键干净卸载。

---

## 🛡️ 核心安全与架构特性

1. **绝对零破坏共存（Zero-Conflict Architecture）**：
   - 自动检测 80/443 端口占用情况。若宿主机已有 Nginx（如个人博客、静态站），脚本自动走 `--nginx` 模式无缝申请 Let's Encrypt 证书；
   - 强制隔离全局 `auto_https off`，绝不擅自抢占或干扰 80/443 端口。
2. **最小特权沙箱隔离（Least Privilege Sandbox）**：
   - 自动创建独立的系统非特权专有用户 `caddy`（登录 Shell 设置为 `/usr/sbin/nologin`，彻底阻断 SSH 登录风险）；
   - Systemd 服务级硬化配置：开启 `ProtectSystem=strict`、`ProtectHome=yes`、`NoNewPrivileges=yes` 与 Linux Capability `CAP_NET_BIND_SERVICE` 精准赋权；
   - 证书文件权限收紧为 `600`（私钥）与 `644`（公钥），仅 `caddy` 自身可读。
3. **企业级指纹混淆与主动探测防御**：
   - 自动消除 Caddy 原生特征，将响应头伪装为 `Server: nginx` 或 `Server: cloudflare`；
   - 开启现代 Web 网关标配的 `encode zstd gzip` 传输压缩与 HSTS (`Strict-Transport-Security`, `nosniff`, `DENY`) 安全头；
   - 内置 `probe_resistance` 防御密钥机制，面对未授权主动嗅探与 GFW 扫描时，自动回源展示高逼真企业级边缘网关文档站。
4. **低内存编译自动防护（OOM Protection）**：
   - 检测到机器物理内存低于 2GB 时，自动调度 2GB 临时 Swap 虚拟内存，确保 Go 编译期间不会触发 Linux OOM Killer，编译完成后自动释放，即使 512MB / 1GB 小鸡也能丝滑搭建。
5. **内核级网络加速**：
   - 一键开启 Linux 官方 Google BBR 拥塞控制算法，结合 7.5MB `rmem_max`/`wmem_max` 核心网络缓冲区微调，晚高峰跨境吞吐量显著提升。
6. **全自动证书续期与平滑重载**：
   - 部署 Certbot Deploy-Hook 钩子脚本，每 60 天后台无感自动续期并执行 `systemctl reload caddy`，零停机、零断流。

---

## 💻 客户端接入指引 (Client Configuration)

安装完成后，脚本将在当前目录生成标准客户端配置文件 `naive_client.json`：

```json
{
  "listen": "socks://127.0.0.1:10808",
  "proxy": "https://username:password@your-domain.com:8443"
}
```

### 1. v2rayN 客户端
1. 前往 [NaiveProxy GitHub Releases](https://github.com/klzgrad/naiveproxy/releases) 下载适合您系统架构的客户端，解压得到 `naive.exe`，放入 v2rayN 根目录或 `v2rayN-Core` 文件夹中；
2. 在 v2rayN 界面点击 **服务器** -> **添加自定义配置服务器**；
3. Core 类型选择 **`naive`**，导入或粘贴上述 JSON 内容，Socks 监听端口填 `10808`；
4. 设为活动服务器即可连接。

### 2. 原生命令行客户端
```bash
./naive naive_client.json
```

---

## 🛠️ 管理控制台常用命令

除了再次运行 `bash <(curl ...)` 调出管理控制台外，您也可以直接使用 Linux 原生命令进行维护：

```bash
# 查看服务状态
systemctl status caddy

# 平滑热重载配置（修改配置后使用，不中断已有连接）
systemctl reload caddy

# 查看 Caddy 运行日志
journalctl -u caddy -f

# 查看 JSON 访问审计日志（监控扫描器探测）
tail -f /var/log/caddy/access.log

# 校验配置文件语法
/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile
```

---

## 📂 项目文件结构

```text
buds-naiveproxy/
├── .gitignore                 # Git 忽略规则（阻断敏感信息泄露）
├── README.md                  # 开源项目说明文档
├── install.sh                 # 核心自动化交互式安装与运维脚本
└── naive_config.example.json  # 客户端配置示例模板
```

---

## 📄 许可证

本项目基于 [MIT 许可证](LICENSE) 开源。
