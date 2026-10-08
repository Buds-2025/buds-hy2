# buds-hy2

面向主流Linux发行版的Hysteria 2自动化部署与运维管理脚本。

提供Debian、Ubuntu、Alpine、CentOS、Rocky、Alma、Fedora和Arch的依赖安装分支，以及systemd、OpenRC和精简容器的服务管理分支。支持标准VPS与NAT端口映射，提供Let's Encrypt证书和免80端口的ECC自签名证书。实际可用性取决于系统权限、UDP映射及客户端支持；运行脚本需要Bash和root权限。

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
   - **ECC自签名证书**：不依赖80端口，自动导出SHA-256证书指纹，适用于支持指纹验证的客户端；
5. **内核与服务管理**：从官方来源确定版本并校验SHA-256后安装内核；systemd/OpenRC提供进程守护，精简容器提供启动、停止和状态检查。

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

在支持Hysteria 2的客户端中导入脚本输出的`hysteria2://`链接。自签名模式要求客户端识别并实际使用`pinSHA256`；当前v2rayN支持该导入字段，其他客户端及转换工具需确认其支持情况。原生Hysteria客户端可直接使用`buds hy2 client`输出的YAML。若客户端不支持指纹验证，请使用可信CA证书。

如需提升传输效率，可在客户端节点设置中填入与本地网络相符的上传与下载带宽数值。

可信CA证书的链接和YAML保留正常证书验证；自签名证书跳过CA链验证，同时固定完整证书的SHA-256指纹以核验服务端身份。重新安装会生成新的自签名证书，需要重新导入连接配置。

Let's Encrypt模式会复用并启用已有续签定时器或cron任务，缺失时自动补建。无init容器需要保持cron进程运行；自签名模式不创建续签任务。卸载会清除本项目创建的定时任务和`rc.local`启动行，保留其他服务的任务。

必需依赖缺失会明确停止安装，Certbot缺失仍允许使用自签名模式。Arch分支使用现有软件库索引安装依赖，不刷新索引后进行部分升级，也不自动升级整台服务器。

开发验证：`python scripts/test_regressions.py`执行隔离回归测试（需Python 3和Bash），`python scripts/sync_cli.py --check`检查CLI与安装器内嵌版本的一致性。测试使用临时文件和系统命令替身，不执行真实安装。
