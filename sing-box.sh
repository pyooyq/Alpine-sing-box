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
users_dir="${work_dir}/users.d"
outbounds_dir="${work_dir}/outbounds.d"
installed_script="${work_dir}/sb.sh"
reality_domain="cas-bridge.xethub.hf.co"
vless_port=""
auto_install=0
reality_inbound_tag="reality-in"
direct_outbound_tag="direct"
block_outbound_tag="block"
default_user_name="default-direct"
default_flow="xtls-rprx-vision"
default_fingerprint="chrome"

usage() {
    cat << EOF
sing-box Reality 中转/本机节点管理脚本

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

load_state() {
    [ -f "$state_file" ] && . "$state_file"
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
    mkdir -p "$work_dir" "$users_dir" "$outbounds_dir"
    chmod 755 "$work_dir"
    chmod 700 "$users_dir" "$outbounds_dir"
}

user_file() {
    printf '%s/%s.env' "$users_dir" "$(sanitize_tag "$1")"
}

outbound_file() {
    printf '%s/%s.env' "$outbounds_dir" "$(sanitize_tag "$1")"
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

validate_new_outbound_tag() {
    local tag="$1"
    [ -n "$tag" ] || { red "tag 不能为空"; return 1; }
    [ "$tag" != "$direct_outbound_tag" ] && [ "$tag" != "$block_outbound_tag" ] || { red "不能使用内置 tag: $tag"; return 1; }
    outbound_exists "$tag" && { red "outbound 已存在: $tag"; return 1; }
}

load_user_file() {
    NAME="" UUID="" FLOW="$default_flow" OUTBOUND_TAG="$direct_outbound_tag"
    . "$1"
    FLOW="${FLOW:-$default_flow}"
    OUTBOUND_TAG="${OUTBOUND_TAG:-$direct_outbound_tag}"
}

save_user() {
    local name="$1" uuid="$2" outbound_tag="$3" flow="${4:-$default_flow}" file
    name=$(sanitize_tag "$name")
    file=$(user_file "$name")
    {
        write_env_line NAME "$name"
        write_env_line UUID "$uuid"
        write_env_line FLOW "$flow"
        write_env_line OUTBOUND_TAG "$outbound_tag"
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
    local tag="$1" display_name="$2" server="$3" server_port="$4" uuid="$5" flow="$6" network="$7" tls_enabled="$8" tls_server_name="$9" tls_insecure="${10}" reality_enabled="${11}" reality_public_key="${12}" reality_short_id="${13}" utls_fingerprint="${14}" file
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
        write_env_line NETWORK "${network:-tcp}"
        write_env_line TLS_ENABLED "${tls_enabled:-0}"
        write_env_line TLS_SERVER_NAME "$tls_server_name"
        write_env_line TLS_INSECURE "${tls_insecure:-0}"
        write_env_line REALITY_ENABLED "${reality_enabled:-0}"
        write_env_line REALITY_PUBLIC_KEY "$reality_public_key"
        write_env_line REALITY_SHORT_ID "$reality_short_id"
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
        local legacy_uuid="${UUID:-}"
        [ -n "$legacy_uuid" ] || legacy_uuid=$(generate_uuid)
        save_user "$default_user_name" "$legacy_uuid" "$direct_outbound_tag"
    fi
}

require_reality_state() {
    migrate_legacy_state || {
        yellow "尚未安装，请先选择 1 安装 / 初始化 Reality 节点。"
        return 1
    }
}

validate_config_file() {
    local file="$1" check_output

    is_working_singbox "${work_dir}/${server_name}" || return 0
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

render_inbound_users_json() {
    local file first=1 name uuid flow
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        name="$NAME"
        uuid="$UUID"
        flow="$FLOW"
        [ -n "$name" ] && [ -n "$uuid" ] || continue
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        printf '        {\n'
        printf '          "name": %s,\n' "$(json_string "$name")"
        printf '          "uuid": %s,\n' "$(json_string "$uuid")"
        printf '          "flow": %s\n' "$(json_string "$flow")"
        printf '        }'
    done
}

render_outbound_json() {
    local file first=0 tag type display server server_port username password method plugin plugin_opts
    printf '    {\n      "type": "direct",\n      "tag": %s\n    },\n' "$(json_string "$direct_outbound_tag")"
    printf '    {\n      "type": "block",\n      "tag": %s\n    }' "$(json_string "$block_outbound_tag")"

    for file in "$outbounds_dir"/*.env; do
        [ -f "$file" ] || continue
        TAG="" TYPE="" DISPLAY_NAME="" SERVER="" SERVER_PORT="" USERNAME="" PASSWORD="" METHOD="" PLUGIN="" PLUGIN_OPTS="" OUT_UUID="" FLOW="" NETWORK="tcp" TLS_ENABLED="0" TLS_SERVER_NAME="" TLS_INSECURE="0" REALITY_ENABLED="0" REALITY_PUBLIC_KEY="" REALITY_SHORT_ID="" UTLS_FINGERPRINT=""
        UUID=""
        . "$file"
        tag="$TAG"
        type="$TYPE"
        server="$SERVER"
        server_port="$SERVER_PORT"
        [ -n "$tag" ] && [ -n "$type" ] || continue
        case "$type" in
            socks|shadowsocks|vless) ;;
            *) continue ;;
        esac
        printf ',\n'
        case "$type" in
            socks)
                printf '    {\n'
                printf '      "type": "socks",\n'
                printf '      "tag": %s,\n' "$(json_string "$tag")"
                printf '      "server": %s,\n' "$(json_string "$server")"
                printf '      "server_port": %s,\n' "$server_port"
                printf '      "version": "5"'
                [ -n "$USERNAME" ] && printf ',\n      "username": %s' "$(json_string "$USERNAME")"
                [ -n "$PASSWORD" ] && printf ',\n      "password": %s' "$(json_string "$PASSWORD")"
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
                local outbound_uuid="${OUT_UUID:-${UUID:-}}" network="${NETWORK:-tcp}"
                printf '    {\n'
                printf '      "type": "vless",\n'
                printf '      "tag": %s,\n' "$(json_string "$tag")"
                printf '      "server": %s,\n' "$(json_string "$server")"
                printf '      "server_port": %s,\n' "$server_port"
                printf '      "uuid": %s' "$(json_string "$outbound_uuid")"
                [ -n "$FLOW" ] && printf ',\n      "flow": %s' "$(json_string "$FLOW")"
                printf ',\n      "network": %s' "$(json_string "$network")"
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
    local file first=1 name outbound_tag
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        name="$NAME"
        outbound_tag="$OUTBOUND_TAG"
        [ -n "$name" ] || continue
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        printf '      {\n'
        printf '        "inbound": [%s],\n' "$(json_string "$reality_inbound_tag")"
        printf '        "auth_user": [%s],\n' "$(json_string "$name")"
        printf '        "action": "route",\n'
        printf '        "outbound": %s\n' "$(json_string "$outbound_tag")"
        printf '      }'
    done

    [ "$first" -eq 1 ] || printf ',\n'
    printf '      {\n'
    printf '        "inbound": [%s],\n' "$(json_string "$reality_inbound_tag")"
    printf '        "action": "route",\n'
    printf '        "outbound": %s\n' "$(json_string "$block_outbound_tag")"
    printf '      }'
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
    {
      "type": "vless",
      "tag": "${reality_inbound_tag}",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
$(render_inbound_users_json)
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
    restart_singbox || return 1
}

apply_config_or_remove() {
    local file="$1"
    if ! apply_config; then
        rm -f "$file"
        write_config >/dev/null 2>&1 || true
        return 1
    fi
}

apply_config_or_restore() {
    local target="$1" backup="$2"
    if ! apply_config; then
        if [ -f "$backup" ]; then
            mv "$backup" "$target"
        else
            rm -f "$target"
        fi
        write_config >/dev/null 2>&1 || true
        return 1
    fi
    rm -f "$backup"
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

user_link() {
    local uuid="$1" name="$2" server_ip="$3" link
    load_state
    [ -n "$server_ip" ] || server_ip=$(get_server_ip)
    link="vless://${uuid}@${server_ip}:${PORT}?encryption=none&flow=${default_flow}&security=reality&sni=${REALITY_DOMAIN}&fp=${default_fingerprint}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${name}"
    printf '%s' "$link"
}

list_outbounds() {
    local file
    green "\n=== 落地 outbound ==="
    purple "direct | 本机直连 | 内置"
    for file in "$outbounds_dir"/*.env; do
        [ -f "$file" ] || continue
        TAG="" TYPE="" DISPLAY_NAME="" SERVER="" SERVER_PORT=""
        . "$file"
        purple "${TAG} | ${TYPE} | ${DISPLAY_NAME:-$SERVER:$SERVER_PORT}"
    done
}

list_users() {
    local file
    green "\n=== 入站用户 ==="
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        purple "${NAME} | ${UUID} | outbound=${OUTBOUND_TAG}"
    done
}

show_reality_info() {
    require_reality_state || return 1

    load_state
    local file link server_ip
    server_ip=$(get_server_ip)

    green "\nReality 参数："
    purple "地址: ${server_ip}"
    purple "端口: ${PORT}"
    purple "Security: reality"
    purple "SNI/伪装域名: ${REALITY_DOMAIN}"
    purple "PublicKey: ${PUBLIC_KEY}"
    purple "ShortID: ${SHORT_ID}"
    purple "Fingerprint: ${default_fingerprint}"

    list_users
    yellow "\n用户链接："
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        link=$(user_link "$UUID" "$NAME" "$server_ip")
        purple "${NAME} -> ${OUTBOUND_TAG}"
        purple "$link\n"
    done
}

show_singbox_logs() {
    local log_file="${work_dir}/sing-box.log"

    clear
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
exec bash <(curl -Ls https://raw.githubusercontent.com/pyooyq/Alpine-sing-box/main/sing-box.sh) "$@"
EOF

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
        migrate_legacy_state
        write_config || return 1
        show_reality_info
        create_shortcut
        return 0
    fi

    clear
    purple "正在安装 sing-box Reality 中转/本机节点..."
    ensure_dependencies
    install_singbox_binary
    ensure_state_layout

    PORT="$vless_port"
    REALITY_DOMAIN="$reality_domain"
    generate_reality_values
    save_state
    save_user "$default_user_name" "$(generate_uuid)" "$direct_outbound_tag"
    write_config || exit 1
    allow_port "$PORT"
    install_service
    create_shortcut
    show_reality_info
}

change_port() {
    load_state
    [ -n "${PORT:-}" ] || { yellow "尚未安装。"; return 1; }

    local new_port old_port
    old_port="$PORT"
    reading "请输入新的 Reality 端口（回车随机）: " new_port
    [ -n "$new_port" ] || new_port=$(random_port)
    validate_port "$new_port" || { red "端口范围需在 1-65535"; return 1; }

    if [ "$new_port" = "$old_port" ]; then
        yellow "端口未变化。"
        return 0
    fi

    PORT="$new_port"
    save_state
    if ! apply_config; then
        PORT="$old_port"
        save_state
        write_config >/dev/null 2>&1 || true
        restart_singbox >/dev/null 2>&1 || true
        return 1
    fi
    allow_port "$PORT"
    show_reality_info
}

change_reality_domain() {
    load_state
    [ -n "${REALITY_DOMAIN:-}" ] || { yellow "尚未安装。"; return 1; }

    local new_domain old_domain
    old_domain="$REALITY_DOMAIN"
    reading "请输入新的 Reality 伪装域名/SNI: " new_domain
    validate_domain "$new_domain" || { red "域名不能为空，且不能包含空格或引号。"; return 1; }

    REALITY_DOMAIN="$new_domain"
    if [ "$REALITY_DOMAIN" = "$old_domain" ]; then
        yellow "Reality 伪装域名未变化。"
        return 0
    fi

    save_state
    if ! apply_config; then
        REALITY_DOMAIN="$old_domain"
        save_state
        write_config >/dev/null 2>&1 || true
        restart_singbox >/dev/null 2>&1 || true
        return 1
    fi
    show_reality_info
}

select_outbound_tag() {
    require_reality_state || return 1

    local options=("$direct_outbound_tag") labels=("${direct_outbound_tag} | 本机直连") file index choice
    for file in "$outbounds_dir"/*.env; do
        [ -f "$file" ] || continue
        TAG="" TYPE="" DISPLAY_NAME=""
        . "$file"
        [ -n "$TAG" ] || continue
        options+=("$TAG")
        labels+=("${TAG} | ${TYPE} | ${DISPLAY_NAME:-$TAG}")
    done

    green "\n请选择 outbound："
    for index in "${!labels[@]}"; do
        purple "$((index + 1)). ${labels[$index]}"
    done
    reading "请输入编号: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ] || return 1
    SELECTED_OUTBOUND_TAG="${options[$((choice - 1))]}"
}

add_user_with_outbound() {
    local name uuid outbound_tag
    require_reality_state || return 1
    reading "请输入用户名称（英文/数字，留空自动生成）: " name
    [ -n "$name" ] || name="user-$(date +%s)"
    name=$(sanitize_tag "$name")
    user_exists "$name" && { red "用户已存在: $name"; return 1; }

    if ! select_outbound_tag; then
        red "未选择有效 outbound。"
        return 1
    fi

    outbound_tag="$SELECTED_OUTBOUND_TAG"
    uuid=$(generate_uuid)
    save_user "$name" "$uuid" "$outbound_tag"
    apply_config_or_remove "$(user_file "$name")" || return 1
    green "用户已添加：${name} -> ${outbound_tag}"
    purple "$(user_link "$uuid" "$name")\n"
}

change_user_outbound() {
    local name file
    require_reality_state || return 1
    list_users
    reading "请输入要修改的用户名称: " name
    name=$(sanitize_tag "$name")
    file=$(user_file "$name")
    [ -f "$file" ] || { red "用户不存在: $name"; return 1; }

    if ! select_outbound_tag; then
        red "未选择有效 outbound。"
        return 1
    fi

    load_user_file "$file"
    if [ "$OUTBOUND_TAG" = "$SELECTED_OUTBOUND_TAG" ]; then
        yellow "用户 ${NAME} 的 outbound 未变化。"
        return 0
    fi
    cp "$file" "${file}.bak"
    save_user "$NAME" "$UUID" "$SELECTED_OUTBOUND_TAG" "$FLOW"
    apply_config_or_restore "$file" "${file}.bak" || return 1
    green "用户 ${NAME} 已绑定到 ${SELECTED_OUTBOUND_TAG}"
}

show_one_user_link() {
    local name file
    require_reality_state || return 1
    list_users
    reading "请输入用户名称: " name
    name=$(sanitize_tag "$name")
    file=$(user_file "$name")
    [ -f "$file" ] || { red "用户不存在: $name"; return 1; }
    load_user_file "$file"
    purple "$(user_link "$UUID" "$NAME")\n"
}

delete_user() {
    local name file count=0 item
    require_reality_state || return 1
    list_users
    reading "请输入要删除的用户名称: " name
    name=$(sanitize_tag "$name")
    file=$(user_file "$name")
    [ -f "$file" ] || { red "用户不存在: $name"; return 1; }

    for item in "$users_dir"/*.env; do
        [ -f "$item" ] && count=$((count + 1))
    done
    [ "$count" -gt 1 ] || { red "至少保留一个入站用户。"; return 1; }

    mv "$file" "${file}.bak"
    apply_config_or_restore "$file" "${file}.bak" || return 1
    green "用户已删除：$name"
}

manage_users_menu() {
    local choice
    require_reality_state || return 1
    clear
    green "=== 入站用户管理 ===\n"
    green "1. 列出用户"
    green "2. 添加用户并绑定 outbound"
    green "3. 查看用户链接"
    green "4. 修改用户绑定 outbound"
    red "5. 删除用户"
    purple "0. 返回主菜单"
    reading "请输入选择: " choice

    case "$choice" in
        1) list_users ;;
        2) add_user_with_outbound ;;
        3) show_one_user_link ;;
        4) change_user_outbound ;;
        5) delete_user ;;
        0) return ;;
        *) red "无效的选项" ;;
    esac
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
    apply_config_or_remove "$(outbound_file "$tag")" || return 1
    green "SOCKS5 落地已添加：$tag"
}

decode_import_input() {
    local input="$1" decoded
    input=$(trim "$input")
    if [[ "$input" == ss://* || "$input" == vless://* ]]; then
        printf '%s' "$input"
        return 0
    fi
    decoded=$(b64_decode "$input") || return 1
    decoded=$(trim "$decoded")
    if [[ "$decoded" == ss://* || "$decoded" == vless://* ]]; then
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

import_shadowsocks_outbound() {
    local input uri body fragment query main userinfo hostport decoded method password server server_port plugin plugin_opts tag display_name
    require_reality_state || return 1
    reading "请输入 ss:// 链接或其 base64: " input
    parse_common_uri "$input" || { red "无法解析 SS 导入内容。"; return 1; }
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
        server=${hostport%:*}
        server_port=${hostport##*:}
    else
        decoded=$(b64_decode "$main") || { red "SS 主体 base64 解析失败。"; return 1; }
        method=${decoded%%:*}
        decoded=${decoded#*:}
        password=${decoded%@*}
        hostport=${decoded#*@}
        server=${hostport%:*}
        server_port=${hostport##*:}
    fi

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
    apply_config_or_remove "$(outbound_file "$tag")" || return 1
    green "SS 落地已导入：$tag"
}

import_vless_outbound() {
    local input uri body fragment query main hostport security tag display_name outbound_uuid server server_port flow network tls_enabled tls_server_name tls_insecure reality_enabled reality_public_key reality_short_id utls_fingerprint
    require_reality_state || return 1
    reading "请输入 vless:// 链接或其 base64: " input
    parse_common_uri "$input" || { red "无法解析 VLESS 导入内容。"; return 1; }
    uri="$PARSED_URI"
    body="$PARSED_BODY"
    query="$PARSED_QUERY"
    fragment="$PARSED_FRAGMENT"
    [[ "$uri" == vless://* ]] || { red "导入内容不是 vless://"; return 1; }

    main="$body"
    outbound_uuid=${main%@*}
    hostport=${main#*@}
    server=${hostport%:*}
    server_port=${hostport##*:}
    [ -n "$outbound_uuid" ] && [ -n "$server" ] || { red "VLESS 链接缺少 UUID 或服务器地址。"; return 1; }
    validate_port "$server_port" || { red "VLESS 端口无效。"; return 1; }

    flow=$(get_query_param "$query" "flow" || true)
    network=$(get_query_param "$query" "type" || true)
    [ -n "$network" ] || network="tcp"
    security=$(get_query_param "$query" "security" || true)
    tls_server_name=$(get_query_param "$query" "sni" || true)
    utls_fingerprint=$(get_query_param "$query" "fp" || true)
    tls_insecure=$(get_query_param "$query" "allowInsecure" || true)
    [ "$tls_insecure" = "1" ] || [ "$tls_insecure" = "true" ] && tls_insecure=1 || tls_insecure=0
    reality_public_key=$(get_query_param "$query" "pbk" || true)
    reality_short_id=$(get_query_param "$query" "sid" || true)
    tls_enabled=0
    reality_enabled=0
    if [ "$security" = "tls" ] || [ "$security" = "reality" ]; then
        tls_enabled=1
    fi
    if [ "$security" = "reality" ]; then
        reality_enabled=1
        [ -n "$reality_public_key" ] || { red "Reality VLESS 链接缺少 pbk。"; return 1; }
    fi

    if [ "$network" != "tcp" ]; then
        red "当前首版仅支持导入 VLESS TCP 出站，请改用 TCP 链接或手动配置。"
        return 1
    fi

    reading "请输入落地 tag（留空使用链接名称）: " tag
    [ -n "$tag" ] || tag="${fragment:-vless-$(date +%s)}"
    tag=$(sanitize_tag "$tag")
    validate_new_outbound_tag "$tag" || return 1
    display_name="${fragment:-$tag}"
    save_vless_outbound "$tag" "$display_name" "$server" "$server_port" "$outbound_uuid" "$flow" "$network" "$tls_enabled" "$tls_server_name" "$tls_insecure" "$reality_enabled" "$reality_public_key" "$reality_short_id" "$utls_fingerprint"
    apply_config_or_remove "$(outbound_file "$tag")" || return 1
    green "VLESS 落地已导入：$tag"
}

outbound_in_use() {
    local tag="$1" file
    for file in "$users_dir"/*.env; do
        [ -f "$file" ] || continue
        load_user_file "$file"
        [ "$OUTBOUND_TAG" = "$tag" ] && { printf '%s' "$NAME"; return 0; }
    done
    return 1
}

delete_outbound() {
    local tag user file
    require_reality_state || return 1
    list_outbounds
    reading "请输入要删除的落地 tag: " tag
    tag=$(sanitize_tag "$tag")
    [ "$tag" != "$direct_outbound_tag" ] && [ "$tag" != "$block_outbound_tag" ] || { red "不能删除内置 outbound: $tag"; return 1; }
    file=$(outbound_file "$tag")
    [ -f "$file" ] || { red "outbound 不存在: $tag"; return 1; }
    user=$(outbound_in_use "$tag" || true)
    [ -z "$user" ] || { red "outbound 正被用户 ${user} 使用，不能删除。"; return 1; }
    mv "$file" "${file}.bak"
    apply_config_or_restore "$file" "${file}.bak" || return 1
    green "outbound 已删除：$tag"
}

manage_outbounds_menu() {
    local choice
    require_reality_state || return 1
    clear
    green "=== 落地 outbound 管理 ===\n"
    green "1. 列出落地"
    green "2. 添加 SOCKS5 落地"
    green "3. 导入 SS 落地"
    green "4. 导入 VLESS 落地"
    red "5. 删除落地"
    purple "0. 返回主菜单"
    reading "请输入选择: " choice

    case "$choice" in
        1) list_outbounds ;;
        2) add_socks_outbound ;;
        3) import_shadowsocks_outbound ;;
        4) import_vless_outbound ;;
        5) delete_outbound ;;
        0) return ;;
        *) red "无效的选项" ;;
    esac
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
    local choice
    reading "确定要卸载 sing-box 并删除 ${work_dir} 吗？(y/n): " choice
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
    purple "=== sing-box Reality 中转/本机节点脚本 ===\n"
    purple "sing-box 状态: ${singbox_status}\n"
    green "1. 安装 / 初始化 Reality 节点"
    green "2. 查看 Reality 用户和落地摘要"
    green "3. 管理入站用户"
    green "4. 管理落地 outbound"
    green "5. 修改 Reality 端口"
    green "6. 修改 Reality 伪装域名"
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

while true; do
    menu
    case "$choice" in
        1) run_install_flow ;;
        2) show_reality_info ;;
        3) manage_users_menu ;;
        4) manage_outbounds_menu ;;
        5) change_port ;;
        6) change_reality_domain ;;
        7) manage_singbox ;;
        8) show_singbox_logs ;;
        9) uninstall_singbox ;;
        0) exit 0 ;;
        *) red "无效的选项，请输入 0 到 9" ;;
    esac
    read -r -n 1 -s -p $'\033[1;91m按任意键返回...\033[0m'
    echo ""
done
