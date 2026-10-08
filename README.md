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
3. **灵活端口配置**：支持随机高位单端口、指定单端口或端口跳跃范围（如 `20000-40000`）；NAT/容器环境可另填公网UDP端口，默认与本机监听端口相同；
4. **智能双模证书**：
   - **Let's Encrypt 权威证书**：适合独立公网 IP 机器，优先使用 Nginx 插件或网站目录验证；失败时自动回退自签名，不停止现有网站；
   - **极速 ECC 自签名证书**：免除 80 端口依赖，专为 NAT VPS / LXD 容器定制，客户端免维护无缝直连；
5. **内核与服务自愈**：内核 UDP 缓冲区智能调优，守护进程崩溃自愈与全局管理工具安装。

已安装节点再次执行安装命令时，将直接打开管理菜单，保留现有域名、端口和密码。卸载成功后再次执行则按全新安装处理。

NAT端口填写示例：服务商映射为`公网19957 → 本机24443/UDP`时，监听端口填`24443`，公网连接端口填`19957`。域名解析到公网IP，服务商须提供UDP映射。

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

可信CA证书的链接和YAML启用证书验证；自签名证书的两种导出方式统一跳过CA验证。

开发验证：`python scripts/test_regressions.py`执行隔离回归测试（需Python 3和Bash），`python scripts/sync_cli.py --check`检查CLI与安装器内嵌版本的一致性。测试使用临时文件和系统命令替身，不执行真实安装。
