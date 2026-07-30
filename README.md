# VPS Hardening Toolkit

[![Quality](https://github.com/allury/vps-init/actions/workflows/quality.yml/badge.svg)](https://github.com/allury/vps-init/actions/workflows/quality.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

面向 Debian 和 Ubuntu VPS 的交互式初始化与安全加固脚本。当前版本为 **1.1.2**，集中提供系统更新、SWAP、时区、SSH、Fail2ban、BBR、DNS 和 IPv6 等常用运维操作。

> [!WARNING]
> 本项目会修改 SSH、网络、内核及系统服务配置。运行前请创建快照、确认云厂商控制台可用，并保留一个已登录的备用会话。请先在测试实例验证，再用于生产环境。

## 功能

- 系统更新与软件包清理
- SWAP 创建、检查与删除
- 时区和时间同步配置
- SSH 端口及密钥登录加固
- Fail2ban 安装与规则配置
- BBR 与 FQ 队列配置
- DNS 同步兼容 systemd-resolved、netplan 和 interfaces/cloud-init 配置
- IPv4/IPv6 优先级和 IPv6 开关
- 关键 SSH 操作的配置校验与失败回滚
- Ubuntu 24.04+ `ssh.socket` 处理、真实监听端口检测和 Fail2ban 端口同步
- BBR、SSH、DNS、IPv6、SWAP 与 Fail2ban 关键状态汇总

## 1.1.2 更新

- SWAP 删除只处理脚本管理的 `/swapfile`，操作前确认并备份 `/etc/fstab`，不会再卸载或删除其他 SWAP。
- BBR 根据当前运行状态处理：`bbr + fq` 已生效时不修改文件；仅缺 FQ 时征询后只补 FQ；未启用 BBR 时才搜索现有 `/etc` TCP 配置并安全补齐两项。
- 没有可复用的 `/etc` TCP 配置时才新建 `/etc/sysctl.d/99-vps-init.conf`；系统目录中的配置只读不改，多个候选文件交由用户选择。
- BBR 仍只配置 `net.core.default_qdisc=fq` 与 `net.ipv4.tcp_congestion_control=bbr`，不加入额外 TCP 调优参数。
- DNS 地址增加格式校验；修改前统一备份，应用后验证默认路由与域名解析，失败时自动回滚。

## 1.1.1 更新

- Cloudflare DNS 默认同时配置 IPv4 和 IPv6；IPv6 已禁用时自动跳过 IPv6 地址。
- 系统更新后检测 `/var/run/reboot-required`，提示重启以启用新内核。
- SSH 改端口后自动同步已安装的 Fail2ban，并提醒保留当前会话直至新端口验证成功。

## 支持范围

| 系统 | 版本 | 状态 |
| --- | --- | --- |
| Debian | 12 / 13 | 支持 |
| Ubuntu | 20.04 / 22.04 / 24.04 | 支持 |

其他发行版尚未经过验证。脚本依赖 Bash、systemd 和 Debian 系软件包管理工具。

## 快速开始

请先阅读脚本，再以 `root` 权限运行：

```bash
curl -fsSL https://raw.githubusercontent.com/allury/vps-init/main/vps.sh -o vps.sh
chmod +x vps.sh
sudo ./vps.sh
```

不建议直接使用 `curl | bash`，因为这会跳过运行前审查。

## 运行前检查

1. 为 VPS 创建可恢复的快照。
2. 确认能够通过云厂商控制台或救援模式登录。
3. 将 SSH 公钥写入 `/root/.ssh/authorized_keys`。
4. 修改 SSH 端口时，同步更新安全组和防火墙规则。
5. 在关闭当前 SSH 会话前，用新会话验证登录。

脚本日志默认写入 `/var/log/vps_init.log`；不可写时会回退到 `/tmp/vps_init.log`。

## 开发与检查

```bash
bash -n vps.sh
shellcheck --severity=error vps.sh
```

提交代码前请阅读 [贡献指南](CONTRIBUTING.md)。安全问题请按 [安全策略](SECURITY.md) 私下报告，不要公开创建 Issue。

## 许可证

本项目采用 [MIT License](LICENSE)。
