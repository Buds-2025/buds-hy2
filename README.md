# buds-hy2

适用于 Ubuntu / Debian 系统的 Hysteria 2 自动化部署与运维脚本。

针对已托管个人网站的服务器设计，部署过程中避开 80/443 端口与现有网站配置，通过 Certbot 进行证书申请与自动续期同步。

---

## 快速安装

在服务器终端（root 权限）执行以下命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Buds-2025/buds-hy2/main/install.sh)
```

脚本将引导完成：
1. 域名设置（输入已解析到本机的域名，如 your.domain.com）；
2. 端口设置（支持回车使用随机高位端口、指定单端口或输入端口范围开启端口跳跃）；
3. 证书申请、服务端配置、内核参数调优及服务启动。

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
