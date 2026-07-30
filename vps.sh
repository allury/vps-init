#!/bin/bash

# ==========================================
# 0. 全局变量与前置环境配置
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'
LOG_FILE="/var/log/vps_init.log"
SYSCTL_FILE="/etc/sysctl.d/99-vps-init.conf"
VERSION="1.1.2"
MANAGED_SWAP_FILE="/swapfile"
BACKUP_DIR="/var/backups/vps-init"

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/vps_init.log"

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | sed -r 's/\x1B\[[0-9;]*[mK]//g' >> "$LOG_FILE"
}

error() {
    echo -e "${RED}[错误]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" | sed -r 's/\x1B\[[0-9;]*[mK]//g' >> "$LOG_FILE"
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

sync_fail2ban_ssh_port() {
    local port="$1"

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        return 0
    fi

    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/99-vps-init-port.local <<EOF
[sshd]
port = $port
EOF

    if systemctl restart fail2ban; then
        log "Fail2ban 已同步监听 SSH 端口 $port。"
    else
        error "Fail2ban 端口已写入，但服务重启失败；请执行 fail2ban-client -t 检查配置。"
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

scan_sysctl_configs() {
    local dir
    local file
    local real_file
    local is_etc_file
    local -A seen_files=()
    local -a scan_dirs=(/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d)

    ALL_SYSCTL_FILES=()
    ETC_KEY_FILES=()
    ETC_TCP_FILES=()
    READONLY_TCP_FILES=()
    LEGACY_TCP_FILES=()

    for dir in "${scan_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' file; do
            real_file=$(readlink -f "$file" 2>/dev/null || printf '%s' "$file")
            [[ -n "${seen_files[$real_file]+x}" ]] && continue
            seen_files[$real_file]=1
            ALL_SYSCTL_FILES+=("$file")
        done < <(find "$dir" -maxdepth 1 \( -type f -o -type l \) -name '*.conf' -print0 2>/dev/null)
    done
    if [[ -f /etc/sysctl.conf ]]; then
        real_file=$(readlink -f /etc/sysctl.conf 2>/dev/null || printf '%s' /etc/sysctl.conf)
        if [[ -z "${seen_files[$real_file]+x}" ]]; then
            seen_files[$real_file]=1
            ALL_SYSCTL_FILES+=(/etc/sysctl.conf)
        fi
    fi

    for file in "${ALL_SYSCTL_FILES[@]}"; do
        real_file=$(readlink -f "$file" 2>/dev/null || printf '%s' "$file")
        is_etc_file=0
        [[ "$file" == /etc/* && "$real_file" == /etc/* ]] && is_etc_file=1

        if grep -qE '^[[:space:]]*(net\.ipv4\.tcp_congestion_control|net\.core\.default_qdisc)[[:space:]]*=' "$file"; then
            if [[ "$file" == "/etc/sysctl.conf" ]]; then
                add_unique_path LEGACY_TCP_FILES "$file"
            elif [[ "$is_etc_file" == "1" ]]; then
                add_unique_path ETC_KEY_FILES "$file"
            else
                add_unique_path READONLY_TCP_FILES "$file"
            fi
        fi

        if grep -qE '^[[:space:]]*(net\.ipv4\.tcp_[A-Za-z0-9_]*|net\.core\.[A-Za-z0-9_]*)[[:space:]]*=' "$file"; then
            if [[ "$file" == "/etc/sysctl.conf" ]]; then
                add_unique_path LEGACY_TCP_FILES "$file"
            elif [[ "$is_etc_file" == "1" ]]; then
                add_unique_path ETC_TCP_FILES "$file"
            else
                add_unique_path READONLY_TCP_FILES "$file"
            fi
        fi
    done
}

filter_high_priority_sysctl_files() {
    local source_name="$1"
    local target_name="$2"
    local file
    local filename
    local -n source_array="$source_name"
    local -n target_array="$target_name"

    target_array=()
    for file in "${source_array[@]}"; do
        filename=$(basename "$file")
        if [[ "$filename" > "59-" ]]; then
            add_unique_path "$target_name" "$file"
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
    read -p "请选择配置文件: " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#candidates[@]} )); then
        SYSCTL_TARGET=""
        return 1
    fi
    SYSCTL_TARGET="${candidates[$((choice - 1))]}"
}

select_sysctl_target() {
    local -a high_priority_key_files=()
    local -a high_priority_tcp_files=()
    local resolved_target
    SYSCTL_TARGET=""
    scan_sysctl_configs
    filter_high_priority_sysctl_files ETC_KEY_FILES high_priority_key_files
    filter_high_priority_sysctl_files ETC_TCP_FILES high_priority_tcp_files

    if (( ${#high_priority_key_files[@]} == 1 )); then
        SYSCTL_TARGET="${high_priority_key_files[0]}"
    elif (( ${#high_priority_key_files[@]} > 1 )); then
        choose_path_interactively "检测到多个高优先级 /etc 配置文件定义了 BBR 或队列参数：" "${high_priority_key_files[@]}" || return 1
    elif (( ${#high_priority_tcp_files[@]} == 1 )); then
        SYSCTL_TARGET="${high_priority_tcp_files[0]}"
    elif (( ${#high_priority_tcp_files[@]} > 1 )); then
        choose_path_interactively "检测到多个高优先级 /etc TCP 参数文件，不自动选择：" "${high_priority_tcp_files[@]}" || return 1
    elif [[ -f "$SYSCTL_FILE" ]]; then
        if [[ "$(readlink -f "$SYSCTL_FILE" 2>/dev/null)" == /etc/* ]]; then
            SYSCTL_TARGET="$SYSCTL_FILE"
        else
            SYSCTL_TARGET="/etc/sysctl.d/99-vps-init-bbr.conf"
            echo -e "${YELLOW}$SYSCTL_FILE 指向系统目录，不会修改；改用 $SYSCTL_TARGET。${NC}"
        fi
    else
        SYSCTL_TARGET="$SYSCTL_FILE"
        if (( ${#READONLY_TCP_FILES[@]} > 0 )); then
            echo -e "${YELLOW}只在系统只读目录发现 TCP 配置，将使用 $SYSCTL_FILE 覆盖，不修改以下文件：${NC}"
            printf ' - %s\n' "${READONLY_TCP_FILES[@]}"
        else
            log "未发现可安全复用的高优先级 /etc TCP 参数文件，将新建 $SYSCTL_FILE。"
        fi
    fi

    if (( ${#ETC_TCP_FILES[@]} > ${#high_priority_tcp_files[@]} )); then
        echo -e "${YELLOW}已忽略文件名优先级偏低的 /etc TCP 配置，避免在 Debian 13 启动时被后加载文件覆盖。${NC}"
    fi
    if (( ${#LEGACY_TCP_FILES[@]} > 0 )); then
        echo -e "${YELLOW}检测到裸 /etc/sysctl.conf，但未发现 sysctl.d 链接，因此只检查、不作为 systemd 持久化目标。${NC}"
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

write_sysctl_key() {
    local file="$1"
    local key="$2"
    local value="$3"
    local escaped_key="${key//./\\.}"

    sed -i -E "\\|^[[:space:]]*${escaped_key}[[:space:]]*=|d" "$file"
    printf '%s = %s\n' "$key" "$value" >> "$file"
}

persist_bbr_settings() {
    local previous_cc="$1"
    local previous_qdisc="$2"
    local write_bbr="${3:-1}"
    local target_existed=0
    local backup_file=""
    local result_label="BBR + FQ"

    select_sysctl_target || {
        error "未选择 sysctl 配置文件，已取消 BBR 配置。"
        return 1
    }

    [[ "$write_bbr" == "0" ]] && result_label="FQ"

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
    elif sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 && \
         { [[ "$write_bbr" == "0" ]] || sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; } && \
         [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" == "fq" ]] && \
         { [[ "$write_bbr" == "0" ]] || [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; }; then
        log "$result_label 已生效，配置写入 $SYSCTL_TARGET。"
        [[ -n "$backup_file" ]] && log "原配置备份：$backup_file"
        return 0
    fi

    if [[ "$target_existed" == "1" ]]; then
        cp -a "$backup_file" "$SYSCTL_TARGET"
    else
        rm -f "$SYSCTL_TARGET"
    fi
    [[ -n "$previous_qdisc" ]] && sysctl -w "net.core.default_qdisc=$previous_qdisc" >/dev/null 2>&1 || true
    [[ -n "$previous_cc" ]] && sysctl -w "net.ipv4.tcp_congestion_control=$previous_cc" >/dev/null 2>&1 || true
    error "$result_label 应用失败，配置文件和运行参数已回滚。"
    return 1
}

if [[ $EUID -ne 0 ]]; then
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
}

# ==========================================
# 辅助函数：安全重启 SSH 服务（兼容 Ubuntu 24.04+）
# ==========================================
restart_ssh() {
    if [[ "$OS_ID" == "ubuntu" ]]; then
        UBUNTU_MAJOR="${OS_VERSION%%.*}"
        if [[ "$UBUNTU_MAJOR" =~ ^[0-9]+$ && "$UBUNTU_MAJOR" -ge 24 ]]; then
            # Ubuntu 24.04+ 必须切换到 ssh.service，socket 不重新监听新端口
            systemctl stop ssh.socket 2>/dev/null
            systemctl disable ssh.socket 2>/dev/null
            systemctl mask ssh.socket >/dev/null 2>&1 || true
            systemctl enable ssh.service 2>/dev/null
            systemctl daemon-reload
            systemctl restart ssh.service
        else
            systemctl daemon-reload
            systemctl restart ssh.socket 2>/dev/null || systemctl restart ssh 2>/dev/null
        fi
    else
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi
}

# ==========================================
# 模块一：三级菜单 A - SWAP 设置
# ==========================================
submenu_swap() {
    while true; do
        clear
        echo "=================================="
        echo "     --- 三级菜单：SWAP 设置 ---"
        echo "=================================="
        echo -e "当前 SWAP 状态："
        if swapon --show | grep -q "."; then
            swapon --show | awk 'NR>1 {print " - 路径: "$1" | 大小: "$3" | 已用: "$4}'
            echo -e " - 合计：$(free -h | awk '/^Swap/{print $2" 总 / "$3" 已用"}')"
        else
            echo -e "${YELLOW} - 未配置任何 SWAP${NC}"
        fi
        echo "----------------------------------"
        echo "1. 快速添加 1GB SWAP"
        echo "2. 快速添加 2GB SWAP"
        echo -e "${GREEN}3. 手动输入 SWAP 大小 (MB/GB)${NC}"
        echo -e "${RED}4. 卸载并删除现有 SWAP${NC}"
        echo "0. 返回上一级菜单"
        echo "=================================="
        read -p "请输入选项 [0-4]: " choice_swap

        if [[ "$choice_swap" =~ ^[1-3]$ ]]; then
            if swapon --show | grep -q "." || awk '!/^#/ && $3=="swap"' /etc/fstab | grep -q "."; then
                error "检测到已存在 SWAP 配置！请先使用选项 4 卸载现有 SWAP。"
                read -p "按回车键继续..."; continue
            fi
        fi

        case "$choice_swap" in
            1) swap_size="1G" ;;
            2) swap_size="2G" ;;
            3)
                read -p "请输入所需 SWAP 大小 (例如 512M 或 4G): " swap_size
                if [[ ! "$swap_size" =~ ^[0-9]+[MGmg]$ ]]; then
                    error "格式错误！请输入带有 M 或 G 单位的数字。"
                    read -p "按回车键继续..."; continue
                fi
                ;;
            4)
                SWAP_ACTIVE=0
                SWAP_CONFIGURED=0
                swapon --show=NAME --noheadings --raw 2>/dev/null | grep -Fxq "$MANAGED_SWAP_FILE" && SWAP_ACTIVE=1
                awk -v path="$MANAGED_SWAP_FILE" '!/^[[:space:]]*#/ && $1==path && $3=="swap" {found=1} END {exit !found}' /etc/fstab && SWAP_CONFIGURED=1

                if [[ "$SWAP_ACTIVE" == "0" && "$SWAP_CONFIGURED" == "0" ]]; then
                    error "未检测到由脚本管理的 $MANAGED_SWAP_FILE；其他 SWAP 分区或文件不会被删除。"
                    read -p "按回车键继续..."; continue
                fi

                read -p "确认只卸载并删除 $MANAGED_SWAP_FILE 吗？其他 SWAP 将保留。[y/N]: " confirm_swap_remove
                [[ "$confirm_swap_remove" != "y" && "$confirm_swap_remove" != "Y" ]] && continue

                log "正在安全卸载并删除 $MANAGED_SWAP_FILE..."
                if [[ "$SWAP_ACTIVE" == "1" ]] && ! swapoff "$MANAGED_SWAP_FILE"; then
                    error "$MANAGED_SWAP_FILE 卸载失败，未修改 fstab，也未删除文件。"
                    read -p "按回车键继续..."; continue
                fi

                mkdir -p "$BACKUP_DIR"
                FSTAB_BACKUP="$BACKUP_DIR/fstab.$(date +%Y%m%d%H%M%S).bak"
                cp -a /etc/fstab "$FSTAB_BACKUP"
                FSTAB_TMP=$(mktemp /tmp/vps-init-fstab.XXXXXX)
                if awk -v path="$MANAGED_SWAP_FILE" '!($1==path && $3=="swap")' /etc/fstab > "$FSTAB_TMP" && cat "$FSTAB_TMP" > /etc/fstab; then
                    rm -f "$FSTAB_TMP"
                else
                    rm -f "$FSTAB_TMP"
                    cp -a "$FSTAB_BACKUP" /etc/fstab
                    [[ "$SWAP_ACTIVE" == "1" ]] && swapon "$MANAGED_SWAP_FILE" >/dev/null 2>&1 || true
                    error "fstab 更新失败，已恢复原配置。"
                    read -p "按回车键继续..."; continue
                fi

                if [[ -f "$MANAGED_SWAP_FILE" ]] && ! rm -f "$MANAGED_SWAP_FILE"; then
                    error "SWAP 已卸载且 fstab 条目已移除，但文件删除失败：$MANAGED_SWAP_FILE"
                    read -p "按回车键继续..."; continue
                fi

                log "$MANAGED_SWAP_FILE 已安全删除；其他 SWAP 配置保持不变。fstab 备份：$FSTAB_BACKUP"
                read -p "按回车键继续..."; continue
                ;;
            0) return ;;
            *) error "无效选项！"; sleep 1; continue ;;
        esac

        if [[ "$choice_swap" =~ ^[1-3]$ ]]; then
            if [[ -e "$MANAGED_SWAP_FILE" ]]; then
                error "$MANAGED_SWAP_FILE 已存在但未被识别为活动 SWAP，为避免覆盖未知文件已停止操作。"
                read -p "按回车键继续..."; continue
            fi
            log "正在创建 $swap_size 的 SWAP 文件..."
            
            if command -v numfmt >/dev/null 2>&1; then
                count_val=$(numfmt --from=iec "$swap_size" | awk '{printf "%d", $1/1048576}')
            else
                num="${swap_size//[^0-9]/}"
                unit="${swap_size//[0-9]/}"
                [[ "${unit^^}" == "G" ]] && count_val=$((num * 1024)) || count_val=$num
            fi

            if ! fallocate -l "$swap_size" "$MANAGED_SWAP_FILE" 2>/dev/null; then
                log "当前文件系统不支持 fallocate，正在降级使用 dd 创建 (请耐心等待)..."
                dd if=/dev/zero of="$MANAGED_SWAP_FILE" bs=1M count="$count_val" status=progress conv=fsync
            fi
            
            if [[ ! -f "$MANAGED_SWAP_FILE" ]] || [[ $(stat -c%s "$MANAGED_SWAP_FILE") -lt 1048576 ]]; then
                error "SWAP 文件创建失败，磁盘空间可能不足！"
                rm -f "$MANAGED_SWAP_FILE"
                read -p "按回车键继续..."; continue
            fi

            chmod 600 "$MANAGED_SWAP_FILE"
            if ! mkswap "$MANAGED_SWAP_FILE" >/dev/null || ! swapon "$MANAGED_SWAP_FILE"; then
                error "SWAP 初始化或启用失败，正在清理未完成文件。"
                swapoff "$MANAGED_SWAP_FILE" >/dev/null 2>&1 || true
                rm -f "$MANAGED_SWAP_FILE"
                read -p "按回车键继续..."; continue
            fi
            awk -v path="$MANAGED_SWAP_FILE" '!/^[[:space:]]*#/ && $1==path && $3=="swap" {found=1} END {exit !found}' /etc/fstab || \
                printf '%s none swap sw 0 0 # managed by vps-init\n' "$MANAGED_SWAP_FILE" >> /etc/fstab
            
            mkdir -p /etc/sysctl.d/
            if grep -q "^vm.swappiness" "$SYSCTL_FILE" 2>/dev/null; then
                sed -i 's/^vm.swappiness=.*/vm.swappiness=10/' "$SYSCTL_FILE"
            else
                echo "vm.swappiness=10" >> "$SYSCTL_FILE"
            fi
            sysctl --system >/dev/null 2>&1
            
            log "SWAP 创建成功！"
            read -p "按回车键继续..."
        fi
    done
}

# ==========================================
# 模块一：三级菜单 B - 时区设置
# ==========================================
submenu_timezone() {
    while true; do
        clear
        echo "=================================="
        echo "     --- 三级菜单：时区设置 ---"
        echo "=================================="
        echo -e "当前系统时间与时区："
        echo -e " - $(date "+%Y-%m-%d %H:%M:%S %Z")"
        echo "----------------------------------"
        echo "1. 设置为 Asia/Shanghai (北京时间)"
        echo "2. 设置为 UTC (协调世界时)"
        echo -e "${GREEN}3. 手动输入目标时区 (例如 America/New_York)${NC}"
        echo "0. 返回上一级菜单"
        echo "=================================="
        read -p "请输入选项 [0-3]: " choice_tz

        case "$choice_tz" in
            1) target_tz="Asia/Shanghai" ;;
            2) target_tz="UTC" ;;
            3)
                read -p "请输入标准的时区代码 (注意大小写): " target_tz
                if [[ -z "$target_tz" ]]; then
                    error "时区不能为空！"
                    read -p "按回车键继续..."; continue
                fi
                if ! timedatectl list-timezones | grep -qx "$target_tz"; then
                    error "无效的时区代码：$target_tz"
                    read -p "按回车键继续..."; continue
                fi
                ;;
            0) return ;;
            *) error "无效选项！"; sleep 1; continue ;;
        esac

        log "正在同步时间并设置时区为: $target_tz ..."
        timedatectl set-timezone "$target_tz" 2>/dev/null

        if [[ "$(timedatectl show -p Timezone --value 2>/dev/null)" != "$target_tz" ]]; then
            error "时区设置失败！"
            read -p "按回车键继续..."; continue
        fi

        if [[ "$OS_ID" == "debian" ]]; then
            if ! command -v systemd-timesyncd >/dev/null 2>&1; then
                apt-get install systemd-timesyncd -y >/dev/null 2>&1
            fi
            systemctl restart systemd-timesyncd || error "systemd-timesyncd 启动失败！"
            systemctl enable systemd-timesyncd >/dev/null 2>&1
        elif [[ "$OS_ID" == "ubuntu" ]]; then
            if ! systemctl restart systemd-timesyncd 2>/dev/null && ! systemctl restart chrony 2>/dev/null; then
                error "时间同步服务启动失败，未找到 systemd-timesyncd 或 chrony！"
            fi
        fi

        log "时区配置成功！当前时间：$(date "+%Y-%m-%d %H:%M:%S %Z")"
        read -p "按回车键继续..."
    done
}

