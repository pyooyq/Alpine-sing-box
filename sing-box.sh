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
hy2_inbound_tag="hy2-in"
http_inbound_tag="http-in"
socks_inbound_tag="socks-in"
direct_outbound_tag="direct"
block_outbound_tag="block"
default_user_name="default-direct"
default_flow="xtls-rprx-vision"
default_fingerprint="chrome"
default_inbound_type="vless-reality"
default_ss_method="aes-128-gcm"
imported_outbound_tag=""
# 用户态转发（realm）：替代内核 iptables DNAT，可在无 iptables / 无特权容器环境工作
realm_bin="/usr/local/bin/realm"
realm_config="/etc/realm/config.json"
realm_work="/etc/realm"
# Hysteria2 自签名证书（所有 hy2 入站共用；客户端通常以 insecure=1 连接，不校验证书）
hy2_cert="${work_dir}/hy2-cert.pem"
hy2_key="${work_dir}/hy2-key.pem"

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

    # 含冒号 -> 视为 IPv6（最终由 realm/sing-box 解析校验）
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

# 对 URI 组件做百分号编码（保留未保留字符与 '-' '_' '.' '~'），
# 用于 hysteria2 链接中可能含特殊字符（如 base64 生成的密码）的片段
url_encode() {
    local value="$1" out="" i c
    for ((i = 0; i < ${#value}; i++)); do
        c="${value:i:1}"
        case "$c" in
            [a-zA-Z0-9._~-]) out="${out}${c}" ;;
            ' ') out="${out}%20" ;;
            *) printf -v hex '%02X' "'$c" 2>/dev/null && out="${out}%${hex}" || out="${out}${c}" ;;
        esac
    done
    printf '%s' "$out"
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
    local port="$1" type="$2" skip_user="${3:-}" file
    # 主端口仅当存在 Reality 入站时视为占用（初始化选非 Reality 协议时 PORT 仅为占位值）
    if has_inbound_type "vless-reality" && [ "$port" = "$PORT" ]; then
        return 0
    fi
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        [ "$NAME" = "$skip_user" ] && continue
        [ "$INBOUND_TYPE" = "vless-reality" ] && continue
        [ "$INBOUND_PORT" = "$port" ] || continue
        # 同协议同端口视为加入同一入站（共享）；仅 SS（暂未支持一端口多用户）与其他协议占用视为冲突
        [ "$INBOUND_TYPE" = "$type" ] && [ "$type" != "shadowsocks" ] && continue
        return 0
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
    unset NAME UUID FLOW OUTBOUND_TAG INBOUND_TYPE INBOUND_PORT METHOD PASSWORD H2_SNI USERNAME
    NAME=$(read_env_value "$file" NAME || true)
    UUID=$(read_env_value "$file" UUID || true)
    FLOW=$(read_env_value "$file" FLOW || true)
    OUTBOUND_TAG=$(read_env_value "$file" OUTBOUND_TAG || true)
    INBOUND_TYPE=$(read_env_value "$file" INBOUND_TYPE || true)
    INBOUND_PORT=$(read_env_value "$file" INBOUND_PORT || true)
    METHOD=$(read_env_value "$file" METHOD || true)
    PASSWORD=$(read_env_value "$file" PASSWORD || true)
    H2_SNI=$(read_env_value "$file" H2_SNI || true)
    USERNAME=$(read_env_value "$file" USERNAME || true)
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
    H2_SNI="${H2_SNI:-$REALITY_DOMAIN}"
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
    local name="$1" uuid="$2" outbound_tag="$3" flow="${4:-$default_flow}" inbound_type="${5:-$default_inbound_type}" password="${6:-}" method="${7:-$default_ss_method}" inbound_port="${8:-$PORT}" sni="${9:-}" username="${10:-}" file
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
        [ -n "$sni" ] && write_env_line H2_SNI "$sni"
        [ -n "$username" ] && write_env_line USERNAME "$username"
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

# 生成 Hysteria2 自签名证书（所有 hy2 入站共用；客户端以 insecure=1 连接，不校验证书）
ensure_hy2_cert() {
    local sni="${1:-$REALITY_DOMAIN}"
    [ -f "$hy2_cert" ] && [ -f "$hy2_key" ] && return 0
    command_exists openssl || manage_packages install openssl >/dev/null 2>&1
    command_exists openssl || { red "需要 openssl 生成 Hysteria2 自签名证书，请先安装 openssl 后重试。"; return 1; }
    mkdir -p "$work_dir"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$hy2_key" -out "$hy2_cert" -days 3650 -nodes \
        -subj "/CN=${sni}" 2>/dev/null
    if [ -f "$hy2_cert" ] && [ -f "$hy2_key" ]; then
        chmod 600 "$hy2_key"
        chmod 644 "$hy2_cert"
        return 0
    fi
    red "生成 Hysteria2 自签名证书失败。"
    return 1
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

inbound_tag_for_group() {
    local type="$1" port="$2"
    case "$type" in
        vless) printf '%s-%s' "$vless_inbound_tag" "$port" ;;
        shadowsocks) printf '%s-%s' "$ss_inbound_tag" "$port" ;;
        hysteria2) printf '%s-%s' "$hy2_inbound_tag" "$port" ;;
        http) printf '%s-%s' "$http_inbound_tag" "$port" ;;
        socks) printf '%s-%s' "$socks_inbound_tag" "$port" ;;
        *) printf '%s' "$reality_inbound_tag" ;;
    esac
}

# 收集所有可见入站到全局数组 INBOUND_GROUPS，每项 "type|port"（Reality 归一为 PORT）
collect_inbound_groups() {
    local file type port key already existing
    INBOUND_GROUPS=()
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        user_is_visible || continue
        type="$INBOUND_TYPE"
        if [ "$type" = "vless-reality" ]; then
            port="$PORT"
        else
            port="$INBOUND_PORT"
            validate_port "$port" || continue
        fi
        key="${type}|${port}"
        already=0
        for existing in "${INBOUND_GROUPS[@]}"; do
            [ "$existing" = "$key" ] && { already=1; break; }
        done
        [ "$already" -eq 0 ] && INBOUND_GROUPS+=("$key")
    done
}

# 读取组内（type,port）某字段值（取首个成员），缺省回退 default
group_member_field() {
    local type="$1" port="$2" field="$3" default="$4" file
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        user_is_visible || continue
        [ "$INBOUND_TYPE" = "$type" ] || continue
        if [ "$type" = "vless-reality" ]; then
            [ "$INBOUND_PORT" = "$PORT" ] || continue
        else
            [ "$INBOUND_PORT" = "$port" ] || continue
        fi
        case "$field" in
            METHOD) printf '%s' "${METHOD:-$default}" ;;
            PASSWORD) printf '%s' "${PASSWORD:-$default}" ;;
            H2_SNI) printf '%s' "${H2_SNI:-$default}" ;;
        esac
        return 0
    done
    printf '%s' "$default"
}

# 组内成员名（空格分隔），供遍历/展示
group_member_names() {
    local type="$1" port="$2" file first=1
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        user_is_visible || continue
        [ "$INBOUND_TYPE" = "$type" ] || continue
        if [ "$type" = "vless-reality" ]; then
            [ "$INBOUND_PORT" = "$PORT" ] || continue
        else
            [ "$INBOUND_PORT" = "$port" ] || continue
        fi
        [ "$first" -eq 1 ] || printf ' '
        first=0
        printf '%s' "$NAME"
    done
}

group_label() {
    case "$1" in
        vless-reality) printf 'VLESS+Reality :%s' "$2" ;;
        vless) printf 'VLESS :%s' "$2" ;;
        shadowsocks) printf 'SS :%s' "$2" ;;
        hysteria2) printf 'HY2 :%s' "$2" ;;
        http) printf 'HTTP :%s' "$2" ;;
        socks) printf 'SOCKS5 :%s' "$2" ;;
        *) printf '%s :%s' "$1" "$2" ;;
    esac
}

