# buds-hy2

面向主流Linux发行版的Hysteria 2自动化部署与运维管理脚本。

提供Debian、Ubuntu、Alpine、CentOS、Rocky、Alma、Fedora和Arch的依赖安装分支，以及systemd、OpenRC和精简容器的服务管理分支。支持标准VPS与NAT端口映射，提供Let's Encrypt证书和免80端口的ECC自签名证书。实际可用性取决于系统权限、UDP映射及客户端支持；运行脚本需要Bash和root权限。

---

## 快速安装

从 [updates 分支](https://github.com/Buds-2025/buds-hy2/tree/updates) 取得 `update.pub`（PEM 格式），用 `openssl pkey -pubin -in update.pub -outform DER | openssl dgst -sha256` 计算公钥指纹，并与维护者通过独立可信渠道提供的指纹核对。核对后以 root 身份安装公钥：

```bash
install -d -m 0755 -o root -g root /etc/buds-hy2
install -m 0644 -o root -g root update.pub /etc/buds-hy2/update.pub
```

从仓库更新分支的 `releases/` 目录选择版本。将下方版本号换为所选版本，验签成功后运行安装器：

```bash
(
  set -e
  version=1.7.4
  base="https://raw.githubusercontent.com/Buds-2025/buds-hy2/updates/releases/$version"
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' EXIT
  curl -q -fsSL --proto '=https' --proto-redir '=https' "$base/install.sh" -o "$work/install.sh"
  curl -q -fsSL --proto '=https' --proto-redir '=https' "$base/install.sh.sig" -o "$work/install.sh.sig"
  openssl dgst -sha256 -verify /etc/buds-hy2/update.pub -signature "$work/install.sh.sig" "$work/install.sh"
  test "$(grep -m 1 '^SCRIPT_VERSION=' "$work/install.sh")" = "SCRIPT_VERSION=\"$version\""
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

首页上方是 **A 节点管理**，下方是 **B WARP 分流管理**。两区所有操作均在首页预览。先输入 `A` 或 `B` 并回车，再输入该区编号。区内输入 `0` 返回首页，首页输入 `0` 退出，输入 `U` 更新脚本。

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

脚本更新从仓库 `updates` 分支读取签名版本清单，再按版本下载并验签脚本。更新需要 `curl`、`openssl`、`flock` 和可信公钥。v1.5.0 及更早版本需先按下文「从旧管理脚本迁移」进行一次验签迁移。

如果旧版导出的 `client.yaml` 把服务器地址拆成两行，运行 `buds hy2 client` 即可修复。脚本会沿用原公网端口，从服务端配置补回空缺的认证和混淆密码，并保留客户端的带宽和本地监听设置。

### 新增和管理多个节点

在已安装主节点的 systemd 服务器上，打开 `buds hy2`，选 **A → 2. 一键新增节点**。名称、访问地址和本地 UDP 端口都可直接回车，脚本会生成节点名称和可用的单端口，并沿用主节点地址。也可以指定域名、单端口、`40000-40031` 或 `40000:40031` 跳跃范围，或输入 `auto:32` 自动选择 32 个连续端口。识别到 NAT 映射时，额外询问公网端口。脚本会自动生成独立凭据、选择证书、写入配置、启动服务并在页面底部显示连接链接。

选 **A → 10. 编辑端口、密码等设置**，再按列表编号选中 `main`（主节点）或附加节点。可改本地端口、公网映射、认证密码、混淆密码、访问地址和伪装网址。主节点沿用原证书和续签任务，改地址时会检查证书是否覆盖新地址。附加节点还可切换证书。每个节点都有独立的链接、客户端配置、状态、日志和启停入口。A 区另有整套卸载和主节点模拟续签入口，整套卸载前请先删除附加节点。

**从单端口改成跳跃端口**：在所选节点的编辑菜单选 **2. 本地 UDP 端口**，先看本机空闲范围，再输入连续范围（如 `41000-41031`）或 `auto:32`。要改回单端口，填一个数字即可。请先确认服务商安全组放行对应 UDP 范围。使用 NAT 映射时，还要在编辑菜单第3项核对公网端口。提交后，回到 A 区选 **3. 连接链接** 或 **4. 客户端配置**，选择该节点，重新导入客户端。

```bash
buds hy2 nodes list
buds hy2 nodes add work --ports auto:32
buds hy2 nodes add personal --ports 41000 --tls self
buds hy2 nodes edit work --auth random --obfs random
buds hy2 nodes link work
buds hy2 nodes client personal
buds hy2 nodes delete personal --yes
```

`--auth custom` 和 `--obfs custom` 会提示在终端中隐藏输入密码。自动 TLS 会复用覆盖该地址的主节点受信任证书，否则为新节点生成独立的自签名证书。自签名节点需使用支持证书或公钥指纹校验的客户端。

脚本检查托管节点的端口、正在监听的 UDP 套接字和可识别的本机 UDP 转发规则。启用 UFW 的服务器会自动添加节点所需的 UDP 入站规则。其他防火墙及服务商安全组由管理员放行。NAT VPS 用 `--public-ports` 填写实际映射后的公网端口或范围。新增本地端口跳跃需要 Hysteria 2.12.3 或更新版本，以及配置本机转发规则的权限。2.12.3 修复了旧版跳跃规则会误重定向其它出站 UDP 流量的问题。[端口跳跃文档](https://v2.hysteria.network/docs/advanced/Port-Hopping/)、[Hysteria 2 更新日志](https://v2.hysteria.network/docs/Changelog/)

自动编辑和新增节点需要 systemd、Python 3.6 或更新版本、`ss`、`flock` 和 OpenSSL。编辑主节点 YAML 还需要 PyYAML，脚本按字段修改并保留其他配置。修改运行中的主节点服务配置会短暂重启主节点；仅改公网映射或客户端地址无需重启。启动失败时会尝试恢复原配置和运行状态。OpenRC 和无 systemd 的环境可在节点区查看和启停主节点。

### WARP 系统级域名分流

首页选 **B** 进入 WARP 分流管理，默认关闭。首次使用选 **1** 引导安装并启用。脚本会检查环境、准备 sing-box 和独立 WireGuard 配置，并在需要时确认是否迁移 DNS。启用后会验证选路和实际 WARP 出口。之后可留在同一菜单选 **2** 检测、**3** 管理域名、**5** 关闭，或选 **12** 恢复迁移前的 DNS。分步操作也可以使用同一菜单。

Gemini 提示地区受限时，先选 **B → 2**，分别查看 Cloudflare 报告的隧道地区和 Gemini 未登录页面经 IPv4、IPv6 入口返回的地区标记。如果两个入口结果不同，可在 **B → 4** 为已列入分流的 Gemini 域名指定 `ipv4` 或 `ipv6`，或选 `auto` 恢复默认。更改会短暂重载 WARP。登录后的可用性需在 Gemini 中确认。

已有节点可运行 `buds hy2 update` 升级。直接使用可信源码时，将下文的`buds hy2 warp`换为`bash "/源码绝对路径/buds" hy2 warp`，并填入本机实际路径。

适用于使用systemd和systemd-resolved的Linux VPS。`/etc/resolv.conf`中的有效`nameserver`必须全部指向本机存根`127.0.0.53`。混用外部DNS可能导致同一目标有时走WARP、有时走原出口。需要内核TUN、iproute2、Python 3、curl、flock，以及包含WireGuard和gVisor的sing-box 1.12或更高1.x版本。VPS的公网可以只有IPv4。内核关闭IPv6时只建立IPv4虚拟路由。sing-box可按[官方软件包说明](https://sing-box.sagernet.org/installation/package-manager/)安装。

先在服务器上运行 `buds hy2 warp doctor`（**B → 6**）。它会检查 TUN、DNS、内核、WireGuard 配置和已有路由。脚本可识别活动 sing-box 服务、`/etc/s-box/sing-box`、受信任的 PATH 程序及脚本准备的独立内核。非标准位置可在启用时用 `BUDS_SING_BOX_BIN=/绝对路径/sing-box buds hy2 warp enable` 指定。

```bash
buds hy2 warp doctor           # 启用前诊断
buds hy2 warp setup            # 准备内核，缺少配置时用 wgcf 注册和生成配置
buds hy2 warp enable           # 自动查找 WireGuard 配置
buds hy2 warp check            # 检查分流和实际 WARP 出口
buds hy2 warp disable          # 关闭分流
```

`setup`在 x86_64 和 ARM64 上可按固定 SHA-256 校验下载 sing-box 和 wgcf，保存在`/etc/buds-hy2/warp-tools`。其他架构可先安装适配的内核和 wgcf，或用`buds hy2 warp enable /实际路径/warp.conf`导入独立配置。wgcf 是社区工具，首次注册需在服务器终端阅读并确认条款。不要重复使用正在运行的 WireGuard 私钥；如需为 buds-HY2 单独注册，执行`buds hy2 warp setup --new-profile`。脚本会检查常见 sing-box 配置中的重复身份。

服务器另有 sing-box 服务时，可以选 **B → 9** 或运行 `buds hy2 warp setup --managed-core` 下载独立内核。新启用的 buds-HY2 分流优先使用这个内核，原有 sing-box 实例继续用自己的配置运行。若分流已经启用，先选 **B → 5** 停止专用分流，再选 **B → 13** 启用，即可切换内核。

如果诊断发现`/etc/resolv.conf`是只含公网 nameserver 的静态文件，可在服务器终端以 root 执行`buds hy2 warp dns-switch`。脚本备份原文件、保留原上游并短暂重启解析服务。查询验证失败时会尝试恢复原配置。以后需要撤销时先执行`buds hy2 warp disable`，再执行`buds hy2 warp dns-restore`。带搜索域、解析选项、容器挂载或其他 DNS 管理器的主机，请按本机管理方式配置 systemd-resolved。OpenRC 或无 systemd 的环境仍可使用 HY2 基础功能。容器启用 WARP 需由宿主机提供 TUN 和网络管理权限。
内置清单只包含Google系列服务，覆盖搜索、Play、谷歌学术、YouTube、Gemini及相关资源域名。ChatGPT、Claude、GitHub和x.com默认沿用原有出口。列入清单的域名由专用解析器分配虚拟IPv4或IPv6地址，sing-box通过WARP查询真实地址并转发TCP或UDP。

选择 **B → 3**即可管理域名。内置条目与自行添加的条目都支持增删和修改。命令行示例：

```bash
buds hy2 warp domains list                         # 查看当前清单，每行一个域名
buds hy2 warp domains add chatgpt.com oaistatic.com
buds hy2 warp domains remove youtube.com
buds hy2 warp domains replace google.com scholar.google.com
buds hy2 warp domains import /root/my-domains.txt  # 用文件替换整份清单
buds hy2 warp domains reset                        # 用内置 Google 清单替换整份清单
```

一条规则匹配该域名及其所有子域名。例如，把`google.com`改成`scholar.google.com`后，谷歌学术仍走WARP，`www.google.com`恢复原出口。若清单内还保留父域名，删除单个子域名条目后仍会匹配父域名。一个服务可能使用多个独立域名，例如YouTube的视频请求还会访问`googlevideo.com`。

**日常检测**用B区第2项或`buds hy2 warp check`。它检查内核选路和WARP出口，并对清单覆盖的Google、YouTube逐个测试系统返回的IPv4、IPv6虚拟地址。每个HTTPS探测须返回204。检测失败会显示出错的域名和地址族，检查过程不会重启服务。客户端仍需从实际节点复测。

**已有服务器升级**可在首页按U更新，随后进入B区第15项在线刷新保护。命令行先执行`buds hy2 update`，再运行`buds hy2 nodes reserve-ports`。已启用托管WARP的机器可以执行`buds hy2 warp refresh`，刷新下次启动和巡检使用的文件，当前进程和会话继续运行。早于1.7.3且还没有看门狗单元的安装，可在维护时段使用B区第14项或`buds hy2 warp repair`补齐单元并修复分流，必要时会重启WARP。

**自动恢复**由`buds-warp-watch.timer`每五分钟执行。出口探针正常但Google或YouTube某个地址族异常时，巡检记录失败并保留会话。探针两次失败后会核对已选业务和原生网络；同一WARP会话跨两轮都满足重启条件时才尝试重连。启动阶段有独立的握手探测。对使用默认UDP 2408的Cloudflare入口，启动探测持续失败后，下次启动会尝试同一地址的500、1701、4500，依次循环。原始WireGuard配置继续保留。上游或线路持续不可用时，备用端口也可能失败。[Cloudflare入口及端口说明](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/deployment/firewall/)

**端口跳跃**会在Linux上安装UDP重定向规则。新装和改端口时先保留跳跃范围，再启用规则，旧范围在切换成功后回收。若范围中已有其他UDP套接字、内核拒绝保留，或新范围会过度挤占临时端口，操作会停止并提示换用较小范围或单端口。脚本记录自己新增的保留范围，遇到其他工具持久管理同一内核参数时会提示核对。保留范围只影响后续自动分配的端口。[Linux源端口参数说明](https://docs.kernel.org/networking/ip-sysctl.html)

查看本次开机的启动和巡检记录可用`journalctl -b -u buds-warp-split -u buds-warp-watch --no-pager -n 80`。内核维护前后各执行一次B区第2项，再用实际客户端各访问一个分流网站和一个原生出口网站。

批量导入时可每行写一个域名，支持空行和`#`注释，空文件表示清空。脚本统一大小写并去重。可先用`buds hy2 warp domains list > /root/my-domains.txt`导出、编辑，再导入。配置保存在`/etc/buds-hy2/warp-domains`，关闭分流、重启和升级CLI后继续保留。在线修改会重启专用WARP服务，已有WARP连接需要重连；新规则启动失败时脚本会尝试恢复原清单和服务。

从v1.4.0升级时，正在运行的旧服务继续使用原清单，`domains list`可查看。要立即切换到仅Google的默认规则，执行`buds hy2 warp domains reset`。

该策略覆盖VPS本机和交给HY2服务端按域名连接的请求。客户端提前解析后只交给HY2一个真实IP、应用自带DoH、独立网络命名空间、自定义HY2解析器或已有DNS缓存，都可能绕过分流。已有全局VPN的机器会沿用其原有出口。新启用或关闭后请重连客户端，必要时清除应用DNS缓存。

启动前会检查专用地址段及已有DNS路由，并使用系统DNS解析WireGuard端点，再建立分流链路。其他解析链路若已接管相同或更具体的目标后缀，脚本会拒绝启用有冲突的清单。WireGuard的`Endpoint`使用域名时，也应将它及覆盖它的父域名留在清单之外，否则建立隧道本身就会依赖该隧道。

启用时会抽查样本域名、GitHub和x.com的选路。清单非空时，还会通过隧道请求Cloudflare Trace并核对WARP出口标记。诊断失败会撤销本次启用。可用`journalctl -u buds-warp-split.service -b`查看日志。关闭分流或卸载节点时会清理专用服务，保留输入的WireGuard配置。Google Play内容、YouTube Premium权益和AI服务可用性仍取决于出口地区、账号及各平台策略，需登录相应服务验证。

### 从旧管理脚本迁移

先按上面的步骤安装可信公钥。选择已签名的版本，验签后在同一文件系统内替换管理脚本。此操作只更新 CLI，沿用已有节点配置和证书。

```bash
(
  set -e
  version=1.7.4
  base="https://raw.githubusercontent.com/Buds-2025/buds-hy2/updates/releases/$version"
  work=$(mktemp -d /usr/local/bin/.buds_upgrade.XXXXXX)
  trap 'rm -rf -- "$work"' EXIT
  curl -q -fsSL --proto '=https' --proto-redir '=https' "$base/buds" -o "$work/buds"
  curl -q -fsSL --proto '=https' --proto-redir '=https' "$base/buds.sig" -o "$work/buds.sig"
  openssl dgst -sha256 -verify /etc/buds-hy2/update.pub -signature "$work/buds.sig" "$work/buds"
  grep -Fx "SCRIPT_VERSION=\"$version\"" "$work/buds"
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

## 仓库更新资产

使用独立保管的 RSA 或 ECDSA 私钥签署同步后的 `buds` 和 `install.sh`，并签署版本文件：

```bash
set -e
python3 scripts/sync_cli.py --check
version=$(sed -n 's/^SCRIPT_VERSION="\([0-9.]*\)"$/\1/p' buds)
test -n "$version"
test "$(grep -m 1 '^SCRIPT_VERSION=' install.sh)" = "SCRIPT_VERSION=\"$version\""
printf '%s\n' "$version" > buds.version
openssl dgst -sha256 -sign /secure/path/update.key -out buds.version.sig buds.version
openssl dgst -sha256 -sign /secure/path/update.key -out buds.sig buds
openssl dgst -sha256 -sign /secure/path/update.key -out install.sh.sig install.sh
```

将 `update.pub`、`buds.version`、`buds.version.sig` 放在 `updates` 分支根目录，将 `buds`、`buds.sig`、`install.sh`、`install.sh.sig` 放在该分支的 `releases/$version/` 下。用一次提交发布版本目录和版本清单。保留已发布的版本目录，并通过独立可信渠道分发公钥指纹。
