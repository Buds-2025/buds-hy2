# buds-hy2

面向主流Linux发行版的Hysteria 2自动化部署与运维管理脚本。

提供Debian、Ubuntu、Alpine、CentOS、Rocky、Alma、Fedora和Arch的依赖安装分支，以及systemd、OpenRC和精简容器的服务管理分支。支持标准VPS与NAT端口映射，提供Let's Encrypt证书和免80端口的ECC自签名证书。实际可用性取决于系统权限、UDP映射及客户端支持；运行脚本需要Bash和root权限。

---

## 快速安装

从发布页取得 `update.pub`（PEM 格式），用 `openssl pkey -pubin -in update.pub -outform DER | openssl dgst -sha256` 计算公钥指纹，并与维护者通过独立可信渠道提供的指纹核对。核对后以 root 身份安装公钥：

```bash
install -d -m 0755 -o root -g root /etc/buds-hy2
install -m 0644 -o root -g root update.pub /etc/buds-hy2/update.pub
```

从[项目 Releases](https://github.com/Buds-2025/buds-hy2/releases)选择已签名的版本。将下方版本号换为所选版本，验签成功后运行安装器：

```bash
(
  set -e
  version=v1.3.1
  base="https://github.com/Buds-2025/buds-hy2/releases/download/$version"
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' EXIT
  curl -q -fsSL --proto '=https' --proto-redir '=https' "$base/install.sh" -o "$work/install.sh"
  curl -q -fsSL --proto '=https' --proto-redir '=https' "$base/install.sh.sig" -o "$work/install.sh.sig"
  openssl dgst -sha256 -verify /etc/buds-hy2/update.pub -signature "$work/install.sh.sig" "$work/install.sh"
  test "$(grep -m 1 '^SCRIPT_VERSION=' "$work/install.sh")" = "SCRIPT_VERSION=\"${version#v}\""
  bash "$work/install.sh"
)
```

若已从可信渠道取得完整源码包，可在解包目录中以 root 身份运行 `bash install.sh`。

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
buds hy2 client      # 输出客户端配置（原生 YAML、sing-box JSON 与 Mihomo YAML）
buds hy2 update      # 检查并更新管理脚本至最新版本
buds hy2 renew-test  # 模拟测试证书自动续签逻辑
buds hy2 uninstall   # 安全卸载服务
```

管理面板从 GitHub Release 检查版本。更新需要 `curl`、`openssl`、`flock` 和预先安装的可信公钥。只有版本匹配、签名有效且通过 Bash 语法检查的脚本才会替换现有 CLI。

### 从旧管理脚本迁移

先按上面的步骤安装可信公钥。选择已签名的版本，验签后在同一文件系统内替换管理脚本。此操作只更新 CLI，沿用已有节点配置和证书。

```bash
(
  set -e
  version=v1.3.1
  base="https://github.com/Buds-2025/buds-hy2/releases/download/$version"
  work=$(mktemp -d /usr/local/bin/.buds_upgrade.XXXXXX)
  trap 'rm -rf -- "$work"' EXIT
  curl -q -fsSL --proto '=https' --proto-redir '=https' "$base/buds" -o "$work/buds"
  curl -q -fsSL --proto '=https' --proto-redir '=https' "$base/buds.sig" -o "$work/buds.sig"
  openssl dgst -sha256 -verify /etc/buds-hy2/update.pub -signature "$work/buds.sig" "$work/buds"
  grep -Fx "SCRIPT_VERSION=\"${version#v}\"" "$work/buds"
  bash -n "$work/buds"
  chmod 755 "$work/buds"
  mv -f "$work/buds" /usr/local/bin/buds
  ln -sf /usr/local/bin/buds /usr/local/bin/hy2
)
```

**现有服务权限**也需要单独检查。安排维护窗口并备份服务定义。systemd 端口跳跃节点的 `CapabilityBoundingSet` 和 `AmbientCapabilities` 都应为 `CAP_NET_BIND_SERVICE CAP_NET_ADMIN`，单端口只需 `CAP_NET_BIND_SERVICE`。支持 `--capabilities` 的 OpenRC 可为专用服务账号设置 `capabilities="^cap_net_admin"`，单端口可以省略此项。旧版 OpenRC 的端口跳跃继续由 root 启动。确认服务定义后，用 `getcap /usr/local/bin/hysteria` 检查旧版留下的文件能力，有记录时执行 `setcap -r /usr/local/bin/hysteria`。重新加载服务配置并重启，验证端口连通性。

---

## 客户端连接

原生 Hysteria 客户端可将 `buds hy2 link` 输出的链接作为配置的 `server` 值。如果输出单独标出了原生链接，请选用该链接。自签名的原生链接同时包含 `insecure=1` 和 `pinSHA256`，须使用 Hysteria 2.6.4 或更新版本，以便只匹配服务端叶证书的指纹。端口跳跃范围写在原生链接的地址中。[Hysteria 2.6.4 版本说明](https://v2.hysteria.network/docs/Changelog/#264)

第三方链接的参数支持取决于应用和内核版本。导入自签名链接后须确认内核会强制验证指纹。可用 `buds hy2 client` 获取原生 Hysteria YAML、sing-box 1.14+ 出站 JSON（自签名时固定公钥）或支持 `fingerprint` 的 Mihomo 配置。客户端无法验证指纹时，应使用可信 CA 证书。

如需提升传输效率，可在客户端节点设置中填入与本地网络相符的上传与下载带宽数值。

可信CA证书的链接和YAML保留正常证书验证；自签名证书跳过CA链验证，同时固定完整证书的SHA-256指纹以核验服务端身份。重新安装会生成新的自签名证书，需要重新导入连接配置。

Let's Encrypt模式会复用并启用已有续签定时器或cron任务，缺失时自动补建。无init容器需要保持cron进程运行；自签名模式不创建续签任务。卸载会清除本项目创建的定时任务和`rc.local`启动行，保留其他服务的任务。

必需依赖缺失会明确停止安装，Certbot缺失仍允许使用自签名模式。Arch分支使用现有软件库索引安装依赖，不刷新索引后进行部分升级，也不自动升级整台服务器。

开发验证：`python scripts/test_regressions.py`执行隔离回归测试（需Python 3和Bash），`python scripts/sync_cli.py --check`检查CLI与安装器内嵌版本的一致性。测试使用临时文件和系统命令替身，不执行真实安装。

## 发布资产

使用独立保管的 RSA 或 ECDSA 私钥签署同步后的 `buds` 和 `install.sh`，并生成与两个脚本一致的版本文件：

```bash
version=1.3.1
printf '%s\n' "$version" > buds.version
openssl dgst -sha256 -sign /secure/path/update.key -out buds.sig buds
openssl dgst -sha256 -sign /secure/path/update.key -out install.sh.sig install.sh
```

在 GitHub Release `v$version` 下发布 `buds`、`buds.sig`、`buds.version`、`install.sh`、`install.sh.sig` 和 `update.pub`。每次发布使用新标签，公钥指纹通过独立可信渠道分发。