# 渲染组内所有成员的 users 数组条目（含逗号）；kind = vless|shadowsocks|hysteria2
render_group_users_json() {
    local type="$1" port="$2" kind="$3" file first=1
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        user_is_visible || continue
        [ "$INBOUND_TYPE" = "$type" ] || continue
        if [ "$type" = "vless-reality" ]; then
            [ "$INBOUND_PORT" = "$PORT" ] || continue
        else
            [ "$INBOUND_PORT" = "$port" ] || continue
        fi
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        case "$kind" in
            vless)
                printf '        {\n'
                printf '          "name": %s,\n' "$(json_string "$NAME")"
                printf '          "uuid": %s\n' "$(json_string "$UUID")"
                printf '        }'
                ;;
            shadowsocks|hysteria2)
                printf '        {\n'
                printf '          "name": %s,\n' "$(json_string "$NAME")"
                printf '          "password": %s\n' "$(json_string "$PASSWORD")"
                printf '        }'
                ;;
            http|socks)
                printf '        {\n'
                printf '          "username": %s,\n' "$(json_string "$USERNAME")"
                printf '          "password": %s\n' "$(json_string "$PASSWORD")"
                printf '        }'
                ;;
        esac
    done
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
            hysteria2)
                [ -n "$NAME" ] && [ -n "$PASSWORD" ] && validate_port "$INBOUND_PORT" && return 0
                ;;
            http|socks)
                [ -n "$NAME" ] && [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] && validate_port "$INBOUND_PORT" && return 0
                ;;
            *)
                [ -n "$NAME" ] && [ -n "$UUID" ] && validate_port "$INBOUND_PORT" && return 0
                ;;
        esac
    done
    return 1
}

render_inbounds_json() {
    local g type port tag owner_method owner_password owner_sni first=1
    collect_inbound_groups
    for g in "${INBOUND_GROUPS[@]}"; do
        type="${g%%|*}"
        port="${g##*|}"
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        case "$type" in
            vless-reality)
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
                ;;
            vless)
                tag=$(inbound_tag_for_group "$type" "$port")
                cat << EOF
    {
      "type": "vless",
      "tag": "${tag}",
      "listen": "::",
      "listen_port": ${port},
      "users": [
$(render_group_users_json "$type" "$port" vless)
      ]
    }
EOF
                ;;
            shadowsocks)
                tag=$(inbound_tag_for_group "$type" "$port")
                owner_method=$(group_member_field "$type" "$port" METHOD "$default_ss_method")
                owner_password=$(group_member_field "$type" "$port" PASSWORD "")
                # SS 暂不支持一端口多用户（需 2022 加密），此处按单用户渲染，仅 method+password
                cat << EOF
    {
      "type": "shadowsocks",
      "tag": "${tag}",
      "listen": "::",
      "listen_port": ${port},
      "method": $(json_string "$owner_method"),
      "password": $(json_string "$owner_password")
    }
EOF
                ;;
            hysteria2)
                tag=$(inbound_tag_for_group "$type" "$port")
                owner_sni=$(group_member_field "$type" "$port" H2_SNI "$REALITY_DOMAIN")
                cat << EOF
    {
      "type": "hysteria2",
      "tag": "${tag}",
      "listen": "::",
      "listen_port": ${port},
      "users": [
$(render_group_users_json "$type" "$port" hysteria2)
      ],
      "tls": {
        "enabled": true,
        "server_name": $(json_string "$owner_sni"),
        "key_path": "$(json_escape "$hy2_key")",
        "certificate_path": "$(json_escape "$hy2_cert")"
      }
    }
EOF
                ;;
            http|socks)
                tag=$(inbound_tag_for_group "$type" "$port")
                cat << EOF
    {
      "type": "${type}",
      "tag": "${tag}",
      "listen": "::",
      "listen_port": ${port},
      "users": [
$(render_group_users_json "$type" "$port" "$type")
      ]
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
    local file first=1 name auth_user_name outbound_tag inbound_type inbound_port inbound_tag
    local fallback_inbounds="" fallback_seen=""
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        user_is_visible || continue
        name="$NAME"
        outbound_tag="$OUTBOUND_TAG"
        inbound_type="$INBOUND_TYPE"
        # http/socks 的 auth_user 匹配的是代理用户名（users 用 username 字段）
        auth_user_name="$NAME"
        case "$inbound_type" in
            http|socks) auth_user_name="$USERNAME" ;;
        esac
        if [ "$inbound_type" = "vless-reality" ]; then
            inbound_port="$PORT"
        else
            inbound_port="$INBOUND_PORT"
            validate_port "$inbound_port" || continue
        fi
        inbound_tag=$(inbound_tag_for_group "$inbound_type" "$inbound_port")
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
        # SS 现为单用户（无 users 数组/命名用户），连接无 auth_user，故不带该匹配
        [ "$inbound_type" != "shadowsocks" ] && printf '        "auth_user": [%s],\n' "$(json_string "$auth_user_name")"
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
Restart=always
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now sing-box
}

write_openrc_service() {
    # 守护：给 sing-box 套一个 shell 包装器循环。子进程退出/被杀则重启；
    # `rc-service sing-box stop` 时清理子进程并退出，不复活。不依赖 supervise-daemon，纯 OpenRC 生效。
    cat > "${work_dir}/singbox-wrapper.sh" << EOF
#!/bin/sh
# sing-box 守护包装器：子进程退出/被杀则重启；rc-service stop 时清理子进程并退出
BIN="${work_dir}/${server_name}"
CONF="${config_dir}"
child=""
cleanup() {
    [ -n "\$child" ] && kill "\$child" 2>/dev/null || true
    exit 0
}
trap 'cleanup' TERM INT
while :; do
    "\$BIN" run -c "\$CONF" &
    child=\$!
    wait "\$child" 2>/dev/null
    child=""
    sleep 3
done
EOF
    chmod +x "${work_dir}/singbox-wrapper.sh"

    cat > /etc/init.d/sing-box << EOF
#!/sbin/openrc-run

description="sing-box service (respawn wrapper)"
command="${work_dir}/singbox-wrapper.sh"
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
    local uuid="$1" name="$2" flow="$3" server_ip="$4" inbound_type="${5:-$default_inbound_type}" password="${6:-}" method="${7:-$default_ss_method}" inbound_port="${8:-$PORT}" sni="${9:-}" username="${10:-}" link userinfo
    load_state
    [ -n "$server_ip" ] || server_ip=$(get_server_ip)
    [ -n "$sni" ] || sni="$REALITY_DOMAIN"
    case "$inbound_type" in
        vless)
            link="vless://${uuid}@${server_ip}:${inbound_port}?encryption=none&security=none&type=tcp&headerType=none#${name}"
            ;;
        shadowsocks)
            userinfo=$(printf '%s:%s' "$method" "$password" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
            link="ss://${userinfo}@${server_ip}:${inbound_port}#${name}"
            ;;
        hysteria2)
            link="hysteria2://$(url_encode "$password")@${server_ip}:${inbound_port}?sni=${sni}&insecure=1#${name}"
            ;;
        http)
            link="http://$(url_encode "${username:-$name}"):$(url_encode "$password")@${server_ip}:${inbound_port}#${name}"
            ;;
        socks)
            link="socks5://$(url_encode "${username:-$name}"):$(url_encode "$password")@${server_ip}:${inbound_port}#${name}"
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

# 判定某个已 load_user_file 的用户是否为可见、可管理的入站（过滤缺字段的脏数据）
user_is_visible() {
    [ -n "$NAME" ] || return 1
    case "$INBOUND_TYPE" in
        shadowsocks|hysteria2) [ -n "$PASSWORD" ] || return 1 ;;
        http|socks) [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] || return 1 ;;
        *) [ -n "$UUID" ] || return 1 ;;
    esac
    return 0
}

# 收集可见入站用户名到全局数组 INBOUND_NAMES
collect_inbound_names() {
    local file
    INBOUND_NAMES=()
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        user_is_visible || continue
        INBOUND_NAMES+=("$NAME")
    done
}

