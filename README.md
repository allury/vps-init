# VPS Hardening Toolkit

一键初始化与安全加固 Linux VPS 的交互式脚本，覆盖系统更新、SWAP/时区管理、SSH 强化、Fail2ban 部署、BBR 开启、DNS/IPv6 优化等常用运维操作。

## 特性

- **基础环境优化**：智能系统更新、清理旧内核、快速创建/删除 SWAP、同步时间与时区
- **SSH 安全强化**：修改默认端口（带端口冲突检测、监听验证与自动回滚）、强制密钥登录并禁用密码（严格校验公钥）
- **Fail2ban 自动部署**：自动适配系统日志后端，即装即用
- **网络与内核调优**：一键开启 BBR + FQ 队列、灵活设置 DNS、调整 IPv4/IPv6 优先级或禁用 IPv6
- **全面兼容**：Debian 12/13、Ubuntu 20.04/22.04/24.04 等主流版本，精准识别系统环境
- **安全可靠**：所有关键操作均有备份与自动回滚机制，防误配置导致失联

## 支持的操作系统

| 系统     | 版本                  | 说明                          |
|----------|-----------------------|-------------------------------|
| Debian   | 12 / 13               | 含 testing/trixie 补丁        |
| Ubuntu   | 20.04 / 22.04 / 24.04 | 完整适配 systemd 生态         |

> ⚠️ 目前仅针对 **Debian/Ubuntu** 系列进行适配，其他发行版未测试。

## 快速开始

### 1. 下载并运行

以 **root** 身份执行以下命令：

```bash
# 推荐方式（获取最新版）
wget -O vps.sh https://raw.githubusercontent.com/allury/vps-init/main/vps.sh
chmod +x vps.sh
sudo bash vps.sh
