#!/usr/bin/env bash

set -o pipefail

export LANG=en_US.UTF-8

re="\033[0m"
red="\033[1;91m"
green="\033[1;32m"
yellow="\033[1;33m"
purple="\033[1;35m"
skyblue="\033[1;36m"

red() { echo -e "${red}$1${re}"; }
green() { echo -e "${green}$1${re}"; }
yellow() { echo -e "${yellow}$1${re}"; }
purple() { echo -e "${purple}$1${re}"; }
skyblue() { echo -e "${skyblue}$1${re}"; }
reading() { read -r -p "$(red "$1")" "$2"; }

server_name="sing-box"
work_dir="/etc/sing-box"
config_dir="${work_dir}/config.json"
state_file="${work_dir}/reality.env"
installed_script="${work_dir}/sb.sh"
reality_domain="cas-bridge.xethub.hf.co"
vless_port=""
auto_install=0

usage() {
    cat << EOF
sing-box Reality-only 安装脚本

用法:
  bash sing-box.sh                         进入菜单
  bash sing-box.sh -install                自动安装
  bash sing-box.sh -install -port 20086    指定 Reality 端口
  bash sing-box.sh -install -reality-domain example.com

参数:
  -install                 执行安装
  -port <1-65535>          Reality 监听端口
  -reality-domain <domain> Reality 伪装域名/SNI
  -h, --help               显示帮助
EOF
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_domain() {
    [ -n "$1" ] && [[ "$1" != *\ * ]] && [[ "$1" != *\"* ]] && [[ "$1" != *\'* ]]
}

random_port() {
    if command_exists shuf; then
        shuf -i 20000-65000 -n 1
        return
    fi

    local n
    n=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')
    echo $((20000 + n % 45001))
}

while [ $# -gt 0 ]; do
    case "$1" in
        -install|--install)
            auto_install=1
            shift
            ;;
        -port|--port)
            [ -n "$2" ] || { red "-port 缺少端口参数"; exit 1; }
            validate_port "$2" || { red "-port 端口范围需在 1-65535"; exit 1; }
            vless_port="$2"
            shift 2
            ;;
        -reality-domain|--reality-domain|--domain)
            [ -n "$2" ] || { red "-reality-domain 缺少域名参数"; exit 1; }
            validate_domain "$2" || { red "-reality-domain 参数不合法"; exit 1; }
            reality_domain="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            red "未知参数: $1"
            usage
            exit 1
            ;;
    esac
done

[ -n "$vless_port" ] || vless_port=$(random_port)

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    red "请在 root 用户下运行脚本"
    exit 1
fi

load_state() {
    [ -f "$state_file" ] && . "$state_file"
}

save_state() {
    cat > "$state_file" << EOF
PORT="$PORT"
REALITY_DOMAIN="$REALITY_DOMAIN"
UUID="$UUID"
PRIVATE_KEY="$PRIVATE_KEY"
PUBLIC_KEY="$PUBLIC_KEY"
SHORT_ID="$SHORT_ID"
EOF
    chmod 600 "$state_file"
}

check_singbox() {
    if [ ! -x "${work_dir}/${server_name}" ] && [ ! -f /etc/systemd/system/sing-box.service ] && [ ! -f /etc/init.d/sing-box ]; then
        red "not installed"
        return 2
    fi

    if command_exists rc-service; then
        rc-service sing-box status 2>/dev/null | grep -q "started" && green "running" || yellow "not running"
    elif command_exists systemctl; then
        systemctl is-active sing-box 2>/dev/null | grep -q "^active$" && green "running" || yellow "not running"
    else
        yellow "unknown"
    fi
}

manage_packages() {
    local action="$1"
    shift

    [ "$action" = "install" ] || { red "不支持的包管理动作: $action"; return 1; }

    if command_exists apt; then
        apt update
        DEBIAN_FRONTEND=noninteractive apt install -y "$@"
    elif command_exists dnf; then
        dnf install -y "$@"
    elif command_exists yum; then
        yum install -y "$@"
    elif command_exists apk; then
        apk update
        apk add --no-cache "$@"
    else
        red "未识别的包管理器，请手动安装: $*"
        return 1
    fi
}

ensure_dependencies() {
    local packages=(curl tar ca-certificates)
    manage_packages install "${packages[@]}"
    command_exists update-ca-certificates && update-ca-certificates >/dev/null 2>&1 || true
}

is_working_singbox() {
    [ -x "$1" ] && "$1" version >/dev/null 2>&1
}

use_existing_singbox() {
    local candidate

    for candidate in "${work_dir}/${server_name}" "$(command -v sing-box 2>/dev/null || true)" /usr/local/bin/sing-box /usr/bin/sing-box; do
        [ -n "$candidate" ] || continue
        is_working_singbox "$candidate" || continue

        mkdir -p "$work_dir"
        chmod 755 "$work_dir"
        if [ "$candidate" != "${work_dir}/${server_name}" ]; then
            cp "$candidate" "${work_dir}/${server_name}"
            chmod +x "${work_dir}/${server_name}"
        fi
        green "使用本机已安装的 sing-box: $candidate"
        return 0
    done

    return 1
}

install_singbox_from_package() {
    command_exists apk || return 1

    yellow "未发现可用的本机 sing-box，尝试通过 apk 安装 sing-box..."
    apk add --no-cache sing-box >/dev/null 2>&1 || return 1
    use_existing_singbox
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        i386|i686|x86) echo "386" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7) echo "armv7" ;;
        armv6l|armv6) echo "armv6" ;;
        s390x) echo "s390x" ;;
        *) red "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

