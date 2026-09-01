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
clear_screen() { command -v clear >/dev/null 2>&1 && clear || printf '\033c'; }

server_name="sing-box"
work_dir="/etc/sing-box"
config_dir="${work_dir}/config.json"
state_file="${work_dir}/reality.env"
users_dir="${work_dir}/users.d"
outbounds_dir="${work_dir}/outbounds.d"
forwards_dir="${work_dir}/forwards.d"
installed_script="${work_dir}/sb.sh"
reality_domain="cas-bridge.xethub.hf.co"
vless_port=""   # 由 -port 指定；实为 Reality 主入站监听端口（历史命名，非 VLESS 入站端口）
auto_install=0
reality_inbound_tag="reality-in"
vless_inbound_tag="vless-in"
ss_inbound_tag="ss-in"
direct_outbound_tag="direct"
block_outbound_tag="block"
default_user_name="default-direct"
default_flow="xtls-rprx-vision"
default_fingerprint="chrome"
default_inbound_type="vless-reality"
default_ss_method="aes-128-gcm"
imported_outbound_tag=""

usage() {
    cat << EOF
sing-box 多协议入站中转/本机节点管理脚本

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

validate_host_address() {
    # 接受 IPv4 / IPv6（带或不带方括号）/ 主机名/域名
    local addr="$1"
    [ -n "$addr" ] || return 1

    # 去掉 IPv6 方括号
    if [[ "$addr" == \[*\] ]]; then
        addr="${addr#[}"
        addr="${addr%]}"
    fi

    # 含冒号 -> 视为 IPv6（格式由 iptables 兜底校验）
    [[ "$addr" == *:* ]] && return 0

    # 否则应是主机名/域名或 IPv4：仅允许字母/数字/点/连字符/下划线，须以字母数字开头
    [[ "$addr" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] && return 0
    return 1
}

validate_domain() {
    [ -n "$1" ] || return 1
    [[ "$1" == *.* ]] || return 1
    [[ "$1" =~ ^[a-zA-Z0-9.-]+$ ]] || return 1
    return 0
}

random_port() {
    if command_exists shuf; then
        shuf -i 20000-65000 -n 1
        return
    fi

    local n
    n=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')
    [[ "$n" =~ ^[0-9]+$ ]] || n=$RANDOM
    echo $((20000 + n % 45001))
}

trim() {
    printf '%s' "$1" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

sanitize_tag() {
    local value
    value=$(trim "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g;s/--*/-/g;s/^-//;s/-$//')
    [ -n "$value" ] || value="item-$(date +%s)"
    printf '%s' "$value"
}

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

json_string() {
    printf '"%s"' "$(json_escape "$1")"
}

env_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//\$/\\\$}
    value=${value//\`/\\\`}
    value=${value//$'\n'/}
    value=${value//$'\r'/}
    printf '%s' "$value"
}

write_env_line() {
    printf '%s="%s"\n' "$1" "$(env_escape "$2")"
}

# 解析 IPv4/IPv6 地址:端口。IPv6 地址需带方括号，如 [::1]:8080
split_hostport() {
    local hp="$1" addr port
    # 去掉 authority 之后的路径（见 import_http_uri：http 链接常带末尾 / 或 /path）
    hp="${hp%%/*}"
    if [[ "$hp" == \[*\]* ]]; then
        # IPv6: [::1]:8080
        addr=${hp%%\]*}
        addr="${addr#\[}"
        port=${hp#*\]}
        port=${port#:}
    else
        # IPv4 或域名: 1.2.3.4:8080
        addr=${hp%:*}
        port=${hp##*:}
    fi
    printf '%s|%s' "$addr" "$port"
}

url_decode() {
    local value="${1//+/ }"
    printf '%b' "${value//%/\\x}" 2>/dev/null || printf '%s' "$1"
}

b64_decode() {
    local value padding decoded
    value=$(trim "$1")
    value=${value//-/+}
    value=${value//_/\/}
    padding=$(( (4 - ${#value} % 4) % 4 ))
    value="${value}$(printf '%*s' "$padding" '' | tr ' ' '=')"

    if decoded=$(printf '%s' "$value" | base64 -d 2>/dev/null); then
        [ -n "$decoded" ] || return 1
        printf '%s' "$decoded"
        return 0
    fi

    if decoded=$(printf '%s' "$value" | base64 --decode 2>/dev/null); then
        [ -n "$decoded" ] || return 1
        printf '%s' "$decoded"
        return 0
    fi

    return 1
}

get_query_param() {
    local query="$1" key="$2" pair name value
    IFS='&' read -ra pairs <<< "$query"
    for pair in "${pairs[@]}"; do
        name=${pair%%=*}
        value=${pair#*=}
        [ "$name" = "$key" ] || continue
        url_decode "$value"
        return 0
    done
    return 1
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

env_unescape() {
    local value="$1" result="" char next i
    for ((i = 0; i < ${#value}; i++)); do
        char="${value:i:1}"
        if [ "$char" = "\\" ] && [ $((i + 1)) -lt "${#value}" ]; then
            i=$((i + 1))
            next="${value:i:1}"
            case "$next" in
                \\|\"|\$|\`) result="${result}${next}" ;;
                *) result="${result}\\${next}" ;;
            esac
        else
            result="${result}${char}"
        fi
    done
    printf '%s' "$result"
}

read_env_value() {
    local file="$1" key="$2" line value
    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key="*)
                value=${line#"$key="}
                if [[ "$value" == \"* ]]; then
                    value=${value#\"}
                    value=${value%\"}
                fi
                env_unescape "$value"
                return 0
                ;;
        esac
    done < "$file"
    return 1
}

load_state() {
    [ -f "$state_file" ] || return 1
    PORT=$(read_env_value "$state_file" PORT || true)
    REALITY_DOMAIN=$(read_env_value "$state_file" REALITY_DOMAIN || true)
    PRIVATE_KEY=$(read_env_value "$state_file" PRIVATE_KEY || true)
    PUBLIC_KEY=$(read_env_value "$state_file" PUBLIC_KEY || true)
    SHORT_ID=$(read_env_value "$state_file" SHORT_ID || true)
}

save_state() {
    mkdir -p "$work_dir"
    {
        write_env_line PORT "${PORT:-}"
        write_env_line REALITY_DOMAIN "${REALITY_DOMAIN:-}"
        write_env_line PRIVATE_KEY "${PRIVATE_KEY:-}"
        write_env_line PUBLIC_KEY "${PUBLIC_KEY:-}"
        write_env_line SHORT_ID "${SHORT_ID:-}"
    } > "$state_file"
    chmod 600 "$state_file"
}

ensure_state_layout() {
    mkdir -p "$work_dir" "$users_dir" "$outbounds_dir" "$forwards_dir"
    chmod 755 "$work_dir"
    chmod 700 "$users_dir" "$outbounds_dir" "$forwards_dir"
}

user_file() {
    printf '%s/%s.env' "$users_dir" "$(sanitize_tag "$1")"
}

outbound_file() {
    printf '%s/%s.env' "$outbounds_dir" "$(sanitize_tag "$1")"
}

forward_file() {
    printf '%s/%s.env' "$forwards_dir" "$(sanitize_tag "$1")"
}

forward_service_name() {
    printf 'sing-box-forward-%s' "$(sanitize_tag "$1")"
}

has_users() {
    local file
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] && return 0
    done
    return 1
}

user_exists() {
    [ -f "$(user_file "$1")" ]
}

outbound_exists() {
    { [ "$1" = "$direct_outbound_tag" ] || [ "$1" = "$block_outbound_tag" ]; } && return 0
    [ -f "$(outbound_file "$1")" ]
}

inbound_port_in_use() {
    local port="$1" skip_user="${2:-}" file
    [ "$port" = "$PORT" ] && return 0
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        [ "$NAME" = "$skip_user" ] && continue
        [ "$INBOUND_TYPE" = "vless-reality" ] && continue
        [ "$INBOUND_PORT" = "$port" ] && return 0
    done
    return 1
}

validate_new_outbound_tag() {
    local tag="$1"
    [ -n "$tag" ] || { red "tag 不能为空"; return 1; }
    [ "$tag" != "$direct_outbound_tag" ] && [ "$tag" != "$block_outbound_tag" ] || { red "不能使用内置 tag: $tag"; return 1; }
    outbound_exists "$tag" && { red "outbound 已存在: $tag"; return 1; }
    return 0
}

prepare_import_base() {
    imported_outbound_tag=""
}
load_user_file() {
    local file="$1"
    [ -f "$file" ] || return 1
    case "$file" in
        "$users_dir"/*.env) ;;
        *) return 1 ;;
    esac
    # 保证 Reality 用户端口解析前 PORT 已加载（避免在 load_state 之前调用时的空端口）
    [ -n "$PORT" ] || load_state
    unset NAME UUID FLOW OUTBOUND_TAG INBOUND_TYPE INBOUND_PORT METHOD PASSWORD
    NAME=$(read_env_value "$file" NAME || true)
    UUID=$(read_env_value "$file" UUID || true)
    FLOW=$(read_env_value "$file" FLOW || true)
    OUTBOUND_TAG=$(read_env_value "$file" OUTBOUND_TAG || true)
    INBOUND_TYPE=$(read_env_value "$file" INBOUND_TYPE || true)
    INBOUND_PORT=$(read_env_value "$file" INBOUND_PORT || true)
    METHOD=$(read_env_value "$file" METHOD || true)
    PASSWORD=$(read_env_value "$file" PASSWORD || true)
    FLOW="${FLOW:-$default_flow}"
    OUTBOUND_TAG="${OUTBOUND_TAG:-$direct_outbound_tag}"
    INBOUND_TYPE="${INBOUND_TYPE:-$default_inbound_type}"
    if [ "$INBOUND_TYPE" = "vless-reality" ]; then
        INBOUND_PORT="$PORT"
    else
        # 非 Reality 用户必须显式指定端口：缺省时不再回退到主端口，避免与主端口绑定冲突，
        # 渲染时会被 validate_port 跳过而非静默抢占主端口。
        INBOUND_PORT="${INBOUND_PORT:-}"
    fi
    METHOD="${METHOD:-$default_ss_method}"
}

load_outbound_file() {
    local file="$1"
    [ -f "$file" ] || return 1
    case "$file" in
        "$outbounds_dir"/*.env) ;;
        *) return 1 ;;
    esac
    unset TAG TYPE DISPLAY_NAME SERVER SERVER_PORT USERNAME PASSWORD METHOD \
          PLUGIN PLUGIN_OPTS OUT_UUID UUID FLOW NETWORK \
          TLS_ENABLED TLS_SERVER_NAME TLS_INSECURE \
          REALITY_ENABLED REALITY_PUBLIC_KEY REALITY_SHORT_ID UTLS_FINGERPRINT
    TAG=$(read_env_value "$file" TAG || true)
    TYPE=$(read_env_value "$file" TYPE || true)
    DISPLAY_NAME=$(read_env_value "$file" DISPLAY_NAME || true)
    SERVER=$(read_env_value "$file" SERVER || true)
    SERVER_PORT=$(read_env_value "$file" SERVER_PORT || true)
    USERNAME=$(read_env_value "$file" USERNAME || true)
    PASSWORD=$(read_env_value "$file" PASSWORD || true)
    METHOD=$(read_env_value "$file" METHOD || true)
    PLUGIN=$(read_env_value "$file" PLUGIN || true)
    PLUGIN_OPTS=$(read_env_value "$file" PLUGIN_OPTS || true)
    OUT_UUID=$(read_env_value "$file" OUT_UUID || true)
    UUID=$(read_env_value "$file" UUID || true)
    FLOW=$(read_env_value "$file" FLOW || true)
    NETWORK=$(read_env_value "$file" NETWORK || true)
    TLS_ENABLED=$(read_env_value "$file" TLS_ENABLED || true)
    TLS_SERVER_NAME=$(read_env_value "$file" TLS_SERVER_NAME || true)
    TLS_INSECURE=$(read_env_value "$file" TLS_INSECURE || true)
    REALITY_ENABLED=$(read_env_value "$file" REALITY_ENABLED || true)
    REALITY_PUBLIC_KEY=$(read_env_value "$file" REALITY_PUBLIC_KEY || true)
    REALITY_SHORT_ID=$(read_env_value "$file" REALITY_SHORT_ID || true)
    UTLS_FINGERPRINT=$(read_env_value "$file" UTLS_FINGERPRINT || true)
    OUT_UUID="${OUT_UUID:-${UUID:-}}"
    NETWORK="${NETWORK:-tcp}"
    TLS_ENABLED="${TLS_ENABLED:-0}"
    TLS_INSECURE="${TLS_INSECURE:-0}"
    REALITY_ENABLED="${REALITY_ENABLED:-0}"
}

save_user() {
    local name="$1" uuid="$2" outbound_tag="$3" flow="${4:-$default_flow}" inbound_type="${5:-$default_inbound_type}" password="${6:-}" method="${7:-$default_ss_method}" inbound_port="${8:-$PORT}" file
    name=$(sanitize_tag "$name")
    file=$(user_file "$name")
    {
        write_env_line NAME "$name"
        write_env_line UUID "$uuid"
        write_env_line FLOW "$flow"
        write_env_line OUTBOUND_TAG "$outbound_tag"
        write_env_line INBOUND_TYPE "$inbound_type"
        write_env_line INBOUND_PORT "$inbound_port"
        write_env_line METHOD "$method"
        write_env_line PASSWORD "$password"
    } > "$file"
    chmod 600 "$file"
}

save_socks_outbound() {
    local tag="$1" display_name="$2" server="$3" server_port="$4" username="$5" password="$6" file
    tag=$(sanitize_tag "$tag")
    file=$(outbound_file "$tag")
    {
        write_env_line TAG "$tag"
        write_env_line TYPE "socks"
        write_env_line DISPLAY_NAME "$display_name"
        write_env_line SERVER "$server"
        write_env_line SERVER_PORT "$server_port"
        write_env_line USERNAME "$username"
        write_env_line PASSWORD "$password"
    } > "$file"
    chmod 600 "$file"
}

save_http_outbound() {
    local tag="$1" display_name="$2" server="$3" server_port="$4" username="$5" password="$6" tls_enabled="${7:-0}" file
    tag=$(sanitize_tag "$tag")
    file=$(outbound_file "$tag")
    {
        write_env_line TAG "$tag"
        write_env_line TYPE "http"
        write_env_line DISPLAY_NAME "$display_name"
        write_env_line SERVER "$server"
        write_env_line SERVER_PORT "$server_port"
        write_env_line USERNAME "$username"
        write_env_line PASSWORD "$password"
        write_env_line TLS_ENABLED "$tls_enabled"
    } > "$file"
    chmod 600 "$file"
}

save_shadowsocks_outbound() {
    local tag="$1" display_name="$2" server="$3" server_port="$4" method="$5" password="$6" plugin="$7" plugin_opts="$8" file
    tag=$(sanitize_tag "$tag")
    file=$(outbound_file "$tag")
    {
        write_env_line TAG "$tag"
        write_env_line TYPE "shadowsocks"
        write_env_line DISPLAY_NAME "$display_name"
        write_env_line SERVER "$server"
        write_env_line SERVER_PORT "$server_port"
        write_env_line METHOD "$method"
        write_env_line PASSWORD "$password"
        write_env_line PLUGIN "$plugin"
        write_env_line PLUGIN_OPTS "$plugin_opts"
    } > "$file"
    chmod 600 "$file"
}

save_vless_outbound() {
    local tag="$1" display_name="$2" server="$3" server_port="$4" uuid="$5"
    local flow="${6:-}" network="${7:-tcp}" tls_enabled="${8:-0}"
    local tls_server_name="${9:-}" tls_insecure="${10:-0}" utls_fingerprint="${11:-}"
    local file
    tag=$(sanitize_tag "$tag")
    file=$(outbound_file "$tag")
    {
        write_env_line TAG "$tag"
        write_env_line TYPE "vless"
        write_env_line DISPLAY_NAME "$display_name"
        write_env_line SERVER "$server"
        write_env_line SERVER_PORT "$server_port"
        write_env_line UUID "$uuid"
        write_env_line FLOW "$flow"
        write_env_line NETWORK "$network"
        write_env_line TLS_ENABLED "$tls_enabled"
        write_env_line TLS_SERVER_NAME "$tls_server_name"
        write_env_line TLS_INSECURE "$tls_insecure"
        write_env_line REALITY_ENABLED "0"
        write_env_line UTLS_FINGERPRINT "$utls_fingerprint"
    } > "$file"
    chmod 600 "$file"
}

migrate_legacy_state() {
    load_state

    [ -f "$state_file" ] || return 1
    [ -n "${PORT:-}" ] && [ -n "${REALITY_DOMAIN:-}" ] && [ -n "${PRIVATE_KEY:-}" ] && [ -n "${PUBLIC_KEY:-}" ] && [ -n "${SHORT_ID:-}" ] || return 1

    ensure_state_layout
    if ! has_users; then
        local legacy_uuid
        legacy_uuid=$(read_env_value "$state_file" UUID || true)
        [ -n "$legacy_uuid" ] || legacy_uuid=$(generate_uuid)
        save_user "$default_user_name" "$legacy_uuid" "$direct_outbound_tag" "$default_flow" "$default_inbound_type" "" "$default_ss_method" "$PORT"
    fi
}

require_reality_state() {
    migrate_legacy_state || {
        yellow "尚未安装，请先选择 1 安装 / 初始化节点。"
        return 1
    }
}

validate_config_file() {
    local file="$1" check_output

    if ! is_working_singbox "${work_dir}/${server_name}"; then
        [ -f "$config_dir" ] && yellow "sing-box 二进制不可用，跳过配置预校验。"
        return 0
    fi
    check_output=$("${work_dir}/${server_name}" check -c "$file" 2>&1) && return 0

    if printf '%s' "$check_output" | grep -qiE 'unknown command|unknown flag|flag provided but not defined|No help topic'; then
        yellow "当前 sing-box 不支持 check -c，跳过配置预校验。"
        return 0
    fi

    red "sing-box 配置校验失败："
    red "$check_output"
    return 1
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

ensure_alpine_compat() {
    command_exists apk || return 0

    yellow "检测到 Alpine，安装 glibc 兼容库以支持上游 sing-box 二进制..."
    apk add --no-cache gcompat libc6-compat libstdc++ >/dev/null 2>&1 || yellow "兼容库安装失败，将继续尝试。"
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
            cp "$candidate" "${work_dir}/${server_name}" || { yellow "复制 sing-box 失败: $candidate"; continue; }
            chmod +x "${work_dir}/${server_name}"
            is_working_singbox "${work_dir}/${server_name}" || { yellow "复制后的 sing-box 不可执行，继续尝试下一个候选..."; continue; }
        fi
        green "使用本机已安装的 sing-box: $candidate"
        return 0
    done

    return 1
}

install_singbox_from_package() {
    command_exists apk || return 1

    yellow "未发现可用的本机 sing-box，尝试通过 apk 安装 sing-box..."
    apk add --no-cache sing-box || apk add --no-cache sing-box-openrc || return 1
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
    ensure_alpine_compat

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
        ensure_alpine_compat
    fi

    if ! is_working_singbox "${work_dir}/${server_name}"; then
        red "下载的 sing-box 无法在当前系统执行。"
        red "请先用系统包管理器安装 sing-box 后重试；Alpine 可尝试执行: apk add --no-cache sing-box sing-box-openrc gcompat libc6-compat"
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

generate_password() {
    if command_exists openssl; then
        openssl rand -base64 32 | tr -d '\n'
        return
    fi
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

generate_reality_values() {
    local output

    output=$("${work_dir}/${server_name}" generate reality-keypair)
    PRIVATE_KEY=$(echo "$output" | awk '/PrivateKey:/ {print $2}')
    PUBLIC_KEY=$(echo "$output" | awk '/PublicKey:/ {print $2}')
    SHORT_ID=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')

    [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] && [ -n "$SHORT_ID" ] || {
        red "生成 Reality 参数失败"
        exit 1
    }
}

render_vless_reality_users_json() {
    local file first=1 name uuid flow inbound_type
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        name="$NAME"
        uuid="$UUID"
        flow="$FLOW"
        inbound_type="$INBOUND_TYPE"
        [ "$inbound_type" = "vless-reality" ] || continue
        [ -n "$name" ] && [ -n "$uuid" ] || continue
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        printf '        {\n'
        printf '          "name": %s,\n' "$(json_string "$name")"
        printf '          "uuid": %s,\n' "$(json_string "$uuid")"
        printf '          "flow": %s\n' "$(json_string "${flow:-$default_flow}")"
        printf '        }'
    done
}

inbound_tag_for_user() {
    local name="$1" inbound_type="$2"
    case "$inbound_type" in
        vless) printf '%s-%s' "$vless_inbound_tag" "$name" ;;
        shadowsocks) printf '%s-%s' "$ss_inbound_tag" "$name" ;;
        *) printf '%s' "$reality_inbound_tag" ;;
    esac
}

has_inbound_type() {
    local wanted_type="$1" file
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        [ "$INBOUND_TYPE" = "$wanted_type" ] || continue
        case "$wanted_type" in
            shadowsocks)
                [ -n "$NAME" ] && [ -n "$PASSWORD" ] && validate_port "$INBOUND_PORT" && return 0
                ;;
            *)
                [ -n "$NAME" ] && [ -n "$UUID" ] && validate_port "$INBOUND_PORT" && return 0
                ;;
        esac
    done
    return 1
}

render_inbounds_json() {
    local file first=1 name uuid inbound_type inbound_port inbound_tag password method
    if has_inbound_type "vless-reality"; then
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        cat << EOF
    {
      "type": "vless",
      "tag": "${reality_inbound_tag}",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
$(render_vless_reality_users_json)
      ],
      "tls": {
        "enabled": true,
        "server_name": "$(json_escape "$REALITY_DOMAIN")",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$(json_escape "$REALITY_DOMAIN")",
            "server_port": 443
          },
          "private_key": "$(json_escape "$PRIVATE_KEY")",
          "short_id": [
            "$(json_escape "$SHORT_ID")"
          ]
        }
      }
    }
EOF
    fi

    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        name="$NAME"
        uuid="$UUID"
        inbound_type="$INBOUND_TYPE"
        inbound_port="$INBOUND_PORT"
        inbound_tag=$(inbound_tag_for_user "$name" "$inbound_type")
        case "$inbound_type" in
            vless)
                [ -n "$name" ] && [ -n "$uuid" ] && validate_port "$inbound_port" || continue
                [ "$first" -eq 1 ] || printf ',\n'
                first=0
                cat << EOF
    {
      "type": "vless",
      "tag": "${inbound_tag}",
      "listen": "::",
      "listen_port": ${inbound_port},
      "users": [
        {
          "name": $(json_string "$name"),
          "uuid": $(json_string "$uuid")
        }
      ]
    }
EOF
                ;;
            shadowsocks)
                password="$PASSWORD"
                method="${METHOD:-$default_ss_method}"
                [ -n "$name" ] && [ -n "$password" ] && validate_port "$inbound_port" || continue
                [ "$first" -eq 1 ] || printf ',\n'
                first=0
                cat << EOF
    {
      "type": "shadowsocks",
      "tag": "${inbound_tag}",
      "listen": "::",
      "listen_port": ${inbound_port},
      "method": $(json_string "$method"),
      "password": $(json_string "$password")
    }
EOF
                ;;
        esac
    done
}

render_outbound_json() {
    local file first=0 tag type display server server_port username password method plugin plugin_opts
    printf '    {\n      "type": "direct",\n      "tag": %s\n    },\n' "$(json_string "$direct_outbound_tag")"
    printf '    {\n      "type": "block",\n      "tag": %s\n    }' "$(json_string "$block_outbound_tag")"

    for file in "$outbounds_dir"/*.env; do
        [ -f "$file" ] || continue
        load_outbound_file "$file" || continue
        tag="$TAG"
        type="$TYPE"
        server="$SERVER"
        server_port="$SERVER_PORT"
        [ -n "$tag" ] && [ -n "$type" ] || continue
        case "$type" in
            socks|http)
                [ -n "$server" ] && validate_port "$server_port" || continue
                ;;
            shadowsocks)
                [ -n "$server" ] && [ -n "$METHOD" ] && [ -n "$PASSWORD" ] && validate_port "$server_port" || continue
                ;;
            vless)
                [ -n "$server" ] && [ -n "$OUT_UUID" ] && validate_port "$server_port" || continue
                ;;
            *)
                continue
                ;;
        esac
        printf ',\n'
        case "$type" in
            socks|http)
                printf '    {\n'
                printf '      "type": %s,\n' "$(json_string "$type")"
                printf '      "tag": %s,\n' "$(json_string "$tag")"
                printf '      "server": %s,\n' "$(json_string "$server")"
                printf '      "server_port": %s' "$server_port"
                [ "$type" = "socks" ] && printf ',\n      "version": "5"'
                [ -n "$USERNAME" ] && printf ',\n      "username": %s' "$(json_string "$USERNAME")"
                [ -n "$PASSWORD" ] && printf ',\n      "password": %s' "$(json_string "$PASSWORD")"
                if [ "$type" = "http" ] && [ "$TLS_ENABLED" = "1" ]; then
                    printf ',\n      "tls": {\n        "enabled": true\n      }'
                fi
                printf '\n    }'
                ;;
            shadowsocks)
                printf '    {\n'
                printf '      "type": "shadowsocks",\n'
                printf '      "tag": %s,\n' "$(json_string "$tag")"
                printf '      "server": %s,\n' "$(json_string "$server")"
                printf '      "server_port": %s,\n' "$server_port"
                printf '      "method": %s,\n' "$(json_string "$METHOD")"
                printf '      "password": %s' "$(json_string "$PASSWORD")"
                [ -n "$PLUGIN" ] && printf ',\n      "plugin": %s' "$(json_string "$PLUGIN")"
                [ -n "$PLUGIN_OPTS" ] && printf ',\n      "plugin_opts": %s' "$(json_string "$PLUGIN_OPTS")"
                printf '\n    }'
                ;;
            vless)
                printf '    {\n'
                printf '      "type": "vless",\n'
                printf '      "tag": %s,\n' "$(json_string "$tag")"
                printf '      "server": %s,\n' "$(json_string "$server")"
                printf '      "server_port": %s,\n' "$server_port"
                printf '      "uuid": %s' "$(json_string "$OUT_UUID")"
                [ -n "$FLOW" ] && printf ',\n      "flow": %s' "$(json_string "$FLOW")"
                printf ',\n      "network": %s' "$(json_string "$NETWORK")"
                if [ "$TLS_ENABLED" = "1" ]; then
                    printf ',\n      "tls": {\n        "enabled": true'
                    [ -n "$TLS_SERVER_NAME" ] && printf ',\n        "server_name": %s' "$(json_string "$TLS_SERVER_NAME")"
                    [ "$TLS_INSECURE" = "1" ] && printf ',\n        "insecure": true'
                    if [ -n "$UTLS_FINGERPRINT" ]; then
                        printf ',\n        "utls": {\n          "enabled": true,\n          "fingerprint": %s\n        }' "$(json_string "$UTLS_FINGERPRINT")"
                    fi
                    if [ "$REALITY_ENABLED" = "1" ]; then
                        printf ',\n        "reality": {\n          "enabled": true,\n          "public_key": %s' "$(json_string "$REALITY_PUBLIC_KEY")"
                        [ -n "$REALITY_SHORT_ID" ] && printf ',\n          "short_id": %s' "$(json_string "$REALITY_SHORT_ID")"
                        printf '\n        }'
                    fi
                    printf '\n      }'
                fi
                printf '\n    }'
                ;;
        esac
    done
}

render_route_rules_json() {
    local file first=1 name outbound_tag inbound_tag inbound_type fallback_inbounds="" fallback_seen=""
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        name="$NAME"
        outbound_tag="$OUTBOUND_TAG"
        inbound_type="$INBOUND_TYPE"
        inbound_tag=$(inbound_tag_for_user "$name" "$inbound_type")
        [ -n "$name" ] || continue
        case "|$fallback_seen|" in
            *"|$inbound_tag|"*) ;;
            *)
                if [ -n "$fallback_inbounds" ]; then
                    fallback_inbounds="${fallback_inbounds}, $(json_string "$inbound_tag")"
                else
                    fallback_inbounds=$(json_string "$inbound_tag")
                fi
                fallback_seen="${fallback_seen}|${inbound_tag}"
                ;;
        esac
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        printf '      {\n'
        printf '        "inbound": [%s],\n' "$(json_string "$inbound_tag")"
        if [ "$inbound_type" = "vless-reality" ]; then
            printf '        "auth_user": [%s],\n' "$(json_string "$name")"
        fi
        printf '        "action": "route",\n'
        printf '        "outbound": %s\n' "$(json_string "$outbound_tag")"
        printf '      }'
    done

    if [ -n "$fallback_inbounds" ]; then
        [ "$first" -eq 1 ] || printf ',\n'
        printf '      {\n'
        printf '        "inbound": [%s],\n' "$fallback_inbounds"
        printf '        "action": "route",\n'
        printf '        "outbound": %s\n' "$(json_string "$block_outbound_tag")"
        printf '      }'
    fi
}

write_config() {
    local tmp_config="${config_dir}.tmp"
    ensure_state_layout
    load_state

    cat > "$tmp_config" << EOF
{
  "log": {
    "level": "warn",
    "output": "${work_dir}/sing-box.log",
    "timestamp": true
  },
  "inbounds": [
$(render_inbounds_json)
  ],
  "outbounds": [
$(render_outbound_json)
  ],
  "route": {
    "rules": [
$(render_route_rules_json)
    ],
    "final": "${direct_outbound_tag}"
  }
}
EOF

    if ! validate_config_file "$tmp_config"; then
        rm -f "$tmp_config"
        return 1
    fi

    mv "$tmp_config" "$config_dir"
    chmod 600 "$config_dir"
}

apply_config() {
    write_config || return 1
    restart_singbox || return 2
}

apply_config_or_remove() {
    local file="$1" status
    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        rm -f "$file"
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi
}

apply_config_or_restore() {
    local target="$1" backup="$2" status
    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        if [ -f "$backup" ]; then
            mv "$backup" "$target"
        else
            rm -f "$target"
        fi
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi
    rm -f "$backup"
}

allow_port() {
    local port="$1" protocol="${2:-tcp}" proto_flag

    yellow "尝试放行端口 ${port}（${protocol}）..."
    for proto_flag in $protocol; do
        command_exists ufw && ufw allow "${port}/${proto_flag}" >/dev/null 2>&1 || true
        command_exists firewall-cmd && firewall-cmd --permanent --add-port="${port}/${proto_flag}" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 || true
        command_exists iptables && iptables -C INPUT -p "$proto_flag" --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p "$proto_flag" --dport "$port" -j ACCEPT 2>/dev/null || true
        command_exists ip6tables && ip6tables -C INPUT -p "$proto_flag" --dport "$port" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p "$proto_flag" --dport "$port" -j ACCEPT 2>/dev/null || true
    done
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

install_logrotate() {
    [ -d /etc/logrotate.d ] || return 0
    cat > /etc/logrotate.d/sing-box << EOF
${work_dir}/sing-box.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    chmod 644 /etc/logrotate.d/sing-box
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

user_link() {
    local uuid="$1" name="$2" flow="$3" server_ip="$4" inbound_type="${5:-$default_inbound_type}" password="${6:-}" method="${7:-$default_ss_method}" inbound_port="${8:-$PORT}" link userinfo
    load_state
    [ -n "$server_ip" ] || server_ip=$(get_server_ip)
    case "$inbound_type" in
        vless)
            link="vless://${uuid}@${server_ip}:${inbound_port}?encryption=none&security=none&type=tcp&headerType=none#${name}"
            ;;
        shadowsocks)
            userinfo=$(printf '%s:%s' "$method" "$password" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
            link="ss://${userinfo}@${server_ip}:${inbound_port}#${name}"
            ;;
        *)
            link="vless://${uuid}@${server_ip}:${PORT}?encryption=none&flow=${flow:-$default_flow}&security=reality&sni=${REALITY_DOMAIN}&fp=${default_fingerprint}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${name}"
            ;;
    esac
    printf '%s' "$link"
}

list_outbounds() {
    local file
    green "\n=== 落地 outbound ==="
    purple "direct | 本机直连 | 内置"
    for file in "$outbounds_dir"/*.env; do
        [ -f "$file" ] || continue
        load_outbound_file "$file" || continue
        [ -n "$TAG" ] && [ -n "$TYPE" ] || continue
        purple "${TAG} | ${TYPE} | ${DISPLAY_NAME:-$SERVER:$SERVER_PORT}"
    done
}

list_users() {
    local file
    green "\n=== 入站用户 ==="
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        [ -n "$NAME" ] || continue
        [ "$INBOUND_TYPE" = "shadowsocks" ] && [ -z "$PASSWORD" ] && continue
        [ "$INBOUND_TYPE" != "shadowsocks" ] && [ -z "$UUID" ] && continue
        purple "${NAME} | $(inbound_label "$INBOUND_TYPE") | port=${INBOUND_PORT} | outbound=${OUTBOUND_TAG}"
    done
}

show_reality_info() {
    require_reality_state || return 1

    load_state
    local file link server_ip
    server_ip=$(get_server_ip)

    green "\n节点参数："
    purple "地址: ${server_ip}"
    purple "端口: ${PORT}"
    purple "Reality SNI/伪装域名: ${REALITY_DOMAIN}"
    purple "Reality PublicKey: ${PUBLIC_KEY}"
    purple "Reality ShortID: ${SHORT_ID}"
    purple "Reality Fingerprint: ${default_fingerprint}"

    list_users
    yellow "\n用户链接："
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        [ -n "$NAME" ] || continue
        link=$(user_link "$UUID" "$NAME" "$FLOW" "$server_ip" "$INBOUND_TYPE" "$PASSWORD" "$METHOD" "$INBOUND_PORT")
        purple "${NAME} ($(inbound_label "$INBOUND_TYPE")) -> ${OUTBOUND_TAG}"
        purple "$link\n"
    done
}

show_singbox_logs() {
    local log_file="${work_dir}/sing-box.log"

    clear_screen
    green "=== sing-box 日志 ===\n"

    if [ -s "$log_file" ]; then
        yellow "最近 200 行文件日志: $log_file\n"
        tail -n 200 "$log_file"
        return 0
    fi

    if command_exists journalctl && command_exists systemctl && [ -f /etc/systemd/system/sing-box.service ]; then
        yellow "未找到文件日志，显示最近 200 行 systemd journal 日志。\n"
        journalctl -u sing-box -n 200 --no-pager
        return 0
    fi

    if command_exists rc-service && [ -f /etc/init.d/sing-box ]; then
        yellow "未找到文件日志。OpenRC 可尝试查看系统日志中的 sing-box 记录。"
        if [ -f /var/log/messages ]; then
            tail -n 200 /var/log/messages | grep -i 'sing-box' || true
        elif [ -f /var/log/syslog ]; then
            tail -n 200 /var/log/syslog | grep -i 'sing-box' || true
        else
            yellow "未发现 /var/log/messages 或 /var/log/syslog。"
        fi
        return 0
    fi

    yellow "暂无日志。请先安装并启动 sing-box。"
}

create_shortcut() {
    mkdir -p "$work_dir"

    cat > "$installed_script" << 'EOF'
#!/usr/bin/env bash
url="https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh"
tmp=$(mktemp) || { echo "创建临时文件失败" >&2; exit 1; }
trap 'rm -f "$tmp"' EXIT

if ! curl -fsSL "$url" -o "$tmp"; then
    echo "拉取 sing-box.sh 失败，请检查网络或稍后重试。" >&2
    exit 1
fi

if [ ! -s "$tmp" ]; then
    echo "拉取到的 sing-box.sh 为空，请稍后重试。" >&2
    exit 1
fi

bash "$tmp" "$@"
EOF

    chmod +x "$installed_script"
    cat > /usr/bin/sb << EOF
#!/usr/bin/env bash
if [ "\${EUID:-\$(id -u)}" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo bash "${installed_script}" "\$@"
    fi
    if command -v doas >/dev/null 2>&1; then
        exec doas bash "${installed_script}" "\$@"
    fi
    echo "请在 root 用户下运行 sb（例如：sudo sb）。" >&2
    exit 1
fi
export SB_SHORTCUT_INSTALLING=1
exec bash "${installed_script}" "\$@"
EOF
    chmod +x /usr/bin/sb
    green "快捷指令 sb 创建成功，后续可输入 sb 打开脚本。"
}

run_install_flow() {
    local uuid
    if [ -f "$state_file" ] && [ -x "${work_dir}/${server_name}" ]; then
        yellow "sing-box 已安装。"
        migrate_legacy_state
        write_config || return 1
        allow_port "$PORT"
        install_service
        install_logrotate
        show_reality_info
        create_shortcut
        return 0
    fi

    clear_screen
    purple "正在安装 sing-box 多协议入站中转/本机节点..."
    ensure_dependencies
    install_singbox_binary
    ensure_state_layout

    PORT="$vless_port"
    REALITY_DOMAIN="$reality_domain"
    generate_reality_values
    save_state
    if [ "$auto_install" -eq 1 ]; then
        use_default_inbound_profile
    else
        select_inbound_profile || exit 1
    fi
    uuid=$(generate_uuid)
    save_selected_user "$default_user_name" "$uuid" "$direct_outbound_tag"
    write_config || exit 1
    allow_port "$SELECTED_INBOUND_PORT"
    install_service
    install_logrotate
    create_shortcut
    show_reality_info
}

change_port() {
    load_state
    [ -n "${PORT:-}" ] || { yellow "尚未安装。"; return 1; }

    local new_port old_port status file
    old_port="$PORT"
    reading "请输入新的 Reality 端口（回车随机）: " new_port
    [ -n "$new_port" ] || new_port=$(random_port)
    validate_port "$new_port" || { red "端口范围需在 1-65535"; return 1; }

    if [ "$new_port" = "$old_port" ]; then
        yellow "端口未变化。"
        return 0
    fi

    if inbound_port_in_use "$new_port"; then
        red "端口已被普通 VLESS/SS 入站占用: $new_port"
        return 1
    fi

    # 避免与 TCP/UDP 转发规则的本地监听端口冲突（与 add_forward 的检查对称）
    for file in "$forwards_dir"/*.env; do
        [ -f "$file" ] || continue
        load_forward_file "$file" || continue
        [ "$LOCAL_PORT" = "$new_port" ] && { red "端口 ${new_port} 已被转发规则 \"${TAG}\" 占用"; return 1; }
    done

    PORT="$new_port"
    save_state
    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        PORT="$old_port"
        save_state
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi
    allow_port "$PORT"
    show_reality_info
}

change_reality_domain() {
    load_state
    [ -n "${REALITY_DOMAIN:-}" ] || { yellow "尚未安装。"; return 1; }

    local new_domain old_domain status
    old_domain="$REALITY_DOMAIN"
    reading "请输入新的 Reality 伪装域名/SNI: " new_domain
    validate_domain "$new_domain" || { red "域名需为包含点的 FQDN，且只能包含字母、数字、点或连字符。"; return 1; }

    REALITY_DOMAIN="$new_domain"
    if [ "$REALITY_DOMAIN" = "$old_domain" ]; then
        yellow "Reality 伪装域名未变化。"
        return 0
    fi

    save_state
    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        REALITY_DOMAIN="$old_domain"
        save_state
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi
    show_reality_info
}

select_inbound_type() {
    local choice
    green "\n请选择入站协议："
    purple "1. VLESS + Reality（推荐，当前默认配置）"
    purple "2. VLESS（无 Reality/TLS）"
    purple "3. Shadowsocks"
    reading "请输入编号（默认 1）: " choice
    case "${choice:-1}" in
        1) SELECTED_INBOUND_TYPE="vless-reality" ;;
        2) SELECTED_INBOUND_TYPE="vless" ;;
        3) SELECTED_INBOUND_TYPE="shadowsocks" ;;
        *) red "无效的入站协议。"; return 1 ;;
    esac
}

inbound_label() {
    case "$1" in
        vless) printf 'VLESS' ;;
        shadowsocks) printf 'SS' ;;
        *) printf 'VLESS+Reality' ;;
    esac
}

select_inbound_port() {
    local inbound_type="$1" port
    if [ "$inbound_type" = "vless-reality" ]; then
        SELECTED_INBOUND_PORT="$PORT"
        return 0
    fi
    reading "请输入入站监听端口（留空随机）: " port
    [ -n "$port" ] || port=$(random_port)
    validate_port "$port" || { red "端口范围需在 1-65535"; return 1; }
    if inbound_port_in_use "$port"; then
        red "端口已被现有入站占用: $port"
        return 1
    fi
    SELECTED_INBOUND_PORT="$port"
}

select_inbound_profile() {
    select_inbound_type || return 1
    select_inbound_port "$SELECTED_INBOUND_TYPE" || return 1
    SELECTED_INBOUND_PASSWORD=""
    SELECTED_INBOUND_METHOD="$default_ss_method"
    if [ "$SELECTED_INBOUND_TYPE" = "shadowsocks" ]; then
        reading "请输入 SS 入站密码（留空自动生成）: " SELECTED_INBOUND_PASSWORD
        [ -n "$SELECTED_INBOUND_PASSWORD" ] || SELECTED_INBOUND_PASSWORD=$(generate_password)
    fi
}

use_default_inbound_profile() {
    SELECTED_INBOUND_TYPE="$default_inbound_type"
    SELECTED_INBOUND_PORT="$PORT"
    SELECTED_INBOUND_PASSWORD=""
    SELECTED_INBOUND_METHOD="$default_ss_method"
}

save_selected_user() {
    save_user "$1" "$2" "$3" "$default_flow" "$SELECTED_INBOUND_TYPE" "$SELECTED_INBOUND_PASSWORD" "$SELECTED_INBOUND_METHOD" "$SELECTED_INBOUND_PORT"
}

create_bound_user_for_outbound() {
    local outbound_tag="$1" name uuid user_path outbound_path status
    name=$(sanitize_tag "$outbound_tag")
    if user_exists "$name"; then
        name="${name}-$(date +%s)"
    fi

    use_default_inbound_profile
    uuid=$(generate_uuid)
    save_selected_user "$name" "$uuid" "$outbound_tag"
    user_path=$(user_file "$name")
    outbound_path=$(outbound_file "$outbound_tag")

    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        rm -f "$user_path" "$outbound_path"
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi

    allow_port "$SELECTED_INBOUND_PORT"
    green "已添加落地并自动绑定用户：${name} -> ${outbound_tag} ($(inbound_label "$SELECTED_INBOUND_TYPE"), port=${SELECTED_INBOUND_PORT})"
    purple "$(user_link "$uuid" "$name" "$default_flow" "" "$SELECTED_INBOUND_TYPE" "$SELECTED_INBOUND_PASSWORD" "$SELECTED_INBOUND_METHOD" "$SELECTED_INBOUND_PORT")\n"
}

add_socks_outbound() {
    local tag display_name server server_port username password
    require_reality_state || return 1
    reading "请输入落地 tag（英文/数字）: " tag
    tag=$(sanitize_tag "$tag")
    validate_new_outbound_tag "$tag" || return 1
    reading "请输入显示名称（可留空）: " display_name
    [ -n "$display_name" ] || display_name="$tag"
    reading "请输入 SOCKS5 服务器地址: " server
    [ -n "$server" ] || { red "服务器不能为空"; return 1; }
    reading "请输入 SOCKS5 端口: " server_port
    validate_port "$server_port" || { red "端口范围需在 1-65535"; return 1; }
    reading "请输入 SOCKS5 用户名: " username
    reading "请输入 SOCKS5 密码: " password

    save_socks_outbound "$tag" "$display_name" "$server" "$server_port" "$username" "$password"
    create_bound_user_for_outbound "$tag" || return 1
}

decode_import_input() {
    local input="$1" decoded
    input=$(trim "$input")
    if [[ "$input" == ss://* || "$input" == vless://* || "$input" == http://* || "$input" == https://* ]]; then
        printf '%s' "$input"
        return 0
    fi
    decoded=$(b64_decode "$input") || return 1
    decoded=$(trim "$decoded")
    if [[ "$decoded" == ss://* || "$decoded" == vless://* || "$decoded" == http://* || "$decoded" == https://* ]]; then
        printf '%s' "$decoded"
        return 0
    fi
    return 1
}

parse_common_uri() {
    PARSED_URI=$(decode_import_input "$1") || return 1
    PARSED_BODY=${PARSED_URI#*://}
    PARSED_FRAGMENT=""
    PARSED_QUERY=""

    if [[ "$PARSED_BODY" == *#* ]]; then
        PARSED_FRAGMENT=${PARSED_BODY#*#}
        PARSED_BODY=${PARSED_BODY%%#*}
        PARSED_FRAGMENT=$(url_decode "$PARSED_FRAGMENT")
    fi

    if [[ "$PARSED_BODY" == *\?* ]]; then
        PARSED_QUERY=${PARSED_BODY#*\?}
        PARSED_BODY=${PARSED_BODY%%\?*}
    fi
}

import_shadowsocks_uri() {
    local uri body fragment query main userinfo hostport decoded method password server server_port plugin plugin_opts tag display_name
    uri="$PARSED_URI"
    body="$PARSED_BODY"
    query="$PARSED_QUERY"
    fragment="$PARSED_FRAGMENT"
    [[ "$uri" == ss://* ]] || { red "导入内容不是 ss://"; return 1; }

    main="$body"
    if [[ "$main" == *@* ]]; then
        userinfo=${main%@*}
        hostport=${main#*@}
        decoded=$(b64_decode "$userinfo" || printf '%s' "$userinfo")
        method=${decoded%%:*}
        password=${decoded#*:}
    else
        decoded=$(b64_decode "$main") || { red "SS 主体 base64 解析失败。"; return 1; }
        method=${decoded%%:*}
        decoded=${decoded#*:}
        password=${decoded%@*}
        hostport=${decoded#*@}
    fi
    IFS='|' read -r server server_port <<< "$(split_hostport "$hostport")"

    validate_port "$server_port" || { red "SS 端口无效。"; return 1; }
    [ -n "$method" ] && [ -n "$password" ] && [ -n "$server" ] || { red "SS 链接缺少 method、password 或 server。"; return 1; }
    plugin=$(get_query_param "$query" "plugin" || true)
    plugin_opts=""
    if [ -n "$plugin" ] && [[ "$plugin" == *\;* ]]; then
        plugin_opts=${plugin#*;}
        plugin=${plugin%%;*}
    fi

    reading "请输入落地 tag（留空使用链接名称）: " tag
    [ -n "$tag" ] || tag="${fragment:-ss-$(date +%s)}"
    tag=$(sanitize_tag "$tag")
    validate_new_outbound_tag "$tag" || return 1
    display_name="${fragment:-$tag}"
    save_shadowsocks_outbound "$tag" "$display_name" "$server" "$server_port" "$method" "$password" "$plugin" "$plugin_opts"
    imported_outbound_tag="$tag"
}

import_vless_uri() {
    local uri body fragment query main hostport security tag display_name outbound_uuid server server_port flow network tls_enabled tls_server_name tls_insecure utls_fingerprint
    uri="$PARSED_URI"
    body="$PARSED_BODY"
    query="$PARSED_QUERY"
    fragment="$PARSED_FRAGMENT"
    [[ "$uri" == vless://* ]] || { red "导入内容不是 vless://"; return 1; }

    main="$body"
    outbound_uuid=${main%@*}
    hostport=${main#*@}
    IFS='|' read -r server server_port <<< "$(split_hostport "$hostport")"
    [ -n "$outbound_uuid" ] && [ -n "$server" ] || { red "VLESS 链接缺少 UUID 或服务器地址。"; return 1; }
    validate_port "$server_port" || { red "VLESS 端口无效。"; return 1; }

    flow=$(get_query_param "$query" "flow" || true)
    network=$(get_query_param "$query" "type" || true)
    [ -n "$network" ] || network="tcp"
    security=$(get_query_param "$query" "security" || true)
    [ -n "$security" ] || security="none"
    [ "$security" != "reality" ] || { red "不支持导入 VLESS Reality 落地，请使用 non-Reality VLESS/TLS/SS/HTTP/SOCKS5 落地。"; return 1; }
    [ "$security" = "none" ] || [ "$security" = "tls" ] || { red "当前仅支持 VLESS security=none 或 tls。"; return 1; }
    tls_server_name=$(get_query_param "$query" "sni" || true)
    utls_fingerprint=$(get_query_param "$query" "fp" || true)
    tls_insecure=$(get_query_param "$query" "allowInsecure" || true)
    case "$tls_insecure" in
        1|true) tls_insecure=1 ;;
        *) tls_insecure=0 ;;
    esac
    tls_enabled=0
    [ "$security" = "tls" ] && tls_enabled=1

    if [ "$network" != "tcp" ]; then
        red "当前仅支持导入 VLESS TCP 出站，请改用 TCP 链接或手动配置。"
        return 1
    fi

    reading "请输入落地 tag（留空使用链接名称）: " tag
    [ -n "$tag" ] || tag="${fragment:-vless-$(date +%s)}"
    tag=$(sanitize_tag "$tag")
    validate_new_outbound_tag "$tag" || return 1
    display_name="${fragment:-$tag}"
    save_vless_outbound "$tag" "$display_name" "$server" "$server_port" "$outbound_uuid" "$flow" "$network" "$tls_enabled" "$tls_server_name" "$tls_insecure" "$utls_fingerprint"
    imported_outbound_tag="$tag"
}

import_http_uri() {
    local uri body fragment scheme main auth hostport username password server server_port tag display_name tls_enabled
    uri="$PARSED_URI"
    body="$PARSED_BODY"
    fragment="$PARSED_FRAGMENT"
    case "$uri" in
        http://*) scheme="http"; tls_enabled=0 ;;
        https://*) scheme="https"; tls_enabled=1 ;;
        *) red "导入内容不是 http:// 或 https://"; return 1 ;;
    esac

    main="$body"
    username=""
    password=""
    if [[ "$main" == *@* ]]; then
        auth=${main%@*}
        hostport=${main#*@}
        username=$(url_decode "${auth%%:*}")
        if [[ "$auth" == *:* ]]; then
            password=$(url_decode "${auth#*:}")
        fi
    else
        hostport="$main"
    fi

    IFS='|' read -r server server_port <<< "$(split_hostport "$hostport")"

    [ -n "$server" ] || { red "HTTP 落地缺少服务器地址。"; return 1; }
    validate_port "$server_port" || { red "HTTP 落地端口无效。"; return 1; }

    reading "请输入落地 tag（留空使用链接名称）: " tag
    [ -n "$tag" ] || tag="${fragment:-${scheme}-$(date +%s)}"
    tag=$(sanitize_tag "$tag")
    validate_new_outbound_tag "$tag" || return 1
    display_name="${fragment:-$tag}"
    save_http_outbound "$tag" "$display_name" "$server" "$server_port" "$username" "$password" "$tls_enabled"
    imported_outbound_tag="$tag"
}

import_outbound_from_input() {
    local input
    require_reality_state || return 1
    prepare_import_base
    reading "请输入落地链接或其 base64（支持 ss/vless/http/https）: " input
    parse_common_uri "$input" || { red "无法解析导入内容。"; return 1; }

    case "$PARSED_URI" in
        ss://*) import_shadowsocks_uri ;;
        vless://*) import_vless_uri ;;
        http://*|https://*) import_http_uri ;;
        *) red "不支持的落地协议。"; return 1 ;;
    esac
}

import_outbound_auto() {
    require_reality_state || return 1
    import_outbound_from_input || return 1
    create_bound_user_for_outbound "$imported_outbound_tag" || return 1
}

users_for_outbound() {
    local tag="$1" file first=1
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        [ "$OUTBOUND_TAG" = "$tag" ] || continue
        [ "$first" -eq 1 ] || printf ' '
        first=0
        printf '%s' "$NAME"
    done
}

delete_outbound() {
    local tag file user users backup_dir status item count=0
    require_reality_state || return 1
    list_outbounds
    reading "请输入要删除的落地 tag: " tag
    tag=$(sanitize_tag "$tag")
    [ "$tag" != "$direct_outbound_tag" ] && [ "$tag" != "$block_outbound_tag" ] || { red "不能删除内置 outbound: $tag"; return 1; }
    file=$(outbound_file "$tag")
    [ -f "$file" ] || { red "outbound 不存在: $tag"; return 1; }
    users=$(users_for_outbound "$tag")

    for item in "$users_dir"/*.env; do
        [ -f "$item" ] && count=$((count + 1))
    done
    for user in $users; do
        count=$((count - 1))
    done
    [ "$count" -gt 0 ] || { red "至少保留一个入站用户，不能删除最后一组落地和用户。"; return 1; }

    backup_dir="${work_dir}/delete-${tag}-$(date +%s).bak"
    mkdir -p "$backup_dir"
    mv "$file" "$backup_dir/outbound.env"
    for user in $users; do
        mv "$(user_file "$user")" "$backup_dir/user-${user}.env"
    done

    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        mv "$backup_dir/outbound.env" "$file" 2>/dev/null || true
        for item in "$backup_dir"/user-*.env; do
            [ -f "$item" ] || continue
            user=${item##*/user-}
            user=${user%.env}
            mv "$item" "$(user_file "$user")"
        done
        rmdir "$backup_dir" 2>/dev/null || true
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi

    rm -rf "$backup_dir"
    if [ -n "$users" ]; then
        green "outbound 已删除，并同步删除绑定用户：$tag -> $users"
    else
        green "outbound 已删除：$tag"
    fi
}

# ── TCP/UDP 转发（iptables DNAT） ──────────────────────────────────

load_forward_file() {
    local file="$1"
    [ -f "$file" ] || return 1
    case "$file" in
        "$forwards_dir"/*.env) ;;
        *) return 1 ;;
    esac
    unset TAG PROTOCOL LOCAL_PORT TARGET_ADDR TARGET_PORT
    TAG=$(read_env_value "$file" TAG || true)
    PROTOCOL=$(read_env_value "$file" PROTOCOL || true)
    LOCAL_PORT=$(read_env_value "$file" LOCAL_PORT || true)
    TARGET_ADDR=$(read_env_value "$file" TARGET_ADDR || true)
    TARGET_PORT=$(read_env_value "$file" TARGET_PORT || true)
}

save_forward() {
    local tag="$1" protocol="$2" local_port="$3" target_addr="$4" target_port="$5" file
    tag=$(sanitize_tag "$tag")
    file=$(forward_file "$tag")
    {
        write_env_line TAG "$tag"
        write_env_line PROTOCOL "$protocol"
        write_env_line LOCAL_PORT "$local_port"
        write_env_line TARGET_ADDR "$target_addr"
        write_env_line TARGET_PORT "$target_port"
    } > "$file"
    chmod 600 "$file"
}

forward_exists() {
    [ -f "$(forward_file "$1")" ]
}

has_forwards() {
    local file
    for file in "$forwards_dir"/*.env; do
        [ -f "$file" ] && return 0
    done
    return 1
}

list_forwards_cli() {
    local file
    green "\n=== TCP/UDP 转发规则 ==="
    for file in "$forwards_dir"/*.env; do
        [ -f "$file" ] || continue
        load_forward_file "$file" || continue
        [ -n "$TAG" ] && [ -n "$LOCAL_PORT" ] || continue
        purple "${TAG} | ${PROTOCOL} | :${LOCAL_PORT} -> ${TARGET_ADDR}:${TARGET_PORT}"
    done
}

forward_iptables_rules() {
    local tag="$1" protocol="$2" local_port="$3" target_addr="$4" target_port="$5" proto_flag

    for proto_flag in $protocol; do
        iptables -t nat -C PREROUTING -p "$proto_flag" --dport "$local_port" -j DNAT --to-destination "${target_addr}:${target_port}" 2>/dev/null ||
            iptables -t nat -A PREROUTING -p "$proto_flag" --dport "$local_port" -j DNAT --to-destination "${target_addr}:${target_port}"
        iptables -t nat -C POSTROUTING -d "$target_addr" -p "$proto_flag" --dport "$target_port" -j MASQUERADE 2>/dev/null ||
            iptables -t nat -A POSTROUTING -d "$target_addr" -p "$proto_flag" --dport "$target_port" -j MASQUERADE
        # 被 DNAT 的包走 FORWARD 链（而非 INPUT/OUTPUT）。若 FORWARD 默认策略是 DROP，
        # 需显式放行到目标的出向包与来自目标的回向包，否则转发会被丢弃。
        iptables -C FORWARD -p "$proto_flag" -d "$target_addr" --dport "$target_port" -j ACCEPT 2>/dev/null ||
            iptables -A FORWARD -p "$proto_flag" -d "$target_addr" --dport "$target_port" -j ACCEPT
        # 回程包来源端口可能不是 target_port（如 UDP 临时端口），按目标地址用 conntrack 放行已建立/相关连接
        iptables -C FORWARD -p "$proto_flag" -s "$target_addr" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null ||
            iptables -A FORWARD -p "$proto_flag" -s "$target_addr" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    done
}

remove_forward_iptables_rules() {
    local tag="$1" protocol="$2" local_port="$3" target_addr="$4" target_port="$5" proto_flag

    for proto_flag in $protocol; do
        iptables -t nat -D PREROUTING -p "$proto_flag" --dport "$local_port" -j DNAT --to-destination "${target_addr}:${target_port}" 2>/dev/null || true
        iptables -t nat -D POSTROUTING -d "$target_addr" -p "$proto_flag" --dport "$target_port" -j MASQUERADE 2>/dev/null || true
        iptables -D FORWARD -p "$proto_flag" -d "$target_addr" --dport "$target_port" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -p "$proto_flag" -s "$target_addr" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    done
}

write_forward_openrc_service() {
    local tag="$1" protocol="$2" local_port="$3" target_addr="$4" target_port="$5" service_name
    service_name=$(forward_service_name "$tag")
    cat > "/etc/init.d/${service_name}" << EOF
#!/sbin/openrc-run

description="sing-box TCP/UDP forward: :${local_port} -> ${target_addr}:${target_port} (${protocol})"
command="/sbin/iptables"
command_args=""
pidfile="/var/run/${service_name}.pid"
command_background=false

depend() {
    # 不依赖 iptables 服务：部分系统未安装/未启用 iptables OpenRC 服务会阻塞启动
    need net
}

start() {
    ebegin "Starting forward ${tag} (:${local_port} -> ${target_addr}:${target_port})"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
EOF
    for proto_flag in $protocol; do
        cat >> "/etc/init.d/${service_name}" << EOF
    iptables -t nat -C PREROUTING -p ${proto_flag} --dport ${local_port} -j DNAT --to-destination ${target_addr}:${target_port} 2>/dev/null ||
        iptables -t nat -A PREROUTING -p ${proto_flag} --dport ${local_port} -j DNAT --to-destination ${target_addr}:${target_port}
    iptables -t nat -C POSTROUTING -d ${target_addr} -p ${proto_flag} --dport ${target_port} -j MASQUERADE 2>/dev/null ||
        iptables -t nat -A POSTROUTING -d ${target_addr} -p ${proto_flag} --dport ${target_port} -j MASQUERADE
    iptables -C FORWARD -p ${proto_flag} -d ${target_addr} --dport ${target_port} -j ACCEPT 2>/dev/null ||
        iptables -A FORWARD -p ${proto_flag} -d ${target_addr} --dport ${target_port} -j ACCEPT
    iptables -C FORWARD -p ${proto_flag} -s ${target_addr} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null ||
        iptables -A FORWARD -p ${proto_flag} -s ${target_addr} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
EOF
    done
    cat >> "/etc/init.d/${service_name}" << EOF
    eend 0
}

stop() {
    ebegin "Stopping forward ${tag} (:${local_port} -> ${target_addr}:${target_port})"
EOF
    for proto_flag in $protocol; do
        cat >> "/etc/init.d/${service_name}" << EOF
    iptables -t nat -D PREROUTING -p ${proto_flag} --dport ${local_port} -j DNAT --to-destination ${target_addr}:${target_port} 2>/dev/null || true
    iptables -t nat -D POSTROUTING -d ${target_addr} -p ${proto_flag} --dport ${target_port} -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -p ${proto_flag} -d ${target_addr} --dport ${target_port} -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p ${proto_flag} -s ${target_addr} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
EOF
    done
    cat >> "/etc/init.d/${service_name}" << EOF
    eend 0
}

status() {
    local found=0
EOF
    for proto_flag in $protocol; do
        cat >> "/etc/init.d/${service_name}" << EOF
    iptables -t nat -C PREROUTING -p ${proto_flag} --dport ${local_port} -j DNAT --to-destination ${target_addr}:${target_port} 2>/dev/null && found=1
EOF
    done
    cat >> "/etc/init.d/${service_name}" << EOF
    if [ "\$found" -eq 1 ]; then
        ebegin "forward ${tag} is active" && eend 0
    else
        eerror "forward ${tag} is not active"
        return 1
    fi
}
EOF
    chmod +x "/etc/init.d/${service_name}"
}

install_forward_service() {
    local tag="$1" protocol="$2" local_port="$3" target_addr="$4" target_port="$5" service_name
    service_name=$(forward_service_name "$tag")
    if command_exists rc-service && command_exists rc-update; then
        write_forward_openrc_service "$tag" "$protocol" "$local_port" "$target_addr" "$target_port"
        rc-update add "$service_name" default >/dev/null 2>&1
        rc-service "$service_name" start
    elif command_exists systemctl; then
        write_forward_systemd_service "$tag" "$protocol" "$local_port" "$target_addr" "$target_port"
    else
        yellow "未检测到 OpenRC 或 systemd，无法设置转发服务开机自启；iptables 规则已生效，重启后需手动重加。"
    fi
}

write_forward_systemd_service() {
    local tag="$1" protocol="$2" local_port="$3" target_addr="$4" target_port="$5" service_name wrapper service_file
    service_name=$(forward_service_name "$tag")
    wrapper="${work_dir}/${service_name}.sh"
    service_file="/etc/systemd/system/${service_name}.service"
    {
        cat << EOF
#!/bin/sh
# sing-box TCP/UDP forward: :${local_port} -> ${target_addr}:${target_port} (${protocol})
case "\$1" in
  start)
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
EOF
        for proto_flag in $protocol; do
            cat << EOF
    iptables -t nat -C PREROUTING -p ${proto_flag} --dport ${local_port} -j DNAT --to-destination ${target_addr}:${target_port} 2>/dev/null ||
        iptables -t nat -A PREROUTING -p ${proto_flag} --dport ${local_port} -j DNAT --to-destination ${target_addr}:${target_port}
    iptables -t nat -C POSTROUTING -d ${target_addr} -p ${proto_flag} --dport ${target_port} -j MASQUERADE 2>/dev/null ||
        iptables -t nat -A POSTROUTING -d ${target_addr} -p ${proto_flag} --dport ${target_port} -j MASQUERADE
    iptables -C FORWARD -p ${proto_flag} -d ${target_addr} --dport ${target_port} -j ACCEPT 2>/dev/null ||
        iptables -A FORWARD -p ${proto_flag} -d ${target_addr} --dport ${target_port} -j ACCEPT
    iptables -C FORWARD -p ${proto_flag} -s ${target_addr} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null ||
        iptables -A FORWARD -p ${proto_flag} -s ${target_addr} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
EOF
        done
        cat << EOF
    ;;
  stop)
EOF
        for proto_flag in $protocol; do
            cat << EOF
    iptables -t nat -D PREROUTING -p ${proto_flag} --dport ${local_port} -j DNAT --to-destination ${target_addr}:${target_port} 2>/dev/null || true
    iptables -t nat -D POSTROUTING -d ${target_addr} -p ${proto_flag} --dport ${target_port} -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -p ${proto_flag} -d ${target_addr} --dport ${target_port} -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p ${proto_flag} -s ${target_addr} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
EOF
        done
        cat << EOF
    ;;
  status)
    found=0
EOF
        for proto_flag in $protocol; do
            cat << EOF
    iptables -t nat -C PREROUTING -p ${proto_flag} --dport ${local_port} -j DNAT --to-destination ${target_addr}:${target_port} 2>/dev/null && found=1
EOF
        done
        cat << EOF
    [ "\$found" -eq 1 ] && echo "forward ${tag} is active" && exit 0 || { echo "forward ${tag} is not active" >&2; exit 1; }
    ;;
  *) echo "usage: \$0 {start|stop|status}" >&2; exit 1 ;;
esac
EOF
    } > "$wrapper"
    chmod +x "$wrapper"

    cat > "$service_file" << EOF
[Unit]
Description=sing-box TCP/UDP forward: :${local_port} -> ${target_addr}:${target_port} (${protocol})
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${wrapper} start
ExecStop=${wrapper} stop

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${service_name}.service"
}

uninstall_forward_service() {
    local tag="$1" service_name
    service_name=$(forward_service_name "$tag")
    if [ -f "/etc/init.d/${service_name}" ]; then
        rc-service "$service_name" stop 2>/dev/null || true
        rc-update del "$service_name" default 2>/dev/null || true
        rm -f "/etc/init.d/${service_name}"
    fi
    if [ -f "/etc/systemd/system/${service_name}.service" ]; then
        systemctl disable --now "${service_name}.service" 2>/dev/null || true
        rm -f "/etc/systemd/system/${service_name}.service"
        systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f "${work_dir}/${service_name}.sh"
}

add_forward() {
    local tag protocol local_port target_addr target_port
    load_state

    reading "请输入转发规则名称（英文/数字）: " tag
    tag=$(sanitize_tag "$tag")
    [ -n "$tag" ] || { red "名称不能为空"; return 1; }
    forward_exists "$tag" && { red "转发规则已存在: $tag"; return 1; }

    reading "请选择协议 (tcp/udp/both，默认 tcp): " protocol
    case "${protocol:-tcp}" in
        tcp) protocol="tcp" ;;
        udp) protocol="udp" ;;
        both|tcp+udp|tcpudp) protocol="tcp udp" ;;
        *) red "无效的协议: $protocol"; return 1 ;;
    esac

    reading "请输入本地监听端口: " local_port
    validate_port "$local_port" || { red "端口范围需在 1-65535"; return 1; }

    reading "请输入目标地址 (IP 或域名): " target_addr
    validate_host_address "$target_addr" || { red "目标地址无效。"; return 1; }
    # 转发走 iptables（IPv4 DNAT），暂不支持 IPv6 目标地址
    [[ "$target_addr" == *:* ]] && { red "当前仅支持 IPv4/域名目标地址，不支持 IPv6。"; return 1; }

    reading "请输入目标端口: " target_port
    validate_port "$target_port" || { red "端口范围需在 1-65535"; return 1; }

    # 检查本地端口是否已被其他转发占用
    local file
    for file in "$forwards_dir"/*.env; do
        [ -f "$file" ] || continue
        load_forward_file "$file" || continue
        [ "$LOCAL_PORT" = "$local_port" ] && { red "本地端口 ${local_port} 已被转发规则 \"${TAG}\" 占用"; return 1; }
    done

    # 检查本地端口是否与 sing-box 入站端口冲突（Reality 主端口或非 Reality 入站端口）
    if inbound_port_in_use "$local_port"; then
        red "本地端口 ${local_port} 已被 sing-box 入站占用，请换一个端口或先调整入站配置。"
        return 1
    fi

    save_forward "$tag" "$protocol" "$local_port" "$target_addr" "$target_port"

    # 启用 IP 转发
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1

    forward_iptables_rules "$tag" "$protocol" "$local_port" "$target_addr" "$target_port"
    allow_port "$local_port" "$protocol"
    install_forward_service "$tag" "$protocol" "$local_port" "$target_addr" "$target_port"

    green "转发规则已添加: ${tag} | ${protocol} | :${local_port} -> ${target_addr}:${target_port}"
}

delete_forward() {
    local tag file service_name
    ensure_state_layout
    list_forwards_cli
    has_forwards || { yellow "暂无转发规则。"; return 1; }

    reading "请输入要删除的转发规则名称: " tag
    tag=$(sanitize_tag "$tag")
    file=$(forward_file "$tag")
    [ -f "$file" ] || { red "转发规则不存在: $tag"; return 1; }

    load_forward_file "$file"
    uninstall_forward_service "$tag"
    # 兜底：即使 OpenRC 服务缺失，也直接删除 iptables 规则，避免残留
    remove_forward_iptables_rules "$TAG" "$PROTOCOL" "$LOCAL_PORT" "$TARGET_ADDR" "$TARGET_PORT"
    rm -f "$file"
    green "转发规则已删除: $tag"
}

manage_forwards_menu() {
    local choice
    ensure_state_layout
    clear_screen
    green "=== TCP/UDP 转发管理 ===\n"
    list_forwards_cli
    echo
    green "1. 添加 TCP/UDP 转发规则"
    red "2. 删除转发规则"
    purple "0. 返回主菜单"
    reading "请输入选择: " choice

    case "$choice" in
        1) add_forward ;;
        2) delete_forward ;;
        0) return ;;
        *) red "无效的选项" ;;
    esac
}

manage_route_menu() {
    local choice
    require_reality_state || return 1
    clear_screen
    green "=== 落地管理 ===\n"
    green "1. 导入落地并自动绑定用户"
    green "2. 手动添加 SOCKS5 落地并自动绑定用户"
    green "3. 查看节点链接"
    green "4. 列出落地"
    red "5. 删除落地和绑定用户"
    purple "0. 返回主菜单"
    reading "请输入选择: " choice

    case "$choice" in
        1) import_outbound_auto ;;
        2) add_socks_outbound ;;
        3) show_reality_info ;;
        4) list_outbounds ;;
        5) delete_outbound ;;
        0) return ;;
        *) red "无效的选项" ;;
    esac
}

manage_reality_settings_menu() {
    local choice
    require_reality_state || return 1
    clear_screen
    green "=== Reality 设置 ===\n"
    green "1. 修改 Reality 端口"
    green "2. 修改 Reality 伪装域名/SNI"
    purple "0. 返回主菜单"
    reading "请输入选择: " choice

    case "$choice" in
        1) change_port ;;
        2) change_reality_domain ;;
        0) return ;;
        *) red "无效的选项" ;;
    esac
}

manage_singbox() {
    local singbox_status choice
    singbox_status=$(check_singbox 2>/dev/null)

    clear_screen
    green "=== sing-box 服务管理 ===\n"
    green "当前状态: ${singbox_status}\n"
    green "1. 启动 sing-box"
    green "2. 停止 sing-box"
    green "3. 重启 sing-box"
    green "4. 查看 sing-box 日志"
    purple "0. 返回主菜单"
    reading "请输入选择: " choice

    case "$choice" in
        1) start_singbox ;;
        2) stop_singbox ;;
        3) restart_singbox ;;
        4) show_singbox_logs ;;
        0) return ;;
        *) red "无效的选项" ;;
    esac
}

uninstall_singbox() {
    local choice file
    reading "确定要卸载 sing-box 并删除 ${work_dir} 吗？(y/n): " choice
    case "$choice" in
        y|Y)
            yellow "正在卸载 sing-box..."

            # 清理所有转发规则（iptables 规则 + OpenRC 服务）
            for file in "$forwards_dir"/*.env; do
                [ -f "$file" ] || continue
                load_forward_file "$file" || continue
                [ -n "$TAG" ] || continue
                remove_forward_iptables_rules "$TAG" "$PROTOCOL" "$LOCAL_PORT" "$TARGET_ADDR" "$TARGET_PORT"
                uninstall_forward_service "$TAG"
            done

            # 清理服务
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
            rm -f /etc/logrotate.d/sing-box
            green "sing-box 已卸载。"
            ;;
        *)
            yellow "已取消卸载。"
            ;;
    esac
}

ensure_shortcut() {
    [ "${SB_SHORTCUT_INSTALLING:-0}" = "1" ] && return 0
    [ "${EUID:-$(id -u)}" -eq 0 ] || return 0
    [ -f "$installed_script" ] && [ -x /usr/bin/sb ] && return 0
    # 仅在已安装（存在运行状态与配置）时才创建快捷命令，避免仅查看菜单就改写系统
    [ -f "$state_file" ] && [ -f "$config_dir" ] || return 0
    create_shortcut
}

menu() {
    local singbox_status
    singbox_status=$(check_singbox 2>/dev/null)

    clear_screen
    purple "=== sing-box 多协议入站中转/本机节点脚本 ===\n"
    purple "sing-box 状态: ${singbox_status}\n"
    green "1. 安装 / 初始化节点"
    green "2. 添加落地并自动绑定用户"
    green "3. 查看节点和落地摘要"
    green "4. 管理落地"
    green "5. 修改 Reality 设置"
    green "6. TCP/UDP 转发管理"
    green "7. sing-box 服务管理"
    green "8. 查看 sing-box 日志"
    red "9. 卸载 sing-box"
    red "0. 退出脚本"
    reading "请输入选择(0-9): " choice
}

trap 'red "已取消操作"; exit 130' INT

if [ "$auto_install" -eq 1 ]; then
    run_install_flow
    exit 0
fi

ensure_shortcut

while true; do
    menu
    case "$choice" in
        1) run_install_flow ;;
        2) import_outbound_auto ;;
        3) show_reality_info; list_forwards_cli ;;
        4) manage_route_menu ;;
        5) manage_reality_settings_menu ;;
        6) manage_forwards_menu ;;
        7) manage_singbox ;;
        8) show_singbox_logs ;;
        9) uninstall_singbox ;;
        0) exit 0 ;;
        *) red "无效的选项，请输入 0 到 9" ;;
    esac
    read -r -n 1 -s -p $'\033[1;91m按任意键返回...\033[0m'
    echo ""
done
