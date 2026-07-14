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

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/vps_init.log"

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | sed -r 's/\x1B\[[0-9;]*[mK]//g' >> "$LOG_FILE"
}

error() {
    echo -e "${RED}[错误]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" | sed -r 's/\x1B\[[0-9;]*[mK]//g' >> "$LOG_FILE"
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
                log "正在卸载并删除当前 SWAP..."
                swapoff -a
                SWAP_FILE=$(awk '!/^#/ && $3=="swap" {print $1}' /etc/fstab)
                if [[ -n "$SWAP_FILE" && -f "$SWAP_FILE" ]]; then
                    rm -f "$SWAP_FILE"
                fi
                sed -i '/^\s*[^#].*swap/d' /etc/fstab
                log "SWAP 已彻底清理完毕。"
                read -p "按回车键继续..."; continue
                ;;
            0) return ;;
            *) error "无效选项！"; sleep 1; continue ;;
        esac

        if [[ "$choice_swap" =~ ^[1-3]$ ]]; then
            log "正在创建 $swap_size 的 SWAP 文件..."
            
            if command -v numfmt >/dev/null 2>&1; then
                count_val=$(numfmt --from=iec "$swap_size" | awk '{printf "%d", $1/1048576}')
            else
                num="${swap_size//[^0-9]/}"
                unit="${swap_size//[0-9]/}"
                [[ "${unit^^}" == "G" ]] && count_val=$((num * 1024)) || count_val=$num
            fi

            if ! fallocate -l "$swap_size" /swapfile 2>/dev/null; then
                log "当前文件系统不支持 fallocate，正在降级使用 dd 创建 (请耐心等待)..."
                dd if=/dev/zero of=/swapfile bs=1M count="$count_val" status=progress conv=fsync
            fi
            
            if [[ ! -f /swapfile ]] || [[ $(stat -c%s /swapfile) -lt 1048576 ]]; then
                error "SWAP 文件创建失败，磁盘空间可能不足！"
                rm -f /swapfile
                read -p "按回车键继续..."; continue
            fi

            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            
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
        CURRENT_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
        [[ -z "$CURRENT_PORT" ]] && CURRENT_PORT="未知"
        
        PWD_AUTH=$(sshd -T 2>/dev/null | grep -i "^passwordauthentication " | awk '{print $2}')
        [[ "$PWD_AUTH" == "yes" ]] && PWD_STATUS="${RED}已开启 (存在爆破风险)${NC}" || PWD_STATUS="${GREEN}已禁用 (安全)${NC}"
        
        echo -e "当前 SSH 端口: ${YELLOW}$CURRENT_PORT${NC}"
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
                
                log "SSH 端口修改成功！请确保控制台已放行 $new_port 端口，并新开终端验证后再关闭当前会话。"
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
                CURRENT_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
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
submenu_dns() {
    while true; do
        clear
        echo "=================================="
        echo "      --- 三级菜单：DNS 设置 ---"
        echo "=================================="
        echo "当前生效 DNS 配置："
        if systemctl is-active systemd-resolved >/dev/null 2>&1 && command -v resolvectl >/dev/null 2>&1; then
            resolvectl status global 2>/dev/null | grep -E "DNS Servers|DNS Server" | sed 's/^[ \t]*//' | awk '{print " - "$NF}' | sort -u
        else
            grep "^nameserver" /etc/resolv.conf | awk '{print " - "$2}'
        fi
        echo "----------------------------------"
        echo "1. 快速设置为 Cloudflare (1.1.1.1 / 1.0.0.1)"
        echo "2. 快速设置为 Google (8.8.8.8 / 8.8.4.4)"
        echo -e "${GREEN}3. 手动输入自定义 DNS 地址 (支持 IPv4/IPv6)${NC}"
        echo "0. 返回上一级菜单"
        echo "=================================="
        read -p "请输入选项 [0-3]: " choice_dns

        IPV6_STATUS=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        dns1=""
        dns2=""

        case "$choice_dns" in
            1) dns1="1.1.1.1"; dns2="1.0.0.1" ;;
            2) dns1="8.8.8.8"; dns2="8.8.4.4" ;;
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
                ;;
            0) return ;;
            *) error "无效选项！"; sleep 1; continue ;;
        esac

        log "正在配置 DNS..."
        DNS_ENTRY="$dns1"
        [[ -n "$dns2" ]] && DNS_ENTRY="$dns1 $dns2"

        if systemctl is-active systemd-resolved >/dev/null 2>&1; then
            log "检测到 systemd-resolved，正在应用 override 配置..."
            mkdir -p /etc/systemd/resolved.conf.d/
            cat > /etc/systemd/resolved.conf.d/dns.conf <<EOF
