#!/bin/bash

# ==========================================
# 0. 全局变量与前置环境配置
# ==========================================
RED=''
GREEN=''
YELLOW=''
CYAN=''
BOLD=''
DIM=''
NC=''
LOG_FILE="${VPS_INIT_LOG_FILE:-/var/log/vps_init.log}"
LOG_MAX_BYTES="${VPS_INIT_LOG_MAX_BYTES:-1048576}"
LOG_KEEP_LINES="${VPS_INIT_LOG_KEEP_LINES:-1000}"
LOG_DETAIL_LIMIT=2048
DNS_ROUTE_V4_WAIT_SECONDS="${VPS_INIT_DNS_ROUTE_V4_WAIT_SECONDS:-10}"
DNS_ROUTE_V6_WAIT_SECONDS="${VPS_INIT_DNS_ROUTE_V6_WAIT_SECONDS:-30}"
NETPLAN_DNS_MANAGED_MARKER="# Managed by vps-init: DNS override"
IPV6_SYSCTL_FILE="/etc/sysctl.d/99-zz-vps-init-ipv6.conf"
SWAP_SYSCTL_FILE="/etc/sysctl.d/99-zz-vps-init-swap.conf"
SSH_MANAGED_FILE="/etc/ssh/sshd_config.d/00-00-vps-init.conf"
SSH_SOCKET_SERVICE_DROPIN="/etc/systemd/system/ssh.service.d/00-socket.conf"
SSH_SOCKET_ADDRESS_DROPIN="/etc/systemd/system/ssh.socket.d/addresses.conf"
SSH_SOCKET_GENERATOR_MASK="/etc/systemd/system-generators/sshd-socket-generator"
GAI_MANAGED_BEGIN="# BEGIN vps-init IPv4 preference"
GAI_MANAGED_END="# END vps-init IPv4 preference"
VERSION="1.2.3"
MANAGED_SWAP_FILE="/swapfile"
BACKUP_DIR="/var/backups/vps-init"
declare -a DNS_RESOLVED_LINKS=()
declare -A DNS_LINK_DNS_BEFORE=()
declare -A DNS_LINK_DOMAINS_BEFORE=()
DNS_INTERFACES_CONFIGURED=0
DNS_INTERFACES_FILE=""
DNS_INTERFACES_METHOD=""
LEGACY_SYSCTL_CONF_STANDALONE=0

if [[ -t 1 && "${TERM:-}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
fi

initialize_log_file() {
    local fallback_file=""

    [[ "$LOG_MAX_BYTES" =~ ^[0-9]+$ ]] || LOG_MAX_BYTES=1048576
    [[ "$LOG_KEEP_LINES" =~ ^[0-9]+$ ]] || LOG_KEEP_LINES=1000
    (( LOG_MAX_BYTES > 0 )) || LOG_MAX_BYTES=1048576
    (( LOG_KEEP_LINES > 0 )) || LOG_KEEP_LINES=1000

    if [[ -L "$LOG_FILE" ]] || \
       [[ -e "$LOG_FILE" && ! -f "$LOG_FILE" ]] || \
       ! touch "$LOG_FILE" 2>/dev/null || [[ ! -f "$LOG_FILE" ]]; then
        if command -v mktemp >/dev/null 2>&1; then
            fallback_file=$(mktemp "/tmp/vps_init-${EUID}.XXXXXX.log" 2>/dev/null || true)
        fi
        if [[ -z "$fallback_file" ]]; then
            LOG_FILE="/dev/null"
            return 0
        fi
        LOG_FILE="$fallback_file"
    fi
    chmod 600 "$LOG_FILE" 2>/dev/null || true
}

compact_log_file() {
    local current_size
    local temp_file

    [[ "$LOG_FILE" != "/dev/null" && -f "$LOG_FILE" ]] || return 0
    current_size=$(wc -c < "$LOG_FILE" 2>/dev/null) || return 0
    (( current_size > LOG_MAX_BYTES )) || return 0
    command -v mktemp >/dev/null 2>&1 || return 0

    temp_file=$(mktemp "${LOG_FILE}.vps-init.XXXXXX") || return 0
    if tail -n "$LOG_KEEP_LINES" "$LOG_FILE" 2>/dev/null | \
       tail -c "$LOG_MAX_BYTES" > "$temp_file" 2>/dev/null; then
        chmod 600 "$temp_file" 2>/dev/null || true
        mv -f -- "$temp_file" "$LOG_FILE" 2>/dev/null || rm -f -- "$temp_file"
    else
        rm -f -- "$temp_file"
    fi
}

sanitize_log_message() {
    printf '%s' "$1" |
        sed -E \
            -e 's/\x1B\[[0-9;]*[mK]//g' \
            -e 's#(https?://)[^/@[:space:]]+@#\1***@#g' \
            -e 's/((password|passwd|token|secret)[[:space:]]*[=:][[:space:]]*)[^;[:space:]]+/\1***/Ig' |
        tr '\r\n' '  '
}

append_log_line() {
    local timestamp="$1"
    local level="$2"
    local message="$3"
    local clean_message

    clean_message=$(sanitize_log_message "$message")
    if [[ -n "$level" ]]; then
        printf '[%s] [%s] %s\n' "$timestamp" "$level" "$clean_message" >> "$LOG_FILE"
    else
        printf '[%s] %s\n' "$timestamp" "$clean_message" >> "$LOG_FILE"
    fi
}

log() {
    local timestamp

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[$timestamp]${NC} $1"
    append_log_line "$timestamp" "" "$1"
}

error() {
    local timestamp

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[错误]${NC} $1"
    append_log_line "$timestamp" "ERROR" "$1"
}

warn() {
    local timestamp

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[注意]${NC} $1"
    append_log_line "$timestamp" "WARN" "$1"
}

detail() {
    local module="$1"
    local stage="$2"
    local message="$3"
    local timestamp
    local clean_message

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    clean_message=$(sanitize_log_message "$message")
    clean_message="${clean_message:0:LOG_DETAIL_LIMIT}"
    printf '[%s] [DETAIL] [%s][%s] %s\n' \
        "$timestamp" "$module" "$stage" "$clean_message" >> "$LOG_FILE"
}

initialize_log_file
compact_log_file

pause_menu() {
    read -r -p "按回车键继续..."
}

confirm_action() {
    local prompt="$1"
    local answer

    read -r -p "$prompt [y/N]: " answer
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        return 0
    fi
    print_result "操作" "已取消" "未做任何更改"
    return 1
}

require_commands() {
    local label="$1"
    shift
    local command_name
    local -a missing_commands=()

    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
    done
    if (( ${#missing_commands[@]} > 0 )); then
        error "$label 缺少必要命令：${missing_commands[*]}"
        return 1
    fi
}

prepare_private_directory() {
    local path="$1"

    if [[ -L "$path" ]] || [[ -e "$path" && ! -d "$path" ]]; then
        error "$path 不是可安全使用的目录。"
        return 1
    fi
    mkdir -p -- "$path" || return 1
    chmod 700 -- "$path" || return 1
}

prepare_backup_path() {
    local path="$1"

    [[ "$path" == "$BACKUP_DIR"/* ]] || {
        error "备份路径不在 $BACKUP_DIR 内，已停止操作。"
        return 1
    }
    prepare_private_directory "$BACKUP_DIR" || return 1
    prepare_private_directory "$path"
}

print_header() {
    local title="$1"

    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${BOLD}${CYAN}  $title${NC}"
    echo -e "${CYAN}==================================================${NC}"
}

print_menu_item() {
    local number="$1"
    local label="$2"
    local description="${3:-}"

    if [[ -n "$description" ]]; then
        echo -e "  ${GREEN}${number}.${NC} ${label} ${DIM}${description}${NC}"
    else
        echo -e "  ${GREEN}${number}.${NC} ${label}"
    fi
}

print_result() {
    local label="$1"
    local state="$2"
    local detail="${3:-}"
    local color="$YELLOW"

    case "$state" in
        正常|已启用|运行中|成功|已完成) color="$GREEN" ;;
        异常|失败|已禁用) color="$RED" ;;
    esac
    printf '  %-22s ' "$label"
    echo -e "${color}${state}${NC}${detail:+  $detail}"
}

action_success() {
    local label="$1"
    local detail_text="${2:-}"
    local timestamp

    print_result "$label" "已完成" "$detail_text"
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    append_log_line "$timestamp" "" "$label 已完成${detail_text:+：$detail_text}"
}

action_partial() {
    local label="$1"
    local detail_text="$2"
    local timestamp

    print_result "$label" "部分完成" "$detail_text"
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    append_log_line "$timestamp" "WARN" "$label 部分完成：$detail_text"
}

get_ssh_port() {
    sshd -T 2>/dev/null | awk '/^port /{print $2; exit}'
}

get_configured_ssh_ports() {
    sshd -T 2>/dev/null | awk '
        /^port [0-9]+$/ {
            port=$2
            if (!seen[port]++) ports[++count]=port
        }
        END {
            for (i=1; i<=count; i++) printf "%s%s", ports[i], (i<count ? "," : "")
        }'
}

is_valid_ssh_port() {
    local port="$1"

    [[ "$port" == "22" ]] && return 0
    [[ "$port" =~ ^[1-9][0-9]{3,4}$ ]] || return 1
    (( 10#$port >= 1024 && 10#$port <= 65535 ))
}

fail2ban_port_list_is_safe() {
    local port_list="$1"
    local port
    local -a ports=()

    [[ -n "$port_list" && "$port_list" != ,* && "$port_list" != *, && \
       "$port_list" != *,,* ]] || return 1
    IFS=',' read -r -a ports <<< "$port_list"
    (( ${#ports[@]} > 0 )) || return 1
    for port in "${ports[@]}"; do
        [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
        (( 10#$port <= 65535 )) || return 1
    done
}

ssh_uses_only_port() {
    local expected_port="$1"
    local configured_ports="${2:-$(get_configured_ssh_ports)}"
    local listening_ports="${3:-$(get_listening_ssh_ports)}"

    [[ "$configured_ports" == "$expected_port" && "$listening_ports" == "$expected_port" ]]
}

ssh_port_accepts_loopback() {
    local port="$1"
    local endpoint
    local host
    local -a candidate_hosts=(127.0.0.1 ::1)
    local -a unique_hosts=()

    while IFS= read -r endpoint; do
        [[ -n "$endpoint" ]] || continue
        host="${endpoint%:$port}"
        host="${host#[}"
        host="${host%]}"
        case "$host" in
            0.0.0.0|'*') host=127.0.0.1 ;;
            ::|'[::]') host=::1 ;;
        esac
        [[ -n "$host" ]] && candidate_hosts+=("$host")
    done < <(
        ss -H -ltn 2>/dev/null | awk -v expected="$port" '
            {
                address=$4
                parsed=address
                sub(/^.*:/, "", parsed)
                if (parsed == expected) print address
            }
        '
    )

    for host in "${candidate_hosts[@]}"; do
        if ! array_contains_value unique_hosts "$host"; then
            unique_hosts+=("$host")
        fi
    done

    for host in "${unique_hosts[@]}"; do
        if timeout 5 bash -c '
            host=$1
            port=$2
            exec 3<>"/dev/tcp/${host}/${port}" || exit 1
            IFS= read -r -t 3 banner <&3 || exit 1
            [[ "$banner" == SSH-* ]]
        ' _ "$host" "$port" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

ssh_ports_accept_loopback() {
    local ports_csv="$1"
    local port
    local -a ports=()

    IFS=',' read -r -a ports <<< "$ports_csv"
    (( ${#ports[@]} > 0 )) || return 1
    for port in "${ports[@]}"; do
        [[ "$port" =~ ^[0-9]+$ ]] || return 1
        ssh_port_accepts_loopback "$port" || return 1
    done
}

tcp_port_is_listening() {
    local port="$1"

    ss -H -ltn 2>/dev/null | awk -v expected="$port" '
        {
            address=$4
            sub(/^.*:/, "", address)
            if (address == expected) found=1
        }
        END {exit !found}
    '
}

get_listening_ssh_ports() {
    local configured_ports
    local endpoint
    local port
    local socket_state
    local -a configured_candidates=()
    local -a trusted_candidates=()
    local -a listening_ports=()

    configured_ports=$(get_configured_ssh_ports)
    IFS=',' read -r -a configured_candidates <<< "$configured_ports"

    socket_state=$(systemctl is-active ssh.socket 2>/dev/null || true)
    if [[ "$socket_state" == "active" ]]; then
        while IFS= read -r endpoint; do
            [[ -n "$endpoint" ]] || continue
            port="${endpoint##*:}"
            [[ "$port" == "$endpoint" ]] && port="${endpoint#[}"
            port="${port%]}"
            [[ "$port" =~ ^[0-9]+$ ]] && trusted_candidates+=("$port")
        done < <(
            systemctl show ssh.socket --property=Listen --value 2>/dev/null |
                awk '
                    {
                        for (i=1; i<=NF; i++) {
                            if ($i == "(Stream)" && i > 1) print $(i-1)
                        }
                    }
                '
        )
    fi

    while IFS= read -r port; do
        [[ "$port" =~ ^[0-9]+$ ]] && trusted_candidates+=("$port")
    done < <(
        ss -H -ltnp 2>/dev/null | awk '
            index($0, "\"sshd\"") {
                address=$4
                sub(/^.*:/, "", address)
                if (address ~ /^[0-9]+$/) print address
            }
        '
    )

    for port in "${trusted_candidates[@]}"; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        if tcp_port_is_listening "$port" && ! array_contains_value listening_ports "$port"; then
            listening_ports+=("$port")
        fi
    done
    for port in "${configured_candidates[@]}"; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        if tcp_port_is_listening "$port" && ssh_port_accepts_loopback "$port" && \
           ! array_contains_value listening_ports "$port"; then
            listening_ports+=("$port")
        fi
    done
    if (( ${#listening_ports[@]} > 0 )); then
        printf '%s\n' "${listening_ports[@]}" | LC_ALL=C sort -n -u | paste -sd, -
    fi
}

render_fail2ban_sshd_section() {
    local source_file="$1"
    local output_file="$2"
    local port="$3"
    local mode="$4"

    awk -v port="$port" -v mode="$mode" '
        function is_section(line, normalized) {
            normalized=tolower(line)
            return normalized ~ /^[[:space:]]*\[[^]]+\]/
        }
        function is_sshd_section(line, normalized) {
            normalized=tolower(line)
            return normalized ~ /^[[:space:]]*\[sshd\][[:space:]]*([#;].*)?$/
        }
        function emit_managed_values() {
            if (mode == "full") {
                print "enabled = true"
                print "port = " port
                print "maxretry = 5"
                print "findtime = 3600"
                print "bantime = 86400"
            } else {
                print "port = " port
            }
        }
        {
            if (is_section($0)) {
                if (in_sshd) emit_managed_values()
                in_sshd=is_sshd_section($0)
                if (in_sshd) found_sshd=1
                print
                next
            }
            if (in_sshd) {
                key=$0
                sub(/^[[:space:]]*/, "", key)
                sub(/[[:space:]]*[=:].*$/, "", key)
                key=tolower(key)
                if (mode == "full" &&
                    (key == "enabled" || key == "port" || key == "maxretry" ||
                     key == "findtime" || key == "bantime")) next
                if (mode == "port" && key == "port") next
            }
            print
        }
        END {
            if (in_sshd) emit_managed_values()
            if (!found_sshd) {
                if (NR > 0) print ""
                print "[sshd]"
                emit_managed_values()
            }
        }
    ' "$source_file" > "$output_file"
}

fail2ban_file_has_after_include() {
    local file="$1"

    [[ -f "$file" ]] || return 1
    awk '
        /^[[:space:]]*[#;]/ {next}
        /^[[:space:]]*\[[^]]+\]/ {
            section=$0
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\].*$/, "", section)
            in_includes=(tolower(section) == "includes")
            in_after=0
            next
        }
        !in_includes {next}
        /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            key=line
            sub(/[[:space:]]*=.*$/, "", key)
            key=tolower(key)
            value=line
            sub(/^[^=]*=/, "", value)
            sub(/[[:space:]]*[#;].*$/, "", value)
            gsub(/[[:space:]]/, "", value)
            in_after=(key == "after")
            if (in_after && value != "") found=1
            next
        }
        in_after && /^[[:space:]]+/ {
            value=$0
            sub(/[[:space:]]*[#;].*$/, "", value)
            gsub(/[[:space:]]/, "", value)
            if (value != "") found=1
        }
        END {exit(found ? 0 : 1)}
    ' "$file" 2>/dev/null
}

find_fail2ban_late_sshd_overrides() {
    local mode="$1"
    local file
    local -a local_files=(/etc/fail2ban/jail.d/*.local)

    for file in "${local_files[@]}"; do
        [[ "$file" != "/etc/fail2ban/jail.d/99-vps-init-port.local" ]] || continue
        if [[ -L "$file" ]] || [[ -e "$file" && ! -f "$file" ]]; then
            printf '%s:%s\n' "$file" "unsafe-file-type"
            continue
        fi
        [[ -f "$file" ]] || continue
        awk -v source="$file" -v mode="$mode" '
            /^[[:space:]]*[#;]/ {next}
            /^[[:space:]]*\[[^]]+\]/ {
                section=$0
                sub(/^[[:space:]]*\[/, "", section)
                sub(/\].*$/, "", section)
                in_sshd=(tolower(section) == "sshd")
                next
            }
            in_sshd {
                line=$0
                sub(/^[[:space:]]*/, "", line)
                key=line
                sub(/[[:space:]]*[=:].*$/, "", key)
                key=tolower(key)
                if (key == "port" ||
                    (mode == "full" &&
                     (key == "enabled" || key == "maxretry" ||
                      key == "findtime" || key == "bantime"))) {
                    print source ":" key
                }
            }
        ' "$file"
    done
}

verify_fail2ban_sshd_runtime() {
    local mode="$1"
    local expect_sshd_jail="${2:-1}"
    local actual

    FAIL2BAN_VERIFY_FAILURE=""
    timeout 15 fail2ban-client ping >/dev/null 2>&1 || {
        FAIL2BAN_VERIFY_FAILURE="fail2ban-client ping 失败"
        return 1
    }
    [[ "$expect_sshd_jail" == "1" ]] || return 0
    timeout 15 fail2ban-client status sshd >/dev/null 2>&1 || {
        FAIL2BAN_VERIFY_FAILURE="sshd jail 未运行"
        return 1
    }
    if [[ "$mode" == "full" ]]; then
        actual=$(timeout 15 fail2ban-client get sshd maxretry 2>/dev/null) || {
            FAIL2BAN_VERIFY_FAILURE="无法读取 sshd maxretry"
            return 1
        }
        [[ "$actual" == "5" ]] || {
            FAIL2BAN_VERIFY_FAILURE="sshd maxretry 期望=5 实际=$actual"
            return 1
        }
        actual=$(timeout 15 fail2ban-client get sshd findtime 2>/dev/null) || {
            FAIL2BAN_VERIFY_FAILURE="无法读取 sshd findtime"
            return 1
        }
        [[ "$actual" == "3600" ]] || {
            FAIL2BAN_VERIFY_FAILURE="sshd findtime 期望=3600 实际=$actual"
            return 1
        }
        actual=$(timeout 15 fail2ban-client get sshd bantime 2>/dev/null) || {
            FAIL2BAN_VERIFY_FAILURE="无法读取 sshd bantime"
            return 1
        }
        [[ "$actual" == "86400" ]] || {
            FAIL2BAN_VERIFY_FAILURE="sshd bantime 期望=86400 实际=$actual"
            return 1
        }
    fi
}

restore_fail2ban_transaction() {
    local target_file="$1"
    local backup_file="$2"
    local file_existed="$3"
    local service_active="$4"
    local service_enabled="$5"
    local legacy_file="${6:-}"
    local legacy_backup="${7:-}"
    local legacy_existed="${8:-0}"
    local failed=0

    if [[ "$file_existed" == "1" ]]; then
        cp -a -- "$backup_file" "$target_file" || failed=1
    else
        rm -f -- "$target_file" || failed=1
    fi
    if [[ "$legacy_existed" == "1" ]]; then
        mkdir -p "$(dirname "$legacy_file")" || failed=1
        cp -a -- "$legacy_backup" "$legacy_file" || failed=1
    fi

    restore_unit_enablement fail2ban.service "$service_enabled" || failed=1
    systemctl daemon-reload >/dev/null 2>&1 || failed=1
    if [[ "$service_active" == "active" ]]; then
        systemctl restart fail2ban >/dev/null 2>&1 || failed=1
    else
        systemctl stop fail2ban >/dev/null 2>&1 || true
    fi
    return "$failed"
}

rollback_fail2ban_with_message() {
    local backup_path="$1"
    local message="$2"
    shift 2

    if restore_fail2ban_transaction "$@"; then
        error "$message，jail.local 与服务状态已回滚。备份：$backup_path"
    else
        error "$message，自动回滚不完整，请从 $backup_path 手动恢复。"
    fi
}

update_fail2ban_sshd_jail() {
    local port="$1"
    local mode="$2"
    local start_service="${3:-0}"
    local target_file="/etc/fail2ban/jail.local"
    local source_file
    local legacy_file="/etc/fail2ban/jail.d/99-vps-init-port.local"
    local backup_path
    local backup_file
    local temp_file
    local section_count=0
    local file_existed=0
    local service_active
    local service_enabled
    local sshd_jail_active_before=0
    local expect_sshd_jail=0
    local legacy_backup
    local legacy_existed=0
    local late_overrides
    local override
    local command_output
    local command_status

    backup_path="$BACKUP_DIR/fail2ban-$(date +%Y%m%d%H%M%S)-$$"
    backup_file="$backup_path/jail.local"
    legacy_backup="$backup_path/99-vps-init-port.local"

    require_commands "Fail2ban 配置" awk mktemp timeout fail2ban-client systemctl || return 1
    if ! fail2ban_port_list_is_safe "$port"; then
        error "Fail2ban SSH 端口列表无效：$port"
        return 1
    fi
    if [[ -L "$target_file" ]] || [[ -e "$target_file" && ! -f "$target_file" ]]; then
        error "$target_file 不是可安全替换的普通文件，已停止操作。"
        return 1
    fi
    prepare_backup_path "$backup_path" || return 1
    mkdir -p "$(dirname "$target_file")" || return 1
    if [[ -f "$target_file" ]]; then
        file_existed=1
        cp -a -- "$target_file" "$backup_file" || return 1
        section_count=$(awk 'tolower($0) ~ /^[[:space:]]*\[sshd\][[:space:]]*([#;].*)?$/ {count++} END {print count+0}' "$target_file")
        if (( section_count > 1 )); then
            error "$target_file 中存在多个 [sshd] 段，已停止自动修改。"
            return 1
        fi
        if fail2ban_file_has_after_include "$target_file"; then
            error "$target_file 的 [INCLUDES] 含有 after 文件；无法证明后置文件不会覆盖 sshd 参数，已停止自动修改。"
            detail "FAIL2BAN" "PREFLIGHT" "检测到 jail.local 后置 include；配置=$target_file"
            return 1
        fi
    else
        : > "$backup_file" || return 1
    fi
    if [[ -L "$legacy_file" ]] || [[ -e "$legacy_file" && ! -f "$legacy_file" ]]; then
        error "$legacy_file 不是可安全迁移的普通文件。"
        return 1
    elif [[ -f "$legacy_file" ]]; then
        legacy_existed=1
        cp -a -- "$legacy_file" "$legacy_backup" || return 1
    fi

    service_active=$(systemctl is-active fail2ban 2>/dev/null || true)
    service_enabled=$(systemctl is-enabled fail2ban 2>/dev/null || true)
    if ! unit_transaction_state_is_supported "$service_enabled" "$service_active"; then
        error "fail2ban.service 的 systemd 状态无法安全事务化（启用=$service_enabled，运行=$service_active），已停止操作。"
        return 1
    fi
    if [[ "$service_active" == "active" ]] && \
       timeout 15 fail2ban-client status sshd >/dev/null 2>&1; then
        sshd_jail_active_before=1
    fi
    source_file="$target_file"
    [[ "$file_existed" == "0" ]] && source_file=/dev/null
    temp_file=$(mktemp /etc/fail2ban/.vps-init-jail.XXXXXX) || return 1
    if ! render_fail2ban_sshd_section "$source_file" "$temp_file" "$port" "$mode"; then
        rm -f -- "$temp_file"
        error "Fail2ban [sshd] 配置生成失败，原文件未修改。"
        return 1
    fi
    if [[ "$file_existed" == "1" ]]; then
        chmod --reference="$target_file" "$temp_file" || { rm -f -- "$temp_file"; return 1; }
        chown --reference="$target_file" "$temp_file" || { rm -f -- "$temp_file"; return 1; }
    else
        chmod 640 "$temp_file" || { rm -f -- "$temp_file"; return 1; }
        chown root:root "$temp_file" || { rm -f -- "$temp_file"; return 1; }
    fi
    mv -f -- "$temp_file" "$target_file" || return 1
    if [[ "$legacy_existed" == "1" ]] && ! rm -f -- "$legacy_file"; then
        rollback_fail2ban_with_message "$backup_path" "旧版独立端口文件迁移失败" \
            "$target_file" "$backup_file" "$file_existed" "$service_active" "$service_enabled" \
            "$legacy_file" "$legacy_backup" "$legacy_existed"
        return 1
    fi

    late_overrides=$(find_fail2ban_late_sshd_overrides "$mode")
    if [[ -n "$late_overrides" ]]; then
        echo "以下 jail.d/*.local 配置会在 jail.local 之后覆盖本次设置："
        while IFS= read -r override; do
            printf ' - %s\n' "$override"
        done <<< "$late_overrides"
        rollback_fail2ban_with_message "$backup_path" "检测到加载顺序更晚的 sshd jail 覆盖项" \
            "$target_file" "$backup_file" "$file_existed" "$service_active" "$service_enabled" \
            "$legacy_file" "$legacy_backup" "$legacy_existed"
        return 1
    fi

    command_output=$(timeout 20 fail2ban-client -t 2>&1)
    command_status=$?
    if (( command_status != 0 )); then
        detail "FAIL2BAN" "CONFIG_TEST" "退出码=$command_status；输出=${command_output:-无}"
        rollback_fail2ban_with_message "$backup_path" "Fail2ban 配置测试失败" \
            "$target_file" "$backup_file" "$file_existed" "$service_active" "$service_enabled" \
            "$legacy_file" "$legacy_backup" "$legacy_existed"
        return 1
    fi

    if [[ "$start_service" == "1" ]]; then
        command_output=$(systemctl enable fail2ban 2>&1)
        command_status=$?
        if (( command_status == 0 )); then
            command_output=$(systemctl restart fail2ban 2>&1)
            command_status=$?
        fi
        if (( command_status != 0 )); then
            detail "FAIL2BAN" "START_SERVICE" "退出码=$command_status；输出=${command_output:-无}"
            rollback_fail2ban_with_message "$backup_path" "Fail2ban 启用或重启失败" \
                "$target_file" "$backup_file" "$file_existed" "$service_active" "$service_enabled" \
                "$legacy_file" "$legacy_backup" "$legacy_existed"
            return 1
        fi
    elif [[ "$service_active" == "active" ]]; then
        command_output=$(systemctl restart fail2ban 2>&1)
        command_status=$?
        if (( command_status != 0 )); then
            detail "FAIL2BAN" "RESTART_SERVICE" "退出码=$command_status；输出=${command_output:-无}"
            rollback_fail2ban_with_message "$backup_path" "Fail2ban 重启失败" \
                "$target_file" "$backup_file" "$file_existed" "$service_active" "$service_enabled" \
                "$legacy_file" "$legacy_backup" "$legacy_existed"
            return 1
        fi
    fi

    if [[ "$mode" == "full" || "$start_service" == "1" || \
          "$sshd_jail_active_before" == "1" ]]; then
        expect_sshd_jail=1
    fi
    if [[ "$start_service" == "1" || "$service_active" == "active" ]] && \
       ! verify_fail2ban_sshd_runtime "$mode" "$expect_sshd_jail"; then
        detail "FAIL2BAN" "RUNTIME_VERIFY" "原因=${FAIL2BAN_VERIFY_FAILURE:-未知}；模式=$mode；要求 sshd jail=$expect_sshd_jail"
        rollback_fail2ban_with_message "$backup_path" "Fail2ban 重启后 sshd jail 或生效参数验证失败" \
            "$target_file" "$backup_file" "$file_existed" "$service_active" "$service_enabled" \
            "$legacy_file" "$legacy_backup" "$legacy_existed"
        return 1
    fi

    detail "FAIL2BAN" "VERIFY" "配置=$target_file；端口=$port；模式=$mode；语法和运行状态验证通过；备份=$backup_path"
    [[ "$legacy_existed" == "1" ]] && \
        detail "FAIL2BAN" "MIGRATE" "旧版独立端口文件已迁移并移除：$legacy_file"
    return 0
}

sync_fail2ban_ssh_port() {
    local port="$1"

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        return 0
    fi
    if update_fail2ban_sshd_jail "$port" port; then
        detail "FAIL2BAN" "SYNC_PORT" "SSH 端口已同步为 $port"
    else
        detail "FAIL2BAN" "SYNC_PORT" "SSH 已切换到端口 $port，但 Fail2ban 端口同步失败"
        return 1
    fi
}

add_unique_path() {
    local array_name="$1"
    local value="$2"
    local existing
    local -n target_array="$array_name"

    for existing in "${target_array[@]}"; do
        [[ "$existing" == "$value" ]] && return 0
    done
    target_array+=("$value")
}

array_contains_value() {
    local array_name="$1"
    local value="$2"
    local existing
    local -n source_array="$array_name"

    for existing in "${source_array[@]}"; do
        [[ "$existing" == "$value" ]] && return 0
    done
    return 1
}

array_contains_package_name() {
    local array_name="$1"
    local value="${2%%:*}"
    local existing
    local -n source_array="$array_name"

    for existing in "${source_array[@]}"; do
        [[ "${existing%%:*}" == "$value" ]] && return 0
    done
    return 1
}

paths_resolve_to_same_file() {
    local first="$1"
    local second="$2"
    local first_real
    local second_real

    first_real=$(readlink -f -- "$first" 2>/dev/null || true)
    second_real=$(readlink -f -- "$second" 2>/dev/null || true)
    [[ -n "$first_real" && -n "$second_real" && "$first_real" == "$second_real" ]]
}

sysctl_file_has_scope() {
    local file="$1"
    local scope="$2"

    awk -v scope="$scope" '
        {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            if (line == "" || line ~ /^[#;]/) next
            sub(/^-[[:space:]]*/, "", line)
            equals=index(line, "=")
            if (!equals) next
            lhs=substr(line, 1, equals-1)
            gsub(/[[:space:]]/, "", lhs)
            gsub(/\//, ".", lhs)
            if (scope == "bbr" &&
                (lhs == "net.ipv4.tcp_congestion_control" || lhs == "net.core.default_qdisc")) found=1
            if (scope == "tcp" &&
                (lhs ~ /^net\.ipv4\.tcp_[A-Za-z0-9_]+$/ || lhs ~ /^net\.core\.[A-Za-z0-9_]+$/)) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$file" 2>/dev/null
}

scan_sysctl_configs() {
    local dir
    local file
    local filename
    local real_file
    local is_etc_file
    local name
    local -A effective_by_name=()
    local -a scan_dirs=(/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d)
    local -a sorted_names=()

    EFFECTIVE_SYSCTL_FILES=()
    ETC_TCP_FILES=()
    LEGACY_TCP_FILES=()
    LAST_EFFECTIVE_KEY_FILE=""
    LEGACY_SYSCTL_CONF_STANDALONE=0

    for dir in "${scan_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' file; do
            filename=$(basename "$file")
            [[ -n "${effective_by_name[$filename]+x}" ]] && continue
            effective_by_name[$filename]="$file"
        done < <(find "$dir" -maxdepth 1 \( -type f -o -type l \) -name '*.conf' -print0 2>/dev/null)
    done

    if (( ${#effective_by_name[@]} > 0 )); then
        mapfile -t sorted_names < <(printf '%s\n' "${!effective_by_name[@]}" | LC_ALL=C sort)
        for name in "${sorted_names[@]}"; do
            EFFECTIVE_SYSCTL_FILES+=("${effective_by_name[$name]}")
        done
    fi
    if [[ -f /etc/sysctl.conf ]]; then
        real_file=$(readlink -f /etc/sysctl.conf 2>/dev/null || printf '%s' /etc/sysctl.conf)
        for file in "${EFFECTIVE_SYSCTL_FILES[@]}"; do
            if [[ "$(readlink -f "$file" 2>/dev/null || printf '%s' "$file")" == "$real_file" ]]; then
                real_file=""
                break
            fi
        done
        if [[ -n "$real_file" ]]; then
            LEGACY_SYSCTL_CONF_STANDALONE=1
            if sysctl_file_has_scope /etc/sysctl.conf tcp; then
                LEGACY_TCP_FILES+=(/etc/sysctl.conf)
            fi
        fi
    fi

    for file in "${EFFECTIVE_SYSCTL_FILES[@]}"; do
        real_file=$(readlink -f "$file" 2>/dev/null || printf '%s' "$file")
        is_etc_file=0
        [[ "$file" == /etc/* && "$real_file" == /etc/* ]] && is_etc_file=1

        if sysctl_file_has_scope "$file" bbr; then
            LAST_EFFECTIVE_KEY_FILE="$file"
        fi

        if sysctl_file_has_scope "$file" tcp; then
            if [[ "$is_etc_file" == "1" ]]; then
                add_unique_path ETC_TCP_FILES "$file"
            fi
        fi
    done
}

sysctl_file_has_ipv6_disable_setting() {
    local file="$1"

    awk '
        {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            if (line == "" || line ~ /^[#;]/) next
            sub(/^-[[:space:]]*/, "", line)
            equals=index(line, "=")
            if (!equals) next
            lhs=substr(line, 1, equals-1)
            gsub(/[[:space:]]/, "", lhs)
            gsub(/\//, ".", lhs)
            if (lhs ~ /^net\.ipv6\.conf\..+\.disable_ipv6$/) found=1
        }
        END {exit(found ? 0 : 1)}
    ' "$file" 2>/dev/null
}

select_ipv6_sysctl_target() {
    local effective_file
    local latest_file=""
    local latest_name=""
    local candidate
    local candidate_name
    local collision
    local LC_ALL=C
    local -a candidates=(
        /etc/sysctl.d/99-zz-vps-init-ipv6.conf
        /etc/sysctl.d/zz-vps-init-ipv6.conf
        /etc/sysctl.d/zzzz-vps-init-ipv6.conf
    )

    scan_sysctl_configs
    for effective_file in "${EFFECTIVE_SYSCTL_FILES[@]}"; do
        if sysctl_file_has_ipv6_disable_setting "$effective_file"; then
            latest_file="$effective_file"
            latest_name=$(basename "$effective_file")
        fi
    done

    for candidate in "${candidates[@]}"; do
        [[ ! -L "$candidate" ]] || continue
        [[ ! -e "$candidate" || -f "$candidate" ]] || continue
        candidate_name=$(basename "$candidate")
        collision=0
        for effective_file in "${EFFECTIVE_SYSCTL_FILES[@]}"; do
            if [[ "$(basename "$effective_file")" == "$candidate_name" && \
                  "$effective_file" != "$candidate" ]]; then
                collision=1
                break
            fi
        done
        [[ "$collision" == "0" ]] || continue
        if [[ -n "$latest_name" && "$candidate_name" < "$latest_name" ]]; then
            continue
        fi
        if [[ -n "$latest_name" && "$candidate_name" == "$latest_name" && \
              "$latest_file" != "$candidate" ]]; then
            continue
        fi
        IPV6_SYSCTL_FILE="$candidate"
        return 0
    done

    error "未找到能够晚于 ${latest_name:-现有配置} 加载且不遮蔽系统文件的 IPv6 sysctl 文件名。"
    [[ -n "$latest_file" ]] && echo "最终相关配置：$latest_file"
    return 1
}

choose_path_interactively() {
    local prompt="$1"
    shift
    local -a candidates=("$@")
    local index
    local choice

    while true; do
        echo "$prompt"
        for index in "${!candidates[@]}"; do
            printf ' %d. %s\n' "$((index + 1))" "${candidates[$index]}"
        done
        echo " 0. 取消"
        read -r -p "请选择配置文件: " choice
        if [[ "$choice" == "0" ]]; then
            SYSCTL_TARGET=""
            print_result "BBR / FQ" "已取消" "未修改任何 sysctl 文件"
            return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidates[@]} )); then
            SYSCTL_TARGET="${candidates[$((choice - 1))]}"
            return 0
        fi
        error "无效的配置文件选项，请重新选择。"
    done
}

select_sysctl_target() {
    local resolved_target
    local latest_key_real
    local latest_key_name=""
    local candidate
    local candidate_name
    local effective_file
    local candidate_in_use
    local LC_ALL=C
    local -a override_candidates=(
        /etc/sysctl.d/99-vps-init.conf
        /etc/sysctl.d/zz-vps-init-bbr.conf
        /etc/sysctl.d/zzzz-vps-init-bbr.conf
    )

    SYSCTL_TARGET=""
    scan_sysctl_configs

    if [[ -n "$LAST_EFFECTIVE_KEY_FILE" ]]; then
        latest_key_name=$(basename "$LAST_EFFECTIVE_KEY_FILE")
        latest_key_real=$(readlink -f "$LAST_EFFECTIVE_KEY_FILE" 2>/dev/null || printf '%s' "$LAST_EFFECTIVE_KEY_FILE")
        if [[ "$LAST_EFFECTIVE_KEY_FILE" == /etc/* && "$latest_key_real" == /etc/* ]]; then
            SYSCTL_TARGET="$latest_key_real"
            log "将更新最终生效的本地 sysctl 文件：$LAST_EFFECTIVE_KEY_FILE"
        else
            warn "最终生效的 BBR/队列配置来自只读位置：$LAST_EFFECTIVE_KEY_FILE，将创建更晚加载的本地覆盖文件。"
        fi
    elif (( ${#ETC_TCP_FILES[@]} == 1 )); then
        SYSCTL_TARGET="${ETC_TCP_FILES[0]}"
    elif (( ${#ETC_TCP_FILES[@]} > 1 )); then
        choose_path_interactively "检测到多个实际参与加载的 /etc TCP 参数文件，请选择写入位置：" "${ETC_TCP_FILES[@]}" || return 1
    fi

    if [[ -z "$SYSCTL_TARGET" ]]; then
        for candidate in "${override_candidates[@]}"; do
            candidate_name=$(basename "$candidate")
            candidate_in_use=0
            for effective_file in "${EFFECTIVE_SYSCTL_FILES[@]}"; do
                if [[ "$(basename "$effective_file")" == "$candidate_name" && \
                      "$effective_file" != "$candidate" ]]; then
                    candidate_in_use=1
                    break
                fi
            done
            [[ "$candidate_in_use" == "0" ]] || continue
            if [[ -n "$latest_key_name" && "$candidate_name" < "$latest_key_name" ]] || [[ "$candidate_name" == "$latest_key_name" ]]; then
                continue
            fi
            if [[ -L "$candidate" ]]; then
                resolved_target=$(readlink -f "$candidate" 2>/dev/null)
                [[ "$resolved_target" == /etc/* ]] || continue
            fi
            SYSCTL_TARGET="$candidate"
            break
        done
        if [[ -z "$SYSCTL_TARGET" ]]; then
            error "未找到能够晚于 $latest_key_name 加载的安全本地 sysctl 文件名。"
            return 1
        fi
        log "将使用本地托管配置：$SYSCTL_TARGET"
    fi

    if (( ${#LEGACY_TCP_FILES[@]} > 0 )); then
        warn "检测到未通过 sysctl.d 链接加载的 /etc/sysctl.conf，仅检查、不直接修改。"
    fi

    if [[ -L "$SYSCTL_TARGET" ]]; then
        resolved_target=$(readlink -f "$SYSCTL_TARGET" 2>/dev/null)
        if [[ "$resolved_target" == /etc/* ]]; then
            log "$SYSCTL_TARGET 是符号链接，将安全更新其实际 /etc 文件：$resolved_target"
            SYSCTL_TARGET="$resolved_target"
        else
            error "$SYSCTL_TARGET 指向 /etc 之外，无法安全修改；未写入任何 sysctl 文件。"
            return 1
        fi
    fi

    return 0
}

get_effective_sysctl_value() {
    local key="$1"
    local file
    local file_value
    local value=""

    scan_sysctl_configs
    for file in "${EFFECTIVE_SYSCTL_FILES[@]}"; do
        file_value=$(awk -v wanted="$key" '
            {
                line=$0
                sub(/^[[:space:]]*-?[[:space:]]*/, "", line)
                equals=index(line, "=")
                if (!equals) next
                lhs=substr(line, 1, equals-1)
                gsub(/[[:space:]]/, "", lhs)
                gsub(/\//, ".", lhs)
                if (lhs != wanted) next
                rhs=substr(line, equals+1)
                sub(/^[[:space:]]*/, "", rhs)
                sub(/[[:space:]]*[#;].*$/, "", rhs)
                sub(/[[:space:]]*$/, "", rhs)
                value=rhs
            }
            END { if (value != "") print value }
        ' "$file" 2>/dev/null)
        [[ -n "$file_value" ]] && value="$file_value"
    done
    printf '%s' "$value"
}

bbr_persistence_is_complete() {
    local effective_cc
    local effective_qdisc

    effective_cc=$(get_effective_sysctl_value net.ipv4.tcp_congestion_control)
    effective_qdisc=$(get_effective_sysctl_value net.core.default_qdisc)
    [[ "$effective_cc" == "bbr" && "$effective_qdisc" == "fq" ]] || return 1

    if [[ -f /etc/sysctl.conf ]] && sysctl_file_has_scope /etc/sysctl.conf bbr; then
        sysctl_file_keys_match_values /etc/sysctl.conf \
            net.ipv4.tcp_congestion_control bbr \
            net.core.default_qdisc fq || return 1
    fi
}

get_effective_sysctl_source() {
    local key="$1"
    local file
    local source=""

    scan_sysctl_configs
    for file in "${EFFECTIVE_SYSCTL_FILES[@]}"; do
        if awk -v wanted="$key" '
            {
                line=$0
                sub(/^[[:space:]]*-?[[:space:]]*/, "", line)
                equals=index(line, "=")
                if (!equals) next
                lhs=substr(line, 1, equals-1)
                gsub(/[[:space:]]/, "", lhs)
                gsub(/\//, ".", lhs)
                if (lhs == wanted) found=1
            }
            END { exit(found ? 0 : 1) }
        ' "$file" 2>/dev/null; then
            source="$file"
        fi
    done
    printf '%s' "$source"
}

get_sysctl_value_from_file() {
    local file="$1"
    local key="$2"

    [[ -f "$file" ]] || return 1
    awk -v wanted="$key" '
        {
            line=$0
            sub(/^[[:space:]]*-?[[:space:]]*/, "", line)
            equals=index(line, "=")
            if (!equals) next
            lhs=substr(line, 1, equals-1)
            gsub(/[[:space:]]/, "", lhs)
            gsub(/\//, ".", lhs)
            if (lhs != wanted) next
            rhs=substr(line, equals+1)
            sub(/^[[:space:]]*/, "", rhs)
            sub(/[[:space:]]*[#;].*$/, "", rhs)
            sub(/[[:space:]]*$/, "", rhs)
            value=rhs
        }
        END { if (value != "") print value }
    ' "$file" 2>/dev/null
}

sysctl_file_keys_match_values() {
    local file="$1"
    shift
    local key
    local expected
    local actual

    (( $# > 0 && $# % 2 == 0 )) || return 2
    while (( $# > 0 )); do
        key="$1"
        expected="$2"
        shift 2
        actual=$(get_sysctl_value_from_file "$file" "$key")
        [[ -z "$actual" || "$actual" == "$expected" ]] || return 1
    done
}

sysctl_file_ipv6_disable_values_match() {
    local file="$1"
    local expected="$2"

    awk -v expected="$expected" '
        {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            if (line == "" || line ~ /^[#;]/) next
            sub(/^-[[:space:]]*/, "", line)
            equals=index(line, "=")
            if (!equals) next
            lhs=substr(line, 1, equals-1)
            gsub(/[[:space:]]/, "", lhs)
            gsub(/\//, ".", lhs)
            if (lhs !~ /^net\.ipv6\.conf\..+\.disable_ipv6$/) next
            rhs=substr(line, equals+1)
            sub(/^[[:space:]]*/, "", rhs)
            sub(/[[:space:]]*[#;].*$/, "", rhs)
            sub(/[[:space:]]*$/, "", rhs)
            seen=1
            if (rhs != expected) mismatch=1
        }
        END {exit(mismatch ? 1 : 0)}
    ' "$file" 2>/dev/null
}

sysctl_file_ipv6_interface_values_match() {
    local file="$1"
    local expected="$2"

    awk -v expected="$expected" '
        {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            if (line == "" || line ~ /^[#;]/) next
            sub(/^-[[:space:]]*/, "", line)
            equals=index(line, "=")
            if (!equals) next
            lhs=substr(line, 1, equals-1)
            gsub(/[[:space:]]/, "", lhs)
            gsub(/\//, ".", lhs)
            if (lhs !~ /^net\.ipv6\.conf\..+\.disable_ipv6$/) next
            if (lhs == "net.ipv6.conf.all.disable_ipv6" ||
                lhs == "net.ipv6.conf.default.disable_ipv6" ||
                lhs == "net.ipv6.conf.lo.disable_ipv6") next
            rhs=substr(line, equals+1)
            sub(/^[[:space:]]*/, "", rhs)
            sub(/[[:space:]]*[#;].*$/, "", rhs)
            sub(/[[:space:]]*$/, "", rhs)
            if (rhs != expected) mismatch=1
        }
        END {exit(mismatch ? 1 : 0)}
    ' "$file" 2>/dev/null
}

validate_effective_ipv6_interface_overrides() {
    local target_value="$1"
    local file
    local -a conflicts=()

    scan_sysctl_configs
    for file in "${EFFECTIVE_SYSCTL_FILES[@]}"; do
        if ! sysctl_file_ipv6_interface_values_match "$file" "$target_value"; then
            conflicts+=("$file")
        fi
    done
    if (( ${#conflicts[@]} > 0 )); then
        error "检测到与目标状态冲突的单接口 IPv6 开关；为避免重启或网卡重建后出现混合状态，已停止操作："
        printf ' - %s\n' "${conflicts[@]}"
        detail "IPV6" "INTERFACE_CONFLICT" "目标值=$target_value；冲突文件=${conflicts[*]}"
        return 1
    fi
}

ipv6_persistent_value_matches() {
    local configured_value="$1"
    local target_value="$2"

    if [[ "$target_value" == "0" ]]; then
        [[ -z "$configured_value" || "$configured_value" == "0" ]]
    else
        [[ "$configured_value" == "$target_value" ]]
    fi
}

ipv6_persistence_is_complete() {
    local target_value="$1"
    local file
    local configured_value
    local key

    for key in \
        net.ipv6.conf.all.disable_ipv6 \
        net.ipv6.conf.default.disable_ipv6 \
        net.ipv6.conf.lo.disable_ipv6; do
        configured_value=$(get_effective_sysctl_value "$key")
        ipv6_persistent_value_matches "$configured_value" "$target_value" || return 1
    done

    scan_sysctl_configs
    for file in "${EFFECTIVE_SYSCTL_FILES[@]}"; do
        sysctl_file_ipv6_interface_values_match "$file" "$target_value" || return 1
    done
    if [[ -f /etc/sysctl.conf ]] && \
       sysctl_file_has_ipv6_disable_setting /etc/sysctl.conf; then
        sysctl_file_ipv6_disable_values_match /etc/sysctl.conf "$target_value" || return 1
    fi
}

sysctl_final_pass_bbr_is_compatible() {
    local final_file="$1"
    local target_file="$2"

    [[ -f "$final_file" ]] || return 0
    paths_resolve_to_same_file "$final_file" "$target_file" && return 0
    sysctl_file_has_scope "$final_file" bbr || return 0
    sysctl_file_keys_match_values "$final_file" \
        net.ipv4.tcp_congestion_control bbr \
        net.core.default_qdisc fq
}

sysctl_final_pass_ipv6_is_compatible() {
    local final_file="$1"
    local target_file="$2"
    local target_value="$3"

    [[ -f "$final_file" ]] || return 0
    paths_resolve_to_same_file "$final_file" "$target_file" && return 0
    sysctl_file_has_ipv6_disable_setting "$final_file" || return 0
    sysctl_file_ipv6_disable_values_match "$final_file" "$target_value"
}

validate_sysctl_conf_final_pass_for_bbr() {
    scan_sysctl_configs
    [[ -f /etc/sysctl.conf ]] || return 0
    sysctl_file_has_scope /etc/sysctl.conf bbr || return 0

    if ! sysctl_final_pass_bbr_is_compatible /etc/sysctl.conf "$SYSCTL_TARGET"; then
        detail "BBR" "FINAL_PASS_CONFLICT" "/etc/sysctl.conf 中的 BBR/FQ 定义与目标值冲突；sysctl --system 会在最后再次读取该路径"
        error "/etc/sysctl.conf 中存在冲突的 BBR/FQ 定义；为避免以后执行 sysctl --system 时覆盖本次配置，已停止操作。"
        echo "请先迁移或移除其中的 net.ipv4.tcp_congestion_control / net.core.default_qdisc 定义。"
        return 1
    fi
    if paths_resolve_to_same_file /etc/sysctl.conf "$SYSCTL_TARGET"; then
        warn "/etc/sysctl.conf 会由 sysctl --system 最后再次读取，并与本次写入目标指向同一文件；将同步更新。"
    else
        warn "/etc/sysctl.conf 中存在相同的 BBR/FQ 定义；本次保留该文件不变。"
    fi
}

validate_sysctl_conf_final_pass_for_ipv6() {
    local target_value="$1"

    scan_sysctl_configs
    [[ -f /etc/sysctl.conf ]] || return 0
    sysctl_file_has_ipv6_disable_setting /etc/sysctl.conf || return 0

    if ! sysctl_final_pass_ipv6_is_compatible \
        /etc/sysctl.conf "$IPV6_SYSCTL_FILE" "$target_value"; then
        detail "IPV6" "FINAL_PASS_CONFLICT" "/etc/sysctl.conf 中的 disable_ipv6 定义与目标值 $target_value 冲突；sysctl --system 会在最后再次读取该路径"
        error "/etc/sysctl.conf 中存在冲突的 IPv6 开关定义；为避免以后执行 sysctl --system 时改变状态，已停止操作。"
        echo "请先迁移或移除其中的 net.ipv6.conf.*.disable_ipv6 定义。"
        return 1
    fi
    if paths_resolve_to_same_file /etc/sysctl.conf "$IPV6_SYSCTL_FILE"; then
        warn "/etc/sysctl.conf 会由 sysctl --system 最后再次读取，并与本次写入目标指向同一文件；将同步更新。"
    else
        warn "/etc/sysctl.conf 中存在相同的 IPv6 开关定义；本次保留该文件不变。"
    fi
}

write_sysctl_keys_atomic() {
    local file="$1"
    shift
    local key
    local value
    local flexible_key
    local temp_file

    (( $# > 0 && $# % 2 == 0 )) || return 1
    [[ ! -L "$file" ]] || return 1
    [[ ! -e "$file" || -f "$file" ]] || return 1
    mkdir -p "$(dirname "$file")" || return 1
    temp_file=$(mktemp "$(dirname "$file")/.vps-init-sysctl.XXXXXX") || return 1
    if [[ -f "$file" ]]; then
        if ! cp -a -- "$file" "$temp_file"; then
            rm -f -- "$temp_file"
            return 1
        fi
    elif ! chmod 644 "$temp_file" || ! chown root:root "$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi

    while (( $# > 0 )); do
        key="$1"
        value="$2"
        shift 2
        flexible_key="${key//./[.\/]}"
        if ! sed -i -E "\\|^[[:space:]]*-?[[:space:]]*${flexible_key}[[:space:]]*=|d" "$temp_file" || \
           ! ensure_text_file_ends_with_newline "$temp_file" || \
           ! printf '%s = %s\n' "$key" "$value" >> "$temp_file"; then
            rm -f -- "$temp_file"
            return 1
        fi
    done
    mv -f -- "$temp_file" "$file"
}

write_sysctl_key() {
    write_sysctl_keys_atomic "$@"
}

remove_sysctl_key() {
    local file="$1"
    local key="$2"
    local flexible_key="${key//./[.\/]}"
    local temp_file

    [[ -f "$file" ]] || return 0
    [[ ! -L "$file" ]] || return 1
    temp_file=$(mktemp "$(dirname "$file")/.vps-init-sysctl.XXXXXX") || return 1
    if ! cp -a -- "$file" "$temp_file" || \
       ! sed -i -E "\\|^[[:space:]]*-?[[:space:]]*${flexible_key}[[:space:]]*=|d" "$temp_file" || \
       ! mv -f -- "$temp_file" "$file"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

persist_bbr_settings() {
    local previous_cc="$1"
    local previous_qdisc="$2"
    local write_bbr="${3:-1}"
    local target_existed=0
    local backup_file=""
    local result_label="BBR + FQ"
    local effective_cc
    local effective_qdisc
    local rollback_failed=0

    select_sysctl_target || return 1
    validate_sysctl_conf_final_pass_for_bbr || return 1

    [[ "$write_bbr" == "0" ]] && result_label="FQ"
    detail "BBR" "DETECT" "目标=$SYSCTL_TARGET；写入 BBR=$write_bbr；原拥塞控制=${previous_cc:-未知}；原队列=${previous_qdisc:-未知}"

    if ! mkdir -p "$(dirname "$SYSCTL_TARGET")" || \
       ! prepare_private_directory "$BACKUP_DIR"; then
        error "无法创建 sysctl 配置或备份目录。"
        return 1
    fi
    if [[ -L "$SYSCTL_TARGET" ]] || [[ -e "$SYSCTL_TARGET" && ! -f "$SYSCTL_TARGET" ]]; then
        error "$SYSCTL_TARGET 不是可安全替换的普通文件。"
        return 1
    elif [[ -f "$SYSCTL_TARGET" ]]; then
        target_existed=1
        backup_file="$BACKUP_DIR/$(basename "$SYSCTL_TARGET").$(date +%Y%m%d%H%M%S)-$$.bak"
        if ! cp -a "$SYSCTL_TARGET" "$backup_file"; then
            error "无法备份 $SYSCTL_TARGET，未修改配置。"
            return 1
        fi
    fi

    if command -v modprobe >/dev/null 2>&1; then
        modprobe sch_fq >/dev/null 2>&1 || true
        [[ "$write_bbr" == "0" ]] || modprobe tcp_bbr >/dev/null 2>&1 || true
    fi

    if [[ "$write_bbr" == "1" ]] && \
       ! write_sysctl_keys_atomic "$SYSCTL_TARGET" \
           net.core.default_qdisc fq \
           net.ipv4.tcp_congestion_control bbr; then
        error "写入 BBR 与 FQ 配置失败。"
    elif [[ "$write_bbr" == "0" ]] && \
         ! write_sysctl_keys_atomic "$SYSCTL_TARGET" net.core.default_qdisc fq; then
        error "写入 FQ 配置失败。"
    else
        effective_qdisc=$(get_effective_sysctl_value net.core.default_qdisc)
        effective_cc=$(get_effective_sysctl_value net.ipv4.tcp_congestion_control)
        if [[ "$effective_qdisc" != "fq" ]] || \
           [[ "$write_bbr" == "1" && "$effective_cc" != "bbr" ]] || \
           ! bbr_persistence_is_complete; then
            error "配置文件加载顺序验证失败，重启后可能被其他 sysctl 文件覆盖。"
        elif sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 && \
             { [[ "$write_bbr" == "0" ]] || sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; } && \
             [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" == "fq" ]] && \
             { [[ "$write_bbr" == "0" ]] || [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; }; then
            action_success "$result_label" "运行状态和持久化顺序验证通过；配置：$SYSCTL_TARGET"
            [[ -n "$backup_file" ]] && detail "BBR" "BACKUP" "原配置备份=$backup_file"
            return 0
        fi
    fi

    effective_qdisc=$(get_effective_sysctl_value net.core.default_qdisc)
    effective_cc=$(get_effective_sysctl_value net.ipv4.tcp_congestion_control)
    detail "BBR" "VERIFY" "目标=$SYSCTL_TARGET；期望队列=fq；期望拥塞控制=$([[ "$write_bbr" == "1" ]] && printf bbr || printf 保持不变)；持久化队列=${effective_qdisc:-未定义}；持久化拥塞控制=${effective_cc:-未定义}；运行队列=$(sysctl -n net.core.default_qdisc 2>/dev/null || printf 未知)；运行拥塞控制=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 未知)"
    if [[ "$target_existed" == "1" ]]; then
        cp -a "$backup_file" "$SYSCTL_TARGET" || rollback_failed=1
    else
        rm -f "$SYSCTL_TARGET" || rollback_failed=1
    fi
    if [[ -n "$previous_qdisc" ]]; then
        sysctl -w "net.core.default_qdisc=$previous_qdisc" >/dev/null 2>&1 || rollback_failed=1
        [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" == "$previous_qdisc" ]] || rollback_failed=1
    fi
    if [[ -n "$previous_cc" ]]; then
        sysctl -w "net.ipv4.tcp_congestion_control=$previous_cc" >/dev/null 2>&1 || rollback_failed=1
        [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "$previous_cc" ]] || rollback_failed=1
    fi
    if [[ "$rollback_failed" == "0" ]]; then
        detail "BBR" "ROLLBACK" "配置文件和运行参数恢复成功；目标=$SYSCTL_TARGET"
        error "$result_label 应用失败，配置文件和运行参数已回滚。"
    else
        detail "BBR" "ROLLBACK" "自动恢复不完整；目标=$SYSCTL_TARGET；备份=${backup_file:-无}"
        error "$result_label 应用失败且自动回滚不完整，请使用备份 ${backup_file:-$SYSCTL_TARGET} 手动恢复。"
    fi
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" && $EUID -ne 0 ]]; then
    error "请以 root 权限运行本脚本！"
    exit 1
fi

# ==========================================
# 1. 系统环境精准嗅探
# ==========================================
OS_ID=""
OS_VERSION=""
OS_CODENAME=""
OS_ARCH=""
OS_MAINTENANCE_CODE="unknown"
UBUNTU_PRO_ESM_STATUS_REASON=""

os_version_is_supported() {
    local os_id="$1"
    local os_version="$2"

    case "$os_id:$os_version" in
        debian:12|debian:13|ubuntu:20.04|ubuntu:22.04|ubuntu:24.04) return 0 ;;
        *) return 1 ;;
    esac
}

os_codename_matches_version() {
    local os_id="$1"
    local os_version="$2"
    local os_codename="$3"

    case "$os_id:$os_version:$os_codename" in
        debian:12:bookworm|debian:13:trixie|\
        ubuntu:20.04:focal|ubuntu:22.04:jammy|ubuntu:24.04:noble) return 0 ;;
        *) return 1 ;;
    esac
}

ubuntu_pro_json_result_is_usable() {
    local json="$1"

    # Newer Pro clients wrap API attributes with a result field, while older
    # documented clients may print the attributes directly. If a result field
    # exists, only an explicit success response is accepted.
    if grep -Eq '"result"[[:space:]]*:' <<< "$json"; then
        grep -Eq '"result"[[:space:]]*:[[:space:]]*"success"' <<< "$json"
    else
        return 0
    fi
}

ubuntu_pro_attachment_json_is_valid() {
    local json="$1"

    ubuntu_pro_json_result_is_usable "$json" &&
        grep -Eq '"is_attached_and_contract_valid"[[:space:]]*:[[:space:]]*true([[:space:],}])' <<< "$json"
}

ubuntu_pro_enabled_services_json_has_esm_infra() {
    local json="$1"

    ubuntu_pro_enabled_services_json_has_service "$json" esm-infra
}

ubuntu_pro_enabled_services_json_has_service() {
    local json="$1"
    local service="$2"
    local pattern

    [[ "$service" =~ ^[a-z0-9-]+$ ]] || return 1
    pattern="\"name\"[[:space:]]*:[[:space:]]*\"${service}\""
    ubuntu_pro_json_result_is_usable "$json" &&
        grep -Eq "$pattern" <<< "$json"
}

ubuntu_pro_service_is_active() {
    local service="$1"
    local attachment_json=""
    local services_json=""

    [[ "$service" =~ ^[a-z0-9-]+$ ]] || return 1
    UBUNTU_PRO_ESM_STATUS_REASON=""
    if ! command -v pro >/dev/null 2>&1; then
        UBUNTU_PRO_ESM_STATUS_REASON="未找到 Ubuntu Pro 客户端（pro）"
        return 1
    fi
    if ! command -v timeout >/dev/null 2>&1; then
        UBUNTU_PRO_ESM_STATUS_REASON="缺少用于限制状态检查时长的 timeout 命令"
        return 1
    fi
    if ! attachment_json=$(LC_ALL=C timeout 15 pro api \
            u.pro.status.is_attached.v1 2>/dev/null); then
        UBUNTU_PRO_ESM_STATUS_REASON="Pro 客户端无法执行合同状态 API（请更新 ubuntu-advantage-tools）"
        return 1
    fi
    if ! ubuntu_pro_attachment_json_is_valid "$attachment_json"; then
        UBUNTU_PRO_ESM_STATUS_REASON="Ubuntu Pro 未绑定，或当前合同已经失效"
        return 1
    fi
    if ! services_json=$(LC_ALL=C timeout 15 pro api \
            u.pro.status.enabled_services.v1 2>/dev/null); then
        UBUNTU_PRO_ESM_STATUS_REASON="Pro 客户端无法读取已启用服务"
        return 1
    fi
    if ! ubuntu_pro_enabled_services_json_has_service "$services_json" "$service"; then
        UBUNTU_PRO_ESM_STATUS_REASON="$service 未启用"
        return 1
    fi
}

ubuntu_pro_esm_infra_is_active() {
    ubuntu_pro_service_is_active esm-infra
}

ubuntu_pro_esm_apps_is_active() {
    ubuntu_pro_service_is_active esm-apps
}

os_arch_is_supported() {
    local os_id="$1"
    local os_version="$2"
    local architecture="$3"

    case "$os_id:$os_version" in
        debian:12)
            case "$architecture" in
                amd64|arm64|armel|armhf|i386|mips64el|mipsel|ppc64el|s390x) return 0 ;;
            esac
            ;;
        debian:13)
            case "$architecture" in
                amd64|arm64|armhf|ppc64el|riscv64|s390x) return 0 ;;
            esac
            ;;
        ubuntu:20.04|ubuntu:22.04|ubuntu:24.04)
            case "$architecture" in
                amd64|arm64|armhf|ppc64el|riscv64|s390x) return 0 ;;
            esac
            ;;
    esac
    return 1
}

debian_lts_arch_is_supported() {
    local version="$1"
    local architecture="$2"

    case "$version" in
        12)
            case "$architecture" in
                amd64|i386|arm64|armhf|ppc64el) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

debian_lts_arch_data_is_available() {
    [[ "$1" == "12" ]]
}

ubuntu_extended_maintenance_arch_is_supported() {
    local version="$1"
    local architecture="$2"

    case "$version" in
        20.04)
            case "$architecture" in
                amd64|arm64|ppc64el|riscv64|s390x) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

ubuntu_extended_maintenance_arch_data_is_available() {
    local version="$1"
    local phase="$2"

    [[ "$version" == "20.04" && "$phase" == "esm" ]]
}

report_debian_lts_package_support() {
    local support_output=""
    local support_status=0

    if ! command -v check-support-status >/dev/null 2>&1; then
        warn "未安装 debian-security-support，无法检查已安装软件包是否提前结束或仅受有限安全支持。"
        echo "建议执行：apt install debian-security-support"
        detail "OS" "DEBIAN_LTS_PACKAGES" "缺少 check-support-status；仅完成发行版与架构覆盖检查"
        return 0
    fi
    if ! command -v timeout >/dev/null 2>&1; then
        warn "缺少 timeout，未运行 Debian LTS 软件包覆盖检查。"
        return 0
    fi
    if support_output=$(LC_ALL=C timeout 30 check-support-status --no-heading 2>&1); then
        support_status=0
    else
        support_status=$?
    fi
    if (( support_status != 0 )); then
        warn "check-support-status 执行失败，无法确认全部已安装软件包的安全支持状态。"
        detail "OS" "DEBIAN_LTS_PACKAGES" "退出码=$support_status；输出=$support_output"
    elif grep -q '[^[:space:]]' <<< "$support_output"; then
        warn "以下已安装软件包的安全支持已结束、将提前结束或受到限制："
        printf '%s\n' "$support_output"
        detail "OS" "DEBIAN_LTS_PACKAGES" "检测结果=$support_output"
    else
        detail "OS" "DEBIAN_LTS_PACKAGES" "未发现提前结束或受限支持的软件包"
    fi
}

get_os_maintenance_code() {
    local os_id="$1"
    local os_version="$2"
    local today="${VPS_INIT_TODAY:-$(date +%Y%m%d)}"
    local normalized_date

    if ! [[ "$today" =~ ^[0-9]{8}$ ]]; then
        printf unknown
        return 0
    fi
    normalized_date=$(date -d \
        "${today:0:4}-${today:4:2}-${today:6:2}" +%Y%m%d 2>/dev/null || true)
    if [[ "$normalized_date" != "$today" ]]; then
        printf unknown
        return 0
    fi
    case "$os_id:$os_version" in
        debian:12)
            if (( 10#$today <= 20260711 )); then
                printf standard
            elif (( 10#$today <= 20280630 )); then
                printf lts
            else
                printf eol
            fi
            ;;
        debian:13)
            if (( 10#$today <= 20280809 )); then
                printf standard
            elif (( 10#$today <= 20300630 )); then
                printf lts
            else
                printf eol
            fi
            ;;
        ubuntu:20.04)
            if (( 10#$today <= 20250531 )); then
                printf standard
            elif (( 10#$today <= 20300531 )); then
                printf esm
            elif (( 10#$today <= 20350531 )); then
                printf legacy
            else
                printf eol
            fi
            ;;
        ubuntu:22.04)
            if (( 10#$today <= 20270531 )); then
                printf standard
            elif (( 10#$today <= 20320531 )); then
                printf esm
            elif (( 10#$today <= 20370531 )); then
                printf legacy
            else
                printf eol
            fi
            ;;
        ubuntu:24.04)
            if (( 10#$today <= 20290531 )); then
                printf standard
            elif (( 10#$today <= 20340531 )); then
                printf esm
            elif (( 10#$today <= 20390531 )); then
                printf legacy
            else
                printf eol
            fi
            ;;
        *) printf unknown ;;
    esac
}

format_os_maintenance_status() {
    case "${1:-$OS_MAINTENANCE_CODE}" in
        standard) printf '标准维护期' ;;
        lts) printf 'Debian LTS 维护期' ;;
        esm) printf 'Ubuntu Pro / ESM 维护期' ;;
        legacy) printf 'Ubuntu Pro Legacy 支持期' ;;
        eol) printf '维护已结束' ;;
        *) printf '未知' ;;
    esac
}

check_os() {
    if [ -f /etc/os-release ]; then
        OS_ID=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        OS_VERSION=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        OS_CODENAME=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
    else
        error "无法获取系统版本信息！"
        exit 1
    fi

    if ! os_version_is_supported "$OS_ID" "$OS_VERSION"; then
        error "当前系统 $OS_ID ${OS_VERSION:-未知版本} 不在已验证范围内。"
        echo "仅支持 Debian 12/13 与 Ubuntu 20.04/22.04/24.04。"
        exit 1
    fi
    if ! os_codename_matches_version "$OS_ID" "$OS_VERSION" "$OS_CODENAME"; then
        error "系统版本与代号不一致：$OS_ID ${OS_VERSION:-未知版本} / ${OS_CODENAME:-未知代号}。"
        echo "脚本仅接受官方对应关系：Debian 12/bookworm、13/trixie；Ubuntu 20.04/focal、22.04/jammy、24.04/noble。"
        exit 1
    fi
    if [[ ! -d /run/systemd/system ]]; then
        error "当前环境未运行 systemd；脚本的服务状态、回滚与持久化验证无法可靠执行，已停止操作。"
        exit 1
    fi

    OS_ARCH=$(dpkg --print-architecture 2>/dev/null || true)
    if ! os_arch_is_supported "$OS_ID" "$OS_VERSION" "$OS_ARCH"; then
        error "$OS_ID $OS_VERSION 的架构 ${OS_ARCH:-未知} 不在该版本的常规受支持与已验证范围内，脚本已停止。"
        exit 1
    fi
    OS_MAINTENANCE_CODE=$(get_os_maintenance_code "$OS_ID" "$OS_VERSION")
    case "$OS_MAINTENANCE_CODE" in
        lts)
            if [[ "$OS_ID" == "debian" ]] && \
               ! debian_lts_arch_data_is_available "$OS_VERSION"; then
                error "Debian $OS_VERSION 已进入 LTS，但当前脚本没有该阶段已发布的架构覆盖数据；请先更新脚本。"
                exit 1
            elif [[ "$OS_ID" == "debian" ]] && \
                 ! debian_lts_arch_is_supported "$OS_VERSION" "$OS_ARCH"; then
                error "Debian $OS_VERSION 已进入 LTS，但架构 ${OS_ARCH:-未知} 不在该版本的 LTS 覆盖范围内，脚本已停止。"
                exit 1
            fi
            warn "$OS_ID $OS_VERSION 已进入 Debian LTS 阶段，请确认所用架构和软件包仍在 LTS 覆盖范围内。"
            report_debian_lts_package_support
            ;;
        esm)
            if [[ "$OS_ID" == "ubuntu" ]] && \
               ! ubuntu_extended_maintenance_arch_data_is_available "$OS_VERSION" esm; then
                error "Ubuntu $OS_VERSION 已进入 ESM，但当前脚本没有该阶段已发布的架构覆盖数据；请先更新脚本。"
                exit 1
            elif [[ "$OS_ID" == "ubuntu" ]] && \
                 ! ubuntu_extended_maintenance_arch_is_supported "$OS_VERSION" "$OS_ARCH"; then
                error "Ubuntu $OS_VERSION 已进入 ESM，但架构 ${OS_ARCH:-未知} 不在该版本的官方 ESM 覆盖范围内，脚本已停止。"
                exit 1
            fi
            if ! ubuntu_pro_esm_infra_is_active; then
                error "Ubuntu $OS_VERSION 已结束标准安全维护，但无法确认有效的 ESM Infra：${UBUNTU_PRO_ESM_STATUS_REASON:-状态未知}。"
                echo "请先更新 ubuntu-advantage-tools，并使用 'pro status --all' 确认 esm-infra 为 enabled；脚本不会自动绑定订阅或启用服务。"
                exit 1
            fi
            warn "$OS_ID $OS_VERSION 已进入 ESM 阶段；已确认 Ubuntu Pro 合同有效且 esm-infra 已启用。"
            ;;
        legacy)
            if [[ "$OS_ID" == "ubuntu" ]] && \
               ! ubuntu_extended_maintenance_arch_data_is_available "$OS_VERSION" legacy; then
                error "Ubuntu $OS_VERSION 已进入 Legacy 支持期，但当前脚本没有该阶段已发布的架构覆盖数据；请先更新脚本。"
                exit 1
            elif [[ "$OS_ID" == "ubuntu" ]] && \
                 ! ubuntu_extended_maintenance_arch_is_supported "$OS_VERSION" "$OS_ARCH"; then
                error "Ubuntu $OS_VERSION 的架构 ${OS_ARCH:-未知} 不在该版本公开列出的 Legacy 覆盖范围内，脚本已停止。"
                exit 1
            fi
            warn "$OS_ID $OS_VERSION 已结束 ESM，仅在订阅 Ubuntu Pro Legacy 支持附加服务时仍受维护；建议尽快升级系统。"
            ;;
        eol)
            error "$OS_ID $OS_VERSION 的维护周期已经结束，为避免在无安全更新的系统上继续操作，脚本已停止。"
            exit 1
            ;;
        unknown)
            warn "无法判断 $OS_ID $OS_VERSION 的当前维护阶段，请核对系统日期后再执行更新操作。"
            ;;
    esac
}

check_dependencies() {
    local command_name
    local -a missing_commands=()
    local -a required_commands=(
        awk basename cat chmod chown clear cp cut date df dirname find free getent
        grep hostname ln mkdir mktemp mv paste readlink rm sed sleep sort stat
        systemctl tail timeout touch tr wc
    )

    for command_name in "${required_commands[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
    done
    if (( ${#missing_commands[@]} > 0 )); then
        error "缺少必要命令：${missing_commands[*]}"
        echo "请先补齐 systemd、procps、coreutils、ncurses-bin 等基础组件。"
        exit 1
    fi
}

acquire_instance_lock() {
    local lock_file="/run/lock/vps-init.lock"

    require_commands "单实例保护" flock || exit 1
    mkdir -p "$(dirname "$lock_file")" || {
        error "无法创建运行锁目录，已停止操作。"
        exit 1
    }
    if [[ -L "$lock_file" ]] || [[ -e "$lock_file" && ! -f "$lock_file" ]]; then
        error "运行锁 $lock_file 不是普通文件，已停止操作。"
        exit 1
    fi
    exec 9>>"$lock_file" || {
        error "无法打开运行锁 $lock_file，已停止操作。"
        exit 1
    }
    chmod 600 "$lock_file" 2>/dev/null || {
        error "无法设置运行锁权限，已停止操作。"
        exit 1
    }
    if ! flock -n 9; then
        error "检测到另一个 vps-init 实例正在运行；为避免并发修改系统配置，本次已退出。"
        exit 1
    fi
}

# ==========================================
# 辅助函数：安全重启 SSH 服务（兼容 Ubuntu 24.04+）
# ==========================================
ssh_unit_exists() {
    systemctl cat "$1" >/dev/null 2>&1
}

unit_transaction_state_is_supported() {
    local enablement="$1"
    local activity="$2"

    case "$enablement" in
        enabled|enabled-runtime|disabled|static|indirect|masked|masked-runtime) ;;
        *) return 1 ;;
    esac
    if [[ "$enablement" == masked* && "$activity" == "active" ]]; then
        return 1
    fi
}

begin_ssh_transaction() {
    SSH_BACKUP_PATH="$BACKUP_DIR/ssh-$(date +%Y%m%d%H%M%S)-$$"
    SSH_MANAGED_EXISTED=0
    SSH_SOCKET_ENABLED=$(systemctl is-enabled ssh.socket 2>/dev/null || true)
    SSH_SOCKET_ACTIVE=$(systemctl is-active ssh.socket 2>/dev/null || true)
    SSH_SERVICE_ENABLED=$(systemctl is-enabled ssh.service 2>/dev/null || true)
    SSH_SERVICE_ACTIVE=$(systemctl is-active ssh.service 2>/dev/null || true)
    SSH_SOCKET_SERVICE_DROPIN_EXISTED=0
    SSH_SOCKET_ADDRESS_DROPIN_EXISTED=0
    SSH_SOCKET_GENERATOR_MASK_EXISTED=0

    if ssh_unit_exists ssh.service && \
       ! unit_transaction_state_is_supported "$SSH_SERVICE_ENABLED" "$SSH_SERVICE_ACTIVE"; then
        error "ssh.service 的 systemd 状态无法安全事务化（启用=$SSH_SERVICE_ENABLED，运行=$SSH_SERVICE_ACTIVE），已停止操作。"
        return 1
    fi
    if ssh_unit_exists ssh.socket && \
       ! unit_transaction_state_is_supported "$SSH_SOCKET_ENABLED" "$SSH_SOCKET_ACTIVE"; then
        error "ssh.socket 的 systemd 状态无法安全事务化（启用=$SSH_SOCKET_ENABLED，运行=$SSH_SOCKET_ACTIVE），已停止操作。"
        return 1
    fi

    if [[ ! -f /etc/ssh/sshd_config || -L /etc/ssh/sshd_config ]]; then
        error "/etc/ssh/sshd_config 不是可安全替换的普通文件，已停止操作。"
        return 1
    fi
    if [[ -L "$SSH_MANAGED_FILE" ]] || \
       [[ -e "$SSH_MANAGED_FILE" && ! -f "$SSH_MANAGED_FILE" ]]; then
        error "$SSH_MANAGED_FILE 不是可安全替换的普通文件，已停止操作。"
        return 1
    fi
    prepare_backup_path "$SSH_BACKUP_PATH" || return 1
    mkdir -p "$(dirname "$SSH_MANAGED_FILE")" || return 1
    cp -a /etc/ssh/sshd_config "$SSH_BACKUP_PATH/sshd_config" || return 1
    if [[ -e "$SSH_MANAGED_FILE" || -L "$SSH_MANAGED_FILE" ]]; then
        SSH_MANAGED_EXISTED=1
        cp -a "$SSH_MANAGED_FILE" "$SSH_BACKUP_PATH/managed.conf" || return 1
    fi
    if [[ -e "$SSH_SOCKET_SERVICE_DROPIN" || -L "$SSH_SOCKET_SERVICE_DROPIN" ]]; then
        if [[ ! -f "$SSH_SOCKET_SERVICE_DROPIN" && ! -L "$SSH_SOCKET_SERVICE_DROPIN" ]]; then
            error "$SSH_SOCKET_SERVICE_DROPIN 不是普通文件或符号链接，已停止操作。"
            return 1
        fi
        SSH_SOCKET_SERVICE_DROPIN_EXISTED=1
        cp -a "$SSH_SOCKET_SERVICE_DROPIN" "$SSH_BACKUP_PATH/00-socket.conf" || return 1
    fi
    if [[ -e "$SSH_SOCKET_ADDRESS_DROPIN" || -L "$SSH_SOCKET_ADDRESS_DROPIN" ]]; then
        if [[ ! -f "$SSH_SOCKET_ADDRESS_DROPIN" && ! -L "$SSH_SOCKET_ADDRESS_DROPIN" ]]; then
            error "$SSH_SOCKET_ADDRESS_DROPIN 不是普通文件或符号链接，已停止操作。"
            return 1
        fi
        SSH_SOCKET_ADDRESS_DROPIN_EXISTED=1
        cp -a "$SSH_SOCKET_ADDRESS_DROPIN" "$SSH_BACKUP_PATH/addresses.conf" || return 1
    fi
    if [[ -e "$SSH_SOCKET_GENERATOR_MASK" || -L "$SSH_SOCKET_GENERATOR_MASK" ]]; then
        if [[ ! -f "$SSH_SOCKET_GENERATOR_MASK" && ! -L "$SSH_SOCKET_GENERATOR_MASK" ]]; then
            error "$SSH_SOCKET_GENERATOR_MASK 不是普通文件或符号链接，已停止操作。"
            return 1
        fi
        SSH_SOCKET_GENERATOR_MASK_EXISTED=1
        cp -a "$SSH_SOCKET_GENERATOR_MASK" "$SSH_BACKUP_PATH/sshd-socket-generator" || return 1
    fi
    detail "SSH" "BACKUP" "备份=$SSH_BACKUP_PATH；托管文件原先存在=$SSH_MANAGED_EXISTED；generator 屏蔽原先存在=$SSH_SOCKET_GENERATOR_MASK_EXISTED；ssh.service 启用=$SSH_SERVICE_ENABLED/运行=$SSH_SERVICE_ACTIVE；ssh.socket 启用=$SSH_SOCKET_ENABLED/运行=$SSH_SOCKET_ACTIVE"
}

restore_ssh_dropin() {
    local target="$1"
    local backup="$2"
    local existed="$3"

    if [[ -d "$target" && ! -L "$target" ]]; then
        return 1
    fi
    rm -f -- "$target" || return 1
    if [[ "$existed" == "1" ]]; then
        mkdir -p "$(dirname "$target")" || return 1
        cp -a -- "$backup" "$target" || return 1
    fi
}

restore_unit_enablement() {
    local unit="$1"
    local state="$2"
    local restored_state

    ssh_unit_exists "$unit" || return 0
    case "$state" in
        masked)
            systemctl stop "$unit" >/dev/null 2>&1 || return 1
            systemctl unmask "$unit" >/dev/null 2>&1 || true
            systemctl mask "$unit" >/dev/null 2>&1 || return 1
            ;;
        masked-runtime)
            systemctl stop "$unit" >/dev/null 2>&1 || return 1
            systemctl unmask "$unit" >/dev/null 2>&1 || true
            systemctl mask --runtime "$unit" >/dev/null 2>&1 || return 1
            ;;
        enabled)
            systemctl unmask "$unit" >/dev/null 2>&1 || return 1
            systemctl enable "$unit" >/dev/null 2>&1 || return 1
            ;;
        enabled-runtime)
            systemctl unmask "$unit" >/dev/null 2>&1 || return 1
            systemctl disable "$unit" >/dev/null 2>&1 || true
            systemctl enable --runtime "$unit" >/dev/null 2>&1 || return 1
            ;;
        *)
            systemctl unmask "$unit" >/dev/null 2>&1 || return 1
            systemctl disable "$unit" >/dev/null 2>&1 || true
            ;;
    esac
    restored_state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    [[ "$restored_state" == "$state" ]]
}

restore_ssh_transaction() {
    local failed=0

    cp -a "$SSH_BACKUP_PATH/sshd_config" /etc/ssh/sshd_config || failed=1
    if [[ "$SSH_MANAGED_EXISTED" == "1" ]]; then
        cp -a "$SSH_BACKUP_PATH/managed.conf" "$SSH_MANAGED_FILE" || failed=1
    else
        rm -f "$SSH_MANAGED_FILE" || failed=1
    fi
    restore_ssh_dropin "$SSH_SOCKET_SERVICE_DROPIN" \
        "$SSH_BACKUP_PATH/00-socket.conf" "$SSH_SOCKET_SERVICE_DROPIN_EXISTED" || failed=1
    restore_ssh_dropin "$SSH_SOCKET_ADDRESS_DROPIN" \
        "$SSH_BACKUP_PATH/addresses.conf" "$SSH_SOCKET_ADDRESS_DROPIN_EXISTED" || failed=1
    restore_ssh_dropin "$SSH_SOCKET_GENERATOR_MASK" \
        "$SSH_BACKUP_PATH/sshd-socket-generator" "$SSH_SOCKET_GENERATOR_MASK_EXISTED" || failed=1

    systemctl stop ssh.service >/dev/null 2>&1 || true
    systemctl stop ssh.socket >/dev/null 2>&1 || true
    restore_unit_enablement ssh.service "$SSH_SERVICE_ENABLED" || failed=1
    restore_unit_enablement ssh.socket "$SSH_SOCKET_ENABLED" || failed=1
    systemctl daemon-reload >/dev/null 2>&1 || failed=1

    if [[ "$SSH_SOCKET_ACTIVE" == "active" ]] && ssh_unit_exists ssh.socket; then
        systemctl start ssh.socket >/dev/null 2>&1 || failed=1
    fi
    if [[ "$SSH_SERVICE_ACTIVE" == "active" ]]; then
        systemctl start ssh.service >/dev/null 2>&1 || \
            systemctl start ssh >/dev/null 2>&1 || \
            systemctl start sshd >/dev/null 2>&1 || failed=1
    fi
    return "$failed"
}

rollback_ssh_with_message() {
    local message="$1"
    local configured_port
    local listening_ports

    configured_port=$(get_configured_ssh_ports)
    listening_ports=$(get_listening_ssh_ports)
    detail "SSH" "ROLLBACK" "触发原因=$message；配置端口=${configured_port:-未知}；监听端口=${listening_ports:-未检测到}；ssh.service=$(systemctl is-active ssh.service 2>/dev/null || printf 未知)；ssh.socket=$(systemctl is-active ssh.socket 2>/dev/null || printf 未知)；备份=$SSH_BACKUP_PATH"

    if restore_ssh_transaction; then
        detail "SSH" "ROLLBACK" "SSH 配置及 service/socket 状态恢复成功"
        error "$message，SSH 配置与 socket/service 状态已回滚。"
    else
        detail "SSH" "ROLLBACK" "SSH 自动恢复不完整；备份=$SSH_BACKUP_PATH"
        error "$message，自动回滚未完全成功，请从 $SSH_BACKUP_PATH 手动恢复。"
    fi
}

ensure_ssh_managed_include() {
    local temp_file

    mkdir -p "$(dirname "$SSH_MANAGED_FILE")" || return 1
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' /etc/ssh/sshd_config; then
        temp_file=$(mktemp /etc/ssh/.vps-init-sshd.XXXXXX) || return 1
        {
            echo "Include /etc/ssh/sshd_config.d/*.conf"
            cat /etc/ssh/sshd_config
        } > "$temp_file" || {
            rm -f "$temp_file"
            return 1
        }
        chmod --reference=/etc/ssh/sshd_config "$temp_file" || {
            rm -f "$temp_file"
            return 1
        }
        chown --reference=/etc/ssh/sshd_config "$temp_file" || {
            rm -f "$temp_file"
            return 1
        }
        mv -f "$temp_file" /etc/ssh/sshd_config || return 1
    fi
    touch "$SSH_MANAGED_FILE" || return 1
    chmod 600 "$SSH_MANAGED_FILE" || return 1
}

write_sshd_keys_atomic() {
    local key
    local value
    local temp_file

    (( $# > 0 && $# % 2 == 0 )) || return 1
    [[ -f "$SSH_MANAGED_FILE" && ! -L "$SSH_MANAGED_FILE" ]] || return 1
    temp_file=$(mktemp "$(dirname "$SSH_MANAGED_FILE")/.vps-init-sshd-managed.XXXXXX") || return 1
    if ! cp -a -- "$SSH_MANAGED_FILE" "$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
    while (( $# > 0 )); do
        key="$1"
        value="$2"
        shift 2
        [[ "$key" =~ ^[A-Za-z][A-Za-z0-9]+$ && "$value" != *$'\n'* ]] || {
            rm -f -- "$temp_file"
            return 1
        }
        if ! sed -i -E "/^[[:space:]]*${key}[[:space:]]+/Id" "$temp_file" || \
           ! ensure_text_file_ends_with_newline "$temp_file" || \
           ! printf '%s %s\n' "$key" "$value" >> "$temp_file"; then
            rm -f -- "$temp_file"
            return 1
        fi
    done
    mv -f -- "$temp_file" "$SSH_MANAGED_FILE"
}

write_sshd_key() {
    write_sshd_keys_atomic "$@"
}

has_valid_root_authorized_key() {
    local key_file="/root/.ssh/authorized_keys"

    [[ -r "$key_file" ]] || return 1
    if command -v ssh-keygen >/dev/null 2>&1; then
        ssh-keygen -l -f "$key_file" >/dev/null 2>&1
        return $?
    fi
    grep -Eq '(^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]]|$)' "$key_file"
}

get_effective_root_sshd_config() {
    local port
    local client_address="127.0.0.1"
    local server_address="127.0.0.1"
    local client_port
    local server_port
    local host_name="localhost"

    port=$(get_ssh_port)
    [[ "$port" =~ ^[0-9]+$ ]] || port=22
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r client_address client_port server_address server_port <<< "$SSH_CONNECTION"
        [[ -n "$server_port" ]] && port="$server_port"
    fi
    host_name=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf localhost)
    sshd -T -C "user=root,host=$host_name,addr=$client_address,laddr=$server_address,lport=$port" 2>/dev/null ||
        sshd -T 2>/dev/null
}

root_authorized_keys_path_is_effective() {
    local authorized_paths
    local path

    authorized_paths=$(get_effective_root_sshd_config |
        awk '/^authorizedkeysfile / {$1=""; sub(/^[[:space:]]+/, ""); print; exit}')
    for path in $authorized_paths; do
        case "$path" in
            .ssh/authorized_keys|%h/.ssh/authorized_keys|/root/.ssh/authorized_keys) return 0 ;;
        esac
    done
    return 1
}

root_authorized_keys_permissions_are_safe() {
    local path
    local owner
    local mode
    local mode_value

    for path in /root /root/.ssh /root/.ssh/authorized_keys; do
        [[ -e "$path" && ! -L "$path" ]] || return 1
        owner=$(stat -c '%U' "$path" 2>/dev/null) || return 1
        mode=$(stat -c '%a' "$path" 2>/dev/null) || return 1
        [[ "$owner" == "root" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        mode_value=$((8#$mode))
        (( (mode_value & 8#022) == 0 )) || return 1
    done
}

root_key_only_login_is_safe() {
    local effective_config
    local permit_root
    local pubkey_auth
    local password_auth
    local keyboard_auth
    local auth_methods

    effective_config=$(get_effective_root_sshd_config) || return 1
    permit_root=$(awk '/^permitrootlogin / {print $2; exit}' <<< "$effective_config")
    pubkey_auth=$(awk '/^pubkeyauthentication / {print $2; exit}' <<< "$effective_config")
    password_auth=$(awk '/^passwordauthentication / {print $2; exit}' <<< "$effective_config")
    keyboard_auth=$(awk '/^kbdinteractiveauthentication / {print $2; exit}' <<< "$effective_config")
    auth_methods=$(awk '/^authenticationmethods / {$1=""; sub(/^[[:space:]]+/, ""); print; exit}' <<< "$effective_config")

    case "$permit_root" in
        yes|prohibit-password|without-password) ;;
        *) return 1 ;;
    esac
    [[ "$pubkey_auth" == "yes" && "$password_auth" == "no" && "$keyboard_auth" == "no" ]] || return 1
    case " $auth_methods " in
        *" any "*|*" publickey "*) return 0 ;;
        *) return 1 ;;
    esac
}

ssh_uses_ubuntu_socket_generator() {
    local ubuntu_major="${OS_VERSION%%.*}"

    [[ "$OS_ID" == "ubuntu" && "$ubuntu_major" =~ ^[0-9]+$ && "$ubuntu_major" -ge 24 ]]
}

switch_ssh_to_service() {
    local mask_generator="${1:-0}"
    local generator_target=""

    if [[ "$mask_generator" == "1" ]]; then
        if [[ -e "$SSH_SOCKET_GENERATOR_MASK" || -L "$SSH_SOCKET_GENERATOR_MASK" ]]; then
            if [[ ! -L "$SSH_SOCKET_GENERATOR_MASK" ]]; then
                error "$SSH_SOCKET_GENERATOR_MASK 已存在且不是官方 /dev/null 屏蔽链接，无法安全切换 SSH 模式。"
                return 1
            fi
            generator_target=$(readlink -f "$SSH_SOCKET_GENERATOR_MASK" 2>/dev/null || true)
            if [[ "$generator_target" != "/dev/null" ]]; then
                error "$SSH_SOCKET_GENERATOR_MASK 指向未知目标，无法安全切换 SSH 模式。"
                return 1
            fi
        else
            mkdir -p "$(dirname "$SSH_SOCKET_GENERATOR_MASK")" || return 1
            ln -s /dev/null "$SSH_SOCKET_GENERATOR_MASK" || return 1
        fi
        rm -f -- "$SSH_SOCKET_SERVICE_DROPIN" "$SSH_SOCKET_ADDRESS_DROPIN" || return 1
    fi
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    if ssh_unit_exists ssh.socket; then
        systemctl disable --now ssh.socket >/dev/null 2>&1 || return 1
    fi
    systemctl unmask ssh.service >/dev/null 2>&1 || return 1
    systemctl enable ssh.service >/dev/null 2>&1 || return 1
    systemctl restart ssh.service >/dev/null 2>&1
}

restart_ssh() {
    local expected_port="${1:-}"
    local expected_ports
    local listening_ports
    local mask_generator=0
    local socket_state
    local socket_enabled

    expected_ports="$expected_port"
    [[ -n "$expected_ports" ]] || expected_ports=$(get_configured_ssh_ports)
    [[ -n "$expected_ports" ]] || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    if ssh_unit_exists ssh.socket; then
        socket_state=$(systemctl is-active ssh.socket 2>/dev/null || true)
        socket_enabled=$(systemctl is-enabled ssh.socket 2>/dev/null || true)
        ssh_uses_ubuntu_socket_generator && mask_generator=1
        if [[ "$socket_state" == "active" || "$socket_enabled" == "enabled" || \
              "$socket_enabled" == "enabled-runtime" ]]; then
            if [[ "$mask_generator" == "1" ]] && \
               systemctl restart ssh.socket >/dev/null 2>&1; then
                sleep 1
                listening_ports=$(get_listening_ssh_ports)
                if [[ "$listening_ports" == "$expected_ports" ]] && \
                   ssh_ports_accept_loopback "$expected_ports"; then
                    SSH_RUNTIME_MODE="socket"
                    detail "SSH" "RESTART" "Ubuntu ssh.socket 已按 sshd 配置重新生成并验证；端口=$expected_ports"
                    return 0
                fi
            fi
            if [[ "$mask_generator" == "1" ]]; then
                warn "ssh.socket 未能按目标配置重新监听，将按 Ubuntu 官方回退流程切换到 ssh.service。"
            else
                warn "检测到 ssh.socket；该模式不会自动采用 sshd_config 的端口，将按发行版官方流程切换到 ssh.service。"
            fi
        else
            mask_generator=0
        fi
        if [[ "$socket_state" == "active" || "$socket_enabled" == "enabled" || \
              "$socket_enabled" == "enabled-runtime" ]] && \
           switch_ssh_to_service "$mask_generator"; then
            sleep 1
            listening_ports=$(get_listening_ssh_ports)
            [[ "$listening_ports" == "$expected_ports" ]] || return 1
            ssh_ports_accept_loopback "$expected_ports" || return 1
            SSH_RUNTIME_MODE="service"
            detail "SSH" "RESTART" "已禁用 ssh.socket 并切换到 ssh.service；Ubuntu generator 屏蔽=$mask_generator"
            return 0
        fi
        if [[ "$socket_state" == "active" || "$socket_enabled" == "enabled" || \
              "$socket_enabled" == "enabled-runtime" ]]; then
            return 1
        fi
    fi

    SSH_RUNTIME_MODE="service"
    if ! systemctl restart ssh.service >/dev/null 2>&1 && \
       ! systemctl restart ssh >/dev/null 2>&1 && \
       ! systemctl restart sshd >/dev/null 2>&1; then
        return 1
    fi
    sleep 1
    listening_ports=$(get_listening_ssh_ports)
    [[ "$listening_ports" == "$expected_ports" ]] && \
        ssh_ports_accept_loopback "$expected_ports"
}

begin_swap_transaction() {
    SWAP_BACKUP_PATH="$BACKUP_DIR/swap-$(date +%Y%m%d%H%M%S)-$$"
    SWAP_SYSCTL_EXISTED=0
    SWAP_PREVIOUS_SWAPPINESS=$(sysctl -n vm.swappiness 2>/dev/null)

    if [[ ! -f /etc/fstab || -L /etc/fstab ]]; then
        error "/etc/fstab 不是可安全替换的普通文件，已停止 SWAP 操作。"
        return 1
    fi
    prepare_backup_path "$SWAP_BACKUP_PATH" || return 1
    mkdir -p "$(dirname "$SWAP_SYSCTL_FILE")" || return 1
    cp -a /etc/fstab "$SWAP_BACKUP_PATH/fstab" || return 1
    if [[ -e "$SWAP_SYSCTL_FILE" || -L "$SWAP_SYSCTL_FILE" ]]; then
        if [[ -L "$SWAP_SYSCTL_FILE" || ! -f "$SWAP_SYSCTL_FILE" ]]; then
            error "$SWAP_SYSCTL_FILE 不是可安全替换的普通文件，已停止操作。"
            return 1
        fi
        SWAP_SYSCTL_EXISTED=1
        cp -a "$SWAP_SYSCTL_FILE" "$SWAP_BACKUP_PATH/swappiness.conf" || return 1
    fi
    detail "SWAP" "BACKUP" "备份=$SWAP_BACKUP_PATH；文件=$MANAGED_SWAP_FILE；活动=$(swapon --show=NAME --noheadings --raw 2>/dev/null | grep -Fxq "$MANAGED_SWAP_FILE" && printf 是 || printf 否)；原 swappiness=${SWAP_PREVIOUS_SWAPPINESS:-未知}；托管配置原先存在=$SWAP_SYSCTL_EXISTED"
}

restore_swap_persistence() {
    local failed=0

    cp -a "$SWAP_BACKUP_PATH/fstab" /etc/fstab || failed=1
    if [[ "$SWAP_SYSCTL_EXISTED" == "1" ]]; then
        cp -a "$SWAP_BACKUP_PATH/swappiness.conf" "$SWAP_SYSCTL_FILE" || failed=1
    else
        rm -f "$SWAP_SYSCTL_FILE" || failed=1
    fi
    systemctl daemon-reload >/dev/null 2>&1 || failed=1
    if [[ -n "$SWAP_PREVIOUS_SWAPPINESS" ]]; then
        sysctl -w "vm.swappiness=$SWAP_PREVIOUS_SWAPPINESS" >/dev/null 2>&1 || failed=1
        [[ "$(sysctl -n vm.swappiness 2>/dev/null)" == "$SWAP_PREVIOUS_SWAPPINESS" ]] || failed=1
    fi
    return "$failed"
}

create_swap_backing_file() {
    local count_val="$1"
    local filesystem_type

    SWAP_BACKING_FORMATTED=0

    filesystem_type=$(findmnt -n -o FSTYPE -T "$(dirname "$MANAGED_SWAP_FILE")" 2>/dev/null)
    [[ -n "$filesystem_type" ]] || {
        error "无法识别 SWAP 所在文件系统，已停止创建。"
        return 1
    }
    case "$filesystem_type" in
        nfs|nfs4|cifs|smb3|9p|overlay|tmpfs|ramfs|squashfs|iso9660|zfs)
            error "$filesystem_type 文件系统不适合由本脚本创建 SWAP 文件。"
            return 1
            ;;
    esac

    if [[ "$filesystem_type" == "btrfs" ]]; then
        if command -v btrfs >/dev/null 2>&1 && \
           btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
            if ! btrfs filesystem mkswapfile --size "${count_val}M" "$MANAGED_SWAP_FILE"; then
                error "Btrfs 官方 mkswapfile 命令未能创建可用的 SWAP 文件。"
                return 1
            fi
            chmod 600 "$MANAGED_SWAP_FILE" || return 1
            if btrfs inspect-internal map-swapfile --help >/dev/null 2>&1 && \
               ! btrfs inspect-internal map-swapfile "$MANAGED_SWAP_FILE" >/dev/null 2>&1; then
                error "Btrfs SWAP 文件映射验证失败。"
                return 1
            fi
            SWAP_BACKING_FORMATTED=1
            detail "SWAP" "CREATE_FILE" "文件系统=btrfs；使用 btrfs filesystem mkswapfile 创建并格式化"
            return 0
        fi
        if ! command -v chattr >/dev/null 2>&1 || ! command -v lsattr >/dev/null 2>&1; then
            error "Btrfs SWAP 需要 chattr 与 lsattr 来设置并验证 NOCOW 属性。"
            return 1
        fi
        : > "$MANAGED_SWAP_FILE" || return 1
        chmod 600 "$MANAGED_SWAP_FILE" || return 1
        if ! chattr +C "$MANAGED_SWAP_FILE" >/dev/null 2>&1 || \
           ! lsattr -d "$MANAGED_SWAP_FILE" 2>/dev/null | awk '{print $1}' | grep -q C; then
            error "无法为 Btrfs SWAP 文件设置 NOCOW 属性。"
            return 1
        fi
        detail "SWAP" "CREATE_FILE" "文件系统=btrfs；mkswapfile 不可用，已在写入数据前设置并验证 NOCOW"
    else
        detail "SWAP" "CREATE_FILE" "文件系统=$filesystem_type；使用 dd 创建无稀疏区文件"
    fi

    dd if=/dev/zero of="$MANAGED_SWAP_FILE" bs=1M count="$count_val" \
        status=progress conv=fsync
}

rollback_swap_creation() {
    local failed=0
    local can_remove=1

    detail "SWAP" "ROLLBACK_CREATE" "开始回滚未完成的 SWAP 创建；文件=$MANAGED_SWAP_FILE；备份=$SWAP_BACKUP_PATH"

    if swapon --show=NAME --noheadings --raw 2>/dev/null | grep -Fxq "$MANAGED_SWAP_FILE"; then
        if ! swapoff "$MANAGED_SWAP_FILE" >/dev/null 2>&1; then
            failed=1
            can_remove=0
        fi
    fi
    if [[ "$can_remove" == "1" && -e "$MANAGED_SWAP_FILE" ]] && \
       ! rm -f "$MANAGED_SWAP_FILE" >/dev/null 2>&1; then
        failed=1
    fi
    restore_swap_persistence || failed=1
    if [[ "$failed" == "1" ]]; then
        detail "SWAP" "ROLLBACK_CREATE" "自动恢复不完整；文件存在=$([[ -e "$MANAGED_SWAP_FILE" ]] && printf 是 || printf 否)；备份=$SWAP_BACKUP_PATH"
        error "SWAP 自动回滚未完全成功，请从 $SWAP_BACKUP_PATH 手动恢复。"
        return 1
    fi
    detail "SWAP" "ROLLBACK_CREATE" "fstab、swappiness 和托管 SWAP 文件恢复成功"
    warn "未完成的 SWAP 创建已回滚，fstab、swappiness 与 /swapfile 已恢复。"
    return 0
}

rollback_swap_removal() {
    local was_active="$1"
    local failed=0

    detail "SWAP" "ROLLBACK_REMOVE" "开始恢复 SWAP 删除操作；原活动=$was_active；备份=$SWAP_BACKUP_PATH"

    restore_swap_persistence || failed=1
    if [[ "$was_active" == "1" ]] && \
       ! swapon --show=NAME --noheadings --raw 2>/dev/null | grep -Fxq "$MANAGED_SWAP_FILE"; then
        swapon "$MANAGED_SWAP_FILE" >/dev/null 2>&1 || failed=1
    fi
    if [[ "$failed" == "0" ]]; then
        detail "SWAP" "ROLLBACK_REMOVE" "fstab、swappiness 和运行状态恢复成功"
    else
        detail "SWAP" "ROLLBACK_REMOVE" "自动恢复不完整；备份=$SWAP_BACKUP_PATH"
    fi
    return "$failed"
}

remove_managed_swappiness() {
    local marker_value=""
    local restore_value=""
    local legacy_value=""
    local temp_file=""

    if [[ -f "$SWAP_SYSCTL_FILE" ]]; then
        marker_value=$(awk -F= '/^[[:space:]]*#[[:space:]]*vps-init-previous-vm-swappiness[[:space:]]*=/ {
            value=$2; gsub(/[[:space:]]/, "", value); saved=value
        } END {print saved}' "$SWAP_SYSCTL_FILE")
        if [[ -z "$marker_value" ]]; then
            SWAP_RESTORED_SWAPPINESS=$(sysctl -n vm.swappiness 2>/dev/null || printf 系统值)
            detail "SWAP" "PRESERVE_SWAPPINESS" \
                "$SWAP_SYSCTL_FILE 没有 vps-init 管理标记，未修改该文件或运行值"
            return 0
        fi
        if [[ ! "$marker_value" =~ ^[0-9]+$ ]]; then
            error "$SWAP_SYSCTL_FILE 中的 vps-init swappiness 恢复标记无效，已停止删除。"
            return 1
        fi
        temp_file=$(mktemp "$(dirname "$SWAP_SYSCTL_FILE")/.vps-init-sysctl.XXXXXX") || return 1
        if ! cp -a -- "$SWAP_SYSCTL_FILE" "$temp_file" || \
           ! sed -i -E \
               -e '/^[[:space:]]*#[[:space:]]*vps-init-previous-vm-swappiness[[:space:]]*=/d' \
               -e '\|^[[:space:]]*-?[[:space:]]*vm[./]swappiness[[:space:]]*=|d' \
               "$temp_file"; then
            rm -f -- "$temp_file"
            return 1
        fi
        if grep -qE '[^[:space:]]' "$temp_file"; then
            mv -f -- "$temp_file" "$SWAP_SYSCTL_FILE" || {
                rm -f -- "$temp_file"
                return 1
            }
        else
            rm -f -- "$SWAP_SYSCTL_FILE" "$temp_file" || return 1
        fi
    fi

    restore_value=$(get_effective_sysctl_value vm.swappiness)
    if [[ ! "$restore_value" =~ ^[0-9]+$ ]]; then
        legacy_value=$(get_sysctl_value_from_file /etc/sysctl.conf vm.swappiness)
        [[ "$legacy_value" =~ ^[0-9]+$ ]] && restore_value="$legacy_value"
    fi
    if [[ ! "$restore_value" =~ ^[0-9]+$ && "$marker_value" =~ ^[0-9]+$ ]]; then
        restore_value="$marker_value"
    fi
    [[ "$restore_value" =~ ^[0-9]+$ ]] || restore_value=60

    if ! sysctl -w "vm.swappiness=$restore_value" >/dev/null 2>&1 || \
       [[ "$(sysctl -n vm.swappiness 2>/dev/null)" != "$restore_value" ]]; then
        return 1
    fi
    SWAP_RESTORED_SWAPPINESS="$restore_value"
}

swap_memory_headroom_bytes() {
    local total_bytes="$1"
    local headroom=$((64 * 1024 * 1024))
    local proportional

    [[ "$total_bytes" =~ ^[0-9]+$ ]] || total_bytes=0
    proportional=$((total_bytes / 10))
    (( proportional > headroom )) && headroom="$proportional"
    printf '%s' "$headroom"
}

swap_creation_capacity_is_safe() {
    local available_bytes="$1"
    local expected_bytes="$2"
    local headroom=$((256 * 1024 * 1024))

    [[ "$available_bytes" =~ ^[0-9]+$ ]] || return 1
    [[ "$expected_bytes" =~ ^[0-9]+$ ]] || return 1
    (( available_bytes >= expected_bytes + headroom ))
}

managed_swap_fstab_entry_exists() {
    awk -v path="$MANAGED_SWAP_FILE" '
        /^[[:space:]]*#/ {next}
        $1 == path && $3 == "swap" && tolower($0) ~ /managed by vps-init/ {
            found=1
        }
        END {exit !found}
    ' /etc/fstab
}

ensure_text_file_ends_with_newline() {
    local file="$1"

    [[ -f "$file" && ! -L "$file" ]] || return 1
    if [[ -s "$file" ]] && (( $(tail -c 1 -- "$file" | wc -l) == 0 )); then
        printf '\n' >> "$file" || return 1
    fi
}

swap_removal_capacity_is_safe() {
    local available_bytes="$1"
    local used_swap_bytes="$2"
    local total_bytes="$3"
    local headroom

    [[ "$available_bytes" =~ ^[0-9]+$ ]] || return 1
    [[ "$used_swap_bytes" =~ ^[0-9]+$ ]] || return 1
    [[ "$total_bytes" =~ ^[0-9]+$ ]] || return 1
    (( used_swap_bytes == 0 )) && return 0
    headroom=$(swap_memory_headroom_bytes "$total_bytes")
    (( available_bytes >= used_swap_bytes + headroom ))
}

preflight_swap_creation() {
    local expected_bytes="$1"
    local available_bytes
    local headroom=$((256 * 1024 * 1024))
    local required_bytes=$((expected_bytes + headroom))

    available_bytes=$(df -B1 --output=avail "$(dirname "$MANAGED_SWAP_FILE")" 2>/dev/null |
        awk 'NR==2 {gsub(/[[:space:]]/, ""); print $1}')
    if [[ ! "$available_bytes" =~ ^[0-9]+$ ]]; then
        error "无法读取 SWAP 所在文件系统的可用空间，已停止创建。"
        return 1
    fi
    if ! swap_creation_capacity_is_safe "$available_bytes" "$expected_bytes"; then
        error "磁盘可用空间不足：需要至少 $(format_bytes "$required_bytes")（包含 256MiB 安全余量），当前仅 $(format_bytes "$available_bytes")。"
        return 1
    fi
    echo "磁盘预检：可用 $(format_bytes "$available_bytes")；创建后至少保留 256MiB 安全余量。"
}

system_has_any_swap_configuration() {
    local fstab_file="${1:-/etc/fstab}"

    if swapon --show=NAME --noheadings --raw 2>/dev/null | grep -q '[^[:space:]]'; then
        return 0
    fi
    [[ -f "$fstab_file" ]] || return 1
    awk '
        /^[[:space:]]*#/ {next}
        NF >= 3 && $3 == "swap" {found=1; exit}
        END {exit(found ? 0 : 1)}
    ' "$fstab_file"
}

preflight_swap_removal() {
    local available_bytes
    local total_bytes
    local used_swap_bytes
    local headroom

    available_bytes=$(awk '/^MemAvailable:/ {printf "%.0f\n", $2 * 1024; exit}' /proc/meminfo)
    total_bytes=$(awk '/^MemTotal:/ {printf "%.0f\n", $2 * 1024; exit}' /proc/meminfo)
    used_swap_bytes=$(swapon --show=NAME,USED --bytes --noheadings --raw 2>/dev/null |
        awk -v path="$MANAGED_SWAP_FILE" '$1==path {sum+=$2} END {printf "%.0f\n", sum+0}')
    if [[ ! "$available_bytes" =~ ^[0-9]+$ || ! "$total_bytes" =~ ^[0-9]+$ || \
          ! "$used_swap_bytes" =~ ^[0-9]+$ ]]; then
        error "无法读取内存或 SWAP 使用量，已停止删除。"
        return 1
    fi
    headroom=$(swap_memory_headroom_bytes "$total_bytes")
    echo "内存预检：可用 $(format_bytes "$available_bytes")；该 SWAP 已用 $(format_bytes "$used_swap_bytes")；安全余量 $(format_bytes "$headroom")。"
    if ! swap_removal_capacity_is_safe "$available_bytes" "$used_swap_bytes" "$total_bytes"; then
        error "可用内存不足以安全卸载 $MANAGED_SWAP_FILE，已停止删除；请先释放内存或降低 SWAP 使用量。"
        return 1
    fi
}

create_managed_swap() {
    local swap_size="$1"
    local expected_bytes
    local count_val
    local actual_bytes
    local fstab_temp
    local number
    local unit

    [[ "$swap_size" =~ ^[1-9][0-9]*[MGmg]$ ]] || {
        error "SWAP 大小格式无效。"
        return 1
    }
    if system_has_any_swap_configuration; then
        error "检测到已存在活动或持久化 SWAP 配置，脚本不会叠加或覆盖。"
        return 1
    fi
    number="${swap_size//[^0-9]/}"
    unit="${swap_size//[0-9]/}"
    if (( ${#number} > 7 )) || \
       { [[ "${unit^^}" == "G" ]] && (( 10#$number > 1024 )); } || \
       { [[ "${unit^^}" == "M" ]] && (( 10#$number > 1048576 )); }; then
        error "SWAP 大小不能超过 1TiB。"
        return 1
    fi

    if command -v numfmt >/dev/null 2>&1; then
        expected_bytes=$(numfmt --from=iec "$swap_size" 2>/dev/null) || return 1
    else
        if [[ "${unit^^}" == "G" ]]; then
            expected_bytes=$((10#$number * 1024 * 1024 * 1024))
        else
            expected_bytes=$((10#$number * 1024 * 1024))
        fi
    fi
    if [[ ! "$expected_bytes" =~ ^[0-9]+$ ]] || \
       (( expected_bytes <= 0 || expected_bytes > 1099511627776 )); then
        error "SWAP 大小必须在 1MiB 到 1TiB 之间。"
        return 1
    fi
    count_val=$((expected_bytes / 1048576))

    preflight_swap_creation "$expected_bytes" || return 1
    if [[ -e "$MANAGED_SWAP_FILE" || -L "$MANAGED_SWAP_FILE" ]]; then
        error "$MANAGED_SWAP_FILE 已存在，为避免覆盖未知文件已停止创建。"
        return 1
    fi

    if ! begin_swap_transaction; then
        error "无法完成 SWAP 配置备份，未创建文件。"
        return 1
    fi

    log "正在创建 $swap_size 的 SWAP 文件..."
    if ! create_swap_backing_file "$count_val"; then
        error "SWAP 文件创建失败。"
        rollback_swap_creation
        return 1
    fi

    actual_bytes=$(stat -c%s "$MANAGED_SWAP_FILE" 2>/dev/null)
    if [[ "$actual_bytes" != "$expected_bytes" ]]; then
        error "SWAP 文件大小校验失败：期望 $expected_bytes bytes，实际 ${actual_bytes:-未知}。"
        rollback_swap_creation
        return 1
    fi
    if ! chmod 600 "$MANAGED_SWAP_FILE" || \
       { [[ "$SWAP_BACKING_FORMATTED" == "1" ]] || mkswap "$MANAGED_SWAP_FILE" >/dev/null; } || \
       ! swapon "$MANAGED_SWAP_FILE"; then
        error "SWAP 初始化或启用失败。"
        rollback_swap_creation
        return 1
    fi

    fstab_temp=$(mktemp /etc/.vps-init-fstab.XXXXXX) || {
        rollback_swap_creation
        return 1
    }
    if ! cp -a /etc/fstab "$fstab_temp" || \
       ! ensure_text_file_ends_with_newline "$fstab_temp" || \
       ! printf '%s none swap sw 0 0 # managed by vps-init\n' "$MANAGED_SWAP_FILE" >> "$fstab_temp" || \
       ! mv -f "$fstab_temp" /etc/fstab; then
        rm -f "$fstab_temp"
        error "写入 /etc/fstab 失败。"
        rollback_swap_creation
        return 1
    fi
    if ! systemctl daemon-reload >/dev/null 2>&1; then
        error "fstab 已写入，但 systemd 配置重载失败。"
        rollback_swap_creation
        return 1
    fi

    if ! managed_swap_fstab_entry_exists || \
       ! swapon --show=NAME --noheadings --raw 2>/dev/null | grep -Fxq "$MANAGED_SWAP_FILE"; then
        error "SWAP 运行状态或 fstab 托管标记验证失败。"
        rollback_swap_creation
        return 1
    fi

    action_success "SWAP 创建" "$swap_size；保留 vm.swappiness=${SWAP_PREVIOUS_SWAPPINESS:-系统值}；运行状态和持久化验证通过；备份：$SWAP_BACKUP_PATH"
}

remove_managed_swap() {
    local was_active="$1"
    local fstab_temp

    if ! managed_swap_fstab_entry_exists; then
        error "未检测到 vps-init 的 fstab 托管标记，拒绝删除未知来源的 $MANAGED_SWAP_FILE。"
        return 1
    fi
    if [[ -L "$MANAGED_SWAP_FILE" ]] || \
       [[ -e "$MANAGED_SWAP_FILE" && ! -f "$MANAGED_SWAP_FILE" ]]; then
        error "$MANAGED_SWAP_FILE 不是脚本可安全删除的普通文件。"
        return 1
    fi
    preflight_swap_removal || return 1
    if ! begin_swap_transaction; then
        error "无法备份 SWAP 配置，未执行删除。"
        return 1
    fi
    log "正在删除脚本管理的 $MANAGED_SWAP_FILE ..."
    if [[ "$was_active" == "1" ]] && ! swapoff "$MANAGED_SWAP_FILE"; then
        error "$MANAGED_SWAP_FILE 卸载失败，未修改持久化配置。"
        return 1
    fi

    fstab_temp=$(mktemp /etc/.vps-init-fstab.XXXXXX) || {
        if rollback_swap_removal "$was_active"; then
            error "fstab 临时文件创建失败，SWAP 运行状态已恢复。"
        else
            error "fstab 临时文件创建失败且 SWAP 运行状态回滚不完整，请从 $SWAP_BACKUP_PATH 手动恢复。"
        fi
        return 1
    }
    if ! awk -v path="$MANAGED_SWAP_FILE" \
        '!($1==path && $3=="swap" && tolower($0) ~ /managed by vps-init/)' \
        /etc/fstab > "$fstab_temp" || \
       ! chmod --reference=/etc/fstab "$fstab_temp" || \
       ! chown --reference=/etc/fstab "$fstab_temp" || \
       ! mv -f "$fstab_temp" /etc/fstab; then
        rm -f "$fstab_temp"
        if rollback_swap_removal "$was_active"; then
            error "fstab 更新失败，原配置与 SWAP 运行状态已恢复。"
        else
            error "fstab 更新失败且自动回滚不完整，请从 $SWAP_BACKUP_PATH 手动恢复。"
        fi
        return 1
    fi
    if ! systemctl daemon-reload >/dev/null 2>&1; then
        if rollback_swap_removal "$was_active"; then
            error "systemd 配置重载失败，fstab 与 SWAP 运行状态已恢复。"
        else
            error "systemd 配置重载失败且自动回滚不完整，请从 $SWAP_BACKUP_PATH 手动恢复。"
        fi
        return 1
    fi

    SWAP_RESTORED_SWAPPINESS=""
    if ! remove_managed_swappiness; then
        if rollback_swap_removal "$was_active"; then
            error "vm.swappiness 持久化配置清理失败，fstab 与运行状态已恢复。"
        else
            error "vm.swappiness 清理失败且自动回滚不完整，请从 $SWAP_BACKUP_PATH 手动恢复。"
        fi
        return 1
    fi

    if [[ -f "$MANAGED_SWAP_FILE" ]] && ! rm -f "$MANAGED_SWAP_FILE"; then
        if rollback_swap_removal "$was_active"; then
            error "SWAP 文件删除失败，fstab 与运行状态已恢复。"
        else
            error "SWAP 文件删除失败且自动回滚不完整，请从 $SWAP_BACKUP_PATH 手动恢复。"
        fi
        return 1
    fi

    if managed_swap_fstab_entry_exists || \
       swapon --show=NAME --noheadings --raw 2>/dev/null | grep -Fxq "$MANAGED_SWAP_FILE" || \
       [[ -e "$MANAGED_SWAP_FILE" || -L "$MANAGED_SWAP_FILE" ]]; then
        error "SWAP 删除后的状态验证失败，请根据备份 $SWAP_BACKUP_PATH 检查配置。"
        return 1
    fi

    action_success "SWAP 删除" "仅删除 $MANAGED_SWAP_FILE；vm.swappiness=${SWAP_RESTORED_SWAPPINESS:-系统值}；备份：$SWAP_BACKUP_PATH"
}

# ==========================================
# 模块一：SWAP 配置
# ==========================================
submenu_swap() {
    require_commands "SWAP 配置" swapon swapoff mkswap stat dd findmnt systemctl mktemp awk sed sysctl find readlink sort || { pause_menu; return; }
    while true; do
        print_header "SWAP 配置"
        echo "当前状态："
        if swapon --show | grep -q "."; then
            swapon --show | awk 'NR>1 {print " - 路径: "$1" | 大小: "$3" | 已用: "$4}'
            echo " - 合计：$(free -h | awk '/^Swap/{print $2" 总 / "$3" 已用"}')"
        else
            echo -e "${YELLOW} - 未配置任何 SWAP${NC}"
        fi
        echo -e "${DIM}--------------------------------------------------${NC}"
        print_menu_item 1 "快速添加 1GB SWAP"
        print_menu_item 2 "快速添加 2GB SWAP"
        print_menu_item 3 "手动输入 SWAP 大小" "支持 MB/GB"
        echo -e "  ${RED}4. [需确认] 删除脚本管理的 /swapfile${NC}"
        echo -e "  ${DIM}0. 返回上一级${NC}"
        echo -e "${CYAN}==================================================${NC}"
        read -r -p "请输入选项 [0-4]: " choice_swap

        if [[ "$choice_swap" =~ ^[1-3]$ ]]; then
            if system_has_any_swap_configuration; then
                error "检测到已存在 SWAP 配置！请先确认现有配置，脚本不会覆盖。"
                pause_menu; continue
            fi
        fi

        case "$choice_swap" in
            1) swap_size="1G" ;;
            2) swap_size="2G" ;;
            3)
                read -r -p "请输入所需 SWAP 大小 (例如 512M 或 4G): " swap_size
                if [[ ! "$swap_size" =~ ^[1-9][0-9]*[MGmg]$ ]]; then
                    error "格式错误！请输入带有 M 或 G 单位的正整数。"
                    pause_menu; continue
                fi
                ;;
            4)
                SWAP_ACTIVE=0
                SWAP_CONFIGURED=0
                swapon --show=NAME --noheadings --raw 2>/dev/null | grep -Fxq "$MANAGED_SWAP_FILE" && SWAP_ACTIVE=1
                managed_swap_fstab_entry_exists && SWAP_CONFIGURED=1

                if [[ "$SWAP_CONFIGURED" == "0" ]]; then
                    error "未检测到带有 vps-init fstab 标记的 $MANAGED_SWAP_FILE；未知来源的 SWAP 不会被删除。"
                    pause_menu; continue
                fi
                if [[ -L "$MANAGED_SWAP_FILE" ]] || \
                   [[ -e "$MANAGED_SWAP_FILE" && ! -f "$MANAGED_SWAP_FILE" ]]; then
                    error "$MANAGED_SWAP_FILE 不是脚本可安全删除的普通文件，已停止操作。"
                    pause_menu; continue
                fi

                confirm_action "确认只卸载并删除 $MANAGED_SWAP_FILE 吗？其他 SWAP 将保留。" || continue
                remove_managed_swap "$SWAP_ACTIVE"
                pause_menu; continue
                ;;
            0) return ;;
            *) error "无效选项！"; sleep 1; continue ;;
        esac

        if [[ "$choice_swap" =~ ^[1-3]$ ]]; then
            if [[ -e "$MANAGED_SWAP_FILE" ]]; then
                error "$MANAGED_SWAP_FILE 已存在但未被识别为活动 SWAP，为避免覆盖未知文件已停止操作。"
                pause_menu; continue
            fi
            echo "将创建：$MANAGED_SWAP_FILE（$swap_size）；保留当前 vm.swappiness 不变。"
            confirm_action "确认创建并启用该 SWAP 吗？" || continue
            create_managed_swap "$swap_size"
            pause_menu
        fi
    done
}

# ==========================================
# 模块一：时间与时区配置
# ==========================================
wait_for_ntp_synchronization() {
    local timeout_seconds="${1:-15}"
    local elapsed=0

    while (( elapsed <= timeout_seconds )); do
        [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]] && return 0
        (( elapsed == timeout_seconds )) && break
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

select_time_sync_service() {
    local candidate_service
    local canonical_service
    local activity
    local enablement
    local -A seen_services=()
    local -a active_services=()
    local -a enabled_services=()
    local -a available_services=()
    local -a blocked_services=()
    local -a time_sync_candidates=(
        chrony.service
        ntpsec.service
        ntp.service
        systemd-timesyncd.service
    )

    TIME_SYNC_SERVICE=""
    TIME_SYNC_SERVICE_STATE=""
    TIME_SYNC_SELECTION_DETAIL=""

    for candidate_service in "${time_sync_candidates[@]}"; do
        systemctl cat "$candidate_service" >/dev/null 2>&1 || continue
        canonical_service=$(systemctl show -p Id --value "$candidate_service" 2>/dev/null || true)
        [[ "$canonical_service" == *.service ]] || canonical_service="$candidate_service"
        [[ -z "${seen_services[$canonical_service]:-}" ]] || continue
        seen_services["$canonical_service"]=1

        enablement=$(systemctl is-enabled "$canonical_service" 2>/dev/null || true)
        activity=$(systemctl is-active "$canonical_service" 2>/dev/null || true)
        if [[ "$activity" == "active" && "$enablement" == masked* ]]; then
            blocked_services+=("$canonical_service($enablement-active)")
        elif [[ "$activity" == "active" ]]; then
            active_services+=("$canonical_service")
        elif [[ "$enablement" == "enabled" || "$enablement" == "enabled-runtime" ]]; then
            enabled_services+=("$canonical_service")
        elif [[ "$enablement" == "disabled" || "$enablement" == "indirect" ]]; then
            available_services+=("$canonical_service")
        elif [[ "$enablement" != masked* ]]; then
            blocked_services+=("$canonical_service($enablement)")
        fi
    done

    TIME_SYNC_SELECTION_DETAIL="active=${active_services[*]:-none}; enabled=${enabled_services[*]:-none}; available=${available_services[*]:-none}; unsupported=${blocked_services[*]:-none}"
    if (( ${#active_services[@]} == 1 && ${#enabled_services[@]} > 0 )); then
        return 2
    elif (( ${#active_services[@]} == 1 )); then
        TIME_SYNC_SERVICE="${active_services[0]}"
        TIME_SYNC_SERVICE_STATE="active"
        return 0
    elif (( ${#active_services[@]} > 1 )); then
        return 2
    fi

    if (( ${#enabled_services[@]} == 1 )); then
        TIME_SYNC_SERVICE="${enabled_services[0]}"
        TIME_SYNC_SERVICE_STATE="enabled"
        return 0
    elif (( ${#enabled_services[@]} > 1 )); then
        return 2
    fi

    if (( ${#available_services[@]} == 1 && ${#blocked_services[@]} == 0 )); then
        TIME_SYNC_SERVICE="${available_services[0]}"
        TIME_SYNC_SERVICE_STATE="available"
        return 0
    elif (( ${#available_services[@]} > 1 || ${#blocked_services[@]} > 0 )); then
        return 2
    fi
    return 1
}

submenu_timezone() {
    local time_sync_service
    local time_sync_service_state
    local selection_status
    local ntp_synchronized
    local command_output
    local command_status

    require_commands "时区配置" timedatectl systemctl sleep || { pause_menu; return; }
    while true; do
        print_header "时间与时区配置"
        echo -e "当前时间：${YELLOW}$(date "+%Y-%m-%d %H:%M:%S %Z")${NC}"
        echo -e "${DIM}--------------------------------------------------${NC}"
        print_menu_item 1 "设置为 Asia/Shanghai" "北京时间"
        print_menu_item 2 "设置为 UTC" "协调世界时"
        print_menu_item 3 "手动输入目标时区" "例如 America/New_York"
        echo -e "  ${DIM}0. 返回上一级${NC}"
        echo -e "${CYAN}==================================================${NC}"
        read -r -p "请输入选项 [0-3]: " choice_tz

        case "$choice_tz" in
            1) target_tz="Asia/Shanghai" ;;
            2) target_tz="UTC" ;;
            3)
                read -r -p "请输入标准的时区代码 (注意大小写): " target_tz
                if [[ -z "$target_tz" ]]; then
                    error "时区不能为空！"
                    pause_menu; continue
                fi
                if ! timedatectl list-timezones | grep -qx "$target_tz"; then
                    error "无效的时区代码：$target_tz"
                    pause_menu; continue
                fi
                ;;
            0) return ;;
            *) error "无效选项！"; sleep 1; continue ;;
        esac

        echo "目标时区：$target_tz；同时确保已有时间同步服务正常运行。"
        confirm_action "确认应用该时间与时区配置吗？" || continue
        log "正在设置时区并检查时间同步服务：$target_tz ..."
        command_output=$(timedatectl set-timezone "$target_tz" 2>&1)
        command_status=$?

        if (( command_status != 0 )) || \
           [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" != "$target_tz" ]]; then
            detail "TIME" "SET_TIMEZONE" "目标=$target_tz；退出码=$command_status；输出=${command_output:-无}"
            error "时区设置失败！"
            pause_menu; continue
        fi

        select_time_sync_service
        selection_status=$?
        if (( selection_status == 2 )); then
            detail "TIME" "SELECT_SERVICE" "检测到多个或不可安全启用的时间同步服务；$TIME_SYNC_SELECTION_DETAIL"
            action_partial "时区配置" "时区已设置为 $target_tz，但时间同步服务状态存在冲突，未自动修改服务"
            warn "请先只保留一个明确的时间同步服务，再重新执行。"
            pause_menu; continue
        fi
        time_sync_service="$TIME_SYNC_SERVICE"
        time_sync_service_state="$TIME_SYNC_SERVICE_STATE"
        if (( selection_status == 1 )); then
            require_commands "时间同步服务安装" apt-get dpkg || {
                action_partial "时区配置" "时区已设置为 $target_tz，但无法安装时间同步服务"
                pause_menu; continue
            }
            package_manager_ready || {
                action_partial "时区配置" "时区已设置为 $target_tz，但软件包管理器不可用"
                pause_menu; continue
            }
            command_output=$(apt_update_strict 2>&1)
            command_status=$?
            if (( command_status != 0 )); then
                detail "TIME" "APT_UPDATE" "退出码=$command_status；输出=${command_output:-无}"
                action_partial "时区配置" "时区已设置为 $target_tz，但 systemd-timesyncd 安装失败"
                pause_menu; continue
            fi
            validate_official_package_install_plan \
                "时间同步服务" 0 systemd-timesyncd || {
                detail "TIME" "INSTALL_PREVIEW" "systemd-timesyncd 安装预览未通过无删除或官方来源边界"
                action_partial "时区配置" "时区已设置为 $target_tz，但 systemd-timesyncd 安装预览未通过"
                pause_menu; continue
            }
            command_output=$(apt-get install --no-remove -y -- systemd-timesyncd 2>&1)
            command_status=$?
            if (( command_status != 0 )) || \
               ! systemctl cat systemd-timesyncd.service >/dev/null 2>&1; then
                detail "TIME" "INSTALL_SERVICE" "退出码=$command_status；输出=${command_output:-无}；unit=$(systemctl cat systemd-timesyncd.service >/dev/null 2>&1 && printf 存在 || printf 不存在)"
                action_partial "时区配置" "时区已设置为 $target_tz，但 systemd-timesyncd 安装失败"
                pause_menu; continue
            fi
            time_sync_service="systemd-timesyncd.service"
            time_sync_service_state="available"
        fi

        command_output=""
        command_status=0
        if [[ "$time_sync_service_state" == "enabled" ]]; then
            command_output=$(systemctl start "$time_sync_service" 2>&1)
            command_status=$?
        elif [[ "$time_sync_service_state" == "available" && \
                "$time_sync_service" == "systemd-timesyncd.service" ]]; then
            command_output=$(timedatectl set-ntp true 2>&1)
            command_status=$?
        elif [[ "$time_sync_service_state" == "available" ]]; then
            command_output=$(systemctl enable --now "$time_sync_service" 2>&1)
            command_status=$?
        fi
        if (( command_status != 0 )) || \
           [[ "$(systemctl is-active "$time_sync_service" 2>/dev/null)" != "active" ]]; then
            detail "TIME" "START_SERVICE" "服务=$time_sync_service；选择状态=$time_sync_service_state；退出码=$command_status；输出=${command_output:-无}；状态=$(systemctl is-active "$time_sync_service" 2>/dev/null || printf 未知)"
            action_partial "时区配置" "时区已设置为 $target_tz，但 $time_sync_service 启用失败"
            pause_menu; continue
        fi

        if wait_for_ntp_synchronization 15; then
            ntp_synchronized=yes
        else
            ntp_synchronized=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
        fi
        detail "TIME" "VERIFY" "时区=$target_tz；同步服务=$time_sync_service；运行=$(systemctl is-active "$time_sync_service" 2>/dev/null || printf 未知)；NTPSynchronized=${ntp_synchronized:-未知}"
        if [[ "$ntp_synchronized" == "yes" ]]; then
            action_success "时区配置" "$target_tz；时间已同步；当前时间：$(date "+%Y-%m-%d %H:%M:%S %Z")"
        else
            action_partial "时区配置" "$target_tz；$time_sync_service 已运行，尚未确认完成同步"
            warn "请稍后使用 timedatectl status 复查同步状态。"
        fi
        pause_menu
    done
}

# ==========================================
# 模块一：系统清理辅助函数
# ==========================================
format_bytes() {
    local bytes="${1:-0}"

    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$bytes"
    else
        awk -v value="$bytes" 'BEGIN {
            split("B KiB MiB GiB TiB", units, " ")
            index=1
            while (value >= 1024 && index < 5) {
                value /= 1024
                index++
            }
            printf "%.1f%s", value, units[index]
        }'
    fi
}

get_path_size_bytes() {
    local target="$1"

    if [[ -e "$target" ]] && command -v du >/dev/null 2>&1; then
        du -sb -- "$target" 2>/dev/null | awk 'NR==1 {print $1+0}'
    else
        echo 0
    fi
}

get_root_used_bytes() {
    df -B1 --output=used / 2>/dev/null | awk 'NR==2 {gsub(/[[:space:]]/, ""); print $1+0}'
}

get_filesystem_used_bytes() {
    local target="$1"

    df -B1 --output=used -- "$target" 2>/dev/null |
        awk 'NR==2 {gsub(/[[:space:]]/, ""); print $1+0}'
}

get_kernel_storage_used_bytes() {
    local root_device=""
    local boot_device=""
    local root_used=0
    local boot_used=0

    root_used=$(get_filesystem_used_bytes /)
    [[ "$root_used" =~ ^[0-9]+$ ]] || root_used=0
    if [[ -d /boot ]]; then
        root_device=$(stat -c '%d' / 2>/dev/null || true)
        boot_device=$(stat -c '%d' /boot 2>/dev/null || true)
        if [[ -n "$root_device" && -n "$boot_device" && "$root_device" != "$boot_device" ]]; then
            boot_used=$(get_filesystem_used_bytes /boot)
            [[ "$boot_used" =~ ^[0-9]+$ ]] || boot_used=0
        fi
    fi
    printf '%s\n' "$((root_used + boot_used))"
}

show_released_space() {
    local before="$1"
    local after="$2"
    local released=0

    if [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ && "$before" -gt "$after" ]]; then
        released=$((before - after))
    fi
    echo -e "实际释放空间：${GREEN}$(format_bytes "$released")${NC}"
}

package_manager_ready() {
    local audit_output
    local lock_file
    local -a lock_files=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )

    require_commands "软件包管理" apt-get dpkg dpkg-query || return 1

    if command -v fuser >/dev/null 2>&1; then
        for lock_file in "${lock_files[@]}"; do
            if [[ -e "$lock_file" ]] && fuser "$lock_file" >/dev/null 2>&1; then
                error "检测到软件包管理器正在运行，请等待其结束后再试。"
                return 1
            fi
        done
    fi

    audit_output=$(dpkg --audit 2>/dev/null || true)
    if [[ -n "$audit_output" ]]; then
        error "检测到未完成的软件包配置，请先处理后再执行软件包操作："
        echo "$audit_output"
        return 1
    fi
}

apt_update_strict() {
    apt-get \
        -o Acquire::Retries=3 \
        -o APT::Update::Error-Mode=any \
        update
}

parse_apt_simulated_installs() {
    awk '$1 == "Inst" {print $2}'
}

parse_apt_simulated_install_versions() {
    awk '
        $1 == "Inst" {
            package=$2
            line=$0
            sub(/^Inst[[:space:]]+[^[:space:]]+[[:space:]]+/, "", line)
            sub(/^\[[^]]+\][[:space:]]+/, "", line)
            if (substr(line, 1, 1) != "(") next
            sub(/^\(/, "", line)
            version=line
            sub(/[[:space:]].*$/, "", version)
            sub(/\).*$/, "", version)
            if (package != "" && version != "") print package "\t" version
        }
    '
}

parse_apt_simulated_removals() {
    awk '$1 == "Remv" || $1 == "Purg" {print $2}'
}

validate_package_install_without_removals() {
    local label="$1"
    shift
    local simulation_output
    local -a removals=()

    if ! simulation_output=$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 \
        install --no-remove -- "$@" 2>&1); then
        error "$label 的安装预览失败，已停止操作："
        echo "$simulation_output"
        return 1
    fi
    mapfile -t removals < <(
        printf '%s\n' "$simulation_output" | parse_apt_simulated_removals
    )
    if (( ${#removals[@]} > 0 )); then
        error "$label 的安装预览会删除现有软件包，已停止自动安装："
        printf ' - %s\n' "${removals[@]}"
        return 1
    fi
}

validate_official_package_install_plan() {
    local label="$1"
    local allow_ubuntu_esm_apps="$2"
    shift 2
    local simulation_output
    local record
    local package
    local version
    local validated_count=0
    local -a removals=()
    local -a version_records=()
    local -A planned_versions=()

    [[ "$allow_ubuntu_esm_apps" == "0" || "$allow_ubuntu_esm_apps" == "1" ]] || return 2
    if ! simulation_output=$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 \
        install --no-remove -- "$@" 2>&1); then
        error "$label 的安装预览失败，已停止操作："
        echo "$simulation_output"
        return 1
    fi
    mapfile -t removals < <(
        printf '%s\n' "$simulation_output" | parse_apt_simulated_removals
    )
    if (( ${#removals[@]} > 0 )); then
        error "$label 的安装预览会删除现有软件包，已停止自动安装："
        printf ' - %s\n' "${removals[@]}"
        return 1
    fi
    mapfile -t version_records < <(
        printf '%s\n' "$simulation_output" | parse_apt_simulated_install_versions
    )
    for record in "${version_records[@]}"; do
        IFS=$'\t' read -r package version <<< "$record"
        [[ -n "$package" && -n "$version" ]] || continue
        planned_versions["$package"]="$version"
    done
    for package in "${!planned_versions[@]}"; do
        version="${planned_versions[$package]}"
        validate_official_candidate_source \
            "$package" "$version" "$allow_ubuntu_esm_apps" || {
            error "$label 的计划软件包不完全来自当前发行版的官方稳定更新范围。"
            return 1
        }
        ((validated_count += 1))
    done
    detail "UPDATE" "INSTALL_SOURCES" \
        "$label 已核验 $validated_count 个计划安装/升级软件包的发行方、版本代号与稳定更新 pocket"
}

package_is_installed() {
    local package="$1"

    [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null)" == ii* ]]
}

is_kernel_meta_package_name() {
    local package="${1%%:*}"

    case "$package" in
        *-dbg|*-dbgsym|*-signed-template)
            return 1
            ;;
        linux-image-[0-9]*|linux-image-unsigned-[0-9]*|linux-image-extra-[0-9]*|\
        linux-headers-[0-9]*|linux-modules-[0-9]*|linux-modules-extra-[0-9]*|\
        linux-tools-[0-9]*|linux-cloud-tools-[0-9]*)
            return 1
            ;;
    esac

    case "$OS_ID" in
        debian)
            [[ "$package" == linux-image-* ]]
            return
            ;;
        ubuntu)
            case "$package" in
                linux-image-generic*|linux-image-virtual*|linux-image-aws*|\
                linux-image-azure*|linux-image-gcp*|linux-image-oracle*|\
                linux-image-kvm*|linux-image-lowlatency*|linux-image-oem-*|\
                linux-generic|linux-generic-*|linux-virtual|linux-virtual-*|\
                linux-aws|linux-aws-*|linux-azure|linux-azure-*|linux-gcp|linux-gcp-*|\
                linux-oracle|linux-oracle-*|linux-kvm|linux-kvm-*|\
                linux-lowlatency|linux-lowlatency-*|linux-oem-*)
                    return 0
                    ;;
            esac
            ;;
    esac
    return 1
}

is_kernel_update_package() {
    local package="${1%%:*}"

    if is_versioned_kernel_package "$package" || \
       is_kernel_meta_package_name "$package" || \
       is_kernel_cleanup_meta_package "$package"; then
        return 0
    fi
    case "$package" in
        linux-base|linux-firmware*|linux-libc-dev|initramfs-tools*|dracut*|kmod|\
        busybox-initramfs|busybox-static|zstd|\
        amd64-microcode|intel-microcode)
            return 0
            ;;
    esac
    return 1
}

kernel_flavor_from_release() {
    local release="$1"

    case "$OS_ID" in
        debian)
            if [[ "$release" =~ \+deb[0-9]+-(.+)$ ]]; then
                printf '%s\n' "${BASH_REMATCH[1]}"
            elif [[ "$release" =~ ^[0-9].*-[0-9]+-(.+)$ ]]; then
                printf '%s\n' "${BASH_REMATCH[1]}"
            else
                return 1
            fi
            ;;
        ubuntu)
            case "$release" in
                *-generic) printf '%s\n' generic ;;
                *-lowlatency) printf '%s\n' lowlatency ;;
                *-aws) printf '%s\n' aws ;;
                *-azure) printf '%s\n' azure ;;
                *-gcp) printf '%s\n' gcp ;;
                *-oracle) printf '%s\n' oracle ;;
                *-kvm) printf '%s\n' kvm ;;
                *) return 1 ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

latest_installed_kernel_for_current_flavor() {
    local current_kernel="$1"
    shift
    local current_flavor
    local release
    local release_flavor
    local -a matching_releases=()

    current_flavor=$(kernel_flavor_from_release "$current_kernel") || return 1
    for release in "$@"; do
        release_flavor=$(kernel_flavor_from_release "$release" 2>/dev/null || true)
        [[ "$release_flavor" == "$current_flavor" ]] && matching_releases+=("$release")
    done
    (( ${#matching_releases[@]} > 0 )) || return 1
    printf '%s\n' "${matching_releases[@]}" | LC_ALL=C sort -Vu | tail -n 1
}

is_versioned_kernel_package() {
    local package="${1%%:*}"

    case "$package" in
        linux-image-[0-9]*|linux-image-unsigned-[0-9]*|linux-image-extra-[0-9]*|\
        linux-headers-[0-9]*|linux-modules-[0-9]*|linux-modules-extra-[0-9]*|\
        linux-tools-[0-9]*|linux-cloud-tools-[0-9]*|linux-restricted-modules-[0-9]*)
            return 0
            ;;
    esac
    return 1
}

is_kernel_autoremove_protected_package() {
    local package="${1%%:*}"

    is_kernel_update_package "$package"
}

parse_kernel_package_records() {
    awk '$2 ~ /^(ii|rc)/ {sub(/:.*/, "", $1); print $1 "\t" $2}'
}

kernel_versioned_package_matches_release_list() {
    local package="${1%%:*}"
    local release_array_name="$2"
    local suffix=""
    local shared_release=0
    local retained_release
    local -n release_list="$release_array_name"

    case "$package" in
        linux-image-unsigned-[0-9]*) suffix="${package#linux-image-unsigned-}" ;;
        linux-image-extra-[0-9]*) suffix="${package#linux-image-extra-}" ;;
        linux-image-[0-9]*) suffix="${package#linux-image-}" ;;
        linux-modules-extra-[0-9]*) suffix="${package#linux-modules-extra-}" ;;
        linux-modules-[0-9]*) suffix="${package#linux-modules-}" ;;
        linux-restricted-modules-[0-9]*) suffix="${package#linux-restricted-modules-}" ;;
        linux-headers-[0-9]*)
            suffix="${package#linux-headers-}"
            shared_release=1
            ;;
        linux-cloud-tools-[0-9]*)
            suffix="${package#linux-cloud-tools-}"
            shared_release=1
            ;;
        linux-tools-[0-9]*)
            suffix="${package#linux-tools-}"
            shared_release=1
            ;;
        *) return 1 ;;
    esac
    [[ "$shared_release" == "1" ]] && suffix="${suffix%-common}"
    for retained_release in "${release_list[@]}"; do
        [[ "$retained_release" == "$suffix" ]] && return 0
        if [[ "$shared_release" == "1" && "$retained_release" == "$suffix"-* ]]; then
            return 0
        fi
    done
    return 1
}

kernel_versioned_package_matches_retained_release() {
    kernel_versioned_package_matches_release_list "$1" RETAINED_KERNEL_RELEASES
}

kernel_meta_route_and_flavor() {
    local package="${1%%:*}"
    local route

    KERNEL_META_ROUTE=""
    KERNEL_META_FLAVOR=""
    KERNEL_META_PRIORITY=0
    is_kernel_meta_package_name "$package" || return 1

    if [[ "$OS_ID" == "debian" ]]; then
        route="${package#linux-image-}"
        KERNEL_META_ROUTE="$route"
        KERNEL_META_FLAVOR="$route"
        KERNEL_META_PRIORITY=1
        return 0
    fi

    if [[ "$package" == linux-image-* ]]; then
        route="${package#linux-image-}"
        KERNEL_META_PRIORITY=1
    else
        route="${package#linux-}"
        KERNEL_META_PRIORITY=2
    fi
    KERNEL_META_ROUTE="$route"
    case "$route" in
        generic*|virtual*|oem-*) KERNEL_META_FLAVOR="generic" ;;
        lowlatency*) KERNEL_META_FLAVOR="lowlatency" ;;
        aws*) KERNEL_META_FLAVOR="aws" ;;
        azure*) KERNEL_META_FLAVOR="azure" ;;
        gcp*) KERNEL_META_FLAVOR="gcp" ;;
        oracle*) KERNEL_META_FLAVOR="oracle" ;;
        kvm*) KERNEL_META_FLAVOR="kvm" ;;
        *) return 1 ;;
    esac
}

list_installed_kernel_root_meta_packages() {
    dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' 2>/dev/null |
        awk '$2 ~ /^ii/ {sub(/:.*/, "", $1); print $1}'
}

collect_compatible_kernel_meta_packages() {
    local current_kernel="$1"
    local current_flavor
    local package
    local route
    local priority
    local -A package_by_route=()
    local -A priority_by_route=()

    KERNEL_META_CANDIDATES=()
    current_flavor=$(kernel_flavor_from_release "$current_kernel") || return 1
    while IFS= read -r package; do
        [[ -n "$package" ]] || continue
        kernel_meta_route_and_flavor "$package" || continue
        [[ "$KERNEL_META_FLAVOR" == "$current_flavor" ]] || continue
        route="$KERNEL_META_ROUTE"
        priority="$KERNEL_META_PRIORITY"
        if [[ -z "${package_by_route[$route]:-}" ]] || \
           (( priority > ${priority_by_route[$route]:-0} )); then
            package_by_route["$route"]="$package"
            priority_by_route["$route"]="$priority"
        fi
    done < <(list_installed_kernel_root_meta_packages)

    if (( ${#package_by_route[@]} > 0 )); then
        mapfile -t KERNEL_META_CANDIDATES < <(
            for route in "${!package_by_route[@]}"; do
                printf '%s\n' "${package_by_route[$route]}"
            done | sort -V
        )
    fi
}

select_kernel_meta_package() {
    local current_kernel="$1"
    local action_label="${2:-内核更新}"
    local choice
    local index
    local package

    SELECTED_KERNEL_META=""
    if ! collect_compatible_kernel_meta_packages "$current_kernel"; then
        warn "无法识别当前内核 $current_kernel 的发行版内核类型，已停止自动更新。"
        return 1
    fi
    if (( ${#KERNEL_META_CANDIDATES[@]} == 0 )); then
        warn "未发现与当前内核类型匹配且已安装的内核元软件包，已停止自动更新。"
        return 1
    fi
    if (( ${#KERNEL_META_CANDIDATES[@]} == 1 )); then
        SELECTED_KERNEL_META="${KERNEL_META_CANDIDATES[0]}"
        return 0
    fi

    warn "检测到多条与当前内核类型兼容的更新路线，请明确选择一条："
    index=1
    for package in "${KERNEL_META_CANDIDATES[@]}"; do
        printf ' %d. %s（已安装 %s）\n' "$index" "$package" \
            "$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || echo 未知)"
        ((index++))
    done
    echo " 0. 取消"
    while true; do
        read -r -p "请选择内核更新路线 [0-${#KERNEL_META_CANDIDATES[@]}]: " choice
        if [[ "$choice" == "0" ]]; then
            print_result "$action_label" "已取消" "未做任何更改"
            return 0
        fi
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && \
           (( 10#$choice <= ${#KERNEL_META_CANDIDATES[@]} )); then
            SELECTED_KERNEL_META="${KERNEL_META_CANDIDATES[choice-1]}"
            return 0
        fi
        error "无效选择，请重新输入。"
    done
}

get_installed_package_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

get_candidate_package_version() {
    LC_ALL=C apt-cache policy "$1" 2>/dev/null |
        awk '/^[[:space:]]*Candidate:/ {print $2; exit}'
}

kernel_source_record_allowed() {
    local record="$1"
    local allow_ubuntu_esm_apps="${2:-0}"
    local codename="$OS_CODENAME"
    local source_record="${record%%$'\t'*}"
    local metadata="${record#*$'\t'}"
    local release_record="${metadata%%$'\t'*}"
    local release_csv
    local pocket=""

    [[ "$codename" =~ ^[a-z0-9]+$ ]] || return 1
    [[ "$record" == *$'\t'* && "$metadata" == *$'\t'* ]] || return 1
    release_record="${release_record#release }"
    release_csv=",${release_record},"
    case "$OS_ID" in
        debian)
            [[ "$release_csv" == *,o=Debian,* ]] || return 1
            case "$release_csv" in
                *,c=main,*|*,c=contrib,*|*,c=non-free,*|*,c=non-free-firmware,*) ;;
                *) return 1 ;;
            esac
            case " $source_record " in
                *" $codename/"*|*" stable/"*|*" oldstable/"*) pocket="$codename" ;;
                *" ${codename}-updates/"*|*" stable-updates/"*|*" oldstable-updates/"*) pocket="${codename}-updates" ;;
                *" ${codename}-security/"*|*" stable-security/"*|*" oldstable-security/"*) pocket="${codename}-security" ;;
                *) return 1 ;;
            esac
            if [[ "$release_csv" != *,n="$pocket",* ]] && \
               ! [[ "$pocket" == "$codename" && "$release_csv" == *,n="$codename",* ]]; then
                return 1
            fi
            ;;
        ubuntu)
            case "$release_csv" in
                *,c=main,*|*,c=restricted,*|*,c=universe,*|*,c=multiverse,*) ;;
                *) return 1 ;;
            esac
            case " $source_record " in
                *" $codename/"*) pocket="$codename" ;;
                *" ${codename}-updates/"*) pocket="${codename}-updates" ;;
                *" ${codename}-security/"*) pocket="${codename}-security" ;;
                *" ${codename}-infra-security/"*) pocket="${codename}-infra-security" ;;
                *" ${codename}-infra-updates/"*) pocket="${codename}-infra-updates" ;;
                *" ${codename}-apps-security/"*) pocket="${codename}-apps-security" ;;
                *" ${codename}-apps-updates/"*) pocket="${codename}-apps-updates" ;;
                *) return 1 ;;
            esac
            case "$pocket" in
                "$codename"|"${codename}-updates"|"${codename}-security")
                    [[ "$release_csv" == *,o=Ubuntu,* ]] || return 1
                    ;;
                "${codename}-infra-security"|"${codename}-infra-updates")
                    [[ "$release_csv" == *,o=UbuntuESM,* ]] || return 1
                    ;;
                "${codename}-apps-security"|"${codename}-apps-updates")
                    [[ "$allow_ubuntu_esm_apps" == "1" ]] || return 1
                    [[ "$release_csv" == *,o=UbuntuESM,* ]] || return 1
                    ;;
            esac
            [[ "$release_csv" == *,n="$codename",* || "$release_csv" == *,n="$pocket",* ]] || return 1
            if [[ "$release_csv" != *,a="$pocket",* ]] && \
               ! [[ "$pocket" == "$codename" && "$release_csv" == *,a="$codename",* ]]; then
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
    return 0
}

list_apt_policy_source_records() {
    LC_ALL=C apt-cache policy 2>/dev/null | awk '
        function emit() {
            if (source != "") print source "\t" release "\t" origin
        }
        /^[[:space:]]*[0-9]+[[:space:]]+/ {
            emit()
            source=$0
            sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", source)
            release=""
            origin=""
            next
        }
        source != "" && /^[[:space:]]*release[[:space:]]+/ {
            release=$0
            sub(/^[[:space:]]*/, "", release)
            next
        }
        source != "" && /^[[:space:]]*origin[[:space:]]+/ {
            origin=$0
            sub(/^[[:space:]]*/, "", origin)
            next
        }
        END { emit() }
    '
}

list_package_version_sources() {
    local package="$1"
    local version="$2"
    local candidate_source
    local policy_source
    local policy_release
    local policy_origin
    local matched
    local record
    local -a candidate_sources=()
    local -a policy_records=()

    mapfile -t candidate_sources < <(LC_ALL=C apt-cache madison "$package" 2>/dev/null |
        awk -F'|' -v expected="$version" '
            {
                candidate=$2
                source=$3
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", candidate)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", source)
                if (candidate == expected) print source
            }
        ')
    mapfile -t policy_records < <(list_apt_policy_source_records)

    for candidate_source in "${candidate_sources[@]}"; do
        matched=0
        for record in "${policy_records[@]}"; do
            IFS=$'\t' read -r policy_source policy_release policy_origin <<< "$record"
            [[ "$policy_source" == "$candidate_source" ]] || continue
            printf '%s\t%s\t%s\n' "$candidate_source" "$policy_release" "$policy_origin"
            matched=1
        done
        if [[ "$matched" == "0" ]]; then
            printf '%s\t\t\n' "$candidate_source"
        fi
    done
}

validate_official_candidate_source() {
    local package="$1"
    local version="$2"
    local allow_ubuntu_esm_apps="${3:-0}"
    local record
    local allowed_record=""
    local rejected=0
    local -a records=()

    mapfile -t records < <(list_package_version_sources "$package" "$version")
    for record in "${records[@]}"; do
        if kernel_source_record_allowed "$record" "$allow_ubuntu_esm_apps"; then
            [[ -n "$allowed_record" ]] || allowed_record="$record"
        else
            rejected=1
        fi
    done
    if [[ -z "$allowed_record" || "$rejected" == "1" ]]; then
        error "$package 候选版本 $version 的全部可用来源未同时通过发行方、版本代号与稳定更新 pocket 校验，已停止操作。"
        if (( ${#records[@]} > 0 )); then
            for record in "${records[@]}"; do
                printf ' - %s\n' "$(sanitize_log_message "$record")"
            done
        else
            echo " - 未找到可核验的软件包来源"
        fi
        return 1
    fi
    VALIDATED_PACKAGE_SOURCE=$(tr '\t' ' ' <<< "$allowed_record")
}

parse_candidate_kernel_image_dependencies() {
    awk '
        {
            line=$0
            sub(/^[[:space:]|]*/, "", line)
            if (line !~ /^(Pre)?Depends:[[:space:]]+/) next
            sub(/^(Pre)?Depends:[[:space:]]+/, "", line)
            gsub(/[<>]/, "", line)
            sub(/:.*/, "", line)
            if (line ~ /^linux-image-(unsigned-)?[0-9]/) print line
        }
    '
}

collect_candidate_kernel_images() {
    local meta_package="$1"

    CANDIDATE_KERNEL_IMAGES=()
    mapfile -t CANDIDATE_KERNEL_IMAGES < <(
        LC_ALL=C apt-cache depends --recurse --important "$meta_package" 2>/dev/null |
            parse_candidate_kernel_image_dependencies |
            sort -u
    )
    if (( ${#CANDIDATE_KERNEL_IMAGES[@]} == 0 )); then
        error "无法从 $meta_package 的候选依赖中解析具体内核映像软件包，已停止操作。"
        return 1
    fi
}

kernel_release_from_image_package() {
    local package="${1%%:*}"

    package="${package#linux-image-unsigned-}"
    package="${package#linux-image-}"
    printf '%s\n' "$package"
}

validate_candidate_kernel_images() {
    local current_flavor="$1"
    local package
    local release
    local flavor
    local version

    for package in "${CANDIDATE_KERNEL_IMAGES[@]}"; do
        release=$(kernel_release_from_image_package "$package")
        flavor=$(kernel_flavor_from_release "$release") || {
            error "无法识别候选内核 $package 的内核类型，已停止操作。"
            return 1
        }
        if [[ "$flavor" != "$current_flavor" ]]; then
            error "候选内核 $package 属于 $flavor 路线，与当前 $current_flavor 路线不一致，已停止操作。"
            return 1
        fi
        version=$(get_candidate_package_version "$package")
        if [[ -z "$version" || "$version" == "(none)" ]]; then
            error "无法获取候选内核软件包 $package 的候选版本，已停止操作。"
            return 1
        fi
        validate_official_candidate_source "$package" "$version" || return 1
    done
}

package_is_held() {
    apt-mark showhold 2>/dev/null | grep -Fxq -- "$1"
}

collect_installed_kernel_meta_packages() {
    local package

    KERNEL_META_PACKAGES=()
    while IFS= read -r package; do
        [[ -n "$package" ]] || continue
        if is_kernel_meta_package_name "$package"; then
            add_unique_path KERNEL_META_PACKAGES "$package"
        fi
    done < <(
        dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' 2>/dev/null |
            awk '$2 ~ /^ii/ {print $1}'
    )
}

collect_installed_kernel_releases() {
    local image
    local owner

    INSTALLED_KERNEL_RELEASES=()
    for image in /boot/vmlinuz-*; do
        [[ -e "$image" ]] || continue
        owner=$(dpkg-query -S "$image" 2>/dev/null | awk -F': ' 'NR==1 {print $1}')
        [[ "$owner" == linux-image-* ]] || continue
        INSTALLED_KERNEL_RELEASES+=("${image#/boot/vmlinuz-}")
    done
    if (( ${#INSTALLED_KERNEL_RELEASES[@]} > 0 )); then
        mapfile -t INSTALLED_KERNEL_RELEASES < <(
            printf '%s\n' "${INSTALLED_KERNEL_RELEASES[@]}" | sort -Vu
        )
    fi
}

collect_update_plan() {
    local mode="$1"
    shift
    local package
    local -a simulated_installs=()

    UPDATE_UPGRADE_PACKAGES=()
    UPDATE_NEW_PACKAGES=()
    UPDATE_REMOVE_PACKAGES=()
    UPDATE_SIMULATION_OUTPUT=""

    case "$mode" in
        regular)
            UPDATE_SIMULATION_OUTPUT=$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 upgrade 2>&1) || {
                error "无法生成常规升级预览。"
                echo "$UPDATE_SIMULATION_OUTPUT"
                return 1
            }
            ;;
        full)
            UPDATE_SIMULATION_OUTPUT=$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 full-upgrade 2>&1) || {
                error "无法生成完整系统升级预览。"
                echo "$UPDATE_SIMULATION_OUTPUT"
                return 1
            }
            ;;
        kernel)
            (( $# > 0 )) || {
                error "未提供内核元软件包，无法生成内核更新预览。"
                return 1
            }
            UPDATE_SIMULATION_OUTPUT=$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 \
                install --only-upgrade --no-install-recommends --no-remove -- "$@" 2>&1) || {
                error "无法生成内核更新预览。"
                echo "$UPDATE_SIMULATION_OUTPUT"
                return 1
            }
            ;;
        *)
            error "未知的软件包更新模式：$mode"
            return 1
            ;;
    esac

    mapfile -t simulated_installs < <(
        printf '%s\n' "$UPDATE_SIMULATION_OUTPUT" | parse_apt_simulated_installs
    )
    mapfile -t UPDATE_REMOVE_PACKAGES < <(
        printf '%s\n' "$UPDATE_SIMULATION_OUTPUT" | parse_apt_simulated_removals
    )
    for package in "${simulated_installs[@]}"; do
        if package_is_installed "$package"; then
            UPDATE_UPGRADE_PACKAGES+=("$package")
        else
            UPDATE_NEW_PACKAGES+=("$package")
        fi
    done
}

print_update_plan() {
    local package

    echo "升级已有软件包：${#UPDATE_UPGRADE_PACKAGES[@]} 个"
    for package in "${UPDATE_UPGRADE_PACKAGES[@]}"; do
        echo " - $package"
    done
    echo "新增依赖软件包：${#UPDATE_NEW_PACKAGES[@]} 个"
    for package in "${UPDATE_NEW_PACKAGES[@]}"; do
        echo " - $package"
    done
    echo "删除软件包：${#UPDATE_REMOVE_PACKAGES[@]} 个"
    for package in "${UPDATE_REMOVE_PACKAGES[@]}"; do
        echo -e "${RED} - $package${NC}"
    done
}

update_plan_is_empty() {
    (( ${#UPDATE_UPGRADE_PACKAGES[@]} == 0 && \
       ${#UPDATE_NEW_PACKAGES[@]} == 0 && \
       ${#UPDATE_REMOVE_PACKAGES[@]} == 0 ))
}

update_plan_signature() {
    printf '%s\n' "$UPDATE_SIMULATION_OUTPUT" |
        awk '$1 == "Inst" || $1 == "Remv" || $1 == "Purg" {print}'
}

validate_regular_update_plan() {
    if (( ${#UPDATE_NEW_PACKAGES[@]} > 0 || ${#UPDATE_REMOVE_PACKAGES[@]} > 0 )); then
        error "常规升级预览包含新增或删除软件包，与保守升级边界不符，已停止操作。"
        return 1
    fi
}

system_update_package_requires_release_validation() {
    local package="${1%%:*}"

    is_kernel_update_package "$package" && return 0
    case "$package" in
        base-files|apt|dpkg|libc6|libc-bin|systemd|systemd-sysv)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_system_update_release_sources() {
    local record
    local package
    local version
    local checked=0
    local -a version_records=()
    local -A planned_versions=()

    mapfile -t version_records < <(
        printf '%s\n' "$UPDATE_SIMULATION_OUTPUT" | parse_apt_simulated_install_versions
    )
    for record in "${version_records[@]}"; do
        IFS=$'\t' read -r package version <<< "$record"
        [[ -n "$package" && -n "$version" ]] || continue
        planned_versions["$package"]="$version"
    done
    for package in "${UPDATE_UPGRADE_PACKAGES[@]}" "${UPDATE_NEW_PACKAGES[@]}"; do
        [[ -n "$package" ]] || continue
        system_update_package_requires_release_validation "$package" || continue
        version="${planned_versions[$package]:-}"
        if [[ -z "$version" ]]; then
            error "无法从 APT 预览中确定核心软件包 $package 的计划版本，已停止升级。"
            return 1
        fi
        validate_official_candidate_source "$package" "$version" || {
            error "系统核心软件包来源不属于当前 $OS_ID $OS_VERSION 的稳定更新范围；这可能是跨发行版升级或来源配置错误。"
            return 1
        }
        ((checked += 1))
    done
    (( checked == 0 )) || detail "UPDATE" "RELEASE_BOUNDARY" \
        "已核验 $checked 个发行版核心软件包仍来自当前版本的官方稳定更新 pocket"
}

validate_kernel_update_plan() {
    local package
    local -a unexpected_packages=()

    if (( ${#UPDATE_REMOVE_PACKAGES[@]} > 0 )); then
        error "内核更新预览包含软件包删除，已停止操作；请改用完整系统升级并核对预览。"
        return 1
    fi
    for package in "${UPDATE_UPGRADE_PACKAGES[@]}" "${UPDATE_NEW_PACKAGES[@]}"; do
        [[ -n "$package" ]] || continue
        is_kernel_update_package "$package" || unexpected_packages+=("$package")
    done
    if (( ${#unexpected_packages[@]} > 0 )); then
        error "内核更新预览包含非内核范围的软件包，已停止操作："
        printf ' - %s\n' "${unexpected_packages[@]}"
        return 1
    fi
}

validate_kernel_update_sources() {
    local record
    local package
    local version
    local validated_count=0
    local -a version_records=()
    local -A planned_versions=()

    mapfile -t version_records < <(
        printf '%s\n' "$UPDATE_SIMULATION_OUTPUT" | parse_apt_simulated_install_versions
    )
    for record in "${version_records[@]}"; do
        IFS=$'\t' read -r package version <<< "$record"
        [[ -n "$package" && -n "$version" ]] || continue
        planned_versions["$package"]="$version"
    done

    for package in "${UPDATE_UPGRADE_PACKAGES[@]}" "${UPDATE_NEW_PACKAGES[@]}"; do
        [[ -n "$package" ]] || continue
        version="${planned_versions[$package]:-}"
        if [[ -z "$version" ]]; then
            error "无法从 APT 预览中确定 $package 的计划版本，已停止内核更新。"
            return 1
        fi
        validate_official_candidate_source "$package" "$version" || return 1
        ((validated_count += 1))
    done
    detail "UPDATE" "KERNEL_SOURCES" \
        "已核验 $validated_count 个计划安装/升级软件包的发行方、版本代号与稳定更新 pocket"
}

collect_package_cleanup_candidates() {
    local package
    local residual_package
    local simulation_output
    local -a simulated_packages=()
    local -a residual_packages=()

    AUTOREMOVE_PACKAGES=()
    AUTOREMOVE_KERNEL_PACKAGES=()
    RESIDUAL_PACKAGES=()

    if ! simulation_output=$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 autoremove --purge 2>&1); then
        error "无法生成无用软件包清理预览，已停止操作："
        echo "$simulation_output"
        return 1
    fi
    mapfile -t simulated_packages < <(
        printf '%s\n' "$simulation_output" | parse_apt_simulated_removals
    )
    for package in "${simulated_packages[@]}"; do
        if is_kernel_autoremove_protected_package "$package"; then
            add_unique_path AUTOREMOVE_KERNEL_PACKAGES "$package"
        else
            AUTOREMOVE_PACKAGES+=("$package")
        fi
    done

    mapfile -t residual_packages < <(
        dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' 2>/dev/null |
            awk '$2 ~ /^rc/ {print $1}'
    )
    for residual_package in "${residual_packages[@]}"; do
        if is_kernel_autoremove_protected_package "$residual_package"; then
            add_unique_path AUTOREMOVE_KERNEL_PACKAGES "$residual_package"
        else
            RESIDUAL_PACKAGES+=("$residual_package")
        fi
    done
}

print_package_cleanup_candidates() {
    local package

    echo "无用依赖包：${#AUTOREMOVE_PACKAGES[@]} 个"
    for package in "${AUTOREMOVE_PACKAGES[@]}"; do
        echo " - $package"
    done
    echo "残留配置包：${#RESIDUAL_PACKAGES[@]} 个"
    for package in "${RESIDUAL_PACKAGES[@]}"; do
        echo " - $package"
    done
    if (( ${#AUTOREMOVE_KERNEL_PACKAGES[@]} > 0 )); then
        echo -e "${YELLOW}检测到 ${#AUTOREMOVE_KERNEL_PACKAGES[@]} 个内核相关候选，已保留给【清理旧内核】单独处理。${NC}"
    fi
}

validate_explicit_package_purge() {
    local array_name="$1"
    local label="$2"
    local expected
    local planned
    local simulation_output
    local -n expected_packages="$array_name"
    local -a planned_packages=()

    (( ${#expected_packages[@]} > 0 )) || return 0
    if ! simulation_output=$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 purge -- \
        "${expected_packages[@]}" 2>&1); then
        error "$label 的最终删除预览失败，已停止操作："
        echo "$simulation_output"
        return 1
    fi
    mapfile -t planned_packages < <(
        printf '%s\n' "$simulation_output" | parse_apt_simulated_removals
    )
    if (( ${#planned_packages[@]} == 0 )); then
        error "$label 的最终删除预览为空，已停止操作。"
        return 1
    fi
    for planned in "${planned_packages[@]}"; do
        if ! array_contains_package_name "$array_name" "$planned"; then
            error "$label 的最终预览包含未确认的连带删除 $planned，已停止操作。"
            return 1
        fi
    done
    for expected in "${expected_packages[@]}"; do
        if ! array_contains_package_name planned_packages "$expected"; then
            error "$label 的最终预览缺少候选 $expected，已停止操作。"
            return 1
        fi
    done
}

perform_package_cleanup() {
    local failed=0

    if (( ${#AUTOREMOVE_PACKAGES[@]} > 0 )); then
        if ! validate_explicit_package_purge AUTOREMOVE_PACKAGES "无用依赖包"; then
            print_result "无用依赖包" "失败" "最终删除边界验证未通过"
            failed=1
        elif apt-get purge -y -- "${AUTOREMOVE_PACKAGES[@]}"; then
            print_result "无用依赖包" "已完成" "${#AUTOREMOVE_PACKAGES[@]} 个"
        else
            print_result "无用依赖包" "失败"
            failed=1
        fi
    else
        print_result "无用依赖包" "跳过" "未发现"
    fi

    if (( ${#RESIDUAL_PACKAGES[@]} > 0 )); then
        if ! validate_explicit_package_purge RESIDUAL_PACKAGES "残留配置包"; then
            print_result "残留配置包" "失败" "最终删除边界验证未通过"
            failed=1
        elif apt-get purge -y -- "${RESIDUAL_PACKAGES[@]}"; then
            print_result "残留配置包" "已完成" "${#RESIDUAL_PACKAGES[@]} 个"
        else
            print_result "残留配置包" "失败"
            failed=1
        fi
    else
        print_result "残留配置包" "跳过" "未发现"
    fi

    return "$failed"
}

perform_cache_cleanup() {
    if apt-get clean; then
        print_result "APT 下载缓存" "已完成"
        return 0
    fi
    print_result "APT 下载缓存" "失败"
    return 1
}

get_old_crash_count() {
    local count=0

    if [[ -d /var/crash ]]; then
        count=$(find /var/crash -xdev -type f -mtime +7 -print 2>/dev/null | wc -l)
    fi
    echo "$count"
}

perform_log_cleanup() {
    local crash_failed=0
    local failed=0

    if command -v journalctl >/dev/null 2>&1; then
        if journalctl --rotate --vacuum-time=7d; then
            print_result "systemd 历史日志" "已完成" "保留最近 7 天"
        else
            print_result "systemd 历史日志" "失败"
            failed=1
        fi
    else
        print_result "systemd 历史日志" "跳过" "journalctl 不可用"
    fi

    if command -v systemd-tmpfiles >/dev/null 2>&1; then
        if systemd-tmpfiles --clean; then
            print_result "过期临时文件" "已完成"
        else
            print_result "过期临时文件" "失败"
            failed=1
        fi
    else
        print_result "过期临时文件" "跳过" "systemd-tmpfiles 不可用"
    fi

    if [[ ! -d /var/crash ]]; then
        print_result "/var/crash 文件" "跳过" "目录不存在"
    else
        if ! find /var/crash -xdev -type f -mtime +7 -delete 2>/dev/null; then
            crash_failed=1
        fi
        if [[ "$crash_failed" == "0" ]]; then
            print_result "/var/crash 文件" "已完成" "仅删除 7 天前文件"
        else
            print_result "/var/crash 文件" "失败"
            failed=1
        fi
    fi

    return "$failed"
}

cleanup_package_cache() {
    local before
    local after
    local failed=0

    package_manager_ready || return 1
    before=$(get_path_size_bytes /var/cache/apt/archives)
    echo "APT 下载缓存占用：$(format_bytes "$before")"
    confirm_action "确认清理全部 APT 下载缓存和下载残片吗？" || return 0
    perform_cache_cleanup || failed=1
    after=$(get_path_size_bytes /var/cache/apt/archives)
    show_released_space "$before" "$after"
    return "$failed"
}

cleanup_unused_packages() {
    local before
    local after
    local failed=0

    package_manager_ready || return 1
    collect_package_cleanup_candidates || return 1
    if (( ${#AUTOREMOVE_PACKAGES[@]} == 0 && ${#RESIDUAL_PACKAGES[@]} == 0 )); then
        echo -e "${GREEN}未发现可清理的无用软件包或残留配置。${NC}"
        (( ${#AUTOREMOVE_KERNEL_PACKAGES[@]} > 0 )) &&
            echo -e "${YELLOW}内核相关候选请在【清理旧内核】中单独确认。${NC}"
        return 0
    fi

    print_package_cleanup_candidates
    confirm_action "确认只删除以上非内核软件包和残留配置吗？" || return 0
    before=$(get_root_used_bytes)
    perform_package_cleanup || failed=1
    after=$(get_root_used_bytes)
    show_released_space "$before" "$after"
    return "$failed"
}

is_kernel_cleanup_meta_package() {
    local package="${1%%:*}"

    is_kernel_meta_package_name "$package" && return 0
    case "$package" in
        *-common|linux-tools-common|linux-cloud-tools-common)
            return 1
            ;;
    esac
    case "$package" in
        linux-headers-[0-9]*|linux-tools-[0-9]*|linux-cloud-tools-[0-9]*|\
        linux-restricted-modules-[0-9]*|linux-modules-extra-[0-9]*)
            return 1
            ;;
        linux-headers-*|linux-tools-*|linux-cloud-tools-*|linux-restricted-modules-*|\
        linux-modules-extra-*)
            return 0
            ;;
    esac
    return 1
}

prepare_active_kernel_meta_for_cleanup() {
    local current_kernel="$1"

    ACTIVE_KERNEL_META=""
    if ! collect_compatible_kernel_meta_packages "$current_kernel"; then
        warn "无法识别当前内核类型，已停止旧内核清理。"
        return 1
    fi
    case "${#KERNEL_META_CANDIDATES[@]}" in
        0)
            warn "未发现与当前内核匹配的元软件包；将保护当前内核，但不允许连带删除任何内核元包。"
            ;;
        1)
            ACTIVE_KERNEL_META="${KERNEL_META_CANDIDATES[0]}"
            ;;
        *)
            select_kernel_meta_package "$current_kernel" "旧内核清理" || return 1
            [[ -n "$SELECTED_KERNEL_META" ]] || return 1
            ACTIVE_KERNEL_META="$SELECTED_KERNEL_META"
            ;;
    esac
}

build_old_kernel_release_plan() {
    local retention_policy="$1"
    local current_kernel="$2"
    shift 2
    local release
    local flavor
    local current_flavor
    local latest_current_flavor
    local -a installed_releases=("$@")
    local -a current_flavor_releases=()

    OLD_KERNEL_RELEASES=()
    RETAINED_KERNEL_RELEASES=()
    FALLBACK_KERNEL=""
    if [[ "$retention_policy" != "keep-fallback" && "$retention_policy" != "current-only" ]]; then
        error "未知的旧内核保留策略：$retention_policy"
        return 1
    fi
    if ! array_contains_value installed_releases "$current_kernel"; then
        warn "当前运行内核 $current_kernel 不在可识别的软件包列表中，已停止清理。"
        return 1
    fi
    current_flavor=$(kernel_flavor_from_release "$current_kernel") || {
        warn "无法识别当前运行内核 $current_kernel 的内核类型，已停止清理。"
        return 1
    }
    for release in "${installed_releases[@]}"; do
        flavor=$(kernel_flavor_from_release "$release" 2>/dev/null || true)
        [[ "$flavor" == "$current_flavor" ]] && current_flavor_releases+=("$release")
    done
    mapfile -t current_flavor_releases < <(
        printf '%s\n' "${current_flavor_releases[@]}" | LC_ALL=C sort -Vu
    )
    latest_current_flavor="${current_flavor_releases[-1]}"
    if [[ "$current_kernel" != "$latest_current_flavor" ]]; then
        warn "当前运行内核 $current_kernel 不是同类型中最新已安装内核 $latest_current_flavor，请先重启。"
        return 1
    fi

    RETAINED_KERNEL_RELEASES=("$current_kernel")
    if [[ "$retention_policy" == "keep-fallback" ]] && \
       (( ${#current_flavor_releases[@]} > 1 )); then
        FALLBACK_KERNEL="${current_flavor_releases[-2]}"
        RETAINED_KERNEL_RELEASES+=("$FALLBACK_KERNEL")
    fi
    for release in "${installed_releases[@]}"; do
        if array_contains_value RETAINED_KERNEL_RELEASES "$release"; then
            continue
        fi
        OLD_KERNEL_RELEASES+=("$release")
    done
}

current_kernel_boot_artifacts_are_ready() {
    local current_kernel="$1"
    local owner
    local require_initrd=0

    owner=$(dpkg-query -S "/boot/vmlinuz-$current_kernel" 2>/dev/null |
        awk -F': ' 'NR==1 {print $1}')
    owner="${owner%%:*}"
    if [[ ! -s "/boot/vmlinuz-$current_kernel" ]] || \
       [[ "$owner" != "linux-image-$current_kernel" && \
          "$owner" != "linux-image-unsigned-$current_kernel" ]]; then
        error "当前运行内核的引导文件或软件包归属异常。"
        return 1
    fi
    if command -v update-initramfs >/dev/null 2>&1 || command -v dracut >/dev/null 2>&1; then
        require_initrd=1
    fi
    if [[ "$require_initrd" == "1" && ! -s "/boot/initrd.img-$current_kernel" ]]; then
        error "当前运行内核的 initramfs 不存在或为空。"
        return 1
    fi
}

collect_old_kernel_candidates() {
    local retention_policy="${1:-keep-fallback}"
    local release
    local package
    local current_kernel
    local retained_release
    local old_release
    local related_stem
    local old_uses_related
    local retained_uses_related
    local record
    local package_status
    local -a installed_releases=()
    local -a installed_kernel_packages=()
    local -a kernel_package_records=()
    local -a residual_kernel_packages=()

    OLD_KERNEL_RELEASES=()
    OLD_KERNEL_PACKAGES=()
    OLD_KERNEL_RESIDUAL_PACKAGES=()
    OLD_KERNEL_META_PACKAGES=()
    current_kernel=$(uname -r)

    mapfile -t kernel_package_records < <(
        dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' \
            'linux-image-[0-9]*' 'linux-image-unsigned-[0-9]*' \
            'linux-image-extra-[0-9]*' \
            'linux-headers-[0-9]*' 'linux-modules-[0-9]*' \
            'linux-modules-extra-[0-9]*' 'linux-tools-[0-9]*' \
            'linux-cloud-tools-[0-9]*' \
            'linux-restricted-modules-[0-9]*' 2>/dev/null |
            parse_kernel_package_records
    )
    for record in "${kernel_package_records[@]}"; do
        IFS=$'\t' read -r package package_status <<< "$record"
        [[ -n "$package" ]] || continue
        if [[ "$package_status" == rc* ]]; then
            add_unique_path residual_kernel_packages "$package"
        else
            installed_kernel_packages+=("$package")
        fi
    done
    for package in "${installed_kernel_packages[@]}"; do
        case "$package" in
            linux-image-[0-9]*|linux-image-unsigned-[0-9]*)
                installed_releases+=("$(kernel_release_from_image_package "$package")")
                ;;
        esac
    done
    if (( ${#installed_releases[@]} == 0 )); then
        warn "未检测到由软件包管理器安装的版本化内核映像。"
        return 1
    fi
    mapfile -t installed_releases < <(
        printf '%s\n' "${installed_releases[@]}" | LC_ALL=C sort -Vu
    )
    if ! current_kernel_boot_artifacts_are_ready "$current_kernel"; then
        error "当前运行内核引导文件未通过前置校验，已停止清理。"
        return 1
    fi
    prepare_active_kernel_meta_for_cleanup "$current_kernel" || return 1
    if [[ -f /var/run/reboot-required ]]; then
        warn "系统提示需要重启，为避免删除尚未启动的新内核，本次不执行旧内核清理。"
        return 1
    fi
    build_old_kernel_release_plan \
        "$retention_policy" "$current_kernel" "${installed_releases[@]}" || return 1
    for package in "${residual_kernel_packages[@]}"; do
        if ! kernel_versioned_package_matches_retained_release "$package"; then
            add_unique_path OLD_KERNEL_RESIDUAL_PACKAGES "$package"
        fi
    done
    if (( ${#OLD_KERNEL_RELEASES[@]} == 0 && \
          ${#OLD_KERNEL_RESIDUAL_PACKAGES[@]} == 0 )); then
        echo -e "${GREEN}当前没有符合该保留策略的非运行内核。${NC}"
        return 0
    fi
    for release in "${OLD_KERNEL_RELEASES[@]}"; do
        for package in "${installed_kernel_packages[@]}"; do
            case "$package" in
                linux-image-"$release"|linux-image-unsigned-"$release"|\
                 linux-image-extra-"$release"|\
                 linux-modules-"$release"|linux-modules-extra-"$release"|\
                 linux-headers-"$release"|linux-tools-"$release"|\
                 linux-cloud-tools-"$release"|linux-restricted-modules-"$release")
                    add_unique_path OLD_KERNEL_PACKAGES "$package"
                    ;;
            esac
        done
    done
    for package in "${installed_kernel_packages[@]}"; do
        case "$package" in
            linux-headers-[0-9]*) related_stem="${package#linux-headers-}" ;;
            linux-tools-[0-9]*) related_stem="${package#linux-tools-}" ;;
            linux-cloud-tools-[0-9]*) related_stem="${package#linux-cloud-tools-}" ;;
            *) continue ;;
        esac
        related_stem="${related_stem%-common}"
        old_uses_related=0
        retained_uses_related=0
        for old_release in "${OLD_KERNEL_RELEASES[@]}"; do
            if [[ "$old_release" == "$related_stem"-* ]]; then
                old_uses_related=1
                break
            fi
        done
        [[ "$old_uses_related" == "1" ]] || continue
        for retained_release in "${RETAINED_KERNEL_RELEASES[@]}"; do
            if [[ "$retained_release" == "$related_stem"-* ]]; then
                retained_uses_related=1
                break
            fi
        done
        if [[ "$retained_uses_related" == "0" ]]; then
            add_unique_path OLD_KERNEL_PACKAGES "$package"
        fi
    done
    for package in "${OLD_KERNEL_RESIDUAL_PACKAGES[@]}"; do
        add_unique_path OLD_KERNEL_PACKAGES "$package"
    done

    echo "当前运行内核：$current_kernel"
    echo "当前内核路线：${ACTIVE_KERNEL_META:-未检测到元软件包}"
    if [[ "$retention_policy" == "keep-fallback" ]]; then
        if [[ -n "$FALLBACK_KERNEL" ]]; then
            echo "保留同类型备用内核：$FALLBACK_KERNEL"
        else
            echo "保留同类型备用内核：无"
        fi
    else
        echo -e "${RED}保留策略：仅保留当前运行内核，不保留备用内核${NC}"
    fi
}

validate_old_kernel_removal_plan() {
    local package
    local planned
    local simulation_output
    local -a planned_removals=()

    OLD_KERNEL_META_PACKAGES=()
    OLD_KERNEL_REMOVAL_PLAN=()
    if ! simulation_output=$(LC_ALL=C apt-get -s purge -- "${OLD_KERNEL_PACKAGES[@]}" 2>&1); then
        error "无法生成旧内核删除预览，已停止操作："
        echo "$simulation_output"
        return 1
    fi
    mapfile -t planned_removals < <(
        printf '%s\n' "$simulation_output" |
            parse_apt_simulated_removals |
            awk -F: '{print $1}' |
            sort -u
    )
    if (( ${#planned_removals[@]} == 0 )); then
        error "删除预览中未发现任何候选软件包，已停止操作。"
        return 1
    fi
    OLD_KERNEL_REMOVAL_PLAN=("${planned_removals[@]}")
    for planned in "${planned_removals[@]}"; do
        if is_versioned_kernel_package "$planned" && \
           kernel_versioned_package_matches_retained_release "$planned"; then
            error "模拟删除会移除当前或保留内核关联包 $planned，已停止操作。"
            return 1
        fi
        if array_contains_value OLD_KERNEL_PACKAGES "$planned"; then
            continue
        fi
        if is_kernel_cleanup_meta_package "$planned"; then
            if [[ -z "$ACTIVE_KERNEL_META" ]]; then
                error "模拟删除会移除内核元包 $planned，但当前更新路线未识别，已停止操作。"
                return 1
            fi
            if [[ "$planned" == "$ACTIVE_KERNEL_META" ]]; then
                error "模拟删除会移除当前内核路线元包 $ACTIVE_KERNEL_META，已停止操作。"
                return 1
            fi
            add_unique_path OLD_KERNEL_META_PACKAGES "$planned"
            continue
        fi
        error "模拟删除还会影响非内核软件包 $planned，已停止操作。"
        return 1
    done
    for package in "${OLD_KERNEL_PACKAGES[@]}"; do
        if ! array_contains_value planned_removals "$package"; then
            error "模拟删除未包含候选软件包 $package，已停止操作。"
            return 1
        fi
    done
}

kernel_removal_plan_signature() {
    printf '%s\n' "${OLD_KERNEL_REMOVAL_PLAN[@]}"
}

print_old_kernel_meta_removals() {
    if (( ${#OLD_KERNEL_META_PACKAGES[@]} == 0 )); then
        return 0
    fi
    echo -e "${RED}以下其他内核路线元包将被一并删除：${NC}"
    printf ' - %s\n' "${OLD_KERNEL_META_PACKAGES[@]}"
    warn "删除这些元包后，对应内核路线不会再随系统更新自动安装。"
}

verify_current_kernel_after_cleanup() {
    local current_kernel="$1"
    local package
    local package_status
    local audit_output

    current_kernel_boot_artifacts_are_ready "$current_kernel" || return 1
    if [[ -n "$ACTIVE_KERNEL_META" ]] && ! package_is_installed "$ACTIVE_KERNEL_META"; then
        error "当前内核路线元包 $ACTIVE_KERNEL_META 已被意外删除。"
        return 1
    fi
    for package in "${OLD_KERNEL_PACKAGES[@]}" "${OLD_KERNEL_META_PACKAGES[@]}"; do
        [[ -n "$package" ]] || continue
        package_status=$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)
        if [[ "$package_status" == ii* || "$package_status" == rc* ]]; then
            error "计划清理的软件包 $package 仍处于 ${package_status:-未知} 状态。"
            return 1
        fi
    done
    audit_output=$(dpkg --audit 2>/dev/null || true)
    if [[ -n "$audit_output" ]]; then
        error "旧内核删除后检测到未完成的软件包配置："
        echo "$audit_output"
        return 1
    fi
}

perform_old_kernel_removal() {
    local result_label="$1"
    local before
    local after
    local current_kernel

    current_kernel=$(uname -r)
    before=$(get_kernel_storage_used_bytes)
    if ! apt-get purge -y -- "${OLD_KERNEL_PACKAGES[@]}"; then
        print_result "$result_label" "失败"
        return 1
    fi
    if ! verify_current_kernel_after_cleanup "$current_kernel"; then
        print_result "$result_label" "部分完成" "软件包已删除，但当前内核验证失败"
        error "请勿重启并立即检查 /boot、initramfs 和内核元软件包。"
        return 1
    fi
    if command -v update-grub >/dev/null 2>&1; then
        if update-grub >/dev/null 2>&1; then
            print_result "GRUB 配置刷新" "已完成"
        else
            print_result "$result_label" "部分完成" "软件包已删除"
            print_result "GRUB 配置刷新" "失败"
            error "旧内核软件包已删除，但 update-grub 失败；请修复引导配置后再重启。"
            return 1
        fi
    else
        print_result "GRUB 配置刷新" "跳过" "未安装 update-grub"
    fi
    print_result "$result_label" "已完成" \
        "${#OLD_KERNEL_RELEASES[@]} 个非运行版本，${#OLD_KERNEL_RESIDUAL_PACKAGES[@]} 个残留配置包"
    after=$(get_kernel_storage_used_bytes)
    show_released_space "$before" "$after"
}

cleanup_old_kernels() {
    local expected_current_kernel
    local approved_plan

    package_manager_ready || return 1
    expected_current_kernel=$(uname -r)
    collect_old_kernel_candidates keep-fallback || return 1
    if (( ${#OLD_KERNEL_PACKAGES[@]} == 0 )); then
        if (( ${#OLD_KERNEL_RELEASES[@]} == 0 && \
              ${#OLD_KERNEL_RESIDUAL_PACKAGES[@]} == 0 )); then
            return 0
        fi
        error "已识别非运行内核版本，但未找到对应的已安装软件包，已停止操作。"
        return 1
    fi
    if (( ${#OLD_KERNEL_RELEASES[@]} > 0 )); then
        echo "候选非运行内核版本："
        printf ' - %s\n' "${OLD_KERNEL_RELEASES[@]}"
    fi
    if (( ${#OLD_KERNEL_RESIDUAL_PACKAGES[@]} > 0 )); then
        echo "已卸载内核的残留配置包："
        printf ' - %s\n' "${OLD_KERNEL_RESIDUAL_PACKAGES[@]}"
    fi
    echo "关联软件包："
    printf ' - %s\n' "${OLD_KERNEL_PACKAGES[@]}"
    validate_old_kernel_removal_plan || return 1
    print_old_kernel_meta_removals
    approved_plan=$(kernel_removal_plan_signature)

    echo -e "${YELLOW}本操作保留当前内核和一个同类型备用内核，其余类型内核不保留。${NC}"
    confirm_action "确认删除以上非运行内核吗？" || return 0
    if (( ${#OLD_KERNEL_META_PACKAGES[@]} > 0 )); then
        confirm_action "确认同时移除以上其他内核路线元包吗？" || return 0
    fi
    if [[ -f /var/run/reboot-required ]] || [[ "$(uname -r)" != "$expected_current_kernel" ]]; then
        error "最终执行前检测到内核状态变化或需要重启，已停止操作。"
        return 1
    fi
    current_kernel_boot_artifacts_are_ready "$expected_current_kernel" || {
        error "最终执行前当前内核引导文件校验失败，已停止操作。"
        return 1
    }
    package_manager_ready || return 1
    validate_old_kernel_removal_plan || return 1
    if [[ "$(kernel_removal_plan_signature)" != "$approved_plan" ]]; then
        error "最终 APT 删除计划与确认时不一致，已停止操作；请重新预览并确认。"
        return 1
    fi
    perform_old_kernel_removal "旧内核"
}

cleanup_all_old_kernels() {
    local typed_confirmation
    local expected_current_kernel
    local approved_plan

    package_manager_ready || return 1
    expected_current_kernel=$(uname -r)
    collect_old_kernel_candidates current-only || return 1
    if (( ${#OLD_KERNEL_PACKAGES[@]} == 0 )); then
        if (( ${#OLD_KERNEL_RELEASES[@]} == 0 && \
              ${#OLD_KERNEL_RESIDUAL_PACKAGES[@]} == 0 )); then
            return 0
        fi
        error "已识别非运行内核版本，但未找到对应的已安装软件包，已停止操作。"
        return 1
    fi

    echo -e "${RED}高风险操作：以下全部非运行内核将被删除，只保留当前运行内核。${NC}"
    if (( ${#OLD_KERNEL_RELEASES[@]} > 0 )); then
        echo "待删除的全部非运行内核版本："
        printf ' - %s\n' "${OLD_KERNEL_RELEASES[@]}"
    fi
    if (( ${#OLD_KERNEL_RESIDUAL_PACKAGES[@]} > 0 )); then
        echo "已卸载内核的残留配置包："
        printf ' - %s\n' "${OLD_KERNEL_RESIDUAL_PACKAGES[@]}"
    fi
    echo "关联软件包："
    printf ' - %s\n' "${OLD_KERNEL_PACKAGES[@]}"
    validate_old_kernel_removal_plan || return 1
    print_old_kernel_meta_removals
    approved_plan=$(kernel_removal_plan_signature)

    echo -e "${RED}删除后系统将没有备用内核；当前内核若无法启动，只能通过云厂商控制台或救援模式修复。${NC}"
    confirm_action "确认继续删除所有非运行内核吗？" || return 0
    read -r -p "请输入“删除所有旧内核”进行最终确认: " typed_confirmation
    if [[ "$typed_confirmation" != "删除所有旧内核" ]]; then
        warn "确认文字不匹配，已取消操作。"
        return 0
    fi
    if [[ -f /var/run/reboot-required ]] || [[ "$(uname -r)" != "$expected_current_kernel" ]]; then
        error "最终执行前检测到内核状态变化或需要重启，已停止操作。"
        return 1
    fi
    current_kernel_boot_artifacts_are_ready "$expected_current_kernel" || {
        error "最终执行前当前内核引导文件校验失败，已停止操作。"
        return 1
    }
    package_manager_ready || return 1
    validate_old_kernel_removal_plan || return 1
    if [[ "$(kernel_removal_plan_signature)" != "$approved_plan" ]]; then
        error "最终 APT 删除计划与确认时不一致，已停止操作；请重新预览并确认。"
        return 1
    fi
    perform_old_kernel_removal "全部旧内核"
}

cleanup_system_logs() {
    local journal_usage="不可用"
    local crash_count
    local before
    local after
    local failed=0

    require_commands "系统日志清理" awk df find sed wc || return 1
    command -v journalctl >/dev/null 2>&1 &&
        journal_usage=$(journalctl --disk-usage 2>/dev/null | sed 's/^Archived and active journals take up //')
    crash_count=$(get_old_crash_count)

    echo "systemd 日志占用：$journal_usage"
    echo "7 天前的 /var/crash 文件：$crash_count 个"
    echo "临时文件与 systemd coredump 将严格按照 systemd-tmpfiles 的系统策略清理。"
    confirm_action "确认保留最近 7 天日志并清理过期临时文件和崩溃转储吗？" || return 0

    before=$(get_root_used_bytes)
    perform_log_cleanup || failed=1
    after=$(get_root_used_bytes)
    show_released_space "$before" "$after"
    return "$failed"
}

run_regular_cleanup() {
    local cache_size
    local journal_usage="不可用"
    local crash_count
    local before
    local after
    local failed=0

    require_commands "常规清理" awk df du find sed wc || return 1
    package_manager_ready || return 1
    collect_package_cleanup_candidates || return 1
    cache_size=$(get_path_size_bytes /var/cache/apt/archives)
    crash_count=$(get_old_crash_count)
    command -v journalctl >/dev/null 2>&1 &&
        journal_usage=$(journalctl --disk-usage 2>/dev/null | sed 's/^Archived and active journals take up //')

    echo "常规清理预览："
    echo " - APT 下载缓存：$(format_bytes "$cache_size")"
    echo " - 非内核无用依赖：${#AUTOREMOVE_PACKAGES[@]} 个"
    echo " - 残留配置：${#RESIDUAL_PACKAGES[@]} 个"
    echo " - systemd 日志：$journal_usage（保留 7 天）"
    echo " - 7 天前的 /var/crash 文件：$crash_count 个"
    if (( ${#AUTOREMOVE_KERNEL_PACKAGES[@]} > 0 )); then
        echo -e "${YELLOW} - 内核相关候选：${#AUTOREMOVE_KERNEL_PACKAGES[@]} 个（本次保留）${NC}"
    fi
    echo " - 过期临时文件与 systemd coredump：按 systemd-tmpfiles 策略"
    confirm_action "确认执行以上常规清理吗？" || return 0

    before=$(get_root_used_bytes)
    perform_cache_cleanup || failed=1
    perform_package_cleanup || failed=1
    perform_log_cleanup || failed=1
    after=$(get_root_used_bytes)
    show_released_space "$before" "$after"
    if [[ "$failed" == "1" ]]; then
        error "常规清理有项目执行失败，请查看上方结果后重试对应项目。"
    fi
    return "$failed"
}

parse_disabled_snap_revisions() {
    awk 'NR > 1 && $6=="disabled" {print $1"\t"$3}'
}

cleanup_disabled_snaps() {
    local entry
    local name
    local revision
    local snap_output
    local snap_status
    local failed=0
    local -a disabled_snaps=()

    if ! command -v snap >/dev/null 2>&1; then
        echo -e "${YELLOW}未安装 Snap，已跳过。${NC}"
        return 0
    fi
    if snap_output=$(LANG=C timeout 30 snap list --all 2>&1); then
        snap_status=0
    else
        snap_status=$?
    fi
    if (( snap_status != 0 )); then
        detail "CLEANUP" "SNAP_LIST" "退出码=$snap_status；输出=${snap_output:-无}"
        error "读取 Snap 修订版列表失败，未执行任何删除。"
        return 1
    fi
    mapfile -t disabled_snaps < <(
        printf '%s\n' "$snap_output" | parse_disabled_snap_revisions
    )
    if (( ${#disabled_snaps[@]} == 0 )); then
        echo -e "${GREEN}未发现 disabled 状态的 Snap 旧版本。${NC}"
        return 0
    fi

    echo "待删除的 Snap 旧版本："
    printf ' - %s\n' "${disabled_snaps[@]}"
    confirm_action "确认删除以上 disabled 状态的 Snap 旧版本吗？" || return 0
    for entry in "${disabled_snaps[@]}"; do
        IFS=$'\t' read -r name revision <<< "$entry"
        if ! snap remove "$name" --revision="$revision"; then
            error "Snap $name 修订版 $revision 删除失败。"
            failed=1
        fi
    done
    if [[ "$failed" == "0" ]]; then
        action_success "Snap 旧版本" "已删除 ${#disabled_snaps[@]} 个"
    else
        action_partial "Snap 旧版本" "部分修订版删除失败，请查看上方错误"
    fi
    return "$failed"
}

submenu_advanced_cleanup() {
    local choice_advanced
    local snap_state="未安装"
    local docker_state="未安装"

    command -v snap >/dev/null 2>&1 && snap_state="可用"
    command -v docker >/dev/null 2>&1 && docker_state="可用"
    while true; do
        print_header "高级清理"
        echo -e "  ${YELLOW}[!] 以下项目均需单独确认${NC}"
        print_menu_item 1 "清理 Snap 旧版本" "$snap_state"
        print_menu_item 2 "清理 Docker 悬空镜像" "$docker_state"
        print_menu_item 3 "清理 Docker 构建缓存" "$docker_state"
        print_menu_item 4 "删除所有旧内核" "${RED}高风险，仅保留当前内核${NC}"
        echo -e "  ${DIM}0. 返回上一级${NC}"
        echo -e "${CYAN}==================================================${NC}"
        read -r -p "请输入选项 [0-4]: " choice_advanced

        case "$choice_advanced" in
            1) cleanup_disabled_snaps; pause_menu ;;
            2)
                if ! command -v docker >/dev/null 2>&1; then
                    warn "未安装 Docker。"
                else
                    if ! timeout 30 docker system df; then
                        error "读取 Docker 磁盘占用失败或超时，未执行清理。"
                        pause_menu
                        continue
                    fi
                    if confirm_action "确认清理 Docker 悬空镜像吗？不会删除容器和数据卷。"; then
                        if timeout 300 docker image prune -f; then
                            action_success "Docker 悬空镜像" "不会删除容器和数据卷"
                        else
                            error "Docker 悬空镜像清理失败或超时。"
                        fi
                    fi
                fi
                pause_menu
                ;;
            3)
                if ! command -v docker >/dev/null 2>&1; then
                    warn "未安装 Docker。"
                else
                    if ! timeout 30 docker system df; then
                        error "读取 Docker 磁盘占用失败或超时，未执行清理。"
                        pause_menu
                        continue
                    fi
                    if confirm_action "确认清理 Docker 构建缓存吗？不会删除容器和数据卷。"; then
                        if timeout 300 docker builder prune -f; then
                            action_success "Docker 构建缓存" "不会删除容器和数据卷"
                        else
                            error "Docker 构建缓存清理失败或超时。"
                        fi
                    fi
                fi
                pause_menu
                ;;
            4) cleanup_all_old_kernels; pause_menu ;;
            0) return ;;
            *) error "无效输入！"; sleep 1 ;;
        esac
    done
}

show_disk_usage() {
    require_commands "磁盘占用分析" df timeout du sort || return 1
    print_header "磁盘占用分析"
    df -hT /
    echo
    echo "主要目录占用（扫描最多 30 秒）："
    timeout 30 du -x -h --max-depth=1 /var /usr /opt 2>/dev/null | sort -h
    if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
        warn "目录扫描超时或部分路径不可读。"
    fi
    echo -e "${CYAN}==================================================${NC}"
}

submenu_cleanup() {
    local choice_cleanup
    local cache_size
    local disk_status

    while true; do
        cache_size=$(get_path_size_bytes /var/cache/apt/archives)
        disk_status=$(df -h / | awk 'NR==2 {print $3" 已用 / "$2" 总 ("$5")"}')
        print_header "系统清理"
        echo -e "  当前磁盘：${YELLOW}$disk_status${NC}"
        echo -e "${DIM}--------------------------------------------------${NC}"
        print_menu_item 1 "执行常规清理" "不包含旧内核和高级项目"
        print_menu_item 2 "清理软件包缓存" "当前 $(format_bytes "$cache_size")"
        print_menu_item 3 "清理无用软件包" "无用依赖和残留配置"
        print_menu_item 4 "清理旧内核" "独立预览并确认"
        print_menu_item 5 "清理系统日志" "日志、临时文件和崩溃转储"
        print_menu_item 6 "高级清理" "›"
        print_menu_item 7 "查看磁盘占用" "只读分析"
        echo -e "  ${DIM}0. 返回上一级${NC}"
        echo -e "${CYAN}==================================================${NC}"
        read -r -p "请输入选项 [0-7]: " choice_cleanup

        case "$choice_cleanup" in
            1) run_regular_cleanup; pause_menu ;;
            2) cleanup_package_cache; pause_menu ;;
            3) cleanup_unused_packages; pause_menu ;;
            4) cleanup_old_kernels; pause_menu ;;
            5) cleanup_system_logs; pause_menu ;;
            6) submenu_advanced_cleanup ;;
            7) show_disk_usage; pause_menu ;;
            0) return ;;
            *) error "无效输入！"; sleep 1 ;;
        esac
    done
}

refresh_package_index() {
    log "正在刷新软件包索引..."
    if apt_update_strict; then
        print_result "软件包索引" "已完成"
        return 0
    fi
    error "软件包索引刷新失败，未执行升级。"
    return 1
}

system_reboot_is_required() {
    local current_kernel="${1:-$(uname -r)}"
    local latest_kernel=""

    [[ -f /var/run/reboot-required ]] && return 0
    collect_installed_kernel_releases
    if (( ${#INSTALLED_KERNEL_RELEASES[@]} > 0 )); then
        latest_kernel=$(latest_installed_kernel_for_current_flavor \
            "$current_kernel" "${INSTALLED_KERNEL_RELEASES[@]}" 2>/dev/null || true)
    fi
    [[ -n "$latest_kernel" && "$current_kernel" != "$latest_kernel" ]]
}

show_reboot_notice() {
    local current_kernel
    local latest_kernel=""

    current_kernel=$(uname -r)
    collect_installed_kernel_releases
    if (( ${#INSTALLED_KERNEL_RELEASES[@]} > 0 )); then
        latest_kernel=$(latest_installed_kernel_for_current_flavor \
            "$current_kernel" "${INSTALLED_KERNEL_RELEASES[@]}" 2>/dev/null || true)
    fi

    if [[ -f /var/run/reboot-required ]]; then
        warn "系统提示需要重启；请先重启，再考虑清理旧内核。"
        [[ -f /var/run/reboot-required.pkgs ]] && sed 's/^/ - /' /var/run/reboot-required.pkgs
    elif [[ -n "$latest_kernel" && "$current_kernel" != "$latest_kernel" ]]; then
        warn "当前运行内核 $current_kernel，同类型最新已安装内核 $latest_kernel；请安排重启。"
    fi
}

check_available_updates() {
    require_commands "检查可用更新" apt-get dpkg dpkg-query awk || return 1
    package_manager_ready || return 1

    echo "此操作只刷新软件包索引并生成完整升级预览，不安装、删除或清理任何软件包。"
    confirm_action "确认检查可用更新吗？" || return 0
    refresh_package_index || return 1
    collect_update_plan full || return 1

    echo "可用更新预览："
    print_update_plan
    if update_plan_is_empty; then
        action_success "更新检查" "系统已是最新状态"
    else
        action_success "更新检查" \
            "升级 ${#UPDATE_UPGRADE_PACKAGES[@]} 个，新增 ${#UPDATE_NEW_PACKAGES[@]} 个，删除 ${#UPDATE_REMOVE_PACKAGES[@]} 个；未安装任何软件包"
    fi
    detail "UPDATE" "CHECK" \
        "升级=${#UPDATE_UPGRADE_PACKAGES[@]}；新增=${#UPDATE_NEW_PACKAGES[@]}；删除=${#UPDATE_REMOVE_PACKAGES[@]}"
}

confirm_update_plan_execution() {
    local mode="$1"

    confirm_action "确认执行以上升级吗？" || return 1
    if [[ "$mode" == "full" ]] && (( ${#UPDATE_REMOVE_PACKAGES[@]} > 0 )); then
        confirm_action "完整升级明确包含删除软件包；确认已核对删除列表并再次继续吗？" || return 1
    fi
}

run_package_upgrade() {
    local mode="$1"
    local label
    local description
    local approved_plan
    local final_plan

    require_commands "系统更新" apt-get dpkg dpkg-query awk || return 1
    package_manager_ready || return 1
    export DEBIAN_FRONTEND=noninteractive

    case "$mode" in
        regular)
            label="常规软件包升级"
            description="只升级现有软件包；预览若出现新增依赖或删除软件包将自动停止。"
            ;;
        full)
            label="完整系统升级"
            description="允许为解决依赖而新增或删除软件包，执行前会列出完整预览。"
            ;;
        *)
            error "未知的系统更新模式：$mode"
            return 1
            ;;
    esac

    echo "$description"
    echo "本次升级不会清理缓存、无用软件包或旧内核。"
    confirm_action "确认刷新软件包索引并生成升级预览吗？" || return 0
    refresh_package_index || return 1
    collect_update_plan "$mode" || return 1
    [[ "$mode" != "regular" ]] || validate_regular_update_plan || return 1
    validate_system_update_release_sources || return 1

    if update_plan_is_empty; then
        action_success "$label" "没有可安装的更新"
        return 0
    fi

    echo "$label 预览："
    print_update_plan
    detail "UPDATE" "PREVIEW" \
        "模式=$mode；升级=${#UPDATE_UPGRADE_PACKAGES[@]}；新增=${#UPDATE_NEW_PACKAGES[@]}；删除=${#UPDATE_REMOVE_PACKAGES[@]}"
    approved_plan=$(update_plan_signature)
    if (( ${#UPDATE_REMOVE_PACKAGES[@]} > 0 )); then
        warn "升级将删除 ${#UPDATE_REMOVE_PACKAGES[@]} 个软件包，请仔细核对上方列表。"
    fi
    confirm_update_plan_execution "$mode" || return 0
    package_manager_ready || return 1
    collect_update_plan "$mode" || return 1
    [[ "$mode" != "regular" ]] || validate_regular_update_plan || return 1
    validate_system_update_release_sources || return 1
    final_plan=$(update_plan_signature)
    if [[ "$final_plan" != "$approved_plan" ]]; then
        error "最终 APT 升级计划与确认时不一致，已停止操作；请重新预览并确认。"
        return 1
    fi

    log "开始执行${label}..."
    if [[ "$mode" == "regular" ]]; then
        apt-get upgrade -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" || {
            error "$label 执行失败，请检查上方 APT 输出。"
            return 1
        }
    else
        apt-get full-upgrade -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" || {
            error "$label 执行失败，请检查上方 APT 输出。"
            return 1
        }
    fi

    if [[ -n "$(dpkg --audit 2>/dev/null || true)" ]]; then
        action_partial "$label" "APT 已结束，但 dpkg 检测到未完成的软件包配置"
        return 1
    fi
    action_success "$label" "软件包升级完成；未执行清理"
    show_reboot_notice
}

show_kernel_update_status() {
    local current_kernel
    local latest_kernel="未识别"
    local current_owner="未识别（可能为厂商或自定义内核）"
    local boot_path="/boot"
    local reboot_state="不需要"
    local package
    local release

    require_commands "内核状态" uname dpkg-query sort df || return 1
    current_kernel=$(uname -r)
    if [[ -e "/boot/vmlinuz-$current_kernel" ]]; then
        current_owner=$(dpkg-query -S "/boot/vmlinuz-$current_kernel" 2>/dev/null |
            awk -F': ' 'NR==1 {print $1}')
        [[ -n "$current_owner" ]] || current_owner="未识别（可能为厂商或自定义内核）"
    fi
    collect_installed_kernel_releases
    if (( ${#INSTALLED_KERNEL_RELEASES[@]} > 0 )); then
        latest_kernel=$(latest_installed_kernel_for_current_flavor \
            "$current_kernel" "${INSTALLED_KERNEL_RELEASES[@]}" 2>/dev/null || true)
        [[ -n "$latest_kernel" ]] || latest_kernel="未识别"
    fi
    collect_installed_kernel_meta_packages
    [[ -d /boot ]] || boot_path="/"
    if [[ -f /var/run/reboot-required ]] || \
       [[ "$latest_kernel" != "未识别" && "$current_kernel" != "$latest_kernel" ]]; then
        reboot_state="需要"
    fi

    print_header "内核与重启状态"
    print_result "当前运行内核" "正常" "$current_kernel"
    print_result "内核软件包归属" "$([[ "$current_owner" == linux-image-* ]] && echo 正常 || echo 未识别)" "$current_owner"
    print_result "同类型最新已安装内核" "$([[ "$latest_kernel" == "未识别" ]] && echo 未识别 || echo 正常)" "$latest_kernel"
    print_result "重启状态" "$([[ "$reboot_state" == "需要" ]] && echo 需要 || echo 正常)" "$reboot_state"
    echo "已安装的受管内核版本："
    if (( ${#INSTALLED_KERNEL_RELEASES[@]} == 0 )); then
        echo " - 未识别"
    else
        for release in "${INSTALLED_KERNEL_RELEASES[@]}"; do
            echo " - $release"
        done
    fi
    echo "已安装的内核元软件包："
    if (( ${#KERNEL_META_PACKAGES[@]} == 0 )); then
        echo " - 未识别"
    else
        for package in "${KERNEL_META_PACKAGES[@]}"; do
            echo " - $package"
        done
    fi
    echo "引导分区空间："
    df -h "$boot_path" | awk 'NR==1 || NR==2'
    [[ "$reboot_state" != "需要" ]] || warn "请在清理旧内核前先重启并确认新内核运行正常。"
}

validate_planned_kernel_images() {
    local package
    local candidate
    local matched
    local -a candidate_releases=()

    for candidate in "${CANDIDATE_KERNEL_IMAGES[@]}"; do
        candidate_releases+=("$(kernel_release_from_image_package "$candidate")")
    done
    (( ${#candidate_releases[@]} > 0 )) || {
        error "未发现可用于约束更新计划的候选内核版本，已停止操作。"
        return 1
    }

    for package in "${UPDATE_UPGRADE_PACKAGES[@]}" "${UPDATE_NEW_PACKAGES[@]}"; do
        package="${package%%:*}"
        if [[ "$package" == linux-image-[0-9]* || \
              "$package" == linux-image-unsigned-[0-9]* ]]; then
            matched=0
            for candidate in "${CANDIDATE_KERNEL_IMAGES[@]}"; do
                if [[ "$package" == "${candidate%%:*}" ]]; then
                    matched=1
                    break
                fi
            done
            if [[ "$matched" == "0" ]]; then
                error "升级预览包含未由所选元包声明的内核映像 $package，已停止操作。"
                return 1
            fi
        fi
        if is_versioned_kernel_package "$package" && \
           ! kernel_versioned_package_matches_release_list "$package" candidate_releases; then
            error "升级预览包含不属于候选内核版本的关联软件包 $package，已停止操作。"
            return 1
        fi
    done
}

candidate_kernel_images_ready() {
    local package
    local release
    local require_initrd=0

    if command -v update-initramfs >/dev/null 2>&1 || command -v dracut >/dev/null 2>&1; then
        require_initrd=1
    fi
    for package in "${CANDIDATE_KERNEL_IMAGES[@]}"; do
        release=$(kernel_release_from_image_package "$package")
        if ! package_is_installed "$package"; then
            error "目标内核软件包 $package 未处于已安装状态。"
            return 1
        fi
        if [[ ! -s "/boot/vmlinuz-$release" ]]; then
            error "目标内核引导文件 /boot/vmlinuz-$release 不存在或为空。"
            return 1
        fi
        if [[ "$require_initrd" == "1" && ! -s "/boot/initrd.img-$release" ]]; then
            error "目标内核 initramfs /boot/initrd.img-$release 不存在或为空。"
            return 1
        fi
    done
}

verify_kernel_update_result() {
    local selected_meta="$1"
    local expected_version="$2"
    local current_kernel="$3"
    local installed_version
    local audit_output

    installed_version=$(get_installed_package_version "$selected_meta")
    if [[ "$installed_version" != "$expected_version" ]]; then
        error "$selected_meta 实际版本为 ${installed_version:-未知}，与预期 $expected_version 不一致。"
        return 1
    fi
    audit_output=$(dpkg --audit 2>/dev/null || true)
    if [[ -n "$audit_output" ]]; then
        error "内核更新后检测到未完成的软件包配置："
        echo "$audit_output"
        return 1
    fi
    current_kernel_boot_artifacts_are_ready "$current_kernel" || return 1
    candidate_kernel_images_ready
}

update_kernel_only() {
    local current_kernel
    local current_owner
    local current_flavor
    local installed_meta_version
    local candidate_meta_version
    local meta_source
    local package
    local approved_plan
    local final_plan

    require_commands "内核更新" apt-get apt-cache apt-mark dpkg dpkg-query awk sort uname grep || return 1
    package_manager_ready || return 1
    export DEBIAN_FRONTEND=noninteractive
    current_kernel=$(uname -r)

    if [[ ! -e "/boot/vmlinuz-$current_kernel" ]]; then
        warn "未找到当前内核的 /boot 引导文件，可能使用厂商或自定义内核；已停止自动更新。"
        return 1
    fi
    current_owner=$(dpkg-query -S "/boot/vmlinuz-$current_kernel" 2>/dev/null |
        awk -F': ' 'NR==1 {print $1}')
    current_owner="${current_owner%%:*}"
    if [[ "$current_owner" != linux-image-* && "$current_owner" != linux-image-unsigned-* ]]; then
        warn "当前运行内核不属于可识别的 linux-image 软件包；已停止自动更新。"
        return 1
    fi
    current_flavor=$(kernel_flavor_from_release "$current_kernel") || {
        warn "无法识别当前内核 $current_kernel 的内核类型；已停止自动更新。"
        return 1
    }
    select_kernel_meta_package "$current_kernel" || return 1
    [[ -n "$SELECTED_KERNEL_META" ]] || return 0
    installed_meta_version=$(get_installed_package_version "$SELECTED_KERNEL_META")
    if [[ -z "$installed_meta_version" ]]; then
        error "所选内核元软件包 $SELECTED_KERNEL_META 未处于已安装状态。"
        return 1
    fi
    if package_is_held "$SELECTED_KERNEL_META"; then
        warn "$SELECTED_KERNEL_META 已被 apt-mark hold，未自动解除锁定或执行更新。"
        return 1
    fi

    echo "当前运行内核：$current_kernel"
    echo "当前内核软件包：$current_owner"
    echo "选定更新路线：$SELECTED_KERNEL_META（已安装 $installed_meta_version）"
    echo "不会切换内核类型，也不会删除当前内核、备用内核或其他旧内核。"
    confirm_action "确认刷新软件包索引并核验该内核路线吗？" || return 0
    refresh_package_index || return 1

    candidate_meta_version=$(get_candidate_package_version "$SELECTED_KERNEL_META")
    if [[ -z "$candidate_meta_version" || "$candidate_meta_version" == "(none)" ]]; then
        error "无法获取 $SELECTED_KERNEL_META 的候选版本，已停止操作。"
        return 1
    fi
    validate_official_candidate_source "$SELECTED_KERNEL_META" "$candidate_meta_version" || return 1
    meta_source="$VALIDATED_PACKAGE_SOURCE"
    collect_candidate_kernel_images "$SELECTED_KERNEL_META" || return 1
    validate_candidate_kernel_images "$current_flavor" || return 1

    echo "内核更新目标："
    echo " - 元软件包：$SELECTED_KERNEL_META"
    echo " - 版本：$installed_meta_version → $candidate_meta_version"
    echo " - 来源：$meta_source"
    echo " - 具体内核映像："
    printf '   - %s\n' "${CANDIDATE_KERNEL_IMAGES[@]}"

    collect_update_plan kernel "$SELECTED_KERNEL_META=$candidate_meta_version" || return 1
    validate_kernel_update_plan || return 1
    validate_planned_kernel_images || return 1
    validate_kernel_update_sources || return 1

    if update_plan_is_empty; then
        if ! candidate_kernel_images_ready; then
            error "APT 未生成修复计划，但目标内核文件不完整，请先检查软件包状态。"
            return 1
        fi
        action_success "内核更新" "$SELECTED_KERNEL_META 及目标内核均已是最新状态"
        show_reboot_notice
        return 0
    fi

    echo "内核更新预览："
    print_update_plan
    detail "UPDATE" "KERNEL_PREVIEW" \
        "路线=$SELECTED_KERNEL_META；版本=$installed_meta_version->$candidate_meta_version；目标=${CANDIDATE_KERNEL_IMAGES[*]}；升级=${#UPDATE_UPGRADE_PACKAGES[@]}；新增=${#UPDATE_NEW_PACKAGES[@]}；删除=${#UPDATE_REMOVE_PACKAGES[@]}"
    approved_plan=$(update_plan_signature)
    confirm_action "确认执行以上单一路线内核更新吗？" || return 0
    package_manager_ready || return 1
    collect_update_plan kernel "$SELECTED_KERNEL_META=$candidate_meta_version" || return 1
    validate_kernel_update_plan || return 1
    validate_planned_kernel_images || return 1
    validate_kernel_update_sources || return 1
    final_plan=$(update_plan_signature)
    if [[ "$final_plan" != "$approved_plan" ]]; then
        error "最终内核更新计划与确认时不一致，已停止操作；请重新预览并确认。"
        return 1
    fi

    log "开始通过 $SELECTED_KERNEL_META 更新 $current_flavor 内核路线..."
    if ! apt-get install --only-upgrade --no-install-recommends --no-remove -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        -- "$SELECTED_KERNEL_META=$candidate_meta_version"; then
        error "内核更新失败，请检查上方 APT 输出。"
        return 1
    fi
    if ! verify_kernel_update_result \
        "$SELECTED_KERNEL_META" "$candidate_meta_version" "$current_kernel"; then
        action_partial "内核更新" "软件包操作已结束，但内核或引导文件验证失败"
        error "请勿重启，并立即检查 /boot、initramfs 与已安装内核软件包。"
        return 1
    fi
    if command -v update-grub >/dev/null 2>&1; then
        if update-grub >/dev/null 2>&1; then
            print_result "GRUB 配置刷新" "已完成"
        else
            action_partial "内核更新" "内核验证通过，但 update-grub 失败"
            error "请修复引导配置后再重启。"
            return 1
        fi
    else
        print_result "GRUB 配置刷新" "跳过" "未安装 update-grub"
    fi
    action_success "内核更新" "$SELECTED_KERNEL_META 已更新至 $candidate_meta_version；未删除任何旧内核"
    echo "目标内核映像："
    for package in "${CANDIDATE_KERNEL_IMAGES[@]}"; do
        echo " - $(kernel_release_from_image_package "$package")"
    done
    show_reboot_notice
}

submenu_updates() {
    local choice_update
    local current_kernel
    local latest_kernel
    local reboot_state

    while true; do
        current_kernel=$(uname -r)
        latest_kernel="未识别"
        collect_installed_kernel_releases
        if (( ${#INSTALLED_KERNEL_RELEASES[@]} > 0 )); then
            latest_kernel=$(latest_installed_kernel_for_current_flavor \
                "$current_kernel" "${INSTALLED_KERNEL_RELEASES[@]}" 2>/dev/null || true)
            [[ -n "$latest_kernel" ]] || latest_kernel="未识别"
        fi
        reboot_state="无需重启"
        if [[ -f /var/run/reboot-required ]] || \
           [[ "$latest_kernel" != "未识别" && "$current_kernel" != "$latest_kernel" ]]; then
            reboot_state="需要重启"
        fi

        print_header "系统更新"
        echo -e "  当前内核：${YELLOW}$current_kernel${NC}"
        echo -e "  同类型最新已安装：${YELLOW}$latest_kernel${NC}  |  状态：${YELLOW}$reboot_state${NC}"
        echo -e "${DIM}--------------------------------------------------${NC}"
        print_menu_item 1 "检查可用更新" "只刷新索引并预览"
        print_menu_item 2 "常规软件包升级" "只升级已有包，不新增、不删除"
        print_menu_item 3 "完整系统升级" "允许依赖调整，执行前预览"
        print_menu_item 4 "仅更新内核" "基于已安装的内核元软件包"
        print_menu_item 5 "查看内核与重启状态" "只读"
        echo -e "  ${DIM}0. 返回上一级${NC}"
        echo -e "${CYAN}==================================================${NC}"
        read -r -p "请输入选项 [0-5]: " choice_update

        case "$choice_update" in
            1) check_available_updates; pause_menu ;;
            2) run_package_upgrade regular; pause_menu ;;
            3) run_package_upgrade full; pause_menu ;;
            4) update_kernel_only; pause_menu ;;
            5) show_kernel_update_status; pause_menu ;;
            0) return ;;
            *) error "无效输入！"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 模块一：二级菜单 - 基础环境与系统优化
# ==========================================
submenu_env() {
    local choice_env

    while true; do
        print_header "系统维护"
        print_menu_item 1 "系统更新" "检查 / 常规 / 完整 / 内核 ›"
        print_menu_item 2 "系统清理" "缓存 / 无用包 / 旧内核 / 日志 ›"
        print_menu_item 3 "SWAP 配置" "›"
        print_menu_item 4 "时间与时区配置" "›"
        echo -e "  ${DIM}0. 返回主菜单${NC}"
        echo -e "${CYAN}==================================================${NC}"
        read -r -p "请输入选项 [0-4]: " choice_env

        case "$choice_env" in
            1) submenu_updates ;;
            2) submenu_cleanup ;;
            3) submenu_swap ;;
            4) submenu_timezone ;;
            0) return ;;
            *) error "无效输入！"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 模块二：SSH 安全设置
# ==========================================
submenu_ssh() {
    local fail2ban_synced
    local configured_ports

    require_commands "SSH 配置" \
        sshd ss systemctl timeout awk sed grep mktemp stat hostname paste readlink sleep || { pause_menu; return; }
    while true; do
        print_header "SSH 端口与登录设置"
        CURRENT_PORT=$(get_ssh_port)
        [[ -z "$CURRENT_PORT" ]] && CURRENT_PORT="未知"
        configured_ports=$(get_configured_ssh_ports)
        [[ -z "$configured_ports" ]] && configured_ports="未知"
        LISTENING_PORTS=$(get_listening_ssh_ports)
        [[ -z "$LISTENING_PORTS" ]] && LISTENING_PORTS="未检测到"
        
        PWD_AUTH=$(get_effective_root_sshd_config |
            awk '/^passwordauthentication / {print $2; exit}')
        case "$PWD_AUTH" in
            yes) PWD_STATUS="${RED}已开启（存在爆破风险）${NC}" ;;
            no) PWD_STATUS="${GREEN}已禁用${NC}" ;;
            *) PWD_STATUS="${YELLOW}未知（请先检查 sshd 配置）${NC}" ;;
        esac
        
        echo -e "配置的 SSH 端口: ${YELLOW}$configured_ports${NC}"
        echo -e "实际监听端口:     ${YELLOW}$LISTENING_PORTS${NC}"
        echo -e "密码登录状态:     $PWD_STATUS"
        echo -e "${DIM}--------------------------------------------------${NC}"
        print_menu_item 1 "修改 SSH 端口" "冲突检测、监听验证与完整回滚"
        print_menu_item 2 "启用密钥登录并禁用密码" "验证公钥后应用"
        echo -e "  ${DIM}0. 返回上一级${NC}"
        echo -e "${CYAN}==================================================${NC}"
        read -r -p "请输入选项 [0-2]: " choice_ssh

        case "$choice_ssh" in
            1)
                read -r -p "请输入新的 SSH 端口号 (22 或 1024-65535): " new_port
                if ! is_valid_ssh_port "$new_port"; then
                    error "端口号无效！请输入 22，或 1024 到 65535 之间的纯数字。"
                    pause_menu; continue
                fi

                if [[ "$configured_ports" == "$new_port" && "$LISTENING_PORTS" == "$new_port" ]]; then
                    log "SSH 当前已配置为端口 $new_port，无需修改。"
                    pause_menu; continue
                fi
                if tcp_port_is_listening "$new_port"; then
                    case ",$configured_ports," in
                        *",$new_port,"*)
                            if ! ssh_port_accepts_loopback "$new_port"; then
                                error "端口 $new_port 已监听，但无法确认监听者是 SSH；请更换端口。"
                                pause_menu; continue
                            fi
                            ;;
                        *)
                            error "TCP 端口 $new_port 已被占用，请更换端口！"
                            pause_menu; continue
                            ;;
                    esac
                fi

                echo "SSH 端口将从 $CURRENT_PORT 修改为 $new_port。"
                warn "请先确认云安全组和防火墙已放行新端口；应用时 SSH 服务会重启。"
                confirm_action "确认修改 SSH 端口吗？" || continue

                log "正在备份 SSH 配置和服务状态..."
                if ! begin_ssh_transaction; then
                    error "SSH 备份失败，未修改任何配置。"
                    pause_menu; continue
                fi

                if ! ensure_ssh_managed_include || ! write_sshd_key Port "$new_port"; then
                    rollback_ssh_with_message "SSH 托管配置写入失败"
                    pause_menu; continue
                fi

                configured_ports=$(get_configured_ssh_ports)
                if ! sshd -t 2>/dev/null || [[ "$configured_ports" != "$new_port" ]]; then
                    rollback_ssh_with_message "SSH 语法或生效配置验证失败"
                    pause_menu; continue
                fi

                if ! restart_ssh "$new_port"; then
                    rollback_ssh_with_message "SSH 服务重启失败"
                    pause_menu; continue
                fi

                sleep 1
                configured_ports=$(get_configured_ssh_ports)
                LISTENING_PORTS=$(get_listening_ssh_ports)
                if ! ssh_uses_only_port "$new_port" "$configured_ports" "$LISTENING_PORTS" || \
                   ! ssh_port_accepts_loopback "$new_port"; then
                    rollback_ssh_with_message "SSH 未能仅监听目标端口 $new_port（配置=${configured_ports:-未知}；监听=${LISTENING_PORTS:-未检测到}）"
                    pause_menu; continue
                fi

                fail2ban_synced=1
                sync_fail2ban_ssh_port "$new_port" || fail2ban_synced=0
                if [[ "$fail2ban_synced" == "1" ]]; then
                    action_success "SSH 端口" "$CURRENT_PORT → $new_port；实际监听：${LISTENING_PORTS:-未知}；备份：$SSH_BACKUP_PATH"
                else
                    action_partial "SSH 端口" "已切换为 $new_port，但 Fail2ban 端口同步失败"
                fi
                warn "请先在新终端使用端口 $new_port 登录成功，再关闭当前会话；同时确认云安全组和防火墙已放行。"
                pause_menu
                ;;
                
            2)
                if ! has_valid_root_authorized_key; then
                    error "检测失败！未发现可由 ssh-keygen 识别的 root SSH 公钥。"
                    error "请先在本地终端执行 'ssh-copy-id -p 端口 root@IP' 上传公钥！"
                    pause_menu; continue
                fi
                if ! root_authorized_keys_path_is_effective; then
                    error "SSH 当前生效的 AuthorizedKeysFile 不包含 /root/.ssh/authorized_keys，无法确认该公钥会被使用。"
                    pause_menu; continue
                fi
                if ! root_authorized_keys_permissions_are_safe; then
                    error "/root、/root/.ssh 或 authorized_keys 的所有者/权限不符合 StrictModes 安全要求，未禁用密码登录。"
                    echo "请确保三者均归 root 所有，且组用户和其他用户没有写权限。"
                    pause_menu; continue
                fi

                warn "服务器端只能确认公钥文件有效，无法确认你仍持有对应私钥。"
                warn "请先保持当前会话，并在另一终端完成一次密钥登录测试。"
                confirm_action "确认已在另一终端使用该密钥登录成功，并禁用密码与键盘交互登录吗？" || continue

                log "正在备份并配置密钥登录..."
                if ! begin_ssh_transaction; then
                    error "SSH 备份失败，未修改任何配置。"
                    pause_menu; continue
                fi

                if ! ensure_ssh_managed_include || \
                   ! write_sshd_keys_atomic \
                       PubkeyAuthentication yes \
                       PasswordAuthentication no \
                       KbdInteractiveAuthentication no \
                       ChallengeResponseAuthentication no; then
                    rollback_ssh_with_message "SSH 登录配置写入失败"
                    pause_menu; continue
                fi

                if ! sshd -t 2>/dev/null || ! root_key_only_login_is_safe; then
                    rollback_ssh_with_message "SSH 登录配置验证失败"
                    pause_menu; continue
                fi

                if ! restart_ssh; then
                    rollback_ssh_with_message "SSH 服务重启失败"
                    pause_menu; continue
                fi

                action_success "SSH 密钥登录" "密码与键盘交互登录已禁用；备份：$SSH_BACKUP_PATH"
                warn "请再次在新终端验证密钥登录成功后，再关闭当前会话。"
                pause_menu
                ;;
                
            0) return ;;
            *) error "无效输入！"; sleep 1; continue ;;
        esac
    done
}

# ==========================================
# 模块二：二级菜单 - 系统安全与防护
# ==========================================
submenu_sec() {
    local command_output
    local command_status
    local allow_ubuntu_esm_apps

    while true; do
        print_header "SSH 与安全"
        print_menu_item 1 "SSH 端口与登录设置" "›"
        print_menu_item 2 "安装或更新 Fail2ban" "SSH 防爆破"
        echo -e "  ${DIM}0. 返回主菜单${NC}"
        echo -e "${CYAN}==================================================${NC}"
        read -r -p "请输入选项 [0-2]: " choice_sec

        case "$choice_sec" in
            1) submenu_ssh ;;
            2) 
                require_commands "Fail2ban 安装" apt-get systemctl || { pause_menu; continue; }
                package_manager_ready || { pause_menu; continue; }
                CURRENT_PORT=$(get_configured_ssh_ports)
                if [[ -z "$CURRENT_PORT" ]]; then
                    error "无法读取 SSH 当前生效端口，未执行 Fail2ban 安装或配置。"
                    pause_menu; continue
                fi
                echo "将安装或更新 Fail2ban，并在现有 jail.local 中为 SSH 端口 $CURRENT_PORT 增量配置防爆破规则。"
                allow_ubuntu_esm_apps=0
                if [[ "$OS_ID" == "ubuntu" && "$OS_MAINTENANCE_CODE" == "esm" ]]; then
                    if ! ubuntu_pro_esm_apps_is_active; then
                        error "Ubuntu $OS_VERSION 的 Fail2ban 来自 Universe；当前无法确认 ESM Apps：${UBUNTU_PRO_ESM_STATUS_REASON:-状态未知}。"
                        echo "请先使用 'pro status --all' 确认 esm-apps 为 enabled；脚本不会自动启用订阅服务。"
                        pause_menu; continue
                    fi
                    allow_ubuntu_esm_apps=1
                fi
                confirm_action "确认继续配置 Fail2ban 吗？" || continue
                export DEBIAN_FRONTEND=noninteractive
                echo -e "${YELLOW}正在更新源并安装 Fail2ban，请稍候...${NC}"
                command_output=$(apt_update_strict 2>&1)
                command_status=$?
                if (( command_status != 0 )); then
                    detail "FAIL2BAN" "APT_UPDATE" "退出码=$command_status；输出=${command_output:-无}"
                    error "软件包索引刷新失败，请检查所有已启用的软件源。"
                    pause_menu; continue
                fi
                validate_official_package_install_plan \
                    "Fail2ban" "$allow_ubuntu_esm_apps" fail2ban || { pause_menu; continue; }
                command_output=$(apt-get install --no-remove -y -- fail2ban 2>&1)
                command_status=$?
                if (( command_status != 0 )); then
                    detail "FAIL2BAN" "INSTALL" "退出码=$command_status；输出=${command_output:-无}"
                    error "Fail2ban 安装失败！"
                    pause_menu; continue
                fi

                log "正在配置防爆破规则..."
                # 后端、过滤器与日志来源继承发行版或用户现有配置；systemd 后端不接受 logpath。
                if ! update_fail2ban_sshd_jail "$CURRENT_PORT" full 1; then
                    pause_menu; continue
                fi

                action_success "Fail2ban" "配置语法与 sshd jail 运行状态验证通过；SSH 端口：$CURRENT_PORT"
                pause_menu
                ;;
            0) return ;;
            *) error "无效输入！"; sleep 1; continue ;;
        esac
    done
}

# ==========================================
# 模块三：DNS 设置
# ==========================================
show_dns_status() {
    local dns_output
    local resolver_mode

    if systemctl is-active systemd-resolved >/dev/null 2>&1 && command -v resolvectl >/dev/null 2>&1; then
        resolver_mode=$(get_resolved_resolv_conf_mode)
        printf ' - 解析路径：systemd-resolved（%s）\n' "$resolver_mode"
        if [[ "$resolver_mode" == "foreign" ]]; then
            echo -e " - ${YELLOW}实际 resolv.conf 未连接到 systemd-resolved${NC}"
            dns_output=$(grep -E '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null |
                awk '{print $2}')
        else
            dns_output=$(resolvectl dns 2>/dev/null)
        fi
    else
        if [[ -L /etc/resolv.conf ]]; then
            printf ' - 解析路径：resolv.conf → %s\n' "$(readlink -f /etc/resolv.conf 2>/dev/null || printf 未知)"
        else
            echo " - 解析路径：静态 /etc/resolv.conf"
        fi
        dns_output=$(grep -E '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null | awk '{print $2}')
    fi
    if [[ -n "$dns_output" ]]; then
        while IFS= read -r dns_line; do
            printf ' - %s\n' "$dns_line"
        done <<< "$dns_output"
    else
        echo -e " - ${YELLOW}未检测到有效 DNS 状态${NC}"
    fi
}

get_default_network_interface() {
    local interface_name

    interface_name=$(get_default_route_interface 4)
    if [[ -z "$interface_name" ]]; then
        interface_name=$(get_default_route_interface 6)
    fi
    printf '%s' "$interface_name"
}

get_default_route_interface() {
    local family="$1"

    ip -o "-$family" route show default 2>/dev/null | awk '
        {
            for (i=1; i<NF; i++) {
                if ($i == "dev") {
                    print $(i+1)
                    exit
                }
            }
        }'
}

get_default_route_gateway() {
    local family="$1"

    ip -o "-$family" route show default 2>/dev/null | awk '
        {
            for (i=1; i<NF; i++) {
                if ($i == "via") {
                    print $(i+1)
                    exit
                }
            }
        }'
}

get_route_gateway_from_text() {
    awk '
        {
            for (i=1; i<NF; i++) {
                if ($i == "via") {
                    print $(i+1)
                    exit
                }
            }
        }' <<< "$1"
}

dns_default_routes_share_interface() {
    local ipv4_interface="$1"
    local ipv6_interface="$2"

    [[ -z "$ipv4_interface" || -z "$ipv6_interface" || \
       "$ipv4_interface" == "$ipv6_interface" ]]
}

netplan_interface_name_is_safe() {
    [[ "$1" =~ ^[A-Za-z0-9_-]{1,15}$ ]]
}

get_resolved_resolv_conf_mode() {
    local resolved_target

    if [[ -L /etc/resolv.conf ]]; then
        resolved_target=$(readlink -f /etc/resolv.conf 2>/dev/null)
        case "$resolved_target" in
            /run/systemd/resolve/stub-resolv.conf) printf stub ;;
            /run/systemd/resolve/resolv.conf) printf uplink ;;
            *) printf foreign ;;
        esac
    elif grep -Eq '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.(53|54)([[:space:]]|$)' \
        /etc/resolv.conf 2>/dev/null; then
        printf stub-static
    else
        printf foreign
    fi
}

validate_dns_address() {
    local address="$1"
    local octet
    local part
    local part_count=0
    local ipv4_tail
    local ipv6_prefix
    local -a ipv4_octets=()
    local -a ipv6_parts=()

    if [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a ipv4_octets <<< "$address"
        for octet in "${ipv4_octets[@]}"; do
            [[ "${#octet}" == "1" || "${octet:0:1}" != "0" ]] || return 1
            (( 10#$octet <= 255 )) || return 1
        done
        return 0
    fi

    [[ "$address" == *:* ]] || return 1
    if [[ "$address" == *.* ]]; then
        ipv4_tail="${address##*:}"
        ipv6_prefix="${address%:*}"
        [[ "$ipv6_prefix" != "$address" ]] || return 1
        validate_dns_address "$ipv4_tail" || return 1
        address="${ipv6_prefix}:0:0"
    fi
    [[ "$address" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "$address" != *:::* ]] || return 1
    [[ "$address" != :* || "$address" == ::* ]] || return 1
    [[ "$address" != *: || "$address" == *:: ]] || return 1

    if [[ "$address" == *::* ]]; then
        [[ "${address#*::}" != *::* ]] || return 1
    fi
    IFS=':' read -r -a ipv6_parts <<< "$address"
    for part in "${ipv6_parts[@]}"; do
        [[ -z "$part" ]] && continue
        (( ${#part} <= 4 )) || return 1
        part_count=$((part_count + 1))
    done

    if [[ "$address" == *::* ]]; then
        (( part_count < 8 ))
    else
        (( part_count == 8 ))
    fi
}

canonicalize_ip_address() {
    local address="$1"
    local ipv4_tail
    local ipv6_prefix
    local left
    local right
    local part
    local normalized
    local output=""
    local missing=0
    local numeric
    local first_pair
    local second_pair
    local -a octets=()
    local -a left_parts=()
    local -a right_parts=()
    local -a full_parts=()

    validate_dns_address "$address" || return 1
    if [[ "$address" != *:* ]]; then
        printf '%s' "$address"
        return 0
    fi

    if [[ "$address" == *.* ]]; then
        ipv4_tail="${address##*:}"
        ipv6_prefix="${address%:*}"
        IFS='.' read -r -a octets <<< "$ipv4_tail"
        first_pair=$((10#${octets[0]} * 256 + 10#${octets[1]}))
        second_pair=$((10#${octets[2]} * 256 + 10#${octets[3]}))
        printf -v first_pair '%x' "$first_pair"
        printf -v second_pair '%x' "$second_pair"
        address="${ipv6_prefix}:${first_pair}:${second_pair}"
    fi

    if [[ "$address" == *::* ]]; then
        left="${address%%::*}"
        right="${address#*::}"
        [[ -z "$left" ]] || IFS=':' read -r -a left_parts <<< "$left"
        [[ -z "$right" ]] || IFS=':' read -r -a right_parts <<< "$right"
        missing=$((8 - ${#left_parts[@]} - ${#right_parts[@]}))
        (( missing > 0 )) || return 1
        full_parts=("${left_parts[@]}")
        while (( missing > 0 )); do
            full_parts+=(0)
            missing=$((missing - 1))
        done
        full_parts+=("${right_parts[@]}")
    else
        IFS=':' read -r -a full_parts <<< "$address"
        (( ${#full_parts[@]} == 8 )) || return 1
    fi

    (( ${#full_parts[@]} == 8 )) || return 1
    for part in "${full_parts[@]}"; do
        [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        numeric=$((16#$part))
        printf -v normalized '%04x' "$numeric"
        output+="${output:+:}$normalized"
    done
    printf '%s' "$output"
}

dns_address_is_usable_server() {
    local address="$1"
    local canonical
    local first_part
    local first_value
    local first_octet

    validate_dns_address "$address" || return 1
    if [[ "$address" != *:* ]]; then
        first_octet="${address%%.*}"
        (( 10#$first_octet > 0 && 10#$first_octet < 224 ))
        return
    fi

    canonical=$(canonicalize_ip_address "$address") || return 1
    [[ "$canonical" != "0000:0000:0000:0000:0000:0000:0000:0000" ]] || return 1
    first_part="${canonical%%:*}"
    first_value=$((16#$first_part))
    (( (first_value & 16#ff00) != 16#ff00 )) || return 1
    # Link-local DNS servers require an explicit interface scope, which this
    # global DNS workflow intentionally does not accept.
    (( (first_value & 16#ffc0) != 16#fe80 ))
}

render_static_resolv_conf() {
    local source_file="$1"
    local output_file="$2"
    local dns_line="$3"
    local dns_server

    {
        for dns_server in $dns_line; do
            printf 'nameserver %s\n' "$dns_server"
        done
        if [[ -f "$source_file" ]]; then
            awk '!/^[[:space:]]*nameserver[[:space:]]+/' "$source_file"
        fi
    } > "$output_file"
}

backup_dns_file() {
    local target="$1"
    local index="${#DNS_CHANGED_FILES[@]}"
    local backup
    local existed=0

    backup="$DNS_BACKUP_PATH/$index-$(basename "$target")"

    if [[ -e "$target" || -L "$target" ]]; then
        existed=1
        cp -a -- "$target" "$backup" || return 1
    fi
    DNS_CHANGED_FILES+=("$target")
    DNS_BACKUP_FILES+=("$backup")
    DNS_FILE_EXISTED+=("$existed")
}

restore_dns_files() {
    local index
    local target
    local failed=0
    local command_output
    local command_status
    local -a restored_dns=()
    local -a restored_domains=()

    detail "DNS" "ROLLBACK" "开始恢复 ${#DNS_CHANGED_FILES[@]} 个配置项；备份目录=$DNS_BACKUP_PATH"

    for (( index=${#DNS_CHANGED_FILES[@]}-1; index>=0; index-- )); do
        target="${DNS_CHANGED_FILES[$index]}"
        [[ "$target" == "/etc/resolv.conf" ]] && chattr -i "$target" >/dev/null 2>&1 || true
        if ! rm -f -- "$target"; then
            detail "DNS" "ROLLBACK" "无法移除待恢复文件：$target"
            failed=1
        fi
        if [[ "${DNS_FILE_EXISTED[$index]}" == "1" ]]; then
            if ! mkdir -p "$(dirname "$target")" || \
               ! cp -a -- "${DNS_BACKUP_FILES[$index]}" "$target"; then
                detail "DNS" "ROLLBACK" "文件恢复失败：目标=$target，备份=${DNS_BACKUP_FILES[$index]}"
                failed=1
            fi
        fi
    done

    if [[ "$DNS_NETPLAN_CONFIGURED" == "1" ]] && command -v netplan >/dev/null 2>&1; then
        command_output=$(netplan generate 2>&1)
        command_status=$?
        if (( command_status != 0 )); then
            detail "DNS" "ROLLBACK_NETPLAN" "恢复 YAML 后 netplan generate 失败，退出码=$command_status，输出=${command_output:-无}"
            failed=1
        fi
    fi

    if [[ "$DNS_RESOLVED_ACTIVE" == "1" ]]; then
        command_output=$(timeout 30 systemctl restart systemd-resolved 2>&1)
        command_status=$?
        if (( command_status != 0 )); then
            detail "DNS" "ROLLBACK_RESOLVED" "systemd-resolved 重启失败，退出码=$command_status，输出=${command_output:-无}"
            failed=1
        fi
        if command -v resolvectl >/dev/null 2>&1; then
            for target in "${DNS_RESOLVED_LINKS[@]}"; do
                resolvectl revert "$target" >/dev/null 2>&1 || failed=1
                if [[ -n "${DNS_LINK_DNS_BEFORE[$target]:-}" ]]; then
                    read -r -a restored_dns <<< "${DNS_LINK_DNS_BEFORE[$target]}"
                    resolvectl dns "$target" "${restored_dns[@]}" >/dev/null 2>&1 || failed=1
                fi
                if [[ -n "${DNS_LINK_DOMAINS_BEFORE[$target]:-}" ]]; then
                    read -r -a restored_domains <<< "${DNS_LINK_DOMAINS_BEFORE[$target]}"
                    resolvectl domain "$target" "${restored_domains[@]}" >/dev/null 2>&1 || failed=1
                fi
            done
        fi
    fi
    if [[ "$DNS_RESOLV_WAS_IMMUTABLE" == "1" ]] && ! chattr +i /etc/resolv.conf >/dev/null 2>&1; then
        detail "DNS" "ROLLBACK_RESOLV_CONF" "无法恢复 /etc/resolv.conf 的不可变属性"
        failed=1
    fi
    if [[ "$failed" == "0" ]]; then
        detail "DNS" "ROLLBACK" "配置文件及相关服务状态恢复成功"
    else
        detail "DNS" "ROLLBACK" "恢复流程存在失败项，请使用备份目录手动核对"
    fi
    return "$failed"
}

rollback_dns_with_message() {
    local message="$1"

    detail "DNS" "ROLLBACK" "触发原因=$message；备份目录=$DNS_BACKUP_PATH"
    if restore_dns_files; then
        error "$message，原 DNS 配置已恢复。"
    else
        error "$message，自动回滚不完整，请从 $DNS_BACKUP_PATH 手动恢复。"
    fi
}

interfaces_ipv4_method_from_file() {
    local file="$1"
    local interface="$2"

    awk -v iface="$interface" '
        $1 == "iface" && $2 == iface && $3 == "inet" {
            count++
            method=tolower($4)
        }
        END {
            if (count == 1 && method != "") {
                print method
                exit 0
            }
            exit 1
        }
    ' "$file"
}

interfaces_file_is_loaded() {
    local file="$1"
    local root_file="${2:-/etc/network/interfaces}"
    local root_dir
    local canonical_file
    local directive
    local source_path
    local normalized_pattern
    local file_dir
    local file_name

    [[ -f "$root_file" ]] || return 1
    root_dir=$(dirname "$root_file")
    canonical_file=$(readlink -m -- "$file" 2>/dev/null) || return 1
    root_file=$(readlink -m -- "$root_file" 2>/dev/null) || return 1
    root_dir=$(readlink -m -- "$root_dir" 2>/dev/null) || return 1
    [[ "$canonical_file" == "$root_file" ]] && return 0
    [[ "$canonical_file" == "$root_dir"/* ]] || return 1
    file_dir=$(dirname "$canonical_file")
    file_name=$(basename "$canonical_file")

    while IFS=$'\t' read -r directive source_path; do
        [[ -n "$directive" && -n "$source_path" ]] || continue
        [[ "$source_path" =~ ^[[:alnum:]_./*?\[\]-]+$ ]] || continue
        if [[ "$source_path" != /* ]]; then
            source_path="$root_dir/$source_path"
        fi
        normalized_pattern=$(readlink -m -- "$source_path" 2>/dev/null || true)
        [[ -n "$normalized_pattern" ]] || continue
        case "$directive" in
            source)
                [[ "$canonical_file" == $normalized_pattern ]] && return 0
                ;;
            source-directory)
                if [[ "$file_dir" == $normalized_pattern && \
                      "$file_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
                    return 0
                fi
                ;;
        esac
    done < <(
        awk '
            $1 == "source" || $1 == "source-directory" {
                for (index=2; index<=NF; index++) {
                    print $1 "\t" $index
                }
            }
        ' "$root_file"
    )
    return 1
}

sync_interfaces_dns() {
    local dns_line="$1"
    local resolver_mode="${2:-inactive}"
    local default_iface
    local file
    local target_file=""
    local temp_file
    local -a interface_files=()
    local -a matches=()

    local section_count=0

    default_iface=$(get_default_network_interface)
    [[ -n "$default_iface" ]] || return 0
    [[ -f /etc/network/interfaces ]] && interface_files+=(/etc/network/interfaces)
    if [[ -d /etc/network/interfaces.d ]]; then
        while IFS= read -r -d '' file; do
            interfaces_file_is_loaded "$file" && interface_files+=("$file")
        done < <(find /etc/network/interfaces.d -maxdepth 1 -type f -print0 2>/dev/null)
    fi

    for file in "${interface_files[@]}"; do
        section_count=$(awk -v iface="$default_iface" \
            '$1 == "iface" && $2 == iface && $3 == "inet" {count++} END {print count+0}' "$file")
        if (( section_count > 0 )); then
            matches+=("$file")
            if (( section_count > 1 )); then
                warn "$file 中多次定义默认网卡 $default_iface，已跳过 interfaces 自动修改。"
                return 0
            fi
        fi
    done

    if (( ${#matches[@]} > 1 )); then
        echo -e "${YELLOW}多个 interfaces 文件定义默认网卡 $default_iface，已跳过自动修改：${NC}"
        printf ' - %s\n' "${matches[@]}"
        return 0
    elif (( ${#matches[@]} == 0 )); then
        return 0
    fi

    target_file="${matches[0]}"
    if [[ -L "$target_file" ]]; then
        warn "$target_file 是符号链接，已跳过自动修改；后续会验证 DNS 是否真正生效。"
        return 0
    fi
    DNS_INTERFACES_FILE="$target_file"
    if ! DNS_INTERFACES_METHOD=$(interfaces_ipv4_method_from_file "$target_file" "$default_iface"); then
        error "无法可靠识别 $target_file 中默认网卡 $default_iface 的 IPv4 配置方式，未修改 DNS。"
        detail "DNS" "WRITE_INTERFACES" "无法解析唯一 iface stanza；文件=$target_file；接口=$default_iface"
        return 1
    fi
    if [[ "$resolver_mode" == "static" && "$DNS_INTERFACES_METHOD" == "dhcp" ]]; then
        error "默认网卡 $default_iface 使用 ifupdown DHCP，但当前为普通静态 resolv.conf；dns-nameservers 需要解析器钩子才能可靠持久化，未自动修改。"
        detail "DNS" "WRITE_INTERFACES" "拒绝无法验证的 DHCP 持久化；文件=$target_file；接口=$default_iface；方法=$DNS_INTERFACES_METHOD；解析路径=$resolver_mode"
        return 1
    fi
    backup_dns_file "$target_file" || return 1
    temp_file=$(mktemp "$(dirname "$target_file")/.vps-init-interfaces.XXXXXX") || return 1
    if ! awk -v iface="$default_iface" -v dns="$dns_line" '
        $1 == "iface" && $2 == iface && $3 == "inet" {
            in_target=1
            print
            print "    dns-nameservers " dns
            next
        }
        in_target && $1 == "iface" {
            in_target=0
        }
        in_target && $1 == "dns-nameservers" {
            next
        }
        { print }
    ' "$target_file" > "$temp_file" || \
       ! chmod --reference="$target_file" "$temp_file" || \
       ! chown --reference="$target_file" "$temp_file" || \
       ! mv -f -- "$temp_file" "$target_file"; then
        rm -f "$temp_file"
        return 1
    fi
    rm -f "$temp_file"
    DNS_INTERFACES_CONFIGURED=1
    log "已同步 $target_file 中默认网卡 $default_iface 的 DNS。"
    [[ "$target_file" == *50-cloud-init* ]] && echo -e "${YELLOW}注意：该文件由 cloud-init 生成，云平台后续启动时仍可能覆盖它。${NC}"
    return 0
}

netplan_dns_override_is_managed() {
    local file="$1"

    [[ -f "$file" && ! -L "$file" ]] || return 1
    grep -Fxq -- "$NETPLAN_DNS_MANAGED_MARKER" "$file" && return 0

    # Compatibility with the exact DNS-only file shape written by older vps-init versions.
    awk '
        /^[[:space:]]*$/ {next}
        /^[[:space:]]*network:[[:space:]]*$/ {network=1; next}
        /^[[:space:]]*version:[[:space:]]*2[[:space:]]*$/ {version=1; next}
        /^[[:space:]]*ethernets:[[:space:]]*$/ {ethernets=1; next}
        /^[[:space:]]*"[A-Za-z0-9_-]+"[[:space:]]*:[[:space:]]*$/ {interface=1; next}
        /^[[:space:]]*nameservers:[[:space:]]*$/ {nameservers=1; next}
        /^[[:space:]]*addresses:[[:space:]]*\[[^]]+\][[:space:]]*$/ {addresses=1; next}
        /^[[:space:]]*dhcp[46]-overrides:[[:space:]]*$/ {next}
        /^[[:space:]]*use-dns:[[:space:]]*false[[:space:]]*$/ {next}
        {unsafe=1}
        END {exit !(network && version && ethernets && interface && nameservers && addresses && !unsafe)}
    ' "$file"
}

netplan_configuration_is_present() {
    local config_dir
    local config_file

    for config_dir in /lib/netplan /etc/netplan /run/netplan; do
        [[ -d "$config_dir" ]] || continue
        config_file=$(find -P "$config_dir" -maxdepth 1 \
            \( -type f -o -type l \) -name '*.yaml' -print -quit 2>/dev/null || true)
        [[ -n "$config_file" ]] && return 0
    done
    return 1
}

netplan_get_is_supported() {
    command -v netplan >/dev/null 2>&1 || return 1
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 netplan get --help >/dev/null 2>&1
    else
        netplan get --help >/dev/null 2>&1
    fi
}

netplan_default_interface_uses_networkmanager() {
    local default_iface
    local renderer=""

    command -v netplan >/dev/null 2>&1 || return 1
    netplan_configuration_is_present || return 1
    netplan_get_is_supported || return 1
    default_iface=$(get_default_network_interface)
    if [[ -n "$default_iface" ]] && netplan_interface_name_is_safe "$default_iface"; then
        renderer=$(netplan get "ethernets.${default_iface}.renderer" 2>/dev/null || true)
    fi
    renderer=$(tr -d '[:space:]"' <<< "$renderer" | tr '[:upper:]' '[:lower:]')
    if [[ -z "$renderer" || "$renderer" == "null" ]]; then
        renderer=$(netplan get renderer 2>/dev/null || true)
        renderer=$(tr -d '[:space:]"' <<< "$renderer" | tr '[:upper:]' '[:lower:]')
    fi
    [[ "$renderer" == "networkmanager" ]]
}

sync_netplan_dns() {
    local dns_line="$1"
    local dns_csv="${dns_line// /, }"
    local default_iface
    local override_file="/etc/netplan/99-vps-init-dns.yaml"
    local dhcp4
    local dhcp6
    local command_output
    local command_status
    local merged_dns
    local effective_use_dns
    local temp_file

    netplan_configuration_is_present || return 0
    if ! netplan_get_is_supported; then
        error "检测到 Netplan 配置，但当前 netplan 不支持 get 子命令；无法安全验证合并后的网络配置。"
        detail "DNS" "WRITE_NETPLAN" "netplan get 不可用；请先从当前系统官方仓库更新 netplan.io"
        return 1
    fi
    if [[ -e /etc/netplan && ! -d /etc/netplan ]]; then
        error "/etc/netplan 不是目录，已停止 DNS 配置。"
        return 1
    fi
    if [[ ! -d /etc/netplan ]] && ! mkdir -m 755 -- /etc/netplan; then
        error "无法创建 /etc/netplan，已停止 DNS 配置。"
        return 1
    fi
    if [[ -L "$override_file" ]]; then
        error "$override_file 是符号链接，为避免修改未知目标已停止 DNS 配置。"
        return 1
    fi
    if [[ -e "$override_file" ]] && ! netplan_dns_override_is_managed "$override_file"; then
        error "$override_file 已存在但不是可识别的 vps-init DNS 托管文件，未自动覆盖。"
        return 1
    fi

    default_iface=$(get_default_network_interface)
    if [[ -n "$default_iface" ]] && ! netplan_interface_name_is_safe "$default_iface"; then
        error "默认网卡名称 $default_iface 无法安全映射到 Netplan 配置路径，未自动接管 DNS。"
        detail "DNS" "WRITE_NETPLAN" "接口名不符合安全路径规则；接口=$default_iface"
        return 1
    fi
    if [[ -z "$default_iface" ]] || ! netplan get "ethernets.${default_iface}" >/dev/null 2>&1; then
        error "检测到 Netplan，但无法将默认网卡唯一映射到 ethernets 配置；未自动接管 DNS。"
        detail "DNS" "WRITE_NETPLAN" "默认接口=${default_iface:-未检测到}；可能使用 match/set-name、bridge、bond、VLAN 或其他复杂拓扑"
        return 1
    fi

    backup_dns_file "$override_file" || return 1
    DNS_NETPLAN_CONFIGURED=1
    dhcp4=$(netplan get "ethernets.${default_iface}.dhcp4" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    dhcp6=$(netplan get "ethernets.${default_iface}.dhcp6" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    temp_file=$(mktemp /etc/netplan/.vps-init-dns.XXXXXX) || return 1
    if ! {
        echo "$NETPLAN_DNS_MANAGED_MARKER"
        echo "network:"
        echo "  version: 2"
        echo "  ethernets:"
        printf '    "%s":\n' "$default_iface"
        echo "      nameservers:"
        echo "        addresses: [$dns_csv]"
        if [[ "$dhcp4" == "true" ]]; then
            echo "      dhcp4-overrides:"
            echo "        use-dns: false"
        fi
        if [[ "$dhcp6" == "true" ]]; then
            echo "      dhcp6-overrides:"
            echo "        use-dns: false"
        fi
    } > "$temp_file" || \
       ! chmod 600 "$temp_file" || \
       ! chown root:root "$temp_file" || \
       ! mv -f -- "$temp_file" "$override_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
    command_output=$(netplan generate 2>&1)
    command_status=$?
    if (( command_status != 0 )); then
        detail "DNS" "WRITE_NETPLAN" "netplan generate 失败，退出码=$command_status，输出=${command_output:-无}"
        return 1
    fi
    command_output=$(netplan get "ethernets.${default_iface}.nameservers.addresses" 2>&1)
    command_status=$?
    if (( command_status != 0 )); then
        detail "DNS" "WRITE_NETPLAN" "无法读取合并后的 DNS，退出码=$command_status，输出=${command_output:-无}"
        return 1
    fi
    merged_dns=$(tr '[],"' '    ' <<< "$command_output")
    if ! dns_text_uses_exact_servers "$merged_dns" "$dns_line"; then
        detail "DNS" "WRITE_NETPLAN" "Netplan 列表合并后仍含旧 DNS；请求=$dns_line；合并结果=${command_output:-无}"
        error "Netplan 现有 YAML 中还定义了其他静态 DNS；为避免跨文件列表追加，未自动覆盖原配置。"
        return 1
    fi
    if [[ "$dhcp4" == "true" ]]; then
        effective_use_dns=$(netplan get "ethernets.${default_iface}.dhcp4-overrides.use-dns" 2>/dev/null |
            tr '[:upper:]' '[:lower:]')
        [[ "$effective_use_dns" == "false" ]] || {
            error "Netplan 合并后的 DHCPv4 use-dns 未关闭，持久化验证失败。"
            return 1
        }
    fi
    if [[ "$dhcp6" == "true" ]]; then
        effective_use_dns=$(netplan get "ethernets.${default_iface}.dhcp6-overrides.use-dns" 2>/dev/null |
            tr '[:upper:]' '[:lower:]')
        [[ "$effective_use_dns" == "false" ]] || {
            error "Netplan 合并后的 DHCPv6 use-dns 未关闭，持久化验证失败。"
            return 1
        }
    fi
    detail "DNS" "WRITE_NETPLAN" "接口=$default_iface；配置=$override_file；DHCPv4=$dhcp4；DHCPv6=$dhcp6；DNS=$dns_csv；仅执行 generate，未重载网卡"
    log "已写入并验证 $default_iface 的 netplan DNS 持久化配置；本次不重载网卡。"
}

persist_dns_network_layer() {
    local dns_line="$1"
    local resolver_mode="${2:-inactive}"

    if ! sync_netplan_dns "$dns_line"; then
        detail "DNS" "WRITE_NETPLAN" "netplan 持久化配置写入或验证失败；请求=$dns_line"
        return 1
    fi
    if [[ "$DNS_NETPLAN_CONFIGURED" == "0" ]] && \
       ! sync_interfaces_dns "$dns_line" "$resolver_mode"; then
        detail "DNS" "WRITE_INTERFACES" "interfaces 持久化配置写入失败；请求=$dns_line"
        return 1
    fi
    return 0
}

extract_dns_address() {
    local token="$1"
    local address

    address="${token%%#*}"
    address="${address%%\%*}"
    if [[ "$address" =~ ^\[([^]]+)\]:[0-9]+$ ]]; then
        address="${BASH_REMATCH[1]}"
    elif [[ "$address" =~ ^([0-9.]+):[0-9]+$ ]]; then
        address="${BASH_REMATCH[1]}"
    fi
    printf '%s' "$address"
}

sanitize_resolved_dns_servers() {
    local servers="$1"
    local token
    local address
    local output=""
    local -A seen=()

    for token in $servers; do
        address=$(extract_dns_address "$token")
        validate_dns_address "$address" || continue
        [[ -z "${seen[$address]+x}" ]] || continue
        seen[$address]=1
        output+="${output:+ }$address"
    done
    printf '%s' "$output"
}

sanitize_resolved_dns_server_tokens() {
    local servers="$1"
    local token
    local endpoint
    local address
    local server_name
    local scope
    local port
    local output=""
    local canonical
    local dedupe_key
    local -A seen=()

    for token in $servers; do
        [[ "$token" != -* ]] || continue
        endpoint="${token%%#*}"
        if [[ "$token" == *#* ]]; then
            server_name="${token#*#}"
            [[ -n "$server_name" && "$server_name" != -* && \
               "$server_name" =~ ^([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+\.?$ ]] || continue
        fi
        if [[ "$endpoint" == *%* ]]; then
            scope="${endpoint##*%}"
            [[ "$scope" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || continue
            endpoint="${endpoint%\%*}"
        fi
        if [[ "$endpoint" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
            port="${BASH_REMATCH[2]}"
            (( 10#$port >= 1 && 10#$port <= 65535 )) || continue
        elif [[ "$endpoint" =~ ^([0-9.]+):([0-9]+)$ ]]; then
            port="${BASH_REMATCH[2]}"
            (( 10#$port >= 1 && 10#$port <= 65535 )) || continue
        fi
        address=$(extract_dns_address "$token")
        canonical=$(canonicalize_ip_address "$address") || continue
        dedupe_key="$canonical|$token"
        [[ -z "${seen[$dedupe_key]+x}" ]] || continue
        seen[$dedupe_key]=1
        output+="${output:+ }$token"
    done
    printf '%s' "$output"
}

dns_addresses_equal() {
    local first="$1"
    local second="$2"
    local first_canonical
    local second_canonical

    first_canonical=$(canonicalize_ip_address "$first") || return 1
    second_canonical=$(canonicalize_ip_address "$second") || return 1
    [[ "$first_canonical" == "$second_canonical" ]]
}

dns_address_in_list() {
    local address="$1"
    local address_list="$2"
    local candidate

    for candidate in $address_list; do
        dns_addresses_equal "$address" "$candidate" && return 0
    done
    return 1
}

limit_dns_server_list() {
    local address_list="$1"
    local maximum="$2"
    local address
    local count=0
    local output=""

    for address in $address_list; do
        (( count < maximum )) || break
        output+="${output:+ }$address"
        count=$((count + 1))
    done
    printf '%s' "$output"
}

extract_resolvectl_values() {
    awk '
        NR == 1 {sub(/^[^:]*:[[:space:]]*/, "")}
        {
            for (i=1; i<=NF; i++) {
                if (count++) printf " "
                printf "%s", $i
            }
        }
        END {if (count) print ""}
    ' <<< "$1"
}

extract_resolvectl_global_domains() {
    awk '
        /^Global:/ {
            found=1
            sub(/^[^:]*:[[:space:]]*/, "")
            for (i=1; i<=NF; i++) {
                if (count++) printf " "
                printf "%s", $i
            }
            next
        }
        found && /^[[:space:]]/ {
            for (i=1; i<=NF; i++) {
                if (count++) printf " "
                printf "%s", $i
            }
            next
        }
        found {exit}
        END {if (count) print ""}
    ' <<< "$1"
}

sanitize_resolved_domains() {
    local domains="$1"
    local domain
    local route_domain
    local output=""
    local -A seen=()

    for domain in $domains; do
        [[ "$domain" == "(none)" || "$domain" == "n/a" ]] && continue
        route_domain="${domain#\~}"
        [[ "$route_domain" == -* ]] && continue
        if [[ "$domain" != "~." ]] && \
           ! [[ "$domain" =~ ^~?([A-Za-z0-9_-]+\.)*[A-Za-z0-9_-]+\.?$ ]]; then
            continue
        fi
        [[ -z "${seen[$domain]+x}" ]] || continue
        seen[$domain]=1
        output+="${output:+ }$domain"
    done
    printf '%s' "$output"
}

resolved_domains_with_route_all() {
    local domains

    domains=$(sanitize_resolved_domains "$1")
    if ! dns_text_has_route_all "$domains"; then
        domains+="${domains:+ }~."
    fi
    printf '%s' "$domains"
}

dns_text_has_server() {
    local text="$1"
    local server="$2"
    local token
    local address

    for token in $text; do
        address=$(extract_dns_address "$token")
        validate_dns_address "$address" || continue
        dns_addresses_equal "$address" "$server" && return 0
    done
    return 1
}

dns_link_uses_requested_servers() {
    local link_output="$1"
    local requested="$2"
    local token
    local address
    local found=0

    for token in $link_output; do
        address=$(extract_dns_address "$token")
        validate_dns_address "$address" || continue
        found=1
        dns_address_in_list "$address" "$requested" || return 1
    done
    [[ "$found" == "1" ]]
}

dns_text_uses_exact_servers() {
    local text="$1"
    local requested="$2"
    local server

    dns_link_uses_requested_servers "$text" "$requested" || return 1
    for server in $requested; do
        dns_text_has_server "$text" "$server" || return 1
    done
}

dns_text_has_route_all() {
    local text="$1"
    local token

    for token in $text; do
        [[ "$token" == "~." ]] && return 0
    done
    return 1
}

dns_verify_fail() {
    local stage="$1"
    local summary="$2"
    local diagnostics="${3:-$summary}"

    DNS_VERIFY_FAILURE="$summary"
    detail "DNS" "$stage" "$diagnostics"
    return 1
}

render_resolved_dns_file() {
    local source_file="$1"
    local output_file="$2"
    local dns_line="$3"
    local domains="$4"

    [[ -f "$source_file" ]] || source_file=/dev/null
    awk -v dns="$dns_line" -v domains="$domains" '
        function emit_dns_settings() {
            print "DNS="
            print "DNS=" dns
            print "FallbackDNS="
            print "Domains="
            print "Domains=" domains
        }
        {
            lines[NR]=$0
            if ($0 ~ /^[[:space:]]*\[[^]]+\]/) {
                section=$0
                sub(/^[[:space:]]*\[/, "", section)
                sub(/\].*$/, "", section)
                current=tolower(section)
                if (current == "resolve") last_resolve=NR
            }
            if (current == "resolve" && $0 !~ /^[[:space:]]*[#;]/ &&
                $0 !~ /^[[:space:]]*\[/) {
                key=$0
                sub(/^[[:space:]]*/, "", key)
                sub(/[[:space:]]*=.*$/, "", key)
                key=tolower(key)
                if (key == "dns" || key == "fallbackdns" || key == "domains") skip[NR]=1
            }
        }
        END {
            if (!last_resolve) {
                for (i=1; i<=NR; i++) if (!skip[i]) print lines[i]
                if (NR > 0) print ""
                print "[Resolve]"
                emit_dns_settings()
                exit
            }
            for (i=1; i<=NR; i++) {
                if (!skip[i]) print lines[i]
                if (i == last_resolve) emit_dns_settings()
            }
        }
    ' "$source_file" > "$output_file"
}

resolved_dropin_has_dns_setting() {
    local file="$1"

    awk '
        /^[[:space:]]*[#;]/ {next}
        /^[[:space:]]*\[[^]]+\]/ {
            section=$0
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\].*$/, "", section)
            in_resolve=(tolower(section) == "resolve")
            next
        }
        in_resolve {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            key=line
            sub(/[[:space:]]*=.*$/, "", key)
            key=tolower(key)
            if (key == "dns" || key == "fallbackdns" || key == "domains") found=1
        }
        END {exit(found ? 0 : 1)}
    ' "$file" 2>/dev/null
}

select_resolved_dropin_target() {
    local dir
    local file
    local filename
    local name
    local latest_file=""
    local latest_name=""
    local candidate
    local candidate_name
    local collision
    local LC_ALL=C
    local -A effective_by_name=()
    local -a effective_files=()
    local -a sorted_names=()
    local -a scan_dirs=(
        /etc/systemd/resolved.conf.d
        /run/systemd/resolved.conf.d
        /usr/local/lib/systemd/resolved.conf.d
        /usr/lib/systemd/resolved.conf.d
    )
    local -a candidates=(
        /etc/systemd/resolved.conf.d/99-vps-init-dns.conf
        /etc/systemd/resolved.conf.d/zz-vps-init-dns.conf
        /etc/systemd/resolved.conf.d/zzzz-vps-init-dns.conf
    )

    for dir in "${scan_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' file; do
            filename=$(basename "$file")
            [[ -z "${effective_by_name[$filename]+x}" ]] || continue
            effective_by_name[$filename]="$file"
        done < <(find "$dir" -maxdepth 1 \( -type f -o -type l \) -name '*.conf' -print0 2>/dev/null)
    done
    if (( ${#effective_by_name[@]} > 0 )); then
        mapfile -t sorted_names < <(printf '%s\n' "${!effective_by_name[@]}" | sort)
        for name in "${sorted_names[@]}"; do
            effective_files+=("${effective_by_name[$name]}")
            if resolved_dropin_has_dns_setting "${effective_by_name[$name]}"; then
                latest_file="${effective_by_name[$name]}"
                latest_name="$name"
            fi
        done
    fi

    for candidate in "${candidates[@]}"; do
        [[ ! -L "$candidate" ]] || continue
        [[ ! -e "$candidate" || -f "$candidate" ]] || continue
        candidate_name=$(basename "$candidate")
        collision=0
        for file in "${effective_files[@]}"; do
            if [[ "$(basename "$file")" == "$candidate_name" && "$file" != "$candidate" ]]; then
                collision=1
                break
            fi
        done
        [[ "$collision" == "0" ]] || continue
        if [[ -n "$latest_name" && "$candidate_name" < "$latest_name" ]]; then
            continue
        fi
        if [[ -n "$latest_name" && "$candidate_name" == "$latest_name" && \
              "$latest_file" != "$candidate" ]]; then
            continue
        fi
        DNS_RESOLVED_FILE="$candidate"
        return 0
    done

    error "未找到能够晚于 ${latest_name:-现有配置} 加载且不遮蔽厂商文件的 systemd-resolved drop-in 文件名。"
    [[ -n "$latest_file" ]] && echo "最终相关配置：$latest_file"
    return 1
}

wait_for_default_route() {
    local family="$1"
    local interface_name="$2"
    local max_wait="$4"
    local elapsed=0

    : "$3"
    [[ "$max_wait" =~ ^[0-9]+$ ]] || max_wait=0
    DNS_ROUTE_AFTER=""
    DNS_ROUTE_WAITED=0

    while true; do
        DNS_ROUTE_AFTER=$(ip -o "-$family" route show default dev "$interface_name" 2>/dev/null)
        if [[ -n "$DNS_ROUTE_AFTER" ]]; then
            DNS_ROUTE_WAITED="$elapsed"
            return 0
        fi
        if (( elapsed >= max_wait )); then
            DNS_ROUTE_WAITED="$elapsed"
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

dns_server_route_is_available() {
    local dns_server="$1"
    local family=4
    local route_output=""
    local first_token=""
    local command_status=0

    [[ "$dns_server" == *:* ]] && family=6
    DNS_TARGET_ROUTE_AFTER=""
    if route_output=$(ip "-$family" route get "$dns_server" 2>&1); then
        command_status=0
    else
        command_status=$?
    fi
    DNS_TARGET_ROUTE_AFTER="$route_output"
    (( command_status == 0 )) || return 1

    first_token=$(awk 'NF {print $1; exit}' <<< "$route_output")
    [[ -n "$first_token" ]] || return 1
    case "$first_token" in
        unreachable|prohibit|blackhole|throw) return 1 ;;
    esac
    return 0
}

verify_dns_change() {
    local requested_dns="$1"
    local route_after
    local current_gateway
    local dns_server
    local resolved_output
    local link_output
    local domain_output
    local global_domains
    local global_dns
    local resolver_mode
    local resolv_servers
    local default_iface
    local command_status
    local github_status
    local cloudflare_status

    DNS_VERIFY_FAILURE=""
    detail "DNS" "VERIFY_START" "请求=$requested_dns；IPv4接口=${DNS_DEFAULT_V4_IFACE_BEFORE:-无}；IPv4网关=${DNS_DEFAULT_V4_GATEWAY_BEFORE:-无}；IPv6接口=${DNS_DEFAULT_V6_IFACE_BEFORE:-无}；IPv6网关=${DNS_DEFAULT_V6_GATEWAY_BEFORE:-无}"

    if [[ -n "$DNS_DEFAULT_V4_IFACE_BEFORE" ]]; then
        if ! wait_for_default_route 4 "$DNS_DEFAULT_V4_IFACE_BEFORE" \
            "$DNS_DEFAULT_V4_GATEWAY_BEFORE" "$DNS_ROUTE_V4_WAIT_SECONDS"; then
            dns_verify_fail "VERIFY_ROUTE_V4" \
                "IPv4 默认路由在等待 ${DNS_ROUTE_WAITED} 秒后仍未恢复（接口 $DNS_DEFAULT_V4_IFACE_BEFORE）" \
                "接口=$DNS_DEFAULT_V4_IFACE_BEFORE；修改前网关=${DNS_DEFAULT_V4_GATEWAY_BEFORE:-无}；等待=${DNS_ROUTE_WAITED}秒；修改后未发现默认路由"
            return 1
        fi
        route_after="$DNS_ROUTE_AFTER"
        current_gateway=$(get_route_gateway_from_text "$route_after")
        if (( DNS_ROUTE_WAITED > 0 )); then
            detail "DNS" "VERIFY_ROUTE_V4" "默认路由等待 ${DNS_ROUTE_WAITED} 秒后恢复；实际路由=$route_after"
        fi
        if [[ -n "$DNS_DEFAULT_V4_GATEWAY_BEFORE" && -n "$current_gateway" && \
              "$current_gateway" != "$DNS_DEFAULT_V4_GATEWAY_BEFORE" ]]; then
            detail "DNS" "VERIFY_ROUTE_V4" "默认路由已在原接口恢复，但网关由 $DNS_DEFAULT_V4_GATEWAY_BEFORE 变为 $current_gateway；按 DHCP/RA 合法续租处理"
        fi
    fi
    if [[ -n "$DNS_DEFAULT_V6_IFACE_BEFORE" ]]; then
        if ! wait_for_default_route 6 "$DNS_DEFAULT_V6_IFACE_BEFORE" \
            "$DNS_DEFAULT_V6_GATEWAY_BEFORE" "$DNS_ROUTE_V6_WAIT_SECONDS"; then
            dns_verify_fail "VERIFY_ROUTE_V6" \
                "IPv6 默认路由在等待 ${DNS_ROUTE_WAITED} 秒后仍未恢复（接口 $DNS_DEFAULT_V6_IFACE_BEFORE）" \
                "接口=$DNS_DEFAULT_V6_IFACE_BEFORE；修改前网关=${DNS_DEFAULT_V6_GATEWAY_BEFORE:-无}；等待=${DNS_ROUTE_WAITED}秒；修改后未发现默认路由"
            return 1
        fi
        route_after="$DNS_ROUTE_AFTER"
        current_gateway=$(get_route_gateway_from_text "$route_after")
        if (( DNS_ROUTE_WAITED > 0 )); then
            detail "DNS" "VERIFY_ROUTE_V6" "RA/DHCPv6 默认路由等待 ${DNS_ROUTE_WAITED} 秒后恢复；实际路由=$route_after"
        fi
        if [[ -n "$DNS_DEFAULT_V6_GATEWAY_BEFORE" && -n "$current_gateway" && \
              "$current_gateway" != "$DNS_DEFAULT_V6_GATEWAY_BEFORE" ]]; then
            detail "DNS" "VERIFY_ROUTE_V6" "默认路由已在原接口恢复，但网关由 $DNS_DEFAULT_V6_GATEWAY_BEFORE 变为 $current_gateway；按 DHCP/RA 合法续租处理"
        fi
    fi
    for dns_server in $requested_dns; do
        if ! dns_server_route_is_available "$dns_server"; then
            dns_verify_fail "VERIFY_TARGET_ROUTE" \
                "目标 DNS $dns_server 当前没有可用路由" \
                "目标=$dns_server；路由查询=${DNS_TARGET_ROUTE_AFTER:-无输出}"
            return 1
        fi
        detail "DNS" "VERIFY_TARGET_ROUTE" \
            "目标=$dns_server；路由=${DNS_TARGET_ROUTE_AFTER//$'\n'/ }"
    done
    if systemctl is-active systemd-resolved >/dev/null 2>&1 && command -v resolvectl >/dev/null 2>&1; then
        resolver_mode=$(get_resolved_resolv_conf_mode)
        if [[ "$resolver_mode" == "foreign" ]]; then
            dns_verify_fail "VERIFY_RESOLV_CONF" \
                "systemd-resolved 已运行，但 resolv.conf 未连接到其 stub/uplink" \
                "resolv.conf 模式=$resolver_mode；目标=$(readlink -f /etc/resolv.conf 2>/dev/null || printf 普通文件)"
            return 1
        fi
        resolved_output=$(resolvectl dns 2>&1)
        command_status=$?
        if (( command_status != 0 )); then
            dns_verify_fail "VERIFY_RESOLVED" \
                "无法读取 systemd-resolved 的 DNS 状态" \
                "resolvectl dns 退出码=$command_status；输出=${resolved_output:-无}"
            return 1
        fi
        global_dns=$(extract_resolvectl_global_domains "$resolved_output")
        if ! dns_text_uses_exact_servers "$global_dns" "$requested_dns"; then
            dns_verify_fail "VERIFY_SERVER" \
                "systemd-resolved 的全局 DNS 与请求值不完全一致" \
                "请求=$requested_dns；全局实际=${global_dns:-无}；完整输出=${resolved_output:-无}"
            return 1
        fi
        domain_output=$(resolvectl domain 2>&1)
        command_status=$?
        global_domains=$(extract_resolvectl_global_domains "$domain_output")
        if (( command_status != 0 )) || ! dns_text_has_route_all "$global_domains"; then
            dns_verify_fail "VERIFY_DOMAIN_ROUTE" \
                "systemd-resolved 的全局 DNS 路由域未设置为 ~." \
                "resolvectl domain 退出码=$command_status；输出=${domain_output:-无}"
            return 1
        fi
        for default_iface in "$DNS_DEFAULT_V4_IFACE_BEFORE" "$DNS_DEFAULT_V6_IFACE_BEFORE"; do
            [[ -n "$default_iface" ]] || continue
            link_output=$(resolvectl dns "$default_iface" 2>&1)
            command_status=$?
            if (( command_status != 0 )); then
                dns_verify_fail "VERIFY_LINK_SERVER" \
                    "无法读取接口 $default_iface 的 DNS 状态" \
                    "接口=$default_iface；resolvectl 退出码=$command_status；输出=${link_output:-无}"
                return 1
            fi
            if ! dns_text_uses_exact_servers "$link_output" "$requested_dns"; then
                dns_verify_fail "VERIFY_LINK_SERVER" \
                    "接口 $default_iface 的 DNS 与请求值不完全一致" \
                    "接口=$default_iface；请求=$requested_dns；实际=${link_output:-无}"
                return 1
            fi
            domain_output=$(resolvectl domain "$default_iface" 2>&1)
            command_status=$?
            if (( command_status != 0 )) || ! dns_text_has_route_all "$domain_output"; then
                dns_verify_fail "VERIFY_LINK_DOMAIN" \
                    "接口 $default_iface 的 DNS 路由域未设置为 ~." \
                    "接口=$default_iface；resolvectl 退出码=$command_status；输出=${domain_output:-无}"
                return 1
            fi
        done
        resolvectl flush-caches >/dev/null 2>&1 || true
    else
        resolv_servers=$(awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null)
        for dns_server in $requested_dns; do
            if ! dns_address_in_list "$dns_server" "$resolv_servers"; then
                dns_verify_fail "VERIFY_RESOLV_CONF" \
                    "请求的 DNS $dns_server 未写入 resolv.conf" \
                    "缺少=$dns_server；请求=$requested_dns；实际=${resolv_servers:-无}"
                return 1
            fi
        done
        while IFS= read -r dns_server; do
            [[ -z "$dns_server" ]] && continue
            if ! dns_address_in_list "$dns_server" "$requested_dns"; then
                dns_verify_fail "VERIFY_RESOLV_CONF" \
                    "resolv.conf 仍包含未请求的 DNS $dns_server" \
                    "未请求=$dns_server；请求=$requested_dns；实际=$resolv_servers"
                return 1
            fi
        done <<< "$resolv_servers"
    fi

    timeout 10 getent ahosts github.com >/dev/null 2>&1
    github_status=$?
    (( github_status == 0 )) && return 0
    timeout 10 getent ahosts cloudflare.com >/dev/null 2>&1
    cloudflare_status=$?
    (( cloudflare_status == 0 )) && return 0

    dns_verify_fail "VERIFY_RESOLVE" \
        "域名解析验证失败" \
        "github.com 退出码=$github_status；cloudflare.com 退出码=$cloudflare_status；请求 DNS=$requested_dns"
}

apply_dns_servers() {
    local requested_dns_line="$1"
    local dns_line="$1"
    local dns_server
    local dns_family
    local resolved_file=""
    local command_output
    local command_status
    local resolver_mode="inactive"
    local default_iface
    local resolved_temp
    local resolv_temp
    local link_dns
    local link_domains
    local link_output
    local global_domain_output
    local global_domains
    local resolved_domains
    local resolv_attributes
    local -a dns_arguments=()
    local -a domain_arguments=()
    local -A configured_links=()

    for dns_server in $dns_line; do
        if ! validate_dns_address "$dns_server" || \
           ! dns_address_is_usable_server "$dns_server"; then
            error "无效或不适合作为全局 DNS 服务器的地址：$dns_server"
            return 1
        fi
    done

    if [[ -e /etc/resolv.conf && ! -f /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
        error "/etc/resolv.conf 不是普通文件或符号链接，为避免破坏特殊挂载已停止 DNS 配置。"
        detail "DNS" "PREFLIGHT" "resolv.conf 类型不受支持"
        return 1
    fi

    if netplan_configuration_is_present && ! netplan_get_is_supported; then
        error "检测到 Netplan 配置，但当前版本缺少 get 子命令；无法可靠判断 renderer 与合并后的 DNS，未修改任何配置。"
        detail "DNS" "PREFLIGHT" "netplan get 不可用；请先从当前系统官方仓库更新 netplan.io 后重试"
        return 1
    fi

    if systemctl is-active NetworkManager >/dev/null 2>&1; then
        error "NetworkManager 正在管理网络连接；为避免与连接级 DNS、路由域和 DHCP 设置冲突，未自动接管 DNS。"
        detail "DNS" "PREFLIGHT" "解析路径包含 NetworkManager；请使用 nmcli 修改默认连接的 ipv4.dns/ipv6.dns 与 ignore-auto-dns"
        return 1
    elif netplan_default_interface_uses_networkmanager; then
        error "Netplan 的默认连接由 NetworkManager 渲染；为避免写入无法可靠接管的 DNS 配置，未自动修改。"
        detail "DNS" "PREFLIGHT" "netplan renderer=NetworkManager；请使用 nmcli 修改连接级 DNS"
        return 1
    elif systemctl is-active systemd-resolved >/dev/null 2>&1; then
        if ! command -v resolvectl >/dev/null 2>&1; then
            error "systemd-resolved 正在运行，但缺少 resolvectl，未修改 DNS。"
            return 1
        fi
        resolver_mode=$(get_resolved_resolv_conf_mode)
        if [[ "$resolver_mode" == "foreign" ]]; then
            error "systemd-resolved 正在运行，但 /etc/resolv.conf 未使用其 stub/uplink；为避免接管未知解析器，未修改 DNS。"
            detail "DNS" "PREFLIGHT" "resolved 运行中；resolv.conf 模式=foreign；目标=$(readlink -f /etc/resolv.conf 2>/dev/null || printf 普通文件)"
            return 1
        fi
        select_resolved_dropin_target || return 1
        resolved_file="$DNS_RESOLVED_FILE"
    elif [[ -L /etc/resolv.conf ]]; then
        error "/etc/resolv.conf 由其他解析器管理；为避免破坏 resolvconf/NetworkManager 所有权，未自动替换。"
        detail "DNS" "PREFLIGHT" "resolved 未运行；resolv.conf 目标=$(readlink -f /etc/resolv.conf 2>/dev/null || printf 未知)"
        return 1
    else
        resolver_mode="static"
        dns_line=$(limit_dns_server_list "$dns_line" 3)
        if [[ "$dns_line" != "$requested_dns_line" ]]; then
            warn "静态 resolv.conf 最多使用 3 个 nameserver；本次将按顺序应用：$dns_line"
            detail "DNS" "PREFLIGHT" "静态解析器上限=3；请求=$requested_dns_line；实际应用=$dns_line"
        fi
    fi

    DNS_DEFAULT_V4_IFACE_BEFORE=$(get_default_route_interface 4)
    DNS_DEFAULT_V4_GATEWAY_BEFORE=$(get_default_route_gateway 4)
    DNS_DEFAULT_V6_IFACE_BEFORE=$(get_default_route_interface 6)
    DNS_DEFAULT_V6_GATEWAY_BEFORE=$(get_default_route_gateway 6)
    if ! dns_default_routes_share_interface \
        "$DNS_DEFAULT_V4_IFACE_BEFORE" "$DNS_DEFAULT_V6_IFACE_BEFORE"; then
        error "IPv4 与 IPv6 默认路由分属不同接口，当前 DNS 流程无法安全生成统一的链路级配置，未修改任何文件。"
        detail "DNS" "PREFLIGHT" \
            "IPv4接口=$DNS_DEFAULT_V4_IFACE_BEFORE；IPv6接口=$DNS_DEFAULT_V6_IFACE_BEFORE；拒绝多出口自动接管"
        return 1
    fi

    for dns_server in $dns_line; do
        dns_family="IPv4"
        [[ "$dns_server" == *:* ]] && dns_family="IPv6"
        if ! dns_server_route_is_available "$dns_server"; then
            error "目标 DNS $dns_server 当前没有可用的 $dns_family 路由，未修改任何配置。"
            detail "DNS" "PREFLIGHT_TARGET_ROUTE" \
                "目标=$dns_server；地址族=$dns_family；路由查询=${DNS_TARGET_ROUTE_AFTER:-无输出}"
            return 1
        fi
        detail "DNS" "PREFLIGHT_TARGET_ROUTE" \
            "目标=$dns_server；地址族=$dns_family；路由=${DNS_TARGET_ROUTE_AFTER//$'\n'/ }"
    done

    DNS_CHANGED_FILES=()
    DNS_BACKUP_FILES=()
    DNS_FILE_EXISTED=()
    DNS_BACKUP_PATH="$BACKUP_DIR/dns-$(date +%Y%m%d%H%M%S)-$$"
    DNS_NETPLAN_CONFIGURED=0
    DNS_INTERFACES_CONFIGURED=0
    DNS_INTERFACES_FILE=""
    DNS_INTERFACES_METHOD=""
    DNS_RESOLVED_ACTIVE=0
    DNS_RESOLV_WAS_IMMUTABLE=0
    DNS_RESOLVED_LINKS=()
    DNS_LINK_DNS_BEFORE=()
    DNS_LINK_DOMAINS_BEFORE=()
    if ! prepare_backup_path "$DNS_BACKUP_PATH"; then
        error "无法创建 DNS 备份目录：$DNS_BACKUP_PATH"
        return 1
    fi
    detail "DNS" "DETECT" "请求=$requested_dns_line；实际应用=$dns_line；解析路径=$resolver_mode；IPv4接口=${DNS_DEFAULT_V4_IFACE_BEFORE:-无}；IPv4网关=${DNS_DEFAULT_V4_GATEWAY_BEFORE:-无}；IPv6接口=${DNS_DEFAULT_V6_IFACE_BEFORE:-无}；IPv6网关=${DNS_DEFAULT_V6_GATEWAY_BEFORE:-无}；备份=$DNS_BACKUP_PATH"

    if ! persist_dns_network_layer "$dns_line" "$resolver_mode"; then
        rollback_dns_with_message "DNS 持久化配置写入失败"
        return 1
    fi

    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        DNS_RESOLVED_ACTIVE=1
        if [[ -L "$resolved_file" ]]; then
            rollback_dns_with_message "$resolved_file 是符号链接，无法安全修改"
            return 1
        fi
        mkdir -p /etc/systemd/resolved.conf.d/ || {
            rollback_dns_with_message "无法创建 systemd-resolved 配置目录"
            return 1
        }
        backup_dns_file "$resolved_file" || {
            rollback_dns_with_message "systemd-resolved 配置备份失败"
            return 1
        }
        global_domain_output=$(LC_ALL=C resolvectl domain 2>/dev/null || true)
        global_domains=$(extract_resolvectl_global_domains "$global_domain_output")
        resolved_domains=$(resolved_domains_with_route_all "$global_domains")
        for default_iface in "$DNS_DEFAULT_V4_IFACE_BEFORE" "$DNS_DEFAULT_V6_IFACE_BEFORE"; do
            [[ -n "$default_iface" && -z "${configured_links[$default_iface]+x}" ]] || continue
            configured_links[$default_iface]=1
            DNS_RESOLVED_LINKS+=("$default_iface")
            link_output=$(LC_ALL=C resolvectl dns "$default_iface" 2>/dev/null || true)
            link_dns=$(extract_resolvectl_values "$link_output")
            link_output=$(LC_ALL=C resolvectl domain "$default_iface" 2>/dev/null || true)
            link_domains=$(extract_resolvectl_values "$link_output")
            [[ "$link_dns" == "(none)" || "$link_dns" == "n/a" ]] && link_dns=""
            [[ "$link_domains" == "(none)" || "$link_domains" == "n/a" ]] && link_domains=""
            link_dns=$(sanitize_resolved_dns_server_tokens "$link_dns")
            link_domains=$(sanitize_resolved_domains "$link_domains")
            DNS_LINK_DNS_BEFORE["$default_iface"]="$link_dns"
            DNS_LINK_DOMAINS_BEFORE["$default_iface"]="$link_domains"
        done
        resolved_temp=$(mktemp /etc/systemd/resolved.conf.d/.vps-init-dns.XXXXXX) || {
            rollback_dns_with_message "无法创建 systemd-resolved 临时配置"
            return 1
        }
        if ! render_resolved_dns_file \
            "$resolved_file" "$resolved_temp" "$dns_line" "$resolved_domains"; then
            rm -f -- "$resolved_temp"
            rollback_dns_with_message "systemd-resolved 配置生成失败"
            return 1
        fi
        if [[ -f "$resolved_file" ]]; then
            if ! chmod --reference="$resolved_file" "$resolved_temp" || \
               ! chown --reference="$resolved_file" "$resolved_temp"; then
                rm -f -- "$resolved_temp"
                rollback_dns_with_message "systemd-resolved 配置权限复制失败"
                return 1
            fi
        elif ! chmod 644 "$resolved_temp" || ! chown root:root "$resolved_temp"; then
            rm -f -- "$resolved_temp"
            rollback_dns_with_message "systemd-resolved 配置权限设置失败"
            return 1
        fi
        if ! mv -f -- "$resolved_temp" "$resolved_file"; then
            rm -f -- "$resolved_temp"
            rollback_dns_with_message "systemd-resolved 配置写入失败"
            return 1
        fi
        command_output=$(timeout 30 systemctl restart systemd-resolved 2>&1)
        command_status=$?
        if (( command_status != 0 )); then
            detail "DNS" "APPLY_RESOLVED" "systemd-resolved 重启失败，退出码=$command_status，输出=${command_output:-无}"
            rollback_dns_with_message "systemd-resolved 重启失败"
            return 1
        fi
        read -r -a dns_arguments <<< "$dns_line"
        for default_iface in "${DNS_RESOLVED_LINKS[@]}"; do
            command_output=$(resolvectl dns "$default_iface" "${dns_arguments[@]}" 2>&1)
            command_status=$?
            if (( command_status != 0 )); then
                detail "DNS" "APPLY_LINK" "接口=$default_iface；resolvectl dns 退出码=$command_status；输出=${command_output:-无}"
                rollback_dns_with_message "无法为接口 $default_iface 应用运行时 DNS"
                return 1
            fi
            link_domains=$(resolved_domains_with_route_all "${DNS_LINK_DOMAINS_BEFORE[$default_iface]:-}")
            read -r -a domain_arguments <<< "$link_domains"
            command_output=$(resolvectl domain "$default_iface" "${domain_arguments[@]}" 2>&1)
            command_status=$?
            if (( command_status != 0 )); then
                detail "DNS" "APPLY_LINK" "接口=$default_iface；resolvectl domain 退出码=$command_status；输出=${command_output:-无}"
                rollback_dns_with_message "无法为接口 $default_iface 应用 DNS 路由域"
                return 1
            fi
        done
        detail "DNS" "APPLY_RESOLVED" "配置=$resolved_file；DNS=$dns_line；全局域=$resolved_domains；服务重启成功"
    else
        backup_dns_file /etc/resolv.conf || {
            rollback_dns_with_message "resolv.conf 备份失败"
            return 1
        }
        if command -v lsattr >/dev/null 2>&1 && [[ -e /etc/resolv.conf ]]; then
            resolv_attributes=$(lsattr -d /etc/resolv.conf 2>/dev/null | awk 'NR==1 {print $1}')
            [[ "$resolv_attributes" == *i* ]] && DNS_RESOLV_WAS_IMMUTABLE=1
        fi
        if [[ "$DNS_RESOLV_WAS_IMMUTABLE" == "1" ]]; then
            if ! command -v chattr >/dev/null 2>&1 || \
               ! chattr -i /etc/resolv.conf >/dev/null 2>&1; then
                rollback_dns_with_message "无法安全移除 resolv.conf 的不可变属性"
                return 1
            fi
        fi
        resolv_temp=$(mktemp /etc/.vps-init-resolv.XXXXXX) || {
            rollback_dns_with_message "resolv.conf 临时文件创建失败"
            return 1
        }
        if ! render_static_resolv_conf /etc/resolv.conf "$resolv_temp" "$dns_line"; then
            rm -f -- "$resolv_temp"
            rollback_dns_with_message "resolv.conf 写入失败"
            return 1
        fi
        if [[ -f /etc/resolv.conf ]]; then
            chmod --reference=/etc/resolv.conf "$resolv_temp" || {
                rm -f -- "$resolv_temp"
                rollback_dns_with_message "resolv.conf 权限复制失败"
                return 1
            }
            chown --reference=/etc/resolv.conf "$resolv_temp" || {
                rm -f -- "$resolv_temp"
                rollback_dns_with_message "resolv.conf 所有者复制失败"
                return 1
            }
        elif ! chmod 644 "$resolv_temp" || ! chown root:root "$resolv_temp"; then
            rm -f -- "$resolv_temp"
            rollback_dns_with_message "resolv.conf 权限设置失败"
            return 1
        fi
        if ! mv -f -- "$resolv_temp" /etc/resolv.conf; then
            rm -f -- "$resolv_temp"
            rollback_dns_with_message "resolv.conf 原子替换失败"
            return 1
        fi
        if [[ "$DNS_RESOLV_WAS_IMMUTABLE" == "1" ]] && ! chattr +i /etc/resolv.conf >/dev/null 2>&1; then
            rollback_dns_with_message "resolv.conf 不可变属性恢复失败"
            return 1
        fi
    fi

    if ! verify_dns_change "$dns_line"; then
        rollback_dns_with_message "DNS 应用后验证失败：${DNS_VERIFY_FAILURE:-未知原因}"
        return 1
    fi

    detail "DNS" "VERIFY_SUCCESS" "DNS 已应用并通过路由、解析器状态和域名解析验证；netplan持久化=$DNS_NETPLAN_CONFIGURED；interfaces持久化=$DNS_INTERFACES_CONFIGURED；备份=$DNS_BACKUP_PATH"
    return 0
}

submenu_dns() {
    local dns_entry_valid
    local dns_server
    local ipv6_state

    require_commands "DNS 配置" \
        ip systemctl timeout getent awk sed find mktemp tr chmod chown mv readlink || {
        pause_menu
        return
    }
    while true; do
        print_header "DNS 配置"
        echo "当前生效 DNS 配置："
        show_dns_status
        echo -e "${DIM}--------------------------------------------------${NC}"
        print_menu_item 1 "设置为 Cloudflare" "IPv4 + 可用时的 IPv6"
        print_menu_item 2 "设置为 Google" "8.8.8.8 / 8.8.4.4"
        print_menu_item 3 "输入自定义 DNS" "支持 IPv4/IPv6"
        echo -e "  ${DIM}0. 返回上一级${NC}"
        echo -e "${CYAN}==================================================${NC}"
        read -r -p "请输入选项 [0-3]: " choice_dns

        ipv6_state=$(get_ipv6_runtime_state)
        DNS_ENTRY=""

        case "$choice_dns" in
            1)
                DNS_ENTRY="1.1.1.1 1.0.0.1"
                if [[ "$ipv6_state" == "enabled" ]] && \
                   dns_server_route_is_available "2606:4700:4700::1111" && \
                   dns_server_route_is_available "2606:4700:4700::1001"; then
                    DNS_ENTRY+=" 2606:4700:4700::1111 2606:4700:4700::1001"
                elif [[ "$ipv6_state" == "enabled" ]]; then
                    echo -e "${YELLOW}IPv6 已启用，但当前没有到 Cloudflare IPv6 DNS 的完整路由，已自动使用 IPv4。${NC}"
                else
                    echo -e "${YELLOW}IPv6 未在全部现有接口上启用，Cloudflare IPv6 DNS 已自动跳过。${NC}"
                fi
                ;;
            2) DNS_ENTRY="8.8.8.8 8.8.4.4" ;;
            3)
                read -r -p "请输入首选 DNS 地址: " dns1
                read -r -p "请输入备用 DNS 地址 (留空则不设置): " dns2
                
                if [[ -z "$dns1" ]]; then
                    error "首选 DNS 不能为空！"
                    pause_menu; continue
                fi

                if [[ "$ipv6_state" != "enabled" ]]; then
                    if [[ "$dns1" =~ ":" ]] || [[ "$dns2" =~ ":" ]]; then
                        error "IPv6 未在全部现有接口上启用，未配置 IPv6 DNS 地址。"
                        pause_menu; continue
                    fi
                fi
                DNS_ENTRY="$dns1"
                [[ -n "$dns2" ]] && DNS_ENTRY+=" $dns2"
                ;;
            0) return ;;
            *) error "无效选项！"; sleep 1; continue ;;
        esac

        dns_entry_valid=1
        for dns_server in $DNS_ENTRY; do
            if ! validate_dns_address "$dns_server" || \
               ! dns_address_is_usable_server "$dns_server"; then
                error "无效或不适合作为全局 DNS 服务器的地址：$dns_server"
                dns_entry_valid=0
                break
            fi
        done
        if [[ "$dns_entry_valid" == "0" ]]; then
            pause_menu; continue
        fi

        echo "将配置 DNS：$DNS_ENTRY"
        if netplan_configuration_is_present; then
            echo "netplan 仅写入并执行 generate 校验，不运行 apply，不会主动重载网卡。"
        fi
        confirm_action "确认应用该 DNS 配置吗？" || continue
        log "正在配置 DNS..."
        if ! apply_dns_servers "$DNS_ENTRY"; then
            pause_menu; continue
        fi

        action_success "DNS 配置" "运行状态与域名解析验证通过；备份：$DNS_BACKUP_PATH"
        echo "当前检测到的 DNS："
        show_dns_status
        pause_menu
    done
}

get_gai_preference_mode() {
    local file="${1:-/etc/gai.conf}"

    if [[ -L "$file" ]] || [[ -e "$file" && ! -f "$file" ]]; then
        printf unsafe
        return 0
    fi
    [[ -f "$file" ]] || {
        printf default
        return 0
    }
    awk -v begin="$GAI_MANAGED_BEGIN" -v end="$GAI_MANAGED_END" '
        $0 == begin {
            begin_count++
            if (in_managed) malformed=1
            in_managed=1
            next
        }
        $0 == end {
            end_count++
            if (!in_managed) malformed=1
            in_managed=0
            next
        }
        in_managed {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            if (line == "" || line ~ /^[#;]/) next
            if (line ~ /^precedence[[:space:]]+::1\/128[[:space:]]+50$/) managed_1++
            else if (line ~ /^precedence[[:space:]]+::\/0[[:space:]]+40$/) managed_2++
            else if (line ~ /^precedence[[:space:]]+2002::\/16[[:space:]]+30$/) managed_3++
            else if (line ~ /^precedence[[:space:]]+::\/96[[:space:]]+20$/) managed_4++
            else if (line ~ /^precedence[[:space:]]+::ffff:0:0\/96[[:space:]]+100$/) managed_5++
            else managed_other=1
            next
        }
        /^[[:space:]]*[#;]/ {next}
        /^[[:space:]]*precedence[[:space:]]+::ffff:0:0\/96[[:space:]]+100([[:space:]]|$)/ {
            legacy=1
            next
        }
        /^[[:space:]]*precedence[[:space:]]+/ {custom=1}
        END {
            if (in_managed || begin_count != end_count || begin_count > 1 ||
                (begin_count == 1 &&
                    (managed_1 != 1 || managed_2 != 1 || managed_3 != 1 ||
                     managed_4 != 1 || managed_5 != 1 || managed_other)) || malformed) print "malformed"
            else if (begin_count == 1 && custom) print "mixed"
            else if (begin_count == 1) print "ipv4"
            else if (legacy && !custom) print "legacy-ipv4"
            else if (custom || legacy) print "custom"
            else print "default"
        }
    ' "$file"
}

render_gai_preference_file() {
    local source_file="$1"
    local output_file="$2"
    local mode="$3"
    local remove_legacy="${4:-0}"

    awk -v begin="$GAI_MANAGED_BEGIN" -v end="$GAI_MANAGED_END" \
        -v mode="$mode" -v remove_legacy="$remove_legacy" '
        $0 == begin {in_managed=1; next}
        $0 == end {in_managed=0; next}
        in_managed {next}
        remove_legacy == "1" &&
            $0 ~ /^[[:space:]]*precedence[[:space:]]+::ffff:0:0\/96[[:space:]]+100([[:space:]]|$)/ {next}
        {print}
        END {
            if (mode == "ipv4") {
                print ""
                print begin
                print "# Complete glibc default precedence table; IPv4-mapped addresses are preferred."
                print "precedence ::1/128       50"
                print "precedence ::/0          40"
                print "precedence 2002::/16     30"
                print "precedence ::/96         20"
                print "precedence ::ffff:0:0/96 100"
                print end
            }
        }
    ' "$source_file" > "$output_file"
}

configure_ip_preference() {
    local mode="$1"
    local backup_path
    local gai_existed=0
    local rollback_failed=0
    local current_mode
    local final_mode
    local temp_file
    local remove_legacy=0
    local source_file=/dev/null

    backup_path="$BACKUP_DIR/gai-$(date +%Y%m%d%H%M%S)-$$"

    if [[ -L /etc/gai.conf ]] || [[ -e /etc/gai.conf && ! -f /etc/gai.conf ]]; then
        error "/etc/gai.conf 不是可安全替换的普通文件，为避免修改未知目标已停止操作。"
        return 1
    fi
    current_mode=$(get_gai_preference_mode)
    if [[ "$current_mode" == "malformed" ]]; then
        error "/etc/gai.conf 中的 vps-init 标记不完整或重复，为避免误删配置已停止操作。"
        return 1
    fi
    if [[ "$mode" == "ipv4" ]] &&
       [[ "$current_mode" == "custom" || "$current_mode" == "mixed" ]]; then
        error "/etc/gai.conf 中存在自定义 precedence 规则，为避免改变用户地址选择策略，未自动修改。"
        return 1
    fi
    if [[ "$mode" == "default" && "$current_mode" == "custom" ]]; then
        error "/etc/gai.conf 仅包含非本脚本管理的自定义规则，未做修改。"
        return 1
    fi

    prepare_backup_path "$backup_path" || return 1
    if [[ -f /etc/gai.conf ]]; then
        gai_existed=1
        source_file=/etc/gai.conf
        cp -a /etc/gai.conf "$backup_path/gai.conf" || return 1
    fi

    [[ "$current_mode" == "legacy-ipv4" ]] && remove_legacy=1

    temp_file=$(mktemp /etc/.vps-init-gai.XXXXXX) || return 1
    if ! render_gai_preference_file "$source_file" "$temp_file" "$mode" "$remove_legacy"; then
        rm -f -- "$temp_file"
        error "gai.conf 更新失败。"
    elif [[ "$gai_existed" == "1" ]] && \
         { ! chmod --reference=/etc/gai.conf "$temp_file" || \
           ! chown --reference=/etc/gai.conf "$temp_file"; }; then
        rm -f -- "$temp_file"
        error "gai.conf 权限复制失败。"
    elif [[ "$gai_existed" == "0" ]] && \
         { ! chmod 644 "$temp_file" || ! chown root:root "$temp_file"; }; then
        rm -f -- "$temp_file"
        error "gai.conf 权限设置失败。"
    elif ! mv -f -- "$temp_file" /etc/gai.conf; then
        rm -f -- "$temp_file"
        error "gai.conf 更新失败。"
    else
        final_mode=$(get_gai_preference_mode)
    fi
    if [[ -n "$final_mode" && "$mode" == "ipv4" && "$final_mode" != "ipv4" ]]; then
        error "IPv4 优先级验证失败。"
    elif [[ -n "$final_mode" && "$mode" == "default" ]] && \
         [[ "$final_mode" == "ipv4" || "$final_mode" == "legacy-ipv4" || \
            "$final_mode" == "mixed" || "$final_mode" == "malformed" ]]; then
        error "默认地址优先级恢复验证失败。"
    elif [[ -n "$final_mode" ]]; then
        if [[ "$mode" == "ipv4" ]]; then
            action_success "地址优先级" "IPv4 优先，IPv6 保持启用；备份：$backup_path"
        elif [[ "$final_mode" == "custom" ]]; then
            action_success "地址优先级" "已移除 vps-init 规则并保留原有自定义规则；备份：$backup_path"
        else
            action_success "地址优先级" "已恢复系统默认；备份：$backup_path"
        fi
        return 0
    fi

    if [[ "$gai_existed" == "1" ]]; then
        cp -a "$backup_path/gai.conf" /etc/gai.conf || rollback_failed=1
    else
        rm -f /etc/gai.conf || rollback_failed=1
    fi
    if [[ "$rollback_failed" == "0" ]]; then
        warn "地址优先级修改失败，原 gai.conf 已恢复。"
    else
        error "地址优先级修改失败且自动回滚不完整，请从 $backup_path 手动恢复。"
    fi
    return 1
}

format_gai_preference_status() {
    case "${1:-$(get_gai_preference_mode)}" in
        default) printf '系统默认' ;;
        ipv4) printf 'IPv4 优先（vps-init）' ;;
        legacy-ipv4) printf 'IPv4 优先（旧式单行配置）' ;;
        custom) printf '自定义规则（非 vps-init 管理）' ;;
        mixed) printf 'vps-init 与自定义规则并存' ;;
        malformed) printf 'vps-init 标记异常' ;;
        unsafe) printf 'gai.conf 类型不安全' ;;
        *) printf '未知' ;;
    esac
}

get_ipv6_runtime_state() {
    local runtime_path
    local interface_name
    local runtime_value
    local enabled=0
    local disabled=0

    for runtime_path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        [[ -r "$runtime_path" ]] || continue
        interface_name=$(basename "$(dirname "$runtime_path")")
        [[ "$interface_name" == "all" || "$interface_name" == "default" ]] && continue
        runtime_value=$(<"$runtime_path")
        case "$runtime_value" in
            0) enabled=$((enabled + 1)) ;;
            1) disabled=$((disabled + 1)) ;;
            *) printf unknown; return 0 ;;
        esac
    done
    if (( enabled > 0 && disabled == 0 )); then
        printf enabled
    elif (( disabled > 0 && enabled == 0 )); then
        printf disabled
    elif (( enabled > 0 && disabled > 0 )); then
        printf mixed
    else
        printf unknown
    fi
}

restore_ipv6_transaction() {
    local index
    local failed=0

    if [[ "$IPV6_FILE_EXISTED" == "1" ]]; then
        cp -a "$IPV6_BACKUP_PATH/ipv6.conf" "$IPV6_SYSCTL_FILE" || failed=1
    else
        rm -f "$IPV6_SYSCTL_FILE" || failed=1
    fi
    for index in "${!IPV6_RUNTIME_PATHS[@]}"; do
        if ! printf '%s' "${IPV6_RUNTIME_VALUES[$index]}" > "${IPV6_RUNTIME_PATHS[$index]}" 2>/dev/null; then
            failed=1
        fi
    done
    for index in "${!IPV6_RUNTIME_PATHS[@]}"; do
        if [[ ! -r "${IPV6_RUNTIME_PATHS[$index]}" ]] || \
           [[ "$(<"${IPV6_RUNTIME_PATHS[$index]}")" != "${IPV6_RUNTIME_VALUES[$index]}" ]]; then
            failed=1
        fi
    done
    return "$failed"
}

verify_ipv6_runtime_state() {
    local target_value="$1"
    local runtime_path
    local runtime_value

    IPV6_VERIFY_FAILURE=""

    for runtime_path in "${IPV6_RUNTIME_PATHS[@]}"; do
        if [[ ! -r "$runtime_path" ]]; then
            IPV6_VERIFY_FAILURE="运行状态不可读：$runtime_path"
            return 1
        fi
        runtime_value=$(<"$runtime_path")
        if [[ "$runtime_value" != "$target_value" ]]; then
            IPV6_VERIFY_FAILURE="运行状态不一致：$runtime_path 期望=$target_value 实际=$runtime_value"
            return 1
        fi
    done
}

current_ssh_session_uses_ipv6() {
    local connection="${SSH_CONNECTION:-}"
    local client_address
    local client_port
    local server_address
    local server_port

    [[ -n "$connection" ]] || return 1
    read -r client_address client_port server_address server_port <<< "$connection"
    [[ -n "$client_address" && -n "$client_port" && -n "$server_address" && -n "$server_port" ]] || return 1
    [[ "$server_address" == *:* ]]
}

current_ssh_session_uses_ipv4() {
    local connection="${SSH_CONNECTION:-}"
    local client_address
    local client_port
    local server_address
    local server_port

    [[ -n "$connection" ]] || return 1
    read -r client_address client_port server_address server_port <<< "$connection"
    [[ -n "$client_address" && -n "$client_port" && -n "$server_address" && -n "$server_port" ]] || return 1
    [[ "$client_address" != *:* && "$server_address" != *:* ]]
}

ipv4_route_is_available() {
    local route_output

    route_output=$(ip -4 route get 1.1.1.1 2>/dev/null) || return 1
    [[ -n "$route_output" && "$route_output" != unreachable* && \
       "$route_output" != prohibit* && "$route_output" != blackhole* ]]
}

configure_ipv6_state() {
    local target_value="$1"
    local action_label="禁用"
    local module_disabled=""
    local runtime_path
    local runtime_value

    [[ "$target_value" == "0" ]] && action_label="启用"
    if [[ "$target_value" == "1" ]] && current_ssh_session_uses_ipv6; then
        error "当前 SSH 会话通过 IPv6 连接，禁用 IPv6 会立即中断会话；请改用 IPv4 登录或云厂商控制台执行。"
        return 1
    fi
    if [[ "$target_value" == "1" ]] && \
       ip -6 route show default 2>/dev/null | grep -q . && \
       ! ipv4_route_is_available && ! current_ssh_session_uses_ipv4; then
        error "检测到 IPv6 默认路由，但没有可用的 IPv4 路由或 IPv4 SSH 会话；禁用 IPv6 可能使服务器完全失联，已停止操作。"
        return 1
    fi
    if [[ "$target_value" == "0" && -r /sys/module/ipv6/parameters/disable ]]; then
        module_disabled=$(tr '[:lower:]' '[:upper:]' < /sys/module/ipv6/parameters/disable 2>/dev/null)
        if [[ "$module_disabled" == "Y" || "$module_disabled" == "1" ]]; then
            error "IPv6 已通过内核模块参数全局禁用，无法在运行中重新启用；请移除 ipv6.disable=1 后重启。"
            return 1
        fi
    fi
    IPV6_BACKUP_PATH="$BACKUP_DIR/ipv6-$(date +%Y%m%d%H%M%S)-$$"
    IPV6_FILE_EXISTED=0
    IPV6_RUNTIME_PATHS=()
    IPV6_RUNTIME_VALUES=()
    IPV6_VERIFY_FAILURE=""
    IPV6_PREVIOUS_ALL=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    IPV6_PREVIOUS_DEFAULT=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)
    IPV6_PREVIOUS_LO=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null)

    for runtime_path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        [[ -r "$runtime_path" ]] || continue
        runtime_value=$(<"$runtime_path")
        IPV6_RUNTIME_PATHS+=("$runtime_path")
        IPV6_RUNTIME_VALUES+=("$runtime_value")
    done

    if [[ -z "$IPV6_PREVIOUS_ALL" || -z "$IPV6_PREVIOUS_DEFAULT" || -z "$IPV6_PREVIOUS_LO" ]] || \
       (( ${#IPV6_RUNTIME_PATHS[@]} == 0 )); then
        error "无法读取当前 IPv6 内核状态，未修改配置。"
        return 1
    fi
    validate_effective_ipv6_interface_overrides "$target_value" || return 1
    select_ipv6_sysctl_target || return 1
    validate_sysctl_conf_final_pass_for_ipv6 "$target_value" || return 1
    detail "IPV6" "DETECT" "操作=$action_label；目标值=$target_value；原 all=$IPV6_PREVIOUS_ALL；原 default=$IPV6_PREVIOUS_DEFAULT；原 lo=$IPV6_PREVIOUS_LO；运行路径数=${#IPV6_RUNTIME_PATHS[@]}；配置=$IPV6_SYSCTL_FILE"
    if [[ -L "$IPV6_SYSCTL_FILE" ]] || \
       [[ -e "$IPV6_SYSCTL_FILE" && ! -f "$IPV6_SYSCTL_FILE" ]]; then
        error "$IPV6_SYSCTL_FILE 不是可安全替换的普通文件，已停止操作。"
        return 1
    fi
    prepare_backup_path "$IPV6_BACKUP_PATH" || return 1
    mkdir -p "$(dirname "$IPV6_SYSCTL_FILE")" || return 1
    if [[ -f "$IPV6_SYSCTL_FILE" ]]; then
        IPV6_FILE_EXISTED=1
        cp -a "$IPV6_SYSCTL_FILE" "$IPV6_BACKUP_PATH/ipv6.conf" || return 1
    fi

    log "正在$action_label系统 IPv6 ..."
    if ! write_sysctl_keys_atomic "$IPV6_SYSCTL_FILE" \
           net.ipv6.conf.all.disable_ipv6 "$target_value" \
           net.ipv6.conf.default.disable_ipv6 "$target_value" \
           net.ipv6.conf.lo.disable_ipv6 "$target_value" || \
       [[ "$(get_effective_sysctl_value net.ipv6.conf.all.disable_ipv6)" != "$target_value" ]] || \
       [[ "$(get_effective_sysctl_value net.ipv6.conf.default.disable_ipv6)" != "$target_value" ]] || \
       [[ "$(get_effective_sysctl_value net.ipv6.conf.lo.disable_ipv6)" != "$target_value" ]] || \
       ! ipv6_persistence_is_complete "$target_value" || \
       ! sysctl -w "net.ipv6.conf.all.disable_ipv6=$target_value" >/dev/null 2>&1 || \
       ! sysctl -w "net.ipv6.conf.default.disable_ipv6=$target_value" >/dev/null 2>&1 || \
       ! sysctl -w "net.ipv6.conf.lo.disable_ipv6=$target_value" >/dev/null 2>&1 || \
       [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" != "$target_value" ]] || \
       [[ "$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)" != "$target_value" ]] || \
       [[ "$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null)" != "$target_value" ]] || \
       ! verify_ipv6_runtime_state "$target_value"; then
        detail "IPV6" "VERIFY" "操作=$action_label；原因=${IPV6_VERIFY_FAILURE:-写入、持久化顺序或 sysctl 运行值验证失败}；持久化 all=$(get_effective_sysctl_value net.ipv6.conf.all.disable_ipv6)；持久化 default=$(get_effective_sysctl_value net.ipv6.conf.default.disable_ipv6)；持久化 lo=$(get_effective_sysctl_value net.ipv6.conf.lo.disable_ipv6)；运行 all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || printf 未知)；运行 default=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || printf 未知)；运行 lo=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || printf 未知)"
        if restore_ipv6_transaction; then
            detail "IPV6" "ROLLBACK" "配置文件和运行参数恢复成功；备份=$IPV6_BACKUP_PATH"
            error "IPv6 $action_label失败，配置文件与运行参数已回滚。"
        else
            detail "IPV6" "ROLLBACK" "自动恢复不完整；备份=$IPV6_BACKUP_PATH"
            error "IPv6 $action_label失败且自动回滚不完整，请从 $IPV6_BACKUP_PATH 手动恢复。"
        fi
        return 1
    fi

    action_success "IPv6 $action_label" "运行状态和持久化验证通过；备份：$IPV6_BACKUP_PATH"
    if [[ "$target_value" == "0" ]]; then
        warn "IPv6 内核开关已启用；RA/DHCPv6 地址和默认路由可能需要等待、重新连接网络或重启后恢复。脚本不会主动重置网卡，以免中断当前 SSH 会话。"
    fi
}

# ==========================================
# 模块三：IPv6 优先级
# ==========================================
submenu_ipv6() {
    local ipv6_state
    local gai_mode
    local ipv6_persistent_enabled
    local ipv6_persistent_disabled

    require_commands "IPv4 / IPv6 配置" \
        sysctl ip sed awk grep find readlink sort mktemp chmod chown mv || { pause_menu; return; }
    while true; do
        print_header "IPv4 / IPv6 配置"
        ipv6_state=$(get_ipv6_runtime_state)
        gai_mode=$(get_gai_preference_mode)
        ipv6_persistent_enabled=0
        ipv6_persistent_disabled=0
        ipv6_persistence_is_complete 0 && ipv6_persistent_enabled=1
        ipv6_persistence_is_complete 1 && ipv6_persistent_disabled=1
        case "$ipv6_state" in
            disabled) echo -e "当前 IPv6 状态:   ${RED}已禁用（全部现有接口）${NC}" ;;
            enabled) echo -e "当前 IPv6 状态:   ${GREEN}已启用（全部现有接口）${NC}" ;;
            mixed) echo -e "当前 IPv6 状态:   ${YELLOW}接口状态不一致${NC}" ;;
            *) echo -e "当前 IPv6 状态:   ${YELLOW}未知（运行状态读取失败）${NC}" ;;
        esac
        case "$gai_mode" in
            default) echo -e "当前地址优先级:   ${GREEN}$(format_gai_preference_status "$gai_mode")${NC}" ;;
            ipv4|legacy-ipv4) echo -e "当前地址优先级:   ${YELLOW}$(format_gai_preference_status "$gai_mode")${NC}" ;;
            *) echo -e "当前地址优先级:   ${YELLOW}$(format_gai_preference_status "$gai_mode")${NC}" ;;
        esac
        echo -e "${DIM}--------------------------------------------------${NC}"
        print_menu_item 1 "优先使用 IPv4" "保留 IPv6"
        print_menu_item 2 "恢复系统默认地址优先级"
        echo -e "  ${RED}3. [需确认] 禁用系统 IPv6${NC}"
        print_menu_item 4 "重新启用系统 IPv6"
        echo -e "  ${DIM}0. 返回上一级${NC}"
        echo -e "${CYAN}==================================================${NC}"
        read -r -p "请输入选项 [0-4]: " choice_ipv6

        case "$choice_ipv6" in
            1)
                if [[ "$gai_mode" == "ipv4" ]]; then
                    print_result "地址优先级" "跳过" "当前已是 IPv4 优先"
                    pause_menu; continue
                fi
                if [[ "$gai_mode" == "custom" || "$gai_mode" == "mixed" || \
                      "$gai_mode" == "malformed" || "$gai_mode" == "unsafe" ]]; then
                    error "检测到自定义 precedence 规则或异常标记，为避免覆盖用户策略，未自动修改。"
                    pause_menu; continue
                fi
                confirm_action "确认设置 IPv4 优先并保留 IPv6 吗？" || continue
                log "正在设置 IPv4 优先..."
                configure_ip_preference ipv4
                pause_menu ;;
            2)
                if [[ "$gai_mode" == "default" ]]; then
                    print_result "地址优先级" "跳过" "当前已是系统默认"
                    pause_menu; continue
                fi
                if [[ "$gai_mode" == "custom" ]]; then
                    print_result "地址优先级" "跳过" "仅检测到非本脚本管理的自定义规则"
                    pause_menu; continue
                fi
                if [[ "$gai_mode" == "malformed" || "$gai_mode" == "unsafe" ]]; then
                    error "vps-init 标记异常，为避免误删 gai.conf 内容，未自动修改。"
                    pause_menu; continue
                fi
                confirm_action "确认恢复系统默认地址优先级吗？" || continue
                log "正在恢复默认地址优先级..."
                configure_ip_preference default
                pause_menu ;;
            3)
                if [[ "$ipv6_state" == "disabled" && "$ipv6_persistent_disabled" == "1" ]]; then
                    print_result "IPv6 禁用" "跳过" "运行状态与持久化配置均已禁用"
                    pause_menu; continue
                fi
                if [[ "$ipv6_state" == "disabled" ]]; then
                    warn "IPv6 当前已禁用，但持久化配置不完整或存在冲突，重启后状态可能改变。"
                fi
                confirm_action "禁用 IPv6 可能影响仅提供 IPv6 的服务，确认继续吗？" || continue
                configure_ipv6_state 1
                pause_menu ;;
            4)
                if [[ "$ipv6_state" == "enabled" && "$ipv6_persistent_enabled" == "1" ]]; then
                    print_result "IPv6 启用" "跳过" "运行状态与持久化配置均已启用"
                    pause_menu; continue
                fi
                if [[ "$ipv6_state" == "enabled" ]]; then
                    warn "IPv6 当前已启用，但持久化配置不完整或存在冲突，重启后状态可能改变。"
                fi
                confirm_action "确认重新启用系统 IPv6 吗？" || continue
                configure_ipv6_state 0
                pause_menu ;;
            0) return ;;
            *) error "无效选项！"; sleep 1; continue ;;
        esac
    done
}

# ==========================================
# 模块三：网络配置
# ==========================================
submenu_net() {
    local persistent_cc
    local persistent_qdisc
    local write_bbr

    require_commands "网络配置" sysctl ip timeout getent find readlink sort || { pause_menu; return; }
    while true; do
        print_header "网络配置"
        CURRENT_BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        [[ -z "$CURRENT_BBR" ]] && CURRENT_BBR="未知"
        CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)
        [[ -z "$CURRENT_QDISC" ]] && CURRENT_QDISC="未知"
        
        echo -e "拥塞控制 / 队列: ${YELLOW}$CURRENT_BBR / $CURRENT_QDISC${NC}"
        echo -e "${DIM}--------------------------------------------------${NC}"
        print_menu_item 1 "配置 BBR 与 FQ"
        print_menu_item 2 "DNS 配置" "›"
        print_menu_item 3 "IPv4 / IPv6 配置" "›"
        echo -e "  ${DIM}0. 返回主菜单${NC}"
        echo -e "${CYAN}==================================================${NC}"
        read -r -p "请输入选项 [0-3]: " choice_net

        case "$choice_net" in
            1) 
                CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
                CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)
                persistent_cc=$(get_effective_sysctl_value net.ipv4.tcp_congestion_control)
                persistent_qdisc=$(get_effective_sysctl_value net.core.default_qdisc)

                if [[ "$CURRENT_CC" == "bbr" && "$CURRENT_QDISC" == "fq" ]]; then
                    if bbr_persistence_is_complete; then
                        print_result "BBR / FQ" "跳过" "运行状态与持久化配置均已生效"
                        pause_menu; continue
                    fi
                    warn "BBR 与 FQ 当前正在运行，但持久化配置不完整，重启后可能恢复为系统默认值。"
                    echo "持久化检测：拥塞控制=${persistent_cc:-未定义}；默认队列=${persistent_qdisc:-未定义}。"
                    if confirm_action "确认补齐 BBR 与 FQ 的持久化配置吗？"; then
                        persist_bbr_settings "$CURRENT_CC" "$CURRENT_QDISC" 1
                    fi
                    pause_menu; continue
                fi

                if [[ "$CURRENT_CC" == "bbr" ]]; then
                    write_bbr=0
                    echo -e "${YELLOW}BBR 已开启，但当前默认队列为 ${CURRENT_QDISC:-未知}，不是 fq。${NC}"
                    if [[ "$persistent_cc" != "bbr" ]]; then
                        write_bbr=1
                        warn "当前 BBR 未发现有效持久化配置，将与 FQ 一并写入，确保重启后仍生效。"
                    fi
                    if confirm_action "$([[ "$write_bbr" == "1" ]] && printf '确认补齐并启用 BBR 与 FQ 吗？' || printf '确认只补充并启用 FQ 吗？')"; then
                        persist_bbr_settings "$CURRENT_CC" "$CURRENT_QDISC" "$write_bbr"
                    fi
                    pause_menu; continue
                fi

                echo "拥塞控制将从 ${CURRENT_CC:-未知} 修改为 bbr，默认队列将从 ${CURRENT_QDISC:-未知} 修改为 fq。"
                confirm_action "确认配置 BBR 与 FQ 吗？" || continue
                log "正在根据当前内核的实际能力检测并配置 BBR..."
                if command -v modprobe >/dev/null 2>&1; then
                    modprobe tcp_bbr >/dev/null 2>&1 || true
                    modprobe sch_fq >/dev/null 2>&1 || true
                fi
                
                if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
                    error "当前内核未包含 BBR 支持，开启失败！"
                    pause_menu; continue
                fi
                
                persist_bbr_settings "$CURRENT_CC" "$CURRENT_QDISC" 1
                pause_menu
                ;;
            2) submenu_dns ;;
            3) submenu_ipv6 ;;
            0) return ;;
            *) error "无效输入！"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 主菜单入口
# ==========================================
show_status_summary() {
    local ssh_port
    local listening_ports
    local password_auth
    local password_display
    local ipv6_state
    local ipv6_display
    local gai_mode
    local gai_display
    local fail2ban_status
    local fail2ban_display
    local current_cc
    local current_qdisc
    local persistent_cc
    local persistent_qdisc
    local persistent_cc_file
    local persistent_qdisc_file
    local bbr_persistence_display
    local ipv6_persistence_display=""
    local timezone
    local ntp_synchronized

    require_commands "关键状态汇总" awk dpkg-query free grep ip paste sort ss sshd sysctl systemctl timedatectl timeout uname || {
        pause_menu
        return 1
    }
    ssh_port=$(get_configured_ssh_ports)
    listening_ports=$(get_listening_ssh_ports)
    password_auth=$(get_effective_root_sshd_config |
        awk '/^passwordauthentication / {print $2; exit}')
    ipv6_state=$(get_ipv6_runtime_state)
    gai_mode=$(get_gai_preference_mode)
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    persistent_cc=$(get_effective_sysctl_value net.ipv4.tcp_congestion_control)
    persistent_qdisc=$(get_effective_sysctl_value net.core.default_qdisc)
    persistent_cc_file=$(get_effective_sysctl_source net.ipv4.tcp_congestion_control)
    persistent_qdisc_file=$(get_effective_sysctl_source net.core.default_qdisc)
    timezone=$(timedatectl show -p Timezone --value 2>/dev/null)
    ntp_synchronized=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)

    if bbr_persistence_is_complete; then
        bbr_persistence_display="${GREEN}完整且顺序一致${NC}"
    elif [[ -n "$persistent_cc" || -n "$persistent_qdisc" ]]; then
        bbr_persistence_display="${YELLOW}不完整或存在顺序冲突${NC}"
    else
        bbr_persistence_display="${YELLOW}未检测到${NC}"
    fi

    case "$password_auth" in
        yes) password_display="${RED}已启用${NC}" ;;
        no) password_display="${GREEN}已禁用${NC}" ;;
        *) password_display="${YELLOW}未知${NC}" ;;
    esac
    case "$ipv6_state" in
        enabled)
            ipv6_display="${GREEN}已启用（全部现有接口）${NC}"
            if ipv6_persistence_is_complete 0; then
                ipv6_persistence_display="${GREEN}与启用状态一致${NC}"
            else
                ipv6_persistence_display="${YELLOW}与运行状态不一致${NC}"
            fi
            ;;
        disabled)
            ipv6_display="${RED}已禁用（全部现有接口）${NC}"
            if ipv6_persistence_is_complete 1; then
                ipv6_persistence_display="${GREEN}与禁用状态一致${NC}"
            else
                ipv6_persistence_display="${YELLOW}与运行状态不一致${NC}"
            fi
            ;;
        mixed) ipv6_display="${YELLOW}接口状态不一致${NC}" ;;
        *) ipv6_display="${YELLOW}未知${NC}" ;;
    esac
    [[ -n "$ipv6_persistence_display" ]] || ipv6_persistence_display="${YELLOW}无法判定${NC}"
    case "$gai_mode" in
        default) gai_display="${GREEN}$(format_gai_preference_status "$gai_mode")${NC}" ;;
        malformed|unsafe) gai_display="${RED}$(format_gai_preference_status "$gai_mode")${NC}" ;;
        *) gai_display="${YELLOW}$(format_gai_preference_status "$gai_mode")${NC}" ;;
    esac
    fail2ban_status=$(systemctl is-active fail2ban 2>/dev/null || true)
    case "$fail2ban_status" in
        active)
            if ! command -v fail2ban-client >/dev/null 2>&1 || \
               ! timeout 15 fail2ban-client ping >/dev/null 2>&1; then
                fail2ban_display="${RED}服务 active，但客户端不可达${NC}"
            elif timeout 15 fail2ban-client status sshd >/dev/null 2>&1; then
                fail2ban_display="${GREEN}运行中（sshd jail 已启用）${NC}"
            else
                fail2ban_display="${YELLOW}运行中（sshd jail 未启用）${NC}"
            fi
            ;;
        inactive|failed) fail2ban_display="${RED}${fail2ban_status}${NC}" ;;
        *) fail2ban_display="${YELLOW}${fail2ban_status:-未安装或未知}${NC}" ;;
    esac

    print_header "关键状态汇总"
    echo -e "版本:                   ${CYAN}$VERSION${NC}"
    echo "系统维护状态:           $(format_os_maintenance_status)"
    echo -e "拥塞控制 / 队列:        ${YELLOW}${current_cc:-未知} / ${current_qdisc:-未知}${NC}"
    echo -e "持久化配置值:           ${persistent_cc:-未检测到} / ${persistent_qdisc:-未检测到}"
    echo -e "BBR / FQ 持久化验证:    $bbr_persistence_display"
    echo "BBR 持久化来源:         ${persistent_cc_file:-未检测到}"
    echo "FQ 持久化来源:          ${persistent_qdisc_file:-未检测到}"
    echo "SSH 配置端口:           ${ssh_port:-未知}"
    echo "SSH 实际监听:           ${listening_ports:-未检测到}"
    echo -e "SSH 密码登录:           $password_display"
    echo -e "IPv6 运行状态:          $ipv6_display"
    echo -e "IPv6 持久化验证:        $ipv6_persistence_display"
    echo -e "地址选择优先级:         $gai_display"
    echo -e "时区 / NTP 同步:        ${timezone:-未知} / ${ntp_synchronized:-未知}"
    echo -e "Fail2ban:               $fail2ban_display"
    echo "SWAP:                   $(free -h | awk '/^Swap/{print $2" 总 / "$3" 已用"}')"
    if system_reboot_is_required; then
        echo -e "重启状态:               ${YELLOW}需要重启${NC}"
    else
        echo -e "重启状态:               ${GREEN}当前未检测到重启要求${NC}"
    fi
    echo "DNS:"
    show_dns_status
    echo -e "${CYAN}==================================================${NC}"
    pause_menu
}

show_readonly_diagnostics() {
    local current_cc
    local current_qdisc
    local configured_ports
    local listening_ports
    local ipv6_state
    local ntp_synchronized
    local persistent_cc
    local persistent_qdisc

    require_commands "只读配置诊断" getent grep ip paste sort ss sshd sysctl systemctl timedatectl timeout || {
        pause_menu
        return 1
    }
    print_header "只读配置诊断"
    if sshd -t >/dev/null 2>&1; then
        print_result "SSH 配置语法" "正常"
    else
        print_result "SSH 配置语法" "异常"
    fi
    configured_ports=$(get_configured_ssh_ports)
    listening_ports=$(get_listening_ssh_ports)
    if [[ -n "$configured_ports" && "$configured_ports" == "$listening_ports" ]] && \
       ssh_ports_accept_loopback "$configured_ports"; then
        print_result "SSH 监听与协议握手" "正常" "$listening_ports"
    else
        print_result "SSH 监听与协议握手" "异常" \
            "配置=${configured_ports:-未知}；监听=${listening_ports:-未检测到}"
    fi

    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [[ "$current_cc" == "bbr" && "$current_qdisc" == "fq" ]]; then
        print_result "BBR / FQ 运行状态" "正常" "$current_cc / $current_qdisc"
    elif [[ -n "$current_cc" && -n "$current_qdisc" ]]; then
        print_result "BBR / FQ 运行状态" "未启用" "$current_cc / $current_qdisc"
    else
        print_result "BBR / FQ 运行状态" "未知"
    fi
    persistent_cc=$(get_effective_sysctl_value net.ipv4.tcp_congestion_control)
    persistent_qdisc=$(get_effective_sysctl_value net.core.default_qdisc)
    if bbr_persistence_is_complete; then
        print_result "BBR / FQ 持久化" "正常"
    elif [[ "$current_cc" == "bbr" || "$current_qdisc" == "fq" || \
            -n "$persistent_cc" || -n "$persistent_qdisc" ]]; then
        print_result "BBR / FQ 持久化" "异常" "未配置完整或加载顺序不一致"
    else
        print_result "BBR / FQ 持久化" "未配置"
    fi

    ipv6_state=$(get_ipv6_runtime_state)
    case "$ipv6_state" in
        enabled)
            print_result "IPv6 运行状态" "正常" "全部现有接口已启用"
            if ipv6_persistence_is_complete 0; then
                print_result "IPv6 持久化" "正常" "与启用状态一致"
            else
                print_result "IPv6 持久化" "异常" "与运行状态不一致"
            fi
            ;;
        disabled)
            print_result "IPv6 运行状态" "已禁用" "全部现有接口"
            if ipv6_persistence_is_complete 1; then
                print_result "IPv6 持久化" "正常" "与禁用状态一致"
            else
                print_result "IPv6 持久化" "异常" "与运行状态不一致"
            fi
            ;;
        mixed) print_result "IPv6 运行状态" "异常" "接口状态不一致" ;;
        *) print_result "IPv6 运行状态" "未知" ;;
    esac

    ntp_synchronized=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    if [[ "$ntp_synchronized" == "yes" ]]; then
        print_result "系统时间同步" "正常"
    else
        print_result "系统时间同步" "异常" "NTPSynchronized=${ntp_synchronized:-未知}"
    fi

    if ip route show default 2>/dev/null | grep -q . || ip -6 route show default 2>/dev/null | grep -q .; then
        print_result "默认路由" "正常"
    else
        print_result "默认路由" "异常"
    fi
    if timeout 8 getent ahosts github.com >/dev/null 2>&1 || \
       timeout 8 getent ahosts cloudflare.com >/dev/null 2>&1; then
        print_result "DNS 解析" "正常"
    else
        print_result "DNS 解析" "异常"
    fi
    if command -v fail2ban-client >/dev/null 2>&1; then
        if timeout 15 fail2ban-client -t >/dev/null 2>&1; then
            print_result "Fail2ban 配置" "正常"
        else
            print_result "Fail2ban 配置" "异常"
        fi
        if [[ "$(systemctl is-active fail2ban 2>/dev/null)" == "active" ]] && \
           timeout 15 fail2ban-client ping >/dev/null 2>&1; then
            print_result "Fail2ban 服务" "运行中"
            if timeout 15 fail2ban-client status sshd >/dev/null 2>&1; then
                print_result "Fail2ban sshd jail" "已启用"
            else
                print_result "Fail2ban sshd jail" "已禁用"
            fi
        else
            print_result "Fail2ban 服务" "异常" "未运行或客户端不可达"
        fi
    else
        print_result "Fail2ban 配置" "未安装"
    fi
    echo -e "${CYAN}==================================================${NC}"
    pause_menu
}

show_recent_log() {
    require_commands "日志查看" tail || {
        pause_menu
        return 1
    }
    print_header "最近运行日志"
    if [[ -s "$LOG_FILE" ]]; then
        tail -n 40 "$LOG_FILE"
    else
        echo -e "${YELLOW}暂无日志内容。${NC}"
    fi
    echo -e "${CYAN}==================================================${NC}"
    pause_menu
}

submenu_status() {
    local choice_status

    while true; do
        print_header "状态与诊断"
        print_menu_item 1 "查看关键状态汇总"
        print_menu_item 2 "运行只读配置诊断" "SSH / BBR / 路由 / DNS / Fail2ban"
        print_menu_item 3 "查看最近运行日志" "最近 40 行"
        echo -e "  ${DIM}0. 返回主菜单${NC}"
        echo -e "${CYAN}==================================================${NC}"
        read -r -p "请输入选项 [0-3]: " choice_status
        case "$choice_status" in
            1) show_status_summary ;;
            2) show_readonly_diagnostics ;;
            3) show_recent_log ;;
            0) return ;;
            *) error "无效输入！"; sleep 1 ;;
        esac
    done
}

main_menu() {
    while true; do
        MEM_STATUS=$(free -h | awk '/^Mem/{print $2" 总 / "$3" 已用"}')
        DISK_STATUS=$(df -h / | awk 'NR==2{print $4" 可用 / "$2" 总"}')
        LOAD_AVG=$(cat /proc/loadavg | awk '{print "1m:"$1" 5m:"$2" 15m:"$3}')
        
        print_header "VPS 初始化与安全工具 v$VERSION"
        echo -e "  系统: ${YELLOW}$OS_ID $OS_VERSION${NC}  |  维护: ${YELLOW}$(format_os_maintenance_status)${NC}"
        echo -e "  负载: ${YELLOW}$LOAD_AVG${NC}"
        echo -e "  内存: ${YELLOW}$MEM_STATUS${NC}  |  磁盘: ${YELLOW}$DISK_STATUS${NC}"
        echo -e "${DIM}--------------------------------------------------${NC}"
        print_menu_item 1 "系统维护" "更新 / 清理 / SWAP / 时区"
        print_menu_item 2 "SSH 与安全" "SSH / 密钥登录 / Fail2ban"
        print_menu_item 3 "网络配置" "BBR / DNS / IPv4·IPv6"
        print_menu_item 4 "状态与诊断" "配置汇总 / 校验 / 日志"
        echo -e "${DIM}--------------------------------------------------${NC}"
        echo -e "  ${DIM}0. 退出脚本${NC}"
        echo -e "${CYAN}==================================================${NC}"
        read -r -p "请输入选项 [0-4]: " choice_main

        case "$choice_main" in
            1) submenu_env ;;
            2) submenu_sec ;;
            3) submenu_net ;;
            4) submenu_status ;;
            0) clear; log "已安全退出脚本。"; exit 0 ;;
            *) error "无效输入，请重新选择！"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 启动执行
# ==========================================
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    check_os
    check_dependencies
    acquire_instance_lock
    main_menu
fi
