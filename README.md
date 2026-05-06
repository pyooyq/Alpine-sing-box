# Alpine-sing-box

这是一个 **AI 改写版** 的 `sing-box` 远程拉取执行脚本。

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
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) -port 12345
```

### 指定 Reality 伪装域名
```bash
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) -reality-domain example.com
```

### 自动安装并同时指定端口和伪装域名
```bash
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) -install -port 12345 -reality-domain example.com
```

## 说明

- 建议在 `root` 环境下执行
- 脚本主要面向 Alpine 系统
- 如不传参数，默认进入交互菜单
