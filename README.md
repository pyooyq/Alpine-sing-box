# Alpine-sing-box

这是一个精简版 `sing-box` Reality 安装/管理脚本，只配置一个 VLESS Reality 入站，并支持多个入站用户按用户名绑定到不同 outbound。

## 功能

- 优先复用本机已安装且可执行的 `sing-box`
- 本机没有可用 `sing-box` 时先尝试 Alpine 包安装，再补兼容库并下载上游二进制
- 仅生成 VLESS Reality 入站配置
- 支持多个 Reality 入站用户，每个用户独立 UUID/name
- 支持按用户绑定 outbound：本机直连 `direct`、SOCKS5、Shadowsocks、VLESS、HTTP
- 默认创建 `default-direct` 用户并绑定 `direct`，保留当前 VPS 本机直接作为节点的用法
- 支持一键添加落地并自动创建绑定用户
- 支持手动添加带账号密码的 SOCKS5 落地
- 支持从 `ss://`、`vless://`、`http://`、`https://` 或其 base64 内容自动导入落地
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

菜单支持一键添加落地并绑定用户、自动识别协议导入落地、查看 Reality 摘要、合并管理用户和落地、修改 Reality 设置、启动/停止/重启 sing-box、查看日志、卸载。

## 使用方式

安装完成后会自动生成一个 `default-direct` 用户，绑定内置 `direct` outbound。这个用户连接当前 VPS 后直接从当前 VPS 出口访问网络，保持原来的本机 Reality 节点用法。

如需把当前 VPS 作为中转入口使用，可以在菜单中：

1. 使用“一键添加落地并绑定新用户”，直接粘贴 `ss://`、`vless://`、`http://`、`https://` 或其 base64 内容，脚本会自动识别协议并创建对应落地与用户。
2. 进入“管理用户和落地”处理已有用户、查看链接、修改绑定、列出/删除落地，或单独导入落地。
3. 客户端仍使用脚本生成的 VLESS Reality 链接连接当前 VPS；服务端会按用户 name/UUID 路由到绑定的 outbound。

内置 outbound：

- `direct`：当前 VPS 本机直连出口，不能删除。
- `block`：未匹配用户兜底阻断，不能删除。

删除落地 outbound 前，脚本会检查是否仍有用户绑定；被使用时会拒绝删除。

## 说明

- 建议在 `root` 环境下执行
- 脚本主要面向 Alpine/OpenRC，也兼容常见 systemd 发行版
- 如不传参数，默认进入交互菜单
- 运行状态保存在 `/etc/sing-box/reality.env`、`/etc/sing-box/users.d/` 和 `/etc/sing-box/outbounds.d/`
- 旧版单用户安装会自动迁移为 `default-direct` 用户，并继续绑定本机直连 `direct`