# ==========================================
# 模块一：二级菜单 - 基础环境与系统优化
# ==========================================
submenu_env() {
    while true; do
        clear
        echo "=================================="
        echo "      1. 基础环境与系统优化"
        echo "=================================="
        echo "1. 更新软件包并清理旧内核 (严格区分大版本)"
        echo -e "2. 配置或调整 SWAP 虚拟内存 ${GREEN}[进入三级菜单]${NC}"
        echo -e "3. 配置系统时间与时区同步   ${GREEN}[进入三级菜单]${NC}"
        echo "0. 返回主菜单"
        echo "=================================="
        read -p "请输入选项 [0-3]: " choice_env

        case "$choice_env" in
            1) 
                log "开始执行系统更新和清理..."
                export DEBIAN_FRONTEND=noninteractive 
                
                if [[ "$OS_ID" == "debian" ]]; then
                    if [[ "$OS_VERSION" == "12" ]]; then
                        apt-get update -y || { error "更新源失败！"; read -p "按回车键继续..."; continue; }
                        apt-get full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || { error "系统升级失败！"; read -p "按回车键继续..."; continue; }
                        apt-get autoremove --purge -y && apt-get clean
                        dpkg -l | grep ^rc | awk '{print $2}' | xargs -r dpkg -P
                    elif [[ "$OS_VERSION" == "13" ]]; then
                        apt update -y || { error "更新源失败！"; read -p "按回车键继续..."; continue; }
                        apt full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || { error "系统升级失败！"; read -p "按回车键继续..."; continue; }
                        apt autoremove --purge -y && apt clean
                        dpkg -l | awk '/^rc/ {print $2}' | xargs -r apt-get purge -y
                    else
                        log "执行通用 Debian 更新策略..."
                        apt-get update -y || { error "更新源失败！"; read -p "按回车键继续..."; continue; }
                        apt-get full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || { error "系统升级失败！"; read -p "按回车键继续..."; continue; }
                        apt-get autoremove --purge -y && apt-get clean
                    fi
                elif [[ "$OS_ID" == "ubuntu" ]]; then
                    apt-get update -y || { error "更新源失败！"; read -p "按回车键继续..."; continue; }
                    apt-get full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || { error "系统升级失败！"; read -p "按回车键继续..."; continue; }
                    apt-get autoremove --purge -y && apt-get clean
                fi
                log "系统更新与清理完成。"
                if [[ -f /var/run/reboot-required ]]; then
                    echo -e "${YELLOW}检测到系统需要重启。请重启后再确认新内核和 BBR 是否完全生效。${NC}"
                    [[ -f /var/run/reboot-required.pkgs ]] && sed 's/^/ - /' /var/run/reboot-required.pkgs
                fi
                read -p "按回车键继续..." 
                ;;
            2) submenu_swap ;;
            3) submenu_timezone ;;
            0) return ;;
            *) error "无效输入！"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 模块二：三级菜单 C - SSH 安全设置
