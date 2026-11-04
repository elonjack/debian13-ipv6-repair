#!/usr/bin/env bash

# Debian 13 IPv6 configuration auditor/repair helper.
# Scope: ifupdown + dhcpcd, with either "inet6 auto" or "inet6 static".

set -uo pipefail

SCRIPT_VERSION="1.2.0"
STATE_DIR="/var/lib/debian13-ipv6-repair"
PENDING_FILE="${STATE_DIR}/pending"
BACKUP_ROOT="/var/backups/debian13-ipv6-repair"
DHCPCD_CONF="/etc/dhcpcd.conf"
MANAGED_BEGIN="# BEGIN debian13-ipv6-repair"
MANAGED_END="# END debian13-ipv6-repair"

if [[ -t 1 && ${TERM:-dumb} != "dumb" && -z ${NO_COLOR:-} ]]; then
    C_RESET='\033[0m'
    C_RED='\033[31m'
    C_GREEN='\033[32m'
    C_YELLOW='\033[33m'
    C_CYAN='\033[36m'
else
    C_RESET=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_CYAN=''
fi

info() { printf "%b[信息]%b %s\n" "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf "%b[正常]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%b[警告]%b %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err() { printf "%b[错误]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

pause_screen() {
    printf '\n'
    read -r -p "按回车键返回菜单..." _
}

require_interactive_terminal() {
    if [[ ! -t 0 ]]; then
        err "本工具需要交互式终端，不能通过管道或无 TTY 环境运行。"
        err "请先下载脚本，再执行：sudo ./debian13-ipv6-repair.sh"
        exit 1
    fi
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "请使用 root 运行：sudo bash $0"
        exit 1
    fi
}

require_commands() {
    local missing=()
    local cmd
    for cmd in ip awk sed grep curl pgrep find date cp mkdir mktemp chmod touch basename mv rm reboot sysctl clear; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ((${#missing[@]} > 0)); then
        err "缺少必要命令：${missing[*]}"
        err "脚本不会自动安装软件，请先补齐依赖。"
        return 1
    fi
}

check_platform() {
    if [[ ! -r /etc/os-release ]]; then
        err "无法识别操作系统。"
        return 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ ${ID:-} != "debian" || ${VERSION_ID:-} != "13" ]]; then
        err "仅支持 Debian 13；当前系统：${PRETTY_NAME:-未知}"
        return 1
    fi

    if [[ ! -f /etc/network/interfaces ]]; then
        err "未发现 /etc/network/interfaces，当前系统可能不是 ifupdown。"
        return 1
    fi
}

detect_interface() {
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk 'NR == 1 {print $5}')
    if [[ -z $iface ]]; then
        iface=$(ip -6 route show default 2>/dev/null | awk 'NR == 1 {print $5}')
    fi
    printf '%s' "$iface"
}

validate_interface_name() {
    # Keep interface-derived sysctl keys and file names within a conservative,
    # ordinary Linux interface-name subset.
    [[ $1 =~ ^[[:alnum:]_.-]{1,15}$ ]]
}

collect_interface_files() {
    INTERFACE_FILES=()
    [[ -f /etc/network/interfaces ]] && INTERFACE_FILES+=(/etc/network/interfaces)
    if [[ -d /etc/network/interfaces.d ]]; then
        while IFS= read -r -d '' file; do
            INTERFACE_FILES+=("$file")
        done < <(find /etc/network/interfaces.d -maxdepth 1 -type f -print0 2>/dev/null)
    fi
}

detect_ipv6_method() {
    local iface=$1
    local file method
    collect_interface_files
    for file in "${INTERFACE_FILES[@]}"; do
        method=$(awk -v dev="$iface" '
            $1 == "iface" && $2 == dev && $3 == "inet6" {print $4; exit}
        ' "$file")
        if [[ -n $method ]]; then
            printf '%s' "$method"
            return 0
        fi
    done
    return 1
}

count_ipv6_stanzas() {
    local iface=$1
    local file count=0 current
    collect_interface_files
    for file in "${INTERFACE_FILES[@]}"; do
        current=$(awk -v dev="$iface" '
            $1 == "iface" && $2 == dev && $3 == "inet6" {count++}
            END {print count + 0}
        ' "$file")
        count=$((count + current))
    done
    printf '%s' "$count"
}

read_ipv6_option() {
    local iface=$1
    local method=$2
    local option=$3
    local file value
    collect_interface_files
    for file in "${INTERFACE_FILES[@]}"; do
        value=$(awk -v dev="$iface" -v mode="$method" -v wanted="$option" '
            $1 == "iface" {
                active = ($2 == dev && $3 == "inet6" && $4 == mode)
                next
            }
            active && $1 == wanted {print $2; exit}
        ' "$file")
        if [[ -n $value ]]; then
            printf '%s' "$value"
            return 0
        fi
    done
    return 1
}

count_ipv6_options() {
    local iface=$1
    local method=$2
    local option=$3
    local file current count=0
    collect_interface_files
    for file in "${INTERFACE_FILES[@]}"; do
        current=$(awk -v dev="$iface" -v mode="$method" -v wanted="$option" '
            $1 == "iface" {
                active = ($2 == dev && $3 == "inet6" && $4 == mode)
                next
            }
            active && $1 == wanted {count++}
            END {print count + 0}
        ' "$file")
        count=$((count + current))
    done
    printf '%s' "$count"
}

ifupdown_options_safe_for_repair() {
    local iface=$1
    local mode=$2
    local value option
    IFUPDOWN_CONFLICT=''

    case "$mode" in
        auto)
            value=$(read_ipv6_option "$iface" "$mode" privext || true)
            if [[ -n $value && $value != "0" ]]; then
                IFUPDOWN_CONFLICT="inet6 auto 显式设置 privext=${value}，重启后可能重新生成额外地址"
                return 1
            fi
            value=$(read_ipv6_option "$iface" "$mode" accept_ra || true)
            if [[ $value == "0" ]]; then
                IFUPDOWN_CONFLICT="inet6 auto 显式设置 accept_ra=0，与自动 RA 模式冲突"
                return 1
            fi
            ;;
        static)
            for option in accept_ra autoconf privext; do
                value=$(read_ipv6_option "$iface" "$mode" "$option" || true)
                if [[ -n $value && $value != "0" ]]; then
                    IFUPDOWN_CONFLICT="inet6 static 显式设置 ${option}=${value}，可能在启动时覆盖修复参数"
                    return 1
                fi
            done
            ;;
    esac
}

trim_ipv6_prefix() {
    local value=${1//$'\r'/}
    value=${value//[[:space:]]/}
    printf '%s' "${value%%/*}"
}

validate_expected_ipv6() {
    local raw=${1//$'\r'/}
    local address prefix=''
    raw=${raw//[[:space:]]/}
    [[ -n $raw ]] || return 1

    if [[ $raw == */* ]]; then
        address=${raw%%/*}
        prefix=${raw##*/}
        [[ $prefix =~ ^[0-9]{1,3}$ ]] || return 1
        ((prefix >= 0 && prefix <= 128)) || return 1
    else
        address=$raw
    fi

    [[ $address == *:* && $address != *%* ]] || return 1

    # Let iproute2 perform the actual IPv6 parser validation. `addr show` is
    # read-only and also works when the host currently has no IPv6 default route.
    ip -6 addr show to "${address}/128" >/dev/null 2>&1
}

assigned_ipv6() {
    local iface=$1
    local address=$2
    ip -6 -o addr show dev "$iface" to "${address}/128" scope global 2>/dev/null |
        awk 'NR == 1 {split($4, parts, "/"); print parts[1]}'
}

address_is_kernel_ra() {
    local iface=$1
    local address=$2
    ip -6 -o addr show dev "$iface" to "${address}/128" scope global 2>/dev/null |
        grep -q 'proto kernel_ra'
}

eui64_iid_from_mac() {
    local mac=${1,,}
    local b1 b2 b3 b4 b5 b6 first
    [[ $mac =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]] || return 1
    IFS=: read -r b1 b2 b3 b4 b5 b6 <<<"$mac"
    first=$((16#$b1 ^ 2))
    printf '%x:%x:%x:%x' \
        "$((first * 256 + 16#$b2))" \
        "$((16#$b3 * 256 + 255))" \
        "$((254 * 256 + 16#$b4))" \
        "$((16#$b5 * 256 + 16#$b6))"
}

ipv6_matches_mac_eui64() {
    local address=${1,,}
    local mac=$2
    local iid
    iid=$(eui64_iid_from_mac "$mac") || return 1
    [[ $address == *":${iid}" ]]
}

other_network_manager_active() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet NetworkManager.service 2>/dev/null ||
        systemctl is-active --quiet systemd-networkd.service 2>/dev/null
}

test_ipv6_egress() {
    local source_addr=${1:-}
    local endpoint output
    local endpoints=(
        "https://api6.ipify.org"
        "https://ipv6.icanhazip.com"
    )

    for endpoint in "${endpoints[@]}"; do
        if [[ -n $source_addr ]]; then
            output=$(curl -g -6 --interface "$source_addr" -fsS \
                --connect-timeout 5 --max-time 8 "$endpoint" 2>/dev/null) || output=''
        else
            output=$(curl -g -6 -fsS --connect-timeout 5 --max-time 8 \
                "$endpoint" 2>/dev/null) || output=''
        fi
        output=${output//$'\r'/}
        output=${output//$'\n'/}
        if validate_expected_ipv6 "$output"; then
            printf '%s' "$output"
            return 0
        fi
    done
    return 1
}

has_effective_noipv6rs() {
    local iface=$1
    [[ -f $DHCPCD_CONF ]] || return 1
    awk -v dev="$iface" '
        /^[[:space:]]*#/ || NF == 0 {next}
        $1 == "interface" {scope = $2; next}
        ($1 == "noipv6rs" || $1 == "ipv6rs") && (scope == "" || scope == dev) {
            disabled = ($1 == "noipv6rs")
        }
        END {exit(disabled ? 0 : 1)}
    ' "$DHCPCD_CONF"
}

dhcpcd_manages_interface() {
    local iface=$1
    pgrep -a dhcpcd 2>/dev/null |
        awk -v dev="$iface" '
            {for (field = 2; field <= NF; field++) if ($field == dev) found = 1}
            END {exit(found ? 0 : 1)}
        '
}

verify_provider_address() {
    local iface=$1
    local mode=$2
    local provider_address=$3
    local static_address=${4:-}
    local assigned static_assigned mac

    PROVIDER_ERRORS=()
    PROVIDER_CANONICAL=''
    assigned=$(assigned_ipv6 "$iface" "$provider_address")
    if [[ -z $assigned ]]; then
        PROVIDER_ERRORS+=("控制台 IPv6 当前未精确配置在网卡上")
        return 1
    fi
    PROVIDER_CANONICAL=$assigned

    case "$mode" in
        static)
            static_assigned=$(assigned_ipv6 "$iface" "$static_address")
            if [[ -z $static_assigned || $static_assigned != "$assigned" ]]; then
                PROVIDER_ERRORS+=("控制台 IPv6 与 inet6 static 的 address 不一致")
            fi
            ;;
        auto)
            if ! address_is_kernel_ra "$iface" "$assigned"; then
                PROVIDER_ERRORS+=("控制台 IPv6 不是当前网卡的内核 RA 地址")
            fi
            if [[ ! -r /sys/class/net/${iface}/address ]]; then
                PROVIDER_ERRORS+=("无法读取网卡 MAC，不能验证 EUI-64")
            else
                mac=$(<"/sys/class/net/${iface}/address")
                if ! ipv6_matches_mac_eui64 "$assigned" "$mac"; then
                    PROVIDER_ERRORS+=("控制台 IPv6 不是由当前网卡 MAC 生成的 EUI-64 地址")
                fi
            fi
            ;;
    esac

    ((${#PROVIDER_ERRORS[@]} == 0))
}

collect_runtime_state() {
    local iface=$1

    mapfile -t GLOBAL_LINES < <(ip -6 -o addr show dev "$iface" scope global 2>/dev/null)
    mapfile -t GLOBAL_ADDRS < <(
        ip -6 -o addr show dev "$iface" scope global 2>/dev/null |
            awk '{split($4, parts, "/"); print parts[1]}'
    )
    mapfile -t DEFAULT_ROUTES < <(ip -6 route show default dev "$iface" 2>/dev/null)

    ROUTE_GET=$(ip -6 route get 2606:4700:4700::1111 2>&1 || true)
    ROUTE_SRC=$(printf '%s\n' "$ROUTE_GET" | sed -n 's/.* src \([^ ]*\).*/\1/p')
    DEFAULT_PUBLIC=$(test_ipv6_egress '' || true)

    WORKING_ADDRS=()
    FAILED_ADDRS=()
    local addr result
    for addr in "${GLOBAL_ADDRS[@]}"; do
        result=$(test_ipv6_egress "$addr" || true)
        if [[ -n $result ]]; then
            WORKING_ADDRS+=("$addr")
        else
            FAILED_ADDRS+=("$addr")
        fi
    done

    ACCEPT_RA=$(sysctl -n "net.ipv6.conf.${iface}.accept_ra" 2>/dev/null || printf '?')
    AUTOCONF=$(sysctl -n "net.ipv6.conf.${iface}.autoconf" 2>/dev/null || printf '?')
    USE_TEMPADDR=$(sysctl -n "net.ipv6.conf.${iface}.use_tempaddr" 2>/dev/null || printf '?')
    ADDR_GEN_MODE=$(sysctl -n "net.ipv6.conf.${iface}.addr_gen_mode" 2>/dev/null || printf '?')

    if pgrep -x dhcpcd >/dev/null 2>&1; then
        DHCPCD_RUNNING=1
    else
        DHCPCD_RUNNING=0
    fi
    if dhcpcd_manages_interface "$iface"; then
        DHCPCD_ON_IFACE=1
    else
        DHCPCD_ON_IFACE=0
    fi
}

print_array_or_none() {
    local item
    if (($# == 0)); then
        printf '  无\n'
        return
    fi
    for item in "$@"; do
        printf '  %s\n' "$item"
    done
}

show_audit() {
    local iface=$1
    local mode=$2
    local expected=$3
    local expected_label=$4

    printf '\n========== IPv6 诊断报告 ==========\n'
    printf '系统：Debian 13\n'
    printf '网卡：%s\n' "$iface"
    printf 'ifupdown IPv6 模式：%s\n' "$mode"
    [[ -n $expected ]] && printf '%s：%s\n' "$expected_label" "$expected"
    printf 'dhcpcd：%s\n' "$([[ $DHCPCD_RUNNING -eq 1 ]] && printf '运行中' || printf '未运行')"
    printf 'dhcpcd 管理当前网卡：%s\n' "$([[ $DHCPCD_ON_IFACE -eq 1 ]] && printf '是' || printf '否')"
    printf 'dhcpcd noipv6rs：%s\n' "$(has_effective_noipv6rs "$iface" && printf '已配置' || printf '未配置')"

    printf '\n[全局 IPv6，共 %s 个]\n' "${#GLOBAL_ADDRS[@]}"
    print_array_or_none "${GLOBAL_LINES[@]}"

    printf '\n[默认 IPv6 路由，共 %s 条]\n' "${#DEFAULT_ROUTES[@]}"
    print_array_or_none "${DEFAULT_ROUTES[@]}"

    printf '\n[路由选择]\n  %s\n' "$ROUTE_GET"
    printf '  默认源地址：%s\n' "${ROUTE_SRC:-无}"

    printf '\n[逐地址出站测试]\n'
    if ((${#GLOBAL_ADDRS[@]} == 0)); then
        printf '  无可测试地址\n'
    else
        local addr
        for addr in "${GLOBAL_ADDRS[@]}"; do
            if printf '%s\n' "${WORKING_ADDRS[@]}" | grep -Fxq "$addr"; then
                printf '  %s -> 成功\n' "$addr"
            else
                printf '  %s -> 失败\n' "$addr"
            fi
        done
    fi
    printf '  默认 IPv6 出站：%s\n' "${DEFAULT_PUBLIC:-失败}"

    printf '\n[内核参数]\n'
    printf '  accept_ra=%s autoconf=%s use_tempaddr=%s addr_gen_mode=%s\n' \
        "$ACCEPT_RA" "$AUTOCONF" "$USE_TEMPADDR" "$ADDR_GEN_MODE"
}

evaluate_state() {
    local iface=$1
    local mode=$2
    local expected=$3

    ISSUES=()
    NEEDS_REPAIR=0

    if ((${#GLOBAL_ADDRS[@]} == 0)); then
        ISSUES+=("没有全局 IPv6 地址")
    fi
    if ((${#DEFAULT_ROUTES[@]} == 0)); then
        ISSUES+=("没有 IPv6 默认路由")
    fi
    if [[ -z $DEFAULT_PUBLIC ]]; then
        ISSUES+=("默认 IPv6 出站失败")
    fi
    if [[ -n $expected && -n $ROUTE_SRC && ${ROUTE_SRC,,} != "${expected,,}" ]]; then
        ISSUES+=("默认路由源地址不是预期 IPv6")
    fi
    if [[ -n $expected && -n $DEFAULT_PUBLIC && ${DEFAULT_PUBLIC,,} != "${expected,,}" ]]; then
        ISSUES+=("公网回显 IPv6 不是预期 IPv6")
    fi
    if ((${#GLOBAL_ADDRS[@]} > 1)); then
        ISSUES+=("存在多个全局 IPv6 地址")
        NEEDS_REPAIR=1
    fi
    if ((${#DEFAULT_ROUTES[@]} > 1)); then
        ISSUES+=("存在多条 IPv6 默认路由")
        NEEDS_REPAIR=1
    fi
    if ((${#FAILED_ADDRS[@]} > 0)); then
        ISSUES+=("至少一个已配置 IPv6 无法出站")
        NEEDS_REPAIR=1
    fi

    if [[ $DHCPCD_ON_IFACE -eq 1 ]] && ! has_effective_noipv6rs "$iface"; then
        ISSUES+=("dhcpcd 正在处理 IPv6 RA/SLAAC")
        NEEDS_REPAIR=1
    fi

    case "$mode" in
        static)
            if [[ -z $expected ]]; then
                ISSUES+=("静态模式未解析到 address")
                NEEDS_REPAIR=0
                return 2
            fi
            if ! ip -6 addr show dev "$iface" to "$expected" scope global 2>/dev/null | grep -q 'inet6'; then
                ISSUES+=("服务商静态 IPv6 未配置到网卡")
            fi
            if [[ $ACCEPT_RA != "0" || $AUTOCONF != "0" ]]; then
                ISSUES+=("静态模式仍允许内核 RA/SLAAC")
                NEEDS_REPAIR=1
            fi
            ;;
        auto)
            if ! printf '%s\n' "${GLOBAL_LINES[@]}" | grep -q 'proto kernel_ra'; then
                ISSUES+=("自动模式未发现内核 RA 地址")
            fi
            if [[ $ACCEPT_RA == "0" || $AUTOCONF != "1" ]]; then
                ISSUES+=("自动模式的内核 RA/SLAAC 未正确启用")
                NEEDS_REPAIR=1
            fi
            ;;
        *)
            ISSUES+=("不支持的 inet6 模式：$mode")
            NEEDS_REPAIR=0
            return 2
            ;;
    esac

    if [[ -n $expected ]] && ! ip -6 addr show dev "$iface" to "$expected" scope global 2>/dev/null | grep -q 'inet6'; then
        ISSUES+=("网卡地址与服务商登记地址不一致")
    fi

    if ((${#ISSUES[@]} == 0)); then
        NEEDS_REPAIR=0
        return 0
    fi
    return 1
}

backup_configs() {
    local iface=$1
    local stamp backup_dir file
    stamp=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$BACKUP_ROOT" || return 1
    chmod 700 "$BACKUP_ROOT" || return 1
    backup_dir=$(mktemp -d "${BACKUP_ROOT}/${stamp}-${iface}.XXXXXX") || return 1
    chmod 700 "$backup_dir" || return 1

    if [[ -f $DHCPCD_CONF ]]; then
        cp -a "$DHCPCD_CONF" "$backup_dir/dhcpcd.conf" || return 1
    fi
    if [[ -f /etc/network/interfaces ]]; then
        cp -a /etc/network/interfaces "$backup_dir/interfaces" || return 1
    fi
    mkdir -p "$backup_dir/interfaces.d" || return 1
    for file in "${INTERFACE_FILES[@]}"; do
        [[ $file == /etc/network/interfaces ]] && continue
        cp -a "$file" "$backup_dir/interfaces.d/$(basename "$file")" || return 1
    done

    local sysctl_file="/etc/sysctl.d/99-debian13-ipv6-${iface}.conf"
    if [[ -f $sysctl_file ]]; then
        cp -a "$sysctl_file" "$backup_dir/" || return 1
    fi

    printf '%s' "$backup_dir"
}

ensure_dhcpcd_noipv6rs() {
    local iface=$1
    local temporary_file
    [[ -L $DHCPCD_CONF ]] && return 1
    if has_effective_noipv6rs "$iface"; then
        return 0
    fi

    temporary_file=$(mktemp "${DHCPCD_CONF}.tmp.XXXXXX") || return 1
    if [[ -f $DHCPCD_CONF ]]; then
        cp -a "$DHCPCD_CONF" "$temporary_file" || {
            rm -f -- "$temporary_file"
            return 1
        }
    else
        chmod 644 "$temporary_file" || {
            rm -f -- "$temporary_file"
            return 1
        }
    fi

    if ! cat >>"$temporary_file" <<EOF; then

${MANAGED_BEGIN} interface=${iface}
interface ${iface}
noipv6rs
${MANAGED_END}
EOF
        rm -f -- "$temporary_file"
        return 1
    fi
    mv -f -- "$temporary_file" "$DHCPCD_CONF"
}

write_mode_sysctl() {
    local iface=$1
    local mode=$2
    local sysctl_file="/etc/sysctl.d/99-debian13-ipv6-${iface}.conf"
    local temporary_file

    [[ -L $sysctl_file ]] && return 1
    temporary_file=$(mktemp "${sysctl_file}.tmp.XXXXXX") || return 1

    case "$mode" in
        static)
            if ! cat >"$temporary_file" <<EOF; then
# Managed by debian13-ipv6-repair ${SCRIPT_VERSION}
# Static IPv6 is configured by ifupdown; reject kernel RA/SLAAC on ${iface}.
net.ipv6.conf.${iface}.accept_ra=0
net.ipv6.conf.${iface}.autoconf=0
net.ipv6.conf.${iface}.use_tempaddr=0
EOF
                rm -f -- "$temporary_file"
                return 1
            fi
            ;;
        auto)
            if ! cat >"$temporary_file" <<EOF; then
# Managed by debian13-ipv6-repair ${SCRIPT_VERSION}
# ifupdown inet6 auto owns IPv6; use kernel RA with MAC-based EUI-64.
net.ipv6.conf.${iface}.accept_ra=2
net.ipv6.conf.${iface}.autoconf=1
net.ipv6.conf.${iface}.use_tempaddr=0
net.ipv6.conf.${iface}.addr_gen_mode=0
EOF
                rm -f -- "$temporary_file"
                return 1
            fi
            ;;
        *)
            rm -f -- "$temporary_file"
            return 1
            ;;
    esac

    chmod 644 "$temporary_file" || {
        rm -f -- "$temporary_file"
        return 1
    }
    mv -f -- "$temporary_file" "$sysctl_file"
}

mark_pending() {
    local iface=$1
    local mode=$2
    mkdir -p "$STATE_DIR" || return 1
    chmod 700 "$STATE_DIR" || return 1
    {
        printf 'interface=%q\n' "$iface"
        printf 'mode=%q\n' "$mode"
        printf 'created_at=%q\n' "$(date -Is)"
    } >"$PENDING_FILE" || return 1
    chmod 600 "$PENDING_FILE"
}

rollback_configs() {
    local iface=$1
    local backup_dir=$2
    local sysctl_file="/etc/sysctl.d/99-debian13-ipv6-${iface}.conf"
    local rollback_rc=0

    if [[ -f $backup_dir/dhcpcd.conf ]]; then
        cp -a "$backup_dir/dhcpcd.conf" "$DHCPCD_CONF" || rollback_rc=1
    else
        rm -f -- "$DHCPCD_CONF" || rollback_rc=1
    fi
    if [[ -f $backup_dir/$(basename "$sysctl_file") ]]; then
        cp -a "$backup_dir/$(basename "$sysctl_file")" "$sysctl_file" || rollback_rc=1
    else
        rm -f -- "$sysctl_file" || rollback_rc=1
    fi
    return "$rollback_rc"
}

repair_configuration() {
    local iface=$1
    local mode=$2
    local backup_dir
    local sysctl_file="/etc/sysctl.d/99-debian13-ipv6-${iface}.conf"

    if [[ -L $DHCPCD_CONF || -L $sysctl_file ]]; then
        err "目标配置文件是符号链接；为避免替换链接，脚本拒绝写入。"
        return 1
    fi

    backup_dir=$(backup_configs "$iface") || {
        err "备份失败，未写入修复配置。"
        return 1
    }
    write_mode_sysctl "$iface" "$mode" || {
        err "写入 sysctl 配置失败；请勿重启，并检查备份：$backup_dir"
        return 1
    }
    ensure_dhcpcd_noipv6rs "$iface" || {
        rollback_configs "$iface" "$backup_dir" || err "自动回滚也失败，请手动恢复：$backup_dir"
        err "写入 dhcpcd 配置失败，已尝试回滚；请勿重启。备份：$backup_dir"
        return 1
    }
    mark_pending "$iface" "$mode" || {
        rollback_configs "$iface" "$backup_dir" || err "自动回滚也失败，请手动恢复：$backup_dir"
        rm -f -- "$PENDING_FILE"
        err "无法创建待验证标记，已尝试回滚；请勿重启。备份：$backup_dir"
        return 1
    }

    ok "修复配置已写入。"
    info "备份目录：$backup_dir"
    warn "尚未验证修复成功；dhcpcd 必须在重启后读取 noipv6rs。"
    warn "脚本不会执行 ifdown、重启 networking 或终止 dhcpcd，以免当前 SSH 断线。"
}

run_audit_and_repair() {
    local iface mode provider_input provider_expected expected expected_label
    local static_addr static_canonical static_address_count eval_rc stanza_count provider_supplied=0 provider_verified=0
    local issue provider_error answer

    require_commands || return 1
    check_platform || return 1

    iface=$(detect_interface)
    if [[ -z $iface ]]; then
        err "未找到默认出口网卡。"
        return 1
    fi
    if ! validate_interface_name "$iface"; then
        err "网卡名称不在脚本的安全处理范围内：$iface"
        return 1
    fi

    stanza_count=$(count_ipv6_stanzas "$iface")
    if ((stanza_count != 1)); then
        err "网卡 $iface 检测到 ${stanza_count} 个 inet6 stanza；为避免误改，脚本只允许恰好一个。"
        return 1
    fi

    mode=$(detect_ipv6_method "$iface" || true)
    if [[ $mode != "auto" && $mode != "static" ]]; then
        err "检测到 inet6 方法：${mode:-无配置}"
        err "ifupdown 还支持 manual、dhcp、v4tunnel、6to4、loopback 等方法，"
        err "但本工具只对已经验证的 auto/static 自动修复，当前不会修改。"
        return 1
    fi

    provider_input=''
    if ! read -r -p "服务商控制台登记的本机 IPv6（可带前缀；留空仅检查）： " provider_input; then
        warn "未读取到输入，返回菜单。"
        return 1
    fi
    if [[ -n $provider_input ]] && ! validate_expected_ipv6 "$provider_input"; then
        err "输入不是可识别的 IPv6 地址。"
        return 1
    fi
    provider_expected=$(trim_ipv6_prefix "$provider_input")
    expected=$provider_expected
    expected_label="服务商控制台输入 IPv6"
    if [[ -n $provider_expected ]]; then
        provider_supplied=1
    fi

    static_addr=''
    if [[ $mode == "static" ]]; then
        static_address_count=$(count_ipv6_options "$iface" "$mode" address)
        if ((static_address_count != 1)); then
            err "inet6 static 必须恰好包含一个 address；当前检测到 ${static_address_count} 个。"
            err "脚本不会修改多地址或缺少地址的配置。"
            return 1
        fi
        static_addr=$(read_ipv6_option "$iface" "$mode" address || true)
        static_addr=$(trim_ipv6_prefix "$static_addr")
        if [[ -z $static_addr ]] || ! validate_expected_ipv6 "$static_addr"; then
            err "inet6 static stanza 缺少有效的 address，脚本不会修改。"
            return 1
        fi
        static_canonical=$(assigned_ipv6 "$iface" "$static_addr")
        if [[ $provider_supplied -eq 0 ]]; then
            expected=${static_canonical:-$static_addr}
            expected_label="inet6 static 配置 IPv6（未与控制台核对）"
        fi
    fi

    collect_runtime_state "$iface"

    if [[ $provider_supplied -eq 1 ]]; then
        if verify_provider_address "$iface" "$mode" "$provider_expected" "$static_addr"; then
            provider_verified=1
            provider_expected=$PROVIDER_CANONICAL
            expected=$PROVIDER_CANONICAL
        fi
    fi

    show_audit "$iface" "$mode" "$expected" "$expected_label"

    printf '\n[服务商控制台地址核验]\n'
    if [[ $provider_supplied -eq 0 ]]; then
        printf '  未输入，仅检查网络状态；不能证明当前地址就是控制台分配地址。\n'
    elif [[ $provider_verified -eq 1 ]]; then
        printf '  通过：当前地址与输入精确匹配，地址来源也符合 %s 模式。\n' "$mode"
    else
        for provider_error in "${PROVIDER_ERRORS[@]}"; do
            printf '  失败：%s\n' "$provider_error"
        done
    fi

    eval_rc=0
    evaluate_state "$iface" "$mode" "$expected" || eval_rc=$?

    printf '\n========== 判断结果 ==========\n'
    if [[ $eval_rc -eq 0 ]]; then
        ok "IPv6 出站、地址数量、路由和运行配置均正常。"
        if [[ $provider_supplied -eq 1 && $provider_verified -ne 1 ]]; then
            err "但未通过服务商控制台 IPv6 核验，不能判定为完整正常。"
            err "脚本未做任何修改。"
            return 1
        fi
        if [[ $provider_verified -eq 1 ]]; then
            ok "当前使用的 IPv6 已与服务商控制台输入地址精确核对。"
        else
            warn "未输入控制台 IPv6，本次结果只代表网络可用，不代表地址归属已核对。"
        fi
        ok "无需执行任何修改。"
        if [[ -f $PENDING_FILE && $provider_verified -eq 1 ]]; then
            rm -f "$PENDING_FILE"
            ok "已完成重启后验证，清除待验证标记。"
        elif [[ -f $PENDING_FILE ]]; then
            warn "存在待验证标记；必须输入控制台 IPv6 并核验通过后才会清除。"
        fi
        return 0
    fi

    for issue in "${ISSUES[@]}"; do
        warn "$issue"
    done
    if [[ $provider_supplied -eq 1 && $provider_verified -ne 1 ]]; then
        for provider_error in "${PROVIDER_ERRORS[@]}"; do
            warn "$provider_error"
        done
    fi

    if [[ $eval_rc -eq 2 || $NEEDS_REPAIR -ne 1 ]]; then
        err "当前状态超出脚本的安全自动修复范围，未做任何修改。"
        return 1
    fi

    if [[ $provider_supplied -ne 1 ]]; then
        err "检测到问题，但未提供服务商控制台 IPv6。"
        err "为避免把错误地址当成正式地址，本次仅检查，不执行修复。"
        return 1
    fi

    if [[ $provider_verified -ne 1 ]]; then
        err "服务商控制台 IPv6 未通过地址、配置和来源核验。"
        err "脚本不会添加、推导或写死地址，也不会执行修复。"
        return 1
    fi

    if [[ $DHCPCD_ON_IFACE -ne 1 ]]; then
        err "未检测到 dhcpcd 正在管理网卡 $iface；当前问题不属于已验证场景。"
        err "脚本不会修改。"
        return 1
    fi

    if other_network_manager_active; then
        err "检测到 NetworkManager 或 systemd-networkd 正在运行。"
        err "为避免多个网络管理器冲突，脚本不会修改。"
        return 1
    fi

    if ! ifupdown_options_safe_for_repair "$iface" "$mode"; then
        err "$IFUPDOWN_CONFLICT"
        err "脚本不会覆盖用户显式写入的 ifupdown 选项。"
        return 1
    fi

    printf '\n'
    answer=''
    read -r -p "确认按 ${mode} 模式写入最小修复配置？[y/N] " answer || answer=''
    if [[ ! $answer =~ ^[Yy]$ ]]; then
        info "用户取消，未做任何修改。"
        return 0
    fi

    repair_configuration "$iface" "$mode" || return 1

    printf '\n'
    answer=''
    read -r -p "是否现在重启 VPS？重启后需再次输入同一控制台 IPv6 验证。[y/N] " answer || answer=''
    if [[ $answer =~ ^[Yy]$ ]]; then
        info "正在重启……"
        reboot
    else
        warn "请稍后手动执行 reboot，重启后再次运行本脚本选项 1。"
    fi
}

show_menu() {
    while true; do
        if [[ -t 1 ]]; then
            clear
        fi
        printf '%b' "$C_YELLOW"
        printf '========================================\n'
        printf ' Debian 13 IPv6 检查与修复工具 v%s\n' "$SCRIPT_VERSION"
        printf '========================================\n'
        printf ' 1) 检查并按需修复 IPv6\n'
        printf ' 0) 退出\n'
        printf '========================================\n'
        printf '请选择 [0-1]：%b ' "$C_RESET"
        if ! read -r choice; then
            printf '\n'
            return 0
        fi
        case "$choice" in
            1)
                run_audit_and_repair
                pause_screen
                ;;
            0)
                exit 0
                ;;
            *)
                warn "无效选项。"
                pause_screen
                ;;
        esac
    done
}

if [[ ${D13_IPV6_REPAIR_LIBRARY:-0} == "1" ]]; then
    return 0
fi

require_root
require_interactive_terminal
show_menu
