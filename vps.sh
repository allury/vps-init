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
IPV6_SYSCTL_FILE="/etc/sysctl.d/99-zz-vps-init-ipv6.conf"
SWAP_SYSCTL_FILE="/etc/sysctl.d/99-zz-vps-init-swap.conf"
SSH_MANAGED_FILE="/etc/ssh/sshd_config.d/00-00-vps-init.conf"
VERSION="1.1.7"
MANAGED_SWAP_FILE="/swapfile"
BACKUP_DIR="/var/backups/vps-init"

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
    local fallback_file="/tmp/vps_init-${EUID}.log"

    [[ "$LOG_MAX_BYTES" =~ ^[0-9]+$ ]] || LOG_MAX_BYTES=1048576
    [[ "$LOG_KEEP_LINES" =~ ^[0-9]+$ ]] || LOG_KEEP_LINES=1000
    (( LOG_MAX_BYTES > 0 )) || LOG_MAX_BYTES=1048576
    (( LOG_KEEP_LINES > 0 )) || LOG_KEEP_LINES=1000

    if [[ -L "$LOG_FILE" ]] || ! touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="$fallback_file"
        if [[ -L "$LOG_FILE" ]] || ! touch "$LOG_FILE" 2>/dev/null; then
            LOG_FILE="/dev/null"
            return 0
        fi
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
    printf '%s' "$1" | sed -E 's/\x1B\[[0-9;]*[mK]//g' | tr '\r\n' '  '
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
    [[ "$answer" == "y" || "$answer" == "Y" ]]
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

get_ssh_port() {
    sshd -T 2>/dev/null | awk '/^port /{print $2; exit}'
}

get_listening_ssh_ports() {
    ss -ltnp 2>/dev/null | awk '
        /sshd/ {
            address=$4
            sub(/^.*:/, "", address)
            if (address ~ /^[0-9]+$/ && !seen[address]++) ports[++count]=address
        }
        END {
            for (i=1; i<=count; i++) printf "%s%s", ports[i], (i<count ? "," : "")
        }'
}