# ==========================================
submenu_ssh() {
    while true; do
        clear
        echo "=================================="
        echo "   --- 三级菜单：SSH 安全设置 ---"
        echo "=================================="
        CURRENT_PORT=$(get_ssh_port)
        [[ -z "$CURRENT_PORT" ]] && CURRENT_PORT="未知"
        LISTENING_PORTS=$(get_listening_ssh_ports)
        [[ -z "$LISTENING_PORTS" ]] && LISTENING_PORTS="未检测到"
        
        PWD_AUTH=$(sshd -T 2>/dev/null | grep -i "^passwordauthentication " | awk '{print $2}')
        [[ "$PWD_AUTH" == "yes" ]] && PWD_STATUS="${RED}已开启 (存在爆破风险)${NC}" || PWD_STATUS="${GREEN}已禁用 (安全)${NC}"
        
        echo -e "配置的 SSH 端口: ${YELLOW}$CURRENT_PORT${NC}"
        echo -e "实际监听端口:     ${YELLOW}$LISTENING_PORTS${NC}"
        echo -e "密码登录状态:  $PWD_STATUS"
        echo "----------------------------------"
        echo "1. 更改 SSH 端口 (带冲突检测与自动回滚)"
        echo "2. 强制启用密钥登录并禁用密码 (带严格验证与目录排雷)"
        echo "0. 返回上一级菜单"
        echo "=================================="
        read -p "请输入选项 [0-2]: " choice_ssh

        case "$choice_ssh" in
            1)
                read -p "请输入新的 SSH 端口号 (10000-65535): " new_port
                if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 10000 ] || [ "$new_port" -gt 65535 ]; then
                    error "端口号无效！请输入 10000 到 65535 之间的纯数字。"
                    read -p "按回车键继续..."; continue
                fi
                
                if ss -tuln | grep -q ":$new_port "; then
                    error "端口 $new_port 已被占用，请更换端口！"
                    read -p "按回车键继续..."; continue
                fi
                
                log "正在备份并修改 SSH 端口..."
                BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
                cp /etc/ssh/sshd_config "$BACKUP_FILE"
                
                if [[ -d /etc/ssh/sshd_config.d/ ]]; then
                    grep -rilE "^[[:space:]]*port[[:space:]]" /etc/ssh/sshd_config.d/ 2>/dev/null | xargs -r sed -i '/^[[:space:]]*[Pp]ort[[:space:]]/d'
                fi
                
                sed -i '/^#\?[[:space:]]*Port[[:space:]]/d' /etc/ssh/sshd_config
                echo "Port $new_port" >> /etc/ssh/sshd_config
                
                if ! sshd -t 2>/dev/null; then
                    error "sshd_config 语法检查未通过！正在自动回滚备份..."
                    cp "$BACKUP_FILE" /etc/ssh/sshd_config
                    read -p "按回车键继续..."; continue
                fi
                
                if ! restart_ssh; then
                    error "SSH 服务重启失败！正在回滚配置..."
                    cp "$BACKUP_FILE" /etc/ssh/sshd_config
                    restart_ssh >/dev/null 2>&1
                    read -p "按回车键继续..."; continue
                fi
                
                # 等待 sshd 完成监听
                sleep 1
                
                # 验证新端口是否真正 accept
                if ! timeout 3 bash -c "</dev/tcp/127.0.0.1/$new_port" 2>/dev/null; then
                    error "端口 $new_port 验证失败！sshd 可能未正常监听，正在回滚..."
                    cp "$BACKUP_FILE" /etc/ssh/sshd_config
                    restart_ssh >/dev/null 2>&1
                    read -p "按回车键继续..."; continue
                fi
                
                sync_fail2ban_ssh_port "$new_port"
                LISTENING_PORTS=$(get_listening_ssh_ports)
                log "SSH 端口修改成功，当前实际监听：${LISTENING_PORTS:-未知}。"
                echo -e "${YELLOW}请先在新终端使用端口 $new_port 登录成功，再关闭当前会话；同时确认云安全组和防火墙已放行。${NC}"
                read -p "按回车键继续..."
                ;;
                
            2)
                if ! grep -qE "^(ssh-|ecdsa-|sk-)" /root/.ssh/authorized_keys 2>/dev/null; then
                    error "检测失败！未发现有效格式的 SSH 公钥。"
                    error "请先在本地终端执行 'ssh-copy-id -p 端口 root@IP' 上传公钥！"
                    read -p "按回车键继续..."; continue
                fi
                
                read -p "⚠️  已检测到有效公钥。确认禁用密码登录吗？[y/N]: " confirm
                [[ "$confirm" != "y" && "$confirm" != "Y" ]] && continue
                
                log "正在备份并强制密钥登录..."
                BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
                cp /etc/ssh/sshd_config "$BACKUP_FILE"
                
                if [[ -d /etc/ssh/sshd_config.d/ ]]; then
                    grep -rl "PasswordAuthentication" /etc/ssh/sshd_config.d/ 2>/dev/null | xargs -r sed -i '/^[[:space:]]*PasswordAuthentication[[:space:]]/d'
                    grep -rl "PubkeyAuthentication" /etc/ssh/sshd_config.d/ 2>/dev/null | xargs -r sed -i '/^[[:space:]]*PubkeyAuthentication[[:space:]]/d'
                fi
                
                sed -i '/^#\?[[:space:]]*PasswordAuthentication[[:space:]]/d' /etc/ssh/sshd_config
                sed -i '/^#\?[[:space:]]*PubkeyAuthentication[[:space:]]/d' /etc/ssh/sshd_config
                echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
                echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
                
                if ! sshd -t 2>/dev/null; then
                    error "sshd_config 语法检查未通过！正在自动回滚备份..."
                    cp "$BACKUP_FILE" /etc/ssh/sshd_config
                    read -p "按回车键继续..."; continue
                fi
                
                if ! restart_ssh; then
                    error "SSH 服务重启失败！正在回滚配置..."
                    cp "$BACKUP_FILE" /etc/ssh/sshd_config
                    restart_ssh >/dev/null 2>&1
                    read -p "按回车键继续..."; continue
                fi
                
                log "密码登录已成功禁用，大门已焊死！"
                read -p "按回车键继续..."
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
        clear
        echo "=================================="
        echo "      2. 系统安全与防护"
        echo "=================================="
        echo -e "1. SSH 端口与登录防护设置 ${GREEN}[进入三级菜单]${NC}"
        echo "2. 一键部署 Fail2ban 防爆破系统"
        echo "0. 返回主菜单"
        echo "=================================="
        read -p "请输入选项 [0-2]: " choice_sec

        case "$choice_sec" in
            1) submenu_ssh ;;
            2) 
                export DEBIAN_FRONTEND=noninteractive
                echo -e "${YELLOW}正在更新源并安装 Fail2ban，请稍候...${NC}"
                apt-get update -y >/dev/null 2>&1 || { error "源更新失败，请检查网络！"; read -p "按回车键继续..."; continue; }
                apt-get install fail2ban -y >/dev/null 2>&1 || { error "Fail2ban 安装失败！"; read -p "按回车键继续..."; continue; }
                
                log "正在配置防爆破规则..."
                CURRENT_PORT=$(get_ssh_port)
                [[ -z "$CURRENT_PORT" ]] && CURRENT_PORT=22
                
                UBUNTU_MAJOR="${OS_VERSION%%.*}"
                if [[ "$OS_ID" == "ubuntu" && "$UBUNTU_MAJOR" =~ ^[0-9]+$ && "$UBUNTU_MAJOR" -ge 22 ]] || \
                   [[ "$OS_ID" == "debian" && "$OS_VERSION" =~ ^[0-9]+$ && "$OS_VERSION" -ge 12 && ! -f /var/log/auth.log ]]; then
                    F2B_BACKEND="systemd"
                    F2B_LOGPATH=""
                else
                    F2B_BACKEND="auto"
                    F2B_LOGPATH="logpath = /var/log/auth.log"
                fi
                
                cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled  = true