[Resolve]
DNS=$DNS_ENTRY
FallbackDNS=
EOF
            systemctl restart systemd-resolved || { error "systemd-resolved 重启失败！"; read -p "按回车键继续..."; continue; }
        else
            log "正在写入传统 /etc/resolv.conf 配置..."
            chattr -i /etc/resolv.conf >/dev/null 2>&1
            [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
            echo "nameserver $dns1" > /etc/resolv.conf
            [[ -n "$dns2" ]] && echo "nameserver $dns2" >> /etc/resolv.conf
            chattr +i /etc/resolv.conf >/dev/null 2>&1
        fi
        
        sleep 1
        log "DNS 修改成功！"
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
                K_MAJOR=$(uname -r | cut -d. -f1)
                K_MINOR=$(uname -r | cut -d. -f2)
                if [[ "$K_MAJOR" -lt 4 ]] || [[ "$K_MAJOR" -eq 4 && "$K_MINOR" -lt 9 ]]; then
                    error "当前内核版本 $(uname -r) 过低，BBR 需要 4.9 或以上版本！"
                    read -p "按回车键继续..."; continue
                fi
                
                log "开始基于 $OS_ID $OS_VERSION 架构校验并配置 BBR..."
                
                # 补丁：简化且安全的逻辑分支
                if [[ "$OS_ID" == "debian" ]]; then
                    if [[ "$OS_VERSION" =~ ^[0-9]+$ && "$OS_VERSION" -le 12 ]]; then
                        modprobe tcp_bbr 2>/dev/null
                    elif [[ "$OS_VERSION" =~ ^[0-9]+$ && "$OS_VERSION" -ge 13 ]]; then
                        log "Debian 13+ 内核已内置 BBR，跳过模块手动加载..."
                    fi
                elif [[ "$OS_ID" == "ubuntu" ]]; then
                    UBUNTU_MAJOR="${OS_VERSION%%.*}"
                    if [[ "$UBUNTU_MAJOR" =~ ^[0-9]+$ && "$UBUNTU_MAJOR" -le 20 ]]; then
                        modprobe tcp_bbr 2>/dev/null
                    else
                        log "Ubuntu 22.04+ 内核已内置 BBR，跳过模块手动加载..."
                    fi
                else
                    modprobe tcp_bbr 2>/dev/null
                fi
                
                if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
                    error "当前内核未包含 BBR 支持，开启失败！"
                    read -p "按回车键继续..."; continue
                fi
                
                mkdir -p /etc/sysctl.d/
                cat > "$SYSCTL_FILE" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
                sysctl --system >/dev/null 2>&1
                
                if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
                    log "BBR 加速模块开启成功！(当前: $(sysctl -n net.ipv4.tcp_congestion_control))"
                else
                    error "BBR 开启失败！请检查系统环境或尝试重启服务器。"
                fi
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
main_menu() {
    while true; do
        MEM_STATUS=$(free -h | awk '/^Mem/{print $2" 总 / "$3" 已用"}')
        DISK_STATUS=$(df -h / | awk 'NR==2{print $4" 可用 / "$2" 总"}')
        LOAD_AVG=$(cat /proc/loadavg | awk '{print "1m:"$1" 5m:"$2" 15m:"$3}')
        
        clear
        echo "=================================================="
        echo -e "         ${GREEN}VPS 极简初始化与安全加固脚本${NC}"
        echo "=================================================="
        echo -e "  当前系统: ${YELLOW}$OS_ID $OS_VERSION${NC}"
        echo -e "  系统负载: ${YELLOW}$LOAD_AVG${NC}"
        echo -e "  内存状态: ${YELLOW}$MEM_STATUS${NC}"
        echo -e "  磁盘状态: ${YELLOW}$DISK_STATUS${NC}"
        echo "--------------------------------------------------"
        echo "  1. 基础环境与系统优化   # 更新/SWAP/时区"
        echo "  2. 系统安全与防火墙     # SSH加固/防爆破"
        echo "  3. 网络与内核优化       # BBR/DNS/IPv6"
        echo "--------------------------------------------------"
        echo "  0. 退出脚本"
        echo "=================================================="
        read -p "请输入选项 [0-3]: " choice_main

        case "$choice_main" in
            1) submenu_env ;;
            2) submenu_sec ;;
            3) submenu_net ;;
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