install_singbox_binary() {
    local arch latest_version archive tmp_dir source_bin

    use_existing_singbox && return 0
    install_singbox_from_package && return 0

    arch=$(detect_arch)
    mkdir -p "$work_dir"
    chmod 755 "$work_dir"

    latest_version=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$latest_version" ] || { red "获取 sing-box 最新版本失败"; exit 1; }

    archive="${work_dir}/sing-box-${latest_version}-linux-${arch}.tar.gz"
    tmp_dir=$(mktemp -d)

    yellow "下载 sing-box v${latest_version}..."
    curl -fL --retry 3 -o "$archive" "https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/sing-box-${latest_version}-linux-${arch}.tar.gz" || {
        rm -rf "$tmp_dir" "$archive"
        red "下载 sing-box 失败"
        exit 1
    }

    tar -xzf "$archive" -C "$tmp_dir" || {
        rm -rf "$tmp_dir" "$archive"
        red "解压 sing-box 失败"
        exit 1
    }

    source_bin="${tmp_dir}/sing-box-${latest_version}-linux-${arch}/sing-box"
    [ -x "$source_bin" ] || { rm -rf "$tmp_dir" "$archive"; red "未找到 sing-box 可执行文件"; exit 1; }

    mv "$source_bin" "${work_dir}/${server_name}"
    chmod +x "${work_dir}/${server_name}"
    rm -rf "$tmp_dir" "$archive"

    if ! is_working_singbox "${work_dir}/${server_name}"; then
        red "下载的 sing-box 无法在当前系统执行，请先用系统包管理器安装 sing-box 后重试。"
        red "Alpine 可尝试执行: apk add --no-cache sing-box"
        exit 1
    fi
}

generate_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        "${work_dir}/${server_name}" generate uuid
    fi
}

generate_reality_values() {
    local output

    UUID=$(generate_uuid)
    output=$("${work_dir}/${server_name}" generate reality-keypair)
    PRIVATE_KEY=$(echo "$output" | awk '/PrivateKey:/ {print $2}')
    PUBLIC_KEY=$(echo "$output" | awk '/PublicKey:/ {print $2}')
    SHORT_ID=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')

    [ -n "$UUID" ] && [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] && [ -n "$SHORT_ID" ] || {
        red "生成 Reality 参数失败"
        exit 1
    }
}

