# Alpine-sing-box

这是一个精简版 `sing-box` 安装/管理脚本，支持 VLESS Reality、普通 VLESS、Shadowsocks、Hysteria2 入站，并支持多个入站按用户名绑定到不同 outbound。

## 功能

- 优先复用本机已安装且可执行的 `sing-box`
- 本机没有可用 `sing-box` 时先尝试 Alpine 包安装，再补兼容库并下载上游二进制
- 生成精简 sing-box 入站配置，默认使用 VLESS Reality 作为中转入口
- 支持多个入站用户，每个用户独立 UUID/name 或 SS 密码
- 添加落地时自动创建独立 VLESS Reality 用户（当前无任何入站时兜底）
- 支持按用户绑定 outbound：本机直连 `direct`、SOCKS5、Shadowsocks、VLESS、HTTP
- 默认创建 `default-direct` 用户并绑定 `direct`，保留当前 VPS 本机直接作为节点的用法
- 添加落地后按序号选择一个现有入站绑定（不再自动新建用户）
- 支持从 `ss://`、`vless://`、`http://`、`https://`、`socks5://`（支持带/不带密码）或其 base64 内容导入落地并绑定到所选入站
- 支持自定义 Reality 端口和伪装域名/SNI（交互式初始化节点时可回车使用默认值）
- 支持额外增加入站（和初始化节点一样作为代理服务器，可添加多个；自动检测端口是否与已有入站/转发冲突）
- 一种协议一个入站（一个端口）可挂多个用户，每个用户独立绑定不同出站（本机 `direct` 或落地）。如同一 Hysteria2 端口上既有走直连的用户，也有走落地的用户，互不覆盖
- 支持 Hysteria2 多用户入站：自签名证书、默认随机高位端口、TLS，SNI 默认为当前 Reality 域名，可自定义端口和 SNI，同一端口多用户按用户名区分路由
- 支持 VLESS / VLESS+Reality 多用户入站：同一端口多用户按 UUID 区分路由（Reality 用户共享主端口，用 `auth_user` 区分）
- Shadowsocks 暂为单用户独立端口（一端口多用户需 `2022-blake3-*` 加密与 master key，暂未开放）
- sing-box 守护：进程被杀自动重启；用户手动“停止”时不复活（systemd 用 `Restart=always`，OpenRC 用 shell 包装器循环 respawn）
- 支持 TCP/UDP 纯转发：基于用户态 realm 转发，不处理协议，客户端无需任何配置，支持 tcp、udp 或两者，无需 iptables（可在无 iptables / 无特权容器环境工作）
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

菜单支持：安装/初始化节点、添加落地、入站管理（增/删/改入站与用户）、落地管理（查看/删除/改绑）、TCP/UDP 转发管理、服务与日志（启动/停止/重启/日志）、卸载。

## 使用方式

安装完成后会自动生成一个 `default-direct` 用户，绑定内置 `direct` outbound。这个用户连接当前 VPS 后直接从当前 VPS 出口访问网络，保持原来的本机 Reality 节点用法。

如需把当前 VPS 作为中转入口使用，可以在菜单中：

1. 使用“添加落地”，直接粘贴 `ss://`、`vless://`、`http://`、`https://`、`socks5://`（支持带/不带密码）或其 base64 内容；脚本识别协议后列出现有入站（按 协议+端口 分组），由你按序号选择要挂到哪个入站。落地会作为该入站上的**新用户**（不覆盖已有用户），若当前没有任何入站则自动创建一个绑定该落地的新用户。
2. 进入“入站管理”可增加入站（选协议、端口、绑定的 outbound 建第一个用户），或选中某个入站后添加用户 / 修改端口 / 编辑用户出站 / 删除用户 / 删除整个入站 / 查看连接链接。增加用户时若端口已有同协议入站，新用户会加入该入站（同端口多用户）。
3. 进入“落地管理”按序号列出所有落地及其绑定用户；选择某个落地后可删除它，或把它改绑到某个用户。
4. 客户端使用脚本生成的对应协议链接连接当前 VPS；服务端会按入站用户（`auth_user`，Reality/VLESS/Hysteria2）路由到绑定的 outbound。

内置 outbound：

- `direct`：当前 VPS 本机直连出口，不能删除。
- `block`：未匹配用户兜底阻断，不能删除。

删除落地 outbound 时，脚本会同步删除所有绑定到该落地的用户。

## TCP/UDP 转发

如需把当前 VPS 作为纯 TCP/UDP 转发器（不处理协议、不解析流量），可在主菜单选择 **5. TCP/UDP 转发管理** 添加转发规则：

1. 输入规则名称，选择协议（`tcp` / `udp` / `both`）。
2. 输入本地监听端口和目标地址:端口。
3. 脚本自动安装用户态转发工具 **realm** 并生成 `/etc/realm/config.json`，由 realm 服务（`/etc/systemd/system/realm.service` 或 `/etc/init.d/realm`，开机自启）接管所有转发。

```
本地 :10086  ->  目标 1.2.3.4:443  (tcp udp)
```

特点：

- 用户态级转发，无需 iptables，客户端无需任何代理配置；也可在无 iptables / 无特权容器环境工作。
- 所有转发规则统一由单个 realm 服务接管，重载配置即可生效。
- TCP 与 UDP 可分别或同时转发。
- 删除规则会重写 realm 配置并重载服务；删除最后一条规则时会停用并移除 realm 服务。
- 卸载时会自动清理 realm 服务与配置。

> 注意：realm 为 `realm` 官方发布版本，适用于 Alpine/OpenRC 及大部分 Linux 发行版；目标地址支持 IPv4 / IPv6 / 域名。

## 说明

- 建议在 `root` 环境下执行
- 脚本主要面向 Alpine/OpenRC，也兼容常见 systemd 发行版
- 如不传参数，默认进入交互菜单
- 运行状态保存在 `/etc/sing-box/reality.env`、`/etc/sing-box/users.d/`、`/etc/sing-box/outbounds.d/` 和 `/etc/sing-box/forwards.d/`
- 旧版单用户安装会自动迁移为 `default-direct` 用户，并继续绑定本机直连 `direct`
- `-port` 指定的是 Reality 主入站端口；添加落地时若没有任何入站，会自动创建使用该端口的 Reality 用户
- 守护：只要未手动“停止”，进程被杀会自动重启（systemd `Restart=always` / OpenRC respawn 包装器）；手动停止后不会复活