port     = $CURRENT_PORT
filter   = sshd
backend  = $F2B_BACKEND
$([ -n "$F2B_LOGPATH" ] && echo "$F2B_LOGPATH")
maxretry = 5
findtime = 3600
bantime  = 86400
EOF
                systemctl restart fail2ban || { error "Fail2ban 启动失败，请检查配置文件！"; read -p "按回车键继续..."; continue; }
                systemctl enable fail2ban >/dev/null 2>&1
                
                log "Fail2ban 部署完成，当前已自动监听 $CURRENT_PORT 端口。"
                read -p "按回车键继续..." 
                ;;
            0) return ;;
            *) error "无效输入！"; sleep 1; continue ;;
        esac
    done
}

# ==========================================
# 模块三：三级菜单 D - DNS 设置
# ==========================================
show_dns_status() {
    if systemctl is-active systemd-resolved >/dev/null 2>&1 && command -v resolvectl >/dev/null 2>&1; then
        resolvectl dns 2>/dev/null | sed 's/^/ - /'
    else
        grep -E '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null | awk '{print " - "$2}'
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
    local backup="$DNS_BACKUP_PATH/$index-$(basename "$target")"
    local existed=0

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

    for (( index=${#DNS_CHANGED_FILES[@]}-1; index>=0; index-- )); do
        target="${DNS_CHANGED_FILES[$index]}"
        [[ "$target" == "/etc/resolv.conf" ]] && chattr -i "$target" >/dev/null 2>&1 || true
        rm -f -- "$target"
        if [[ "${DNS_FILE_EXISTED[$index]}" == "1" ]]; then
            mkdir -p "$(dirname "$target")"
            cp -a -- "${DNS_BACKUP_FILES[$index]}" "$target"
        fi
    done

    if [[ "$DNS_NETPLAN_APPLIED" == "1" ]] && command -v netplan >/dev/null 2>&1; then
        netplan generate >/dev/null 2>&1 && netplan apply >/dev/null 2>&1 || true
    fi
    if [[ "$DNS_RESOLVED_ACTIVE" == "1" ]]; then
        systemctl restart systemd-resolved >/dev/null 2>&1 || true
    fi
    [[ "$DNS_RESOLV_WAS_IMMUTABLE" == "1" ]] && chattr +i /etc/resolv.conf >/dev/null 2>&1 || true
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
        if grep -qE "^[[:space:]]*iface[[:space:]]+$default_iface[[:space:]]+inet[[:space:]]+" "$file"; then
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
    backup_dns_file "$target_file" || return 1
    temp_file=$(mktemp /tmp/vps-init-interfaces.XXXXXX) || return 1
    if ! awk -v iface="$default_iface" -v dns="$dns_line" '
        $0 ~ "^[[:space:]]*iface[[:space:]]+" iface "[[:space:]]+inet[[:space:]]+" {
            in_target=1; wrote_dns=0; print; next
        }
        in_target && /^[[:space:]]*iface[[:space:]]+/ {
            if (!wrote_dns) print "    dns-nameservers " dns
            in_target=0
        }
        in_target && /^[[:space:]]*dns-nameservers[[:space:]]+/ {
            if (!wrote_dns) print "    dns-nameservers " dns
            wrote_dns=1; next
        }
        { print }
        END { if (in_target && !wrote_dns) print "    dns-nameservers " dns }
    ' "$target_file" > "$temp_file" || ! cat "$temp_file" > "$target_file"; then
        rm -f "$temp_file"
        return 1
    fi
    rm -f "$temp_file"
    log "已同步 $target_file 中默认网卡 $default_iface 的 DNS。"
    [[ "$target_file" == *50-cloud-init* ]] && echo -e "${YELLOW}注意：该文件由 cloud-init 生成，云平台后续启动时仍可能覆盖它。${NC}"
}

sync_netplan_dns() {
    local dns_csv="$1"
    local default_iface
    local override_file="/etc/netplan/99-vps-init-dns.yaml"

    command -v netplan >/dev/null 2>&1 || return 0
    [[ -d /etc/netplan ]] || return 0

    default_iface=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -z "$default_iface" ]] || ! netplan get "ethernets.${default_iface}" >/dev/null 2>&1; then
        echo -e "${YELLOW}检测到 netplan，但默认网卡不在 ethernets 中；为避免中断网络，已跳过自动写入。${NC}"
        return 0
    fi

    backup_dns_file "$override_file" || return 1
    cat > "$override_file" <<EOF
network:
  version: 2
  ethernets:
    $default_iface:
      nameservers:
        addresses: [$dns_csv]
EOF
    chmod 600 "$override_file" || return 1
    DNS_NETPLAN_APPLIED=1
    netplan generate >/dev/null 2>&1 || return 1
    netplan apply >/dev/null 2>&1 || return 1
    log "已通过 netplan 为 $default_iface 同步 DNS。"
}

verify_dns_change() {
    local route_after

    if [[ -n "$DNS_DEFAULT_ROUTE_BEFORE" ]]; then
        route_after=$(ip route show default 2>/dev/null; ip -6 route show default 2>/dev/null)
        [[ -n "$route_after" ]] || return 1
    fi
    getent ahosts github.com >/dev/null 2>&1 || getent ahosts cloudflare.com >/dev/null 2>&1
}

apply_dns_servers() {
    local dns_line="$1"
    local dns_csv="${dns_line// /, }"
    local dns_server
    local resolved_file="/etc/systemd/resolved.conf.d/99-vps-init-dns.conf"

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
    DNS_DEFAULT_ROUTE_BEFORE=$(ip route show default 2>/dev/null; ip -6 route show default 2>/dev/null)
    DNS_NETPLAN_APPLIED=0
    DNS_RESOLVED_ACTIVE=0
    DNS_RESOLV_WAS_IMMUTABLE=0
    mkdir -p "$DNS_BACKUP_PATH" || return 1

    if ! sync_interfaces_dns "$dns_line" || ! sync_netplan_dns "$dns_csv"; then
        error "DNS 持久化配置写入失败，正在回滚。"
        restore_dns_files
        return 1
    fi

    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        DNS_RESOLVED_ACTIVE=1
        mkdir -p /etc/systemd/resolved.conf.d/ || {
            restore_dns_files
            return 1
        }
        backup_dns_file "$resolved_file" || {
            restore_dns_files
            return 1
        }
        cat > "$resolved_file" <<EOF
[Resolve]
DNS=$dns_line
FallbackDNS=
EOF
        if ! systemctl restart systemd-resolved; then
            error "systemd-resolved 重启失败，正在回滚 DNS。"
            restore_dns_files
            return 1
        fi
    else
        backup_dns_file /etc/resolv.conf || {
            restore_dns_files
            return 1
        }
        lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q i && DNS_RESOLV_WAS_IMMUTABLE=1
        chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
        if ! rm -f /etc/resolv.conf; then
            restore_dns_files
            return 1
        fi
        : > /etc/resolv.conf || {
            restore_dns_files
            return 1
        }
        for dns_server in $dns_line; do
            printf 'nameserver %s\n' "$dns_server" >> /etc/resolv.conf || {
                restore_dns_files
                return 1
            }
        done
        [[ "$DNS_RESOLV_WAS_IMMUTABLE" == "1" ]] && chattr +i /etc/resolv.conf >/dev/null 2>&1 || true
    fi

    if ! verify_dns_change; then
        error "DNS 应用后网络或解析验证失败，正在恢复原配置。"
        restore_dns_files
        return 1
    fi

    log "DNS 已应用并验证成功；原文件备份保存在 $DNS_BACKUP_PATH。"
    return 0
}

submenu_dns() {
    while true; do
        clear
        echo "=================================="
        echo "      --- 三级菜单：DNS 设置 ---"
        echo "=================================="
        echo "当前生效 DNS 配置："
        show_dns_status
        echo "----------------------------------"
        echo "1. 快速设置为 Cloudflare (IPv4 + IPv6)"
        echo "2. 快速设置为 Google (8.8.8.8 / 8.8.4.4)"
        echo -e "${GREEN}3. 手动输入自定义 DNS 地址 (支持 IPv4/IPv6)${NC}"
        echo "0. 返回上一级菜单"
        echo "=================================="
        read -p "请输入选项 [0-3]: " choice_dns

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
                read -p "请输入首选 DNS 地址: " dns1
                read -p "请输入备用 DNS 地址 (留空则不设置): " dns2
                
                if [[ -z "$dns1" ]]; then
                    error "首选 DNS 不能为空！"
                    read -p "按回车键继续..."; continue
                fi

                if [[ "$IPV6_STATUS" == "1" ]]; then
                    if [[ "$dns1" =~ ":" ]] || [[ "$dns2" =~ ":" ]]; then
                        error "当前系统已禁用 IPv6，无法配置 IPv6 格式的 DNS 解析！"
                        read -p "按回车键继续..."; continue
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
            read -p "按回车键继续..."; continue
        fi
        
        sleep 1
        log "DNS 修改成功！"
        echo "当前检测到的 DNS："
        show_dns_status
        read -p "按回车键继续..."
    done
}

# ==========================================
# 模块三：三级菜单 E - IPv6 优先级
# ==========================================
submenu_ipv6() {
    while true; do
        clear
        echo "=================================="
        echo "   --- 三级菜单：IPv6 优先级 ---"
        echo "=================================="
        IPV6_STATUS=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        if [[ "$IPV6_STATUS" == "1" ]]; then
            echo -e "当前 IPv6 状态: ${RED}已禁用${NC}"
        else
            echo -e "当前 IPv6 状态: ${GREEN}已启用${NC}"
            if grep -q "^precedence ::ffff:0:0/96" /etc/gai.conf 2>/dev/null; then
                echo -e "当前路由优先:   ${YELLOW}IPv4 优先${NC}"
            else
                echo -e "当前路由优先:   ${GREEN}系统默认 (通常为 IPv6 优先)${NC}"
            fi
        fi
        echo "----------------------------------"
        echo "1. 强制优先使用 IPv4 (解决双栈机器访问过慢、卡顿)"
        echo "2. 恢复系统默认路由优先级"
        echo -e "${RED}3. 彻底禁用系统 IPv6 功能${NC}"
        echo -e "${GREEN}4. 重新启用系统 IPv6 功能${NC}"
        echo "0. 返回上一级菜单"
        echo "=================================="
        read -p "请输入选项 [0-4]: " choice_ipv6

        touch /etc/gai.conf 2>/dev/null

        case "$choice_ipv6" in
            1)
                log "正在设置 IPv4 优先..."
                sed -i '/^precedence ::ffff:0:0\/96/d' /etc/gai.conf
                echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
                log "IPv4 优先级提升成功。"
                read -p "按回车键继续..." ;;
            2)
                log "正在恢复默认路由优先级..."
                sed -i '/^precedence ::ffff:0:0\/96/d' /etc/gai.conf
                log "路由优先级已恢复系统默认。"
                read -p "按回车键继续..." ;;
            3|4)
                local target_val=1
                [[ "$choice_ipv6" == "4" ]] && target_val=0
                local action_msg=$([[ "$target_val" == 1 ]] && echo "禁用" || echo "启用")
                
                log "正在$action_msg IPv6..."
                sed -i '/^net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
                sed -i '/^net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
                sed -i '/^net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf

                echo "net.ipv6.conf.all.disable_ipv6 = $target_val" >> /etc/sysctl.conf
                echo "net.ipv6.conf.default.disable_ipv6 = $target_val" >> /etc/sysctl.conf
                echo "net.ipv6.conf.lo.disable_ipv6 = $target_val" >> /etc/sysctl.conf
                sysctl -p >/dev/null 2>&1
                
                log "系统 IPv6 已$action_msg。部分接口（如 lo）可能需要重启服务器后才能完全生效。"
                read -p "按回车键继续..." ;;
            0) return ;;
            *) error "无效选项！"; sleep 1; continue ;;
        esac
    done
}

