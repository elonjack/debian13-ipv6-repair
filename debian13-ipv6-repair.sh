#!/usr/bin/env bash

# Debian 13 IPv6 configuration auditor/repair helper.
# Scope: ifupdown + dhcpcd, with either "inet6 auto" or "inet6 static".

set -uo pipefail

SCRIPT_VERSION="1.0.0"
STATE_DIR="/var/lib/debian13-ipv6-repair"
PENDING_FILE="${STATE_DIR}/pending"
BACKUP_ROOT="/var/backups/debian13-ipv6-repair"
DHCPCD_CONF="/etc/dhcpcd.conf"
MANAGED_BEGIN="# BEGIN debian13-ipv6-repair"
MANAGED_END="# END debian13-ipv6-repair"

if [[ -t 1 ]]; then
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

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "请使用 root 运行：sudo bash $0"
        exit 1
    fi
}

require_commands() {
    local missing=()
    local cmd
    for cmd in ip awk sed grep cut wc curl pgrep find date cp mkdir sysctl; do
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

read_static_option() {
    local iface=$1
    local option=$2
    local file value
    collect_interface_files
    for file in "${INTERFACE_FILES[@]}"; do
        value=$(awk -v dev="$iface" -v wanted="$option" '
            $1 == "iface" {
                active = ($2 == dev && $3 == "inet6" && $4 == "static")
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

    [[ $address == *:* ]] || return 1
    [[ $address =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
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
        if [[ $output == *:* ]]; then
            printf '%s' "$output"
            return 0
        fi
    done
    return 1
}

has_managed_dhcpcd_block() {
    [[ -f $DHCPCD_CONF ]] && grep -Fq "$MANAGED_BEGIN interface=$1" "$DHCPCD_CONF"
}

has_effective_noipv6rs() {
    local iface=$1
    [[ -f $DHCPCD_CONF ]] || return 1
    awk -v dev="$iface" '
        /^[[:space:]]*#/ || NF == 0 {next}
        $1 == "interface" {scope = $2; next}
        $1 == "noipv6rs" && (scope == "" || scope == dev) {found = 1}
        END {exit(found ? 0 : 1)}
    ' "$DHCPCD_CONF"
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

    printf '\n========== IPv6 诊断报告 ==========\n'
    printf '系统：Debian 13\n'
    printf '网卡：%s\n' "$iface"
    printf 'ifupdown IPv6 模式：%s\n' "$mode"
    [[ -n $expected ]] && printf '配置/用户提供的预期 IPv6：%s\n' "$expected"
    printf 'dhcpcd：%s\n' "$([[ $DHCPCD_RUNNING -eq 1 ]] && printf '运行中' || printf '未运行')"
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

    if [[ $DHCPCD_RUNNING -eq 1 ]] && ! has_effective_noipv6rs "$iface"; then
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
    backup_dir="${BACKUP_ROOT}/${stamp}-${iface}"
    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir"

    [[ -f $DHCPCD_CONF ]] && cp -a "$DHCPCD_CONF" "$backup_dir/dhcpcd.conf"
    [[ -f /etc/network/interfaces ]] && cp -a /etc/network/interfaces "$backup_dir/interfaces"
    for file in "${INTERFACE_FILES[@]}"; do
        [[ $file == /etc/network/interfaces ]] && continue
        cp -a "$file" "$backup_dir/$(basename "$file")"
    done

    local sysctl_file="/etc/sysctl.d/99-debian13-ipv6-${iface}.conf"
    [[ -f $sysctl_file ]] && cp -a "$sysctl_file" "$backup_dir/"

    printf '%s' "$backup_dir"
}

ensure_dhcpcd_noipv6rs() {
    local iface=$1
    touch "$DHCPCD_CONF"
    if has_effective_noipv6rs "$iface"; then
        return 0
    fi

    cat >>"$DHCPCD_CONF" <<EOF

${MANAGED_BEGIN} interface=${iface}
interface ${iface}
noipv6rs
${MANAGED_END}
EOF
}

write_mode_sysctl() {
    local iface=$1
    local mode=$2
    local sysctl_file="/etc/sysctl.d/99-debian13-ipv6-${iface}.conf"

    case "$mode" in
        static)
            cat >"$sysctl_file" <<EOF
# Managed by debian13-ipv6-repair ${SCRIPT_VERSION}
# Static IPv6 is configured by ifupdown; reject kernel RA/SLAAC on ${iface}.
net.ipv6.conf.${iface}.accept_ra=0
net.ipv6.conf.${iface}.autoconf=0
net.ipv6.conf.${iface}.use_tempaddr=0
EOF
            ;;
        auto)
            cat >"$sysctl_file" <<EOF
# Managed by debian13-ipv6-repair ${SCRIPT_VERSION}
# ifupdown inet6 auto owns IPv6; use kernel RA with MAC-based EUI-64.
net.ipv6.conf.${iface}.accept_ra=2
net.ipv6.conf.${iface}.autoconf=1
net.ipv6.conf.${iface}.use_tempaddr=0
net.ipv6.conf.${iface}.addr_gen_mode=0
EOF
            ;;
    esac

    sysctl -p "$sysctl_file" >/dev/null
}

mark_pending() {
    local iface=$1
    local mode=$2
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    {
        printf 'interface=%q\n' "$iface"
        printf 'mode=%q\n' "$mode"
        printf 'created_at=%q\n' "$(date -Is)"
    } >"$PENDING_FILE"
    chmod 600 "$PENDING_FILE"
}

repair_configuration() {
    local iface=$1
    local mode=$2
    local backup_dir

    backup_dir=$(backup_configs "$iface")
    ensure_dhcpcd_noipv6rs "$iface"
    write_mode_sysctl "$iface" "$mode"
    mark_pending "$iface" "$mode"

    ok "修复配置已写入。"
    info "备份目录：$backup_dir"
    warn "尚未验证修复成功；dhcpcd 必须在重启后读取 noipv6rs。"
    warn "脚本不会执行 ifdown、重启 networking 或终止 dhcpcd，以免当前 SSH 断线。"
}

run_audit_and_repair() {
    local iface mode expected_input expected static_addr eval_rc stanza_count

    require_commands || return 1
    check_platform || return 1

    iface=$(detect_interface)
    if [[ -z $iface ]]; then
        err "未找到默认出口网卡。"
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

    expected_input=''
    read -r -p "服务商控制台登记的本机 IPv6（可带前缀；留空仅检查）： " expected_input
    if [[ -n $expected_input ]] && ! validate_expected_ipv6 "$expected_input"; then
        err "输入不是可识别的 IPv6 地址。"
        return 1
    fi
    expected=$(trim_ipv6_prefix "$expected_input")
    if [[ $mode == "static" ]]; then
        static_addr=$(read_static_option "$iface" address || true)
        static_addr=$(trim_ipv6_prefix "$static_addr")
        if [[ -n $expected && -n $static_addr && $expected != "$static_addr" ]]; then
            err "输入地址与静态配置不一致。"
            err "输入：$expected"
            err "配置：$static_addr"
            err "为避免写错服务商地址，脚本不会修改。"
            return 1
        fi
        [[ -z $expected ]] && expected=$static_addr
    fi

    collect_runtime_state "$iface"
    show_audit "$iface" "$mode" "$expected"

    eval_rc=0
    evaluate_state "$iface" "$mode" "$expected" || eval_rc=$?

    printf '\n========== 判断结果 ==========\n'
    if [[ $eval_rc -eq 0 ]]; then
        ok "IPv6 出站、地址数量、路由和配置均正常。"
        ok "无需执行任何修改。"
        if [[ -f $PENDING_FILE ]]; then
            rm -f "$PENDING_FILE"
            ok "已完成重启后验证，清除待验证标记。"
        fi
        return 0
    fi

    local issue
    for issue in "${ISSUES[@]}"; do
        warn "$issue"
    done

    if [[ $eval_rc -eq 2 || $NEEDS_REPAIR -ne 1 ]]; then
        err "当前状态超出脚本的安全自动修复范围，未做任何修改。"
        return 1
    fi

    if [[ -z $expected ]]; then
        err "检测到问题，但未提供服务商控制台 IPv6。"
        err "为避免把错误地址当成正式地址，本次仅检查，不执行修复。"
        return 1
    fi

    if ! ip -6 addr show dev "$iface" to "$expected" scope global 2>/dev/null | grep -q 'inet6'; then
        err "服务商控制台 IPv6 当前不在网卡上，脚本不会自行添加或写死该地址。"
        err "请先核对 DD 网络配置或联系服务商。"
        return 1
    fi

    if [[ $mode == "auto" ]]; then
        if ! ip -6 -o addr show dev "$iface" to "$expected" scope global 2>/dev/null | grep -q 'proto kernel_ra'; then
            err "auto 模式下，服务商 IPv6 不是内核 RA 地址；无法安全确认地址来源。"
            err "脚本不会修改。"
            return 1
        fi
    fi

    if [[ $DHCPCD_RUNNING -ne 1 ]]; then
        err "未检测到 dhcpcd；当前问题不属于本工具验证过的冲突场景。"
        err "脚本不会修改。"
        return 1
    fi

    if other_network_manager_active; then
        err "检测到 NetworkManager 或 systemd-networkd 正在运行。"
        err "为避免多个网络管理器冲突，脚本不会修改。"
        return 1
    fi

    printf '\n'
    read -r -p "确认按 ${mode} 模式写入最小修复配置？[y/N] " answer
    if [[ ! $answer =~ ^[Yy]$ ]]; then
        info "用户取消，未做任何修改。"
        return 0
    fi

    repair_configuration "$iface" "$mode"

    printf '\n'
    read -r -p "是否现在重启 VPS？重启后需再次运行选项 1 验证。[y/N] " answer
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
        printf '========================================\n'
        printf ' Debian 13 IPv6 检查与修复工具 v%s\n' "$SCRIPT_VERSION"
        printf '========================================\n'
        printf ' 1) 检查并按需修复 IPv6\n'
        printf ' 0) 退出\n'
        printf '========================================\n'
        read -r -p "请选择 [0-1]： " choice
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
    return 0 2>/dev/null || exit 0
fi

require_root
show_menu
