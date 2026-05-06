# Alpine-sing-box

这是一个 **AI 改写版** 的 `sing-box` 远程拉取执行脚本。

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

### 指定端口
```bash
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) -port 20086
```

### 指定 Reality 伪装域名
```bash
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) -reality-domain example.com
```

### 自动安装并同时指定端口和伪装域名
```bash
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) -install -port 20086 -reality-domain example.com
```

## 说明

- 建议在 `root` 环境下执行
- 脚本主要面向 Alpine 系统
- 如不传参数，默认进入交互菜单
