# buds-hy2

全平台通用、高鲁棒性的 Hysteria 2 自动化部署与运维管理脚本。

原生适配主流 Linux 发行版（Debian / Ubuntu / Alpine / CentOS / Rocky / Alma / Fedora / Arch），全面支持标准 VPS、NAT VPS 及 LXD / LXC / Docker 等虚拟化容器环境。支持与现有网站零停机共存，兼备 Let's Encrypt 权威证书与免 80 端口的极速 ECC 自签名证书。

---

## 快速安装

在服务器终端（root 权限）执行以下一键安装命令（自带防 CDN 缓存参数）：

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/Buds-2025/buds-hy2/main/install.sh?v=$(date +%s)")
```

脚本将智能引导完成：
1. **环境与网络检测**：自动识别容器虚拟化（LXD/LXC/Docker）与 NAT 内网环境；
2. **域名解析校验**：多源比对本机公网 IP 与域名解析记录；
3. **灵活端口配置**：支持随机高位单端口、指定单端口或端口跳跃范围（如 `20000-40000`）；
4. **智能双模证书**：
   - **Let's Encrypt 权威证书**：适合独立公网 IP 机器，支持 Nginx 零停机平滑签发；
   - **极速 ECC 自签名证书**：免除 80 端口依赖，专为 NAT VPS / LXD 容器定制，客户端免维护无缝直连；
5. **内核与服务自愈**：内核 UDP 缓冲区智能调优，守护进程崩溃自愈与全局管理工具安装。

---

## 运维管理

安装完成后，在终端输入 `buds hy2` 即可打开交互式管理面板：

```bash
buds hy2
```

同时也支持直接运行常见子命令（兼容 `buds hy2 <命令>` 与 `hy2 <命令>`）：

```bash
buds hy2 status      # 查看服务运行状态与监听端口
buds hy2 link        # 显示节点连接信息与导入链接
buds hy2 log         # 查看实时运行日志
buds hy2 restart     # 重启服务
buds hy2 stop        # 停止服务
buds hy2 start       # 启动服务
buds hy2 client      # 输出客户端 YAML 配置文件
buds hy2 renew-test  # 模拟测试证书自动续签逻辑
buds hy2 uninstall   # 安全卸载服务
```

---

## 客户端连接

在 v2rayN、Clash Verge 等客户端中复制脚本输出的 `hysteria2://` 链接并导入（快捷键 `Ctrl + V`）。

如需提升传输效率，可在客户端节点设置中填入与本地网络相符的上传与下载带宽数值。
