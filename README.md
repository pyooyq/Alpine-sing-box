# Alpine-sing-box

这是一个精简版 `sing-box` 安装/管理脚本，支持 VLESS Reality、普通 VLESS、Shadowsocks 入站，并支持多个入站按用户名绑定到不同 outbound。

## 功能

- 优先复用本机已安装且可执行的 `sing-box`
- 本机没有可用 `sing-box` 时先尝试 Alpine 包安装，再补兼容库并下载上游二进制
- 生成精简 sing-box 入站配置，默认使用 VLESS Reality 作为中转入口
- 支持多个入站用户，每个用户独立 UUID/name 或 SS 密码
- 添加落地时自动创建独立 VLESS Reality 用户
- 支持按用户绑定 outbound：本机直连 `direct`、SOCKS5、Shadowsocks、VLESS、HTTP
- 默认创建 `default-direct` 用户并绑定 `direct`，保留当前 VPS 本机直接作为节点的用法
- 支持添加落地时自动创建并绑定用户
- 支持手动添加带账号密码的 SOCKS5 落地并自动绑定用户
- 支持从 `ss://`、`vless://`、`http://`、`https://` 或其 base64 内容自动导入落地并绑定用户
- 支持自定义 Reality 端口和伪装域名/SNI
- 不支持导入 VLESS Reality 落地
- 不安装 nginx
- 不配置 Argo/Cloudflare Tunnel
- 不生成订阅文件
- 安装后保留 `sb` 快捷命令打开管理菜单

## 免责声明

- 本项目仅供学习、研究与合法授权环境下的测试使用
- 使用者应自行确认当地法律法规、服务商条款及目标系统授权范围
- 因使用本项目造成的账号、网络、服务或数据风险与损失，由使用者自行承担
- 请勿将本项目用于未授权访问、滥用代理、绕过限制或其他违法违规用途

## 远程拉取执行

### 交互模式

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh)
```

### 自动安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) -install
```

### 自动安装并指定端口

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) -install -port 20086
```

### 自动安装并指定 Reality 伪装域名

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) -install -reality-domain example.com
```

### 自动安装并同时指定端口和伪装域名

```bash
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) -install -port 20086 -reality-domain example.com
```

## 管理

安装完成后可执行：

```bash
sb
```

菜单支持添加落地并自动绑定用户、查看节点摘要、管理落地、修改 Reality 设置、启动/停止/重启 sing-box、查看日志、卸载。

## 使用方式

安装完成后会自动生成一个 `default-direct` 用户，绑定内置 `direct` outbound。这个用户连接当前 VPS 后直接从当前 VPS 出口访问网络，保持原来的本机 Reality 节点用法。

如需把当前 VPS 作为中转入口使用，可以在菜单中：

1. 使用“添加落地并自动绑定用户”，直接粘贴 `ss://`、`vless://`、`http://`、`https://` 或其 base64 内容，脚本会自动识别协议并创建对应落地与默认 Reality 入站用户。
2. 进入“管理落地”可导入落地、手动添加 SOCKS5、查看节点链接、列出落地或删除落地。
3. 客户端使用脚本生成的对应协议链接连接当前 VPS；服务端会按入站用户路由到绑定的 outbound。

内置 outbound：

- `direct`：当前 VPS 本机直连出口，不能删除。
- `block`：未匹配用户兜底阻断，不能删除。

删除落地 outbound 时，脚本会同步删除所有绑定到该落地的用户。

## 说明

- 建议在 `root` 环境下执行
- 脚本主要面向 Alpine/OpenRC，也兼容常见 systemd 发行版
- 如不传参数，默认进入交互菜单
- 运行状态保存在 `/etc/sing-box/reality.env`、`/etc/sing-box/users.d/` 和 `/etc/sing-box/outbounds.d/`
- 旧版单用户安装会自动迁移为 `default-direct` 用户，并继续绑定本机直连 `direct`
- `-port` 指定的是 Reality 主入站端口；添加落地时会自动创建使用该端口的 Reality 用户
