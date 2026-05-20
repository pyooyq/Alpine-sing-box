# Alpine-sing-box

这是一个精简版 `sing-box` Reality-only 安装/管理脚本，只配置 VLESS Reality 入站。

## 功能

- 优先复用本机已安装且可执行的 `sing-box`
- 本机没有可用 `sing-box` 时先尝试 Alpine 包安装，再补兼容库并下载上游二进制
- 仅生成 VLESS Reality 配置
- 支持自定义 Reality 端口和伪装域名/SNI
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

菜单支持查看 Reality 参数、修改端口、修改伪装域名、启动/停止/重启 sing-box、查看日志、卸载。

## 说明

- 建议在 `root` 环境下执行
- 脚本主要面向 Alpine/OpenRC，也兼容常见 systemd 发行版
- 如不传参数，默认进入交互菜单