# 收集落地 outbound tag（不含内置 direct/block）到全局数组 OUTBOUND_TAGS
collect_outbound_tags() {
    local file
    OUTBOUND_TAGS=()
    for file in "$outbounds_dir"/*.env; do
        [ -f "$file" ] || continue
        load_outbound_file "$file" || continue
        [ -n "$TAG" ] && [ -n "$TYPE" ] || continue
        OUTBOUND_TAGS+=("$TAG")
    done
}

# 打印带序号的入站列表（依赖 collect_inbound_names 已执行）
list_inbounds_numbered() {
    local i name
    if [ "${#INBOUND_NAMES[@]}" -eq 0 ]; then
        purple "（暂无入站）"
        return 0
    fi
    green "\n=== 现有入站 ===\n"
    for i in "${!INBOUND_NAMES[@]}"; do
        name="${INBOUND_NAMES[$i]}"
        load_user_file "$(user_file "$name")"
        purple "$((i + 1))) ${NAME} | $(inbound_label "$INBOUND_TYPE") | port=${INBOUND_PORT} | outbound=${OUTBOUND_TAG}"
    done
}

# 打印带序号的落地列表（依赖 collect_outbound_tags 已执行）
list_outbounds_numbered() {
    local i tag users
    if [ "${#OUTBOUND_TAGS[@]}" -eq 0 ]; then
        purple "（暂无落地）"
        return 0
    fi
    green "\n=== 落地列表 ===\n"
    for i in "${!OUTBOUND_TAGS[@]}"; do
        tag="${OUTBOUND_TAGS[$i]}"
        load_outbound_file "$(outbound_file "$tag")" || continue
        users=$(users_for_outbound "$tag")
        purple "$((i + 1))) ${TAG} | ${TYPE} | ${DISPLAY_NAME:-$SERVER:$SERVER_PORT} | 入站=${users:-无}"
    done
}

# 读取一个 1..total 的序号到全局 PICKED_INDEX
pick_index() {
    local total="$1" sel
    reading "请输入序号: " sel
    [[ "$sel" =~ ^[0-9]+$ ]] || { red "无效序号。"; return 1; }
    [ "$sel" -ge 1 ] && [ "$sel" -le "$total" ] || { red "序号需在 1 到 ${total} 之间。"; return 1; }
    PICKED_INDEX="$sel"
}

# 除指定用户外，是否还存在其他可见入站（用于删除的最后一条保护）
has_more_inbound_users() {
    local skip="$1" file count=0
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        user_is_visible || continue
        [ "$NAME" = "$skip" ] && continue
        count=$((count + 1))
    done
    [ "$count" -gt 0 ]
}

list_users() {
    local file
    green "\n=== 入站用户 ==="
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        [ -n "$NAME" ] || continue
        [ "$INBOUND_TYPE" = "shadowsocks" ] && [ -z "$PASSWORD" ] && continue
        [ "$INBOUND_TYPE" = "hysteria2" ] && [ -z "$PASSWORD" ] && continue
        { [ "$INBOUND_TYPE" != "shadowsocks" ] && [ "$INBOUND_TYPE" != "hysteria2" ]; } && [ -z "$UUID" ] && continue
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
        link=$(user_link "$UUID" "$NAME" "$FLOW" "$server_ip" "$INBOUND_TYPE" "$PASSWORD" "$METHOD" "$INBOUND_PORT" "$H2_SNI" "$USERNAME")
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

prompt_reality_settings() {
    local p
    reading "请输入 Reality 端口（回车随机，默认 ${PORT}）: " p
    [ -n "$p" ] || p="$PORT"
    validate_port "$p" || { red "端口范围需在 1-65535"; return 1; }
    PORT="$p"
    reading "请输入 Reality 伪装域名/SNI（回车默认 ${REALITY_DOMAIN}）: " p
    [ -n "$p" ] || p="$REALITY_DOMAIN"
    validate_domain "$p" || { red "域名需为包含点的 FQDN，且只能包含字母、数字、点或连字符。"; return 1; }
    REALITY_DOMAIN="$p"
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
    if [ "$auto_install" -eq 1 ]; then
        use_default_inbound_profile
    else
        # 先选协议，再按协议输入具体配置（Reality 端口/SNI 仅在选到 Reality 时提示）
        select_inbound_profile || exit 1
    fi
    generate_reality_values
    save_state
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
    purple "4. Hysteria2（自签名 TLS，默认随机高位端口）"
    purple "5. HTTP（用户名/密码代理）"
    purple "6. SOCKS5（用户名/密码代理）"
    reading "请输入编号（默认 1）: " choice
    case "${choice:-1}" in
        1) SELECTED_INBOUND_TYPE="vless-reality" ;;
        2) SELECTED_INBOUND_TYPE="vless" ;;
        3) SELECTED_INBOUND_TYPE="shadowsocks" ;;
        4) SELECTED_INBOUND_TYPE="hysteria2" ;;
        5) SELECTED_INBOUND_TYPE="http" ;;
        6) SELECTED_INBOUND_TYPE="socks" ;;
        *) red "无效的入站协议。"; return 1 ;;
    esac
}

inbound_label() {
    case "$1" in
        vless) printf 'VLESS' ;;
        shadowsocks) printf 'SS' ;;
        hysteria2) printf 'HY2' ;;
        http) printf 'HTTP' ;;
        socks) printf 'SOCKS5' ;;
        *) printf 'VLESS+Reality' ;;
    esac
}

select_inbound_port() {
    local inbound_type="$1" port file
    if [ "$inbound_type" = "vless-reality" ]; then
        SELECTED_INBOUND_PORT="$PORT"
        return 0
    fi
    reading "请输入入站监听端口（留空随机）: " port
    [ -n "$port" ] || port=$(random_port)
    validate_port "$port" || { red "端口范围需在 1-65535"; return 1; }
    if inbound_port_in_use "$port" "$inbound_type"; then
        red "端口已被现有入站占用: $port"
        return 1
    fi
    # 亦不能与 TCP/UDP 转发的本地监听端口冲突
    for file in "$forwards_dir"/*.env; do
        [ -f "$file" ] || continue
        load_forward_file "$file" || continue
        [ "$LOCAL_PORT" = "$port" ] && { red "端口 ${port} 已被转发规则 \"${TAG}\" 占用"; return 1; }
    done
    # 已有同协议同端口入站 -> 新用户将加入该入站（共享）
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        [ "$INBOUND_TYPE" = "$inbound_type" ] || continue
        [ "$INBOUND_PORT" = "$port" ] || continue
        yellow "端口 ${port} 已有 ${inbound_type} 入站，新用户将加入其中（不新建端口）。"
        break
    done
    SELECTED_INBOUND_PORT="$port"
}

select_inbound_profile() {
    # $1=1 时（初始化）作为 Reality 主入站会提示端口/SNI；add_inbound 传 0 复用现有值
    local prompt_reality="${1:-1}"
    select_inbound_type || return 1
    if [ "$SELECTED_INBOUND_TYPE" = "vless-reality" ]; then
        [ "$prompt_reality" = "1" ] && { prompt_reality_settings || return 1; }
        SELECTED_INBOUND_PORT="$PORT"
    else
        select_inbound_port "$SELECTED_INBOUND_TYPE" || return 1
    fi
    SELECTED_INBOUND_PASSWORD=""
    SELECTED_INBOUND_METHOD="$default_ss_method"
    SELECTED_INBOUND_SNI=""
    SELECTED_INBOUND_USERNAME=""
    if [ "$SELECTED_INBOUND_TYPE" = "shadowsocks" ]; then
        reading "请输入 SS 入站密码（留空自动生成）: " SELECTED_INBOUND_PASSWORD
        [ -n "$SELECTED_INBOUND_PASSWORD" ] || SELECTED_INBOUND_PASSWORD=$(generate_password)
    elif [ "$SELECTED_INBOUND_TYPE" = "hysteria2" ]; then
        reading "请输入 Hysteria2 入站密码（留空自动生成）: " SELECTED_INBOUND_PASSWORD
        [ -n "$SELECTED_INBOUND_PASSWORD" ] || SELECTED_INBOUND_PASSWORD=$(generate_password)
        reading "请输入 HY2 SNI（回车默认 ${REALITY_DOMAIN}）: " SELECTED_INBOUND_SNI
        [ -n "$SELECTED_INBOUND_SNI" ] || SELECTED_INBOUND_SNI="$REALITY_DOMAIN"
    elif [ "$SELECTED_INBOUND_TYPE" = "http" ] || [ "$SELECTED_INBOUND_TYPE" = "socks" ]; then
        reading "请输入代理用户名（留空随机）: " SELECTED_INBOUND_USERNAME
        [ -n "$SELECTED_INBOUND_USERNAME" ] || SELECTED_INBOUND_USERNAME="user-$(generate_password)"
        reading "请输入代理密码（留空自动生成）: " SELECTED_INBOUND_PASSWORD
        [ -n "$SELECTED_INBOUND_PASSWORD" ] || SELECTED_INBOUND_PASSWORD=$(generate_password)
    fi
}

use_default_inbound_profile() {
    SELECTED_INBOUND_TYPE="$default_inbound_type"
    SELECTED_INBOUND_PORT="$PORT"
    SELECTED_INBOUND_PASSWORD=""
    SELECTED_INBOUND_METHOD="$default_ss_method"
    SELECTED_INBOUND_SNI=""
    SELECTED_INBOUND_USERNAME=""
}

save_selected_user() {
    if [ "$SELECTED_INBOUND_TYPE" = "hysteria2" ]; then
        ensure_hy2_cert "${SELECTED_INBOUND_SNI:-$REALITY_DOMAIN}" || return 1
    fi
    save_user "$1" "$2" "$3" "$default_flow" "$SELECTED_INBOUND_TYPE" "$SELECTED_INBOUND_PASSWORD" "$SELECTED_INBOUND_METHOD" "$SELECTED_INBOUND_PORT" "${SELECTED_INBOUND_SNI:-}" "${SELECTED_INBOUND_USERNAME:-}"
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
    purple "$(user_link "$uuid" "$name" "$default_flow" "$(get_server_ip)" "$SELECTED_INBOUND_TYPE" "$SELECTED_INBOUND_PASSWORD" "$SELECTED_INBOUND_METHOD" "$SELECTED_INBOUND_PORT" "$SELECTED_INBOUND_SNI" "")\n"
}

add_inbound() {
    local name uuid outbound_tag status join=0 file
    require_reality_state || return 1
    list_outbounds

    select_inbound_profile 0 || return 1

    # 加入已有同协议同端口组（SS 暂不支持一端口多用户）；hy2 组级 SNI 继承
    if [ "$SELECTED_INBOUND_TYPE" != "vless-reality" ] && [ "$SELECTED_INBOUND_TYPE" != "shadowsocks" ]; then
        for file in "$users_dir"/*.env; do
            [ -f "$file" ] || continue
            load_user_file "$file"
            [ "$INBOUND_TYPE" = "$SELECTED_INBOUND_TYPE" ] || continue
            [ "$INBOUND_PORT" = "$SELECTED_INBOUND_PORT" ] || continue
            join=1
            [ "$SELECTED_INBOUND_TYPE" = "hysteria2" ] && SELECTED_INBOUND_SNI="$H2_SNI"
            break
        done
    fi

    reading "请输入入站用户名（英文/数字，仅用于标识本站入站）: " name
    name=$(sanitize_tag "$name")
    [ -n "$name" ] || { red "用户名不能为空"; return 1; }
    user_exists "$name" && { red "用户已存在: $name"; return 1; }

    reading "请输入要绑定的 outbound tag（回车默认 ${direct_outbound_tag}）: " outbound_tag
    [ -n "$outbound_tag" ] || outbound_tag="$direct_outbound_tag"
    outbound_exists "$outbound_tag" || { red "outbound 不存在: $outbound_tag"; return 1; }

    if [ "$SELECTED_INBOUND_TYPE" = "hysteria2" ]; then
        ensure_hy2_cert "${SELECTED_INBOUND_SNI:-$REALITY_DOMAIN}" || return 1
    fi

    uuid=$(generate_uuid)
    save_user "$name" "$uuid" "$outbound_tag" "$default_flow" "$SELECTED_INBOUND_TYPE" "$SELECTED_INBOUND_PASSWORD" "$SELECTED_INBOUND_METHOD" "$SELECTED_INBOUND_PORT" "${SELECTED_INBOUND_SNI:-}" "${SELECTED_INBOUND_USERNAME:-}"

    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        rm -f "$(user_file "$name")"
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi

    allow_port "$SELECTED_INBOUND_PORT"
    if [ "$join" -eq 1 ]; then
        green "已加入入站：${name} -> ${outbound_tag} (${SELECTED_INBOUND_TYPE}, port=${SELECTED_INBOUND_PORT})"
    else
        green "已添加入站用户：${name} -> ${outbound_tag} ($(inbound_label "$SELECTED_INBOUND_TYPE"), port=${SELECTED_INBOUND_PORT})"
    fi
    purple "$(user_link "$uuid" "$name" "$default_flow" "$(get_server_ip)" "$SELECTED_INBOUND_TYPE" "$SELECTED_INBOUND_PASSWORD" "$SELECTED_INBOUND_METHOD" "$SELECTED_INBOUND_PORT" "$SELECTED_INBOUND_SNI" "$SELECTED_INBOUND_USERNAME")\n"
}

# 把已导入的落地绑定为指定入站分组上的【新用户】（自动生成凭据，不覆盖现有用户）
bind_landing_to_group() {
    local outbound_tag="$1" type="$2" port="$3" name uuid pw sni username status
    name=$(sanitize_tag "$outbound_tag")
    if user_exists "$name"; then
        name="${name}-$(date +%s)"
    fi
    case "$type" in
        vless-reality)
            uuid=$(generate_uuid)
            save_user "$name" "$uuid" "$outbound_tag" "$default_flow" "$type" "" "" "$port" ""
            ;;
        vless)
            uuid=$(generate_uuid)
            save_user "$name" "$uuid" "$outbound_tag" "" "$type" "" "" "$port" ""
            ;;
        hysteria2)
            sni=$(group_member_field "$type" "$port" H2_SNI "$REALITY_DOMAIN")
            ensure_hy2_cert "$sni" || return 1
            pw=$(generate_password)
            save_user "$name" "" "$outbound_tag" "" "$type" "$pw" "" "$port" "$sni"
            ;;
        http|socks)
            username="user-$(generate_password)"
            pw=$(generate_password)
            save_user "$name" "" "$outbound_tag" "" "$type" "$pw" "" "$port" "" "$username"
            ;;
        *)
            red "不支持的入站类型：$type"
            return 1
            ;;
    esac

    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        rm -f "$(user_file "$name")"
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi
    allow_port "$port"
    green "已绑定落地：用户 ${name} -> ${outbound_tag} (${type}, port=${port})"
}

# 修改某个入站的 outbound 绑定（失败自动还原）
change_user_outbound() {
    local name="$1" new_outbound_tag="$2" file old_outbound_tag status sni
    file=$(user_file "$name")
    [ -f "$file" ] || { red "入站不存在：$name"; return 1; }
    outbound_exists "$new_outbound_tag" || { red "落地不存在：$new_outbound_tag"; return 1; }
    load_user_file "$file"
    old_outbound_tag="$OUTBOUND_TAG"
    [ "$old_outbound_tag" = "$new_outbound_tag" ] && { yellow "绑定未变化。"; return 0; }
    sni=""; [ "$INBOUND_TYPE" = "hysteria2" ] && sni="$H2_SNI"
    save_user "$name" "$UUID" "$new_outbound_tag" "$FLOW" "$INBOUND_TYPE" "$PASSWORD" "$METHOD" "$INBOUND_PORT" "$sni"
    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        sni=""; [ "$INBOUND_TYPE" = "hysteria2" ] && sni="$H2_SNI"
        save_user "$name" "$UUID" "$old_outbound_tag" "$FLOW" "$INBOUND_TYPE" "$PASSWORD" "$METHOD" "$INBOUND_PORT" "$sni"
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi
    green "已更新绑定：入站 ${name} -> 落地 ${new_outbound_tag}"
}

# 修改入站绑定的落地（列出可选项，输入 tag）
change_user_outbound_menu() {
    local name="$1" tag
    list_outbounds
    reading "请输入要绑定到的落地 outbound tag（可输入 ${direct_outbound_tag} 或落地 tag）: " tag
    [ -n "$tag" ] || tag="$direct_outbound_tag"
    change_user_outbound "$name" "$tag"
}

# 删除入站（失败自动还原；保留至少一个入站的保护）
delete_user() {
    local name="$1" file backup status
    file=$(user_file "$name")
    [ -f "$file" ] || { red "入站不存在：$name"; return 1; }
    has_more_inbound_users "$name" || { red "至少保留一个入站用户。"; return 1; }
    backup="${file}.bak.$(date +%s)"
    mv "$file" "$backup"
    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        mv "$backup" "$file"
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi
    rm -f "$backup"
    green "已删除用户：$name"
}

# 修改入站端口（组级：同协议同端口整组迁移）；Reality 走 change_port（主端口）
change_inbound_port_group() {
    local type="$1" old_port="$2" new_port status members name backup_dir f u o fl i pw m sn
    if [ "$type" = "vless-reality" ]; then
        change_port
        return
    fi
    members=$(group_member_names "$type" "$old_port")
    [ -n "$members" ] || { red "入站不存在：$(group_label "$type" "$old_port")"; return 1; }
    reading "请输入新的监听端口（回车随机）: " new_port
    [ -n "$new_port" ] || new_port=$(random_port)
    validate_port "$new_port" || { red "端口范围需在 1-65535"; return 1; }
    [ "$new_port" = "$old_port" ] && { yellow "端口未变化。"; return 0; }
    if inbound_port_in_use "$new_port" "$type"; then
        red "端口已被现有入站或转发占用：$new_port"
        return 1
    fi

    backup_dir="${work_dir}/chgport-$(date +%s).bak"
    mkdir -p "$backup_dir" 2>/dev/null || { red "无法创建备份目录。"; return 1; }
    for name in $members; do mv "$(user_file "$name")" "$backup_dir/${name}.env"; done

    for name in $members; do
        f="$backup_dir/${name}.env"
        u=$(read_env_value "$f" UUID || true)
        o=$(read_env_value "$f" OUTBOUND_TAG || true)
        fl=$(read_env_value "$f" FLOW || true)
        i=$(read_env_value "$f" INBOUND_TYPE || true)
        pw=$(read_env_value "$f" PASSWORD || true)
        m=$(read_env_value "$f" METHOD || true)
        sn=$(read_env_value "$f" H2_SNI || true)
        save_user "$name" "$u" "$o" "$fl" "$i" "$pw" "$m" "$new_port" "$sn"
    done

    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        for name in $members; do mv "$backup_dir/${name}.env" "$(user_file "$name")" 2>/dev/null || true; done
        rmdir "$backup_dir" 2>/dev/null || true
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi
    rm -rf "$backup_dir"
    allow_port "$new_port"
    green "入站端口已更新：$(group_label "$type" "$old_port") -> ${new_port}（用户: ${members}）"
}

# 修改入站 SNI（组级，整组一致）；Reality 走 change_reality_domain，仅 hy2 支持自定义 SNI
change_inbound_sni_group() {
    local type="$1" port="$2" sni old_sni status members name backup_dir f u o fl i pw m sn
    if [ "$type" = "vless-reality" ]; then
        change_reality_domain
        return
    fi
    if [ "$type" != "hysteria2" ]; then
        yellow "该入站类型不支持修改 SNI。"
        return 1
    fi
    reading "请输入新的 SNI（回车默认 ${REALITY_DOMAIN}）: " sni
    [ -n "$sni" ] || sni="$REALITY_DOMAIN"
    validate_domain "$sni" || { red "SNI 需为包含点的 FQDN，且只能包含字母、数字、点或连字符。"; return 1; }
    old_sni=$(group_member_field "$type" "$port" H2_SNI "$REALITY_DOMAIN")
    [ "$sni" = "$old_sni" ] && { yellow "SNI 未变化。"; return 0; }
    ensure_hy2_cert "$sni" || return 1

    members=$(group_member_names "$type" "$port")
    backup_dir="${work_dir}/chgsni-$(date +%s).bak"
    mkdir -p "$backup_dir" 2>/dev/null || { red "无法创建备份目录。"; return 1; }
    for name in $members; do mv "$(user_file "$name")" "$backup_dir/${name}.env"; done

    for name in $members; do
        f="$backup_dir/${name}.env"
        u=$(read_env_value "$f" UUID || true)
        o=$(read_env_value "$f" OUTBOUND_TAG || true)
        fl=$(read_env_value "$f" FLOW || true)
        i=$(read_env_value "$f" INBOUND_TYPE || true)
        pw=$(read_env_value "$f" PASSWORD || true)
        m=$(read_env_value "$f" METHOD || true)
        sn=$(read_env_value "$f" H2_SNI || true)
        save_user "$name" "$u" "$o" "$fl" "$i" "$pw" "$m" "$port" "$sni"
    done

    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        for name in $members; do mv "$backup_dir/${name}.env" "$(user_file "$name")" 2>/dev/null || true; done
        rmdir "$backup_dir" 2>/dev/null || true
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi
    rm -rf "$backup_dir"
    green "SNI 已更新：$(group_label "$type" "$port") -> $sni"
}

# 修改 SS/HY2 入站密码
change_inbound_password() {
    local name="$1" file pw old_pw status sni
    file=$(user_file "$name")
    load_user_file "$file"
    if [ "$INBOUND_TYPE" != "shadowsocks" ] && [ "$INBOUND_TYPE" != "hysteria2" ]; then
        yellow "该入站类型无需密码。"
        return 1
    fi
    reading "请输入新的密码（回车自动生成）: " pw
    [ -n "$pw" ] || pw=$(generate_password)
    old_pw="$PASSWORD"
    sni=""; [ "$INBOUND_TYPE" = "hysteria2" ] && sni="$H2_SNI"
    save_user "$name" "$UUID" "$OUTBOUND_TAG" "$FLOW" "$INBOUND_TYPE" "$pw" "$METHOD" "$INBOUND_PORT" "$sni"
    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        sni=""; [ "$INBOUND_TYPE" = "hysteria2" ] && sni="$H2_SNI"
        save_user "$name" "$UUID" "$OUTBOUND_TAG" "$FLOW" "$INBOUND_TYPE" "$old_pw" "$METHOD" "$INBOUND_PORT" "$sni"
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi
    green "密码已更新：$name"
}

# 可见入站用户总数（删除保护用）
visible_user_count() {
    local file count=0
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        user_is_visible || continue
        count=$((count + 1))
    done
    printf '%s' "$count"
}

# 组概要：`alice->direct, bob->落地1`
group_summary() {
    local type="$1" port="$2" members first=1 m
    members=$(group_member_names "$type" "$port")
    for m in $members; do
        load_user_file "$(user_file "$m")"
        [ "$first" -eq 1 ] || printf ', '
        first=0
        printf '%s->%s' "$NAME" "$OUTBOUND_TAG"
    done
}

# 打印带序号的入站分组列表（依赖 collect_inbound_groups 已执行）
list_inbound_groups() {
    local i g type port
    if [ "${#INBOUND_GROUPS[@]}" -eq 0 ]; then
        purple "（暂无入站）"
        return 0
    fi
    green "\n=== 入站列表（按 协议+端口 分组） ===\n"
    for i in "${!INBOUND_GROUPS[@]}"; do
        g="${INBOUND_GROUPS[$i]}"
        type="${g%%|*}"
        port="${g##*|}"
        purple "$((i + 1))) $(group_label "$type" "$port")  [$(group_summary "$type" "$port")]"
    done
}

# 选择一个入站分组到全局 GROUP_TYPE/GROUP_PORT/GROUP_MEMBERS
select_inbound_group() {
    local g idx name
    GROUP_TYPE=""; GROUP_PORT=""; GROUP_MEMBERS=()
    collect_inbound_groups
    if [ "${#INBOUND_GROUPS[@]}" -eq 0 ]; then
        yellow "暂无入站。请先选择 1 初始化节点，或在本菜单选择 1 增加入站。"
        return 1
    fi
    list_inbound_groups
    pick_index "${#INBOUND_GROUPS[@]}" || return 1
    g="${INBOUND_GROUPS[$((PICKED_INDEX - 1))]}"
    GROUP_TYPE="${g%%|*}"
    GROUP_PORT="${g##*|}"
    for name in $(group_member_names "$GROUP_TYPE" "$GROUP_PORT"); do
        GROUP_MEMBERS+=("$name")
    done
}

# 选择一个组内用户到全局 GROUP_MEMBER
pick_group_member() {
    local type="$1" port="$2" members i name
    members=$(group_member_names "$type" "$port")
    [ -n "$members" ] || { yellow "该入站暂无用户。"; return 1; }
    green "\n请选择该入站中的用户："
    i=0
    for name in $members; do
        i=$((i + 1))
        purple "${i}) ${name}"
    done
    pick_index "$i" || return 1
    GROUP_MEMBER=$(printf '%s' "$members" | awk -v n="$PICKED_INDEX" '{print $n}')
}

# 向既有入站分组添加一个用户（绑定到所选 outbound）
add_user_to_inbound() {
    local type="$1" port="$2" name outbound_tag uuid pw sni username status
    if [ "$type" = "shadowsocks" ]; then
        red "SS 暂不支持一端口多用户。"
        return 1
    fi
    list_outbounds
    reading "请输入该用户绑定的 outbound tag（回车默认 ${direct_outbound_tag}）: " outbound_tag
    [ -n "$outbound_tag" ] || outbound_tag="$direct_outbound_tag"
    outbound_exists "$outbound_tag" || { red "outbound 不存在: $outbound_tag"; return 1; }
    reading "请输入用户名（英文/数字）: " name
    name=$(sanitize_tag "$name")
    [ -n "$name" ] || { red "用户名不能为空"; return 1; }
    user_exists "$name" && { red "用户已存在: $name"; return 1; }

    case "$type" in
        vless-reality)
            uuid=$(generate_uuid)
            save_user "$name" "$uuid" "$outbound_tag" "$default_flow" "$type" "" "" "$port" ""
            ;;
        vless)
            uuid=$(generate_uuid)
            save_user "$name" "$uuid" "$outbound_tag" "" "$type" "" "" "$port" ""
            ;;
        hysteria2)
            sni=$(group_member_field "$type" "$port" H2_SNI "$REALITY_DOMAIN")
            ensure_hy2_cert "$sni" || return 1
            reading "请输入密码（回车自动生成）: " pw
            [ -n "$pw" ] || pw=$(generate_password)
            save_user "$name" "" "$outbound_tag" "" "$type" "$pw" "" "$port" "$sni"
            ;;
        http|socks)
            reading "请输入代理用户名（留空随机）: " username
            [ -n "$username" ] || username="user-$(generate_password)"
            reading "请输入代理密码（回车自动生成）: " pw
            [ -n "$pw" ] || pw=$(generate_password)
            save_user "$name" "" "$outbound_tag" "" "$type" "$pw" "" "$port" "" "$username"
            ;;
    esac

    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        rm -f "$(user_file "$name")"
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi
    allow_port "$port"
    green "已添加用户：${name} -> ${outbound_tag} ($(group_label "$type" "$port"))"
    load_user_file "$(user_file "$name")"
    purple "$(user_link "$UUID" "$NAME" "$FLOW" "$(get_server_ip)" "$INBOUND_TYPE" "$PASSWORD" "$METHOD" "$INBOUND_PORT" "$H2_SNI" "$USERNAME")\n"
}

# 删除整个入站分组（连同其所有用户；失败自动还原；保留至少一个用户保护）
delete_inbound_group() {
    local type="$1" port="$2" members backup_dir status name x word_count total
    members=$(group_member_names "$type" "$port")
    [ -n "$members" ] || { red "入站为空：$(group_label "$type" "$port")"; return 1; }
    word_count=0; for x in $members; do word_count=$((word_count + 1)); done
    total=$(visible_user_count)
    [ "$total" -gt "$word_count" ] || { red "至少保留一个入站用户，不能删除最后一个入站。"; return 1; }
    backup_dir="${work_dir}/delin-$(date +%s).bak"
    mkdir -p "$backup_dir" 2>/dev/null || { red "无法创建备份目录。"; return 1; }
    for name in $members; do mv "$(user_file "$name")" "$backup_dir/${name}.env"; done

    apply_config
    status=$?
    if [ "$status" -ne 0 ]; then
        for name in $members; do mv "$backup_dir/${name}.env" "$(user_file "$name")" 2>/dev/null || true; done
        rmdir "$backup_dir" 2>/dev/null || true
        write_config >/dev/null 2>&1 || true
        [ "$status" -eq 2 ] && restart_singbox >/dev/null 2>&1 || true
        return 1
    fi
    rm -rf "$backup_dir"
    green "已删除入站：$(group_label "$type" "$port")（用户: ${members}）"
}

# 主菜单"列出节点链接"：遍历所有可见用户，打印其类型/端口/出站与标准代理链接
list_node_links() {
    local file found=0 server_ip
    server_ip=$(get_server_ip)
    green "\n=== 全部节点链接 ===\n"
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        user_is_visible || continue
        found=1
        green "${NAME} ($(inbound_label "$INBOUND_TYPE"), port=${INBOUND_PORT}) -> ${OUTBOUND_TAG}"
        purple "$(user_link "$UUID" "$NAME" "$FLOW" "$server_ip" "$INBOUND_TYPE" "$PASSWORD" "$METHOD" "$INBOUND_PORT" "$H2_SNI" "$USERNAME")\n"
    done
    [ "$found" -eq 1 ] || yellow "（暂无可见节点）"
}

# 单个入站分组的子菜单（循环直到返回）
manage_group_menu() {
    local type="$1" port="$2" sub members m
    while :; do
        members=$(group_member_names "$type" "$port")
        clear_screen
        green "=== 入站: $(group_label "$type" "$port") ===\n"
        for m in $members; do
            load_user_file "$(user_file "$m")"
            purple "  ${NAME} -> ${OUTBOUND_TAG}"
        done
        purple ""
        green "1. 添加用户"
        green "2. 修改端口"
        [ "$type" = "hysteria2" ] && green "3. 修改 SNI"
        green "4. 编辑用户出站"
        green "5. 删除用户"
        green "6. 删除入站（连同所有用户）"
        purple "0. 返回"
        reading "请输入选择: " sub
        case "$sub" in
            0) return ;;
            1) add_user_to_inbound "$type" "$port" ;;
            2) change_inbound_port_group "$type" "$port" ;;
            3) [ "$type" = "hysteria2" ] && change_inbound_sni_group "$type" "$port" || red "无效的选项" ;;
            4) pick_group_member "$type" "$port" && change_user_outbound_menu "$GROUP_MEMBER" ;;
            5) pick_group_member "$type" "$port" && delete_user "$GROUP_MEMBER" ;;
            6) delete_inbound_group "$type" "$port" && return ;;
            *) red "无效的选项" ;;
        esac
        [ "$sub" != "0" ] && { read -r -n 1 -s -p $'\033[1;91m按任意键返回...\033[0m'; echo ""; }
    done
}

manage_inbound_menu() {
    local sub
    require_reality_state || return 1
    clear_screen
    green "=== 入站管理 ===\n"
    green "1. 增加入站"
    green "2. 选择一个入站进行管理"
    purple "0. 返回主菜单"
    reading "请输入选择: " sub
    case "$sub" in
        1) add_inbound ;;
        2) select_inbound_group && manage_group_menu "$GROUP_TYPE" "$GROUP_PORT" ;;
        0) return ;;
        *) red "无效的选项" ;;
    esac
}

decode_import_input() {
    local input="$1" decoded
    input=$(trim "$input")
    if [[ "$input" == ss://* || "$input" == vless://* || "$input" == http://* || "$input" == https://* || "$input" == socks5://* || "$input" == socks://* ]]; then
        printf '%s' "$input"
        return 0
    fi
    decoded=$(b64_decode "$input") || return 1
    decoded=$(trim "$decoded")
    if [[ "$decoded" == ss://* || "$decoded" == vless://* || "$decoded" == http://* || "$decoded" == https://* || "$decoded" == socks5://* || "$decoded" == socks://* ]]; then
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

import_socks_uri() {
    local uri body fragment main auth hostport username password server server_port tag display_name
    uri="$PARSED_URI"
    body="$PARSED_BODY"
    fragment="$PARSED_FRAGMENT"
    case "$uri" in
        socks5://*|socks://*) ;;
        *) red "导入内容不是 socks5:// 或 socks://"; return 1 ;;
    esac

    main="$body"
    username=""
    password=""
    if [[ "$main" == *@* ]]; then
        auth=${main%@*}
        hostport=${main#*@}
        if [[ "$auth" == *:* ]]; then
            username=$(url_decode "${auth%%:*}")
            password=$(url_decode "${auth#*:}")
        else
            username=$(url_decode "$auth")
        fi
    else
        hostport="$main"
    fi

    IFS='|' read -r server server_port <<< "$(split_hostport "$hostport")"

    [ -n "$server" ] || { red "SOCKS5 落地缺少服务器地址。"; return 1; }
    validate_port "$server_port" || { red "SOCKS5 落地端口无效。"; return 1; }

    reading "请输入落地 tag（留空使用链接名称）: " tag
    [ -n "$tag" ] || tag="${fragment:-socks5-$(date +%s)}"
    tag=$(sanitize_tag "$tag")
    validate_new_outbound_tag "$tag" || return 1
    display_name="${fragment:-$tag}"
    save_socks_outbound "$tag" "$display_name" "$server" "$server_port" "$username" "$password"
    imported_outbound_tag="$tag"
}

import_outbound_from_input() {
    local input
    require_reality_state || return 1
    prepare_import_base
    reading "请输入落地链接或其 base64（支持 ss/vless/http/https/socks5）： " input
    parse_common_uri "$input" || { red "无法解析导入内容。"; return 1; }

    case "$PARSED_URI" in
        ss://*) import_shadowsocks_uri ;;
        vless://*) import_vless_uri ;;
        http://*|https://*) import_http_uri ;;
        socks5://*|socks://*) import_socks_uri ;;
        *) red "不支持的落地协议。"; return 1 ;;
    esac
}

import_outbound_auto() {
    local outbound_tag g type port
    require_reality_state || return 1
    import_outbound_from_input || return 1
    outbound_tag="$imported_outbound_tag"

    collect_inbound_groups
    if [ "${#INBOUND_GROUPS[@]}" -eq 0 ]; then
        yellow "当前没有任何入站，已自动创建绑定该落地的新用户。"
        create_bound_user_for_outbound "$outbound_tag" || return 1
        return 0
    fi

    green "落地 ${outbound_tag} 已添加，请选择要把该落地挂到哪个入站（将在其上新建一个用户，不覆盖现有用户）："
    list_inbound_groups
    pick_index "${#INBOUND_GROUPS[@]}" || { rm -f "$(outbound_file "$outbound_tag")"; return 1; }
    g="${INBOUND_GROUPS[$((PICKED_INDEX - 1))]}"
    type="${g%%|*}"
    port="${g##*|}"
    if [ "$type" = "shadowsocks" ]; then
        red "SS 暂不支持一端口多用户，请在入站管理中选择 HY2/VLESS/VLESS+Reality 入站。"
        rm -f "$(outbound_file "$outbound_tag")"
        write_config >/dev/null 2>&1 || true
        return 1
    fi
    if ! bind_landing_to_group "$outbound_tag" "$type" "$port"; then
        rm -f "$(outbound_file "$outbound_tag")"
        write_config >/dev/null 2>&1 || true
        return 1
    fi
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

delete_outbound_by_tag() {
    local tag="$1" file user users backup_dir status item count=0
    [ -n "$tag" ] || { red "缺少落地 tag。"; return 1; }
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

# ── TCP/UDP 转发（realm 用户态） ────────────────────────────────────

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

# realm 目标映射（realm release 资产命名）
realm_target_for_arch() {
    local arch="$1" libc
    if command_exists apk; then libc="unknown-linux-musl"; else libc="unknown-linux-gnu"; fi
    case "$arch" in
        amd64) arch="x86_64" ;;
        arm64) arch="aarch64" ;;
        386)   arch="i686" ;;
        armv7) arch="armv7"; libc="unknown-linux-musleabihf" ;;
        *) return 1 ;;
    esac
    printf '%s-%s' "$arch" "$libc"
}

install_realm() {
    local arch target latest tmp_dir dl_url realm_file
    [ -x "$realm_bin" ] && return 0
    arch=$(detect_arch)
    target=$(realm_target_for_arch "$arch") || { red "realm 暂不支持该架构: $(uname -m)"; return 1; }
    latest=$(curl -fsSL "https://api.github.com/repos/zhboner/realm/releases/latest" 2>/dev/null | sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$latest" ] || { red "获取 realm 版本失败"; return 1; }
    tmp_dir=$(mktemp -d)
    dl_url="https://github.com/zhboner/realm/releases/download/v${latest}/realm-${target}.tar.gz"
    yellow "下载 realm v${latest} (${target})..."
    if ! curl -fL --retry 3 -o "$tmp_dir/realm.tar.gz" "$dl_url"; then
        case "$target" in
            *-gnu)      target="${target%-gnu}-unknown-linux-musl" ;;
            *-musleabihf) target="${target%-unknown-linux-musleabihf}-unknown-linux-gnu" ;;
            *-musl)     target="${target%-unknown-linux-musl}-unknown-linux-gnu" ;;
        esac
        dl_url="https://github.com/zhboner/realm/releases/download/v${latest}/realm-${target}.tar.gz"
        yellow "回退尝试 libc: ${target}"
        curl -fL --retry 3 -o "$tmp_dir/realm.tar.gz" "$dl_url" || { rm -rf "$tmp_dir"; red "realm 下载失败"; return 1; }
    fi
    tar -xzf "$tmp_dir/realm.tar.gz" -C "$tmp_dir" 2>/dev/null || { rm -rf "$tmp_dir"; red "解压 realm 失败"; return 1; }
    mkdir -p "$realm_work"
    realm_file="$tmp_dir/realm"
    [ -f "$realm_file" ] || realm_file=$(find "$tmp_dir" -type f -name realm 2>/dev/null | head -n 1)
    [ -n "$realm_file" ] && [ -f "$realm_file" ] || { rm -rf "$tmp_dir"; red "未在压缩包中找到 realm 可执行文件"; return 1; }
    mv "$realm_file" "$realm_bin"
    chmod +x "$realm_bin"
    rm -rf "$tmp_dir"
    green "realm 已安装: $realm_bin"
}

require_realm() {
    [ -x "$realm_bin" ] || install_realm || { yellow "realm 不可用，无法启用用户态转发。"; return 1; }
    return 0
}

write_realm_config() {
    local file first=1 tag protocol local_port target_addr target_port no_tcp use_udp remote
    mkdir -p "$realm_work"
    {
        printf '{\n  "log": { "level": "warn" },\n  "endpoints": [\n'
        for file in "$forwards_dir"/*.env; do
            [ -f "$file" ] || continue
            load_forward_file "$file" || continue
            tag="$TAG"; protocol="$PROTOCOL"; local_port="$LOCAL_PORT"
            target_addr="$TARGET_ADDR"; target_port="$TARGET_PORT"
            [ -n "$tag" ] && validate_port "$local_port" || continue
            [ -z "$protocol" ] && protocol="tcp udp"
            # 目标为 IPv6 时需加方括号，如 [2001:db8::1]:443；先去掉用户可能已输入的方括号
            remote="$target_addr"
            remote="${remote#[}"; remote="${remote%]}"
            [[ "$remote" == *:* ]] && remote="[${remote}]"
            remote="${remote}:${target_port}"
            [ "$first" -eq 1 ] || printf ',\n'
            first=0
            case " $protocol " in *tcp*) no_tcp=false ;; *) no_tcp=true ;; esac
            case " $protocol " in *udp*) use_udp=true ;; *) use_udp=false ;; esac
            printf '    {\n'
            printf '      "listen": %s,\n' "$(json_string "0.0.0.0:${local_port}")"
            printf '      "remote": %s,\n' "$(json_string "$remote")"
            printf '      "network": { "no_tcp": %s, "use_udp": %s }\n' "$no_tcp" "$use_udp"
            printf '    }'
        done
        printf '\n  ]\n}\n'
    } > "$realm_config"
    chmod 600 "$realm_config"
}

# 无 systemd/OpenRC 时的兜底：以直连后台进程方式运行 realm（适用于无 init 的容器）
realm_direct_pid() {
    printf '%s/realm.pid' "$realm_work"
}

stop_realm_direct() {
    local pidfile pid
    pidfile=$(realm_direct_pid)
    [ -f "$pidfile" ] || return 0
    pid=$(cat "$pidfile" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$pidfile"
}

start_realm_direct() {
    local pidfile
    mkdir -p "$realm_work"
    pidfile=$(realm_direct_pid)
    stop_realm_direct
    nohup "$realm_bin" -c "$realm_config" >/dev/null 2>&1 &
    echo $! > "$pidfile"
    sleep 1
}

restart_realm() {
    if command_exists systemctl && [ -f /etc/systemd/system/realm.service ]; then
        systemctl restart realm 2>/dev/null
    elif command_exists rc-service && [ -f /etc/init.d/realm ]; then
        rc-service realm restart 2>/dev/null
    else
        start_realm_direct
    fi
}

install_realm_service() {
    if command_exists systemctl; then
        cat > /etc/systemd/system/realm.service << EOF
[Unit]
Description=realm TCP/UDP forward
After=network.target

[Service]
Type=simple
ExecStart=${realm_bin} -c ${realm_config}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now realm
    elif command_exists rc-service && command_exists rc-update; then
        cat > /etc/init.d/realm << EOF
#!/sbin/openrc-run
description="realm TCP/UDP forward"
command="${realm_bin}"
command_args="-c ${realm_config}"
command_background=true
pidfile="/run/realm.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/realm
        rc-update add realm default >/dev/null 2>&1
        rc-service realm restart
    else
        yellow "未检测到 systemd/OpenRC，realm 以后台进程方式运行（容器重启后需再次添加转发以拉起）。"
        start_realm_direct
        return 0
    fi
}

uninstall_realm_service() {
    if command_exists systemctl && [ -f /etc/systemd/system/realm.service ]; then
        systemctl disable --now realm 2>/dev/null || true
        rm -f /etc/systemd/system/realm.service
        systemctl daemon-reload 2>/dev/null || true
    fi
    if command_exists rc-service && [ -f /etc/init.d/realm ]; then
        rc-service realm stop 2>/dev/null || true
        rc-update del realm default 2>/dev/null || true
        rm -f /etc/init.d/realm
    fi
    stop_realm_direct
    rm -rf "$realm_work" 2>/dev/null || true
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
    # 用户态 realm 转发，支持 IPv4/IPv6/域名目标地址

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

    if ! require_realm; then
        rm -f "$(forward_file "$tag")"
        return 1
    fi
    write_realm_config
    if [ -f /etc/systemd/system/realm.service ] || [ -f /etc/init.d/realm ]; then
        restart_realm
    else
        install_realm_service || { rm -f "$(forward_file "$tag")"; return 1; }
    fi
    allow_port "$local_port" "$protocol"

    green "转发规则已添加: ${tag} | ${protocol} | :${local_port} -> ${target_addr}:${target_port} (用户态 realm)"
}

delete_forward() {
    local tag file
    ensure_state_layout
    list_forwards_cli
    has_forwards || { yellow "暂无转发规则。"; return 1; }

    reading "请输入要删除的转发规则名称: " tag
    tag=$(sanitize_tag "$tag")
    file=$(forward_file "$tag")
    [ -f "$file" ] || { red "转发规则不存在: $tag"; return 1; }

    rm -f "$file"
    if has_forwards; then
        write_realm_config
        restart_realm
    else
        uninstall_realm_service
    fi
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
    local outbound_tag users sub
    require_reality_state || return 1
    clear_screen
    green "=== 落地管理 ===\n"
    collect_outbound_tags
    if [ "${#OUTBOUND_TAGS[@]}" -eq 0 ]; then
        yellow "尚未添加任何落地。请在主菜单选择 2 添加落地。"
        return 1
    fi
    list_outbounds_numbered
    pick_index "${#OUTBOUND_TAGS[@]}" || return 1
    outbound_tag="${OUTBOUND_TAGS[$((PICKED_INDEX - 1))]}"

    load_outbound_file "$(outbound_file "$outbound_tag")"
    users=$(users_for_outbound "$outbound_tag")
    green "\n落地：${outbound_tag} | ${TYPE} | ${DISPLAY_NAME:-$SERVER:$SERVER_PORT}"
    purple "绑定用户：${users:-无}\n"
    green "1. 删除该落地"
    green "2. 改绑到某个用户"
    purple "0. 返回主菜单"
    reading "请输入选择: " sub

    case "$sub" in
        1) delete_outbound_by_tag "$outbound_tag" ;;
        2) rebind_outbound_inbound "$outbound_tag" ;;
        0) return ;;
        *) red "无效的选项" ;;
    esac
}

rebind_outbound_inbound() {
    local outbound_tag="$1" g type port
    collect_inbound_groups
    if [ "${#INBOUND_GROUPS[@]}" -eq 0 ]; then
        yellow "暂无入站可绑定。"
        return 1
    fi
    green "\n请选择要把落地（${outbound_tag}）绑到哪个入站："
    list_inbound_groups
    pick_index "${#INBOUND_GROUPS[@]}" || return 1
    g="${INBOUND_GROUPS[$((PICKED_INDEX - 1))]}"
    type="${g%%|*}"
    port="${g##*|}"
    pick_group_member "$type" "$port" || return 1
    change_user_outbound "$GROUP_MEMBER" "$outbound_tag" || return 1
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

            # 清理所有转发规则（realm 服务 + 配置）
            uninstall_realm_service

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
    green "2. 添加落地"
    green "3. 列出节点链接"
    green "4. 入站管理"
    green "5. 落地管理"
    green "6. TCP/UDP 转发管理"
    green "7. 服务与日志"
    red "8. 卸载 sing-box"
    red "0. 退出脚本"
    reading "请输入选择(0-8): " choice
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
        3) list_node_links ;;
        4) manage_inbound_menu ;;
        5) manage_route_menu ;;
        6) manage_forwards_menu ;;
        7) manage_singbox ;;
        8) uninstall_singbox ;;
        0) exit 0 ;;
        *) red "无效的选项，请输入 0 到 8" ;;
    esac
    read -r -n 1 -s -p $'\033[1;91m按任意键返回...\033[0m'
    echo ""
done