# ==========================================
# 模块三：二级菜单 - 网络与内核优化
# ==========================================
submenu_net() {
    while true; do
        clear
        echo "=================================="
        echo "      3. 网络与内核优化"
        echo "=================================="
        CURRENT_BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        [[ -z "$CURRENT_BBR" ]] && CURRENT_BBR="未知"
        
        echo -e "当前拥塞控制算法: ${YELLOW}$CURRENT_BBR${NC}"
        echo "----------------------------------"
        echo "1. 一键开启 BBR 拥塞控制与 FQ 队列"
        echo -e "2. 配置系统 DNS 解析服务器   ${GREEN}[进入三级菜单]${NC}"
        echo -e "3. 调整 IPv4/IPv6 路由优先级 ${GREEN}[进入三级菜单]${NC}"
        echo "0. 返回主菜单"
        echo "=================================="
        read -p "请输入选项 [0-3]: " choice_net

        case "$choice_net" in
            1) 
                CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
                CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)

                if [[ "$CURRENT_CC" == "bbr" && "$CURRENT_QDISC" == "fq" ]]; then
                    log "BBR 与 FQ 当前均已开启，不创建或修改任何 sysctl 文件。"
                    read -p "按回车键继续..."; continue
                fi

                if [[ "$CURRENT_CC" == "bbr" ]]; then
                    echo -e "${YELLOW}BBR 已开启，但当前默认队列为 ${CURRENT_QDISC:-未知}，不是 fq。${NC}"
                    read -p "是否只补充并启用 FQ？[y/N]: " confirm_fq
                    if [[ "$confirm_fq" == "y" || "$confirm_fq" == "Y" ]]; then
                        persist_bbr_settings "$CURRENT_CC" "$CURRENT_QDISC" 0
                    else
                        log "已保留当前 BBR 与队列配置。"
                    fi
                    read -p "按回车键继续..."; continue
                fi

                K_MAJOR=$(uname -r | cut -d. -f1)
                K_MINOR=$(uname -r | cut -d. -f2)
                if [[ "$K_MAJOR" -lt 4 ]] || [[ "$K_MAJOR" -eq 4 && "$K_MINOR" -lt 9 ]]; then
                    error "当前内核版本 $(uname -r) 过低，BBR 需要 4.9 或以上版本！"
                    read -p "按回车键继续..."; continue
                fi
                
                log "正在根据当前内核的实际能力检测并配置 BBR..."
                command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr >/dev/null 2>&1 || true
                
                if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
                    error "当前内核未包含 BBR 支持，开启失败！"
                    read -p "按回车键继续..."; continue
                fi
                
                persist_bbr_settings "$CURRENT_CC" "$CURRENT_QDISC" 1
                read -p "按回车键继续..." 
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
    local ipv6_disabled
    local ip_preference
    local fail2ban_status

    ssh_port=$(get_ssh_port)
    listening_ports=$(get_listening_ssh_ports)
    password_auth=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2; exit}')
    ipv6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    if [[ "$ipv6_disabled" == "1" ]]; then
        ip_preference="IPv6 已禁用"
    elif grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf 2>/dev/null; then
        ip_preference="IPv4 优先"
    else
        ip_preference="系统默认"
    fi
    fail2ban_status=$(systemctl is-active fail2ban 2>/dev/null || true)

    clear
    echo "=================================================="
    echo "             VPS 关键状态汇总"
    echo "=================================================="
    echo "版本:                 $VERSION"
    echo "拥塞控制 / 队列:      $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知) / $(sysctl -n net.core.default_qdisc 2>/dev/null || echo 未知)"
    echo "TCP 读缓冲上限:       $(sysctl -n net.core.rmem_max 2>/dev/null || echo 未知) bytes"
    echo "TCP 写缓冲上限:       $(sysctl -n net.core.wmem_max 2>/dev/null || echo 未知) bytes"
    echo "netdev backlog:        $(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo 未知)"
    echo "SSH 配置端口:          ${ssh_port:-未知}"
    echo "SSH 实际监听:          ${listening_ports:-未检测到}"
    echo "SSH 密码登录:          ${password_auth:-未知}"
    echo "IPv4/IPv6 优先级:      $ip_preference"
    echo "Fail2ban:              ${fail2ban_status:-未安装或未运行}"
    echo "SWAP:                  $(free -h | awk '/^Swap/{print $2" 总 / "$3" 已用"}')"
    if [[ -f /var/run/reboot-required ]]; then
        echo -e "重启状态:              ${YELLOW}需要重启${NC}"
    else
        echo "重启状态:              当前未检测到重启要求"
    fi
    echo "DNS:"
    show_dns_status
    echo "=================================================="
    read -p "按回车键返回主菜单..."
}