write_config() {
    cat > "$config_dir" << EOF
{
  "log": {
    "level": "warn",
    "output": "${work_dir}/sing-box.log",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_DOMAIN}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF
    chmod 600 "$config_dir"
}

allow_port() {
    local port="$1"

    yellow "尝试放行 TCP ${port} 端口..."
    command_exists ufw && ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    command_exists firewall-cmd && firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 || true

    if command_exists iptables; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    fi

    if command_exists ip6tables; then
        ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
}

write_systemd_service() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=${work_dir}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${work_dir}/${server_name} run -c ${config_dir}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now sing-box
}

write_openrc_service() {
    cat > /etc/init.d/sing-box << EOF
#!/sbin/openrc-run

description="sing-box service"
command="${work_dir}/${server_name}"
command_args="run -c ${config_dir}"
command_background=true
pidfile="/var/run/sing-box.pid"
EOF

    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default >/dev/null 2>&1
    rc-service sing-box restart
}

install_service() {
    if command_exists systemctl; then
        write_systemd_service
    elif command_exists rc-update && command_exists rc-service; then
        write_openrc_service
    else
        red "未检测到 systemd 或 OpenRC，请手动配置 sing-box 服务"
        exit 1
    fi
}

restart_singbox() {
    if command_exists systemctl && [ -f /etc/systemd/system/sing-box.service ]; then
        systemctl daemon-reload
        systemctl restart sing-box
    elif command_exists rc-service && [ -f /etc/init.d/sing-box ]; then
        rc-service sing-box restart
    else
        red "sing-box 服务不存在"
        return 1
    fi
}

start_singbox() {
    if command_exists systemctl && [ -f /etc/systemd/system/sing-box.service ]; then
        systemctl start sing-box
    elif command_exists rc-service && [ -f /etc/init.d/sing-box ]; then
        rc-service sing-box start
    else
        red "sing-box 服务不存在"
        return 1
    fi
}

stop_singbox() {
    if command_exists systemctl && [ -f /etc/systemd/system/sing-box.service ]; then
        systemctl stop sing-box
    elif command_exists rc-service && [ -f /etc/init.d/sing-box ]; then
        rc-service sing-box stop
    else
        red "sing-box 服务不存在"
        return 1
    fi
}

get_server_ip() {
    local ip

    ip=$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)
    if [ -n "$ip" ]; then
        echo "$ip"
        return
    fi

    ip=$(curl -6 -fsS --max-time 3 https://api64.ipify.org 2>/dev/null || true)
    if [ -n "$ip" ]; then
        echo "[${ip}]"
        return
    fi

    echo "你的服务器IP"
}

show_reality_info() {
    if [ ! -f "$state_file" ]; then
        yellow "尚未生成 Reality 参数，请先安装。"
        return 1
    fi

    load_state
    local server_ip link
    server_ip=$(get_server_ip)
    link="vless://${UUID}@${server_ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#sing-box-reality"

    green "\nReality 参数："
    purple "地址: ${server_ip}"
    purple "端口: ${PORT}"
    purple "UUID: ${UUID}"
    purple "Flow: xtls-rprx-vision"
    purple "Security: reality"
    purple "SNI/伪装域名: ${REALITY_DOMAIN}"
    purple "PublicKey: ${PUBLIC_KEY}"
    purple "ShortID: ${SHORT_ID}"
    purple "Fingerprint: chrome"
    yellow "\n单节点链接仅显示在这里："
    purple "$link\n"
}

create_shortcut() {
    mkdir -p "$work_dir"

    if [ -r "$0" ]; then
        cp "$0" "$installed_script" 2>/dev/null || true
    fi

    if [ ! -s "$installed_script" ]; then
        cat > "$installed_script" << 'EOF'
#!/usr/bin/env bash
bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) "$@"
EOF
    fi

    chmod +x "$installed_script"
    cat > /usr/bin/sb << EOF
#!/usr/bin/env bash
exec bash "${installed_script}" "\$@"
EOF
    chmod +x /usr/bin/sb
    green "快捷指令 sb 创建成功，后续可输入 sb 打开脚本。"
}

