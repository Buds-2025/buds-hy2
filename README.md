# buds-naiveproxy

```text
  _               _                                 _                               
 | |__  _   _  __| |___       _ __   __ _ _ ____  _| |_ __  _ __ _____  ___   _ 
 | '_ \| | | |/ _` / __|_____| '_ \ / _` | '__\ \/ / | '_ \| '__/ _ \ \/ / | | |
 | |_) | |_| | (_| \__ \_____| | | | (_| | |   >  <| | |_) | | | (_) >  <| |_| |
 |_.__/ \__,_|\__,_|___/     |_| |_|\__,_|_|  /_/\_\_| .__/|_|  \___/_/\_\\__, |
                                                     |_|                  |___/ 
```

> **A minimalist, least-privilege NaiveProxy orchestration script.**  
> 专为 Linux 设计的 NaiveProxy 自动化部署与沙箱化运维工具，专注于进程权限隔离与网关无冲突协同。

---

## 快速开始

在目标 Linux 服务器（Debian 11+ / Ubuntu 20.04+）上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Buds-2025/buds-naiveproxy/main/install.sh)
```

支持管道流直接交互。再次运行同一命令可呼出管理菜单（状态检查、热重载、审计跟踪、干净卸载）。

---

## 设计哲学

* **特权最小化（Least Privilege）**  
  服务运行于独立系统用户 `caddy`（`nologin`）。Systemd 层面启用 `ProtectSystem=strict`、`ProtectHome=yes`、`NoNewPrivileges=yes`，并通过 Linux Capabilities 仅赋予 `CAP_NET_BIND_SERVICE`。
* **零冲突共存（Gateway Coexistence）**  
  不强占 `80`/`443` 端口。针对已存在 Nginx 的宿主机，通过 Certbot 模块化申请与续签，强制保留 `auto_https off`，绝不修改宿主机已有网站配置。
* **特征常态化（Fingerprint Normalization）**  
  消除 Caddy 特有响应头，自适应回退为 `Server: nginx` 或 `Server: cloudflare`；集成 `encode zstd gzip` 动态压缩与 HSTS 传输安全策略，行为与生产级 Web 网关保持一致。
* **主动探测规避（Probe Resistance）**  
  集成 `probe_resistance` 密钥路径过滤。未携带认证凭证的随机嗅探与恶意扫描将静默路由至预置的静态网关页面，削弱主动探测威胁。
* **低开销运行**  
  Caddy + Go 官方原生编译，空闲内存占用约 15MB~30MB。构建时遇低内存机器（< 2GB）自动调度临时 Swap，防止 OOM 崩溃。

---

## 客户端配置范例

安装完成后，程序将在执行目录生成 `naive_client.json`：

```json
{
  "listen": "socks://127.0.0.1:10808",
  "proxy": "https://username:password@your-domain.com:8443"
}
```

* **v2rayN**：下载 [NaiveProxy 官方 Releases](https://github.com/klzgrad/naiveproxy/releases) 内核放入目录，添加自定义配置服务器，类型选择 `naive`。
* **CLI 原生运行**：`./naive naive_client.json`。

---

## 运维速查

```bash
systemctl status caddy         # 查看运行状态
systemctl reload caddy         # 平滑热重载（不中断活跃连接）
journalctl -u caddy -f         # 跟踪服务日志
tail -f /var/log/caddy/access.log  # 实时审计访问日志（JSON 格式）
/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile  # 校验语法
```

---

## 风险规避与使用说明

1. **非绝对安全声明**  
   任何代理技术都无法提供 100% 的不可封锁保障。虽然 NaiveProxy 基于 Chromium 网络栈与真实 TLS 握手特征，但审查系统仍可能通过 IP 归属地、连接频次、流量时序分析（Traffic Analysis）或针对特定非标准端口的异常流量实施限速或阻断。
2. **域名与证书合规**  
   请使用解析记录准确的自有合规域名，并确保证书由权威 CA（如 Let's Encrypt）有效签发。切勿在证书无效或解析未生效时强行连接，否则客户端可能直接报错或触发 SNI 审计异常。
3. **资源与端口策略**  
   建议选择 `8443`、`2096` 等常见 TLS 备用端口，避免使用冷门高位端口引起异常关注。避免长期单 IP 满载占用境外骨干网出口，降低被运营商策略性流控的几率。
4. **免责条款**  
   本项目仅供网络协议工程研究、学术探索与服务安全加固评估使用。使用者需严格遵守当地法律法规，作者不对因使用此脚本而导致的任何 IP 阻断、数据丢失或合规风险负责。

---

## 许可证

[MIT License](LICENSE)