main_menu() {
    while true; do
        MEM_STATUS=$(free -h | awk '/^Mem/{print $2" 总 / "$3" 已用"}')
        DISK_STATUS=$(df -h / | awk 'NR==2{print $4" 可用 / "$2" 总"}')
        LOAD_AVG=$(cat /proc/loadavg | awk '{print "1m:"$1" 5m:"$2" 15m:"$3}')
        
        clear
        echo "=================================================="
        echo -e "      ${GREEN}VPS 极简初始化与安全加固脚本 v$VERSION${NC}"
        echo "=================================================="
        echo -e "  当前系统: ${YELLOW}$OS_ID $OS_VERSION${NC}"
        echo -e "  系统负载: ${YELLOW}$LOAD_AVG${NC}"
        echo -e "  内存状态: ${YELLOW}$MEM_STATUS${NC}"
        echo -e "  磁盘状态: ${YELLOW}$DISK_STATUS${NC}"
        echo "--------------------------------------------------"
        echo "  1. 基础环境与系统优化   # 更新/SWAP/时区"
        echo "  2. 系统安全与防火墙     # SSH加固/防爆破"
        echo "  3. 网络与内核优化       # BBR/DNS/IPv6"
        echo "  4. 查看当前关键状态     # 网络/SSH/DNS/Fail2ban"
        echo "--------------------------------------------------"
        echo "  0. 退出脚本"
        echo "=================================================="
        read -p "请输入选项 [0-4]: " choice_main

        case "$choice_main" in
            1) submenu_env ;;
            2) submenu_sec ;;
            3) submenu_net ;;
            4) show_status_summary ;;
            0) clear; log "已安全退出脚本。"; exit 0 ;;
            *) error "无效输入，请重新选择！"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 启动执行
# ==========================================
check_os
main_menu