run_install_flow() {
    if [ -f "$state_file" ] && [ -x "${work_dir}/${server_name}" ]; then
        yellow "sing-box Reality 已安装。"
        show_reality_info
        create_shortcut
        return 0
    fi

    clear
    purple "正在安装 sing-box Reality-only..."
    ensure_dependencies
    install_singbox_binary

    PORT="$vless_port"
    REALITY_DOMAIN="$reality_domain"
    generate_reality_values
    write_config
    save_state
    allow_port "$PORT"
    install_service
    create_shortcut
    show_reality_info
}

change_port() {
    load_state
    [ -n "${PORT:-}" ] || { yellow "尚未安装。"; return 1; }

    local new_port
    reading "请输入新的 Reality 端口（回车随机）: " new_port
    [ -n "$new_port" ] || new_port=$(random_port)
    validate_port "$new_port" || { red "端口范围需在 1-65535"; return 1; }

    PORT="$new_port"
    write_config
    save_state
    allow_port "$PORT"
    restart_singbox
    show_reality_info
}

change_reality_domain() {
    load_state
    [ -n "${REALITY_DOMAIN:-}" ] || { yellow "尚未安装。"; return 1; }

    local new_domain
    reading "请输入新的 Reality 伪装域名/SNI: " new_domain
    validate_domain "$new_domain" || { red "域名不能为空，且不能包含空格或引号。"; return 1; }

    REALITY_DOMAIN="$new_domain"
    write_config
    save_state
    restart_singbox
    show_reality_info
}

manage_singbox() {
    local singbox_status choice
    singbox_status=$(check_singbox 2>/dev/null)

    clear
    green "=== sing-box 服务管理 ===\n"
    green "当前状态: ${singbox_status}\n"
    green "1. 启动 sing-box"
    green "2. 停止 sing-box"
    green "3. 重启 sing-box"
    purple "0. 返回主菜单"
    reading "请输入选择: " choice

    case "$choice" in
        1) start_singbox ;;
        2) stop_singbox ;;
        3) restart_singbox ;;
        0) return ;;
        *) red "无效的选项" ;;
    esac
}

uninstall_singbox() {
    local choice
    reading "确定要卸载 sing-box Reality 并删除 ${work_dir} 吗？(y/n): " choice
    case "$choice" in
        y|Y)
            yellow "正在卸载 sing-box..."
            if command_exists rc-service; then
                rc-service sing-box stop >/dev/null 2>&1 || true
                rc-update del sing-box default >/dev/null 2>&1 || true
                rm -f /etc/init.d/sing-box
            fi
            if command_exists systemctl; then
                systemctl stop sing-box >/dev/null 2>&1 || true
                systemctl disable sing-box >/dev/null 2>&1 || true
                rm -f /etc/systemd/system/sing-box.service
                systemctl daemon-reload >/dev/null 2>&1 || true
            fi
            rm -rf "$work_dir"
            rm -f /usr/bin/sb
            green "sing-box 已卸载。"
            ;;
        *)
            yellow "已取消卸载。"
            ;;
    esac
}

menu() {
    local singbox_status
    singbox_status=$(check_singbox 2>/dev/null)

    clear
    purple "=== sing-box Reality-only 脚本 ===\n"
    purple "sing-box 状态: ${singbox_status}\n"
    green "1. 安装 sing-box Reality"
    green "2. 查看 Reality 参数"
    green "3. 修改 Reality 端口"
    green "4. 修改 Reality 伪装域名"
    green "5. sing-box 服务管理"
    red "6. 卸载 sing-box"
    red "0. 退出脚本"
    reading "请输入选择(0-6): " choice
}

trap 'red "已取消操作"; exit 130' INT

if [ "$auto_install" -eq 1 ]; then
    run_install_flow
    exit 0
fi

while true; do
    menu
    case "$choice" in
        1) run_install_flow ;;
        2) show_reality_info ;;
        3) change_port ;;
        4) change_reality_domain ;;
        5) manage_singbox ;;
        6) uninstall_singbox ;;
        0) exit 0 ;;
        *) red "无效的选项，请输入 0 到 6" ;;
    esac
    read -r -n 1 -s -p $'\033[1;91m按任意键返回...\033[0m'
    echo ""
done