render_fail2ban_sshd_section() {
    local source_file="$1"
    local output_file="$2"
    local port="$3"
    local mode="$4"
    local backend="${5:-}"
    local logpath="${6:-}"

    awk -v port="$port" -v mode="$mode" -v backend="$backend" -v logpath="$logpath" '
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
                print "filter = sshd"
                print "backend = " backend
                if (logpath != "") print "logpath = " logpath
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
                    (key == "enabled" || key == "port" || key == "filter" ||
                     key == "backend" || key == "logpath" || key == "maxretry" ||
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
    local backend="${3:-}"
    local logpath="${4:-}"
    local start_service="${5:-0}"
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
    local legacy_backup
    local legacy_existed=0

    backup_path="$BACKUP_DIR/fail2ban-$(date +%Y%m%d%H%M%S)-$$"
    backup_file="$backup_path/jail.local"
    legacy_backup="$backup_path/99-vps-init-port.local"

    require_commands "Fail2ban 配置" awk mktemp timeout fail2ban-client systemctl || return 1
    if [[ -L "$target_file" ]]; then
        error "$target_file 是符号链接，为避免修改未知目标已停止操作。"
        return 1
    fi
    mkdir -p "$backup_path" "$(dirname "$target_file")" || return 1
    if [[ -f "$target_file" ]]; then
        file_existed=1
        cp -a -- "$target_file" "$backup_file" || return 1
        section_count=$(awk 'tolower($0) ~ /^[[:space:]]*\[sshd\][[:space:]]*([#;].*)?$/ {count++} END {print count+0}' "$target_file")
        if (( section_count > 1 )); then
            error "$target_file 中存在多个 [sshd] 段，已停止自动修改。"
            return 1
        fi
    else
        : > "$backup_file" || return 1
    fi
    if [[ -L "$legacy_file" ]]; then
        error "$legacy_file 是符号链接，无法安全迁移到 jail.local。"
        return 1
    elif [[ -f "$legacy_file" ]]; then
        legacy_existed=1
        cp -a -- "$legacy_file" "$legacy_backup" || return 1
    fi

    service_active=$(systemctl is-active fail2ban 2>/dev/null || true)
    service_enabled=$(systemctl is-enabled fail2ban 2>/dev/null || true)
    source_file="$target_file"
    [[ "$file_existed" == "0" ]] && source_file=/dev/null
    temp_file=$(mktemp /etc/fail2ban/.vps-init-jail.XXXXXX) || return 1
    if ! render_fail2ban_sshd_section "$source_file" "$temp_file" "$port" "$mode" "$backend" "$logpath"; then
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

    if ! timeout 20 fail2ban-client -t >/dev/null 2>&1; then
        rollback_fail2ban_with_message "$backup_path" "Fail2ban 配置测试失败" \
            "$target_file" "$backup_file" "$file_existed" "$service_active" "$service_enabled" \
            "$legacy_file" "$legacy_backup" "$legacy_existed"
        return 1
    fi

    if [[ "$start_service" == "1" ]]; then
        if ! systemctl enable fail2ban >/dev/null 2>&1 || ! systemctl restart fail2ban; then
            rollback_fail2ban_with_message "$backup_path" "Fail2ban 启用或重启失败" \
                "$target_file" "$backup_file" "$file_existed" "$service_active" "$service_enabled" \
                "$legacy_file" "$legacy_backup" "$legacy_existed"
            return 1
        fi
    elif [[ "$service_active" == "active" ]] && ! systemctl restart fail2ban; then
        rollback_fail2ban_with_message "$backup_path" "Fail2ban 重启失败" \
            "$target_file" "$backup_file" "$file_existed" "$service_active" "$service_enabled" \
            "$legacy_file" "$legacy_backup" "$legacy_existed"
        return 1
    fi

    log "Fail2ban [sshd] 配置已在 $target_file 中增量更新并通过测试。备份：$backup_path"
    [[ "$legacy_existed" == "1" ]] && log "旧版独立端口文件已迁移并移除：$legacy_file"
    return 0
}

sync_fail2ban_ssh_port() {
    local port="$1"

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        return 0
    fi
    if update_fail2ban_sshd_jail "$port" port; then
        log "Fail2ban 已同步 SSH 端口 $port。"
    else
        error "SSH 已切换到端口 $port，但 Fail2ban 端口同步失败；请检查现有 jail.local。"
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
        if [[ -n "$real_file" ]] && sysctl_file_has_scope /etc/sysctl.conf tcp; then
            LEGACY_TCP_FILES+=(/etc/sysctl.conf)
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

choose_path_interactively() {
    local prompt="$1"
    shift
    local -a candidates=("$@")
    local index
    local choice

    echo "$prompt"
    for index in "${!candidates[@]}"; do
        printf ' %d. %s\n' "$((index + 1))" "${candidates[$index]}"
    done
    echo " 0. 取消"
    read -r -p "请选择配置文件: " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#candidates[@]} )); then
        SYSCTL_TARGET=""
        return 1
    fi
    SYSCTL_TARGET="${candidates[$((choice - 1))]}"
}

select_sysctl_target() {
    local resolved_target
    local latest_key_real
    local latest_key_name=""
    local candidate
    local candidate_name
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
            SYSCTL_TARGET="/etc/sysctl.d/99-vps-init-bbr.conf"
            echo -e "${YELLOW}候选文件指向系统目录，不会修改；改用 $SYSCTL_TARGET。${NC}"
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

write_sysctl_key() {
    local file="$1"
    local key="$2"
    local value="$3"
    local flexible_key="${key//./[.\/]}"

    sed -i -E "\\|^[[:space:]]*-?[[:space:]]*${flexible_key}[[:space:]]*=|d" "$file" || return 1
    printf '%s = %s\n' "$key" "$value" >> "$file"
}

remove_sysctl_key() {
    local file="$1"
    local key="$2"
    local flexible_key="${key//./[.\/]}"

    [[ -f "$file" ]] || return 0
    sed -i -E "\\|^[[:space:]]*-?[[:space:]]*${flexible_key}[[:space:]]*=|d" "$file"
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

    select_sysctl_target || {
        error "未选择 sysctl 配置文件，已取消 BBR 配置。"
        return 1
    }

    [[ "$write_bbr" == "0" ]] && result_label="FQ"
    detail "BBR" "DETECT" "目标=$SYSCTL_TARGET；写入 BBR=$write_bbr；原拥塞控制=${previous_cc:-未知}；原队列=${previous_qdisc:-未知}"

    if ! mkdir -p "$(dirname "$SYSCTL_TARGET")" "$BACKUP_DIR"; then
        error "无法创建 sysctl 配置或备份目录。"
        return 1
    fi
    if [[ -f "$SYSCTL_TARGET" ]]; then
        target_existed=1
        backup_file="$BACKUP_DIR/$(basename "$SYSCTL_TARGET").$(date +%Y%m%d%H%M%S)-$$.bak"
        if ! cp -a "$SYSCTL_TARGET" "$backup_file"; then
            error "无法备份 $SYSCTL_TARGET，未修改配置。"
            return 1
        fi
    else
        if ! touch "$SYSCTL_TARGET"; then
            error "无法创建 $SYSCTL_TARGET。"
            return 1
        fi
    fi

    if ! write_sysctl_key "$SYSCTL_TARGET" net.core.default_qdisc fq; then
        error "写入 FQ 配置失败。"
    elif [[ "$write_bbr" == "1" ]] && ! write_sysctl_key "$SYSCTL_TARGET" net.ipv4.tcp_congestion_control bbr; then
        error "写入 BBR 配置失败。"
    else
        effective_qdisc=$(get_effective_sysctl_value net.core.default_qdisc)
        effective_cc=$(get_effective_sysctl_value net.ipv4.tcp_congestion_control)
        if [[ "$effective_qdisc" != "fq" ]] || [[ "$write_bbr" == "1" && "$effective_cc" != "bbr" ]]; then
            error "配置文件加载顺序验证失败，重启后可能被其他 sysctl 文件覆盖。"
        elif sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 && \
             { [[ "$write_bbr" == "0" ]] || sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; } && \
             [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" == "fq" ]] && \
             { [[ "$write_bbr" == "0" ]] || [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; }; then
            log "$result_label 已生效并通过持久化顺序验证，配置写入 $SYSCTL_TARGET。"
            [[ -n "$backup_file" ]] && log "原配置备份：$backup_file"
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

check_os() {
    if [ -f /etc/os-release ]; then
        OS_ID=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        OS_VERSION=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        # 补丁：防范 testing/unstable 镜像 VERSION_ID 为空的致命缺陷
        if [[ -z "$OS_VERSION" ]]; then
            OS_CODENAME=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
            [[ "$OS_CODENAME" == "trixie" ]] && OS_VERSION="13"
            [[ "$OS_CODENAME" == "bookworm" ]] && OS_VERSION="12"
        fi
    else
        error "无法获取系统版本信息！"
        exit 1
    fi

    if [[ "$OS_ID" != "debian" && "$OS_ID" != "ubuntu" ]]; then
        error "当前系统 $OS_ID 不在支持范围内，仅支持 Debian 和 Ubuntu。"
        exit 1
    fi
}

check_dependencies() {
    local command_name
    local -a missing_commands=()
    local -a required_commands=(
        awk sed grep free df
    )

    for command_name in "${required_commands[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
    done
    if (( ${#missing_commands[@]} > 0 )); then
        error "缺少必要命令：${missing_commands[*]}"
        echo "请先安装 openssh-server、iproute2、procps、util-linux、coreutils 等基础软件包。"
        exit 1
    fi
}

# ==========================================
# 辅助函数：安全重启 SSH 服务（兼容 Ubuntu 24.04+）
# ==========================================
ssh_unit_exists() {
    systemctl cat "$1" >/dev/null 2>&1
}

begin_ssh_transaction() {
    SSH_BACKUP_PATH="$BACKUP_DIR/ssh-$(date +%Y%m%d%H%M%S)-$$"
    SSH_MANAGED_EXISTED=0
    SSH_SOCKET_ENABLED=$(systemctl is-enabled ssh.socket 2>/dev/null || true)
    SSH_SOCKET_ACTIVE=$(systemctl is-active ssh.socket 2>/dev/null || true)
    SSH_SERVICE_ENABLED=$(systemctl is-enabled ssh.service 2>/dev/null || true)
    SSH_SERVICE_ACTIVE=$(systemctl is-active ssh.service 2>/dev/null || true)

    if [[ -L "$SSH_MANAGED_FILE" ]]; then
        error "$SSH_MANAGED_FILE 是符号链接，为避免修改未知目标已停止操作。"
        return 1
    fi
    mkdir -p "$SSH_BACKUP_PATH" "$(dirname "$SSH_MANAGED_FILE")" || return 1
    cp -a /etc/ssh/sshd_config "$SSH_BACKUP_PATH/sshd_config" || return 1
    if [[ -e "$SSH_MANAGED_FILE" || -L "$SSH_MANAGED_FILE" ]]; then
        SSH_MANAGED_EXISTED=1
        cp -a "$SSH_MANAGED_FILE" "$SSH_BACKUP_PATH/managed.conf" || return 1
    fi
    detail "SSH" "BACKUP" "备份=$SSH_BACKUP_PATH；托管文件原先存在=$SSH_MANAGED_EXISTED；ssh.service 启用=$SSH_SERVICE_ENABLED/运行=$SSH_SERVICE_ACTIVE；ssh.socket 启用=$SSH_SOCKET_ENABLED/运行=$SSH_SOCKET_ACTIVE"
}

restore_unit_enablement() {
    local unit="$1"
    local state="$2"

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
}

restore_ssh_transaction() {
    local failed=0

    cp -a "$SSH_BACKUP_PATH/sshd_config" /etc/ssh/sshd_config || failed=1
    if [[ "$SSH_MANAGED_EXISTED" == "1" ]]; then
        cp -a "$SSH_BACKUP_PATH/managed.conf" "$SSH_MANAGED_FILE" || failed=1
    else
        rm -f "$SSH_MANAGED_FILE" || failed=1
    fi

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

    configured_port=$(get_ssh_port)
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

write_sshd_key() {
    local key="$1"
    local value="$2"

    sed -i -E "/^[[:space:]]*${key}[[:space:]]+/Id" "$SSH_MANAGED_FILE" || return 1
    printf '%s %s\n' "$key" "$value" >> "$SSH_MANAGED_FILE"
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

restart_ssh() {
    if [[ "$OS_ID" == "ubuntu" ]]; then
        UBUNTU_MAJOR="${OS_VERSION%%.*}"
        if [[ "$UBUNTU_MAJOR" =~ ^[0-9]+$ && "$UBUNTU_MAJOR" -ge 24 ]]; then
            # Ubuntu 24.04+ 必须切换到 ssh.service，socket 不重新监听新端口
            if ssh_unit_exists ssh.socket; then
                systemctl stop ssh.socket 2>/dev/null || return 1
                systemctl disable ssh.socket 2>/dev/null || return 1
                systemctl mask ssh.socket >/dev/null 2>&1 || return 1
            fi
            systemctl enable ssh.service >/dev/null 2>&1 || return 1
            systemctl daemon-reload || return 1
            systemctl restart ssh.service
        else
            systemctl daemon-reload || return 1
            systemctl restart ssh.socket 2>/dev/null || systemctl restart ssh 2>/dev/null
        fi
    else
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi
}

begin_swap_transaction() {
    SWAP_BACKUP_PATH="$BACKUP_DIR/swap-$(date +%Y%m%d%H%M%S)-$$"
    SWAP_SYSCTL_EXISTED=0
    SWAP_PREVIOUS_SWAPPINESS=$(sysctl -n vm.swappiness 2>/dev/null)

    mkdir -p "$SWAP_BACKUP_PATH" "$(dirname "$SWAP_SYSCTL_FILE")" || return 1
    cp -a /etc/fstab "$SWAP_BACKUP_PATH/fstab" || return 1
    if [[ -e "$SWAP_SYSCTL_FILE" || -L "$SWAP_SYSCTL_FILE" ]]; then
        if [[ -L "$SWAP_SYSCTL_FILE" ]]; then
            error "$SWAP_SYSCTL_FILE 是符号链接，为避免修改未知目标已停止操作。"
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
    if [[ -n "$SWAP_PREVIOUS_SWAPPINESS" ]]; then
        sysctl -w "vm.swappiness=$SWAP_PREVIOUS_SWAPPINESS" >/dev/null 2>&1 || failed=1
        [[ "$(sysctl -n vm.swappiness 2>/dev/null)" == "$SWAP_PREVIOUS_SWAPPINESS" ]] || failed=1
    fi
    return "$failed"
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

    if [[ -f "$SWAP_SYSCTL_FILE" ]]; then
        marker_value=$(awk -F= '/^[[:space:]]*#[[:space:]]*vps-init-previous-vm-swappiness[[:space:]]*=/ {
            value=$2; gsub(/[[:space:]]/, "", value); saved=value
        } END {print saved}' "$SWAP_SYSCTL_FILE")
        sed -i -E '/^[[:space:]]*#[[:space:]]*vps-init-previous-vm-swappiness[[:space:]]*=/d' "$SWAP_SYSCTL_FILE" || return 1
        remove_sysctl_key "$SWAP_SYSCTL_FILE" vm.swappiness || return 1
        if ! grep -qE '[^[:space:]]' "$SWAP_SYSCTL_FILE"; then
            rm -f "$SWAP_SYSCTL_FILE" || return 1
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

create_managed_swap() {
    local swap_size="$1"
    local expected_bytes
    local count_val
    local actual_bytes
    local fstab_temp

    if command -v numfmt >/dev/null 2>&1; then
        expected_bytes=$(numfmt --from=iec "$swap_size" 2>/dev/null) || return 1
    else
        local number="${swap_size//[^0-9]/}"
        local unit="${swap_size//[0-9]/}"
        if [[ "${unit^^}" == "G" ]]; then
            expected_bytes=$((number * 1024 * 1024 * 1024))
        else
            expected_bytes=$((number * 1024 * 1024))
        fi
    fi
    count_val=$((expected_bytes / 1048576))

    if ! begin_swap_transaction; then
        error "无法完成 SWAP 配置备份，未创建文件。"
        return 1
    fi

    log "正在创建 $swap_size 的 SWAP 文件..."
    if ! fallocate -l "$expected_bytes" "$MANAGED_SWAP_FILE" 2>/dev/null; then
        if [[ -e "$MANAGED_SWAP_FILE" ]] && ! rm -f "$MANAGED_SWAP_FILE"; then
            error "fallocate 失败后无法移除不完整的 SWAP 文件。"
            rollback_swap_creation
            return 1
        fi
        log "当前文件系统不支持 fallocate，正在降级使用 dd 创建..."
        if ! dd if=/dev/zero of="$MANAGED_SWAP_FILE" bs=1M count="$count_val" status=progress conv=fsync; then
            error "dd 创建 SWAP 文件失败。"
            rollback_swap_creation
            return 1
        fi
    fi

    actual_bytes=$(stat -c%s "$MANAGED_SWAP_FILE" 2>/dev/null)
    if [[ "$actual_bytes" != "$expected_bytes" ]]; then
        error "SWAP 文件大小校验失败：期望 $expected_bytes bytes，实际 ${actual_bytes:-未知}。"
        rollback_swap_creation
        return 1
    fi
    if ! chmod 600 "$MANAGED_SWAP_FILE" || \
       ! mkswap "$MANAGED_SWAP_FILE" >/dev/null || \
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
       ! printf '%s none swap sw 0 0 # managed by vps-init\n' "$MANAGED_SWAP_FILE" >> "$fstab_temp" || \
       ! mv -f "$fstab_temp" /etc/fstab; then
        rm -f "$fstab_temp"
        error "写入 /etc/fstab 失败。"
        rollback_swap_creation
        return 1
    fi

    touch "$SWAP_SYSCTL_FILE" || {
        rollback_swap_creation
        return 1
    }
    sed -i -E '/^[[:space:]]*#[[:space:]]*vps-init-previous-vm-swappiness[[:space:]]*=/d' "$SWAP_SYSCTL_FILE" || {
        rollback_swap_creation
        return 1
    }
    printf '# vps-init-previous-vm-swappiness = %s\n' "${SWAP_PREVIOUS_SWAPPINESS:-60}" >> "$SWAP_SYSCTL_FILE" || {
        rollback_swap_creation
        return 1
    }
    if ! write_sysctl_key "$SWAP_SYSCTL_FILE" vm.swappiness 10 || \
       ! sysctl -w vm.swappiness=10 >/dev/null 2>&1 || \
       [[ "$(sysctl -n vm.swappiness 2>/dev/null)" != "10" ]] || \
       [[ "$(get_effective_sysctl_value vm.swappiness)" != "10" ]]; then
        error "vm.swappiness 写入或持久化顺序验证失败。"
        rollback_swap_creation
        return 1
    fi

    log "SWAP 创建成功并通过持久化验证。备份：$SWAP_BACKUP_PATH"
}

remove_managed_swap() {
    local was_active="$1"
    local fstab_temp

    if ! begin_swap_transaction; then
        error "无法备份 SWAP 配置，未执行删除。"
        return 1
    fi
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
    if ! awk -v path="$MANAGED_SWAP_FILE" '!($1==path && $3=="swap")' /etc/fstab > "$fstab_temp" || \
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

    log "$MANAGED_SWAP_FILE 已安全删除；其他 SWAP 保持不变，vm.swappiness 已恢复为 ${SWAP_RESTORED_SWAPPINESS:-系统值}。备份：$SWAP_BACKUP_PATH"
}

# ==========================================
# 模块一：SWAP 配置
# ==========================================
submenu_swap() {
    require_commands "SWAP 配置" swapon swapoff mkswap stat dd mktemp awk sed sysctl find readlink sort || { pause_menu; return; }
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
            if swapon --show | grep -q "." || awk '!/^#/ && $3=="swap"' /etc/fstab | grep -q "."; then
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
                awk -v path="$MANAGED_SWAP_FILE" '!/^[[:space:]]*#/ && $1==path && $3=="swap" {found=1} END {exit !found}' /etc/fstab && SWAP_CONFIGURED=1

                if [[ "$SWAP_ACTIVE" == "0" && "$SWAP_CONFIGURED" == "0" ]]; then
                    error "未检测到由脚本管理的 $MANAGED_SWAP_FILE；其他 SWAP 分区或文件不会被删除。"
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
            create_managed_swap "$swap_size"
            pause_menu
        fi
    done
}

# ==========================================
# 模块一：时间与时区配置
# ==========================================
submenu_timezone() {
    local time_sync_service
    local candidate_service
    local ntp_synchronized

    require_commands "时区配置" timedatectl systemctl || { pause_menu; return; }
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

        log "正在设置时区并检查时间同步服务：$target_tz ..."
        timedatectl set-timezone "$target_tz" 2>/dev/null

        if [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" != "$target_tz" ]]; then
            error "时区设置失败！"
            pause_menu; continue
        fi

        time_sync_service=""
        for candidate_service in systemd-timesyncd.service chrony.service; do
            if [[ "$(systemctl is-active "$candidate_service" 2>/dev/null)" == "active" ]]; then
                time_sync_service="$candidate_service"
                break
            fi
        done
        if [[ -z "$time_sync_service" ]]; then
            for candidate_service in systemd-timesyncd.service chrony.service; do
                if systemctl cat "$candidate_service" >/dev/null 2>&1 && \
                   [[ "$(systemctl is-enabled "$candidate_service" 2>/dev/null)" != masked* ]]; then
                    time_sync_service="$candidate_service"
                    break
                fi
            done
        fi
        if [[ -z "$time_sync_service" ]]; then
            require_commands "时间同步服务安装" apt-get dpkg || {
                error "时区已设置，但无法安装时间同步服务。"
                pause_menu; continue
            }
            package_manager_ready || {
                error "时区已设置，但软件包管理器当前不可用，时间同步未配置。"
                pause_menu; continue
            }
            if apt-get install systemd-timesyncd -y >/dev/null 2>&1 && \
               systemctl cat systemd-timesyncd.service >/dev/null 2>&1; then
                time_sync_service="systemd-timesyncd.service"
            else
                error "时区已设置，但 systemd-timesyncd 安装失败。"
                pause_menu; continue
            fi
        fi

        if ! systemctl enable --now "$time_sync_service" >/dev/null 2>&1 || \
           [[ "$(systemctl is-active "$time_sync_service" 2>/dev/null)" != "active" ]]; then
            error "时区已设置，但时间同步服务 $time_sync_service 启用失败。"
            pause_menu; continue
        fi

        ntp_synchronized=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
        if [[ "$ntp_synchronized" == "yes" ]]; then
            log "时区配置成功且系统时间已同步。当前时间：$(date "+%Y-%m-%d %H:%M:%S %Z")"
        else
            warn "时区已设置，时间同步服务 $time_sync_service 正在运行，但尚未确认完成同步；请稍后用 timedatectl status 复查。"
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
        error "检测到未完成的软件包配置，请先处理后再执行清理："
        echo "$audit_output"
        return 1
    fi
}

parse_apt_simulated_removals() {
    awk '$1 == "Remv" || $1 == "Purg" {print $2}'
}

collect_package_cleanup_candidates() {
    local package
    local simulation_output
    local -a simulated_packages=()

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
        case "$package" in
            linux-image-*|linux-headers-*|linux-modules-*)
                AUTOREMOVE_KERNEL_PACKAGES+=("$package")
                ;;
            *)
                AUTOREMOVE_PACKAGES+=("$package")
                ;;
        esac
    done

    mapfile -t RESIDUAL_PACKAGES < <(
        dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' 2>/dev/null |
            awk '$2 ~ /^rc/ {print $1}'
    )
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

perform_package_cleanup() {
    local failed=0

    if (( ${#AUTOREMOVE_PACKAGES[@]} > 0 )); then
        if apt-get purge -y -- "${AUTOREMOVE_PACKAGES[@]}"; then
            print_result "无用依赖包" "已完成" "${#AUTOREMOVE_PACKAGES[@]} 个"
        else
            print_result "无用依赖包" "失败"
            failed=1
        fi
    else
        print_result "无用依赖包" "跳过" "未发现"
    fi

    if (( ${#RESIDUAL_PACKAGES[@]} > 0 )); then
        if apt-get purge -y -- "${RESIDUAL_PACKAGES[@]}"; then
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
    local directory
    local count=0

    for directory in /var/crash /var/lib/systemd/coredump; do
        [[ -d "$directory" ]] || continue
        count=$((count + $(find "$directory" -xdev -type f -mtime +7 -print 2>/dev/null | wc -l)))
    done
    echo "$count"
}

perform_log_cleanup() {
    local directory
    local crash_failed=0
    local failed=0

    if command -v journalctl >/dev/null 2>&1; then
        if journalctl --vacuum-time=7d; then
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

    for directory in /var/crash /var/lib/systemd/coredump; do
        [[ -d "$directory" ]] || continue
        if ! find "$directory" -xdev -type f -mtime +7 -delete 2>/dev/null; then
            crash_failed=1
        fi
    done
    if [[ "$crash_failed" == "0" ]]; then
        print_result "过期崩溃转储" "已完成" "仅删除 7 天前文件"
    else
        print_result "过期崩溃转储" "失败"
        failed=1
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

collect_old_kernel_candidates() {
    local retention_policy="${1:-keep-fallback}"
    local image
    local owner
    local release
    local package
    local current_kernel
    local latest_kernel
    local fallback_kernel
    local retained_release
    local old_release
    local related_stem
    local old_uses_related
    local retained_uses_related
    local -a installed_releases=()
    local -a installed_kernel_packages=()
    local -a retained_releases=()

    OLD_KERNEL_RELEASES=()
    OLD_KERNEL_PACKAGES=()
    current_kernel=$(uname -r)

    if [[ "$retention_policy" != "keep-fallback" && "$retention_policy" != "current-only" ]]; then
        error "未知的旧内核保留策略：$retention_policy"
        return 1
    fi

    for image in /boot/vmlinuz-*; do
        [[ -e "$image" ]] || continue
        owner=$(dpkg-query -S "$image" 2>/dev/null | awk -F': ' 'NR==1 {print $1}')
        [[ "$owner" == linux-image-* ]] || continue
        installed_releases+=("${image#/boot/vmlinuz-}")
    done

    if (( ${#installed_releases[@]} == 0 )); then
        warn "未在 /boot 中检测到由软件包管理器安装的内核。"
        return 1
    fi
    mapfile -t installed_releases < <(printf '%s\n' "${installed_releases[@]}" | sort -Vu)

    if ! printf '%s\n' "${installed_releases[@]}" | grep -Fxq "$current_kernel"; then
        warn "当前运行内核 $current_kernel 不在可识别的软件包列表中，已停止清理。"
        return 1
    fi
    latest_kernel="${installed_releases[-1]}"
    if [[ "$current_kernel" != "$latest_kernel" ]]; then
        warn "当前运行内核 $current_kernel 不是最新已安装内核 $latest_kernel，请先重启。"
        return 1
    fi
    if [[ -f /var/run/reboot-required ]]; then
        warn "系统提示需要重启，为避免删除仍需回退的内核，本次不执行旧内核清理。"
        return 1
    fi

    if [[ "$retention_policy" == "keep-fallback" ]]; then
        if (( ${#installed_releases[@]} <= 2 )); then
            echo -e "${GREEN}当前仅有运行内核和一个备用内核，无需清理。${NC}"
            return 0
        fi
        fallback_kernel="${installed_releases[-2]}"
        retained_releases=("$current_kernel" "$latest_kernel" "$fallback_kernel")
    else
        if (( ${#installed_releases[@]} <= 1 )); then
            echo -e "${GREEN}当前没有可删除的旧内核。${NC}"
            return 0
        fi
        retained_releases=("$current_kernel")
    fi

    for release in "${installed_releases[@]}"; do
        if printf '%s\n' "${retained_releases[@]}" | grep -Fxq "$release"; then
            continue
        fi
        OLD_KERNEL_RELEASES+=("$release")
    done

    mapfile -t installed_kernel_packages < <(
        dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' \
            'linux-image-[0-9]*' 'linux-image-unsigned-[0-9]*' \
            'linux-image-extra-[0-9]*' \
            'linux-headers-[0-9]*' 'linux-modules-[0-9]*' \
            'linux-modules-extra-[0-9]*' 'linux-tools-[0-9]*' \
            'linux-cloud-tools-[0-9]*' 2>/dev/null |
            awk '$2 ~ /^ii/ {sub(/:.*/, "", $1); print $1}'
    )

    for release in "${OLD_KERNEL_RELEASES[@]}"; do
        for package in "${installed_kernel_packages[@]}"; do
            case "$package" in
                linux-image-"$release"|linux-image-unsigned-"$release"|\
                 linux-image-extra-"$release"|\
                 linux-modules-"$release"|linux-modules-extra-"$release"|\
                 linux-headers-"$release"|linux-tools-"$release"|\
                 linux-cloud-tools-"$release")
                    add_unique_path OLD_KERNEL_PACKAGES "$package"
                    ;;
            esac
        done
    done

    for package in "${installed_kernel_packages[@]}"; do
        case "$package" in
            linux-headers-[0-9]*)
                related_stem="${package#linux-headers-}"
                ;;
            linux-tools-[0-9]*)
                related_stem="${package#linux-tools-}"
                ;;
            linux-cloud-tools-[0-9]*)
                related_stem="${package#linux-cloud-tools-}"
                ;;
            *)
                continue
                ;;
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
        for retained_release in "${retained_releases[@]}"; do
            if [[ "$retained_release" == "$related_stem"-* ]]; then
                retained_uses_related=1
                break
            fi
        done
        if [[ "$retained_uses_related" == "0" ]]; then
            add_unique_path OLD_KERNEL_PACKAGES "$package"
        fi
    done

    echo "当前运行内核：$current_kernel"
    if [[ "$retention_policy" == "keep-fallback" ]]; then
        echo "保留备用内核：$fallback_kernel"
    else
        echo -e "${RED}保留策略：仅保留当前运行内核，不保留备用内核${NC}"
    fi
}

validate_old_kernel_removal_plan() {
    local package
    local planned
    local simulation_output
    local -a planned_removals=()

    if ! simulation_output=$(LC_ALL=C apt-get -s purge -- "${OLD_KERNEL_PACKAGES[@]}" 2>&1); then
        error "无法生成旧内核删除预览，已停止操作："
        echo "$simulation_output"
        return 1
    fi
    mapfile -t planned_removals < <(
        printf '%s\n' "$simulation_output" | parse_apt_simulated_removals
    )
    if (( ${#planned_removals[@]} == 0 )); then
        error "删除预览中未发现任何候选软件包，已停止操作。"
        return 1
    fi
    for planned in "${planned_removals[@]}"; do
        if ! printf '%s\n' "${OLD_KERNEL_PACKAGES[@]}" | grep -Fxq "$planned"; then
            error "模拟删除还会影响非候选软件包 $planned，已停止操作。"
            return 1
        fi
    done

    for package in "${OLD_KERNEL_PACKAGES[@]}"; do
        if ! printf '%s\n' "${planned_removals[@]}" | grep -Fxq "$package"; then
            error "模拟删除未包含候选软件包 $package，已停止操作。"
            return 1
        fi
    done
    return 0
}

perform_old_kernel_removal() {
    local result_label="$1"
    local before
    local after
    local current_kernel

    current_kernel=$(uname -r)
    before=$(get_root_used_bytes)
    if apt-get purge -y -- "${OLD_KERNEL_PACKAGES[@]}"; then
        if [[ ! -e "/boot/vmlinuz-$current_kernel" ]] ||
           ! dpkg-query -S "/boot/vmlinuz-$current_kernel" >/dev/null 2>&1; then
            print_result "$result_label" "部分完成" "当前内核引导文件验证失败"
            error "当前运行内核的引导文件或软件包归属异常，请勿重启并立即检查 /boot。"
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
        print_result "$result_label" "已完成" "${#OLD_KERNEL_RELEASES[@]} 个版本"
    else
        print_result "$result_label" "失败"
        return 1
    fi
    after=$(get_root_used_bytes)
    show_released_space "$before" "$after"
}

cleanup_old_kernels() {
    package_manager_ready || return 1
    collect_old_kernel_candidates keep-fallback || return 1
    if (( ${#OLD_KERNEL_RELEASES[@]} == 0 )); then
        return 0
    fi
    if (( ${#OLD_KERNEL_PACKAGES[@]} == 0 )); then
        error "已识别旧内核版本，但未找到对应的已安装软件包，已停止操作。"
        return 1
    fi

    echo "候选旧内核版本："
    printf ' - %s\n' "${OLD_KERNEL_RELEASES[@]}"
    echo "关联软件包："
    printf ' - %s\n' "${OLD_KERNEL_PACKAGES[@]}"
    validate_old_kernel_removal_plan || return 1

    echo -e "${YELLOW}旧内核不会被常规清理自动删除，本操作仅在你确认后执行。${NC}"
    confirm_action "确认删除以上旧内核吗？" || return 0
    perform_old_kernel_removal "旧内核"
}

cleanup_all_old_kernels() {
    local typed_confirmation
    local expected_current_kernel

    package_manager_ready || return 1
    expected_current_kernel=$(uname -r)
    collect_old_kernel_candidates current-only || return 1
    if (( ${#OLD_KERNEL_RELEASES[@]} == 0 )); then
        return 0
    fi
    if (( ${#OLD_KERNEL_PACKAGES[@]} == 0 )); then
        error "已识别旧内核版本，但未找到对应的已安装软件包，已停止操作。"
        return 1
    fi

    echo -e "${RED}高风险操作：以下全部旧内核将被删除，只保留当前运行内核。${NC}"
    echo "待删除的旧内核版本："
    printf ' - %s\n' "${OLD_KERNEL_RELEASES[@]}"
    echo "关联软件包："
    printf ' - %s\n' "${OLD_KERNEL_PACKAGES[@]}"
    validate_old_kernel_removal_plan || return 1

    echo -e "${RED}删除后系统将没有备用内核；当前内核后续若无法启动，只能通过云厂商控制台或救援模式修复。${NC}"
    confirm_action "确认继续删除所有旧内核吗？" || return 0
    read -r -p "请输入“删除所有旧内核”进行最终确认: " typed_confirmation
    if [[ "$typed_confirmation" != "删除所有旧内核" ]]; then
        warn "确认文字不匹配，已取消操作。"
        return 0
    fi

    if [[ -f /var/run/reboot-required ]] || [[ "$(uname -r)" != "$expected_current_kernel" ]]; then
        error "最终执行前检测到内核状态变化或需要重启，已停止操作。"
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

    command -v journalctl >/dev/null 2>&1 &&
        journal_usage=$(journalctl --disk-usage 2>/dev/null | sed 's/^Archived and active journals take up //')
    crash_count=$(get_old_crash_count)

    echo "systemd 日志占用：$journal_usage"
    echo "7 天前的崩溃转储：$crash_count 个"
    echo "临时文件将严格按照 systemd-tmpfiles 的系统策略清理。"
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
    echo " - 过期崩溃转储：$crash_count 个"
    if (( ${#AUTOREMOVE_KERNEL_PACKAGES[@]} > 0 )); then
        echo -e "${YELLOW} - 内核相关候选：${#AUTOREMOVE_KERNEL_PACKAGES[@]} 个（本次保留）${NC}"
    fi
    echo " - 过期临时文件：按 systemd-tmpfiles 策略"
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

cleanup_disabled_snaps() {
    local entry
    local name
    local revision
    local failed=0
    local -a disabled_snaps=()

    if ! command -v snap >/dev/null 2>&1; then
        echo -e "${YELLOW}未安装 Snap，已跳过。${NC}"
        return 0
    fi
    mapfile -t disabled_snaps < <(LANG=C snap list --all 2>/dev/null | awk '$6=="disabled" {print $1"\t"$3}')
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
                    docker system df
                    confirm_action "确认清理 Docker 悬空镜像吗？不会删除容器和数据卷。" &&
                        docker image prune -f
                fi
                pause_menu
                ;;
            3)
                if ! command -v docker >/dev/null 2>&1; then
                    warn "未安装 Docker。"
                else
                    docker system df
                    confirm_action "确认清理 Docker 构建缓存吗？不会删除容器和数据卷。" &&
                        docker builder prune -f
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

update_system_packages() {
    require_commands "系统更新" apt-get dpkg || return 1
    package_manager_ready || return 1
    export DEBIAN_FRONTEND=noninteractive

    log "开始执行系统更新..."
    apt-get update || {
        error "更新软件源失败！"
        return 1
    }
    apt-get full-upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" || {
        error "系统升级失败！"
        return 1
    }

    log "系统更新完成，未执行任何清理操作。"
    if [[ -f /var/run/reboot-required ]]; then
        echo -e "${YELLOW}检测到系统需要重启。请先重启，再考虑清理旧内核。${NC}"
        [[ -f /var/run/reboot-required.pkgs ]] && sed 's/^/ - /' /var/run/reboot-required.pkgs
    fi
    return 0
}

# ==========================================
# 模块一：二级菜单 - 基础环境与系统优化
# ==========================================
submenu_env() {
    local choice_env

    while true; do
        print_header "系统维护"
        print_menu_item 1 "更新系统软件包" "仅更新，不自动清理"
        print_menu_item 2 "系统清理" "缓存 / 无用包 / 旧内核 / 日志 ›"
        print_menu_item 3 "SWAP 配置" "›"
        print_menu_item 4 "时间与时区配置" "›"
        echo -e "  ${DIM}0. 返回主菜单${NC}"
        echo -e "${CYAN}==================================================${NC}"
        read -r -p "请输入选项 [0-4]: " choice_env

        case "$choice_env" in
            1) update_system_packages; pause_menu ;;
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
    require_commands "SSH 配置" sshd ss systemctl timeout awk sed grep mktemp || { pause_menu; return; }
    while true; do
        print_header "SSH 端口与登录设置"
        CURRENT_PORT=$(get_ssh_port)
        [[ -z "$CURRENT_PORT" ]] && CURRENT_PORT="未知"
        LISTENING_PORTS=$(get_listening_ssh_ports)
        [[ -z "$LISTENING_PORTS" ]] && LISTENING_PORTS="未检测到"
        
        PWD_AUTH=$(sshd -T 2>/dev/null | grep -i "^passwordauthentication " | awk '{print $2}')
        case "$PWD_AUTH" in
            yes) PWD_STATUS="${RED}已开启（存在爆破风险）${NC}" ;;
            no) PWD_STATUS="${GREEN}已禁用${NC}" ;;
            *) PWD_STATUS="${YELLOW}未知（请先检查 sshd 配置）${NC}" ;;
        esac
        
        echo -e "配置的 SSH 端口: ${YELLOW}$CURRENT_PORT${NC}"
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
                read -r -p "请输入新的 SSH 端口号 (10000-65535): " new_port
                if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 10000 ] || [ "$new_port" -gt 65535 ]; then
                    error "端口号无效！请输入 10000 到 65535 之间的纯数字。"
                    pause_menu; continue
                fi

                if [[ "$new_port" == "$CURRENT_PORT" ]]; then
                    log "SSH 当前已配置为端口 $new_port，无需修改。"
                    pause_menu; continue
                fi
                if ss -tuln | grep -q ":$new_port "; then
                    error "端口 $new_port 已被占用，请更换端口！"
                    pause_menu; continue
                fi

                log "正在备份 SSH 配置和服务状态..."
                if ! begin_ssh_transaction; then
                    error "SSH 备份失败，未修改任何配置。"
                    pause_menu; continue
                fi

                if ! ensure_ssh_managed_include || ! write_sshd_key Port "$new_port"; then
                    rollback_ssh_with_message "SSH 托管配置写入失败"
                    pause_menu; continue
                fi

                if ! sshd -t 2>/dev/null || [[ "$(get_ssh_port)" != "$new_port" ]]; then
                    rollback_ssh_with_message "SSH 语法或生效配置验证失败"
                    pause_menu; continue
                fi

                if ! restart_ssh; then
                    rollback_ssh_with_message "SSH 服务重启失败"
                    pause_menu; continue
                fi

                sleep 1
                LISTENING_PORTS=$(get_listening_ssh_ports)
                if ! tr ',' '\n' <<< "$LISTENING_PORTS" | grep -Fxq "$new_port" || \
                   ! timeout 3 bash -c "</dev/tcp/127.0.0.1/$new_port" 2>/dev/null; then
                    rollback_ssh_with_message "端口 $new_port 未通过实际监听验证"
                    pause_menu; continue
                fi

                sync_fail2ban_ssh_port "$new_port"
                log "SSH 端口修改成功，当前实际监听：${LISTENING_PORTS:-未知}。备份：$SSH_BACKUP_PATH"
                warn "请先在新终端使用端口 $new_port 登录成功，再关闭当前会话；同时确认云安全组和防火墙已放行。"
                pause_menu
                ;;
                
            2)
                if ! has_valid_root_authorized_key; then
                    error "检测失败！未发现可由 ssh-keygen 识别的 root SSH 公钥。"
                    error "请先在本地终端执行 'ssh-copy-id -p 端口 root@IP' 上传公钥！"
                    pause_menu; continue
                fi

                confirm_action "已检测到有效公钥，确认禁用密码和键盘交互登录吗？" || continue

                log "正在备份并配置密钥登录..."
                if ! begin_ssh_transaction; then
                    error "SSH 备份失败，未修改任何配置。"
                    pause_menu; continue
                fi

                if ! ensure_ssh_managed_include || \
                   ! write_sshd_key PubkeyAuthentication yes || \
                   ! write_sshd_key PasswordAuthentication no || \
                   ! write_sshd_key KbdInteractiveAuthentication no || \
                   ! write_sshd_key ChallengeResponseAuthentication no; then
                    rollback_ssh_with_message "SSH 登录配置写入失败"
                    pause_menu; continue
                fi

                if ! sshd -t 2>/dev/null || \
                   [[ "$(sshd -T 2>/dev/null | awk '/^pubkeyauthentication /{print $2; exit}')" != "yes" ]] || \
                   [[ "$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2; exit}')" != "no" ]] || \
                   [[ "$(sshd -T 2>/dev/null | awk '/^kbdinteractiveauthentication /{print $2; exit}')" != "no" ]]; then
                    rollback_ssh_with_message "SSH 登录配置验证失败"
                    pause_menu; continue
                fi

                if ! restart_ssh; then
                    rollback_ssh_with_message "SSH 服务重启失败"
                    pause_menu; continue
                fi

                log "密钥登录已启用，密码与键盘交互登录已禁用。备份：$SSH_BACKUP_PATH"
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
                export DEBIAN_FRONTEND=noninteractive
                require_commands "Fail2ban 安装" apt-get systemctl || { pause_menu; continue; }
                package_manager_ready || { pause_menu; continue; }
                echo -e "${YELLOW}正在更新源并安装 Fail2ban，请稍候...${NC}"
                apt-get update -y >/dev/null 2>&1 || { error "源更新失败，请检查网络！"; pause_menu; continue; }
                apt-get install fail2ban -y >/dev/null 2>&1 || { error "Fail2ban 安装失败！"; pause_menu; continue; }
                
                log "正在配置防爆破规则..."
                CURRENT_PORT=$(get_ssh_port)
                if [[ -z "$CURRENT_PORT" ]]; then
                    error "无法读取 SSH 当前生效端口，已停止配置 Fail2ban。"
                    pause_menu; continue
                fi
                
                UBUNTU_MAJOR="${OS_VERSION%%.*}"
                if [[ "$OS_ID" == "ubuntu" && "$UBUNTU_MAJOR" =~ ^[0-9]+$ && "$UBUNTU_MAJOR" -ge 22 ]] || \
                   [[ "$OS_ID" == "debian" && "$OS_VERSION" =~ ^[0-9]+$ && "$OS_VERSION" -ge 12 && ! -f /var/log/auth.log ]]; then
                    F2B_BACKEND="systemd"
                    F2B_LOGPATH=""
                else
                    F2B_BACKEND="auto"
                    F2B_LOGPATH="/var/log/auth.log"
                fi

                if ! update_fail2ban_sshd_jail "$CURRENT_PORT" full "$F2B_BACKEND" "$F2B_LOGPATH" 1; then
                    pause_menu; continue
                fi
                
                log "Fail2ban 部署完成，当前已自动监听 $CURRENT_PORT 端口。"
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

    if systemctl is-active systemd-resolved >/dev/null 2>&1 && command -v resolvectl >/dev/null 2>&1; then
        dns_output=$(resolvectl dns 2>/dev/null)
    else
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

validate_dns_address() {
    local address="$1"
    local octet
    local part
    local part_count=0
    local -a ipv4_octets=()
    local -a ipv6_parts=()

    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import ipaddress, sys; ipaddress.ip_address(sys.argv[1])' "$address" >/dev/null 2>&1
        return $?
    fi

    if [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a ipv4_octets <<< "$address"
        for octet in "${ipv4_octets[@]}"; do
            (( 10#$octet <= 255 )) || return 1
        done
        return 0
    fi

    [[ "$address" == *:* ]] || return 1
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
        ((part_count++))
    done

    if [[ "$address" == *::* ]]; then
        (( part_count < 8 ))
    else
        (( part_count == 8 ))
    fi
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

    if [[ "$DNS_NETPLAN_APPLIED" == "1" ]] && command -v netplan >/dev/null 2>&1; then
        command_output=$(netplan generate 2>&1)
        command_status=$?
        if (( command_status != 0 )); then
            detail "DNS" "ROLLBACK_NETPLAN" "netplan generate 失败，退出码=$command_status，输出=${command_output:-无}"
            failed=1
        else
            command_output=$(timeout 30 netplan apply 2>&1)
            command_status=$?
            if (( command_status != 0 )); then
                detail "DNS" "ROLLBACK_NETPLAN" "netplan apply 失败，退出码=$command_status，输出=${command_output:-无}"
                failed=1
            fi
        fi
    fi
    if [[ "$DNS_RESOLVED_ACTIVE" == "1" ]]; then
        command_output=$(timeout 30 systemctl restart systemd-resolved 2>&1)
        command_status=$?
        if (( command_status != 0 )); then
            detail "DNS" "ROLLBACK_RESOLVED" "systemd-resolved 重启失败，退出码=$command_status，输出=${command_output:-无}"
            failed=1
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

sync_interfaces_dns() {
    local dns_line="$1"
    local default_iface
    local file
    local target_file=""
    local temp_file
    local -a interface_files=()
    local -a matches=()

    default_iface=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
    [[ -n "$default_iface" ]] || return 0
    [[ -f /etc/network/interfaces ]] && interface_files+=(/etc/network/interfaces)
    if [[ -d /etc/network/interfaces.d ]]; then
        while IFS= read -r -d '' file; do
            interface_files+=("$file")
        done < <(find /etc/network/interfaces.d -maxdepth 1 -type f -print0 2>/dev/null)
    fi

    for file in "${interface_files[@]}"; do
        if awk -v iface="$default_iface" '$1 == "iface" && $2 == iface && $3 == "inet" {found=1} END {exit(found ? 0 : 1)}' "$file"; then
            matches+=("$file")
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
    log "已同步 $target_file 中默认网卡 $default_iface 的 DNS。"
    [[ "$target_file" == *50-cloud-init* ]] && echo -e "${YELLOW}注意：该文件由 cloud-init 生成，云平台后续启动时仍可能覆盖它。${NC}"
    return 0
}

sync_netplan_dns() {
    local dns_csv="$1"
    local default_iface
    local override_file="/etc/netplan/99-vps-init-dns.yaml"
    local dhcp4
    local dhcp6
    local command_output
    local command_status

    command -v netplan >/dev/null 2>&1 || return 0
    [[ -d /etc/netplan ]] || return 0
    if [[ -L "$override_file" ]]; then
        error "$override_file 是符号链接，为避免修改未知目标已停止 DNS 配置。"
        return 1
    fi

    default_iface=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -z "$default_iface" ]] || ! netplan get "ethernets.${default_iface}" >/dev/null 2>&1; then
        echo -e "${YELLOW}检测到 netplan，但默认网卡不在 ethernets 中；为避免中断网络，已跳过自动写入。${NC}"
        return 0
    fi

    backup_dns_file "$override_file" || return 1
    dhcp4=$(netplan get "ethernets.${default_iface}.dhcp4" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    dhcp6=$(netplan get "ethernets.${default_iface}.dhcp6" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    {
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
    } > "$override_file" || return 1
    chmod 600 "$override_file" || return 1
    DNS_NETPLAN_APPLIED=1
    command_output=$(netplan generate 2>&1)
    command_status=$?
    if (( command_status != 0 )); then
        detail "DNS" "APPLY_NETPLAN" "netplan generate 失败，退出码=$command_status，输出=${command_output:-无}"
        return 1
    fi
    command_output=$(timeout 30 netplan apply 2>&1)
    command_status=$?
    if (( command_status != 0 )); then
        detail "DNS" "APPLY_NETPLAN" "netplan apply 失败，退出码=$command_status，输出=${command_output:-无}"
        return 1
    fi
    detail "DNS" "APPLY_NETPLAN" "接口=$default_iface；配置=$override_file；DHCPv4=$dhcp4；DHCPv6=$dhcp6；DNS=$dns_csv"
    log "已通过 netplan 为 $default_iface 同步 DNS。"
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

dns_addresses_equal() {
    local first="$1"
    local second="$2"

    [[ "${first,,}" == "${second,,}" ]] && return 0
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import ipaddress, sys; raise SystemExit(ipaddress.ip_address(sys.argv[1]) != ipaddress.ip_address(sys.argv[2]))' \
            "$first" "$second" >/dev/null 2>&1
        return $?
    fi
    return 1
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

    for token in $link_output; do
        address=$(extract_dns_address "$token")
        validate_dns_address "$address" || continue
        dns_address_in_list "$address" "$requested" || return 1
    done
    return 0
}

dns_verify_fail() {
    local stage="$1"
    local summary="$2"
    local diagnostics="${3:-$summary}"

    DNS_VERIFY_FAILURE="$summary"
    detail "DNS" "$stage" "$diagnostics"
    return 1
}

verify_dns_change() {
    local requested_dns="$1"
    local route_after
    local dns_server
    local resolved_output
    local link_output
    local resolv_servers
    local default_iface
    local command_status
    local github_status
    local cloudflare_status

    DNS_VERIFY_FAILURE=""
    detail "DNS" "VERIFY_START" "请求=$requested_dns；IPv4接口=${DNS_DEFAULT_V4_IFACE_BEFORE:-无}；IPv4网关=${DNS_DEFAULT_V4_GATEWAY_BEFORE:-无}；IPv6接口=${DNS_DEFAULT_V6_IFACE_BEFORE:-无}；IPv6网关=${DNS_DEFAULT_V6_GATEWAY_BEFORE:-无}"

    if [[ -n "$DNS_DEFAULT_V4_IFACE_BEFORE" ]]; then
        route_after=$(ip -o -4 route show default dev "$DNS_DEFAULT_V4_IFACE_BEFORE" 2>/dev/null)
        if [[ -z "$route_after" ]]; then
            dns_verify_fail "VERIFY_ROUTE_V4" \
                "IPv4 默认路由丢失（接口 $DNS_DEFAULT_V4_IFACE_BEFORE）" \
                "接口=$DNS_DEFAULT_V4_IFACE_BEFORE；修改前网关=${DNS_DEFAULT_V4_GATEWAY_BEFORE:-无}；修改后未发现默认路由"
            return 1
        fi
        if [[ -n "$DNS_DEFAULT_V4_GATEWAY_BEFORE" ]] && \
           ! grep -Fq "via $DNS_DEFAULT_V4_GATEWAY_BEFORE " <<< "$route_after"; then
            dns_verify_fail "VERIFY_ROUTE_V4" \
                "IPv4 默认网关发生变化" \
                "期望网关=$DNS_DEFAULT_V4_GATEWAY_BEFORE；实际路由=$route_after"
            return 1
        fi
    fi
    if [[ -n "$DNS_DEFAULT_V6_IFACE_BEFORE" ]]; then
        route_after=$(ip -o -6 route show default dev "$DNS_DEFAULT_V6_IFACE_BEFORE" 2>/dev/null)
        if [[ -z "$route_after" ]]; then
            dns_verify_fail "VERIFY_ROUTE_V6" \
                "IPv6 默认路由丢失（接口 $DNS_DEFAULT_V6_IFACE_BEFORE）" \
                "接口=$DNS_DEFAULT_V6_IFACE_BEFORE；修改前网关=${DNS_DEFAULT_V6_GATEWAY_BEFORE:-无}；修改后未发现默认路由"
            return 1
        fi
        if [[ -n "$DNS_DEFAULT_V6_GATEWAY_BEFORE" ]] && \
           ! grep -Fq "via $DNS_DEFAULT_V6_GATEWAY_BEFORE " <<< "$route_after"; then
            dns_verify_fail "VERIFY_ROUTE_V6" \
                "IPv6 默认网关发生变化" \
                "期望网关=$DNS_DEFAULT_V6_GATEWAY_BEFORE；实际路由=$route_after"
            return 1
        fi
    fi
    if systemctl is-active systemd-resolved >/dev/null 2>&1 && command -v resolvectl >/dev/null 2>&1; then
        resolved_output=$(resolvectl dns 2>&1)
        command_status=$?
        if (( command_status != 0 )); then
            dns_verify_fail "VERIFY_RESOLVED" \
                "无法读取 systemd-resolved 的 DNS 状态" \
                "resolvectl dns 退出码=$command_status；输出=${resolved_output:-无}"
            return 1
        fi
        for dns_server in $requested_dns; do
            if ! dns_text_has_server "$resolved_output" "$dns_server"; then
                dns_verify_fail "VERIFY_SERVER" \
                    "请求的 DNS $dns_server 未出现在 systemd-resolved 状态中" \
                    "缺少=$dns_server；请求=$requested_dns；实际=${resolved_output:-无}"
                return 1
            fi
        done
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
            if ! dns_link_uses_requested_servers "$link_output" "$requested_dns"; then
                dns_verify_fail "VERIFY_LINK_SERVER" \
                    "接口 $default_iface 仍包含未请求的 DNS" \
                    "接口=$default_iface；请求=$requested_dns；实际=${link_output:-无}"
                return 1
            fi
        done
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
    local dns_line="$1"
    local dns_csv="${dns_line// /, }"
    local dns_server
    local resolved_file="/etc/systemd/resolved.conf.d/99-vps-init-dns.conf"
    local command_output
    local command_status

    for dns_server in $dns_line; do
        if ! validate_dns_address "$dns_server"; then
            error "无效的 DNS 地址：$dns_server"
            return 1
        fi
    done

    DNS_CHANGED_FILES=()
    DNS_BACKUP_FILES=()
    DNS_FILE_EXISTED=()
    DNS_BACKUP_PATH="$BACKUP_DIR/dns-$(date +%Y%m%d%H%M%S)-$$"
    DNS_DEFAULT_V4_IFACE_BEFORE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
    DNS_DEFAULT_V4_GATEWAY_BEFORE=$(ip -o -4 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}')
    DNS_DEFAULT_V6_IFACE_BEFORE=$(ip -o -6 route show default 2>/dev/null | awk '{print $5; exit}')
    DNS_DEFAULT_V6_GATEWAY_BEFORE=$(ip -o -6 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}')
    DNS_NETPLAN_APPLIED=0
    DNS_RESOLVED_ACTIVE=0
    DNS_RESOLV_WAS_IMMUTABLE=0
    if ! mkdir -p "$DNS_BACKUP_PATH"; then
        error "无法创建 DNS 备份目录：$DNS_BACKUP_PATH"
        return 1
    fi
    detail "DNS" "DETECT" "请求=$dns_line；IPv4接口=${DNS_DEFAULT_V4_IFACE_BEFORE:-无}；IPv4网关=${DNS_DEFAULT_V4_GATEWAY_BEFORE:-无}；IPv6接口=${DNS_DEFAULT_V6_IFACE_BEFORE:-无}；IPv6网关=${DNS_DEFAULT_V6_GATEWAY_BEFORE:-无}；备份=$DNS_BACKUP_PATH"

    if ! sync_interfaces_dns "$dns_line"; then
        detail "DNS" "WRITE_INTERFACES" "interfaces 持久化配置写入失败；请求=$dns_line"
        rollback_dns_with_message "DNS interfaces 持久化配置写入失败"
        return 1
    fi
    if ! sync_netplan_dns "$dns_csv"; then
        detail "DNS" "WRITE_NETPLAN" "netplan 持久化配置写入或应用失败；请求=$dns_line"
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
        if ! cat > "$resolved_file" <<EOF
[Resolve]
DNS=$dns_line
FallbackDNS=
EOF
        then
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
        detail "DNS" "APPLY_RESOLVED" "配置=$resolved_file；DNS=$dns_line；服务重启成功"
    else
        backup_dns_file /etc/resolv.conf || {
            rollback_dns_with_message "resolv.conf 备份失败"
            return 1
        }
        lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q i && DNS_RESOLV_WAS_IMMUTABLE=1
        chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
        if ! rm -f /etc/resolv.conf; then
            rollback_dns_with_message "resolv.conf 替换失败"
            return 1
        fi
        : > /etc/resolv.conf || {
            rollback_dns_with_message "resolv.conf 创建失败"
            return 1
        }
        for dns_server in $dns_line; do
            printf 'nameserver %s\n' "$dns_server" >> /etc/resolv.conf || {
                rollback_dns_with_message "resolv.conf 写入失败"
                return 1
            }
        done
        if [[ "$DNS_RESOLV_WAS_IMMUTABLE" == "1" ]] && ! chattr +i /etc/resolv.conf >/dev/null 2>&1; then
            rollback_dns_with_message "resolv.conf 不可变属性恢复失败"
            return 1
        fi
    fi

    if ! verify_dns_change "$dns_line"; then
        rollback_dns_with_message "DNS 应用后验证失败：${DNS_VERIFY_FAILURE:-未知原因}"
        return 1
    fi

    log "DNS 已应用并验证成功；原文件备份保存在 $DNS_BACKUP_PATH。"
    return 0
}

submenu_dns() {
    require_commands "DNS 配置" ip systemctl timeout getent awk sed find mktemp || { pause_menu; return; }
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

        IPV6_STATUS=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        DNS_ENTRY=""

        case "$choice_dns" in
            1)
                DNS_ENTRY="1.1.1.1 1.0.0.1"
                if [[ "$IPV6_STATUS" != "1" ]]; then
                    DNS_ENTRY+=" 2606:4700:4700::1111 2606:4700:4700::1001"
                else
                    echo -e "${YELLOW}当前 IPv6 已禁用，Cloudflare IPv6 DNS 已自动跳过。${NC}"
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

                if [[ "$IPV6_STATUS" == "1" ]]; then
                    if [[ "$dns1" =~ ":" ]] || [[ "$dns2" =~ ":" ]]; then
                        error "当前系统已禁用 IPv6，无法配置 IPv6 格式的 DNS 解析！"
                        pause_menu; continue
                    fi
                fi
                DNS_ENTRY="$dns1"
                [[ -n "$dns2" ]] && DNS_ENTRY+=" $dns2"
                ;;
            0) return ;;
            *) error "无效选项！"; sleep 1; continue ;;
        esac

        log "正在配置 DNS..."
        if ! apply_dns_servers "$DNS_ENTRY"; then
            error "DNS 配置未能完全应用，请根据日志检查网络配置。"
            pause_menu; continue
        fi
        
        sleep 1
        log "DNS 修改成功！"
        echo "当前检测到的 DNS："
        show_dns_status
        pause_menu
    done
}

configure_ip_preference() {
    local mode="$1"
    local backup_path
    local gai_existed=0
    local rollback_failed=0

    backup_path="$BACKUP_DIR/gai-$(date +%Y%m%d%H%M%S)-$$"

    mkdir -p "$backup_path" || return 1
    if [[ -L /etc/gai.conf ]]; then
        error "/etc/gai.conf 是符号链接，为避免修改未知目标已停止操作。"
        return 1
    fi
    if [[ -f /etc/gai.conf ]]; then
        gai_existed=1
        cp -a /etc/gai.conf "$backup_path/gai.conf" || return 1
    else
        touch /etc/gai.conf || return 1
    fi

    if ! sed -i -E '/^[[:space:]]*precedence[[:space:]]+::ffff:0:0\/96[[:space:]]+/d' /etc/gai.conf; then
        error "gai.conf 更新失败。"
    elif [[ "$mode" == "ipv4" ]] && \
         ! printf '%s\n' "precedence ::ffff:0:0/96  100" >> /etc/gai.conf; then
        error "IPv4 优先级写入失败。"
    elif [[ "$mode" == "ipv4" ]] && \
         ! grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' /etc/gai.conf; then
        error "IPv4 优先级验证失败。"
    elif [[ "$mode" == "default" ]] && \
         grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+' /etc/gai.conf; then
        error "默认地址优先级恢复验证失败。"
    else
        log "地址优先级已更新。备份：$backup_path"
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

configure_ipv6_state() {
    local target_value="$1"
    local action_label="禁用"
    local runtime_path
    local runtime_value

    [[ "$target_value" == "0" ]] && action_label="启用"
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
    detail "IPV6" "DETECT" "操作=$action_label；目标值=$target_value；原 all=$IPV6_PREVIOUS_ALL；原 default=$IPV6_PREVIOUS_DEFAULT；原 lo=$IPV6_PREVIOUS_LO；运行路径数=${#IPV6_RUNTIME_PATHS[@]}；配置=$IPV6_SYSCTL_FILE"
    if [[ -L "$IPV6_SYSCTL_FILE" ]]; then
        error "$IPV6_SYSCTL_FILE 是符号链接，为避免修改未知目标已停止操作。"
        return 1
    fi
    mkdir -p "$IPV6_BACKUP_PATH" "$(dirname "$IPV6_SYSCTL_FILE")" || return 1
    if [[ -f "$IPV6_SYSCTL_FILE" ]]; then
        IPV6_FILE_EXISTED=1
        cp -a "$IPV6_SYSCTL_FILE" "$IPV6_BACKUP_PATH/ipv6.conf" || return 1
    else
        touch "$IPV6_SYSCTL_FILE" || return 1
    fi

    if ! write_sysctl_key "$IPV6_SYSCTL_FILE" net.ipv6.conf.all.disable_ipv6 "$target_value" || \
       ! write_sysctl_key "$IPV6_SYSCTL_FILE" net.ipv6.conf.default.disable_ipv6 "$target_value" || \
       ! write_sysctl_key "$IPV6_SYSCTL_FILE" net.ipv6.conf.lo.disable_ipv6 "$target_value" || \
       [[ "$(get_effective_sysctl_value net.ipv6.conf.all.disable_ipv6)" != "$target_value" ]] || \
       [[ "$(get_effective_sysctl_value net.ipv6.conf.default.disable_ipv6)" != "$target_value" ]] || \
       [[ "$(get_effective_sysctl_value net.ipv6.conf.lo.disable_ipv6)" != "$target_value" ]] || \
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

    log "IPv6 已$action_label并通过运行状态和持久化验证。备份：$IPV6_BACKUP_PATH"
}

# ==========================================
# 模块三：IPv6 优先级
# ==========================================
submenu_ipv6() {
    require_commands "IPv4 / IPv6 配置" sysctl sed awk find readlink sort || { pause_menu; return; }
    while true; do
        print_header "IPv4 / IPv6 配置"
        IPV6_STATUS=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        case "$IPV6_STATUS" in
            1) echo -e "当前 IPv6 状态: ${RED}已禁用${NC}" ;;
            0)
                echo -e "当前 IPv6 状态: ${GREEN}已启用${NC}"
                if grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' /etc/gai.conf 2>/dev/null; then
                    echo -e "当前地址优先级:   ${YELLOW}IPv4 优先${NC}"
                else
                    echo -e "当前地址优先级:   ${GREEN}系统默认${NC}"
                fi
                ;;
            *)
                echo -e "当前 IPv6 状态: ${YELLOW}未知（内核参数读取失败）${NC}"
                ;;
        esac
        if [[ "$IPV6_STATUS" == "1" ]]; then
            if grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' /etc/gai.conf 2>/dev/null; then
                echo -e "当前路由优先:   ${YELLOW}IPv4 优先${NC}"
            else
                echo -e "当前地址优先级:   ${DIM}系统默认${NC}"
            fi
        fi
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
                log "正在设置 IPv4 优先..."
                configure_ip_preference ipv4
                pause_menu ;;
            2)
                log "正在恢复默认路由优先级..."
                configure_ip_preference default
                pause_menu ;;
            3)
                confirm_action "禁用 IPv6 可能影响仅提供 IPv6 的服务，确认继续吗？" || continue
                configure_ipv6_state 1
                pause_menu ;;
            4)
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

                if [[ "$CURRENT_CC" == "bbr" && "$CURRENT_QDISC" == "fq" ]]; then
                    log "BBR 与 FQ 当前均已开启，不创建或修改任何 sysctl 文件。"
                    pause_menu; continue
                fi

                if [[ "$CURRENT_CC" == "bbr" ]]; then
                    echo -e "${YELLOW}BBR 已开启，但当前默认队列为 ${CURRENT_QDISC:-未知}，不是 fq。${NC}"
                    read -r -p "是否只补充并启用 FQ？[y/N]: " confirm_fq
                    if [[ "$confirm_fq" == "y" || "$confirm_fq" == "Y" ]]; then
                        persist_bbr_settings "$CURRENT_CC" "$CURRENT_QDISC" 0
                    else
                        log "已保留当前 BBR 与队列配置。"
                    fi
                    pause_menu; continue
                fi

                K_MAJOR=$(uname -r | cut -d. -f1)
                K_MINOR=$(uname -r | cut -d. -f2)
                if [[ "$K_MAJOR" -lt 4 ]] || [[ "$K_MAJOR" -eq 4 && "$K_MINOR" -lt 9 ]]; then
                    error "当前内核版本 $(uname -r) 过低，BBR 需要 4.9 或以上版本！"
                    pause_menu; continue
                fi
                
                log "正在根据当前内核的实际能力检测并配置 BBR..."
                command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr >/dev/null 2>&1 || true
                
                if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
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
    local ipv6_disabled
    local ip_preference
    local fail2ban_status
    local current_cc
    local current_qdisc
    local persistent_cc
    local persistent_qdisc
    local persistent_cc_file
    local persistent_qdisc_file

    ssh_port=$(get_ssh_port)
    listening_ports=$(get_listening_ssh_ports)
    password_auth=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2; exit}')
    ipv6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    persistent_cc=$(get_effective_sysctl_value net.ipv4.tcp_congestion_control)
    persistent_qdisc=$(get_effective_sysctl_value net.core.default_qdisc)
    persistent_cc_file=$(get_effective_sysctl_source net.ipv4.tcp_congestion_control)
    persistent_qdisc_file=$(get_effective_sysctl_source net.core.default_qdisc)

    case "$password_auth" in
        yes) password_display="${RED}已启用${NC}" ;;
        no) password_display="${GREEN}已禁用${NC}" ;;
        *) password_display="${YELLOW}未知${NC}" ;;
    esac
    case "$ipv6_disabled" in
        1) ip_preference="${RED}IPv6 已禁用${NC}" ;;
        0)
            if grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' /etc/gai.conf 2>/dev/null; then
                ip_preference="${YELLOW}IPv4 优先${NC}"
            else
                ip_preference="${GREEN}系统默认${NC}"
            fi
            ;;
        *) ip_preference="${YELLOW}未知${NC}" ;;
    esac
    fail2ban_status=$(systemctl is-active fail2ban 2>/dev/null || true)

    print_header "关键状态汇总"
    echo -e "版本:                   ${CYAN}$VERSION${NC}"
    echo -e "拥塞控制 / 队列:        ${YELLOW}${current_cc:-未知} / ${current_qdisc:-未知}${NC}"
    echo -e "持久化配置值:           ${persistent_cc:-未检测到} / ${persistent_qdisc:-未检测到}"
    echo "BBR 持久化来源:         ${persistent_cc_file:-未检测到}"
    echo "FQ 持久化来源:          ${persistent_qdisc_file:-未检测到}"
    echo "SSH 配置端口:           ${ssh_port:-未知}"
    echo "SSH 实际监听:           ${listening_ports:-未检测到}"
    echo -e "SSH 密码登录:           $password_display"
    echo -e "IPv4 / IPv6:            $ip_preference"
    case "$fail2ban_status" in
        active) echo -e "Fail2ban:               ${GREEN}运行中${NC}" ;;
        inactive|failed) echo -e "Fail2ban:               ${RED}${fail2ban_status}${NC}" ;;
        *) echo -e "Fail2ban:               ${YELLOW}${fail2ban_status:-未安装或未知}${NC}" ;;
    esac
    echo "SWAP:                   $(free -h | awk '/^Swap/{print $2" 总 / "$3" 已用"}')"
    if [[ -f /var/run/reboot-required ]]; then
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

    print_header "只读配置诊断"
    if sshd -t >/dev/null 2>&1; then
        print_result "SSH 配置语法" "正常"
    else
        print_result "SSH 配置语法" "异常"
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
    else
        print_result "Fail2ban 配置" "未安装"
    fi
    echo -e "${CYAN}==================================================${NC}"
    pause_menu
}

show_recent_log() {
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
        echo -e "  系统: ${YELLOW}$OS_ID $OS_VERSION${NC}  |  负载: ${YELLOW}$LOAD_AVG${NC}"
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
    main_menu
fi
